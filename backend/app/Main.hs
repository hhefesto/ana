module Main (main) where

import Control.Monad (filterM, foldM, when)
import Control.Parallel.Strategies (parListChunk, rseq, using)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word64)
import System.Directory (doesFileExist)
import FormalTransformer.AD
import FormalTransformer.Artifact
import FormalTransformer.Bigram
import FormalTransformer.Config
import FormalTransformer.Data
import FormalTransformer.Layout
import FormalTransformer.Model
import FormalTransformer.Optimizer
import FormalTransformer.Tokenizer
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr, stdin)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["inspect"] -> inspect
    ["logits", tokenText] -> case parseTokens tokenText of
      Nothing -> putStrLn "tokens must be comma-separated integers"
      Just tokens -> printResult (fullSequenceLogits tinyConfig initialParameters tokens)
    ["gradcheck"] -> gradcheck
    ["train-smoke"] -> trainSmoke
    ("prepare-bytes" : output : inputs@(_ : _)) -> prepareBytes output inputs
    ["prepare-stdin", output] -> prepareStdin output
    ("prepare-bpe" : tokenizerPath : output : inputs@(_ : _)) ->
      withFastBpe tokenizerPath (\tokenizer -> prepareFiles tokenizer output inputs)
    ["prepare-bpe-stdin", tokenizerPath, output] ->
      withFastBpe tokenizerPath (\tokenizer -> prepareStdinWith tokenizer output)
    ["inspect-corpus", path] -> inspectCorpus path
    ["inspect-checkpoint", path] -> inspectCheckpoint path
    ["compact-checkpoint", input, output] -> compactCheckpoint input output
    ["compare-checkpoint", left, right] -> compareCheckpoint left right
    ["plan-segment", path, offsetText, batchText, size] ->
      planSegment path offsetText batchText size
    ["build-eval", output, planPath, runDir, perShardText, strideText] ->
      buildEval output planPath runDir perShardText strideText
    ["learn-bpe", output, vocabText] -> learnBpe output vocabText "2"
    ["learn-bpe", output, vocabText, minText] -> learnBpe output vocabText minText
    ["bigram-gate", path] -> bigramGateCommand path tinyPreset
    ["bigram-gate", path, "tiny"] -> bigramGateCommand path tinyPreset
    ["bigram-gate", path, "small"] -> bigramGateCommand path smallPreset
    ["bigram-gate", path, "bpe10m"] -> bigramGateCommand path bpe10mPreset
    ["bigram-gate", path, "bpe100m"] -> bigramGateCommand path bpe100mPreset
    _ -> putStrLn "usage: formal-transformer (inspect | logits TOKENS | gradcheck | train-smoke | prepare-bytes OUTPUT INPUT... | prepare-stdin OUTPUT | prepare-bpe TOKENIZER OUTPUT INPUT... | prepare-bpe-stdin TOKENIZER OUTPUT | inspect-corpus PATH | inspect-checkpoint PATH | compact-checkpoint INPUT OUTPUT | compare-checkpoint LEFT RIGHT | plan-segment CORPUS DOCUMENT_OFFSET TRAIN_BATCH SIZE | build-eval OUTPUT PLAN RUN_DIR DOCS_PER_SHARD STRIDE | learn-bpe OUTPUT VOCABULARY [MIN_FREQUENCY] | bigram-gate CORPUS [tiny|small|bpe10m|bpe100m])"

tinyConfig :: Config
tinyConfig = Config 5 6 4 6 2 2

initialParameters :: [Double]
initialParameters = case namedLayout tinyConfig of
  Left message -> error message
  Right layout -> concatMap values layout
  where
    values slice
      | not (sliceDecay slice) = replicate (sliceLength slice) 1
      | otherwise = [0.03 * sin (fromIntegral (sliceOffset slice + i + 1)) | i <- [0 .. sliceLength slice - 1]]

inspect :: IO ()
inspect = case namedLayout tinyConfig of
  Left message -> putStrLn message
  Right layout -> do
    putStrLn ("config: " ++ show tinyConfig)
    putStrLn ("parameters: " ++ show (paramCount tinyConfig))
    mapM_ print layout

gradcheck :: IO ()
gradcheck = case lossGradient tinyConfig initialParameters [0, 2, 3] 1 of
  Left message -> putStrLn message
  Right analytical -> do
    let indices = [0, paramCount tinyConfig `div` 2, paramCount tinyConfig - 1]
        comparisons = [(i, analytical !! i, finiteDifference i) | i <- indices]
    mapM_ print comparisons
    putStrLn (if all (\(_, a, n) -> abs (a - n) < 1e-5) comparisons then "gradient check passed" else "gradient check failed")
  where
    epsilon = 1e-6
    finiteDifference i =
      let plus = adjust i epsilon initialParameters
          minus = adjust i (-epsilon) initialParameters
          loss p = either error id (nextTokenCE tinyConfig p [0, 2, 3] 1)
      in (loss plus - loss minus) / (2 * epsilon)

trainSmoke :: IO ()
trainSmoke = do
  let cfg = AdamWConfig 1e-3 0.9 0.999 1e-8 0.01 2 8
      examples = [([0, 2], 3), ([0, 3], 4), ([0, 4], 1)]
      state = initAdamW (paramCount tinyConfig)
  case decayMask tinyConfig of
    Left message -> putStrLn message
    Right mask -> case foldM (step cfg mask) (VU.fromList initialParameters, state) (take 8 (cycle examples)) of
      Left message -> putStrLn message
      Right (params, finalState) -> do
        putStrLn ("completed steps: " ++ show (adamStep finalState))
        case nextTokenCE tinyConfig (VU.toList params) [0, 2] 3 of
          Left message -> putStrLn message
          Right loss -> do
            print loss
            let identity = Identity "smoke-model" "synthetic-token-v1" "synthetic-documents-v1"
                manifest = Manifest artifactVersion tinyConfig (paramCount tinyConfig)
                  canonicalLayoutIdentity canonicalLayoutVersion cfg identity 1 Fp32IEEE
                checkpoint = Checkpoint manifest params finalState (Just loss) (PRNGState 1 2 3 4)
            case validateCheckpoint checkpoint of
              Left message -> putStrLn message
              Right _ -> putStrLn "checkpoint contract valid"
  where
    step cfg mask (params, state) (prefix, target) = do
      gradient <- lossGradient tinyConfig (VU.toList params) prefix target
      adamWStep cfg mask state params (VU.fromList gradient)

prepareBytes :: FilePath -> [FilePath] -> IO ()
prepareBytes = prepareFiles ByteTokenizer

prepareFiles :: Tokenizer -> FilePath -> [FilePath] -> IO ()
prepareFiles tokenizer output paths = do
  missing <- filterM (fmap not . doesFileExist) paths
  case missing of
    (_ : _) -> putStrLn ("prepare-bytes: input file(s) not found: " ++ unwords missing
      ++ "\n  every INPUT must be an existing text file; the corpus is written to " ++ output)
    [] -> do
      contents <- mapM BS.readFile paths
      writeSources tokenizer output (zip paths contents)

-- Reads NUL-delimited (identifier, text) pairs from stdin and writes one
-- corpus artifact with one document per pair.  Intended producer:
--   jq -j '.id, "\u0000", .text, "\u0000"' articles.jsonl | \
--     formal-transformer prepare-stdin shard.corpus
prepareStdin :: FilePath -> IO ()
prepareStdin = prepareStdinWith ByteTokenizer

prepareStdinWith :: Tokenizer -> FilePath -> IO ()
prepareStdinWith tokenizer output = do
  result <- readNulDocuments
  case result of
    Left message -> putStrLn ("prepare-stdin: " ++ message)
    Right [] -> putStrLn "prepare-stdin: no documents on stdin (expected NUL-delimited id/text pairs)"
    Right sources -> writeDocuments tokenizer output (encodeDocuments tokenizer sources)

-- Tokenizing a corpus is per-document work with no cross-document dependency,
-- and measurement says it is dominated by allocating each document's token
-- list rather than by the BPE merges themselves.  Both facts point the same
-- way: encode the documents in parallel chunks.  `sum` forces each token list
-- to normal form inside its spark, so the work actually happens on the worker
-- rather than being deferred to the serializer on the main thread.
--
-- The result is order-preserving and therefore byte-identical to the serial
-- encoding, which the shard-0 regression in the run document checks exactly.
encodeDocuments :: Tokenizer -> [(String, BS.ByteString)] -> [Document]
encodeDocuments tokenizer sources =
  map encodeOne sources `using` parListChunk 32 rseq
  where
    encodeOne (name, bytes) =
      let tokens = encodeWith tokenizer bytes
      in sum tokens `seq` Document name tokens

-- Reads NUL-delimited (identifier, text) pairs, returning them unencoded so
-- the caller can tokenize the batch in parallel.
readNulDocuments :: IO (Either String [(String, BS.ByteString)])
readNulDocuments = readMore BS.empty Nothing []
  where
    readMore pending identifier sources = do
      chunk <- BS.hGetSome stdin 65536
      if BS.null chunk
        then if BS.null pending && maybe True (const False) identifier
          then pure (Right (reverse sources))
          else pure (Left "incomplete final NUL-delimited id/text pair")
        else consume (pending <> chunk) identifier sources

    consume bytes identifier sources = case BS.elemIndex 0 bytes of
      Nothing -> readMore bytes identifier sources
      Just index ->
        let field = BS.take index bytes
            remaining = BS.drop (index + 1) bytes
        in case identifier of
          Nothing
            | BS.null field -> pure (Left "document id must not be empty")
            | otherwise -> consume remaining (Just field) sources
          Just documentIdBytes ->
            let source = ("curid-" ++ BSC.unpack documentIdBytes, field)
            in consume remaining Nothing (source : sources)

-- Train a BPE tokenizer from the same NUL-delimited id/text stream that
-- prepare-bpe-stdin consumes, so one corpus pipeline feeds both.
--
-- The corpus is streamed and never retained: BPE learns from the word-frequency
-- table, so only distinct words need to be in memory. That is what makes
-- training on a corpus far larger than RAM practical, and it is why the cost is
-- set by vocabulary size rather than by corpus size.
learnBpe :: FilePath -> String -> String -> IO ()
learnBpe output vocabText minText = case (readMaybe vocabText, readMaybe minText) of
  (Nothing, _) -> putStrLn "learn-bpe: VOCABULARY must be an integer"
  (_, Nothing) -> putStrLn "learn-bpe: MIN_FREQUENCY must be an integer"
  (Just vocab, Just minFrequency) -> do
    counted <- streamWordCounts
    case counted of
      Left message -> putStrLn ("learn-bpe: " ++ message)
      Right counts -> do
        -- Web text has an enormous tail of words seen exactly once -- URLs,
        -- hashes, typos, digit strings.  They dominate the distinct-word count
        -- (and hence memory, which is per word type) while contributing weight
        -- 1 against merges whose weights run to millions, so they cannot change
        -- which merges are chosen.  Dropping them is what makes training on a
        -- mixed corpus fit in RAM at all: on a 370 MB Wikipedia+C4 sample the
        -- unfiltered table reached 15.6 GB resident and was still growing.
        let frequencies = Map.filter (>= minFrequency) counts
        putStrLn ("learn-bpe: " ++ show (Map.size counts) ++ " distinct words, "
          ++ show (sum (Map.elems counts)) ++ " occurrences")
        putStrLn ("learn-bpe: " ++ show (Map.size frequencies)
          ++ " kept at frequency >= " ++ show minFrequency
          ++ " (" ++ show (Map.size counts - Map.size frequencies) ++ " dropped)")
        case learnBpeMerges vocab frequencies of
          Left message -> putStrLn ("learn-bpe: " ++ message)
          Right merges -> do
            let achieved = byteVocabSize + length merges
            BS.writeFile output (renderBpeArtifact merges)
            putStrLn ("wrote tokenizer: " ++ output)
            putStrLn ("merges: " ++ show (length merges) ++ "  vocabulary: " ++ show achieved)
            when (achieved < vocab) (putStrLn
              ("learn-bpe: corpus exhausted its merges before reaching " ++ show vocab))

-- Folds word counts over the stream without holding any document.
streamWordCounts :: IO (Either String (Map.Map BS.ByteString Int))
streamWordCounts = readMore BS.empty False Map.empty
  where
    readMore pending isText acc = do
      chunk <- BS.hGetSome stdin 1048576
      if BS.null chunk
        then if BS.null pending
          then pure (Right acc)
          else pure (Left "incomplete final NUL-delimited id/text pair")
        else consume (pending <> chunk) isText acc

    -- Fields alternate id, text, id, text ...; only the text is counted.
    consume bytes isText acc = case BS.elemIndex 0 bytes of
      Nothing -> readMore bytes isText acc
      Just index ->
        let field = BS.take index bytes
            remaining = BS.drop (index + 1) bytes
            acc' = if isText then countWords acc field else acc
        in acc' `seq` consume remaining (not isText) acc'

writeSources :: Tokenizer -> FilePath -> [(String, BS.ByteString)] -> IO ()
writeSources tokenizer output sources = writeArtifact tokenizer output identity documents
  where
    identity = datasetFingerprint sources
    documents = encodeDocuments tokenizer sources

writeDocuments :: Tokenizer -> FilePath -> [Document] -> IO ()
writeDocuments tokenizer output documents =
  writeArtifact tokenizer output
    (datasetFingerprintDocuments (tokenizerIdentityOf tokenizer) documents) documents

writeArtifact :: Tokenizer -> FilePath -> String -> [Document] -> IO ()
writeArtifact tokenizer output datasetFingerprintValue documents = do
  let corpus = CorpusArtifact
        { corpusVersion = corpusArtifactVersion
        , corpusTokenizerIdentity = tokenizerIdentityOf tokenizer
        , corpusDatasetIdentity = datasetFingerprintValue
        , corpusDocuments = documents
        }
  result <- saveCorpusAtomic output corpus
  case result of
    Left message -> putStrLn message
    Right () -> do
      putStrLn ("wrote corpus: " ++ output)
      putStrLn ("documents: " ++ show (length documents))
      putStrLn ("dataset fingerprint: " ++ corpusDatasetIdentity corpus)

withFastBpe :: FilePath -> (Tokenizer -> IO ()) -> IO ()
withFastBpe path action = do
  result <- loadFastBpe path
  either putStrLn (action . FastBpeTokenizer) result

inspectCorpus :: FilePath -> IO ()
inspectCorpus path = do
  result <- loadCorpus path
  case result of
    Left message -> putStrLn message
    Right corpus -> do
      putStrLn ("version: " ++ show (corpusVersion corpus))
      putStrLn ("tokenizer: " ++ corpusTokenizerIdentity corpus)
      putStrLn ("vocabulary: " ++ maybe "unknown" show
        (tokenizerVocabularyFromIdentity (corpusTokenizerIdentity corpus)))
      putStrLn ("dataset fingerprint: " ++ corpusDatasetIdentity corpus)
      putStrLn ("documents: " ++ show (length (corpusDocuments corpus)))
      putStrLn ("ordinary tokens: " ++ show (sum (map (length . documentTokens) (corpusDocuments corpus))))

inspectCheckpoint :: FilePath -> IO ()
inspectCheckpoint path = do
  result <- loadCheckpoint path
  case result of
    Left message -> putStrLn message
    Right checkpoint -> do
      let manifest = checkpointManifest checkpoint
          identity = manifestIdentity manifest
      putStrLn ("artifact version: " ++ show (manifestVersion manifest))
      putStrLn ("config: " ++ show (manifestConfig manifest))
      putStrLn ("parameters: " ++ show (manifestParameterCount manifest))
      putStrLn ("completed step: " ++ show (adamStep (checkpointOptimizer checkpoint)))
      putStrLn ("total steps: " ++ show (totalSteps (manifestOptimizerConfig manifest)))
      putStrLn ("numerics: " ++ show (manifestNumerics manifest))
      putStrLn ("model: " ++ modelIdentity identity)
      putStrLn ("tokenizer: " ++ tokenizerIdentity identity)
      putStrLn ("dataset: " ++ datasetIdentity identity)
      putStrLn ("best validation loss: " ++ show (checkpointBestValidationLoss checkpoint))

-- Element-wise comparison of two checkpoints.  The conformance oracle relates
-- backends on a five-token toy model; this relates them on the real one, which
-- is what the CPU-vs-GPU step-1 check needs and what `check-checkpoint` (an
-- identity check on a single file) has never done.
--
-- The report is data, not a verdict: two backends summing f32 in different
-- orders are expected to differ in the last bits, and only the caller knows
-- what tolerance the comparison deserves.  Exit status is nonzero only when the
-- two files cannot be compared at all — unreadable, or different shapes.
--
-- The cosine of the two first-moment vectors is the number to read first.  At
-- step 1 from a fresh initialization m = (1-beta1)*g, so that cosine IS the
-- gradient cosine — the statistic that caught the piece_ce_bwd miscompile, and
-- the one an element-wise max-abs cannot report.
compareCheckpoint :: FilePath -> FilePath -> IO ()
compareCheckpoint leftPath rightPath = do
  leftResult <- loadCheckpoint leftPath
  rightResult <- loadCheckpoint rightPath
  case (leftResult, rightResult) of
    (Left message, _) -> failWith (leftPath ++ ": " ++ message)
    (_, Left message) -> failWith (rightPath ++ ": " ++ message)
    (Right left, Right right) -> do
      let leftManifest = checkpointManifest left
          rightManifest = checkpointManifest right
      putStrLn ("left:  " ++ leftPath)
      putStrLn ("right: " ++ rightPath)
      putStrLn ("completed step: " ++ show (adamStep (checkpointOptimizer left))
        ++ " vs " ++ show (adamStep (checkpointOptimizer right)))
      putStrLn ("numerics: " ++ show (manifestNumerics leftManifest)
        ++ " vs " ++ show (manifestNumerics rightManifest))
      when (manifestConfig leftManifest /= manifestConfig rightManifest)
        (failWith "checkpoint configs differ; the vectors are not comparable")
      putStrLn ("config: " ++ show (manifestConfig leftManifest))
      mapM_ (uncurry3 reportVector)
        [ ("parameters", checkpointParameters left, checkpointParameters right)
        , ("adam first moment", firstMoment (checkpointOptimizer left)
          , firstMoment (checkpointOptimizer right))
        , ("adam second moment", secondMoment (checkpointOptimizer left)
          , secondMoment (checkpointOptimizer right))
        ]
  where
    uncurry3 f (a, b, c) = f a b c
    failWith message = hPutStrLn stderr ("compare-checkpoint: " ++ message) >> exitFailure

-- Every statistic in ONE strict pass, with no intermediate vector.  At bpe100m
-- each vector is 115,428,096 doubles = 923 MB, and the two checkpoints are
-- already 5.5 GB live, so materializing even one difference vector exhausts a
-- 12 GB heap.  All fields are strict, so the accumulator stays a flat unboxed
-- record rather than a chain of thunks 115M deep.
data VectorDiff = VectorDiff
  { diffMaxAbs :: !Double
  , diffMaxAbsIndex :: !Int
  , diffMaxRel :: !Double
  , diffMaxRelIndex :: !Int
  , diffFirstIndex :: !Int      -- ^ -1 when the vectors are equal
  , diffDot :: !Double
  , diffLeftSquares :: !Double
  , diffRightSquares :: !Double
  }

reportVector :: String -> VU.Vector Double -> VU.Vector Double -> IO ()
reportVector label left right
  | VU.length left /= VU.length right =
      hPutStrLn stderr ("compare-checkpoint: " ++ label ++ " lengths differ: "
        ++ show (VU.length left) ++ " vs " ++ show (VU.length right)) >> exitFailure
  | VU.null left = putStrLn (label ++ ": empty")
  | otherwise = do
      putStrLn (label ++ ": elements=" ++ show (VU.length left)
        ++ " identical=" ++ show (diffFirstIndex accumulated < 0))
      putStrLn ("  max_abs=" ++ show (diffMaxAbs accumulated)
        ++ " at index " ++ show (diffMaxAbsIndex accumulated)
        ++ " (" ++ show (left VU.! diffMaxAbsIndex accumulated)
        ++ " vs " ++ show (right VU.! diffMaxAbsIndex accumulated) ++ ")")
      putStrLn ("  max_rel=" ++ show (diffMaxRel accumulated)
        ++ " at index " ++ show (diffMaxRelIndex accumulated))
      putStrLn ("  cosine=" ++ show cosine
        ++ " norms=" ++ show leftNorm ++ " / " ++ show rightNorm)
      if diffFirstIndex accumulated < 0
        then putStrLn "  first differing index: none"
        else putStrLn ("  first differing index: " ++ show (diffFirstIndex accumulated)
          ++ " (" ++ show (left VU.! diffFirstIndex accumulated)
          ++ " vs " ++ show (right VU.! diffFirstIndex accumulated) ++ ")")
  where
    accumulated = VU.ifoldl' step (VectorDiff (-1) 0 (-1) 0 (-1) 0 0 0) left
    step acc index a =
      let b = right VU.! index
          absolute = abs (a - b)
          -- Relative to the left operand, guarded so an exact zero cannot turn
          -- an already-tiny absolute difference into an infinite ratio.
          rel = absolute / max 1e-30 (abs a)
          (bestAbs, bestAbsIndex)
            | absolute > diffMaxAbs acc = (absolute, index)
            | otherwise = (diffMaxAbs acc, diffMaxAbsIndex acc)
          (bestRel, bestRelIndex)
            | rel > diffMaxRel acc = (rel, index)
            | otherwise = (diffMaxRel acc, diffMaxRelIndex acc)
          firstIndex
            | diffFirstIndex acc >= 0 = diffFirstIndex acc
            | a /= b = index
            | otherwise = -1
      in VectorDiff bestAbs bestAbsIndex bestRel bestRelIndex firstIndex
           (diffDot acc + a * b) (diffLeftSquares acc + a * a) (diffRightSquares acc + b * b)
    leftNorm = sqrt (diffLeftSquares accumulated)
    rightNorm = sqrt (diffRightSquares accumulated)
    cosine
      | leftNorm == 0 || rightNorm == 0 = 0
      | otherwise = diffDot accumulated / (leftNorm * rightNorm)

compactCheckpoint :: FilePath -> FilePath -> IO ()
compactCheckpoint input output = do
  checkpoint <- loadCheckpoint input
  case checkpoint of
    Left message -> putStrLn message
    Right value -> do
      saved <- saveCheckpointAtomic output value
      case saved of
        Left message -> putStrLn message
        Right () -> putStrLn ("wrote compact checkpoint: " ++ output)

planSegment :: FilePath -> String -> String -> String -> IO ()
planSegment path offsetText batchText size = case (readMaybe offsetText, readMaybe batchText) of
  (Just offset, Just batch) | batch > 0 -> do
    result <- loadCorpus path
    case result of
      Left message -> putStrLn message
      Right corpus -> case configFor size of
        Nothing -> putStrLn "unknown model size (expected tiny, small, bpe10m, or bpe100m)"
        Just cfg -> case trainerWindowSplitFrom offset (contextSize cfg) (corpusDocuments corpus) of
          Left message -> putStrLn message
          Right split -> do
            let trainCount = length (training split)
                validationCount = length (validation split)
                steps = (trainCount + batch - 1) `div` batch
            putStrLn (unwords
              [ "segment"
              , show offset
              , show (length (corpusDocuments corpus))
              , corpusDatasetIdentity corpus
              , show trainCount
              , show validationCount
              , show steps
              ])
  _ -> putStrLn "DOCUMENT_OFFSET must be nonnegative and TRAIN_BATCH must be positive"
  where
    configFor "tiny" = Just tinyPreset
    configFor "small" = Just smallPreset
    configFor "bpe10m" = Just bpe10mPreset
    configFor "bpe100m" = Just bpe100mPreset
    configFor _ = Nothing

-- Reconstruct the documents a whole-dataset run held out, as one fixed corpus.
--
-- Every shard's train/validation split is
-- `splitDocumentsFrom offset trainerSplitSeed trainerValidationFraction`, the
-- same function the trainer calls, so a shard's validation documents are
-- exactly the ones that run never trained on.  Collecting them by walking the
-- run's own plan therefore yields an evaluation set that is genuinely held out
-- for any checkpoint that run produced -- no new split, and no retraining.
--
-- Taking every STRIDE-th shard keeps the sample spread across the whole corpus
-- (shards are article-ordered, so a prefix would be a biased slice) while
-- bounding its size; DOCS_PER_SHARD bounds the contribution of each.  The
-- result is deterministic: same plan and shards, same corpus.
buildEval :: FilePath -> FilePath -> FilePath -> String -> String -> IO ()
buildEval output planPath runDir perShardText strideText =
  case (readMaybe perShardText, readMaybe strideText) of
    (Just perShard, Just stride) | perShard > 0 && stride > 0 -> do
      planText <- readFile planPath
      case parsePlan (lines planText) of
        Left message -> putStrLn ("build-eval: " ++ message)
        Right (size, segments) -> do
          let chosen = everyNth stride segments
          putStrLn ("build-eval: " ++ show (length chosen) ++ " of "
            ++ show (length segments) ++ " shards, up to " ++ show perShard
            ++ " held-out documents each")
          gathered <- gather size perShard chosen [] Nothing
          case gathered of
            Left message -> putStrLn ("build-eval: " ++ message)
            Right (documents, identityValue)
              | null documents -> putStrLn "build-eval: no held-out documents collected"
              | otherwise -> writeEvalCorpus output identityValue documents
    _ -> putStrLn "build-eval: DOCS_PER_SHARD and STRIDE must be positive integers"
  where
    parsePlan [] = Left ("empty plan: " ++ planPath)
    parsePlan (header : rest) = case words header of
      ("plan" : _version : _total : _globalId : _hash : _articles : _per : _batch : size : _) ->
        Right (size, [segment | line <- rest, Just segment <- [segmentOf line]])
      _ -> Left ("bad plan header in " ++ planPath)

    segmentOf line = case words line of
      ("segment" : shardText : offsetText : _) ->
        (,) <$> (readMaybe shardText :: Maybe Int)
            <*> (readMaybe offsetText :: Maybe Word64)
      _ -> Nothing

    everyNth n values = [value | (i, value) <- zip [0 :: Int ..] values, i `mod` n == 0]

    gather _ _ [] acc identityValue = pure (case identityValue of
      Nothing -> Left "no shard corpora were readable"
      Just value -> Right (concat (reverse acc), value))
    gather size perShard ((shard, offset) : rest) acc identityValue = do
      let path = runDir ++ "/shard-" ++ show shard ++ "-" ++ size ++ ".corpus"
      exists <- doesFileExist path
      if not exists
        then do
          hPutStrLn stderr ("build-eval: skipping missing " ++ path)
          gather size perShard rest acc identityValue
        else do
          loaded <- loadCorpus path
          case loaded of
            Left message -> pure (Left (path ++ ": " ++ message))
            Right corpus ->
              let corpusIdentity = corpusTokenizerIdentity corpus
              in if maybe False (/= corpusIdentity) identityValue
                then pure (Left ("shard tokenizer identities disagree at " ++ path))
                else case splitDocumentsFrom offset trainerSplitSeed
                       trainerValidationFraction (corpusDocuments corpus) of
                  Left message -> pure (Left (path ++ ": " ++ message))
                  Right split -> gather size perShard rest
                    (take perShard (validation split) : acc) (Just corpusIdentity)

writeEvalCorpus :: FilePath -> String -> [Document] -> IO ()
writeEvalCorpus output identityValue documents = do
  let corpus = CorpusArtifact
        { corpusVersion = corpusArtifactVersion
        , corpusTokenizerIdentity = identityValue
        , corpusDatasetIdentity = datasetFingerprintDocuments identityValue documents
        , corpusDocuments = documents
        }
  result <- saveCorpusAtomic output corpus
  case result of
    Left message -> putStrLn ("build-eval: " ++ message)
    Right () -> do
      putStrLn ("wrote evaluation corpus: " ++ output)
      putStrLn ("documents: " ++ show (length documents))
      putStrLn ("ordinary tokens: " ++ show (sum (map (length . documentTokens) documents)))
      putStrLn ("tokenizer: " ++ identityValue)
      putStrLn ("dataset fingerprint: " ++ corpusDatasetIdentity corpus)

bigramGateCommand :: FilePath -> Config -> IO ()
bigramGateCommand path cfg = do
  result <- loadCorpus path
  case result of
    Left message -> putStrLn message
    Right corpus -> do
      putStrLn ("tokenizer: " ++ corpusTokenizerIdentity corpus)
      putStrLn ("dataset fingerprint: " ++ corpusDatasetIdentity corpus)
      putStrLn ("context: " ++ show (contextSize cfg) ++ " vocab: " ++ show (vocabSize cfg))
      case bigramGate 256 cfg (corpusDocuments corpus) of
        Left message -> putStrLn message
        Right report -> do
          putStrLn ("documents: train=" ++ show (gateTrainDocuments report)
            ++ " validation=" ++ show (gateValidationDocuments report))
          putStrLn ("windows: train=" ++ show (gateTrainWindows report)
            ++ " validation=" ++ show (gateValidationWindows report)
            ++ " sample=" ++ show (gateSampleWindows report))
          putStrLn ("bigram gate (sample): " ++ nats (gateSampleCrossEntropy report))
          putStrLn ("bigram gate (full validation): " ++ nats (gateFullCrossEntropy report))
  where nats ce = show ce ++ " nats (perplexity " ++ show (exp ce) ++ ")"

parseTokens :: String -> Maybe [Int]
parseTokens text = mapM readMaybe (splitComma text)
  where
    splitComma [] = []
    splitComma value = case break (== ',') value of
      (part, []) -> [part]
      (part, _ : remaining) -> part : splitComma remaining

adjust :: Int -> Double -> [Double] -> [Double]
adjust index delta values =
  [if i == index then value + delta else value | (i, value) <- zip [0 ..] values]

printResult :: Show a => Either String a -> IO ()
printResult = either putStrLn print
