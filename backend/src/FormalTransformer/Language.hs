module FormalTransformer.Language
  ( WeightedLanguage (..)
  , nu
  , residual
  , singletonDelta
  , foldScoring
  , foldDetermination
  , LanguageState
  , initialState
  , advance
  , tokenLogProbability
  , prefixLogScore
  , continuationLogScore
  , continuationPathMetric
  , PathMetric
  , pathMetric
  , pathIdentity
  , pathLogProbability
  , pathProbability
  , directedSurprisal
  , composeConditionalPath
  , bradleyMagnitude
  , bradleyMagnitudeDerivativeAtOne
  ) where

import FormalTransformer.Config
import FormalTransformer.Model

newtype WeightedLanguage token weight = WeightedLanguage
  { runWeightedLanguage :: [token] -> weight
  }

nu :: WeightedLanguage token weight -> weight
nu language = runWeightedLanguage language []

-- The left residual by a prefix evaluates suffixes after that prefix.
residual :: [token] -> WeightedLanguage token weight -> WeightedLanguage token weight
residual prefix language = WeightedLanguage (runWeightedLanguage language . (prefix ++))

-- Elliott's one-token derivative is residualization by a singleton prefix.
singletonDelta :: token -> WeightedLanguage token weight -> WeightedLanguage token weight
singletonDelta token = residual [token]

foldScoring
  :: Monoid weight
  => (state -> token -> (weight, state))
  -> (state -> weight)
  -> state
  -> WeightedLanguage token weight
foldScoring step terminal initial = WeightedLanguage (go mempty initial)
  where
    go score state [] = score <> terminal state
    go score state (token : remaining) =
      let (increment, state') = step state token
      in go (score <> increment) state' remaining

foldDetermination :: (state -> token -> state) -> state -> [token] -> state
foldDetermination = foldl

newtype LanguageState = LanguageState { stateTokens :: [Int] }
  deriving (Eq, Show)

initialState :: Int -> LanguageState
initialState bos = LanguageState [bos]

advance :: Config -> LanguageState -> Int -> Either String LanguageState
advance c (LanguageState prefix) token
  | token < 0 || token >= vocabSize c = Left "token out of vocabulary"
  | length prefix >= contextSize c = Left "language state exceeds context"
  | otherwise = Right (LanguageState (prefix ++ [token]))

tokenLogProbability :: Config -> [Double] -> LanguageState -> Int -> Either String Double
tokenLogProbability c params (LanguageState prefix) token = do
  logits <- fullSequenceLogits c params prefix
  if token < 0 || token >= vocabSize c
    then Left "token out of vocabulary"
    else let z = last logits in Right (z !! token - logSumExp z)

prefixLogScore :: Config -> [Double] -> [Int] -> Either String Double
prefixLogScore _ _ [] = Left "a scored prefix must contain an initial token"
prefixLogScore c params (first : rest) = continuationLogScore c params (initialState first) rest

continuationLogScore :: Config -> [Double] -> LanguageState -> [Int] -> Either String Double
continuationLogScore c params = go 0
  where
    go total _ [] = Right total
    go total state (token : remaining) = do
      score <- tokenLogProbability c params state token
      state' <- advance c state token
      go (total + score) state' remaining

continuationPathMetric :: Config -> [Double] -> LanguageState -> [Int] -> Either String PathMetric
continuationPathMetric c params state tokens =
  continuationLogScore c params state tokens >>= pathMetric

newtype PathMetric = PathMetric { pathLogProbability :: Double }
  deriving (Eq, Show)

pathMetric :: Double -> Either String PathMetric
pathMetric logProbability
  | isNaN logProbability || isInfinite logProbability = Left "path log probability must be finite"
  | logProbability > 1e-12 = Left "path log probability must not be positive"
  | otherwise = Right (PathMetric (min 0 logProbability))

pathIdentity :: PathMetric
pathIdentity = PathMetric 0

pathProbability :: PathMetric -> Double
pathProbability = exp . pathLogProbability

directedSurprisal :: PathMetric -> Double
directedSurprisal = negate . pathLogProbability

-- Composition is valid for consecutive conditional path probabilities.
composeConditionalPath :: PathMetric -> PathMetric -> PathMetric
composeConditionalPath (PathMetric first) (PathMetric second) = PathMetric (first + second)

bradleyMagnitude :: Double -> [[Double]] -> Int -> Either String Double
bradleyMagnitude t distributions terminalCount
  | isNaN t || isInfinite t || t <= 0 = Left "magnitude parameter t must be finite and positive"
  | terminalCount < 0 = Left "terminal count must be nonnegative"
  | otherwise = do
      mapM_ validateDistribution distributions
      let normalized = map normalizeDistribution distributions
      let contribution probabilities
            | t == 1 = 0
            | abs (t - 1) < 1e-6 = sum [nearOneTerm p | p <- probabilities, p > 0]
            | otherwise = sum [p - p ** t | p <- probabilities, p > 0]
          nearOneTerm p =
            let x = (t - 1) * log p
            in -p * (x + x * x / 2 + x * x * x / 6)
      pure (fromIntegral terminalCount + sum (map contribution normalized))

bradleyMagnitudeDerivativeAtOne :: [[Double]] -> Either String Double
bradleyMagnitudeDerivativeAtOne distributions = do
  mapM_ validateDistribution distributions
  let normalized = map normalizeDistribution distributions
  pure (sum [-p * log p | probabilities <- normalized, p <- probabilities, p > 0])

validateDistribution :: [Double] -> Either String ()
validateDistribution probabilities
  | null probabilities = Left "probability distribution must be non-empty"
  | any (\p -> isNaN p || isInfinite p) probabilities = Left "probabilities must be finite"
  | any (< 0) probabilities = Left "probabilities must be nonnegative"
  | abs (sum probabilities - 1) > 1e-9 = Left "probabilities must sum to one"
  | otherwise = Right ()

normalizeDistribution :: [Double] -> [Double]
normalizeDistribution probabilities = map (/ sum probabilities) probabilities
