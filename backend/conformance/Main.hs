module Main (main) where

import Control.Exception (SomeException, bracket, try)
import Control.Monad (foldM, unless)
import Data.Int (Int64)
import qualified Data.Vector.Unboxed as VU
import FormalTransformer.Config
import FormalTransformer.Layout
import FormalTransformer.Model
import FormalTransformer.Optimizer
import FutharkKernels
import Numeric.AD (grad)
import System.Exit (die)

-- Five layers cover both block kinds: indices 0,1,2,4 are GLA and index 3
-- is softmax full attention, so one oracle run checks the GLA forward and
-- vjp, the NoPE softmax path, and the mixed layer dispatch.  The Haskell
-- reference computes GLA in the recurrent form while Futhark computes the
-- parallel closed form, so these comparisons are also the f32 shadow of the
-- proved recurrent≡parallel theorem.
--
-- The whole battery runs once per architecture arm: the sigmoid config
-- guards the v2 float path, and each v3 arm (RG-LRU gate, qk-norm, sinks,
-- and all three together) is element-wise verified — including its shifted
-- parameter offsets — across forward, vjp, chunked-vs-quadratic, AdamW,
-- micro-batching, and incremental decode.
configs :: [(String, Config)]
configs =
  [ ("sigmoid", Config 5 4 4 6 5 2 GateSigmoid False False)
  , ("rglru", Config 5 4 4 6 5 2 GateRgLru False False)
  , ("qknorm", Config 5 4 4 6 5 2 GateSigmoid True False)
  , ("sinks", Config 5 4 4 6 5 2 GateSigmoid False True)
  , ("v3-all", Config 5 4 4 6 5 2 GateRgLru True True)
  ]

tokens :: [Int]
tokens = [0, 2, 3, 4]

-- Chunk length 2 over 4-token sequences: every comparison in this oracle
-- then exercises the cross-chunk state carry of the chunked GLA execution
-- (chunk-closed), not just the intra-chunk formula.
chunked2 :: GpuConfig -> GpuConfig
chunked2 cfg = cfg { gpuChunk = 2 }

parametersFor :: Config -> [Double]
parametersFor config = either error (concatMap initialize) (namedLayout config)
  where
    initialize slice
      | sliceDecay slice = [0.025 * sin (fromIntegral (sliceOffset slice + i + 1) * 0.73) | i <- [0 .. sliceLength slice - 1]]
      | otherwise = replicate (sliceLength slice) 1

main :: IO ()
main = do
  mapM_ oracleFor configs
  mapM_ microBatchConformance configs
  mapM_ decodeConformance configs
  mapM_ sizeRejectionConformance configs
  chunkRejectionConformance (snd (head configs))
  putStrLn "conformance: all comparisons passed"

oracleFor :: (String, Config) -> IO ()
oracleFor (label, config) = do
  putStrLn ("=== gate: " ++ label)
  let parameters = parametersFor config
  gpuCfg <- either die pure (chunked2 <$> gpuConfig config)
  layout <- either die pure (namedLayout config)
  mask <- either die pure (decayMask config)
  referenceLogits <- either die pure (fullSequenceLogits config parameters tokens)
  let referenceLoss = sequenceLoss config parameters
      referenceGradient = grad (sequenceLoss config) parameters
      optimizerConfig = AdamWConfig 0.002 0.9 0.99 1e-6 0.03 0 10
      oldM = zipWith (\i _ -> 0.0002 * sin (fromIntegral i)) [1 :: Int ..] parameters
      oldV = zipWith (\i _ -> 0.0003 + 0.00001 * fromIntegral (i `mod` 7)) [1 :: Int ..] parameters
      oldState = AdamWState 2 (VU.fromList oldM) (VU.fromList oldV)
  (referenceUpdatedV, referenceState) <- either die pure (adamWStep optimizerConfig mask oldState
    (VU.fromList parameters) (VU.fromList referenceGradient))
  let referenceUpdated = VU.toList referenceUpdatedV
  withContext $ \ctx -> do
    futharkCount <- futharkParameterCount ctx gpuCfg
    assertExact "parameter count: config" (fromIntegral (paramCount config)) futharkCount
    assertExact "parameter count: layout" (fromIntegral (sum (map sliceLength layout))) futharkCount
    withF32 ctx (map realToFrac parameters) $ \deviceParameters ->
      withI64_1d ctx (map fromIntegral tokens) $ \deviceTokens -> do
        futharkLogits <- logits ctx gpuCfg (length tokens) deviceParameters deviceTokens
        compareVector "all logits" 3e-4 3e-4 (concat referenceLogits) (map realToFrac (concat futharkLogits))
        quadraticLogits <- logitsQuadratic ctx gpuCfg (length tokens) deviceParameters deviceTokens
        compareVector "chunked vs quadratic GLA logits" 1e-5 1e-5
          (map realToFrac (concat quadraticLogits)) (map realToFrac (concat futharkLogits :: [Float]) :: [Double])
        compareVector "last logits" 3e-4 3e-4 (last referenceLogits) (map realToFrac (last futharkLogits))
        (futharkLoss, deviceGradient) <- lossGrad ctx gpuCfg deviceParameters deviceTokens
        bracket (pure deviceGradient) (freeF32 ctx) $ \gradient -> do
          futharkGradient <- map realToFrac <$> downloadF32 ctx (paramCount config) gradient
          compareScalar "mean sequence loss" 3e-4 3e-4 referenceLoss (realToFrac futharkLoss)
          compareVector "full gradient" 2e-3 2e-2 referenceGradient futharkGradient
          withF32 ctx (map realToFrac oldM) $ \deviceM ->
            withF32 ctx (map realToFrac oldV) $ \deviceV ->
              withBoolVector ctx mask $ \deviceMask -> do
                (updated, newM, newV) <- adamwStep ctx 3 (realToFrac (learningRate optimizerConfig 3)) 0.9 0.99 1e-6 0.03 deviceParameters gradient deviceM deviceV deviceMask
                bracket (pure updated) (freeF32 ctx) $ \deviceUpdated ->
                  bracket (pure newM) (freeF32 ctx) $ \deviceNewM ->
                    bracket (pure newV) (freeF32 ctx) $ \deviceNewV -> do
                      futharkUpdated <- map realToFrac <$> downloadF32 ctx (paramCount config) deviceUpdated
                      futharkM <- map realToFrac <$> downloadF32 ctx (paramCount config) deviceNewM
                      futharkV <- map realToFrac <$> downloadF32 ctx (paramCount config) deviceNewV
                      compareVector "AdamW parameters" 2e-5 2e-4 referenceUpdated futharkUpdated
                      compareVector "AdamW first moment" 2e-6 2e-4 (VU.toList (firstMoment referenceState)) futharkM
                      compareVector "AdamW second moment" 2e-7 3e-4 (VU.toList (secondMoment referenceState)) futharkV

-- Incremental decoding must observe the same language as whole-prefix
-- evaluation: feeding the tokens one decode_step at a time (fixed GLA
-- state, softmax ring buffer) must reproduce each row of the batch
-- forward.  This is the proved cache-run law (Attention/LinearTrie.agda)
-- checked numerically through the mixed hybrid stack — for BOTH gate
-- parametrizations, since decode_step materializes the RG-LRU gate on a
-- different code path (per-step recurrence) than the chunked kernels.
decodeConformance :: (String, Config) -> IO ()
decodeConformance (label, config) = do
  putStrLn ("=== decode, gate: " ++ label)
  let parameters = parametersFor config
  gpuCfg <- either die pure (chunked2 <$> gpuConfig config)
  referenceLogits <- either die pure (fullSequenceLogits config parameters tokens)
  let d = modelDim config
      hd = modelDim config `div` headCount config
      glaLength = glaLayerCount config * d * hd
      cacheLength = (layerCount config `div` 4) * contextSize config * d
  withContext $ \ctx ->
    withF32 ctx (map realToFrac parameters) $ \deviceParameters -> do
      gla0 <- zeroVector ctx glaLength
      k0 <- zeroVector ctx cacheLength
      v0 <- zeroVector ctx cacheLength
      (rows', (glaN, kN, vN)) <- foldM
        (\(acc, (gla, kc, vc)) (position, token) -> do
          (logitsArr, gla', kc', vc') <- decodeStep ctx gpuCfg
            (fromIntegral (contextSize config)) position token
            deviceParameters gla kc vc
          row <- downloadF32 ctx (vocabSize config) logitsArr
          freeF32 ctx logitsArr
          pure (acc ++ [row], (gla', kc', vc')))
        ([], (gla0, k0, v0))
        (zip [0 :: Int64 ..] (map fromIntegral tokens))
      mapM_ (freeF32 ctx) [glaN, kN, vN]
      compareVector "incremental decode vs whole-prefix logits" 3e-4 3e-4
        (concat referenceLogits) (map realToFrac (concat rows'))

batchSequences :: [[Int]]
batchSequences = [[0, 2, 3, 4], [0, 3, 2, 4], [0, 4, 2, 3], [0, 2, 4, 3]]

-- Micro-batch accumulation must reproduce the full-batch gradient.  Each
-- chunk divides by the effective batch inside the kernel, so per-sequence
-- adjoint seeds are identical to batch_loss_grad and the only permitted
-- divergence is f32 summation order; hence the tight tolerances.  The
-- accumulated gradient is also compared against the Haskell reference at
-- the ordinary cross-backend gradient tolerances.
microBatchConformance :: (String, Config) -> IO ()
microBatchConformance (label, config) = do
  putStrLn ("=== micro-batch, gate: " ++ label)
  let parameters = parametersFor config
  gpuCfg <- either die pure (chunked2 <$> gpuConfig config)
  let n = paramCount config
      batch = map (map fromIntegral) batchSequences :: [[Int64]]
      width = length (head batch)
      referenceBatchLoss params = sum
        [ sequenceLossFor config sequence' params | sequence' <- batchSequences ]
        / fromIntegral (length batchSequences)
      referenceGradient = grad referenceBatchLoss parameters
  withContext $ \ctx ->
    withF32 ctx (map realToFrac parameters) $ \deviceParameters -> do
      (fullLoss, fullGradient) <- withI64_2d ctx (length batch) width (concat batch)
        (batchLossGrad ctx gpuCfg deviceParameters)
      futharkFull <- bracket (pure fullGradient) (freeF32 ctx)
        (fmap (map realToFrac) . downloadF32 ctx n)
      acc0 <- zeroVector ctx n
      (microLoss, microGradient) <- foldM
        (\(lossSoFar, acc) chunk -> do
          (partial, acc') <- withI64_2d ctx (length chunk) width (concat chunk)
            (microBatchLossGrad ctx gpuCfg (fromIntegral (length batch)) acc deviceParameters)
          freeF32 ctx acc
          pure (lossSoFar + partial, acc'))
        (0, acc0)
        [take 2 batch, drop 2 batch]
      futharkMicro <- bracket (pure microGradient) (freeF32 ctx)
        (fmap (map realToFrac) . downloadF32 ctx n)
      compareScalar "micro-batch loss vs full batch" 1e-6 1e-5
        (realToFrac fullLoss) (realToFrac (microLoss :: Float))
      compareVector "micro-batch gradient vs full batch" 1e-6 1e-5 futharkFull futharkMicro
      compareScalar "micro-batch loss vs reference" 3e-4 3e-4
        (referenceBatchLoss parameters) (realToFrac microLoss)
      compareVector "micro-batch gradient vs reference" 2e-3 2e-2 referenceGradient futharkMicro

-- The parameter length is part of the entry interface type; a mis-sized
-- vector must be rejected.  Runs in its own context so the poisoned error
-- state cannot leak into other comparisons.  Run per gate kind: under
-- RG-LRU a v2-sized vector is exactly the mis-size a wrong arch flag would
-- produce, so this doubles as the arch-mismatch rejection check.
sizeRejectionConformance :: (String, Config) -> IO ()
sizeRejectionConformance (label, config) = do
  let parameters = parametersFor config
  gpuCfg <- either die pure (chunked2 <$> gpuConfig config)
  outcome <- try $ withContext $ \ctx ->
    withF32 ctx (map realToFrac (drop 1 parameters)) $ \shortParameters ->
      withI64_1d ctx (map fromIntegral tokens) $ \deviceTokens -> do
        (_, gradient) <- lossGrad ctx gpuCfg shortParameters deviceTokens
        freeF32 ctx gradient
  case (outcome :: Either SomeException ()) of
    Left _ -> putStrLn ("size-typed interface rejects mis-sized parameters (" ++ label ++ "): exact")
    Right () -> die "size-typed interface accepted a mis-sized parameter vector"

-- Exercise the Futhark runtime assertion in a fresh context because a failed
-- call poisons that context.
chunkRejectionConformance :: Config -> IO ()
chunkRejectionConformance config = do
  let parameters = parametersFor config
  gpuCfg <- either die pure (gpuConfig config)
  let invalidCfg = gpuCfg { gpuChunk = 3 }
  outcome <- try $ withContext $ \ctx ->
    withF32 ctx (map realToFrac parameters) $ \deviceParameters ->
      withI64_1d ctx (map fromIntegral tokens) $ \deviceTokens -> do
        _ <- logits ctx invalidCfg (length tokens) deviceParameters deviceTokens
        pure ()
  case (outcome :: Either SomeException ()) of
    Left _ -> putStrLn "chunk schedule rejects a non-divisor: exact"
    Right () -> die "chunk schedule accepted a non-divisor"

sequenceLoss :: (Floating a, Ord a) => Config -> [a] -> a
sequenceLoss config = sequenceLossFor config tokens

sequenceLossFor :: (Floating a, Ord a) => Config -> [Int] -> [a] -> a
sequenceLossFor config sequenceTokens params = sum losses / fromIntegral (length losses)
  where
    losses =
      [ either error id (nextTokenCEGeneric config params (take index sequenceTokens) (sequenceTokens !! index))
      | index <- [1 .. length sequenceTokens - 1]
      ]

assertExact :: (Eq a, Show a) => String -> a -> a -> IO ()
assertExact label expected actual = do
  unless (expected == actual) (die (label ++ " failed: expected " ++ show expected ++ ", got " ++ show actual))
  putStrLn (label ++ ": exact (" ++ show actual ++ ")")

compareScalar :: String -> Double -> Double -> Double -> Double -> IO ()
compareScalar label absolute relative expected actual
  | close absolute relative expected actual = putStrLn (label ++ ": max_abs=" ++ show (abs (expected - actual)) ++ ", max_rel=" ++ show (relativeError expected actual))
  | otherwise = die (label ++ " failed: expected " ++ show expected ++ ", got " ++ show actual ++ ", abs=" ++ show (abs (expected - actual)) ++ ", rel=" ++ show (relativeError expected actual))

compareVector :: String -> Double -> Double -> [Double] -> [Double] -> IO ()
compareVector label absolute relative expected actual
  | length expected /= length actual = die (label ++ " failed: length " ++ show (length expected) ++ " /= " ++ show (length actual))
  | otherwise = case failures of
      [] -> putStrLn (label ++ ": elements=" ++ show (length expected) ++ ", max_abs=" ++ show maxAbsolute ++ ", max_rel=" ++ show maxRelative)
      (index, x, y) : _ ->
        die (label ++ " failed at index " ++ show index ++ ": expected " ++ show x ++ ", got " ++ show y ++ ", abs=" ++ show (abs (x-y)) ++ ", rel=" ++ show (relativeError x y))
  where
    pairs = zip expected actual
    failures = [(i, x, y) | (i, (x, y)) <- zip [0 :: Int ..] pairs, not (close absolute relative x y)]
    maxAbsolute = maximum (0 : [abs (x-y) | (x,y) <- pairs])
    maxRelative = maximum (0 : [relativeError x y | (x,y) <- pairs])

close :: Double -> Double -> Double -> Double -> Bool
close absolute relative expected actual =
  not (isNaN actual || isInfinite actual) && abs (expected - actual) <= absolute + relative * abs expected

relativeError :: Double -> Double -> Double
relativeError expected actual = abs (expected - actual) / max 1e-12 (abs expected)
