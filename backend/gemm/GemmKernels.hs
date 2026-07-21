-- The device-resident kernel module for the decomposed cuBLAS trainer. It
-- keeps the fused FutharkKernels module API so backend/gpu/Main.hs compiles
-- against either backend, but every array is a real Futhark device handle:
-- pieces run handle-to-handle, GEMMs go through the persistent cuBLAS stream
-- over raw device pointers, and accumulate/clip/AdamW run on device. Host
-- data crosses the boundary only at token upload, checkpoint save/load, and
-- the per-step loss/norm scalars.
module FutharkKernels
  ( Context
  , F32Array
  , I64Array
  , BoolArray
  , GpuConfig (..)
  , gpuConfig
  , gpuConfigIO
  , chunkFor
  , backendNumerics
  , withContext
  , withF32
  , uploadF32
  , withI64_1d
  , withI64_2d
  , withBool
  , downloadF32
  , freeF32
  , batchMeanLoss
  , microBatchLossGrad
  , zeroVector
  , clipGlobalNorm
  , futharkParameterCount
  , logits
  , adamwStep
  , lastLogits
  , decodeStep
  , synchronize
  , gemmFlopsSinceReset
  , resetGemmFlopCount
  , headPathProbe
  ) where

import Control.Exception (bracket, onException)
import Control.Monad (unless)
import CudaDeviceBlas
import Data.Int (Int64)
import qualified Data.Vector.Unboxed as UV
import qualified Data.Vector.Unboxed.Mutable as UMV
import Data.Word (Word64)
import Decomposed (PieceOps (..), modelLossGradDecomposed)
import Foreign.Ptr (Ptr)
import FormalTransformer.Artifact (Numerics (..))
import FormalTransformer.Config
import ProductionPieces
  ( CBool_1d
  , Context
  , DevF32 (..)
  , DevI64 (..)
  , deviceAccumulate
  , deviceAdamwStep
  , deviceClipGlobalNorm
  , deviceZeros
  , freeBool
  , freeI64
  , popArenaKeeping
  , productionPieceOpsWith
  , pushArena
  , syncDevice
  , uploadBool
  , uploadI64
  , withProductionContext
  )
import qualified ProductionPieces as PP
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

newtype F32Array = F32Array DevF32

newtype BoolArray = BoolArray (Ptr CBool_1d)

data I64Array = I64Array ![Int] !DevI64

data GpuConfig = GpuConfig
  { gpuVocab :: !Int64
  , gpuModelDim :: !Int64
  , gpuFfDim :: !Int64
  , gpuHeads :: !Int64
  , gpuLayers :: !Int64
  , gpuChunk :: !Int64
  } deriving (Eq, Show)

gpuConfig :: Config -> Either String GpuConfig
gpuConfig cfg = do
  _ <- validateConfig cfg
  pure GpuConfig
    { gpuVocab = f vocabSize
    , gpuModelDim = f modelDim
    , gpuFfDim = f ffDim
    , gpuHeads = f headCount
    , gpuLayers = f layerCount
    , gpuChunk = fromIntegral (chunkFor (contextSize cfg) (contextSize cfg))
    }
  where
    f field = fromIntegral (field cfg)

gpuConfigIO :: Config -> IO (Either String GpuConfig)
gpuConfigIO cfg = do
  requested <- lookupEnv "GEMM_CHUNK"
  pure $ do
    preferred <- case requested of
      Nothing -> Right 64
      Just value -> case readMaybe value of
        Just candidate | candidate > 0 -> Right candidate
        _ -> Left "GEMM_CHUNK must be a positive integer"
    base <- gpuConfig cfg
    pure base
      { gpuChunk = fromIntegral (chunkFor preferred (contextSize cfg)) }

chunkFor :: Int -> Int -> Int
chunkFor preferred width = maximum
  [ candidate
  | candidate <- [1 .. min (min preferred 64) width]
  , width `mod` candidate == 0
  ]

backendNumerics :: IO Numerics
backendNumerics = do
  selected <- lookupEnv "GEMM_NUMERICS"
  case selected of
    Nothing -> pure Fp32IEEE
    Just "fp32" -> pure Fp32IEEE
    Just "tf32" -> pure Tf32TensorCores
    Just "bf16" -> pure Bf16TensorCores
    Just value -> ioError . userError $
      "GEMM_NUMERICS must be fp32, tf32, or bf16 (got " ++ show value ++ ")"

withContext :: (Context -> IO a) -> IO a
withContext = withProductionContext

withF32 :: Context -> [Float] -> (F32Array -> IO a) -> IO a
withF32 ctx values = bracket (uploadF32 ctx values) (freeF32 ctx)

uploadF32 :: Context -> [Float] -> IO F32Array
uploadF32 ctx values = F32Array <$> PP.uploadF32 ctx values

withI64_1d :: Context -> [Int64] -> (I64Array -> IO a) -> IO a
withI64_1d ctx values action =
  bracket (uploadI64 ctx values) (freeI64 ctx) $ \tokens ->
    action (I64Array [length values] tokens)

withI64_2d :: Context -> Int -> Int -> [Int64] -> (I64Array -> IO a) -> IO a
withI64_2d ctx rows cols values action = do
  unless (rows >= 0 && cols >= 0 && length values == rows * cols) $
    ioError (userError "invalid i64[2] host shape")
  bracket (uploadI64 ctx values) (freeI64 ctx) $ \tokens ->
    action (I64Array [rows, cols] tokens)

withBool :: Context -> [Bool] -> (BoolArray -> IO a) -> IO a
withBool ctx values action =
  bracket (uploadBool ctx values) (freeBool ctx) (action . BoolArray)

downloadF32 :: Context -> Int -> F32Array -> IO [Float]
downloadF32 ctx expected (F32Array dev@(DevF32 _ count)) = do
  unless (count == expected) $
    ioError (userError ("download f32[1] length mismatch: expected "
      ++ show expected ++ ", got " ++ show count))
  PP.downloadF32 ctx dev

freeF32 :: Context -> F32Array -> IO ()
freeF32 ctx (F32Array dev) = PP.freeF32 ctx dev

batchMeanLoss :: Context -> GpuConfig -> F32Array -> I64Array -> IO Float
batchMeanLoss ctx cfg (F32Array params) tokensArray = do
  (batch, width, tokens) <- batchOf tokensArray
  numerics <- backendNumerics
  withArena ctx $ do
    (loss, _) <- modelLossGradDecomposed (pieceOps numerics ctx)
      (configOf cfg width) (fromIntegral (gpuChunk cfg)) batch batch
      params tokens
    pure (loss, [])

microBatchLossGrad
  :: Context -> GpuConfig -> Int64 -> F32Array -> F32Array -> I64Array
  -> IO (Float, F32Array)
microBatchLossGrad ctx cfg effectiveBatch (F32Array accumulator)
    (F32Array params) tokensArray = do
  unless (effectiveBatch > 0) $
    ioError (userError "effective batch must be positive")
  (batch, width, tokens) <- batchOf tokensArray
  numerics <- backendNumerics
  withArena ctx $ do
    (loss, gradient) <- modelLossGradDecomposed (pieceOps numerics ctx)
      (configOf cfg width) (fromIntegral (gpuChunk cfg)) batch
      (fromIntegral effectiveBatch) params tokens
    let DevF32 _ accumulatorCount = accumulator
        DevF32 _ gradientCount = gradient
    unless (accumulatorCount == gradientCount) $
      ioError (userError "gradient accumulator length mismatch")
    accumulated <- deviceAccumulate ctx accumulator gradient
    pure ((loss, F32Array accumulated), [accumulated])

-- All device intermediates of one loss/gradient traversal are freed when the
-- window closes; only the listed survivors escape to the caller.
withArena :: Context -> IO (a, [DevF32]) -> IO a
withArena ctx action = do
  pushArena ctx
  (result, survivors) <- action `onException` popArenaKeeping ctx []
  popArenaKeeping ctx survivors
  pure result

pieceOps :: Numerics -> Context -> PieceOps DevF32 DevI64
pieceOps numerics ctx = productionPieceOpsWith
  (\ops -> ops
    { opsDenseForward = deviceDenseForward ctx numerics
    , opsDenseBackward = deviceDensePullback ctx numerics
    , opsBatchedGemmForward = deviceBatchedGemmForward ctx numerics
    , opsBatchedGemmBackward = deviceBatchedGemmPullback ctx numerics
    })
  ctx

zeroVector :: Context -> Int -> IO F32Array
zeroVector ctx count
  | count < 0 = ioError (userError "zero vector length must be non-negative")
  | otherwise = F32Array <$> deviceZeros ctx count

clipGlobalNorm :: Context -> Float -> F32Array -> IO (Float, F32Array)
clipGlobalNorm ctx maxNorm (F32Array gradient) = do
  (norm, clipped) <- deviceClipGlobalNorm ctx maxNorm gradient
  pure (norm, F32Array clipped)

futharkParameterCount :: Context -> GpuConfig -> IO Int64
futharkParameterCount _ = pure . fromIntegral . paramCount . flip configOf 2

adamwStep
  :: Context -> Int64 -> Float -> Float -> Float -> Float -> Float
  -> F32Array -> F32Array -> F32Array -> F32Array -> BoolArray
  -> IO (F32Array, F32Array, F32Array)
adamwStep ctx step learningRate beta1 beta2 epsilon weightDecay
    (F32Array params) (F32Array gradient) (F32Array firstMoment)
    (F32Array secondMoment) (BoolArray mask) = do
  (params', first', second') <- deviceAdamwStep ctx step learningRate beta1
    beta2 epsilon weightDecay params gradient firstMoment secondMoment mask
  pure (F32Array params', F32Array first', F32Array second')

logits :: Context -> GpuConfig -> Int -> F32Array -> I64Array -> IO [[Float]]
logits _ _ _ _ _ = unsupported "logits"

lastLogits :: Context -> GpuConfig -> F32Array -> I64Array -> IO F32Array
lastLogits _ _ _ _ = unsupported "lastLogits"

decodeStep
  :: Context -> GpuConfig -> Int64 -> Int64 -> Int64
  -> F32Array -> F32Array -> F32Array -> F32Array
  -> IO (F32Array, F32Array, F32Array, F32Array)
decodeStep _ _ _ _ _ _ _ _ _ = unsupported "decodeStep"

unsupported :: String -> IO a
unsupported operation = ioError . userError $
  "GEMM backend does not support generation (" ++ operation ++ ")"

-- Completes all pending device work on both runtimes; the bench timing
-- boundary.  Unconditional: under GEMM_ORDERING=stream the dirty-flag
-- barriers are no-ops, but timing still needs a real device drain.
synchronize :: Context -> IO ()
synchronize = syncDevice

gemmFlopsSinceReset :: Context -> IO Word64
gemmFlopsSinceReset _ = readGemmFlops

resetGemmFlopCount :: Context -> IO ()
resetGemmFlopCount _ = resetGemmFlops

batchOf :: I64Array -> IO (Int, Int, DevI64)
batchOf (I64Array [rows, cols] tokens) = pure (rows, cols, tokens)
batchOf _ = ioError (userError "expected an i64[2] batch")

configOf :: GpuConfig -> Int -> Config
configOf cfg sequenceLength = Config
  { vocabSize = fromIntegral (gpuVocab cfg)
  , contextSize = sequenceLength
  , modelDim = fromIntegral (gpuModelDim cfg)
  , ffDim = fromIntegral (gpuFfDim cfg)
  , layerCount = fromIntegral (gpuLayers cfg)
  , headCount = fromIntegral (gpuHeads cfg)
  }

-- Per-op isolation of the training head path at PRODUCTION dims with
-- synthetic deterministic data: dense forward (cuBLAS), piece_ce_bwd,
-- the dense pullback pair (cuBLAS), piece_rms_norm_bwd, and the embedding
-- scatter are each compared against an independent host reference on a
-- subset of rows.  Motivated by the bpe10m gradient corruption: the tiny
-- conformance dims never exercised these kernels at vocab 8192 / d 320 /
-- rows 2048.
headPathProbe :: Config -> IO ()
headPathProbe cfg = withProductionContext $ \ctx -> do
  numerics <- backendNumerics
  let ops = pieceOps numerics ctx
      batch = 8 :: Int
      n = contextSize cfg
      vocab = vocabSize cfg
      d = modelDim cfg
      rows = batch * n
      sub = 16 :: Int
      noise seed i = 0.5 * sin (fromIntegral i * seed :: Double)
      hHost = [ realToFrac (noise 7.13 i) | i <- [1 .. rows * d] ] :: [Float]
      eHost = [ realToFrac (0.04 * noise 12.9898 i) | i <- [1 .. vocab * d] ] :: [Float]
      dzNoiseHost = [ realToFrac (1.0e-3 * noise 3.77 i) | i <- [1 .. rows * vocab] ] :: [Float]
      barNoiseHost = [ realToFrac (noise 5.21 i) | i <- [1 .. rows * d] ] :: [Float]
      toksHost = [ fromIntegral ((i * 2654435761) `mod` vocab) | i <- [1 .. rows] ] :: [Int64]
      hD = UV.fromListN (rows * d) (map realToFrac hHost) :: UV.Vector Double
      eD = UV.fromListN (vocab * d) (map realToFrac eHost) :: UV.Vector Double
      dzD = UV.fromListN (rows * vocab) (map realToFrac dzNoiseHost) :: UV.Vector Double
      barD = UV.fromListN (rows * d) (map realToFrac barNoiseHost) :: UV.Vector Double
      toksV = UV.fromListN rows (map fromIntegral toksHost) :: UV.Vector Int
      dotHE r w = sum [ (hD UV.! (r * d + j)) * (eD UV.! (w * d + j)) | j <- [0 .. d - 1] ]
      zRow r = UV.generate vocab (dotHE r)
      stage name expected actual = do
        let e = UV.fromListN (length expected) expected :: UV.Vector Double
            a = UV.fromListN (length actual) (map realToFrac actual) :: UV.Vector Double
            dot2 u v = UV.sum (UV.zipWith (*) u v)
            norm2 u = sqrt (dot2 u u)
            c = if norm2 e == 0 || norm2 a == 0 then 0 else dot2 e a / (norm2 e * norm2 a)
            maxDiff = UV.maximum (UV.map abs (UV.zipWith (-) e a))
        putStrLn (name ++ ": cos=" ++ show c ++ " expected_norm=" ++ show (norm2 e)
          ++ " actual_norm=" ++ show (norm2 a) ++ " max_abs_diff=" ++ show maxDiff)
  putStrLn ("head-path-probe rows=" ++ show rows ++ " vocab=" ++ show vocab
    ++ " d=" ++ show d ++ " sub=" ++ show sub ++ " numerics=" ++ show numerics)
  hDev <- PP.uploadF32 ctx hHost
  eDev <- PP.uploadF32 ctx eHost
  dzNoiseDev <- PP.uploadF32 ctx dzNoiseHost
  barNoiseDev <- PP.uploadF32 ctx barNoiseHost
  tokDev <- uploadI64 ctx toksHost
  -- 1: dense forward (cuBLAS) h[rows x d] . E^T -> logits[rows x vocab]
  logitsDev <- opsDenseForward ops rows d vocab hDev eDev
  logitsHost <- PP.downloadF32 ctx logitsDev
  let zSub = concat [ UV.toList (zRow r) | r <- [0 .. sub - 1] ]
  stage "1 dense_fwd(sub rows)" zSub (take (sub * vocab) logitsHost)
  -- 2: piece_ce_bwd on the device logits
  dzDev <- opsCeBackward ops batch n vocab batch 1 logitsDev tokDev
  dzHost <- PP.downloadF32 ctx dzDev
  let denom = fromIntegral batch * fromIntegral (n - 1) :: Double
      dzRefRow r =
        let i = r `mod` n
        in if i == n - 1 then replicate vocab 0
           else
             let z = zRow r
                 zMax = UV.maximum z
                 ez = UV.map (\v -> exp (v - zMax)) z
                 zSum = UV.sum ez
                 t = toksV UV.! (r + 1)
             in [ ((ez UV.! w) / zSum - (if w == t then 1 else 0)) / denom
                | w <- [0 .. vocab - 1] ]
      dzSubRef = concat [ dzRefRow r | r <- [0 .. sub - 1] ]
  stage "2 ce_bwd(sub rows)" dzSubRef (take (sub * vocab) dzHost)
  let lastRows = [ r | r <- [0 .. rows - 1], r `mod` n == n - 1 ]
      lastNonzero = length [ () | r <- lastRows
                           , any (/= 0) (take vocab (drop (r * vocab) dzHost)) ]
  putStrLn ("2b ce_bwd last-position rows nonzero (expect 0): " ++ show lastNonzero)
  -- 3: dense pullback pair (cuBLAS) with the synthetic cotangent
  (aBarDev, bBarDev) <- opsDenseBackward ops rows d vocab hDev eDev dzNoiseDev
  aBarHost <- PP.downloadF32 ctx aBarDev
  bBarHost <- PP.downloadF32 ctx bBarDev
  let aBarRef = [ sum [ (dzD UV.! (r * vocab + w)) * (eD UV.! (w * d + j))
                      | w <- [0 .. vocab - 1] ]
                | r <- [0 .. sub - 1], j <- [0 .. d - 1] ]
      bBarRef = [ sum [ (dzD UV.! (r * vocab + w)) * (hD UV.! (r * d + j))
                      | r <- [0 .. rows - 1] ]
                | w <- [0 .. sub - 1], j <- [0 .. d - 1] ]
  stage "3a dense_bwd inputBar(sub rows)" aBarRef (take (sub * d) aBarHost)
  stage "3b dense_bwd weightBar(sub rows)" bBarRef (take (sub * d) bBarHost)
  -- 4: rms backward at production rows x d with unit gain
  let gainHost = replicate d 1 :: [Float]
  gainDev <- PP.uploadF32 ctx gainHost
  (rmsXBarDev, rmsGainBarDev) <- opsRmsBackward ops rows d hDev gainDev barNoiseDev
  rmsXBarHost <- PP.downloadF32 ctx rmsXBarDev
  rmsGainBarHost <- PP.downloadF32 ctx rmsGainBarDev
  let dn = fromIntegral d :: Double
      rmsRefRow r =
        let x = UV.slice (r * d) d hD
            ob = UV.slice (r * d) d barD
            ms = UV.sum (UV.map (\v -> v * v) x) / dn
            s = sqrt (ms + 1.0e-5)
            uDotX = UV.sum (UV.zipWith (*) ob x)
        in [ (ob UV.! j) / s - (x UV.! j) * uDotX / (dn * s * s * s)
           | j <- [0 .. d - 1] ]
      rmsGainRef = [ sum [ (barD UV.! (r * d + j)) * (hD UV.! (r * d + j))
                             / sqrt (UV.sum (UV.map (\v -> v * v) (UV.slice (r * d) d hD)) / dn + 1.0e-5)
                         | r <- [0 .. rows - 1] ]
                   | j <- [0 .. d - 1] ]
      rmsXSubRef = concat [ rmsRefRow r | r <- [0 .. sub - 1] ]
  stage "4a rms_bwd xBar(sub rows)" rmsXSubRef (take (sub * d) rmsXBarHost)
  stage "4b rms_bwd gainBar(full)" rmsGainRef rmsGainBarHost
  -- 5: embedding scatter with the synthetic bar
  scatterDev <- opsEmbeddingBackward ops vocab d tokDev barNoiseDev
  scatterHost <- PP.downloadF32 ctx scatterDev
  let scatterRef = UV.toList (UV.create (do
        acc <- UMV.replicate (vocab * d) (0 :: Double)
        let go r | r >= rows = pure ()
                 | otherwise = do
                     let t = toksV UV.! r
                         upd j | j >= d = pure ()
                               | otherwise = do
                                   UMV.unsafeModify acc (+ (barD UV.! (r * d + j))) (t * d + j)
                                   upd (j + 1)
                     upd 0
                     go (r + 1)
        go 0
        pure acc))
  stage "5 embed_scatter(full)" scatterRef scatterHost
  -- 6: embedding gather roundtrip
  gatherDev <- opsEmbeddingGather ops vocab d eDev tokDev
  gatherHost <- PP.downloadF32 ctx gatherDev
  let gatherRef = [ eD UV.! ((toksV UV.! r) * d + j) | r <- [0 .. rows - 1], j <- [0 .. d - 1] ]
  stage "6 embed_gather(full)" gatherRef gatherHost
  putStrLn "head-path-probe done"
