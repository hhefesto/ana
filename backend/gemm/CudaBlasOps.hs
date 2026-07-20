{-# LANGUAGE ForeignFunctionInterface #-}

module CudaBlasOps
  ( cudaDenseForward
  , cudaDensePullback
  , cudaBatchedGemmForward
  , cudaBatchedGemmPullback
  ) where

import Blas (Transpose (..))
import Control.Monad (unless, when)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray)
import Foreign.Ptr (Ptr)
import FormalTransformer.Artifact (Numerics (..))

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
  allocaBytes errorCapacity $ \errorPointer -> do
    status <- c_ana_cublas_gemm_strided_batched
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

foreign import ccall unsafe "ana_cublas_gemm_strided_batched"
  c_ana_cublas_gemm_strided_batched
    :: CInt -> CInt -> CInt -> CInt
    -> CInt -> CInt -> CInt -> CInt -> CInt -> CInt
    -> Ptr Float -> Ptr Float -> Ptr Float -> CString -> CSize -> IO CInt
