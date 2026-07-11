module Main (main) where

import Control.Monad (filterM, foldM)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
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
    ["inspect-corpus", path] -> inspectCorpus path
    ["bigram-gate", path] -> bigramGateCommand path tinyPreset
    ["bigram-gate", path, "tiny"] -> bigramGateCommand path tinyPreset
    ["bigram-gate", path, "small"] -> bigramGateCommand path smallPreset
    _ -> putStrLn "usage: formal-transformer (inspect | logits TOKENS | gradcheck | train-smoke | prepare-bytes OUTPUT INPUT... | prepare-stdin OUTPUT | inspect-corpus PATH | bigram-gate CORPUS [tiny|small])"

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
    Right mask -> case foldM (step cfg mask) (initialParameters, state) (take 8 (cycle examples)) of
      Left message -> putStrLn message
      Right (params, finalState) -> do
        putStrLn ("completed steps: " ++ show (adamStep finalState))
        case nextTokenCE tinyConfig params [0, 2] 3 of
          Left message -> putStrLn message
          Right loss -> do
            print loss
            let identity = Identity "smoke-model" "synthetic-token-v1" "synthetic-documents-v1"
                manifest = Manifest artifactVersion tinyConfig (paramCount tinyConfig)
                  canonicalLayoutIdentity canonicalLayoutVersion cfg identity
                checkpoint = Checkpoint manifest params finalState (Just loss) (PRNGState 1 2 3 4)
            case validateCheckpoint checkpoint of
              Left message -> putStrLn message
              Right _ -> putStrLn "checkpoint contract valid"
  where
    step cfg mask (params, state) (prefix, target) = do
      gradient <- lossGradient tinyConfig params prefix target
      adamWStep cfg mask state params gradient

prepareBytes :: FilePath -> [FilePath] -> IO ()
prepareBytes output paths = do
  missing <- filterM (fmap not . doesFileExist) paths
  case missing of
    (_ : _) -> putStrLn ("prepare-bytes: input file(s) not found: " ++ unwords missing
      ++ "\n  every INPUT must be an existing text file; the corpus is written to " ++ output)
    [] -> prepareBytesExisting output paths

-- Reads NUL-delimited (identifier, text) pairs from stdin and writes one
-- corpus artifact with one document per pair.  Intended producer:
--   jq -j '.id, "\u0000", .text, "\u0000"' articles.jsonl | \
--     formal-transformer prepare-stdin shard.corpus
prepareStdin :: FilePath -> IO ()
prepareStdin output = do
  input <- BS.getContents
  let fields = BS.split 0 input
      pair (identifier : text : rest) = (identifier, text) : pair rest
      pair _ = []
      sources =
        [ ("curid-" ++ BSC.unpack identifier, bytes)
        | (identifier, bytes) <- pair fields
        , not (BS.null identifier)
        ]
  if null sources
    then putStrLn "prepare-stdin: no documents on stdin (expected NUL-delimited id/text pairs)"
    else writeCorpus output sources

prepareBytesExisting :: FilePath -> [FilePath] -> IO ()
prepareBytesExisting output paths = do
  contents <- mapM BS.readFile paths
  writeCorpus output (zip paths contents)

writeCorpus :: FilePath -> [(String, BS.ByteString)] -> IO ()
writeCorpus output sources = do
  let corpus = CorpusArtifact
        { corpusVersion = corpusArtifactVersion
        , corpusTokenizerIdentity = byteTokenizerIdentity
        , corpusDatasetIdentity = datasetFingerprint sources
        , corpusDocuments = [Document name (encodeBytes bytes) | (name, bytes) <- sources]
        }
  result <- saveCorpusAtomic output corpus
  case result of
    Left message -> putStrLn message
    Right () -> do
      putStrLn ("wrote corpus: " ++ output)
      putStrLn ("documents: " ++ show (length sources))
      putStrLn ("dataset fingerprint: " ++ corpusDatasetIdentity corpus)

inspectCorpus :: FilePath -> IO ()
inspectCorpus path = do
  result <- loadCorpus path
  case result of
    Left message -> putStrLn message
    Right corpus -> do
      putStrLn ("version: " ++ show (corpusVersion corpus))
      putStrLn ("tokenizer: " ++ corpusTokenizerIdentity corpus)
      putStrLn ("dataset fingerprint: " ++ corpusDatasetIdentity corpus)
      putStrLn ("documents: " ++ show (length (corpusDocuments corpus)))
      putStrLn ("ordinary tokens: " ++ show (sum (map (length . documentTokens) (corpusDocuments corpus))))

bigramGateCommand :: FilePath -> Config -> IO ()
bigramGateCommand path cfg = do
  result <- loadCorpus path
  case result of
    Left message -> putStrLn message
    Right corpus -> do
      putStrLn ("tokenizer: " ++ corpusTokenizerIdentity corpus)
      putStrLn ("dataset fingerprint: " ++ corpusDatasetIdentity corpus)
      putStrLn ("context: " ++ show (contextSize cfg) ++ " vocab: " ++ show (vocabSize cfg))
      case bigramGate cfg (corpusDocuments corpus) of
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
