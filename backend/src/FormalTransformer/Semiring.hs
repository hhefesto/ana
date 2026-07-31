-- The Haskell refinement of FormalTransformer/Foundation/Algebra.agda.
--
-- Agda carries the laws as record fields; Haskell classes cannot, so the laws
-- live in backend/test/Main.hs instead, checked by exhaustive enumeration at
-- the exact carriers (Bool, Int).  That is the whole reason this module exists:
-- the language layer's structure was previously spelled longhand at each use
-- site, so the homomorphisms Elliott's design turns on were unstateable.
--
-- Deliberately base-only and Haskell2010 with no extensions: backend/gemm,
-- backend/gpu and backend/conformance are compiled by raw
-- `ghc -Wall -Wcompat -Werror -ibackend/src` inside Nix derivations that pass
-- no -X flags and carry no package beyond base/vector.
--
-- Double is an instance for uniformity with the rest of the numeric code, but
-- only the Bool and Int instances satisfy the laws exactly; Double's addition
-- is associative only up to rounding.
module FormalTransformer.Semiring
  ( Additive (..)
  , Semiring (..)
  , sumWith
  ) where

infixl 6 <+>
infixl 7 <.>

-- AdditiveMonoid in Algebra.agda: commutative, with a left identity.
class Additive a where
  zero :: a
  (<+>) :: a -> a -> a

-- Semiring in Algebra.agda: an additive monoid with a multiplicative monoid
-- distributing over it and annihilated by zero.
class Additive a => Semiring a where
  one :: a
  (<.>) :: a -> a -> a

-- The fold used wherever a semiring sum is taken over a list.  It is foldr,
-- and every law test below depends on that association order being fixed.
sumWith :: Additive a => [a] -> a
sumWith = foldr (<+>) zero

instance Additive Bool where
  zero = False
  (<+>) = (||)

instance Semiring Bool where
  one = True
  (<.>) = (&&)

instance Additive Int where
  zero = 0
  (<+>) = (+)

instance Semiring Int where
  one = 1
  (<.>) = (*)

instance Additive Double where
  zero = 0
  (<+>) = (+)

instance Semiring Double where
  one = 1
  (<.>) = (*)
