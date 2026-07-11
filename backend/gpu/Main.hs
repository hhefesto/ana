module Main (main) where

import Control.Exception (bracket)
import Control.Monad (foldM, when)
import qualified Data.ByteString as BS
import Data.Bits (rotateL, shiftL, shiftR, xor)
import Data.Int (Int64)
import Data.List (foldl', sortOn)
import Data.Word (Word64)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import FormalTransformer.Artifact
import FormalTransformer.Bigram
import FormalTransformer.Config
import FormalTransformer.Data
import FormalTransformer.Layout
import FormalTransformer.Optimizer
import FormalTransformer.Tokenizer
import FutharkKernels
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import Text.Read (readMaybe)

modelId :: Config -> String
modelId cfg = "formal-transformer-futhark-v1:" ++ show cfg

optimizerFor :: Int -> AdamWConfig
optimizerFor steps = AdamWConfig 3e-4 0.9 0.999 1e-8 0.01 (min 100 steps) steps

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["inspect"] -> inspect tinyPreset
    ["inspect", size] -> chooseConfig size >>= inspect
    ["train", corpus, checkpoint, stepsText] -> do
      spec <- parseTarget stepsText
      train corpus checkpoint spec tinyPreset
    ["train", corpus, checkpoint, stepsText, size] -> do
      spec <- parseTarget stepsText
      cfg <- chooseConfig size
      train corpus checkpoint spec cfg
    ["generate", checkpoint, text] -> generate checkpoint text 128
    ["generate", checkpoint, text, budgetText] -> parseNonnegative "MAXTOKENS" budgetText >>= generate checkpoint text
    _ -> die "usage: formal-transformer-gpu inspect [tiny|small] | train CORPUS CHECKPOINT (STEPS|epoch) [tiny|small] | generate CHECKPOINT TEXT [MAXTOKENS]"

chooseConfig :: String -> IO Config
chooseConfig "tiny" = pure tinyPreset
chooseConfig "small" = pure smallPreset
chooseConfig value = die ("unknown model size: " ++ value ++ " (expected tiny or small)")

inspect :: Config -> IO ()
inspect cfg = either die (mapM_ print) (namedLayout cfg) >> do
  putStrLn ("config: " ++ show cfg)
  putStrLn ("parameters: " ++ show (paramCount cfg))

-- A target is either an explicit completed-step count or "epoch": enough
-- steps that every training window has been consumed at least once.
data TargetSpec = ExplicitSteps Int | EpochSteps

parseTarget :: String -> IO TargetSpec
parseTarget "epoch" = pure EpochSteps
parseTarget value = ExplicitSteps <$> parsePositive "STEPS" value

train :: FilePath -> FilePath -> TargetSpec -> Config -> IO ()
train corpusPath checkpointPath spec cfg = do
  batchSize <- positiveEnv "TRAIN_BATCH" 1
  microSize <- positiveEnv "MICRO_BATCH" batchSize
  when (microSize > batchSize) (die "MICRO_BATCH must not exceed TRAIN_BATCH")
  checkpointEvery <- positiveEnv "CHECKPOINT_EVERY" 10
  corpus <- loadCorpus corpusPath >>= either die pure
  split <- either die pure (trainingSequences cfg (corpusDocuments corpus))
  gate <- if null (validation split)
    then pure Nothing
    else either die (pure . Just) (bigramGate cfg (corpusDocuments corpus))
  let windowCount = length (training split)
      (target, sampler) = case spec of
        ExplicitSteps n -> (n, randomSampler batchSize (training split))
        EpochSteps ->
          ( (windowCount + batchSize - 1) `div` batchSize
          , epochSampler batchSize (training split) )
  case spec of
    ExplicitSteps _ -> pure ()
    EpochSteps -> putStrLn ("epoch target: " ++ show windowCount
      ++ " training windows / batch " ++ show batchSize
      ++ " = " ++ show target ++ " steps (deterministic full-coverage order)")
  let identity = Identity (modelId cfg) byteTokenizerIdentity (corpusDatasetIdentity corpus)
      optCfg = optimizerFor target
  existing <- doesFileExist checkpointPath
  checkpoint <- if existing
    then loadCheckpoint checkpointPath >>= either die (validateResume cfg identity optCfg)
    else do
      fresh <- pure (newCheckpoint cfg identity optCfg)
      initFrom <- lookupEnv "TRAIN_INIT"
      case initFrom of
        Nothing -> pure fresh
        Just source -> do
          -- Warm start: copy only the parameters of a compatible previous
          -- run into a NEW run; identity, schedule, optimizer moments,
          -- step, and PRNG are all fresh.  This is how successive corpus
          -- shards chain into one long training trajectory.
          previous <- loadCheckpoint source >>= either die pure
          when (manifestConfig (checkpointManifest previous) /= cfg)
            (die ("TRAIN_INIT checkpoint has a different model configuration: " ++ source))
          putStrLn ("warm start: parameters initialized from " ++ source
            ++ " (completed step " ++ show (adamStep (checkpointOptimizer previous)) ++ ")")
          pure fresh { checkpointParameters = checkpointParameters previous }
  when (adamStep (checkpointOptimizer checkpoint) > target) (die "checkpoint has already passed target STEPS")
  gpuCfg <- either die pure (gpuConfig cfg)
  mask <- either die pure (decayMask cfg)
  let params0 = map realToFrac (checkpointParameters checkpoint)
      state0 = checkpointOptimizer checkpoint
      n = paramCount cfg
  putStrLn ("training config=" ++ show cfg
    ++ " target=" ++ show target
    ++ " completed=" ++ show (adamStep state0)
    ++ " batch=" ++ show batchSize
    ++ " micro=" ++ show microSize
    ++ " checkpoint_every=" ++ show checkpointEvery)
  case gate of
    Nothing -> pure ()
    Just g -> putStrLn ("bigram gate: sample=" ++ show (gateSampleCrossEntropy g)
      ++ " nats full=" ++ show (gateFullCrossEntropy g) ++ " nats")
  withContext $ \ctx -> do
    params <- uploadF32 ctx params0
    m <- uploadF32 ctx (map realToFrac (firstMoment state0))
    v <- uploadF32 ctx (map realToFrac (secondMoment state0))
    withBool ctx mask $ \deviceMask -> do
      let saveSnapshot step rng best deviceParams deviceM deviceV = do
            hostParams <- map realToFrac <$> downloadF32 ctx n deviceParams
            hostM <- map realToFrac <$> downloadF32 ctx n deviceM
            hostV <- map realToFrac <$> downloadF32 ctx n deviceV
            let snapshot = checkpoint
                  { checkpointParameters = hostParams
                  , checkpointOptimizer = AdamWState step hostM hostV
                  , checkpointBestValidationLoss = best
                  , checkpointPRNG = rng
                  }
            saved <- saveCheckpointAtomic checkpointPath snapshot
            either die pure saved
            putStrLn ("checkpoint step=" ++ show step ++ " path=" ++ checkpointPath)
      (paramsFinal, mFinal, vFinal, rngFinal, bestFinal) <-
        loop ctx gpuCfg n optCfg split sampler target (adamStep state0) microSize checkpointEvery
          (gateSampleCrossEntropy <$> gate)
          saveSnapshot params m v deviceMask (checkpointPRNG checkpoint)
          (checkpointBestValidationLoss checkpoint)
      saveSnapshot target rngFinal bestFinal paramsFinal mFinal vFinal
      putStrLn ("saved checkpoint at completed step " ++ show target ++ ": " ++ checkpointPath)
      mapM_ (freeF32 ctx) [paramsFinal, mFinal, vFinal]

-- Given the one-based step and the PRNG, a sampler yields that step's
-- batch.  The random sampler threads the PRNG; the epoch sampler is a
-- pure function of the step, so resume needs only the completed count.
type Sampler = Int -> PRNGState -> ([[Int64]], PRNGState)

randomSampler :: Int -> [[Int64]] -> Sampler
randomSampler batchSize windows _ rng = sampleBatch batchSize rng windows

-- Deterministic full-coverage order: windows sorted by a hash of their
-- index, sliced cyclically by step.  After ceil(count/batch) steps every
-- training window has been consumed at least once; the final slice wraps.
epochSampler :: Int -> [[Int64]] -> Sampler
epochSampler batchSize windows = \step rng ->
  let start = (step - 1) * batchSize `mod` count
      batch = [permuted !! ((start + i) `mod` count) | i <- [0 .. batchSize - 1]]
  in (batch, rng)
  where
    count = length windows
    permuted = map snd (sortOn fst (zipWith tag [0 ..] windows))
    tag index window = (hashIndex index, window)
    hashIndex :: Word64 -> Word64
    hashIndex x0 = x3 `xor` (x3 `shiftR` 31)
      where
        x1 = (x0 + 0x45504f4348) `xor` ((x0 + 0x45504f4348) `shiftR` 30)
        x2 = x1 * 0xbf58476d1ce4e5b9
        x3 = (x2 `xor` (x2 `shiftR` 27)) * 0x94d049bb133111eb

loop
  :: Context
  -> GpuConfig
  -> Int
  -> AdamWConfig
  -> Split [Int64]
  -> Sampler
  -> Int
  -> Int
  -> Int
  -> Int
  -> Maybe Double
  -> (Int -> PRNGState -> Maybe Double -> F32Array -> F32Array -> F32Array -> IO ())
  -> F32Array
  -> F32Array
  -> F32Array
  -> BoolArray
  -> PRNGState
  -> Maybe Double
  -> IO (F32Array, F32Array, F32Array, PRNGState, Maybe Double)
loop ctx gpuCfg n optCfg split sampler target completed microSize checkpointEvery gate saveSnapshot params m v mask rng best
  | completed >= target = pure (params, m, v, rng, best)
  | otherwise = do
      let step = completed + 1
          (batch, rng') = sampler step rng
          lr = realToFrac (learningRate optCfg step)
      when (null batch) (die "internal error: sampled an empty training batch")
      (loss, gradient) <- microLossGrad ctx gpuCfg n microSize batch params
      (params', m', v') <- bracket (pure gradient) (freeF32 ctx) $ \g ->
        adamwStep ctx (fromIntegral step) lr (f beta1) (f beta2) (f adamEpsilon) (f weightDecay) params g m v mask
      freeF32 ctx params
      freeF32 ctx m
      freeF32 ctx v
      best' <- if null (validation split) || (step `mod` 10 /= 0 && step /= target)
        then pure best
        else do
          let val = take 8 (validation split)
          when (null val) (die "internal error: selected an empty validation batch")
          valLoss <- chunkedMeanLoss ctx gpuCfg microSize val params'
          let gateText = case gate of
                Nothing -> ""
                Just g -> " gate=" ++ show g
                  ++ (if realToFrac valLoss < g then " beats-gate" else " behind-gate")
          putStrLn ("step " ++ show step ++ " train_loss=" ++ show loss
            ++ " validation_loss=" ++ show valLoss ++ gateText)
          pure (Just (maybe (realToFrac valLoss) (min (realToFrac valLoss)) best))
      when (step `mod` 10 /= 0 && step /= target) (putStrLn ("step " ++ show step ++ " train_loss=" ++ show loss))
      when (step `mod` checkpointEvery == 0 && step /= target) $
        saveSnapshot step rng' best' params' m' v'
      loop ctx gpuCfg n optCfg split sampler target step microSize checkpointEvery gate saveSnapshot
        params' m' v' mask rng' best'
  where f field = realToFrac (field optCfg)

-- Micro-batched gradient of the effective-batch mean loss.  Each chunk's
-- adjoints are seeded with 1/effective-batch inside the kernel, so the
-- accumulated gradient equals the full-batch gradient up to f32 summation
-- order, and one AdamW step per effective batch keeps step semantics.
microLossGrad :: Context -> GpuConfig -> Int -> Int -> [[Int64]] -> F32Array -> IO (Float, F32Array)
microLossGrad ctx gpuCfg n microSize batch params = do
  acc0 <- zeroVector ctx n
  foldM accumulate (0, acc0) (chunksOf microSize batch)
  where
    effective = fromIntegral (length batch)
    accumulate (lossSoFar, acc) chunk = do
      width <- case chunk of
        [] -> die "internal error: empty micro-batch chunk"
        first : _ -> pure (length first)
      (partial, acc') <- withI64_2d ctx (length chunk) width (concat chunk)
        (microBatchLossGrad ctx gpuCfg effective acc params)
      freeF32 ctx acc
      pure (lossSoFar + partial, acc')

-- Count-weighted mean over equal chunks; identical to one batchMeanLoss
-- call up to f32 association, but each kernel launch stays watchdog-sized.
chunkedMeanLoss :: Context -> GpuConfig -> Int -> [[Int64]] -> F32Array -> IO Float
chunkedMeanLoss ctx gpuCfg microSize windows params = do
  weighted <- mapM chunkLoss (chunksOf microSize windows)
  pure (sum weighted / fromIntegral (length windows))
  where
    chunkLoss chunk = do
      width <- case chunk of
        [] -> die "internal error: empty validation chunk"
        first : _ -> pure (length first)
      chunkMean <- withI64_2d ctx (length chunk) width (concat chunk)
        (batchMeanLoss ctx gpuCfg params)
      pure (fromIntegral (length chunk) * chunkMean)

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf size values = take size values : chunksOf size (drop size values)

trainingSequences :: Config -> [Document] -> Either String (Split [Int64])
trainingSequences cfg documents = do
  split <- trainerWindowSplit (contextSize cfg) documents
  pure (Split (convert (training split)) (convert (validation split)))
  where convert = map (map fromIntegral)

newCheckpoint :: Config -> Identity -> AdamWConfig -> Checkpoint
newCheckpoint cfg identity optCfg = Checkpoint manifest params (initAdamW count) Nothing initialPRNG
  where
    count = paramCount cfg
    manifest = Manifest artifactVersion cfg count canonicalLayoutIdentity canonicalLayoutVersion optCfg identity
    params = either error (concatMap initialize) (namedLayout cfg)
    initialize slice
      | sliceDecay slice = [0.02 * sin (fromIntegral (sliceOffset slice + i + 1) * 12.9898) | i <- [0 .. sliceLength slice - 1]]
      | otherwise = replicate (sliceLength slice) 1

validateResume :: Config -> Identity -> AdamWConfig -> Checkpoint -> IO Checkpoint
validateResume cfg identity optCfg checkpoint = do
  let manifest = checkpointManifest checkpoint
  when (manifestConfig manifest /= cfg) (die "checkpoint config does not match requested model size")
  when (manifestIdentity manifest /= identity) (die "checkpoint model/tokenizer/dataset identity mismatch")
  when (manifestOptimizerConfig manifest /= optCfg) (die
    ("checkpoint optimizer config does not exactly match this run\n"
      ++ "  checkpoint: " ++ show (manifestOptimizerConfig manifest) ++ "\n"
      ++ "  this run:   " ++ show optCfg ++ "\n"
      ++ "  the schedule is anchored at run creation; to train with a"
      ++ " different target (or a different TRAIN_BATCH for an epoch"
      ++ " target), start a new CHECKPOINT path"))
  when (manifestLayoutIdentity manifest /= canonicalLayoutIdentity || manifestLayoutVersion manifest /= canonicalLayoutVersion) (die "checkpoint layout identity mismatch")
  pure checkpoint

generate :: FilePath -> String -> Int -> IO ()
generate checkpointPath text budget = do
  checkpoint <- loadCheckpoint checkpointPath >>= either die pure
  let manifest = checkpointManifest checkpoint
      cfg = manifestConfig manifest
      identity = manifestIdentity manifest
  when (tokenizerIdentity identity /= byteTokenizerIdentity) (die "checkpoint does not use the fixed byte tokenizer")
  when (modelIdentity identity /= modelId cfg) (die "checkpoint model identity is not supported by this GPU host")
  gpuCfg <- either die pure (gpuConfig cfg)
  let promptBytes = Text.encodeUtf8 (Text.pack text)
      prompt = bosToken : encodeBytes promptBytes
      n = paramCount cfg
  generated <- withContext $ \ctx -> withF32 ctx (map realToFrac (checkpointParameters checkpoint)) $ \params ->
    generateLoop ctx gpuCfg cfg params budget prompt []
  bytes <- either die pure (decodeBytes generated)
  BS.putStr (promptBytes <> bytes)
  putStrLn ""

generateLoop :: Context -> GpuConfig -> Config -> F32Array -> Int -> [Int] -> [Int] -> IO [Int]
generateLoop _ _ _ _ 0 _ output = pure output
generateLoop ctx gpuCfg cfg params remaining state output = do
  let context = takeEnd (contextSize cfg) state
  logits <- withI64_1d ctx (map fromIntegral context) $ \tokens ->
    bracket (lastLogits ctx gpuCfg params tokens) (freeF32 ctx) (downloadF32 ctx (vocabSize cfg))
  let token = argmax logits
  if token == eosToken then pure output
  else if token == bosToken
    then generateLoop ctx gpuCfg cfg params (remaining - 1) (state ++ [token]) output
    else generateLoop ctx gpuCfg cfg params (remaining - 1) (state ++ [token]) (output ++ [token])

sampleBatch :: Int -> PRNGState -> [a] -> ([a], PRNGState)
sampleBatch count state values = foldl' pick ([], state) [1 .. count]
  where
    pick (chosen, rng) _ = let (word, rng') = nextWord rng
      in (chosen ++ [values !! fromIntegral (word `mod` fromIntegral (length values))], rng')

initialPRNG :: PRNGState
initialPRNG = PRNGState 0x243f6a8885a308d3 0x13198a2e03707344 0xa4093822299f31d0 0x082efa98ec4e6c89

nextWord :: PRNGState -> (Word64, PRNGState)
nextWord (PRNGState s0 s1 s2 s3) = (rotateL (s1 * 5) 7 * 9, PRNGState a b c d)
  where
    t = s1 `shiftL` 17
    a = s0 `xor` s3 `xor` (s1 `xor` s2)
    b = s1 `xor` s2
    c = s2 `xor` s0 `xor` t
    d = rotateL (s3 `xor` s1) 45

argmax :: [Float] -> Int
argmax [] = error "empty logits"
argmax (first : remaining) = fst (foldl' choose (0, first) (zip [1 ..] remaining))
  where choose best@(_, x) candidate@(_, y) = if y > x then candidate else best

takeEnd :: Int -> [a] -> [a]
takeEnd n values = drop (max 0 (length values - n)) values

parsePositive :: String -> String -> IO Int
parsePositive label value = case readMaybe value of
  Just n | n > 0 -> pure n
  _ -> die (label ++ " must be a positive integer")

parseNonnegative :: String -> String -> IO Int
parseNonnegative label value = case readMaybe value of
  Just n | n >= 0 -> pure n
  _ -> die (label ++ " must be a nonnegative integer")

positiveEnv :: String -> Int -> IO Int
positiveEnv name fallback = do
  value <- lookupEnv name
  case value of
    Nothing -> pure fallback
    Just text -> case readMaybe text of
      Just n | n > 0 -> pure n
      _ -> die (name ++ " must be a positive integer")
