{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Config
  ( Config (..)
  , GateKind (..)
  , validateConfig
  , headDim
  , paramCount
  , LayerKind (..)
  , layerKind
  , isSoftmaxLayer
  , glaLayerCount
  , softmaxLayerCount
  , tinyPreset
  , smallPreset
  , small4Preset
  , bpe10mPreset
  , bpe10mV3Preset
  , bpe100mPreset
  , glaSmallPreset
  , glaPreset
  ) where

import Data.Binary (Binary)
import GHC.Generics (Generic)

-- How a GLA layer's decay gate is parameterized.  This is architecture, not
-- a knob: the gate defines what every GLA layer's state MEANS, so it lives
-- in Config and hence in the model identity (backend/gpu/Main.hs modelId).
--
--   GateSigmoid  alpha = sigmoid(walpha x) — the v2 gate.  Measured
--                2026-07-31 (run/gate-arms-2026-07-31, design notes §1.1):
--                the shipped setting never opens (frac(alpha>0.9) exactly
--                0.0000, half-life ~0.8 tokens), and the temperature arm
--                that opened it lost on loss because open gates admit
--                unscaled input.  The v2-era tau/output-norm arms were
--                deleted with v2; see git history for their code.
--   GateRgLru    Griffin's RG-LRU reparametrization (arXiv 2402.19427):
--                alpha = a^(c·r) with r = sigmoid(walpha x), a = sigmoid(Λ)
--                learned per channel, c = 8, and the state write scaled by
--                sqrt(1 − alpha²) so open gates do not cause interference —
--                the measured failure mode of the temperature arm.
data GateKind = GateSigmoid | GateRgLru
  deriving (Eq, Show, Generic)

instance Binary GateKind

data Config = Config
  { vocabSize :: !Int
  , contextSize :: !Int
  , modelDim :: !Int
  , ffDim :: !Int
  , layerCount :: !Int
  , headCount :: !Int
  , gateKind :: !GateKind
  , qkNorm :: !Bool     -- per-head RMSNorm on q/k in softmax layers,
                        -- with zero-centered weight-decayed gains
  , headSinks :: !Bool  -- learned per-head sink logit in softmax layers
                        -- (FormalTransformer/Attention/Sink.agda)
  } deriving (Eq, Show, Generic)

instance Binary Config

-- The trainer presets live here so every host and gate shares one value.
-- The v2-era presets keep v2 semantics (sigmoid gate, no qk-norm, no
-- sinks) so smoke paths and recorded conformance references stay valid.
tinyPreset, smallPreset, small4Preset, bpe10mPreset, bpe10mV3Preset, bpe100mPreset, glaSmallPreset, glaPreset :: Config
tinyPreset = Config 258 16 16 48 1 2 GateSigmoid False False
smallPreset = Config 258 64 64 192 2 4 GateSigmoid False False
-- Depth-matched softmax control for the hybrid A/B (gla-small is 4-layer).
small4Preset = Config 258 64 64 192 4 4 GateSigmoid False False
bpe10mPreset = Config 8192 256 320 864 6 5 GateSigmoid False False

-- The v3 pilot preset: bpe10m dimensions with the v3 arms on.  Pilot A/Bs
-- flip individual arms from here (docs/V3-DECISIONS.md).
bpe10mV3Preset = Config 8192 256 320 864 6 5 GateRgLru True True

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
bpe100mPreset = Config 32768 256 768 2048 12 12 GateSigmoid False False

-- Hybrid presets sized for the 3:1 rule below: four layers give three GLA
-- and one softmax layer; eight give six and two.
glaSmallPreset = Config 258 64 64 192 4 4 GateSigmoid False False
glaPreset = Config 8192 256 320 864 8 5 GateSigmoid False False

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

softmaxLayerCount :: Config -> Int
softmaxLayerCount c = layerCount c `div` 4

-- GLA blocks carry one extra d*d gate projection (walpha); the v3 arms add
-- their parameters only when enabled, so a config with every arm off has
-- exactly the v2 count.  Layout.namedLayout mirrors this term for term.
paramCount :: Config -> Int
paramCount c =
  vocabSize c * d
    + layerCount c * (4 * d * d + 3 * f * d + 2 * d)
    + glaLayerCount c * d * d
    + (if gateKind c == GateRgLru then glaLayerCount c * d else 0)
    + (if qkNorm c then softmaxLayerCount c * 2 * headDim c else 0)
    + (if headSinks c then softmaxLayerCount c * headCount c else 0)
    + d
  where
    d = modelDim c
    f = ffDim c
