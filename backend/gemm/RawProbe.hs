-- Pre-flight probes for the device-resident runtime's raw-pointer interop:
-- CUdeviceptr width, cuBLAS-visible writes into Futhark-owned allocations,
-- the device GEMM path end-to-end against a host reference, and whether
-- aliased entry outputs share device memory (informational - the runtime
-- never writes through raw pointers into non-fresh buffers).
module Main (main) where

import Blas (Transpose (..))
import Control.Monad (unless)
import CudaBlasOps (cudaCopyToDevice, cudaDeviceptrSize)
import CudaDeviceBlas
import Data.Int (Int64)
import Decomposed (PieceOps (..), modelLossGradDecomposed)
import FormalTransformer.Artifact (Numerics (..))
import FormalTransformer.Config
import FormalTransformer.Layout
import ProductionPieces
import System.Environment (getArgs)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [] -> probes
    ["e2e", goldenPath] -> endToEnd goldenPath "sigmoid"
    ["e2e", goldenPath, arm] -> endToEnd goldenPath arm
    _ -> fail "usage: raw-probe [e2e GOLDEN_PATH [sigmoid|rglru|qknorm|sinks|v3-tied]]"

probes :: IO ()
probes = withProductionContext $ \ctx -> do
  pointerSize <- cudaDeviceptrSize
  unless (pointerSize == 8) $
    fail ("CUdeviceptr is " ++ show pointerSize ++ " bytes; expected 8")
  putStrLn "probe: CUdeviceptr width is 8 bytes"

  let pattern = [1.5, -2.25, 3.0, 0.125, 9.75] :: [Float]
  scratch <- deviceZeros ctx (length pattern)
  syncFutharkIfDirty ctx
  raw <- deviceRawPointer ctx scratch
  cudaCopyToDevice raw pattern
  written <- downloadF32 ctx scratch
  unless (written == pattern) $
    fail ("raw write through a Futhark allocation did not round-trip: "
      ++ show written)
  freeF32 ctx scratch
  putStrLn "probe: cuda memcpy into a zero_vector allocation round-trips"

  let aRows = 3
      aCols = 4
      bCols = 5
      aValues = [fromIntegral i * 0.5 - 3 | i <- [1 :: Int .. aRows * aCols]]
      bValues = [fromIntegral i * 0.25 + 1 | i <- [1 :: Int .. aCols * bCols]]
      expected =
        [ sum [ aValues !! (row * aCols + inner) * bValues !! (inner * bCols + col)
              | inner <- [0 .. aCols - 1] ]
        | row <- [0 .. aRows - 1]
        , col <- [0 .. bCols - 1]
        ]
  a <- uploadF32 ctx aValues
  b <- uploadF32 ctx bValues
  c <- deviceBatchedGemmForward ctx Fp32IEEE NoTrans NoTrans 1
    aRows aCols aCols bCols aRows bCols a b
  actual <- downloadF32 ctx c
  let worst = maximum (0 : map abs (zipWith (-) actual expected))
  unless (worst <= 1e-5) $
    fail ("device GEMM mismatch: max abs error " ++ show worst)
  mapM_ (freeF32 ctx) [a, b, c]
  putStrLn ("probe: device GEMM against Futhark-owned buffers matches host reference (max abs "
    ++ show worst ++ ")")

  bar <- uploadF32 ctx [7, 8, 9]
  (left, right) <- opsAddBackward (productionPieceOps ctx) bar
  syncFutharkIfDirty ctx
  rawLeft <- deviceRawPointer ctx left
  rawRight <- deviceRawPointer ctx right
  putStrLn ("probe: piece_add_bwd outputs "
    ++ (if rawLeft == rawRight then "ALIAS the same device memory"
        else "occupy distinct device memory"))
  putStrLn "RawProbe passed"

-- The tiny-hybrid end-to-end gate: the device runtime's loss and every
-- gradient entry against the fused-oracle golden values dumped by the CPU
-- conformance driver (GEMM_CONFORMANCE_DUMP). Inputs replicate
-- GemmConformance exactly: the deterministic layout initialization and the
-- fixed two-sequence token batch.  The optional arm selects the battery
-- config the golden was dumped for (GemmConformance writes one golden per
-- arm as GOLDEN.<arm>, base "sigmoid" under the bare name).
endToEnd :: FilePath -> String -> IO ()
endToEnd goldenPath arm = do
  golden <- lines <$> readFile goldenPath
  (goldenLoss, goldenGradient) <- case map read golden :: [Float] of
    lossValue : gradientValues | not (null gradientValues) ->
      pure (lossValue, gradientValues)
    _ -> fail ("invalid golden file: " ++ goldenPath)
  let base = Config 5 4 4 6 5 2 GateSigmoid False False True
  config <- case arm of
    "sigmoid" -> pure base
    "rglru" -> pure base { gateKind = GateRgLru }
    "qknorm" -> pure base { qkNorm = True }
    "sinks" -> pure base { headSinks = True }
    "v3-tied" -> pure base { gateKind = GateRgLru, qkNorm = True, headSinks = True }
    other -> fail ("unknown arm: " ++ other)
  let parameters = either error (concatMap initialize) (namedLayout config)
      initialize slice
        | sliceDecay slice =
            [ 0.025 * sin (fromIntegral (sliceOffset slice + i + 1) * (0.73 :: Double))
            | i <- [0 .. sliceLength slice - 1]
            ]
        | otherwise = replicate (sliceLength slice) 1
      paramFloats = map realToFrac parameters :: [Float]
      flatBatch = [0, 2, 3, 4, 0, 3, 2, 4] :: [Int64]
  unless (length goldenGradient == paramCount config) $
    fail "golden gradient length does not match the tiny config"
  withProductionContext $ \ctx -> do
    params <- uploadF32 ctx paramFloats
    tokens <- uploadI64 ctx flatBatch
    pushArena ctx
    (loss, gradient) <- modelLossGradDecomposed (devicePieceOps ctx) config
      2 2 2 params tokens
    gradientValues <- downloadF32 ctx gradient
    popArenaKeeping ctx []
    freeF32 ctx params
    freeI64 ctx tokens
    let lossError = abs (loss - goldenLoss)
        limit expected = 1e-4 + 1e-3 * abs expected
        failures =
          [ (index, expected, actual)
          | (index, (expected, actual)) <-
              zip [0 :: Int ..] (zip goldenGradient gradientValues)
          , abs (expected - actual) > limit expected
          ]
        worst = maximum
          (0 : map abs (zipWith (-) goldenGradient gradientValues))
    unless (lossError <= limit goldenLoss) $
      fail ("e2e loss mismatch: golden " ++ show goldenLoss
        ++ ", device " ++ show loss)
    case failures of
      (index, expected, actual) : _ ->
        fail ("e2e gradient mismatch at " ++ show index ++ ": golden "
          ++ show expected ++ ", device " ++ show actual)
      [] -> do
        putStrLn ("e2e: device loss=" ++ show loss ++ " golden=" ++ show goldenLoss
          ++ " abs=" ++ show lossError)
        putStrLn ("e2e: every gradient entry within tolerance, elements="
          ++ show (length goldenGradient) ++ ", max_abs=" ++ show worst)
        putStrLn "RawProbe e2e passed"

devicePieceOps :: Context -> PieceOps DevF32 DevI64
devicePieceOps ctx = productionPieceOpsWith
  (\ops -> ops
    { opsDenseForward = deviceDenseForward ctx Fp32IEEE
    , opsDenseBackward = deviceDensePullback ctx Fp32IEEE
    , opsBatchedGemmForward = deviceBatchedGemmForward ctx Fp32IEEE
    , opsBatchedGemmBackward = deviceBatchedGemmPullback ctx Fp32IEEE
    })
  ctx
