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
  ) where

import Control.Exception (bracket, onException)
import Control.Monad (unless)
import CudaDeviceBlas
import Data.Int (Int64)
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
