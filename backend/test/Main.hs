module Main (main) where

import Control.Exception (Exception, SomeException, displayException, finally, throwIO, try)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Monoid (Sum (..))
import FormalTransformer.AD
import FormalTransformer.Artifact
import FormalTransformer.Bigram
import FormalTransformer.Config
import FormalTransformer.Data
import FormalTransformer.Language
import FormalTransformer.Layout
import FormalTransformer.Model
import FormalTransformer.Optimizer
import FormalTransformer.Tokenizer
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.Exit (exitFailure)
import System.FilePath ((</>))

main :: IO ()
main = do
  results <- mapM runTest tests
  unless (and results) exitFailure

tests :: [(String, IO ())]
tests =
  [ ("parameter count and layout coverage", testLayout)
  , ("10M BPE preset has exact dimensions", testBpePreset)
  , ("GLA hybrid presets tile 3:1 with exact counts", testGlaPresets)
  , ("invalid configurations are rejected", testConfigRejection)
  , ("causal prefix logits are invariant", testCausalPrefix)
  , ("weighted-language residual laws", testResidualLaws)
  , ("language prefix scores factorize", testPrefixFactorization)
  , ("conditional path metrics compose", testPathComposition)
  , ("Bradley finite-tree magnitude", testBradleyMagnitude)
  , ("reverse gradient agrees with finite differences", testGradient)
  , ("AdamW one-step equation", testAdamW)
  , ("document split is non-overlapping", testSplit)
  , ("byte tokenizer is lossless", testByteTokenizer)
  , ("FastBPE artifact is strict and lossless", testFastBpe)
  , ("corpus artifact exact roundtrip", testCorpusArtifact)
  , ("corpus rejects malformed byte tokens", testMalformedCorpus)
  , ("document split is deterministic", testDeterministicSplit)
  , ("offset shard splits equal monolithic split", testOffsetSplit)
  , ("checkpoint exact roundtrip", testCheckpoint)
  , ("checkpoint rejects malformed metadata", testCheckpointMetadata)
  , ("bigram exact counts and smoothing", testBigramCounts)
  , ("bigram gate matches weighted-language semantics", testBigramLanguage)
  , ("bigram with no evidence is uniform", testBigramUniform)
  , ("trainer window split is shared and deterministic", testTrainerWindowSplit)
  , ("learned BPE is parseable, deterministic and lossless", testLearnBpe)
  ]

-- A learned tokenizer has to satisfy three things, and all three are checkable
-- without a reference implementation: the artifact must be readable by the very
-- parser that validates contiguity and merge ordering, learning must be
-- deterministic given a word table, and encoding must remain lossless.  The
-- last is the one that matters most in practice -- a trainer whose merges the
-- encoder cannot reproduce would corrupt a corpus silently.
testLearnBpe :: IO ()
testLearnBpe = do
  let text = BSC.pack (concat (replicate 40
        ("the theory of language is a theory of structure; "
          ++ "the structure of a language is the language of structures\n")))
      frequencies = countWords mempty text
      vocabulary = 320
  merges <- either (throwIO . TestException) pure (learnBpeMerges vocabulary frequencies)
  assert (not (null merges)) "learned no merges at all"
  assert (map snd merges == take (length merges) [byteVocabSize ..])
    "merge ids are not contiguous from the first non-byte token"

  again <- either (throwIO . TestException) pure (learnBpeMerges vocabulary frequencies)
  assert (again == merges) "learning is not deterministic for a fixed word table"

  -- Round-trip through the artifact the parser accepts, then through the
  -- encoder, so the trainer is checked against the real reader and writer.
  directory <- getTemporaryDirectory
  let path = directory </> "formal-transformer-learned.bpe"
      cleanup = do
        present <- doesFileExist path
        if present then removeFile path else pure ()
  (do
    BS.writeFile path (renderBpeArtifact merges)
    loaded <- loadFastBpe path >>= either (throwIO . TestException) pure
    let tokenizer = FastBpeTokenizer loaded
    assert (tokenizerVocabSize tokenizer == byteVocabSize + length merges)
      "loaded vocabulary disagrees with the number of learned merges"
    let tokens = encodeWith tokenizer text
    assert (not (null tokens)) "encoding produced no tokens"
    either (throwIO . TestException) (\back -> assert (back == text)
      "decode . encode is not the identity under the learned tokenizer")
      (decodeWith tokenizer tokens)
    -- Merges must actually be used, or the learner produced a table the
    -- encoder silently ignores.
    assert (any (>= byteVocabSize) tokens)
      "no learned merge was applied when encoding the training text"
    assert (length tokens < BS.length text)
      "encoding was no shorter than the raw bytes, so no compression happened")
    `finally` cleanup

runTest :: (String, IO ()) -> IO Bool
runTest (name, action) = do
  result <- catchTest action
  case result of
    Nothing -> putStrLn ("PASS  " ++ name) >> pure True
    Just message -> putStrLn ("FAIL  " ++ name ++ ": " ++ message) >> pure False

catchTest :: IO () -> IO (Maybe String)
catchTest action = do
  result <- try action
  pure $ case (result :: Either SomeException ()) of
    Left exception -> Just (displayException exception)
    Right () -> Nothing

data TestException = TestException String deriving (Show)
instance Exception TestException

assert :: Bool -> String -> IO ()
assert condition message = unless condition (throwIO (TestException message))

assertNear :: Double -> Double -> Double -> String -> IO ()
assertNear tolerance expected actual message =
  assert (abs (expected - actual) <= tolerance) (message ++ ": expected " ++ show expected ++ ", got " ++ show actual)

config :: Config
config = Config 4 5 2 3 1 1

params :: [Double]
params = case namedLayout config of
  Left message -> error message
  Right layout -> concatMap values layout
  where
    values slice
      | sliceDecay slice = [0.04 * sin (fromIntegral (sliceOffset slice + i + 1)) | i <- [0 .. sliceLength slice - 1]]
      | otherwise = replicate (sliceLength slice) 1

testLayout :: IO ()
testLayout = do
  layout <- expectRight (namedLayout config)
  mask <- expectRight (decayMask config)
  assert (sum (map sliceLength layout) == paramCount config) "slice lengths do not cover parameter vector"
  assert (map sliceOffset layout == scanl (+) 0 (map sliceLength (init layout))) "slice offsets are not contiguous"
  assert (length mask == paramCount config) "decay mask length differs from parameter count"
  assert (paramCount config == vocabSize config * modelDim config
    + layerCount config * (4 * modelDim config ^ (2 :: Int) + 3 * ffDim config * modelDim config + 2 * modelDim config)
    + glaLayerCount config * modelDim config ^ (2 :: Int)
    + modelDim config) "parameter count formula differs"

testBpePreset :: IO ()
testBpePreset = do
  _ <- expectRight (validateConfig bpe10mPreset)
  layout <- expectRight (namedLayout bpe10mPreset)
  assert (bpe10mPreset == Config 8192 256 320 864 6 5) "10M BPE preset dimensions differ"
  assert (headDim bpe10mPreset == 64) "10M BPE head dimension differs"
  -- Hybrid rule: of 6 layers only index 3 is softmax; 5 GLA gate
  -- projections add 5*320*320 to the former softmax-only 10,059,840.
  assert (paramCount bpe10mPreset == 10571840) "10M BPE parameter count differs"
  assert (sum (map sliceLength layout) == 10571840) "10M BPE layout does not cover parameters"

testGlaPresets :: IO ()
testGlaPresets = do
  _ <- expectRight (validateConfig glaPreset)
  _ <- expectRight (validateConfig glaSmallPreset)
  layout <- expectRight (namedLayout glaPreset)
  smallLayout <- expectRight (namedLayout glaSmallPreset)
  assert (glaPreset == Config 8192 256 320 864 8 5) "GLA preset dimensions differ"
  assert (glaSmallPreset == Config 258 64 64 192 4 4) "GLA small preset dimensions differ"
  -- Exact 3:1 tiling: 8 layers = 6 GLA + 2 softmax; 4 layers = 3 GLA + 1.
  assert (glaLayerCount glaPreset == 6 && glaLayerCount glaSmallPreset == 3)
    "hybrid 3:1 tiling differs"
  assert (map (isSoftmaxLayer glaPreset) [0 .. 7]
    == [False, False, False, True, False, False, False, True]) "softmax layer rule differs"
  assert (paramCount glaPreset == 13153600) "GLA preset parameter count differs"
  assert (paramCount glaSmallPreset == 242368) "GLA small parameter count differs"
  assert (sum (map sliceLength layout) == paramCount glaPreset)
    "GLA layout does not cover parameters"
  assert (any ((== "blocks.3.rms_att") . sliceName) smallLayout
    && not (any ((== "blocks.3.walpha") . sliceName) smallLayout)
    && any ((== "blocks.2.walpha") . sliceName) smallLayout)
    "softmax block unexpectedly carries a gate projection"

testConfigRejection :: IO ()
testConfigRejection = forM_ invalid $ \cfg ->
  assert (isLeft (validateConfig cfg)) ("accepted invalid config " ++ show cfg)
  where
    valid = config
    invalid =
      [ valid { vocabSize = 2 }
      , valid { contextSize = 1 }
      , valid { modelDim = 0 }
      , valid { ffDim = 0 }
      , valid { layerCount = 0 }
      , valid { headCount = 0 }
      , valid { modelDim = 6, headCount = 4 }
      , valid { modelDim = 3, headCount = 1 }
      ]

testCausalPrefix :: IO ()
testCausalPrefix = do
  short <- expectRight (fullSequenceLogits config params [0, 2, 3])
  long <- expectRight (fullSequenceLogits config params [0, 2, 3, 1])
  assertVectorsNear 1e-12 (concat short) (concat (take 3 long)) "prefix logits changed after adding a future token"

testResidualLaws :: IO ()
testResidualLaws = do
  let language = WeightedLanguage (\word -> length word * 7 + sum word :: Int)
      prefix = [2, 3]
      suffix = [4, 5]
      delta = singletonDelta 2 language
      scoring = foldScoring (\state token -> (Sum token, state + token)) Sum 0 :: WeightedLanguage Int (Sum Int)
  assert (nu (residual prefix language) == runWeightedLanguage language prefix) "nu of a residual differs from prefix evaluation"
  assert (runWeightedLanguage (residual suffix (residual prefix language)) []
    == runWeightedLanguage language (prefix ++ suffix)) "iterated residual does not append prefixes"
  assert (runWeightedLanguage (residual [] language) suffix == runWeightedLanguage language suffix) "empty residual is not identity"
  assert (runWeightedLanguage delta [3, 4] == runWeightedLanguage language [2, 3, 4])
    "singleton derivative does not prepend its token"
  assert (getSum (runWeightedLanguage scoring [2, 3]) == 10) "fold scoring omitted step or terminal weights"
  assert (foldDetermination (+) (0 :: Int) [2, 3, 4] == 9) "fold determination differs from repeated transitions"

testPrefixFactorization :: IO ()
testPrefixFactorization = do
  whole <- expectRight (prefixLogScore config params [0, 2, 3, 1])
  first <- expectRight (prefixLogScore config params [0, 2])
  rest <- expectRight (continuationLogScore config params (languageStateForTest [0, 2]) [3, 1])
  assertNear 1e-12 whole (first + rest) "prefix score does not factorize"

testPathComposition :: IO ()
testPathComposition = do
  let start = initialState 0
  first <- expectRight (continuationPathMetric config params start [2])
  afterFirst <- expectRight (advance config start 2)
  second <- expectRight (continuationPathMetric config params afterFirst [3, 1])
  whole <- expectRight (continuationPathMetric config params start [2, 3, 1])
  let composed = composeConditionalPath first second
  assertNear 1e-12 (pathLogProbability whole) (pathLogProbability composed) "conditional path probabilities do not compose"
  assertNear 1e-12 (directedSurprisal whole)
    (directedSurprisal first + directedSurprisal second) "directed surprisal is not additive"
  assertNear 1e-12 1 (pathProbability pathIdentity) "path identity probability differs from one"

testBradleyMagnitude :: IO ()
testBradleyMagnitude = do
  magnitude <- expectRight (bradleyMagnitude 2 [[0.5, 0.5]] 3)
  limit <- expectRight (bradleyMagnitude 1 [[0.5, 0.5]] 3)
  derivative <- expectRight (bradleyMagnitudeDerivativeAtOne [[0.5, 0.5], [0.25, 0.75]])
  assertNear 1e-12 3.5 magnitude "known Tsallis magnitude differs"
  assertNear 1e-12 3 limit "t=1 magnitude limit differs from terminal count"
  assertNear 1e-12 (log 2 - 0.25 * log 0.25 - 0.75 * log 0.75) derivative "Shannon derivative differs"
  assert (isLeft (bradleyMagnitude 2 [[0.4, 0.4]] 1)) "invalid probability distribution was accepted"

testGradient :: IO ()
testGradient = do
  analytical <- expectRight (lossGradient config params [0, 2, 3] 1)
  forM_ [0, 3, 11, length params - 1] $ \index -> do
    let epsilon = 1e-6
        plus = adjust index epsilon params
        minus = adjust index (-epsilon) params
    lp <- expectRight (nextTokenCE config plus [0, 2, 3] 1)
    lm <- expectRight (nextTokenCE config minus [0, 2, 3] 1)
    assertNear 2e-5 ((lp - lm) / (2 * epsilon)) (analytical !! index) ("gradient mismatch at " ++ show index)

testAdamW :: IO ()
testAdamW = do
  let cfg = AdamWConfig 0.01 0.9 0.99 1e-8 0.1 0 10
      state = initAdamW 2
  (updated, nextState) <- expectRight (adamWStep cfg [True, False] state [2, -3] [0.5, -0.25])
  let rate = learningRate cfg 1
      expected0 = 2 - rate * (0.5 / (sqrt (0.25) + 1e-8) + 0.1 * 2)
      expected1 = -3 - rate * ((-0.25) / (sqrt (0.0625) + 1e-8))
  assertVectorsNear 1e-12 [expected0, expected1] updated "AdamW first update differs"
  assert (adamStep nextState == 1) "AdamW step was not incremented"
  assertVectorsNear 1e-12 [0.05, -0.025] (firstMoment nextState) "AdamW first moment differs"
  assertVectorsNear 1e-12 [0.0025, 0.000625] (secondMoment nextState) "AdamW second moment differs"

testSplit :: IO ()
testSplit = do
  let docs = [Document ("doc-" ++ show i) [2, 3, 2] | i <- [0 :: Int .. 39]]
  split <- expectRight (splitDocuments 17 0.25 docs)
  examples <- expectRight (prepareSplit 17 0.25 3 docs)
  let trainIds = map documentId (training split)
      validationIds = map documentId (validation split)
      trainExampleIds = map exampleDocumentId (training examples)
      validationExampleIds = map exampleDocumentId (validation examples)
  assert (all (`notElem` validationIds) trainIds) "document appears in both splits"
  assert (all (`notElem` validationExampleIds) trainExampleIds) "window appears across document split"
  assert (all ((== [0]) . exampleInput) (filter ((== 1) . length . exampleInput) (training examples ++ validation examples))) "first window does not start with BOS"
  assert (any ((== 1) . exampleTarget) (training examples ++ validation examples)) "EOS target was not inserted"

testByteTokenizer :: IO ()
testByteTokenizer = do
  let bytes = BS.pack [0 .. 255]
      tokens = encodeBytes bytes
  decoded <- expectRight (decodeBytes tokens)
  assert (decoded == bytes) "arbitrary byte sequence did not roundtrip"
  assert (tokens == [2 .. 257]) "byte token mapping is not byte+2"
  assert (byteVocabSize == 258 && bosToken == 0 && eosToken == 1) "fixed tokenizer constants differ"

testFastBpe :: IO ()
testFastBpe = do
  temporaryDirectory <- getTemporaryDirectory
  let path = temporaryDirectory </> "formal-transformer-test.bpe"
      malformed = temporaryDirectory </> "formal-transformer-malformed.bpe"
      cleanup file = do exists <- doesFileExist file; if exists then removeFile file else pure ()
      cleanupAll = cleanup path >> cleanup malformed
  cleanupAll
  (do
      BSC.writeFile path (BSC.pack "BPE 260\n34 118 258\n258 106 259\n")
      bpe <- loadFastBpe path >>= expectRight
      let tokenizer = FastBpeTokenizer bpe
          bytes = BSC.pack " th\n th"
          tokens = encodeWith tokenizer bytes
      decoded <- expectRight (decodeWith tokenizer tokens)
      assert (decoded == bytes) "FastBPE byte sequence did not roundtrip"
      assert (tokens == [259, 12, 259]) "FastBPE rank-greedy encoding differs"
      assert (tokenizerVocabSize tokenizer == 260) "FastBPE vocabulary differs"
      assert (tokenizerVocabularyFromIdentity (tokenizerIdentityOf tokenizer) == Just 260)
        "FastBPE identity does not expose its vocabulary"
      BSC.writeFile malformed (BSC.pack "BPE 259\n34 300 258\n")
      invalid <- loadFastBpe malformed
      assert (isLeft invalid) "FastBPE accepted a future merge operand") `finally` cleanupAll

testCorpusArtifact :: IO ()
testCorpusArtifact = do
  temporaryDirectory <- getTemporaryDirectory
  let path = temporaryDirectory </> "formal-transformer-corpus-roundtrip.bin"
      sources = [("alpha.bin", BS.pack [0, 1, 255]), ("empty.bin", BS.empty)]
      corpus = CorpusArtifact corpusArtifactVersion byteTokenizerIdentity
        (datasetFingerprint sources) [Document name (encodeBytes bytes) | (name, bytes) <- sources]
      cleanup = do exists <- doesFileExist path; if exists then removeFile path else pure ()
  cleanup
  (do
      saved <- saveCorpusAtomic path corpus
      _ <- expectRight saved
      loaded <- loadCorpus path >>= expectRight
      assert (loaded == corpus) "corpus artifact did not roundtrip exactly") `finally` cleanup

testMalformedCorpus :: IO ()
testMalformedCorpus = do
  let make documents = CorpusArtifact corpusArtifactVersion byteTokenizerIdentity "dataset-fingerprint" documents
  assert (isLeft (validateCorpusArtifact (make [Document "bad" [1, 2]]))) "reserved token was accepted in corpus"
  assert (isLeft (validateCorpusArtifact (make [Document "bad" [258]]))) "out-of-range byte token was accepted"
  assert (isLeft (validateCorpusArtifact (make [Document "" [2]]))) "empty document ID was accepted"
  assert (isLeft (validateCorpusArtifact (make [Document "same" [2], Document "same" [3]]))) "duplicate document ID was accepted"

testDeterministicSplit :: IO ()
testDeterministicSplit = do
  let documents = [Document (show i) [2 + i `mod` 10] | i <- [0 :: Int .. 50]]
  first <- expectRight (splitDocuments 991 0.3 documents)
  second <- expectRight (splitDocuments 991 0.3 documents)
  assert (first == second) "same seed and documents produced different splits"
  let sources = [("b", BS.pack [2, 1]), ("a", BS.pack [0])]
  assert (datasetFingerprint sources == datasetFingerprint (reverse sources)) "dataset fingerprint depends on input ordering"

testOffsetSplit :: IO ()
testOffsetSplit = do
  let documents = [Document ("doc-" ++ show i) [2 + (i + j) `mod` 250 | j <- [0 .. 8]]
        | i <- [0 :: Int .. 36]]
      chunks = [take 7 documents, take 11 (drop 7 documents), drop 18 documents]
      offsets = [0, 7, 18]
  whole <- expectRight (splitDocuments trainerSplitSeed trainerValidationFraction documents)
  parts <- mapM (expectRight . uncurry (\offset ->
    splitDocumentsFrom offset trainerSplitSeed trainerValidationFraction)) (zip offsets chunks)
  assert (concatMap training parts == training whole) "sharded training document split differs"
  assert (concatMap validation parts == validation whole) "sharded validation document split differs"
  wholeWindows <- expectRight (trainerWindowSplit 4 documents)
  partWindows <- mapM (expectRight . uncurry (\offset -> trainerWindowSplitFrom offset 4))
    (zip offsets chunks)
  assert (concatMap training partWindows == training wholeWindows) "sharded training windows differ"
  assert (concatMap validation partWindows == validation wholeWindows) "sharded validation windows differ"

testCheckpoint :: IO ()
testCheckpoint = do
  temporaryDirectory <- getTemporaryDirectory
  let path = temporaryDirectory </> "formal-transformer-roundtrip.bin"
      identity = Identity "tiny-model" "integer-v1" "synthetic-v1"
      optimizerConfig = AdamWConfig 0.0025 0.8 0.95 1e-7 0.025 3 37
      manifest = Manifest artifactVersion config (paramCount config) canonicalLayoutIdentity
        canonicalLayoutVersion optimizerConfig identity 0.75 Tf32TensorCores
      checkpoint = Checkpoint manifest params (initAdamW (paramCount config)) (Just 1.2345) (PRNGState 1 2 3 4)
      cleanup = do exists <- doesFileExist path; if exists then removeFile path else pure ()
  cleanup
  (do
      saved <- saveCheckpointAtomic path checkpoint
      _ <- expectRight saved
      loaded <- loadCheckpoint path >>= expectRight
      let quantize = map (realToFrac . (realToFrac :: Double -> Float))
      assert (checkpointManifest loaded == manifest) "checkpoint manifest did not roundtrip exactly"
      assert (checkpointParameters loaded == quantize params) "checkpoint parameters did not roundtrip as f32"
      assert (checkpointOptimizer loaded == initAdamW (paramCount config)) "checkpoint optimizer did not roundtrip"
      assert (checkpointBestValidationLoss loaded == Just 1.2345) "checkpoint best loss did not roundtrip"
      assert (checkpointPRNG loaded == PRNGState 1 2 3 4) "checkpoint PRNG did not roundtrip"
      assert (manifestNumerics (checkpointManifest loaded) == Tf32TensorCores)
        "checkpoint numerics did not roundtrip"
      assert (manifestOptimizerConfig (checkpointManifest loaded) == optimizerConfig) "changed optimizer configuration did not survive roundtrip") `finally` cleanup

testCheckpointMetadata :: IO ()
testCheckpointMetadata = do
  let identity = Identity "tiny-model" "integer-v1" "synthetic-v1"
      optimizerConfig = AdamWConfig 1e-3 0.9 0.999 1e-8 0.01 2 10
      manifest = Manifest artifactVersion config (paramCount config) canonicalLayoutIdentity
        canonicalLayoutVersion optimizerConfig identity 1 Fp32IEEE
      checkpoint = Checkpoint manifest params (initAdamW (paramCount config)) Nothing (PRNGState 1 2 3 4)
      withManifest update = checkpoint { checkpointManifest = update manifest }
  assert (isLeft (validateCheckpoint (withManifest (\m -> m { manifestOptimizerConfig = optimizerConfig { warmupSteps = 11 } }))))
    "checkpoint accepted warmup beyond total steps"
  assert (isLeft (validateCheckpoint (withManifest (\m -> m { manifestOptimizerConfig = optimizerConfig { weightDecay = -0.1 } }))))
    "checkpoint accepted negative weight decay"
  assert (isLeft (validateCheckpoint (withManifest (\m -> m { manifestLayoutIdentity = "" }))))
    "checkpoint accepted empty layout identity"
  assert (isLeft (validateCheckpoint checkpoint { checkpointBestValidationLoss = Just (0 / 0) }))
    "checkpoint accepted non-finite best validation loss"
  assert (isLeft (validateCheckpoint checkpoint { checkpointOptimizer = (checkpointOptimizer checkpoint) { adamStep = 11 } }))
    "checkpoint accepted optimizer step beyond total steps"

-- Streams are [0,2,3,1] and [0,2,2,1]: pair counts (0,2)=2, (2,3)=1,
-- (3,1)=1, (2,2)=1, (2,1)=1; context totals 0=2, 2=3, 3=1; vocab 4.
testBigramCounts :: IO ()
testBigramCounts = do
  let model = trainBigram 4 [Document "one" [2, 3], Document "two" [2, 2]]
  assertNear 1e-12 (log 0.5) (bigramLogProbability model 0 2) "seen pair (0,2) probability differs"
  assertNear 1e-12 (log (2 / 7)) (bigramLogProbability model 2 3) "seen pair (2,3) probability differs"
  assertNear 1e-12 (log (2 / 5)) (bigramLogProbability model 3 1) "seen pair (3,1) probability differs"
  assertNear 1e-12 (log (1 / 5)) (bigramLogProbability model 3 2) "unseen pair did not receive add-one mass"
  assertNear 1e-12 (log (1 / 4)) (bigramLogProbability model 1 0) "unseen context is not uniform"
  ce <- expectRight (windowCrossEntropy model [[0, 2, 3], [2, 2, 1]])
  let window1 = negate (log 0.5 + log (2 / 7)) / 2
      window2 = negate (log (2 / 7) + log (2 / 7)) / 2
  assertNear 1e-12 ((window1 + window2) / 2) ce "window cross entropy differs from hand computation"

testBigramLanguage :: IO ()
testBigramLanguage = do
  let model = trainBigram 4 [Document "one" [2, 3], Document "two" [2, 2]]
      score start tokens = getSum (runWeightedLanguage (bigramLanguage model start) tokens)
  assertNear 1e-12 (log 0.5 + log (2 / 7)) (score 0 [2, 3]) "language score differs from summed conditionals"
  assertNear 1e-12 (score 0 [2, 3]) (score 0 [2] + score 2 [3]) "bigram path scores do not compose additively"
  assert (isLeft (windowCrossEntropy model [])) "empty window list was accepted"
  assert (isLeft (windowCrossEntropy model [[2]])) "single-token window was accepted"

testBigramUniform :: IO ()
testBigramUniform = do
  let model = trainBigram 258 []
  ce <- expectRight (windowCrossEntropy model [[0, 2, 3, 4]])
  assertNear 1e-12 (log 258) ce "no-evidence bigram is not uniform"

testTrainerWindowSplit :: IO ()
testTrainerWindowSplit = do
  let docs = [Document ("doc-" ++ show i) [2 + (i + j) `mod` 250 | j <- [0 .. 6]] | i <- [0 :: Int .. 39]]
      width = 4
  first <- expectRight (trainerWindowSplit width docs)
  second <- expectRight (trainerWindowSplit width docs)
  assert (first == second) "trainer window split is not deterministic"
  assert (all ((== width) . length) (training first ++ validation first)) "trainer windows are not full width"
  docSplit <- expectRight (splitDocuments trainerSplitSeed trainerValidationFraction docs)
  assert (training first == concatMap (fullWindows width) (training docSplit)
    && validation first == concatMap (fullWindows width) (validation docSplit))
    "trainer window split differs from document split plus fullWindows"
  assert (fullWindows 3 (Document "d" [2, 3]) == [[0, 2, 3]]) "fullWindows stream shape differs"
  assert (fullWindows 2 (Document "e" [2, 3]) == [[0, 2], [3, 1]]) "fullWindows windows are not non-overlapping"
  assert (null (fullWindows 5 (Document "short" [2]))) "short document produced a window"

-- Constructing through exported state operations keeps LanguageState abstract.
languageStateForTest :: [Int] -> LanguageState
languageStateForTest [] = initialState 0
languageStateForTest (x:xs) = foldl advanceUnsafe (initialState x) xs
  where advanceUnsafe state token = either error id (advance config state token)

expectRight :: Either String a -> IO a
expectRight = either (throwIO . TestException) pure

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

adjust :: Int -> Double -> [Double] -> [Double]
adjust index delta values = [if i == index then value + delta else value | (i, value) <- zip [0 ..] values]

assertVectorsNear :: Double -> [Double] -> [Double] -> String -> IO ()
assertVectorsNear tolerance expected actual message = do
  assert (length expected == length actual) (message ++ ": lengths differ")
  forM_ (zip expected actual) $ \(a, b) -> assertNear tolerance a b message
