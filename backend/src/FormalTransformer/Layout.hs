module FormalTransformer.Layout
  ( Slice (..)
  , canonicalLayoutIdentity
  , canonicalLayoutVersion
  , namedLayout
  , sliceValues
  , decayMask
  ) where

import FormalTransformer.Config
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word32)

canonicalLayoutIdentity :: String
canonicalLayoutIdentity = "hybrid-gla-decoder-flat-parameters"

-- Version 3: slices carry their matrix shape (rows are output dimension,
-- columns input dimension, matching matVec's row-major convention), and the
-- v3 architecture arms contribute conditional slices — gate_lambda on GLA
-- blocks under GateRgLru, qk_gain_q/qk_gain_k and sink on softmax blocks
-- under qkNorm/headSinks.  A config with every arm off lays out exactly the
-- version-2 slices, but the version is the layout LANGUAGE, not one
-- config's instance of it, so it bumps once here.
canonicalLayoutVersion :: Word32
canonicalLayoutVersion = 3

data Slice = Slice
  { sliceName :: !String
  , sliceOffset :: !Int
  , sliceLength :: !Int
  , sliceDecay :: !Bool
  , sliceRows :: !Int   -- semantic shape: rows * cols == length; vectors
  , sliceCols :: !Int   -- are (length, 1).  Muon-style per-matrix
                        -- optimizers key off cols > 1.
  } deriving (Eq, Show)

namedLayout :: Config -> Either String [Slice]
namedLayout c = do
  _ <- validateConfig c
  pure (snd (foldl add (0, []) specs))
  where
    d = modelDim c
    f = ffDim c
    hd = headDim c
    vec name len decay = (name, len, decay, len, 1)
    mat name r cols decay = (name, r * cols, decay, r, cols)
    -- GLA blocks insert the gate projection walpha (and, under GateRgLru,
    -- the per-channel decay base gate_lambda) between wo and rms_ff;
    -- softmax blocks put the qk-norm gains and the sink logits in the same
    -- position.  The Futhark offsets in model.fut follow this order
    -- exactly.
    block i =
      [ vec ("blocks." ++ show i ++ ".rms_att") d False
      , mat ("blocks." ++ show i ++ ".wq") d d True
      , mat ("blocks." ++ show i ++ ".wk") d d True
      , mat ("blocks." ++ show i ++ ".wv") d d True
      , mat ("blocks." ++ show i ++ ".wo") d d True
      ]
      ++ (case layerKind c i of
            GlaKind ->
              [ mat ("blocks." ++ show i ++ ".walpha") d d True ]
              ++ [ vec ("blocks." ++ show i ++ ".gate_lambda") d False
                 | gateKind c == GateRgLru ]
            SoftmaxKind ->
              [ v | qkNorm c
                  , v <- [ vec ("blocks." ++ show i ++ ".qk_gain_q") hd True
                         , vec ("blocks." ++ show i ++ ".qk_gain_k") hd True ] ]
              ++ [ vec ("blocks." ++ show i ++ ".sink") (headCount c) False
                 | headSinks c ])
      ++
      [ vec ("blocks." ++ show i ++ ".rms_ff") d False
      , mat ("blocks." ++ show i ++ ".wgate") f d True
      , mat ("blocks." ++ show i ++ ".wup") f d True
      , mat ("blocks." ++ show i ++ ".wdown") d f True
      ]
    specs = [mat "embedding" (vocabSize c) d True]
      ++ concatMap block [0 .. layerCount c - 1]
      ++ [vec "final_rms" d False]
    add (off, acc) (name, len, decay, r, cols) =
      (off + len, acc ++ [Slice name off len decay r cols])

sliceValues :: Slice -> [a] -> Either String [a]
sliceValues s xs
  | sliceOffset s < 0 || sliceLength s < 0 = Left "invalid slice"
  | length xs < sliceOffset s + sliceLength s = Left ("parameter vector too short for " ++ sliceName s)
  | otherwise = Right (take (sliceLength s) (drop (sliceOffset s) xs))

-- One flag per parameter, so this is as long as the parameter vector: unboxed
-- for the same reason AdamWState's moments are (a boxed [Bool] of 115M
-- elements is 2.8 GB of cons cells).
decayMask :: Config -> Either String (VU.Vector Bool)
decayMask c =
  VU.concat . map (\s -> VU.replicate (sliceLength s) (sliceDecay s)) <$> namedLayout c
