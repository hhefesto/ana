-- The Haskell refinement of FormalTransformer/Attention/Linear.agda.
--
-- Linear.agda fixes the denotation: the GLA state is `Matrix = Fin dk → Fin dv
-- → Carrier`, a type in which no prefix length appears, and packages the
-- recurrence as a `StateAlgebra` (Language/Autoregressive.agda).  Over that it
-- proves `recurrent≡parallel`, `runGLA-++` and `chunk-closed` -- the semantic
-- licence for the chunkwise parallel form the Futhark backend computes.
--
-- The Haskell side used to spell all of this as a `where`-bound `go` over
-- `replicate hd (replicate hd 0)` inside Model.glaAttention, with no state
-- type and no algebra, so those three theorems were shadowed only by comparing
-- Haskell against Futhark -- that is, only inside a Nix derivation with a
-- Futhark toolchain.  With the structure named here, `recurrent≡parallel` and
-- `runGLA-++` are ordinary local tests.
--
-- STANDING RULE FOR THIS MODULE: wrap containers, never scalars.
-- Model.hs stays polymorphic in `(Floating a, Ord a)` precisely so
-- `Numeric.AD.grad` can differentiate the same source that produces forward
-- values.  `grad`'s constraints fall on the parameter container ([]) and the
-- scalar (a).  StateMatrix and GlaToken are parametric, need no Num or
-- Floating instance, and never appear in the parameter list or in the loss's
-- return type, so AD is unaffected.  A newtype over `a` itself would break it.
module FormalTransformer.Attention.Gla
  ( StateMatrix (..)
  , GlaToken (..)
  , zeroState
  , glaStep
  , glaReadout
  , glaEmitStep
  , glaAlgebra
  , runGla
  , gateProd
  , contrib
  , closedGla
  , glaAttention
  , l2Normalize
  , zip4'
  ) where

import Data.List (transpose)
import FormalTransformer.Config
import FormalTransformer.Language.Autoregressive

-- Linear.agda's `Matrix`.  Square here (dk = dv = headDim), rows indexed by
-- the key dimension and columns by the value dimension.  The point of naming
-- it is that no prefix length occurs in the type: the state a GLA layer
-- carries is bounded, which is the whole content of the linear-attention
-- claim, and it was previously visible only as `replicate hd (replicate hd 0)`.
newtype StateMatrix a = StateMatrix { stateRows :: [[a]] }

-- One position's contribution, per head: Linear.agda's `query`, `key`, `val`
-- and `gate` observations of a token, bundled.
data GlaToken a = GlaToken
  { glaQuery :: [a]
  , glaKey :: [a]
  , glaValue :: [a]
  , glaGate :: [a]
  }

zeroState :: Num a => Int -> StateMatrix a
zeroState hd = StateMatrix (replicate hd (replicate hd 0))

-- Linear.agda's stepGLA: S_t = diag(alpha_t) * S_{t-1} + k_t v_t^T.
glaStep :: Num a => GlaToken a -> StateMatrix a -> StateMatrix a
glaStep token (StateMatrix state) =
  StateMatrix
    (zipWith3
      (\ac kc row -> zipWith (\s vj -> ac * s + kc * vj) row v)
      alpha k state)
  where
    k = glaKey token
    v = glaValue token
    alpha = glaGate token

-- Linear.agda's `readout`: o_t j = Σ_i q_i S_i_j.
glaReadout :: Num a => [a] -> StateMatrix a -> [a]
glaReadout q (StateMatrix state') = [ sum (zipWith (*) q col) | col <- transpose state' ]

-- Linear.agda's Packaged module takes `emit` as a free parameter; attention
-- instantiates it as the readout of the state AFTER the step, so the token at
-- position t sees its own key and value.  Written as one function rather than
-- as `emit` composed with `step` so the state is stepped exactly once.
glaEmitStep :: Num a => StateMatrix a -> GlaToken a -> ([a], StateMatrix a)
glaEmitStep state token = (glaReadout (glaQuery token) state', state')
  where state' = glaStep token state

-- Attention has no terminal emission: Packaged's other free parameter `obs`
-- is instantiated at the additive zero of the output vector space.
glaAlgebra :: Num a => StateAlgebra (GlaToken a) [a] (StateMatrix a)
glaAlgebra = StateAlgebra
  { algebraOut = const []
  , algebraStep = glaEmitStep
  }

-- Linear.agda's runGLA.
runGla :: Num a => StateMatrix a -> [GlaToken a] -> StateMatrix a
runGla = runAlgebra glaAlgebra

-- Linear.agda's gateProd: the diagonal of the transition product.  Later
-- tokens multiply on the LEFT; the order is kept because the Agda proof does
-- not assume commutativity and the float sum here is not associative either.
gateProd :: Num a => Int -> [GlaToken a] -> [a]
gateProd hd [] = replicate hd 1
gateProd hd (token : remaining) = zipWith (*) (gateProd hd remaining) (glaGate token)

-- Linear.agda's contrib: Σ over tokens of (∏ gates strictly after) · k v^T.
contrib :: Num a => Int -> [GlaToken a] -> StateMatrix a
contrib hd [] = StateMatrix (replicate hd (replicate hd 0))
contrib hd (token : remaining) =
  StateMatrix
    (zipWith3
      (\g kc row -> zipWith (\c vj -> g * (kc * vj) + c) row v)
      (gateProd hd remaining) (glaKey token) (stateRows (contrib hd remaining)))
  where v = glaValue token

-- Linear.agda's closedGLA, the parallel form.  `recurrent≡parallel` says this
-- equals runGla; over floats that holds only up to rounding, which is exactly
-- what the local test measures.
closedGla :: Num a => Int -> StateMatrix a -> [GlaToken a] -> StateMatrix a
closedGla hd (StateMatrix state) tokens =
  StateMatrix
    (zipWith3
      (\g row row' -> zipWith (\s c -> g * s + c) row row')
      (gateProd hd tokens) state (stateRows (contrib hd tokens)))

-- Gated linear attention in the RECURRENT form — the definitional reading of
-- the semantics (FormalTransformer/Attention/Linear.agda stepGLA/runGLA):
-- per head, S_t = diag(alpha_t) * S_{t-1} + k_t v_t^T and o_t = q_t^T S_t.
-- The Futhark implementation computes the PARALLEL closed form; their
-- agreement in the conformance oracle is the f32 shadow of the proved
-- recurrent≡parallel theorem.  Queries and keys are L2-normalized per head
-- to bound the state readout.
--
-- Every float expression below is character-for-character what the
-- hand-written recursion in Model.hs computed; only the location of the
-- recursion changed, into emitAlgebra.
glaAttention :: Floating a => Config -> [[a]] -> [[a]] -> [[a]] -> [[a]] -> [[a]]
glaAttention c qs ks vs alphas = map concat (transpose perHead)
  where
    hd = headDim c
    perHead = [ headOutputs h | h <- [0 .. headCount c - 1] ]
    headSlice vector h = take hd (drop (h * hd) vector)
    headOutputs h = emitAlgebra glaAlgebra (zeroState hd) (headTokens h)
    headTokens h =
      [ GlaToken q k v alpha
      | (q, k, v, alpha) <- zip4' qh kh vh ah
      ]
      where
        qh = map (l2Normalize . (`headSlice` h)) qs
        kh = map (l2Normalize . (`headSlice` h)) ks
        vh = map (`headSlice` h) vs
        ah = map (`headSlice` h) alphas

l2Normalize :: Floating a => [a] -> [a]
l2Normalize x = map (/ norm) x
  where norm = sqrt (sum (map (\v -> v * v) x) + 1e-6)

zip4' :: [a] -> [b] -> [c] -> [d] -> [(a, b, c, d)]
zip4' (a : as) (b : bs) (c : cs) (d : ds) = (a, b, c, d) : zip4' as bs cs ds
zip4' _ _ _ _ = []
