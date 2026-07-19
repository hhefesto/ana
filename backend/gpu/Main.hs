module Main (main) where

import Control.Exception (bracket)
import Control.Monad (foldM, unless, when)
import Control.Parallel.Strategies (parListChunk, rdeepseq, using)
import qualified Data.ByteString as BS
import Data.Bits (rotateL, shiftL, shiftR, xor)
import Data.Int (Int64)
import Data.List (foldl', sortOn)
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Data.Word (Word64)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Vector as V
import FormalTransformer.Artifact
import FormalTransformer.Bigram
import FormalTransformer.Config
import FormalTransformer.Data
import FormalTransformer.Layout
import FormalTransformer.Optimizer
import FormalTransformer.Tokenizer
import FutharkKernels
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv, setEnv)
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hFlush, hPutStrLn, hSetBuffering, stderr, stdout)
import Text.Printf (printf)
import Text.Read (readMaybe)

modelId :: Config -> String
modelId cfg = "formal-transformer-futhark-hybrid-gla-v2:" ++ show cfg

optimizerFor :: Int -> AdamWConfig
optimizerFor steps = AdamWConfig 3e-4 0.9 0.999 1e-8 0.01 (min 100 steps) steps

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  setEnv "TZ" "America/Mexico_City"
  args <- getArgs
  case args of
    ["inspect"] -> inspect tinyPreset
    ["inspect", size] -> chooseConfig size >>= inspect
    ["warm-context"] -> warmContext tinyPreset
    ["warm-context", size] -> chooseConfig size >>= warmContext
    ["train", corpus, checkpoint, stepsText] -> do
      spec <- parseTarget stepsText
      train corpus checkpoint (Standalone spec) tinyPreset
    ["train", corpus, checkpoint, stepsText, size] -> do
      spec <- parseTarget stepsText
      cfg <- chooseConfig size
      train corpus checkpoint (Standalone spec) cfg
    ["train-segment", corpus, checkpoint, totalText, startText, endText,
      offsetText, globalIdentity, expectedCorpusIdentity, size] -> do
      total <- parsePositive "GLOBAL_TOTAL_STEPS" totalText
      start <- parseNonnegative "SEGMENT_START_STEP" startText
      end <- parsePositive "SEGMENT_END_STEP" endText
      offset <- parseWord64 "DOCUMENT_OFFSET" offsetText
      cfg <- chooseConfig size
      train corpus checkpoint
        (Segment total start end offset globalIdentity expectedCorpusIdentity) cfg
    ["generate", checkpoint, text] -> generate checkpoint text 128
    ["generate", checkpoint, text, budgetText] -> parseNonnegative "MAXTOKENS" budgetText >>= generate checkpoint text
    ["check-checkpoint", checkpoint] -> checkCheckpoint checkpoint
    _ -> die "usage: formal-transformer-gpu inspect [tiny|small|bpe10m|gla-small|gla] | warm-context [tiny|small|bpe10m|gla-small|gla] | train CORPUS CHECKPOINT (STEPS|epoch) [tiny|small|bpe10m|gla-small|gla] | train-segment CORPUS CHECKPOINT GLOBAL_TOTAL START END DOCUMENT_OFFSET GLOBAL_ID EXPECTED_CORPUS_ID SIZE | generate CHECKPOINT TEXT [MAXTOKENS] | check-checkpoint CHECKPOINT"

chooseConfig :: String -> IO Config
chooseConfig "tiny" = pure tinyPreset
chooseConfig "small" = pure smallPreset
chooseConfig "small4" = pure small4Preset
chooseConfig "bpe10m" = pure bpe10mPreset
chooseConfig "gla-small" = pure glaSmallPreset
chooseConfig "gla" = pure glaPreset
chooseConfig value = die ("unknown model size: " ++ value ++ " (expected tiny, small, bpe10m, gla-small, or gla)")

inspect :: Config -> IO ()
inspect cfg = either die (mapM_ print) (namedLayout cfg) >> do
  putStrLn ("config: " ++ show cfg)
  putStrLn ("parameters: " ++ show (paramCount cfg))

-- Force backend context creation without loading data or taking an optimizer
-- step.  GPU backends compile and cache their generated program here, so a
-- subsequent gate can measure execution independently of cold NVRTC/OpenCL
-- compilation.
warmContext :: Config -> IO ()
warmContext cfg = do
  gpu <- gpuConfigIO cfg >>= either die pure
  withContext $ \ctx -> do
    count <- futharkParameterCount ctx gpu
    when (count /= fromIntegral (paramCount cfg)) $
      die "Futhark parameter count disagrees with the host configuration"
    putStrLn ("context ready: " ++ show cfg ++ " (" ++ show count ++ " parameters)")

-- A target is either an explicit completed-step count or "epoch": enough
-- steps that every training window has been consumed at least once.
data TargetSpec = ExplicitSteps Int | EpochSteps

data TrainingMode
  = Standalone TargetSpec
  | Segment Int Int Int Word64 String String

data TrainingProgress = TrainingProgress
  { progressTrainLossEma :: !(Maybe Float)
  , progressPreviousValidationLoss :: !(Maybe Float)
  , progressBestValidationLoss :: !(Maybe Double)
  }

parseTarget :: String -> IO TargetSpec
parseTarget "epoch" = pure EpochSteps
parseTarget value = ExplicitSteps <$> parsePositive "STEPS" value

train :: FilePath -> FilePath -> TrainingMode -> Config -> IO ()
train corpusPath checkpointPath mode cfg = do
  batchSize <- positiveEnv "TRAIN_BATCH" 1
  microSize <- positiveEnv "MICRO_BATCH" batchSize
  when (microSize > batchSize) (die "MICRO_BATCH must not exceed TRAIN_BATCH")
  checkpointEvery <- positiveEnv "CHECKPOINT_EVERY" 500
  validateEvery <- positiveEnv "VALIDATE_EVERY" 500
  validationWindows <- positiveEnv "VALIDATION_WINDOWS" 256
  clipNorm <- positiveDoubleEnv "GRAD_CLIP" 1
  corpus <- loadCorpus corpusPath >>= either die pure
  corpusVocab <- maybe (die "corpus has an unsupported tokenizer identity") pure
    (tokenizerVocabularyFromIdentity (corpusTokenizerIdentity corpus))
  when (corpusVocab /= vocabSize cfg) (die
    ("corpus tokenizer vocabulary " ++ show corpusVocab
      ++ " does not match model vocabulary " ++ show (vocabSize cfg)))
  tokenizer <- tokenizerForIdentity (corpusTokenizerIdentity corpus)
  let documentOffset = case mode of
        Standalone _ -> 0
        Segment _ _ _ offset _ _ -> offset
  case mode of
    Standalone _ -> pure ()
    Segment _ _ _ _ _ expected -> when (corpusDatasetIdentity corpus /= expected)
      (die "segment corpus identity does not match the run plan")
  fullSplit <- either die pure (trainingSequencesFrom documentOffset cfg (corpusDocuments corpus))
  -- The validation comparison set is the first VALIDATION_WINDOWS windows;
  -- the same sample feeds the loss, the bits-per-byte scale, and the
  -- bigram gate, so all three observe the same denotation.
  let split = fullSplit { validation = take validationWindows (validation fullSplit) }
  bpbScale <- if null (validation split)
    then pure Nothing
    else Just <$> either die pure (bitsPerByteScale tokenizer (validation split))
  skipBigramGate <- (== Just "1") <$> lookupEnv "SKIP_BIGRAM_GATE"
  gate <- if null (validation split) || skipBigramGate
    then pure Nothing
    else either die (pure . Just) (bigramGateFrom validationWindows documentOffset cfg (corpusDocuments corpus))
  let windowCount = length (training split)
      epochSteps = (windowCount + batchSize - 1) `div` batchSize
  (target, scheduleTotal, segmentStart, sampler, runDatasetIdentity) <- case mode of
    Standalone spec -> case spec of
      ExplicitSteps n -> pure
        (n, n, 0, randomSampler batchSize (training split), corpusDatasetIdentity corpus)
      EpochSteps -> pure
        (epochSteps, epochSteps, 0, epochSampler batchSize (training split), corpusDatasetIdentity corpus)
    Segment total start end _ globalIdentity _ -> do
      when (start < 0 || start >= end || end > total)
        (die "segment requires 0 <= START < END <= GLOBAL_TOTAL_STEPS")
      when (end - start /= epochSteps) (die
        ("segment plan step count differs from corpus: planned " ++ show (end - start)
          ++ ", corpus requires " ++ show epochSteps))
      pure (end, total, start,
        segmentSampler start (epochSampler batchSize (training split)), globalIdentity)
  case mode of
    Standalone (ExplicitSteps _) -> pure ()
    _ -> logTraining ("epoch segment: " ++ show windowCount
      ++ " training windows / batch " ++ show batchSize
      ++ " = " ++ show epochSteps ++ " steps, global "
      ++ show segmentStart ++ ".." ++ show target ++ "/" ++ show scheduleTotal)
  let identity = Identity (modelId cfg) (corpusTokenizerIdentity corpus) runDatasetIdentity
      optCfg = optimizerFor scheduleTotal
  existing <- doesFileExist checkpointPath
  checkpoint <- if existing
    then loadCheckpoint checkpointPath >>= either die (validateResume cfg identity optCfg clipNorm)
    else do
      when (segmentStart /= 0) (die "cannot begin a nonzero segment without the global checkpoint")
      fresh <- pure (newCheckpoint cfg identity optCfg clipNorm)
      initFrom <- lookupEnv "TRAIN_INIT"
      case initFrom of
        Nothing -> pure fresh
        Just source -> do
          -- Warm start: copy only the parameters of a compatible previous
          -- run into a NEW run; identity, schedule, optimizer moments,
          -- step, and PRNG are all fresh.
          previous <- loadCheckpoint source >>= either die pure
          let previousManifest = checkpointManifest previous
              previousIdentity = manifestIdentity previousManifest
          when (manifestConfig previousManifest /= cfg)
            (die ("TRAIN_INIT checkpoint has a different model configuration: " ++ source))
          when (modelIdentity previousIdentity /= modelId cfg
            || tokenizerIdentity previousIdentity /= corpusTokenizerIdentity corpus)
            (die ("TRAIN_INIT checkpoint has a different model or tokenizer identity: " ++ source))
          logTraining ("warm start: parameters initialized from " ++ source
            ++ " (completed step " ++ show (adamStep (checkpointOptimizer previous)) ++ ")")
          pure fresh { checkpointParameters = checkpointParameters previous }
  when (adamStep (checkpointOptimizer checkpoint) < segmentStart)
    (die "checkpoint is behind this segment's start step")
  when (adamStep (checkpointOptimizer checkpoint) > target)
    (die "checkpoint has already passed this segment's target step")
  gpuCfg <- gpuConfigIO cfg >>= either die pure
  mask <- either die pure (decayMask cfg)
  let params0 = map realToFrac (checkpointParameters checkpoint)
      state0 = checkpointOptimizer checkpoint
      n = paramCount cfg
  logTraining ("training config=" ++ show cfg
    ++ " target=" ++ show target
    ++ " schedule_total=" ++ show scheduleTotal
    ++ " completed=" ++ show (adamStep state0)
    ++ " batch=" ++ show batchSize
    ++ " micro=" ++ show microSize
    ++ " grad_clip=" ++ show clipNorm
    ++ " checkpoint_every=" ++ show checkpointEvery
    ++ " validate_every=" ++ show validateEvery
    ++ " validation_windows=" ++ show (length (validation split)))
  case gate of
    Nothing -> pure ()
    Just g -> logTraining ("bigram gate: sample=" ++ show (gateSampleCrossEntropy g)
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
            logTraining ("checkpoint step=" ++ show step ++ " path=" ++ checkpointPath)
      let resumedBest = checkpointBestValidationLoss checkpoint
          segmentBest = case mode of
            Segment _ start _ _ _ _ | adamStep state0 == start -> Nothing
            _ -> resumedBest
          progress0 = TrainingProgress Nothing Nothing segmentBest
      (paramsFinal, mFinal, vFinal, rngFinal, progressFinal) <-
        loop ctx gpuCfg n optCfg split sampler target (adamStep state0) microSize checkpointEvery
          validateEvery clipNorm bpbScale
          (gateSampleCrossEntropy <$> gate)
          saveSnapshot params m v deviceMask (checkpointPRNG checkpoint)
          progress0
      saveSnapshot target rngFinal (progressBestValidationLoss progressFinal) paramsFinal mFinal vFinal
      logTraining ("saved checkpoint at completed step " ++ show target ++ ": " ++ checkpointPath)
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
      batch = [permuted V.! ((start + i) `mod` count) | i <- [0 .. batchSize - 1]]
  in (batch, rng)
  where
    count = V.length permuted
    permuted = V.fromList (map snd (sortOn fst (zipWith tag [0 ..] windows)))
    tag index window = (hashIndex index, window)
    hashIndex :: Word64 -> Word64
    hashIndex x0 = x3 `xor` (x3 `shiftR` 31)
      where
        x1 = (x0 + 0x45504f4348) `xor` ((x0 + 0x45504f4348) `shiftR` 30)
        x2 = x1 * 0xbf58476d1ce4e5b9
        x3 = (x2 `xor` (x2 `shiftR` 27)) * 0x94d049bb133111eb

segmentSampler :: Int -> Sampler -> Sampler
segmentSampler segmentStart sampler globalStep = sampler (globalStep - segmentStart)

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
  -> Int
  -> Float
  -> Maybe Double
  -> Maybe Double
  -> (Int -> PRNGState -> Maybe Double -> F32Array -> F32Array -> F32Array -> IO ())
  -> F32Array
  -> F32Array
  -> F32Array
  -> BoolArray
  -> PRNGState
  -> TrainingProgress
  -> IO (F32Array, F32Array, F32Array, PRNGState, TrainingProgress)
loop ctx gpuCfg n optCfg split sampler target completed microSize checkpointEvery validateEvery clipNorm bpbScale gate saveSnapshot params m v mask rng progress
  | completed >= target = pure (params, m, v, rng, progress)
  | otherwise = do
      let step = completed + 1
          (batch, rng') = sampler step rng
          lr = realToFrac (learningRate optCfg step)
      when (null batch) (die "internal error: sampled an empty training batch")
      (loss, gradient) <- microLossGrad ctx gpuCfg n microSize batch params
      (gradientNorm, clipped) <- bracket (pure gradient) (freeF32 ctx) $ \g ->
        clipGlobalNorm ctx clipNorm g
      (params', m', v') <- bracket (pure clipped) (freeF32 ctx) $ \g ->
        adamwStep ctx (fromIntegral step) lr (f beta1) (f beta2) (f adamEpsilon) (f weightDecay) params g m v mask
      freeF32 ctx params
      freeF32 ctx m
      freeF32 ctx v
      let ema = case progressTrainLossEma progress of
            Nothing -> loss
            Just previous -> trainLossEmaDecay * previous + (1 - trainLossEmaDecay) * loss
          progressWithLoss = progress { progressTrainLossEma = Just ema }
      (progress', validationText) <- if null (validation split) || (step `mod` validateEvery /= 0 && step /= target)
        then pure (progressWithLoss, "")
        else do
          let val = validation split
          when (null val) (die "internal error: selected an empty validation batch")
          valLoss <- chunkedMeanLoss ctx gpuCfg microSize val params'
          let gateText = case gate of
                Nothing -> ""
                Just g -> " gate=" ++ show g
                  ++ (if realToFrac valLoss < g then " beats-gate" else " behind-gate")
              bpbText = maybe "" (\scale -> " bits_per_byte="
                ++ formatDouble (realToFrac valLoss * scale)) bpbScale
              valDouble = realToFrac valLoss
              previousBest = progressBestValidationLoss progressWithLoss
              best' = maybe valDouble (min valDouble) previousBest
              deltaText = maybe "na" (formatSignedFloat . (valLoss -))
                (progressPreviousValidationLoss progressWithLoss)
              newBest = maybe True (valDouble <) previousBest
              validation = " validation_loss=" ++ formatFloat valLoss
                ++ " validation_delta=" ++ deltaText
                ++ " best_validation_loss=" ++ formatFloat (realToFrac best')
                ++ " new_best=" ++ boolText newBest
                ++ bpbText ++ gateText
          pure (progressWithLoss
            { progressPreviousValidationLoss = Just valLoss
            , progressBestValidationLoss = Just best'
            }, validation)
      logTraining ("step=" ++ show step ++ "/" ++ show (totalSteps optCfg)
        ++ " progress=" ++ printf "%.3f%%" (100 * fromIntegral step / fromIntegral (totalSteps optCfg) :: Double)
        ++ " lr=" ++ formatFloat lr
        ++ " train_loss=" ++ formatFloat loss
        ++ " train_loss_ema=" ++ formatFloat ema
        ++ " gradient_norm=" ++ formatFloat gradientNorm
        ++ " clipped=" ++ boolText (gradientNorm > clipNorm)
        ++ validationText)
      when (step `mod` checkpointEvery == 0 && step /= target) $
        saveSnapshot step rng' (progressBestValidationLoss progress') params' m' v'
      loop ctx gpuCfg n optCfg split sampler target step microSize checkpointEvery validateEvery clipNorm bpbScale gate saveSnapshot
        params' m' v' mask rng' progress'
  where f field = realToFrac (field optCfg)

logTraining :: String -> IO ()
logTraining message = do
  timestamp <- formatTime defaultTimeLocale "%Y-%m-%d %H:%M %Z" <$> getZonedTime
  putStrLn ("[" ++ timestamp ++ "] " ++ message)

formatFloat :: Float -> String
formatFloat = printf "%.7g"

formatDouble :: Double -> String
formatDouble = printf "%.7g"

formatSignedFloat :: Float -> String
formatSignedFloat = printf "%+.7g"

trainLossEmaDecay :: Float
trainLossEmaDecay = 0.98

boolText :: Bool -> String
boolText True = "true"
boolText False = "false"

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

bitsPerByteScale :: Tokenizer -> [[Int64]] -> Either String Double
bitsPerByteScale tokenizer windows = do
  let targets = concatMap (drop 1) windows
      ordinary = [fromIntegral token | token <- targets, token >= 2]
      predictionCount = length targets
  byteChunks <- mapM (decodeWith tokenizer . pure) ordinary
  let byteCount = sum (map BS.length byteChunks)
  when (predictionCount == 0 || byteCount == 0)
    (Left "validation sample has no ordinary target bytes")
  pure (fromIntegral predictionCount / (fromIntegral byteCount * log 2))

trainingSequencesFrom :: Word64 -> Config -> [Document] -> Either String (Split [Int64])
trainingSequencesFrom offset cfg documents = do
  mapM_ validateDocument documents
  split <- trainerWindowSplitFrom offset (contextSize cfg) documents
  pure (Split (convert (training split)) (convert (validation split)))
  where
    -- A pure map forced in parallel chunks: the value is unchanged, only
    -- where and when it is evaluated.
    convert windows = map (map fromIntegral) windows `using` parListChunk 4096 rdeepseq
    validateDocument document = when
      (any (\token -> token < 2 || token >= vocabSize cfg) (documentTokens document))
      (Left ("document " ++ documentId document ++ " contains a token outside model vocabulary"))

newCheckpoint :: Config -> Identity -> AdamWConfig -> Float -> Checkpoint
newCheckpoint cfg identity optCfg clipNorm = Checkpoint manifest params (initAdamW count) Nothing initialPRNG
  where
    count = paramCount cfg
    manifest = Manifest artifactVersion cfg count canonicalLayoutIdentity canonicalLayoutVersion optCfg identity (realToFrac clipNorm)
    params = either error (concatMap initialize) (namedLayout cfg)
    initialize slice
      | sliceDecay slice = [0.02 * sin (fromIntegral (sliceOffset slice + i + 1) * 12.9898) | i <- [0 .. sliceLength slice - 1]]
      | otherwise = replicate (sliceLength slice) 1

validateResume :: Config -> Identity -> AdamWConfig -> Float -> Checkpoint -> IO Checkpoint
validateResume cfg identity optCfg clipNorm checkpoint = do
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
  when (manifestClipNorm manifest /= realToFrac clipNorm) (die
    ("checkpoint gradient clip does not match this run\n"
      ++ "  checkpoint: " ++ show (manifestClipNorm manifest) ++ "\n"
      ++ "  this run:   " ++ show clipNorm ++ " (GRAD_CLIP)\n"
      ++ "  the clip is part of the training trajectory; resume with the"
      ++ " same GRAD_CLIP or start a new CHECKPOINT path"))
  when (manifestLayoutIdentity manifest /= canonicalLayoutIdentity || manifestLayoutVersion manifest /= canonicalLayoutVersion) (die "checkpoint layout identity mismatch")
  pure checkpoint

-- Silent compatibility probe for checkpoint discovery: exit 0 iff this
-- host's architecture (model identity + canonical layout) can interpret
-- the checkpoint.  Loads and validates the artifact only; no Futhark
-- context is created.  wiki-generate uses this to skip checkpoints written
-- by a different architecture instead of dying on the newest file.
checkCheckpoint :: FilePath -> IO ()
checkCheckpoint path = do
  checkpoint <- loadCheckpoint path >>= either die pure
  let manifest = checkpointManifest checkpoint
      cfg = manifestConfig manifest
      identity = manifestIdentity manifest
  when (modelIdentity identity /= modelId cfg)
    (die "checkpoint model identity is not supported by this host")
  when (manifestLayoutIdentity manifest /= canonicalLayoutIdentity
        || manifestLayoutVersion manifest /= canonicalLayoutVersion)
    (die "checkpoint layout identity is not supported by this host")
  putStrLn ("compatible: " ++ path)

generate :: FilePath -> String -> Int -> IO ()
generate checkpointPath text budget = do
  checkpoint <- loadCheckpoint checkpointPath >>= either die pure
  let manifest = checkpointManifest checkpoint
      cfg = manifestConfig manifest
      identity = manifestIdentity manifest
  when (modelIdentity identity /= modelId cfg) (die "checkpoint model identity is not supported by this GPU host")
  tokenizer <- tokenizerForIdentity (tokenizerIdentity identity)
  when (tokenizerVocabSize tokenizer /= vocabSize cfg)
    (die "checkpoint tokenizer vocabulary does not match its model configuration")
  gpuCfg <- gpuConfigIO cfg >>= either die pure
  temperature <- nonnegativeDoubleEnv "TEMPERATURE" 0.8
  topK <- positiveEnv "TOP_K" 40
  seedText <- lookupEnv "SAMPLE_SEED"
  rng <- case seedText of
    Nothing -> pure (checkpointPRNG checkpoint)
    Just value -> seededPRNG <$> parseWord64 "SAMPLE_SEED" value
  hPutStrLn stderr ("generate: temperature=" ++ show temperature
    ++ " top_k=" ++ show topK
    ++ " seed=" ++ maybe "checkpoint-prng" id seedText)
  let promptBytes = Text.encodeUtf8 (Text.pack text)
      prompt = bosToken : encodeWith tokenizer promptBytes
      n = paramCount cfg
      completed = adamStep (checkpointOptimizer checkpoint)
      scheduled = totalSteps (manifestOptimizerConfig manifest)
      progress = 100 * fromIntegral completed / fromIntegral scheduled :: Double
      emit token = do
        bytes <- either die pure (decodeWith tokenizer [token])
        BS.putStr bytes
        hFlush stdout
  printf "=== Wikipedia corpus training: %.3f%% complete (%d/%d updates) ===\n"
    progress completed scheduled
  BS.putStr promptBytes
  hFlush stdout
  _ <- withContext $ \ctx -> withF32 ctx (map realToFrac (checkpointParameters checkpoint)) $ \params ->
    generateLoop ctx gpuCfg cfg params (pickToken temperature topK) emit budget rng prompt []
  putStrLn ""

tokenizerForIdentity :: String -> IO Tokenizer
tokenizerForIdentity identity
  | identity == byteTokenizerIdentity = pure ByteTokenizer
  | otherwise = do
      path <- lookupEnv "TOKENIZER_FILE" >>= maybe
        (die "checkpoint uses BPE; set TOKENIZER_FILE to its .bpe artifact") pure
      bpe <- loadFastBpe path >>= either die pure
      let tokenizer = FastBpeTokenizer bpe
      when (tokenizerIdentityOf tokenizer /= identity)
        (die "TOKENIZER_FILE identity does not match the checkpoint")
      pure tokenizer

-- Incremental decoding: the proved cache-run law executed.  Each prompt or
-- sampled token is fed through decode_step exactly once; GLA layers carry a
-- fixed dk x dv state per head that is never reset (the StateAlgebra run),
-- and the NoPE softmax layers attend over a ring buffer of the trailing
-- context window.  Within the first window this observes the same language
-- as full recomputation (recurrent≡parallel plus causality); per-token cost
-- is O(model) instead of O(window * model).
generateLoop
  :: Context -> GpuConfig -> Config -> F32Array
  -> ([Float] -> PRNGState -> (Int, PRNGState))
  -> (Int -> IO ()) -> Int -> PRNGState -> [Int] -> [Int] -> IO [Int]
generateLoop ctx gpuCfg cfg params pick emit budget rng prompt _ = do
  let d = modelDim cfg
      hd = headDim cfg
      glaStateLength = glaLayerCount cfg * d * hd
      cacheLength = (layerCount cfg `div` 4) * contextSize cfg * d
      step (gla, kc, vc) position token = do
        (logitsArr, gla', kc', vc') <- decodeStep ctx gpuCfg
          (fromIntegral (contextSize cfg)) (fromIntegral position)
          (fromIntegral token) params gla kc vc
        values <- downloadF32 ctx (vocabSize cfg) logitsArr
        freeF32 ctx logitsArr
        pure (values, (gla', kc', vc'))
  gla0 <- zeroVector ctx glaStateLength
  k0 <- zeroVector ctx cacheLength
  v0 <- zeroVector ctx cacheLength
  (promptLogits, primed) <- foldM
    (\(_, states) (position, token) -> step states position token)
    ([], (gla0, k0, v0))
    (zip [0 ..] prompt)
  let go remaining rng' position states logits output
        | remaining <= (0 :: Int) = pure output
        | otherwise = do
            let (token, rng'') = pick logits rng'
            if token == eosToken then pure output
            else do
              unless (token == bosToken) (emit token)
              (logits', states') <- step states position token
              go (remaining - 1) rng'' (position + 1) states' logits'
                 (if token == bosToken then output else output ++ [token])
  go budget rng (length prompt) primed promptLogits []

-- Observation of the model's next-token distribution.  TEMPERATURE=0 is
-- the degenerate greedy observation (the exact argmax path); otherwise the
-- top-K logits are softmaxed at the given temperature and sampled by
-- inverse CDF.  The denotation being observed is unchanged either way.
pickToken :: Float -> Int -> [Float] -> PRNGState -> (Int, PRNGState)
pickToken temperature topK logits rng
  | temperature <= 0 = (argmax logits, rng)
  | otherwise = (select (unitInterval word * total) weights, rng')
  where
    top = take topK (sortOn (negate . snd) (zip [0 ..] logits))
    peak = maximum (map snd top)
    weights =
      [ (index, exp (realToFrac ((logit - peak) / temperature) :: Double))
      | (index, logit) <- top ]
    total = sum (map snd weights)
    (word, rng') = nextWord rng
    select _ [] = argmax logits
    select remaining ((index, weight) : rest)
      | remaining < weight || null rest = index
      | otherwise = select (remaining - weight) rest

-- The high 53 bits of a PRNG word as a Double in [0, 1).
unitInterval :: Word64 -> Double
unitInterval word = fromIntegral (word `shiftR` 11) / 9007199254740992

-- SplitMix64 expansion of one seed word into a full xoshiro256** state:
-- the generator authors' recommended seeding procedure.
seededPRNG :: Word64 -> PRNGState
seededPRNG seed = PRNGState a b c d
  where
    (a, s1) = splitmix seed
    (b, s2) = splitmix s1
    (c, s3) = splitmix s2
    (d, _) = splitmix s3
    splitmix s = (z2 `xor` (z2 `shiftR` 31), s')
      where
        s' = s + 0x9e3779b97f4a7c15
        z1 = (s' `xor` (s' `shiftR` 30)) * 0xbf58476d1ce4e5b9
        z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb

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

parseWord64 :: String -> String -> IO Word64
parseWord64 label value = case readMaybe value of
  Just number -> pure number
  Nothing -> die (label ++ " must be a nonnegative 64-bit integer")

positiveEnv :: String -> Int -> IO Int
positiveEnv name fallback = do
  value <- lookupEnv name
  case value of
    Nothing -> pure fallback
    Just text -> case readMaybe text of
      Just n | n > 0 -> pure n
      _ -> die (name ++ " must be a positive integer")

positiveDoubleEnv :: String -> Double -> IO Float
positiveDoubleEnv name fallback = do
  value <- lookupEnv name
  case value of
    Nothing -> pure (realToFrac fallback)
    Just text -> case readMaybe text of
      Just number | number > 0 -> pure number
      _ -> die (name ++ " must be a positive number")

nonnegativeDoubleEnv :: String -> Double -> IO Float
nonnegativeDoubleEnv name fallback = do
  value <- lookupEnv name
  case value of
    Nothing -> pure (realToFrac fallback)
    Just text -> case readMaybe text of
      Just number | number >= 0 -> pure number
      _ -> die (name ++ " must be a nonnegative number")
