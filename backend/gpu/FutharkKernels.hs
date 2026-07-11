{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module FutharkKernels
  ( Context
  , F32Array
  , I64Array
  , BoolArray
  , GpuConfig (..)
  , gpuConfig
  , withContext
  , withF32
  , uploadF32
  , withI64_1d
  , withI64_2d
  , withBool
  , downloadF32
  , freeF32
#ifndef OPENCL_BACKEND
  , batchLossGrad
  , lossGrad
#endif
  , batchMeanLoss
  , microBatchLossGrad
  , zeroVector
  , futharkParameterCount
  , logits
  , adamwStep
  , lastLogits
  ) where

import Control.Exception (bracket, throwIO)
import Control.Monad (when)
import Data.Int (Int64)
import Data.Word (Word8)
import Foreign
import Foreign.C.String (CString, newCString, peekCString)
import Foreign.C.Types
import FormalTransformer.Config (Config (..), validateConfig)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data CContextConfig
data CContext
data CF32_1d
data CF32_2d
data CI64_1d
data CI64_2d
data CBool_1d

newtype Context = Context (Ptr CContext)
newtype F32Array = F32Array (Ptr CF32_1d)
newtype I64Array = I64Array (Ptr CI64_1d)
newtype BoolArray = BoolArray (Ptr CBool_1d)

data GpuConfig = GpuConfig
  { gpuVocab :: !Int64
  , gpuModelDim :: !Int64
  , gpuFfDim :: !Int64
  , gpuHeads :: !Int64
  , gpuLayers :: !Int64
  } deriving (Eq, Show)

gpuConfig :: Config -> Either String GpuConfig
gpuConfig cfg = do
  _ <- validateConfig cfg
  pure (GpuConfig (f vocabSize) (f modelDim) (f ffDim) (f headCount) (f layerCount))
  where f = fromIntegral . ($ cfg)

withContext :: (Context -> IO a) -> IO a
withContext action = bracket c_config_new c_config_free $ \cfg -> do
  when (cfg == nullPtr) (throwIO (userError "Futhark context config allocation failed"))
#ifdef OPENCL_BACKEND
  groupSize <- lookupEnv "FUT_GROUP"
  let group = maybe 64 id (groupSize >>= readMaybe)
  when (group <= 0) (throwIO (userError "FUT_GROUP must be a positive integer"))
  c_config_group_size cfg group
  -- rusticl compiles the whole program on the host CPU at context
  -- creation (~1 minute even for the reduced entry set); a cache file
  -- stores the built binary so later contexts load it in seconds.
  cachePath <- lookupEnv "FUT_CACHE"
  case cachePath of
    Nothing -> pure ()
    Just path -> newCString path >>= c_config_set_cache_file cfg
#endif
  bracket (c_context_new cfg) freeContext $ \ctx -> do
    when (ctx == nullPtr) (throwIO (userError "Futhark context creation failed"))
    action (Context ctx)
  where
    freeContext ctx = when (ctx /= nullPtr) (c_context_free ctx)

withF32 :: Context -> [Float] -> (F32Array -> IO a) -> IO a
withF32 ctx values = bracket (uploadF32 ctx values) (freeF32 ctx)

withI64_1d :: Context -> [Int64] -> (I64Array -> IO a) -> IO a
withI64_1d (Context ctx) values = bracket acquire release
  where
    acquire = withArray values $ \p -> checkedPtr ctx "upload i64[1]" (c_new_i64_1d ctx p (fromIntegral (length values))) I64Array
    release (I64Array p) = c_free_i64_1d ctx p >>= check ctx "free i64[1]"

withI64_2d :: Context -> Int -> Int -> [Int64] -> (Ptr CI64_2d -> IO a) -> IO a
withI64_2d (Context ctx) rows cols values action
  | rows < 0 || cols < 0 || length values /= rows * cols = throwIO (userError "invalid i64[2] host shape")
  | otherwise = bracket acquire release action
  where
    acquire = withArray values $ \p -> checkedPtr ctx "upload i64[2]" (c_new_i64_2d ctx p (fromIntegral rows) (fromIntegral cols)) id
    release p = c_free_i64_2d ctx p >>= check ctx "free i64[2]"

withBool :: Context -> [Bool] -> (BoolArray -> IO a) -> IO a
withBool (Context ctx) values = bracket acquire release
  where
    bytes = map (\x -> if x then 1 else 0 :: Word8) values
    acquire = withArray bytes $ \p -> checkedPtr ctx "upload bool[1]" (c_new_bool_1d ctx p (fromIntegral (length bytes))) BoolArray
    release (BoolArray p) = c_free_bool_1d ctx p >>= check ctx "free bool[1]"

uploadF32 :: Context -> [Float] -> IO F32Array
uploadF32 (Context ctx) values = withArray values $ \p ->
  checkedPtr ctx "upload f32[1]" (c_new_f32_1d ctx p (fromIntegral (length values))) F32Array

downloadF32 :: Context -> Int -> F32Array -> IO [Float]
downloadF32 (Context ctx) n (F32Array arr) = allocaArray n $ \out -> do
  c_values_f32_1d ctx arr out >>= check ctx "download f32[1]"
  peekArray n out

freeF32 :: Context -> F32Array -> IO ()
freeF32 (Context ctx) (F32Array arr) = c_free_f32_1d ctx arr >>= check ctx "free f32[1]"

-- The full-batch and single-sequence gradient entries exist only in the
-- full kernels.fut program (sequential C: conformance oracle); the OpenCL
-- trainer program keeps micro_batch_loss_grad as its one vjp entry.
#ifndef OPENCL_BACKEND
batchLossGrad :: Context -> GpuConfig -> F32Array -> Ptr CI64_2d -> IO (Float, F32Array)
batchLossGrad (Context ctx) cfg (F32Array params) tokens = alloca $ \loss -> alloca $ \gradient -> do
  status <- entry_batch_loss_grad ctx loss gradient (gpuVocab cfg) (gpuModelDim cfg) (gpuFfDim cfg) (gpuHeads cfg) (gpuLayers cfg) params tokens
  check ctx "batch_loss_grad" status
  check ctx "batch_loss_grad sync" =<< c_context_sync ctx
  (,) <$> peek loss <*> (F32Array <$> peek gradient)
#endif

-- Accumulates one micro-batch of gradient into the accumulator; the
-- partial objective divides by the effective batch so accumulated chunks
-- sum to the full-batch loss and gradient (up to f32 summation order).
microBatchLossGrad :: Context -> GpuConfig -> Int64 -> F32Array -> F32Array -> Ptr CI64_2d -> IO (Float, F32Array)
microBatchLossGrad (Context ctx) cfg effectiveBatch (F32Array accumulator) (F32Array params) tokens =
  alloca $ \loss -> alloca $ \gradient -> do
    status <- entry_micro_batch_loss_grad ctx loss gradient (gpuVocab cfg) (gpuModelDim cfg) (gpuFfDim cfg) (gpuHeads cfg) (gpuLayers cfg) effectiveBatch accumulator params tokens
    check ctx "micro_batch_loss_grad" status
    check ctx "micro_batch_loss_grad sync" =<< c_context_sync ctx
    (,) <$> peek loss <*> (F32Array <$> peek gradient)

zeroVector :: Context -> Int -> IO F32Array
zeroVector (Context ctx) count = alloca $ \out -> do
  check ctx "zero_vector" =<< entry_zero_vector ctx out (fromIntegral count)
  check ctx "zero_vector sync" =<< c_context_sync ctx
  F32Array <$> peek out

batchMeanLoss :: Context -> GpuConfig -> F32Array -> Ptr CI64_2d -> IO Float
batchMeanLoss (Context ctx) cfg (F32Array params) tokens = alloca $ \loss -> do
  check ctx "batch_mean_loss" =<< entry_batch_mean_loss ctx loss (gpuVocab cfg) (gpuModelDim cfg) (gpuFfDim cfg) (gpuHeads cfg) (gpuLayers cfg) params tokens
  check ctx "batch_mean_loss sync" =<< c_context_sync ctx
  peek loss

futharkParameterCount :: Context -> GpuConfig -> IO Int64
futharkParameterCount (Context ctx) cfg = alloca $ \out -> do
  check ctx "n_params" =<< entry_n_params ctx out (gpuVocab cfg) (gpuModelDim cfg) (gpuFfDim cfg) (gpuLayers cfg)
  check ctx "n_params sync" =<< c_context_sync ctx
  peek out

logits :: Context -> GpuConfig -> Int -> F32Array -> I64Array -> IO [[Float]]
logits (Context ctx) cfg sequenceLength (F32Array params) (I64Array tokens) = alloca $ \out -> do
  check ctx "logits" =<< entry_logits ctx out (gpuVocab cfg) (gpuModelDim cfg) (gpuFfDim cfg) (gpuHeads cfg) (gpuLayers cfg) params tokens
  check ctx "logits sync" =<< c_context_sync ctx
  arr <- peek out
  bracket (pure arr) (\p -> c_free_f32_2d ctx p >>= check ctx "free f32[2]") $ \p ->
    allocaArray (sequenceLength * fromIntegral (gpuVocab cfg)) $ \values -> do
      c_values_f32_2d ctx p values >>= check ctx "download f32[2]"
      rowsOf (fromIntegral (gpuVocab cfg)) <$> peekArray (sequenceLength * fromIntegral (gpuVocab cfg)) values

#ifndef OPENCL_BACKEND
lossGrad :: Context -> GpuConfig -> F32Array -> I64Array -> IO (Float, F32Array)
lossGrad (Context ctx) cfg (F32Array params) (I64Array tokens) = alloca $ \loss -> alloca $ \gradient -> do
  check ctx "loss_grad" =<< entry_loss_grad ctx loss gradient (gpuVocab cfg) (gpuModelDim cfg) (gpuFfDim cfg) (gpuHeads cfg) (gpuLayers cfg) params tokens
  check ctx "loss_grad sync" =<< c_context_sync ctx
  (,) <$> peek loss <*> (F32Array <$> peek gradient)
#endif

rowsOf :: Int -> [a] -> [[a]]
rowsOf _ [] = []
rowsOf width values = take width values : rowsOf width (drop width values)

adamwStep :: Context -> Int64 -> Float -> Float -> Float -> Float -> Float -> F32Array -> F32Array -> F32Array -> F32Array -> BoolArray -> IO (F32Array, F32Array, F32Array)
adamwStep (Context ctx) step lr b1 b2 eps wd (F32Array params) (F32Array grad) (F32Array m) (F32Array v) (BoolArray mask) =
  alloca $ \outP -> alloca $ \outM -> alloca $ \outV -> do
    check ctx "adamw_step" =<< entry_adamw_step ctx outP outM outV step lr b1 b2 eps wd params grad m v mask
    check ctx "adamw_step sync" =<< c_context_sync ctx
    (,,) <$> (F32Array <$> peek outP) <*> (F32Array <$> peek outM) <*> (F32Array <$> peek outV)

lastLogits :: Context -> GpuConfig -> F32Array -> I64Array -> IO F32Array
lastLogits (Context ctx) cfg (F32Array params) (I64Array tokens) = alloca $ \out -> do
  check ctx "last_logits" =<< entry_last_logits ctx out (gpuVocab cfg) (gpuModelDim cfg) (gpuFfDim cfg) (gpuHeads cfg) (gpuLayers cfg) params tokens
  check ctx "last_logits sync" =<< c_context_sync ctx
  F32Array <$> peek out

checkedPtr :: Ptr CContext -> String -> IO (Ptr a) -> (Ptr a -> b) -> IO b
checkedPtr ctx label acquire wrap = do
  ptr <- acquire
  if ptr == nullPtr then failure ctx label else pure (wrap ptr)

check :: Ptr CContext -> String -> CInt -> IO ()
check ctx label status = when (status /= 0) (failure ctx label)

failure :: Ptr CContext -> String -> IO a
failure ctx label = do
  message <- c_context_get_error ctx
  detail <- if message == nullPtr then pure "unknown Futhark error" else peekCString message
  throwIO (userError (label ++ ": " ++ detail))

foreign import ccall unsafe "futhark_context_config_new" c_config_new :: IO (Ptr CContextConfig)
foreign import ccall unsafe "futhark_context_config_free" c_config_free :: Ptr CContextConfig -> IO ()
#ifdef OPENCL_BACKEND
foreign import ccall unsafe "futhark_context_config_set_default_group_size" c_config_group_size :: Ptr CContextConfig -> Int -> IO ()
foreign import ccall unsafe "futhark_context_config_set_cache_file" c_config_set_cache_file :: Ptr CContextConfig -> CString -> IO ()
#endif
foreign import ccall safe "futhark_context_new" c_context_new :: Ptr CContextConfig -> IO (Ptr CContext)
foreign import ccall safe "futhark_context_free" c_context_free :: Ptr CContext -> IO ()
foreign import ccall safe "futhark_context_sync" c_context_sync :: Ptr CContext -> IO CInt
foreign import ccall unsafe "futhark_context_get_error" c_context_get_error :: Ptr CContext -> IO (Ptr CChar)
foreign import ccall safe "futhark_new_f32_1d" c_new_f32_1d :: Ptr CContext -> Ptr Float -> Int64 -> IO (Ptr CF32_1d)
foreign import ccall safe "futhark_values_f32_1d" c_values_f32_1d :: Ptr CContext -> Ptr CF32_1d -> Ptr Float -> IO CInt
foreign import ccall safe "futhark_free_f32_1d" c_free_f32_1d :: Ptr CContext -> Ptr CF32_1d -> IO CInt
foreign import ccall safe "futhark_values_f32_2d" c_values_f32_2d :: Ptr CContext -> Ptr CF32_2d -> Ptr Float -> IO CInt
foreign import ccall safe "futhark_free_f32_2d" c_free_f32_2d :: Ptr CContext -> Ptr CF32_2d -> IO CInt
foreign import ccall safe "futhark_new_i64_1d" c_new_i64_1d :: Ptr CContext -> Ptr Int64 -> Int64 -> IO (Ptr CI64_1d)
foreign import ccall safe "futhark_free_i64_1d" c_free_i64_1d :: Ptr CContext -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_new_i64_2d" c_new_i64_2d :: Ptr CContext -> Ptr Int64 -> Int64 -> Int64 -> IO (Ptr CI64_2d)
foreign import ccall safe "futhark_free_i64_2d" c_free_i64_2d :: Ptr CContext -> Ptr CI64_2d -> IO CInt
foreign import ccall safe "futhark_new_bool_1d" c_new_bool_1d :: Ptr CContext -> Ptr Word8 -> Int64 -> IO (Ptr CBool_1d)
foreign import ccall safe "futhark_free_bool_1d" c_free_bool_1d :: Ptr CContext -> Ptr CBool_1d -> IO CInt
#ifndef OPENCL_BACKEND
foreign import ccall safe "futhark_entry_batch_loss_grad" entry_batch_loss_grad :: Ptr CContext -> Ptr Float -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_2d -> IO CInt
foreign import ccall safe "futhark_entry_loss_grad" entry_loss_grad :: Ptr CContext -> Ptr Float -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
#endif
foreign import ccall safe "futhark_entry_batch_mean_loss" entry_batch_mean_loss :: Ptr CContext -> Ptr Float -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_2d -> IO CInt
foreign import ccall safe "futhark_entry_micro_batch_loss_grad" entry_micro_batch_loss_grad :: Ptr CContext -> Ptr Float -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CI64_2d -> IO CInt
foreign import ccall safe "futhark_entry_zero_vector" entry_zero_vector :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> IO CInt
foreign import ccall safe "futhark_entry_n_params" entry_n_params :: Ptr CContext -> Ptr Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> IO CInt
foreign import ccall safe "futhark_entry_logits" entry_logits :: Ptr CContext -> Ptr (Ptr CF32_2d) -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
foreign import ccall safe "futhark_entry_adamw_step" entry_adamw_step :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Ptr (Ptr CF32_1d) -> Int64 -> Float -> Float -> Float -> Float -> Float -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CF32_1d -> Ptr CBool_1d -> IO CInt
foreign import ccall safe "futhark_entry_last_logits" entry_last_logits :: Ptr CContext -> Ptr (Ptr CF32_1d) -> Int64 -> Int64 -> Int64 -> Int64 -> Int64 -> Ptr CF32_1d -> Ptr CI64_1d -> IO CInt
