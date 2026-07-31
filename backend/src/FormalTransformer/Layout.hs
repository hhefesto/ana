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

canonicalLayoutVersion :: Word32
canonicalLayoutVersion = 2

data Slice = Slice
  { sliceName :: !String
  , sliceOffset :: !Int
  , sliceLength :: !Int
  , sliceDecay :: !Bool
  } deriving (Eq, Show)

namedLayout :: Config -> Either String [Slice]
namedLayout c = do
  _ <- validateConfig c
  pure (snd (foldl add (0, []) specs))
  where
    d = modelDim c
    f = ffDim c
    -- GLA blocks insert the gate projection walpha between wo and rms_ff;
    -- the Futhark offsets in model.fut follow this order exactly.
    block i =
      [ ("blocks." ++ show i ++ ".rms_att", d, False)
      , ("blocks." ++ show i ++ ".wq", d * d, True)
      , ("blocks." ++ show i ++ ".wk", d * d, True)
      , ("blocks." ++ show i ++ ".wv", d * d, True)
      , ("blocks." ++ show i ++ ".wo", d * d, True)
      ]
      ++ [ ("blocks." ++ show i ++ ".walpha", d * d, True)
         | layerKind c i == GlaKind ]
      ++
      [ ("blocks." ++ show i ++ ".rms_ff", d, False)
      , ("blocks." ++ show i ++ ".wgate", f * d, True)
      , ("blocks." ++ show i ++ ".wup", f * d, True)
      , ("blocks." ++ show i ++ ".wdown", d * f, True)
      ]
    specs = [("embedding", vocabSize c * d, True)]
      ++ concatMap block [0 .. layerCount c - 1]
      ++ [("final_rms", d, False)]
    add (off, acc) (name, len, decay) =
      (off + len, acc ++ [Slice name off len decay])

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
