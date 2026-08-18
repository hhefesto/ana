{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Config
  ( Config (..)
  , validateConfig
  , headDim
  , paramCount
  , LayerKind (..)
  , layerKind
  , isSoftmaxLayer
  , glaLayerCount
  , tinyPreset
  , smallPreset
  , small4Preset
  , bpe10mPreset
  , bpe100mPreset
  , glaSmallPreset
  , glaPreset
  , gateTemperature
  , glaOutputNorm
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
tinyPreset, smallPreset, small4Preset, bpe10mPreset, bpe100mPreset, glaSmallPreset, glaPreset :: Config
tinyPreset = Config 258 16 16 48 1 2
smallPreset = Config 258 64 64 192 2 4
-- Depth-matched softmax control for the hybrid A/B (gla-small is 4-layer).
small4Preset = Config 258 64 64 192 4 4
bpe10mPreset = Config 8192 256 320 864 6 5

-- The scale-up rung, sized against GPT-2-small (124M) so the comparison is
-- like-for-like: 115,428,096 parameters, of which the 32,768-piece vocabulary
-- costs 25.2M because embeddings are tied.  A larger vocabulary is the point --
-- at 8192 pieces, learned on clean prose, unfamiliar text shatters into byte
-- fallbacks (enwik8 tokenized at 2.66 bytes/token against 3.98 on Wikipedia),
-- and that showed up directly as the 1.99 bpb external score.
--
-- ff/d stays at the repo's 2.67, which is the parameter-matched ratio for a
-- gated FFN (three d*f matrices, not two); 12 layers give 9 GLA and 3 softmax,
-- holding the 3:1 rule; head dim is 64.
bpe100mPreset = Config 32768 256 768 2048 12 12

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

-- GLA fix arms, mirrored by `gate_temperature`/`gla_out_norm` in
-- backend/futhark/model.fut (flip both languages together).  The gate is
-- alpha = sigmoid(z)^(1/gateTemperature): at temperature 1 this is the
-- historical sigmoid bit pattern; larger temperatures put the init near
-- alpha ≈ 0.5^(1/tau) (tau=16 gives ≈0.958) so memory spans longer than a
-- couple of tokens have live gradients.  glaOutputNorm applies the same
-- per-head L2 normalization as q/k to the attended output before Wo,
-- bounding the readout once the gates open (the unnormalized sum grows
-- like 1/(1-alpha)).
--
-- MEASURED 2026-07-31, three arms at glaSmallPreset, 600 steps, batch 8, on
-- 715K byte tokens, sequential backend (multicore is not reproducible), same
-- schedule and same PRNG throughout.  Numbers are per-GLA-layer from act-stats.
--
--   arm            alpha_mean   frac>0.9   att_rms   clipped   final val
--   tau=1  (ships) 0.41-0.49    0.0000     0.25-0.48 539/600   3.2251
--   tau=16         0.93-0.94    0.88-0.93  1.58-2.02 228/600   3.3079
--   tau=16 + norm  0.94-0.95    0.88-0.99  0.25000   525/600   3.2438
--
-- The diagnosis above is CONFIRMED and is worse than it reads: at tau=1 the
-- fraction of gates above 0.9 is exactly 0.0000 in every GLA layer after 600
-- steps.  Training does not open them.  Memory half-life is ~0.8 tokens, so
-- the GLA layers are very nearly memoryless -- they are not doing the thing
-- GLA exists to do.  tau=16 opens them (half-life ~9.5 tokens) and
-- glaOutputNorm pins att_rms to exactly 1/sqrt(headDim), giving the tightest
-- residual stream of the three.
--
-- But NEITHER ARM WINS on loss at this horizon, so both stay off.  tau=16
-- alone is 2.5% worse and its apparently-halved clip rate is misleading: the
-- median gradient norm merely fell below the clip (0.91 vs 1.43) while the
-- tail got 8x WORSE (max 54.1 vs 6.67).  tau=16+norm lands within 0.6% of
-- baseline with max 22.1.  600 steps of code and markdown at 242K parameters
-- is a mechanism probe, not a quality verdict -- a longer memory cannot pay
-- off in a horizon barely longer than the memory span.  The real experiment is
-- a bpe10m/bpe100m A/B on a GPU.
--
-- These are architecture, so modelId (backend/gpu/Main.hs) folds them into the
-- model identity: moving either one makes every existing checkpoint fail
-- validateResume rather than being silently reinterpreted.
gateTemperature :: Double
gateTemperature = 1

glaOutputNorm :: Bool
glaOutputNorm = False

-- The hybrid attention rule: every fourth layer is softmax full attention,
-- the rest are gated linear attention (GLA).  The rule is part of the
-- architecture (and hence of the model identity), not per-checkpoint data.
-- Softmax layers use no positional encoding; position lives in the GLA
-- gates (data-dependent transitions subsume rotations).  See
-- docs/RUN-2026-07-25-WIKI-FULL.md.
-- Transformer/Specification.agda's LayerKind and kindOf.  A Bool named
-- `isSoftmaxLayer` says which of two things a layer is only by convention;
-- the sum type says it in the type, and every consumer must now handle both
-- alternatives by name.
data LayerKind = GlaKind | SoftmaxKind
  deriving (Eq, Show)

layerKind :: Config -> Int -> LayerKind
layerKind _ i = if i `mod` 4 == 3 then SoftmaxKind else GlaKind

-- Retained as a one-line shim.  backend/gemm, backend/gpu and
-- backend/conformance are compiled by raw ghc in Nix derivations, several of
-- which need CUDA or OpenCL to build at all; keeping this means none of them
-- has to change to land the sum type.
isSoftmaxLayer :: Config -> Int -> Bool
isSoftmaxLayer c i = layerKind c i == SoftmaxKind

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
