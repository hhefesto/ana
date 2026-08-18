module FormalTransformer.Language
  ( WeightedLanguage (..)
  , nu
  , residual
  , singletonDelta
  , splits
  , single
  , scale
  , algebraScoring
  , algebraLanguage
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
import FormalTransformer.Language.Autoregressive
import FormalTransformer.Model
import FormalTransformer.Semiring

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

-- The weight is the functorial argument: reweighting a language is
-- postcomposition, so `nu` and `residual` are natural in it.
instance Functor (WeightedLanguage token) where
  fmap f (WeightedLanguage run) = WeightedLanguage (f . run)

-- Elliott's generalized convolution (arXiv:1903.10677).  The denotation is
-- the free semimodule over [token]: addition is pointwise, and multiplication
-- sums the products of every way a word splits in two.  Each definition is
-- the pointwise structure transported through `runWeightedLanguage`, which is
-- exactly what makes that projection a semiring homomorphism.
instance Additive weight => Additive (WeightedLanguage token weight) where
  zero = WeightedLanguage (const zero)
  f <+> g = WeightedLanguage (\word -> runWeightedLanguage f word <+> runWeightedLanguage g word)

instance Semiring weight => Semiring (WeightedLanguage token weight) where
  one = WeightedLanguage (\word -> case word of { [] -> one; _ -> zero })
  f <.> g = WeightedLanguage (\word ->
    sumWith [runWeightedLanguage f prefix <.> runWeightedLanguage g suffix | (prefix, suffix) <- splits word])

-- Every way to cut a word in two, shortest prefix first.  The head is always
-- ([], word), which is what makes the Brzozowski product rule hold on the nose
-- rather than only up to reassociation.
splits :: [token] -> [([token], [token])]
splits [] = [([], [])]
splits (token : remaining) =
  ([], token : remaining) : [(token : prefix, suffix) | (prefix, suffix) <- splits remaining]

-- The language accepting exactly one word.  `single` is the monoid morphism
-- from words to languages: single [] = one and single (u ++ v) = single u <.> single v.
single :: (Eq token, Semiring weight) => [token] -> WeightedLanguage token weight
single word = WeightedLanguage (\candidate -> if candidate == word then one else zero)

-- Left scaling by a weight; the semimodule action underlying convolution.
scale :: Semiring weight => weight -> WeightedLanguage token weight -> WeightedLanguage token weight
scale weight language = WeightedLanguage ((weight <.>) . runWeightedLanguage language)

-- The monoidal score of a run: the accumulated step weights followed by the
-- terminal observation.  Accumulation is LEFT-associated, deliberately, so
-- that a Double weight sums in generation order.
algebraScoring
  :: Monoid weight
  => StateAlgebra token weight state
  -> state
  -> WeightedLanguage token weight
algebraScoring algebra initial = WeightedLanguage (go mempty initial)
  where
    go score state [] = score <> algebraOut algebra state
    go score state (token : remaining) =
      let (increment, state') = algebraStep algebra state token
      in go (score <> increment) state' remaining

-- Autoregressive.agda's `unnormalized`: the language a state algebra denotes,
-- pathWeight times the terminal observation of the reached state.  Where
-- algebraScoring is monoidal (used for log weights), this is multiplicative
-- in the semiring, and the `factorization` law is what makes them agree.
algebraLanguage
  :: Semiring weight
  => StateAlgebra token weight state
  -> state
  -> WeightedLanguage token weight
algebraLanguage algebra initial = WeightedLanguage $ \word ->
  pathWeight algebra initial word <.> algebraOut algebra (runAlgebra algebra initial word)

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

-- Do NOT rewrite this with the PathMetric Monoid below.  The accumulation is
-- left-associated, `mconcat` on lists is foldr, and the float association
-- order is the denotation the conformance oracle pins.
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

-- PathMetric is the composition monoid of Bradley's [0,1]-enriched category
-- read in logs: the hom-object is a nonpositive finite log probability, the
-- identity is 0 (probability one), and composition is addition.  The carrier
-- is closed under it (a sum of nonpositive finite doubles is nonpositive) and
-- pathIdentity is in the admitted subset, so this is a genuine Monoid.
--
-- Both identity laws hold exactly in IEEE: x + 0.0 == x for every finite x,
-- and -0.0 is unreachable because pathMetric applies `min 0`, and
-- min 0 (-0.0) = 0.0.  Associativity holds only up to rounding, the same
-- caveat Bigram.hs's `Sum Double` already carries.
instance Semigroup PathMetric where
  (<>) = composeConditionalPath

instance Monoid PathMetric where
  mempty = pathIdentity

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
