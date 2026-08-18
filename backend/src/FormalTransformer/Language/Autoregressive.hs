-- The Haskell refinement of FormalTransformer/Language/Autoregressive.agda.
--
-- A StateAlgebra is the whole shape of an autoregressive model: a state, a
-- terminal observation, and a step emitting a weight and the next state.  It
-- was previously spelled as three positional arguments of
-- Language.foldScoring and again as a `where`-bound `go` in the GLA
-- attention, so nothing named the structure and its two laws -- `run-append`
-- and `factorization` -- were stated nowhere in Haskell.
--
-- Base-only Haskell2010 with no extensions: see FormalTransformer.Semiring
-- for why.  Agda's `State` is an existential record field; here it is a type
-- parameter, since Haskell2010 has no sigma types and every use site knows
-- its own state type.
module FormalTransformer.Language.Autoregressive
  ( StateAlgebra (..)
  , runAlgebra
  , emitAlgebra
  , pathWeight
  ) where

import FormalTransformer.Semiring

data StateAlgebra token weight state = StateAlgebra
  { algebraOut :: state -> weight
  , algebraStep :: state -> token -> (weight, state)
  }

-- Autoregressive.agda's `run`.  Law (run-append, proved there):
--   runAlgebra m q (xs ++ ys) == runAlgebra m (runAlgebra m q xs) ys
runAlgebra :: StateAlgebra token weight state -> state -> [token] -> state
runAlgebra _ state [] = state
runAlgebra algebra state (token : remaining) =
  runAlgebra algebra (snd (algebraStep algebra state token)) remaining

-- The emitted-weight trace.  Attention needs every intermediate emission and
-- not just the final state, so this is the traversal glaAttention folds over.
-- It has no Agda counterpart because Agda only ever needed the product.
emitAlgebra :: StateAlgebra token weight state -> state -> [token] -> [weight]
emitAlgebra _ _ [] = []
emitAlgebra algebra state (token : remaining) =
  let (weight, state') = algebraStep algebra state token
  in weight : emitAlgebra algebra state' remaining

-- Autoregressive.agda's `pathWeight`.  Law (factorization, proved there):
--   pathWeight m q (xs ++ ys)
--     == pathWeight m q xs <.> pathWeight m (runAlgebra m q xs) ys
-- This is the chain rule for autoregressive probability, and the reason
-- prefixLogScore may be computed incrementally at all.
pathWeight :: Semiring weight => StateAlgebra token weight state -> state -> [token] -> weight
pathWeight _ _ [] = one
pathWeight algebra state (token : remaining) =
  let (weight, state') = algebraStep algebra state token
  in weight <.> pathWeight algebra state' remaining
