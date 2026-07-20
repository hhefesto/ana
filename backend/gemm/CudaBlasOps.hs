{-# LANGUAGE ForeignFunctionInterface #-}

module CudaBlasOps
  ( cudaDenseForward
  , cudaDensePullback
  , cudaBatchedGemmForward
  , cudaBatchedGemmPullback
  , CublasCtx
  , globalCublasContext
  , cublasContextSync
  , cudaDeviceGemmEnqueue
  , cudaDeviceptrSize
  , cudaMallocDevice
  , cudaFreeDevice
  , cudaCopyToDevice
  , cudaCopyFromDevice
  ) where

import Blas (Transpose (..))
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Monad (unless, when)
import Data.Word (Word64)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import FormalTransformer.Artifact (Numerics (..))
import System.IO.Unsafe (unsafePerformIO)

-- Y[rows,out] = X[rows,in] * W[out,in]^T. Inputs and output are packed
-- row-major lists, matching checkpoint parameter storage.
cudaDenseForward
  :: Numerics -> Int -> Int -> Int -> [Float] -> [Float] -> IO [Float]
cudaDenseForward numerics rows inputDim outputDim x weights =
  cudaBatchedGemmForward numerics NoTrans Trans 1
    rows inputDim outputDim inputDim rows outputDim x weights

cudaDensePullback
  :: Numerics
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO ([Float], [Float])
cudaDensePullback numerics rows inputDim outputDim x weights outputBar =
  cudaBatchedGemmPullback numerics NoTrans Trans 1
    rows inputDim outputDim inputDim rows outputDim x weights outputBar

cudaBatchedGemmForward
  :: Numerics
  -> Transpose
  -> Transpose
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> IO [Float]
cudaBatchedGemmForward numerics transA transB groups
    aRows aCols bRows bCols cRows cCols a b = do
  call <- validateCall transA transB groups
    aRows aCols bRows bCols cRows cCols a b
  let outputCount = checkedCElements call
  if outputCount == 0 || checkedK call == 0
    then pure (replicate outputCount 0)
    else withArray a $ \aPointer ->
      withArray b $ \bPointer ->
        allocaArray outputCount $ \cPointer -> do
          invoke numerics transA transB call aPointer bPointer cPointer
          peekArray outputCount cPointer

cudaBatchedGemmPullback
  :: Numerics
  -> Transpose
  -> Transpose
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [Float]
  -> [Float]
  -> [Float]
  -> IO ([Float], [Float])
cudaBatchedGemmPullback numerics transA transB groups
    aRows aCols bRows bCols cRows cCols a b cBar = do
  _ <- validateCall transA transB groups
    aRows aCols bRows bCols cRows cCols a b
  cBarCount <- elementCount "C cotangent" groups cRows cCols
  requireLength "C cotangent" cBarCount cBar
  aBar <- case (transA, transB) of
    (NoTrans, NoTrans) -> gemm NoTrans Trans cRows cCols bRows bCols aRows aCols cBar b
    (NoTrans, Trans) -> gemm NoTrans NoTrans cRows cCols bRows bCols aRows aCols cBar b
    (Trans, NoTrans) -> gemm NoTrans Trans bRows bCols cRows cCols aRows aCols b cBar
    (Trans, Trans) -> gemm Trans Trans bRows bCols cRows cCols aRows aCols b cBar
  bBar <- case (transA, transB) of
    (NoTrans, NoTrans) -> gemm Trans NoTrans aRows aCols cRows cCols bRows bCols a cBar
    (NoTrans, Trans) -> gemm Trans NoTrans cRows cCols aRows aCols bRows bCols cBar a
    (Trans, NoTrans) -> gemm NoTrans NoTrans aRows aCols cRows cCols bRows bCols a cBar
    (Trans, Trans) -> gemm Trans Trans cRows cCols aRows aCols bRows bCols cBar a
  pure (aBar, bBar)
  where
    gemm leftTranspose rightTranspose leftRows leftCols rightRows rightCols
        outputRows outputCols left right =
      cudaBatchedGemmForward numerics leftTranspose rightTranspose groups
        leftRows leftCols rightRows rightCols outputRows outputCols left right

data CheckedCall = CheckedCall
  { checkedGroups :: !CInt
  , checkedARows :: !CInt
  , checkedACols :: !CInt
  , checkedBRows :: !CInt
  , checkedBCols :: !CInt
  , checkedCRows :: !CInt
  , checkedCCols :: !CInt
  , checkedK :: !Int
  , checkedCElements :: !Int
  }

validateCall
  :: Transpose -> Transpose -> Int -> Int -> Int -> Int -> Int -> Int -> Int
  -> [Float] -> [Float] -> IO CheckedCall
validateCall transA transB groups aRows aCols bRows bCols cRows cCols a b = do
  let (logicalARows, logicalACols) = logicalShape transA aRows aCols
      (logicalBRows, logicalBCols) = logicalShape transB bRows bCols
  unless (logicalACols == logicalBRows) $
    cudaError ("GEMM inner dimensions do not match: op(A)=" ++ dimensions logicalARows logicalACols
      ++ ", op(B)=" ++ dimensions logicalBRows logicalBCols)
  unless (cRows == logicalARows && cCols == logicalBCols) $
    cudaError ("GEMM output dimensions do not match: expected "
      ++ dimensions logicalARows logicalBCols ++ ", got " ++ dimensions cRows cCols)
  aCount <- elementCount "A" groups aRows aCols
  bCount <- elementCount "B" groups bRows bCols
  cCount <- elementCount "C" groups cRows cCols
  requireLength "A" aCount a
  requireLength "B" bCount b
  CheckedCall
    <$> toCInt "batch count" groups
    <*> toCInt "A rows" aRows
    <*> toCInt "A columns" aCols
    <*> toCInt "B rows" bRows
    <*> toCInt "B columns" bCols
    <*> toCInt "C rows" cRows
    <*> toCInt "C columns" cCols
    <*> pure logicalACols
    <*> pure cCount

logicalShape :: Transpose -> Int -> Int -> (Int, Int)
logicalShape NoTrans rows cols = (rows, cols)
logicalShape Trans rows cols = (cols, rows)

elementCount :: String -> Int -> Int -> Int -> IO Int
elementCount label groups rows cols = do
  when (groups < 0 || rows < 0 || cols < 0) $
    cudaError (label ++ " dimensions must be non-negative")
  let count = toInteger groups * toInteger rows * toInteger cols
  when (count > toInteger (maxBound :: Int)) $
    cudaError (label ++ " element count exceeds Int range")
  pure (fromInteger count)

requireLength :: String -> Int -> [Float] -> IO ()
requireLength label expected values =
  unless (length values == expected) $
    cudaError (label ++ " length mismatch: expected " ++ show expected
      ++ ", got " ++ show (length values))

toCInt :: String -> Int -> IO CInt
toCInt label value
  | value < 0 = cudaError (label ++ " must be non-negative")
  | toInteger value > toInteger (maxBound :: CInt) =
      cudaError (label ++ " exceeds CInt range")
  | otherwise = pure (fromIntegral value)

dimensions :: Int -> Int -> String
dimensions rows cols = show rows ++ "x" ++ show cols

invoke
  :: Numerics
  -> Transpose
  -> Transpose
  -> CheckedCall
  -> Ptr Float
  -> Ptr Float
  -> Ptr Float
  -> IO ()
invoke numerics transA transB call a b c =
  withGlobalCublasContext $ \ctx ->
    allocaBytes errorCapacity $ \errorPointer -> do
      status <- c_ana_cublas_gemm_strided_batched_ctx ctx
        (numericsCode numerics) (transposeCode transA) (transposeCode transB)
        (checkedGroups call)
        (checkedARows call) (checkedACols call)
        (checkedBRows call) (checkedBCols call)
        (checkedCRows call) (checkedCCols call)
        a b c errorPointer (fromIntegral errorCapacity)
      unless (status == 0) $ do
        message <- peekCString errorPointer
        cudaError ((if null message then "cuBLAS shim failed without a diagnostic" else message)
          ++ "; batch=" ++ show (checkedGroups call)
          ++ " A=" ++ dimensionsC (checkedARows call) (checkedACols call)
          ++ " B=" ++ dimensionsC (checkedBRows call) (checkedBCols call)
          ++ " C=" ++ dimensionsC (checkedCRows call) (checkedCCols call))

-- One persistent cuBLAS handle, stream, and workspace per process. The MVar
-- also serializes shim calls; the trainer drives GEMMs from one thread.
data CublasCtx

{-# NOINLINE globalCublasCell #-}
globalCublasCell :: MVar (Maybe (Ptr CublasCtx))
globalCublasCell = unsafePerformIO (newMVar Nothing)

withGlobalCublasContext :: (Ptr CublasCtx -> IO a) -> IO a
withGlobalCublasContext action = modifyMVar globalCublasCell $ \cached -> do
  ctx <- case cached of
    Just ctx -> pure ctx
    Nothing -> allocaBytes errorCapacity $ \errorPointer ->
      alloca $ \ctxPointer -> do
        status <- c_ana_cublas_ctx_create ctxPointer
          errorPointer (fromIntegral errorCapacity)
        unless (status == 0) $ do
          message <- peekCString errorPointer
          cudaError (if null message
            then "persistent cuBLAS context creation failed"
            else message)
        peek ctxPointer
  result <- action ctx
  pure (Just ctx, result)

globalCublasContext :: IO (Ptr CublasCtx)
globalCublasContext = withGlobalCublasContext pure

-- Completes all GEMMs enqueued on the persistent stream. Required before a
-- device output is read, reused by another runtime, or freed.
cublasContextSync :: IO ()
cublasContextSync = withGlobalCublasContext $ \ctx ->
  allocaBytes errorCapacity $ \errorPointer -> do
    status <- c_ana_cublas_ctx_sync ctx errorPointer (fromIntegral errorCapacity)
    unless (status == 0) $ do
      message <- peekCString errorPointer
      cudaError (if null message then "cuBLAS stream sync failed" else message)

-- Enqueue-only GEMM over device pointers; the caller owns ordering per the
-- ownership-transfer contract (inputs ready before the call, cublasContextSync
-- before the output is observed).
cudaDeviceGemmEnqueue
  :: Numerics
  -> Transpose
  -> Transpose
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Word64
  -> Word64
  -> Word64
  -> IO ()
cudaDeviceGemmEnqueue numerics transA transB groups
    aRows aCols bRows bCols cRows cCols a b c =
  withGlobalCublasContext $ \ctx ->
    allocaBytes errorCapacity $ \errorPointer -> do
      groupsC <- toCInt "batch count" groups
      dims <- mapM (uncurry toCInt)
        [ ("A rows", aRows), ("A columns", aCols)
        , ("B rows", bRows), ("B columns", bCols)
        , ("C rows", cRows), ("C columns", cCols)
        ]
      case dims of
        [ar, ac, br, bc, cr, cc] -> do
          status <- c_ana_cublas_gemm_strided_batched_device ctx
            (numericsCode numerics) (transposeCode transA) (transposeCode transB)
            groupsC ar ac br bc cr cc a b c
            errorPointer (fromIntegral errorCapacity)
          unless (status == 0) $ do
            message <- peekCString errorPointer
            cudaError ((if null message
              then "device GEMM failed without a diagnostic" else message)
              ++ "; batch=" ++ show groups
              ++ " A=" ++ dimensions aRows aCols
              ++ " B=" ++ dimensions bRows bCols
              ++ " C=" ++ dimensions cRows cCols)
        _ -> cudaError "device GEMM dimension marshalling failed"

cudaDeviceptrSize :: IO Int
cudaDeviceptrSize = fromIntegral <$> c_ana_cuda_deviceptr_size

cudaMallocDevice :: Int -> IO Word64
cudaMallocDevice bytes =
  allocaBytes errorCapacity $ \errorPointer ->
    alloca $ \outPointer -> do
      status <- c_ana_cuda_malloc outPointer (fromIntegral bytes)
        errorPointer (fromIntegral errorCapacity)
      unless (status == 0) $ do
        message <- peekCString errorPointer
        cudaError (if null message then "cudaMalloc failed" else message)
      peek outPointer

cudaFreeDevice :: Word64 -> IO ()
cudaFreeDevice devicePointer =
  allocaBytes errorCapacity $ \errorPointer -> do
    status <- c_ana_cuda_free devicePointer
      errorPointer (fromIntegral errorCapacity)
    unless (status == 0) $ do
      message <- peekCString errorPointer
      cudaError (if null message then "cudaFree failed" else message)

cudaCopyToDevice :: Word64 -> [Float] -> IO ()
cudaCopyToDevice devicePointer values =
  withArray values $ \hostPointer ->
    allocaBytes errorCapacity $ \errorPointer -> do
      status <- c_ana_cuda_memcpy_h2d devicePointer hostPointer
        (fromIntegral (length values * 4)) errorPointer
        (fromIntegral errorCapacity)
      unless (status == 0) $ do
        message <- peekCString errorPointer
        cudaError (if null message then "host-to-device copy failed" else message)

cudaCopyFromDevice :: Int -> Word64 -> IO [Float]
cudaCopyFromDevice count devicePointer =
  allocaArray count $ \hostPointer ->
    allocaBytes errorCapacity $ \errorPointer -> do
      status <- c_ana_cuda_memcpy_d2h hostPointer devicePointer
        (fromIntegral (count * 4)) errorPointer (fromIntegral errorCapacity)
      unless (status == 0) $ do
        message <- peekCString errorPointer
        cudaError (if null message then "device-to-host copy failed" else message)
      peekArray count hostPointer

dimensionsC :: CInt -> CInt -> String
dimensionsC rows cols = show rows ++ "x" ++ show cols

numericsCode :: Numerics -> CInt
numericsCode Fp32IEEE = 0
numericsCode Tf32TensorCores = 1
numericsCode Bf16TensorCores = 2

transposeCode :: Transpose -> CInt
transposeCode NoTrans = 0
transposeCode Trans = 1

errorCapacity :: Int
errorCapacity = 1024

cudaError :: String -> IO a
cudaError = ioError . userError . ("cuBLAS: " ++)

foreign import ccall unsafe "ana_cublas_ctx_create"
  c_ana_cublas_ctx_create
    :: Ptr (Ptr CublasCtx) -> CString -> CSize -> IO CInt

foreign import ccall unsafe "ana_cublas_ctx_sync"
  c_ana_cublas_ctx_sync
    :: Ptr CublasCtx -> CString -> CSize -> IO CInt

foreign import ccall unsafe "ana_cublas_gemm_strided_batched_ctx"
  c_ana_cublas_gemm_strided_batched_ctx
    :: Ptr CublasCtx -> CInt -> CInt -> CInt -> CInt
    -> CInt -> CInt -> CInt -> CInt -> CInt -> CInt
    -> Ptr Float -> Ptr Float -> Ptr Float -> CString -> CSize -> IO CInt

foreign import ccall unsafe "ana_cublas_gemm_strided_batched_device"
  c_ana_cublas_gemm_strided_batched_device
    :: Ptr CublasCtx -> CInt -> CInt -> CInt -> CInt
    -> CInt -> CInt -> CInt -> CInt -> CInt -> CInt
    -> Word64 -> Word64 -> Word64 -> CString -> CSize -> IO CInt

foreign import ccall unsafe "ana_cuda_deviceptr_size"
  c_ana_cuda_deviceptr_size :: IO CSize

foreign import ccall unsafe "ana_cuda_malloc"
  c_ana_cuda_malloc :: Ptr Word64 -> CSize -> CString -> CSize -> IO CInt

foreign import ccall unsafe "ana_cuda_free"
  c_ana_cuda_free :: Word64 -> CString -> CSize -> IO CInt

foreign import ccall unsafe "ana_cuda_memcpy_h2d"
  c_ana_cuda_memcpy_h2d
    :: Word64 -> Ptr Float -> CSize -> CString -> CSize -> IO CInt

foreign import ccall unsafe "ana_cuda_memcpy_d2h"
  c_ana_cuda_memcpy_d2h
    :: Ptr Float -> Word64 -> CSize -> CString -> CSize -> IO CInt
