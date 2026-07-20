module Main (main) where

import Blas (Transpose (..))
import Control.Monad (forM, unless)
import CudaBlasOps
import FormalTransformer.Artifact (Numerics (..))
import Text.Printf (printf)

data Mode = Mode
  { modeNumerics :: !Numerics
  , modeName :: !String
  , modeAbsTolerance :: !Double
  , modeRelTolerance :: !Double
  }

main :: IO ()
main = do
  pointerSize <- cudaDeviceptrSize
  unless (pointerSize == 8) $
    fail ("CUdeviceptr is " ++ show pointerSize
      ++ " bytes; the Word64 FFI boundary expects 8")
  mapM_ testMode modes
  putStrLn "CudaBlasOps GPU runtime tests passed"

modes :: [Mode]
modes =
  [ Mode Fp32IEEE "FP32 IEEE" 3e-6 3e-6
  , Mode Tf32TensorCores "TF32" 4e-3 4e-3
  , Mode Bf16TensorCores "BF16" 3e-2 3e-2
  ]

testMode :: Mode -> IO ()
testMode mode = do
  denseForwardError <- testDenseForward mode
  (denseXError, denseWeightError) <- testDensePullback mode
  batchedErrors <- forM batchedCases (testBatched mode)
  deviceErrors <- forM batchedCases (testDeviceBatched mode)
  let errors = denseForwardError : denseXError : denseWeightError
        : batchedErrors ++ deviceErrors
  printf "%s max errors: dense=%0.8g, dX=%0.8g, dW=%0.8g, NN=%0.8g, NT=%0.8g, TN=%0.8g, devNN=%0.8g, devNT=%0.8g, devTN=%0.8g; overall=%0.8g\n"
    (modeName mode) denseForwardError denseXError denseWeightError
    (batchedErrors !! 0) (batchedErrors !! 1) (batchedErrors !! 2)
    (deviceErrors !! 0) (deviceErrors !! 1) (deviceErrors !! 2)
    (maximum errors)

testDenseForward :: Mode -> IO Double
testDenseForward mode = do
  let rows = 5
      inputDim = 7
      outputDim = 3
      x = testValues 11 (rows * inputDim)
      weights = testValues 23 (outputDim * inputDim)
      expected = gemmReference NoTrans Trans
        rows inputDim outputDim inputDim x weights
  actual <- cudaDenseForward (modeNumerics mode)
    rows inputDim outputDim x weights
  checkResult mode "dense forward" expected actual

testDensePullback :: Mode -> IO (Double, Double)
testDensePullback mode = do
  let rows = 5
      inputDim = 7
      outputDim = 3
      x = testValues 31 (rows * inputDim)
      weights = testValues 43 (outputDim * inputDim)
      outputBar = testValues 59 (rows * outputDim)
      expectedX = gemmReference NoTrans NoTrans
        rows outputDim outputDim inputDim outputBar weights
      expectedWeights = gemmReference Trans NoTrans
        rows outputDim rows inputDim outputBar x
  (actualX, actualWeights) <- cudaDensePullback (modeNumerics mode)
    rows inputDim outputDim x weights outputBar
  xError <- checkResult mode "dense pullback dX" expectedX actualX
  weightError <- checkResult mode "dense pullback dW" expectedWeights actualWeights
  pure (xError, weightError)

data BatchedCase = BatchedCase
  { caseName :: !String
  , caseTransA :: !Transpose
  , caseTransB :: !Transpose
  , caseARows :: !Int
  , caseACols :: !Int
  , caseBRows :: !Int
  , caseBCols :: !Int
  }

-- Every physical and logical extent is odd: op(A)[3,5] * op(B)[5,7].
batchedCases :: [BatchedCase]
batchedCases =
  [ BatchedCase "NN" NoTrans NoTrans 3 5 5 7
  , BatchedCase "NT" NoTrans Trans   3 5 7 5
  , BatchedCase "TN" Trans   NoTrans 5 3 5 7
  ]

testBatched :: Mode -> BatchedCase -> IO Double
testBatched mode testCase = do
  let groups = 3
      aRows = caseARows testCase
      aCols = caseACols testCase
      bRows = caseBRows testCase
      bCols = caseBCols testCase
      aStride = aRows * aCols
      bStride = bRows * bCols
      a = testValues (71 + aStride) (groups * aStride)
      b = testValues (97 + bStride) (groups * bStride)
      expected = concat
        [ gemmReference (caseTransA testCase) (caseTransB testCase)
            aRows aCols bRows bCols
            (take aStride (drop (group * aStride) a))
            (take bStride (drop (group * bStride) b))
        | group <- [0 .. groups - 1]
        ]
  actual <- cudaBatchedGemmForward (modeNumerics mode)
    (caseTransA testCase) (caseTransB testCase) groups
    aRows aCols bRows bCols 3 7 a b
  checkResult mode ("batched " ++ caseName testCase) expected actual

-- The same batched cases through the enqueue-only device-pointer entry: the
-- inputs live in caller-owned device memory, the GEMM lands on the persistent
-- stream, and the result is observed only after cublasContextSync.
testDeviceBatched :: Mode -> BatchedCase -> IO Double
testDeviceBatched mode testCase = do
  let groups = 3
      aRows = caseARows testCase
      aCols = caseACols testCase
      bRows = caseBRows testCase
      bCols = caseBCols testCase
      aStride = aRows * aCols
      bStride = bRows * bCols
      a = testValues (113 + aStride) (groups * aStride)
      b = testValues (127 + bStride) (groups * bStride)
      outputCount = groups * 3 * 7
      expected = concat
        [ gemmReference (caseTransA testCase) (caseTransB testCase)
            aRows aCols bRows bCols
            (take aStride (drop (group * aStride) a))
            (take bStride (drop (group * bStride) b))
        | group <- [0 .. groups - 1]
        ]
  devA <- cudaMallocDevice (length a * 4)
  devB <- cudaMallocDevice (length b * 4)
  devC <- cudaMallocDevice (outputCount * 4)
  cudaCopyToDevice devA a
  cudaCopyToDevice devB b
  cudaDeviceGemmEnqueue (modeNumerics mode)
    (caseTransA testCase) (caseTransB testCase) groups
    aRows aCols bRows bCols 3 7 devA devB devC
  cublasContextSync
  actual <- cudaCopyFromDevice outputCount devC
  mapM_ cudaFreeDevice [devA, devB, devC]
  checkResult mode ("device batched " ++ caseName testCase) expected actual

-- Inputs are Float, while each dot product is accumulated in Double. This is
-- independent of cuBLAS and preserves the packed row-major interpretation.
gemmReference
  :: Transpose -> Transpose
  -> Int -> Int -> Int -> Int
  -> [Float] -> [Float] -> [Double]
gemmReference transA transB aRows aCols bRows bCols a b =
  [ sum
      [ realToFrac (indexOp transA aCols a row inner)
          * realToFrac (indexOp transB bCols b inner col)
      | inner <- [0 .. innerDim - 1]
      ]
  | row <- [0 .. outputRows - 1]
  , col <- [0 .. outputCols - 1]
  ]
  where
    (outputRows, innerDim) = logicalShape transA aRows aCols
    (_, outputCols) = logicalShape transB bRows bCols

indexOp :: Transpose -> Int -> [Float] -> Int -> Int -> Float
indexOp NoTrans physicalCols values row col =
  values !! (row * physicalCols + col)
indexOp Trans physicalCols values row col =
  values !! (col * physicalCols + row)

logicalShape :: Transpose -> Int -> Int -> (Int, Int)
logicalShape NoTrans rows cols = (rows, cols)
logicalShape Trans rows cols = (cols, rows)

testValues :: Int -> Int -> [Float]
testValues seed count =
  [ fromIntegral (((index * 37 + seed * 17) `mod` 41) - 20) / 17
  | index <- [0 .. count - 1]
  ]

checkResult :: Mode -> String -> [Double] -> [Float] -> IO Double
checkResult mode label expected actual = do
  unless (length actual == length expected) $
    fail (label ++ " length mismatch: expected " ++ show (length expected)
      ++ ", got " ++ show (length actual))
  unless (all finite actual) $
    fail (modeName mode ++ " " ++ label ++ " produced a non-finite value")
  let pairs = zip expected (map realToFrac actual)
      errors = [abs (observed - wanted) | (wanted, observed) <- pairs]
      failures =
        [ (index, wanted, observed, err, limit)
        | (index, (wanted, observed)) <- zip [0 :: Int ..] pairs
        , let err = abs (observed - wanted)
        , let limit = modeAbsTolerance mode + modeRelTolerance mode * abs wanted
        , err > limit
        ]
  case failures of
    (index, wanted, observed, err, limit) : _ ->
      fail (modeName mode ++ " " ++ label ++ " mismatch at index " ++ show index
        ++ ": expected " ++ show wanted ++ ", got " ++ show observed
        ++ ", error " ++ show err ++ " exceeds " ++ show limit)
    [] -> pure (maximum (0 : errors))
  where
    finite value = not (isNaN value || isInfinite value)
