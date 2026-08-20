module FormalTransformer.Layout
  ( Slice (..)
  , canonicalLayoutIdentity
  , canonicalLayoutVersion
  , namedLayout
  , sliceValues
  , decayMask
  , transferParameters
  ) where

import FormalTransformer.Config
import Data.List (isSuffixOf)
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
    -- The unembedding sits LAST so that untying moves no existing offset:
    -- a tied config's layout is a prefix of the untied one.
    specs = [mat "embedding" (vocabSize c) d True]
      ++ concatMap block [0 .. layerCount c - 1]
      ++ [vec "final_rms" d False]
      ++ [ mat "unembedding" (vocabSize c) d True | not (tiedHead c) ]
    add (off, acc) (name, len, decay, r, cols) =
      (off + len, acc ++ [Slice name off len decay r cols])

sliceValues :: Slice -> [a] -> Either String [a]
sliceValues s xs
  | sliceOffset s < 0 || sliceLength s < 0 = Left "invalid slice"
  | length xs < sliceOffset s + sliceLength s = Left ("parameter vector too short for " ++ sliceName s)
  | otherwise = Right (take (sliceLength s) (drop (sliceOffset s) xs))

-- Cross-architecture warm start: build a parameter vector for the target
-- config by transferring every slice that means the same thing in both
-- layouts and keeping the target's fresh initialization for the rest.  The
-- source may be a v2-era checkpoint (which decodes through the read-only
-- migration as the arms-off v3 config) or any other architecture over the
-- same core dimensions.  A slice transfers when its name and shape match;
-- two exceptions are semantic, not structural: walpha does NOT transfer
-- across gate kinds (the same projection feeds a different gate formula, so
-- its trained values are noise under the other parametrization), and a
-- fresh unembedding seeds from a tied source's embedding (which computes
-- exactly the function the tied head was trained to).  New arm slices
-- (gate_lambda, qk_gain_q/k, sink) keep their fresh init, which is neutral
-- or open by construction.  Returns the parameters plus the transferred and
-- fresh slice names for the trainer's log.
transferParameters :: Config -> Config -> VU.Vector Double -> VU.Vector Double
  -> Either String (VU.Vector Double, [String], [String])
transferParameters src dst srcParams freshParams = do
  srcLayout <- namedLayout src
  dstLayout <- namedLayout dst
  check (core src == core dst)
    "warm-start source has different core dimensions (only architecture arms may differ)"
  check (VU.length srcParams == sum (map sliceLength srcLayout))
    "warm-start source parameter vector does not match its layout"
  check (VU.length freshParams == sum (map sliceLength dstLayout))
    "warm-start fresh parameter vector does not match the target layout"
  let srcByName = [(sliceName s, s) | s <- srcLayout]
      sourceFor d
        | ".walpha" `isSuffixOf` sliceName d, gateKind src /= gateKind dst = Nothing
        | sliceName d == "unembedding", tiedHead src = lookup "embedding" srcByName
        | otherwise = lookup (sliceName d) srcByName
      pick d = case sourceFor d of
        Just s | sliceRows s == sliceRows d, sliceCols s == sliceCols d ->
          (VU.slice (sliceOffset s) (sliceLength s) srcParams, [sliceName d], [])
        _ -> (VU.slice (sliceOffset d) (sliceLength d) freshParams, [], [sliceName d])
      picks = map pick dstLayout
  pure ( VU.concat [values | (values, _, _) <- picks]
       , concat [transferred | (_, transferred, _) <- picks]
       , concat [kept | (_, _, kept) <- picks]
       )
  where
    core c = (vocabSize c, contextSize c, modelDim c, ffDim c, layerCount c, headCount c)
    check True _ = Right ()
    check False message = Left message

-- One flag per parameter, so this is as long as the parameter vector: unboxed
-- for the same reason AdamWState's moments are (a boxed [Bool] of 115M
-- elements is 2.8 GB of cons cells).
decayMask :: Config -> Either String (VU.Vector Bool)
decayMask c =
  VU.concat . map (\s -> VU.replicate (sliceLength s) (sliceDecay s)) <$> namedLayout c
