-- A bigram language model is the minimal nontrivial StateAlgebra over the
-- token vocabulary: the state is the previous token.  Its exact
-- sufficient-statistics fit is the honest baseline any trained model must
-- beat on the trainer's own validation windows.
--
-- Smoothing is add-1 (Laplace) over the full vocabulary: the maximum
-- a-posteriori estimate under a Dirichlet(1) prior.  A context with no
-- evidence degrades to the uniform distribution 1/vocab.  Counting runs
-- over whole document streams (BOS : document ++ [EOS]); evaluation runs
-- over the trainer's fixed-width windows.
module FormalTransformer.Bigram
  ( BigramModel (..)
  , trainBigram
  , bigramLogProbability
  , bigramLanguage
  , windowCrossEntropy
  , BigramGateReport (..)
  , bigramGate
  , bigramGateFrom
  ) where

import Control.Monad (when)
import qualified Data.Map.Strict as Map
import Data.Monoid (Sum (..))
import Data.Word (Word64)

import FormalTransformer.Config
import FormalTransformer.Data
import FormalTransformer.Language (WeightedLanguage (..), foldScoring)
import FormalTransformer.Tokenizer (bosToken, eosToken)

data BigramModel = BigramModel
  { bigramVocab :: !Int
  , bigramPairCounts :: !(Map.Map (Int, Int) Int)
  , bigramContextTotals :: !(Map.Map Int Int)
  } deriving (Eq, Show)

-- One streaming pass over the training document streams: exact counts.
trainBigram :: Int -> [Document] -> BigramModel
trainBigram vocab documents = BigramModel vocab pairs totals
  where
    streams = [bosToken : documentTokens doc ++ [eosToken] | doc <- documents]
    pairs = Map.fromListWith (+)
      [((prev, next), 1 :: Int) | stream <- streams, (prev, next) <- zip stream (drop 1 stream)]
    totals = Map.fromListWith (+)
      [(prev, count) | ((prev, _), count) <- Map.toList pairs]

bigramLogProbability :: BigramModel -> Int -> Int -> Double
bigramLogProbability model prev next =
  log ((fromIntegral count + 1) / (fromIntegral total + fromIntegral (bigramVocab model)))
  where
    count = Map.findWithDefault 0 (prev, next) (bigramPairCounts model)
    total = Map.findWithDefault 0 prev (bigramContextTotals model)

-- The bigram as a weighted language conditioned on a start token: fold the
-- per-token conditional log weight through the previous-token state.  This
-- is the same foldScoring semantics the rest of the language layer uses.
bigramLanguage :: BigramModel -> Int -> WeightedLanguage Int (Sum Double)
bigramLanguage model start =
  foldScoring
    (\prev token -> (Sum (bigramLogProbability model prev token), token))
    (const mempty)
    start

-- The trainer's aggregation shape: mean over windows of the per-window
-- mean next-token cross entropy.  Scoring goes through bigramLanguage so
-- the gate cannot drift from the weighted-language semantics.
windowCrossEntropy :: BigramModel -> [[Int]] -> Either String Double
windowCrossEntropy model windows
  | null windows = Left "cross entropy needs at least one window"
  | any ((< 2) . length) windows = Left "windows must contain at least two tokens"
  | otherwise = Right (sum (map perWindow windows) / fromIntegral (length windows))
  where
    perWindow (first : rest) =
      negate (getSum (runWeightedLanguage (bigramLanguage model first) rest))
        / fromIntegral (length rest)
    perWindow [] = error "unreachable: windows were checked to be non-trivial"

data BigramGateReport = BigramGateReport
  { gateTrainDocuments :: !Int
  , gateValidationDocuments :: !Int
  , gateTrainWindows :: !Int
  , gateValidationWindows :: !Int
  , gateSampleWindows :: !Int
  , gateSampleCrossEntropy :: !Double
  , gateFullCrossEntropy :: !Double
  } deriving (Eq, Show)

-- The gate trains on exactly the trainer's training documents and scores
-- exactly the trainer's validation comparison set (the first eight
-- windows) plus the full validation split, so the report survives a
-- change of sampling policy.
bigramGate :: Config -> [Document] -> Either String BigramGateReport
bigramGate = bigramGateFrom 0

bigramGateFrom :: Word64 -> Config -> [Document] -> Either String BigramGateReport
bigramGateFrom offset cfg documents = do
  docs <- splitDocumentsFrom offset trainerSplitSeed trainerValidationFraction documents
  let width = contextSize cfg
      trainWindows = concatMap (fullWindows width) (training docs)
      valWindows = concatMap (fullWindows width) (validation docs)
  when (null trainWindows) (Left "training split has no full context sequences")
  when (null valWindows) (Left "validation split has no full context sequences")
  let model = trainBigram (vocabSize cfg) (training docs)
      sample = take 8 valWindows
  sampleCE <- windowCrossEntropy model sample
  fullCE <- windowCrossEntropy model valWindows
  pure BigramGateReport
    { gateTrainDocuments = length (training docs)
    , gateValidationDocuments = length (validation docs)
    , gateTrainWindows = length trainWindows
    , gateValidationWindows = length valWindows
    , gateSampleWindows = length sample
    , gateSampleCrossEntropy = sampleCE
    , gateFullCrossEntropy = fullCE
    }
