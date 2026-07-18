{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Config
  ( Config (..)
  , validateConfig
  , headDim
  , paramCount
  , isSoftmaxLayer
  , glaLayerCount
  , tinyPreset
  , smallPreset
  , small4Preset
  , bpe10mPreset
  , glaSmallPreset
  , glaPreset
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
tinyPreset, smallPreset, small4Preset, bpe10mPreset, glaSmallPreset, glaPreset :: Config
tinyPreset = Config 258 16 16 48 1 2
smallPreset = Config 258 64 64 192 2 4
-- Depth-matched softmax control for the hybrid A/B (gla-small is 4-layer).
small4Preset = Config 258 64 64 192 4 4
bpe10mPreset = Config 8192 256 320 864 6 5

-- Hybrid presets sized for the 3:1 rule below: four layers give three GLA
-- and one softmax layer; eight give six and two.
glaSmallPreset = Config 258 64 64 192 4 4
glaPreset = Config 8192 256 320 864 8 5

validateConfig :: Config -> Either String Config
validateConfig c
  | vocabSize c < 3 = Left "vocab must be at least 3 (BOS=0, EOS=1, and one ordinary token)"
  | contextSize c < 2 = Left "context must be at least 2"
  | modelDim c <= 0 = Left "model dimension must be positive"
  | ffDim c <= 0 = Left "feed-forward dimension must be positive"
  | layerCount c <= 0 = Left "layer count must be positive"
  | headCount c <= 0 = Left "head count must be positive"
  | modelDim c `mod` headCount c /= 0 = Left "head count must divide model dimension"
  | odd (headDim c) = Left "head dimension must be even"
  | otherwise = Right c

headDim :: Config -> Int
headDim c = modelDim c `div` headCount c

-- The hybrid attention rule: every fourth layer is softmax full attention,
-- the rest are gated linear attention (GLA).  The rule is part of the
-- architecture (and hence of the model identity), not per-checkpoint data.
-- Softmax layers use no positional encoding; position lives in the GLA
-- gates (data-dependent transitions subsume rotations).  See
-- docs/ATTENTION-SEMANTICS.md.
isSoftmaxLayer :: Config -> Int -> Bool
isSoftmaxLayer _ i = i `mod` 4 == 3

glaLayerCount :: Config -> Int
glaLayerCount c = layerCount c - layerCount c `div` 4

-- GLA blocks carry one extra d*d gate projection (walpha).
paramCount :: Config -> Int
paramCount c =
  vocabSize c * d
    + layerCount c * (4 * d * d + 3 * f * d + 2 * d)
    + glaLayerCount c * d * d
    + d
  where
    d = modelDim c
    f = ffDim c
