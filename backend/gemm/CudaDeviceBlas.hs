-- The cuBLAS side of the device-resident runtime: GEMMs over Futhark-owned
-- device buffers through the persistent handle/stream. Outputs are always
-- fresh zero_vector allocations, so cuBLAS never writes into aliased Futhark
-- memory. Each enqueue counts its FLOPs (2*m*n*k per batch element) for MFU
-- reporting.
module CudaDeviceBlas
  ( deviceDenseForward
  , deviceDensePullback
  , deviceBatchedGemmForward
  , deviceBatchedGemmPullback
  , readGemmFlops
  , resetGemmFlops
  ) where

import Blas (Transpose (..))
import Control.Monad (unless, when)
import CudaBlasOps (cudaDeviceGemmEnqueue)
import Data.IORef
import Data.Word (Word64)
import FormalTransformer.Artifact (Numerics (..))
import ProductionPieces
  ( Context
  , DevF32 (..)
  , deviceRawPointer
  , deviceZeros
  , markBlasDirty
  , syncFutharkIfDirty
  , traceOp
  )
import System.IO.Unsafe (unsafePerformIO)

deviceDenseForward
  :: Context -> Numerics -> Int -> Int -> Int -> DevF32 -> DevF32 -> IO DevF32
deviceDenseForward ctx numerics rows inputDim outputDim x weights =
  deviceBatchedGemmForward ctx numerics NoTrans Trans 1
    rows inputDim outputDim inputDim rows outputDim x weights

deviceDensePullback
  :: Context -> Numerics -> Int -> Int -> Int -> DevF32 -> DevF32 -> DevF32
  -> IO (DevF32, DevF32)
deviceDensePullback ctx numerics rows inputDim outputDim x weights outputBar =
  deviceBatchedGemmPullback ctx numerics NoTrans Trans 1
    rows inputDim outputDim inputDim rows outputDim x weights outputBar

deviceBatchedGemmForward
  :: Context
  -> Numerics
  -> Transpose
  -> Transpose
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> DevF32
  -> DevF32
  -> IO DevF32
deviceBatchedGemmForward ctx numerics transA transB groups
    aRows aCols bRows bCols cRows cCols a b = do
  k <- validateShapes transA transB groups aRows aCols bRows bCols cRows cCols a b
  traceOp ("gemm " ++ transposeTag transA ++ transposeTag transB
    ++ " groups=" ++ show groups ++ " a=" ++ dimensions aRows aCols
    ++ " b=" ++ dimensions bRows bCols ++ " c=" ++ dimensions cRows cCols)
  let outputCount = groups * cRows * cCols
  output <- deviceZeros ctx outputCount
  if outputCount == 0 || k == 0
    then pure output
    else do
      -- The fresh output and any pending piece work must be materialized
      -- before cuBLAS touches the raw allocations.
      syncFutharkIfDirty ctx
      rawA <- deviceRawPointer ctx a
      rawB <- deviceRawPointer ctx b
      rawC <- deviceRawPointer ctx output
      cudaDeviceGemmEnqueue numerics transA transB groups
        aRows aCols bRows bCols cRows cCols rawA rawB rawC
      markBlasDirty ctx
      countFlops groups cRows cCols k
      pure output

deviceBatchedGemmPullback
  :: Context
  -> Numerics
  -> Transpose
  -> Transpose
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> DevF32
  -> DevF32
  -> DevF32
  -> IO (DevF32, DevF32)
deviceBatchedGemmPullback ctx numerics transA transB groups
    aRows aCols bRows bCols cRows cCols a b cBar = do
  _ <- validateShapes transA transB groups aRows aCols bRows bCols cRows cCols a b
  let DevF32 _ cBarCount = cBar
  unless (cBarCount == groups * cRows * cCols) $
    deviceBlasError ("C cotangent length mismatch: expected "
      ++ show (groups * cRows * cCols) ++ ", got " ++ show cBarCount)
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
      deviceBatchedGemmForward ctx numerics leftTranspose rightTranspose groups
        leftRows leftCols rightRows rightCols outputRows outputCols left right

validateShapes
  :: Transpose -> Transpose -> Int -> Int -> Int -> Int -> Int -> Int -> Int
  -> DevF32 -> DevF32 -> IO Int
validateShapes transA transB groups aRows aCols bRows bCols cRows cCols
    (DevF32 _ aCount) (DevF32 _ bCount) = do
  when (groups < 0 || minimum [aRows, aCols, bRows, bCols, cRows, cCols] < 0) $
    deviceBlasError "GEMM dimensions must be non-negative"
  let (logicalARows, logicalACols) = logicalShape transA aRows aCols
      (logicalBRows, logicalBCols) = logicalShape transB bRows bCols
  unless (logicalACols == logicalBRows) $
    deviceBlasError ("GEMM inner dimensions do not match: op(A)="
      ++ dimensions logicalARows logicalACols
      ++ ", op(B)=" ++ dimensions logicalBRows logicalBCols)
  unless (cRows == logicalARows && cCols == logicalBCols) $
    deviceBlasError ("GEMM output dimensions do not match: expected "
      ++ dimensions logicalARows logicalBCols
      ++ ", got " ++ dimensions cRows cCols)
  unless (aCount == groups * aRows * aCols) $
    deviceBlasError ("A length mismatch: expected "
      ++ show (groups * aRows * aCols) ++ ", got " ++ show aCount)
  unless (bCount == groups * bRows * bCols) $
    deviceBlasError ("B length mismatch: expected "
      ++ show (groups * bRows * bCols) ++ ", got " ++ show bCount)
  pure logicalACols

logicalShape :: Transpose -> Int -> Int -> (Int, Int)
logicalShape NoTrans rows cols = (rows, cols)
logicalShape Trans rows cols = (cols, rows)

transposeTag :: Transpose -> String
transposeTag NoTrans = "N"
transposeTag Trans = "T"

dimensions :: Int -> Int -> String
dimensions rows cols = show rows ++ "x" ++ show cols

deviceBlasError :: String -> IO a
deviceBlasError = ioError . userError . ("device cuBLAS: " ++)

{-# NOINLINE gemmFlopCounter #-}
gemmFlopCounter :: IORef Word64
gemmFlopCounter = unsafePerformIO (newIORef 0)

countFlops :: Int -> Int -> Int -> Int -> IO ()
countFlops groups cRows cCols k =
  modifyIORef' gemmFlopCounter
    (+ 2 * fromIntegral groups * fromIntegral cRows
       * fromIntegral cCols * fromIntegral k)

readGemmFlops :: IO Word64
readGemmFlops = readIORef gemmFlopCounter

resetGemmFlops :: IO ()
resetGemmFlops = writeIORef gemmFlopCounter 0
