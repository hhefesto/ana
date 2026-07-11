{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Optimizer
  ( AdamWConfig (..)
  , AdamWState (..)
  , validateAdamWConfig
  , initAdamW
  , learningRate
  , adamWStep
  ) where

import Data.Binary (Binary)
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

data AdamWState = AdamWState
  { adamStep :: !Int
  , firstMoment :: ![Double]
  , secondMoment :: ![Double]
  } deriving (Eq, Show, Generic)

instance Binary AdamWState

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
initAdamW n = AdamWState 0 (replicate n 0) (replicate n 0)

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
  -> [Bool]
  -> AdamWState
  -> [Double]
  -> [Double]
  -> Either String ([Double], AdamWState)
adamWStep cfg decay state params gradients
  | Left message <- validateAdamWConfig cfg = Left message
  | any (/= n) [length decay, length (firstMoment state), length (secondMoment state), length gradients] =
      Left "AdamW vectors must have identical lengths"
  | adamStep state < 0 = Left "AdamW step must be nonnegative"
  | adamStep state >= totalSteps cfg = Left "AdamW step has reached the configured total steps"
  | otherwise = Right (updated, AdamWState step m v)
  where
    n = length params
    step = adamStep state + 1
    lr = learningRate cfg step
    m = zipWith (\old g -> beta1 cfg * old + (1 - beta1 cfg) * g) (firstMoment state) gradients
    v = zipWith (\old g -> beta2 cfg * old + (1 - beta2 cfg) * g * g) (secondMoment state) gradients
    b1Correction = 1 - beta1 cfg ** fromIntegral step
    b2Correction = 1 - beta2 cfg ** fromIntegral step
    update p mi vi shouldDecay =
      p - lr * (mi / b1Correction / (sqrt (vi / b2Correction) + adamEpsilon cfg)
        + (if shouldDecay then weightDecay cfg * p else 0))
    updated = zipWith4 update params m v decay

zipWith4 :: (a -> b -> c -> d -> e) -> [a] -> [b] -> [c] -> [d] -> [e]
zipWith4 f (a:as) (b:bs) (c:cs) (d:ds) = f a b c d : zipWith4 f as bs cs ds
zipWith4 _ _ _ _ _ = []
