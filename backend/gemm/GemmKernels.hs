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
  ) where

import Control.Exception (bracket)
import Control.Monad (unless)
import CudaBlasOps
import Data.Int (Int64)
import Data.IORef
import Data.List (zipWith4)
import Decomposed (PieceOps (..), modelLossGradDecomposed)
import FormalTransformer.Artifact (Numerics (..))
import FormalTransformer.Config
import ProductionPieces
  ( Context
  , productionPieceOpsWith
  , withProductionContext
  )
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

newtype F32Array = F32Array (IORef (Maybe [Float]))
newtype BoolArray = BoolArray (IORef [Bool])

data I64Array = I64Array ![Int] !(IORef [Int64])

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
uploadF32 _ values = F32Array <$> newIORef (Just values)

withI64_1d :: Context -> [Int64] -> (I64Array -> IO a) -> IO a
withI64_1d _ values action = newI64 [length values] values >>= action

withI64_2d :: Context -> Int -> Int -> [Int64] -> (I64Array -> IO a) -> IO a
withI64_2d _ rows cols values action = do
  unless (rows >= 0 && cols >= 0 && length values == rows * cols) $
    ioError (userError "invalid i64[2] host shape")
  newI64 [rows, cols] values >>= action

withBool :: Context -> [Bool] -> (BoolArray -> IO a) -> IO a
withBool _ values action = BoolArray <$> newIORef values >>= action

newI64 :: [Int] -> [Int64] -> IO I64Array
newI64 shape values = I64Array shape <$> newIORef values

downloadF32 :: Context -> Int -> F32Array -> IO [Float]
downloadF32 _ expected array = do
  values <- readF32 array
  unless (length values == expected) $
    ioError (userError ("download f32[1] length mismatch: expected "
      ++ show expected ++ ", got " ++ show (length values)))
  pure values

freeF32 :: Context -> F32Array -> IO ()
freeF32 _ (F32Array ref) = writeIORef ref Nothing

batchMeanLoss :: Context -> GpuConfig -> F32Array -> I64Array -> IO Float
batchMeanLoss ctx cfg paramsArray tokensArray = do
  (batch, width, tokens) <- readBatch tokensArray
  params <- readF32 paramsArray
  numerics <- backendNumerics
  fst <$> modelLossGradDecomposed (pieceOps numerics ctx) (configOf cfg width)
    (fromIntegral (gpuChunk cfg)) batch batch params tokens

microBatchLossGrad
  :: Context -> GpuConfig -> Int64 -> F32Array -> F32Array -> I64Array
  -> IO (Float, F32Array)
microBatchLossGrad ctx cfg effectiveBatch accumulatorArray paramsArray tokensArray = do
  unless (effectiveBatch > 0) $
    ioError (userError "effective batch must be positive")
  (batch, width, tokens) <- readBatch tokensArray
  accumulator <- readF32 accumulatorArray
  params <- readF32 paramsArray
  numerics <- backendNumerics
  (loss, gradient) <- modelLossGradDecomposed (pieceOps numerics ctx) (configOf cfg width)
    (fromIntegral (gpuChunk cfg)) batch (fromIntegral effectiveBatch) params tokens
  unless (length accumulator == length gradient) $
    ioError (userError "gradient accumulator length mismatch")
  accumulated <- uploadF32 ctx (zipWith (+) accumulator gradient)
  pure (loss, accumulated)

pieceOps :: Numerics -> Context -> PieceOps [Float] [Int64]
pieceOps numerics = productionPieceOpsWith $ \ops -> ops
  { opsDenseForward = cudaDenseForward numerics
  , opsDenseBackward = cudaDensePullback numerics
  , opsBatchedGemmForward = cudaBatchedGemmForward numerics
  , opsBatchedGemmBackward = cudaBatchedGemmPullback numerics
  }

zeroVector :: Context -> Int -> IO F32Array
zeroVector ctx count
  | count < 0 = ioError (userError "zero vector length must be non-negative")
  | otherwise = uploadF32 ctx (replicate count 0)

clipGlobalNorm :: Context -> Float -> F32Array -> IO (Float, F32Array)
clipGlobalNorm ctx maxNorm gradientArray = do
  gradient <- readF32 gradientArray
  let norm = sqrt (sum (map (\x -> x * x) gradient))
      scale = if norm > maxNorm then maxNorm / norm else 1
  clipped <- uploadF32 ctx (map (* scale) gradient)
  pure (norm, clipped)

futharkParameterCount :: Context -> GpuConfig -> IO Int64
futharkParameterCount _ = pure . fromIntegral . paramCount . flip configOf 2

adamwStep
  :: Context -> Int64 -> Float -> Float -> Float -> Float -> Float
  -> F32Array -> F32Array -> F32Array -> F32Array -> BoolArray
  -> IO (F32Array, F32Array, F32Array)
adamwStep ctx step learningRate beta1 beta2 epsilon weightDecay
    paramsArray gradientArray firstArray secondArray (BoolArray maskRef) = do
  params <- readF32 paramsArray
  gradient <- readF32 gradientArray
  first <- readF32 firstArray
  second <- readF32 secondArray
  mask <- readIORef maskRef
  let lengths = map length [gradient, first, second]
  unless (all (== length params) lengths && length mask == length params) $
    ioError (userError "AdamW vector length mismatch")
  let first' = zipWith (\m g -> beta1 * m + (1 - beta1) * g) first gradient
      second' = zipWith (\v g -> beta2 * v + (1 - beta2) * g * g) second gradient
      firstCorrection = 1 - beta1 ** fromIntegral step
      secondCorrection = 1 - beta2 ** fromIntegral step
      update p m v decay = p - learningRate
        * (m / firstCorrection / (sqrt (v / secondCorrection) + epsilon)
          + if decay then weightDecay * p else 0)
      params' = zipWith4 update params first' second' mask
  (,,) <$> uploadF32 ctx params' <*> uploadF32 ctx first' <*> uploadF32 ctx second'

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

readF32 :: F32Array -> IO [Float]
readF32 (F32Array ref) = readIORef ref >>= maybe
  (ioError (userError "use of freed f32 array")) pure

readBatch :: I64Array -> IO (Int, Int, [Int64])
readBatch (I64Array [rows, cols] valuesRef) = (,,) rows cols <$> readIORef valuesRef
readBatch _ = ioError (userError "expected an i64[2] batch")

configOf :: GpuConfig -> Int -> Config
configOf cfg sequenceLength = Config
  { vocabSize = fromIntegral (gpuVocab cfg)
  , contextSize = sequenceLength
  , modelDim = fromIntegral (gpuModelDim cfg)
  , ffDim = fromIntegral (gpuFfDim cfg)
  , layerCount = fromIntegral (gpuLayers cfg)
  , headCount = fromIntegral (gpuHeads cfg)
  }
