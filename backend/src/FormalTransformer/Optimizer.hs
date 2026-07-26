{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Optimizer
  ( AdamWConfig (..)
  , AdamWState (..)
  , validateAdamWConfig
  , initAdamW
  , learningRate
  , adamWStep
  ) where

import Data.Binary (Binary, get, put)
import qualified Data.Vector.Unboxed as VU
import GHC.Generics (Generic)

data AdamWConfig = AdamWConfig
  { baseLearningRate :: !Double
  , beta1 :: !Double
  , beta2 :: !Double
  , adamEpsilon :: !Double
  , weightDecay :: !Double
  , warmupSteps :: !Int
  , totalSteps :: !Int
  } deriving (Eq, Show, Generic)

instance Binary AdamWConfig

-- The moments are one Double per parameter, so at GPT-2-small scale each is
-- 115M elements. As a boxed [Double] that is 4.6 GB per moment -- 40 bytes an
-- element, against 8 in an unboxed vector -- and a checkpoint holds three such
-- arrays at once. Representation, not denotation: the optimizer is still the
-- same function of the same Doubles.
data AdamWState = AdamWState
  { adamStep :: !Int
  , firstMoment :: !(VU.Vector Double)
  , secondMoment :: !(VU.Vector Double)
  } deriving (Eq, Show, Generic)

-- Written out rather than derived so it stays byte-identical to the instance
-- GHC.Generics produced when the moments were lists: legacy checkpoints
-- (Section "LegacyCheckpoint" in Artifact) are still decoded with it.
instance Binary AdamWState where
  put state = do
    put (adamStep state)
    put (VU.toList (firstMoment state))
    put (VU.toList (secondMoment state))
  get = do
    step <- get
    first <- get
    second <- get
    pure (AdamWState step (VU.fromList first) (VU.fromList second))

validateAdamWConfig :: AdamWConfig -> Either String AdamWConfig
validateAdamWConfig cfg
  | any nonFinite [baseLearningRate cfg, beta1 cfg, beta2 cfg, adamEpsilon cfg, weightDecay cfg] =
      Left "AdamW floating-point configuration values must be finite"
  | baseLearningRate cfg < 0 = Left "base learning rate must be nonnegative"
  | beta1 cfg < 0 || beta1 cfg >= 1 || beta2 cfg < 0 || beta2 cfg >= 1 = Left "Adam betas must be in [0,1)"
  | adamEpsilon cfg <= 0 = Left "Adam epsilon must be positive"
  | weightDecay cfg < 0 = Left "weight decay must be nonnegative"
  | warmupSteps cfg < 0 = Left "warmup steps must be nonnegative"
  | totalSteps cfg <= 0 = Left "total steps must be positive"
  | warmupSteps cfg > totalSteps cfg = Left "warmup steps must not exceed total steps"
  | otherwise = Right cfg
  where nonFinite value = isNaN value || isInfinite value

initAdamW :: Int -> AdamWState
initAdamW n = AdamWState 0 (VU.replicate n 0) (VU.replicate n 0)

learningRate :: AdamWConfig -> Int -> Double
learningRate cfg step
  | step <= 0 = 0
  | warmupSteps cfg > 0 && step <= warmupSteps cfg =
      baseLearningRate cfg * fromIntegral step / fromIntegral (warmupSteps cfg)
  | totalSteps cfg <= warmupSteps cfg = baseLearningRate cfg
  | otherwise = baseLearningRate cfg * 0.5 * (1 + cos (pi * progress))
  where
    elapsed = max 0 (min (totalSteps cfg - warmupSteps cfg) (step - warmupSteps cfg))
    progress = fromIntegral elapsed / fromIntegral (totalSteps cfg - warmupSteps cfg)

adamWStep
  :: AdamWConfig
  -> VU.Vector Bool
  -> AdamWState
  -> VU.Vector Double
  -> VU.Vector Double
  -> Either String (VU.Vector Double, AdamWState)
adamWStep cfg decay state params gradients
  | Left message <- validateAdamWConfig cfg = Left message
  | any (/= n) [ VU.length decay, VU.length (firstMoment state)
               , VU.length (secondMoment state), VU.length gradients ] =
      Left "AdamW vectors must have identical lengths"
  | adamStep state < 0 = Left "AdamW step must be nonnegative"
  | adamStep state >= totalSteps cfg = Left "AdamW step has reached the configured total steps"
  | otherwise = Right (updated, AdamWState step m v)
  where
    n = VU.length params
    step = adamStep state + 1
    lr = learningRate cfg step
    m = VU.zipWith (\old g -> beta1 cfg * old + (1 - beta1 cfg) * g) (firstMoment state) gradients
    v = VU.zipWith (\old g -> beta2 cfg * old + (1 - beta2 cfg) * g * g) (secondMoment state) gradients
    b1Correction = 1 - beta1 cfg ** fromIntegral step
    b2Correction = 1 - beta2 cfg ** fromIntegral step
    update p mi vi shouldDecay =
      p - lr * (mi / b1Correction / (sqrt (vi / b2Correction) + adamEpsilon cfg)
        + (if shouldDecay then weightDecay cfg * p else 0))
    updated = VU.zipWith4 update params m v decay
