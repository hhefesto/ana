{-# LANGUAGE ForeignFunctionInterface #-}

module Blas
  ( Transpose (..)
  , Blas (..)
  , blasGemmPullback
  , blasGemmBatchedPullback
  , openBlas
  ) where

import Buffer
import Control.Monad (forM_, when)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff, pokeElemOff)

data Transpose = NoTrans | Trans
  deriving (Eq, Show)

-- This call-shaped boundary can be implemented by cuBLAS without changing its
-- users. Transposition is logical: views always describe physical row-major
-- matrices, and the flag determines the matrix consumed by GEMM.
data Blas = Blas
  { blasGemm :: Transpose -> Transpose -> Float -> MatrixView -> MatrixView
      -> Float -> MatrixView -> IO ()
  , blasGemmBatched :: Transpose -> Transpose -> Float -> BatchView -> BatchView
      -> Float -> BatchView -> IO ()
  }

openBlas :: Blas
openBlas = Blas cblasGemm cblasGemmBatched

-- Reverse mode for C += alpha * opA(A) * opB(B).  The incoming cotangent dC is
-- multiplied by alpha, and the input cotangents are accumulated with beta=1.
blasGemmPullback
  :: Blas
  -> Transpose
  -> Transpose
  -> Float
  -> MatrixView
  -> MatrixView
  -> MatrixView
  -> MatrixView
  -> MatrixView
  -> IO ()
blasGemmPullback blas transA transB alpha a b dC dA dB =
  case (transA, transB) of
    (NoTrans, NoTrans) -> do
      blasGemm blas NoTrans Trans alpha dC b 1 dA
      blasGemm blas Trans NoTrans alpha a dC 1 dB
    (NoTrans, Trans) -> do
      blasGemm blas NoTrans NoTrans alpha dC b 1 dA
      blasGemm blas Trans NoTrans alpha dC a 1 dB
    (Trans, NoTrans) -> do
      blasGemm blas NoTrans Trans alpha b dC 1 dA
      blasGemm blas NoTrans NoTrans alpha a dC 1 dB
    (Trans, Trans) -> blasError "TT GEMM pullback is not supported by this backend foundation"

blasGemmBatchedPullback
  :: Blas
  -> Transpose
  -> Transpose
  -> Float
  -> BatchView
  -> BatchView
  -> BatchView
  -> BatchView
  -> BatchView
  -> IO ()
blasGemmBatchedPullback blas transA transB alpha as bs dCs dAs dBs = do
  let counts = map batchCount [as, bs, dCs, dAs, dBs]
  when (not (all (== batchCount as) counts)) $
    blasError "batched GEMM pullback operands have different batch counts"
  forM_ [0 .. batchCount as - 1] $ \i -> do
    a <- checkedIO (batchMatrixAt as i)
    b <- checkedIO (batchMatrixAt bs i)
    dC <- checkedIO (batchMatrixAt dCs i)
    dA <- checkedIO (batchMatrixAt dAs i)
    dB <- checkedIO (batchMatrixAt dBs i)
    blasGemmPullback blas transA transB alpha a b dC dA dB

data GemmDims = GemmDims
  { dimM :: !CInt
  , dimN :: !CInt
  , dimK :: !CInt
  , dimLda :: !CInt
  , dimLdb :: !CInt
  , dimLdc :: !CInt
  }

cblasGemm :: Transpose -> Transpose -> Float -> MatrixView -> MatrixView
  -> Float -> MatrixView -> IO ()
cblasGemm transA transB alpha a b beta c = do
  dims <- checkedIO (validateGemm transA transB a b c)
  let m = fromIntegral (dimM dims) :: Int
      n = fromIntegral (dimN dims) :: Int
      k = fromIntegral (dimK dims) :: Int
  if m == 0 || n == 0
    then pure ()
    else if k == 0
      then scaleMatrix beta c
      else withMatrixPtr a $ \aPtr ->
        withMatrixPtr b $ \bPtr ->
          withMatrixPtr c $ \cPtr ->
            c_cblas_sgemm cblasRowMajor (transposeCode transA) (transposeCode transB)
              (dimM dims) (dimN dims) (dimK dims) alpha aPtr (dimLda dims)
              bPtr (dimLdb dims) beta cPtr (dimLdc dims)

cblasGemmBatched :: Transpose -> Transpose -> Float -> BatchView -> BatchView
  -> Float -> BatchView -> IO ()
cblasGemmBatched transA transB alpha as bs beta cs = do
  let counts = [batchCount as, batchCount bs, batchCount cs]
  when (not (all (== batchCount as) counts)) $
    blasError "batched GEMM operands have different batch counts"
  _ <- checkedIO (toCInt "batch count" (batchCount as))
  when (batchCount cs > 1 && batchStride cs == 0) $
    blasError "batched GEMM output stride must be positive"
  _ <- checkedIO (validateGemm transA transB
         (batchMatrix as) (batchMatrix bs) (batchMatrix cs))
  forM_ [0 .. batchCount as - 1] $ \i -> do
    a <- checkedIO (batchMatrixAt as i)
    b <- checkedIO (batchMatrixAt bs i)
    c <- checkedIO (batchMatrixAt cs i)
    cblasGemm transA transB alpha a b beta c

validateGemm :: Transpose -> Transpose -> MatrixView -> MatrixView -> MatrixView
  -> Either String GemmDims
validateGemm transA transB a b c = do
  whenEither (transA == Trans && transB == Trans)
    "TT GEMM is not supported by this backend foundation"
  let (aRows, aCols) = logicalShape transA a
      (bRows, bCols) = logicalShape transB b
  whenEither (aCols /= bRows) "GEMM inner dimensions do not match"
  whenEither (matrixRows c /= aRows || matrixCols c /= bCols)
    "GEMM output dimensions do not match"
  GemmDims
    <$> toCInt "m" aRows
    <*> toCInt "n" bCols
    <*> toCInt "k" aCols
    <*> toCInt "lda" (matrixLeadingDim a)
    <*> toCInt "ldb" (matrixLeadingDim b)
    <*> toCInt "ldc" (matrixLeadingDim c)

logicalShape :: Transpose -> MatrixView -> (Int, Int)
logicalShape NoTrans view = (matrixRows view, matrixCols view)
logicalShape Trans view = (matrixCols view, matrixRows view)

toCInt :: String -> Int -> Either String CInt
toCInt label value
  | value < 0 = Left (label ++ " must be non-negative")
  | toInteger value > toInteger (maxBound :: CInt) =
      Left (label ++ " exceeds CInt range")
  | otherwise = Right (fromIntegral value)

whenEither :: Bool -> String -> Either String ()
whenEither condition message
  | condition = Left message
  | otherwise = Right ()

checkedIO :: Either String a -> IO a
checkedIO = either blasError pure

blasError :: String -> IO a
blasError = ioError . userError . ("BLAS: " ++)

scaleMatrix :: Float -> MatrixView -> IO ()
scaleMatrix beta c = withMatrixPtr c $ \ptr ->
  forM_ [0 .. matrixRows c - 1] $ \row ->
    forM_ [0 .. matrixCols c - 1] $ \col -> do
      let i = row * matrixLeadingDim c + col
      if beta == 0
        then pokeElemOff ptr i 0
        else peekElemOff ptr i >>= pokeElemOff ptr i . (beta *)

cblasRowMajor, cblasNoTrans, cblasTrans :: CInt
cblasRowMajor = 101
cblasNoTrans = 111
cblasTrans = 112

transposeCode :: Transpose -> CInt
transposeCode NoTrans = cblasNoTrans
transposeCode Trans = cblasTrans

foreign import ccall unsafe "cblas_sgemm"
  c_cblas_sgemm :: CInt -> CInt -> CInt -> CInt -> CInt -> CInt
    -> Float -> Ptr Float -> CInt -> Ptr Float -> CInt
    -> Float -> Ptr Float -> CInt -> IO ()
