{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Config
  ( Config (..)
  , validateConfig
  , headDim
  , paramCount
  , tinyPreset
  , smallPreset
  ) where

import Data.Binary (Binary)
import GHC.Generics (Generic)

data Config = Config
  { vocabSize :: !Int
  , contextSize :: !Int
  , modelDim :: !Int
  , ffDim :: !Int
  , layerCount :: !Int
  , headCount :: !Int
  } deriving (Eq, Show, Generic)

instance Binary Config

-- The trainer presets live here so every host and gate shares one value.
tinyPreset, smallPreset :: Config
tinyPreset = Config 258 16 16 48 1 2
smallPreset = Config 258 64 64 192 2 4

validateConfig :: Config -> Either String Config
validateConfig c
  | vocabSize c < 3 = Left "vocab must be at least 3 (BOS=0, EOS=1, and one ordinary token)"
  | contextSize c < 2 = Left "context must be at least 2"
  | modelDim c <= 0 = Left "model dimension must be positive"
  | ffDim c <= 0 = Left "feed-forward dimension must be positive"
  | layerCount c <= 0 = Left "layer count must be positive"
  | headCount c <= 0 = Left "head count must be positive"
  | modelDim c `mod` headCount c /= 0 = Left "head count must divide model dimension"
  | odd (headDim c) = Left "head dimension must be even for RoPE"
  | otherwise = Right c

headDim :: Config -> Int
headDim c = modelDim c `div` headCount c

paramCount :: Config -> Int
paramCount c =
  vocabSize c * d
    + layerCount c * (4 * d * d + 3 * f * d + 2 * d)
    + d
  where
    d = modelDim c
    f = ffDim c
