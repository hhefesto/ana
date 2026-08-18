{-# OPTIONS --safe --without-K #-}

-- The sampler's denotation.  A trained model ends in a next-token
-- distribution; decoding truncates it to a sub-distribution and renormalizes
-- before drawing.  This module specifies the two truncations the GPU
-- backend's pickToken implements and proves the property that separates
-- them:
--
--   * top-p (nucleus) truncation is parameterized by a MASS TARGET and
--     retains at least that mass BY CONSTRUCTION (nucleus-retains);
--   * top-k truncation is parameterized by a COUNT, and its retained mass
--     has no distribution-independent lower bound: on the uniform
--     distribution over v tokens it retains exactly the share k/v
--     (topK-uniform), which vanishes as the distribution flattens.
--
-- Measured instance of the difference (run/generation-samples.md, step
-- 92,000): the model's next-token distribution broadened as training
-- improved it, the fixed k=40 kept ever less mass, and generation looped —
-- with no defect anywhere in the weights.  A fixed k against a moving
-- distribution has no mass guarantee; a mass target does, whichever way the
-- distribution moves.
--
-- Weights are natural numbers: an unnormalized finite measure (any rational
-- distribution put over a common denominator).  The mass arguments are pure
-- ordered-monoid content, so ℕ carries all of it; nothing below depends on
-- the list being sorted.  Sorting descending (as pickToken does) only makes
-- the retained prefix the cheapest one meeting the target — a size concern,
-- not a mass one.

module FormalTransformer.Language.Decoding where

open import Data.List using (List; []; _∷_; take; length; replicate)
open import Data.Nat using (ℕ; zero; suc; _+_; _*_; _⊓_; _≤_; z≤n; s≤s)
open import Data.Nat.Properties
  using (+-assoc; +-identityʳ; +-monoʳ-≤; ≤-refl; ≤-antisym; _≤?_)
open import Relation.Nullary using (yes; no)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; cong; sym; subst)

mass : List ℕ → ℕ
mass [] = zero
mass (x ∷ xs) = x + mass xs

-- The accumulating nucleus: keep elements until the kept mass (acc plus the
-- current element) reaches the target.  Defined without subtraction so the
-- argument transfers verbatim to any ordered commutative monoid.
nucleus : ℕ → ℕ → List ℕ → List ℕ
nucleus needed acc [] = []
nucleus needed acc (x ∷ xs) with needed ≤? acc + x
... | yes _ = x ∷ []
... | no _ = x ∷ nucleus needed (acc + x) xs

topP : ℕ → List ℕ → List ℕ
topP needed = nucleus needed zero

topK : ℕ → List ℕ → List ℕ
topK = take

-- Mass retention, the defining property: whenever the target is reachable
-- at all, the nucleus meets it.
nucleus-retains : ∀ needed acc xs → needed ≤ acc + mass xs →
                  needed ≤ acc + mass (nucleus needed acc xs)
nucleus-retains needed acc [] h = h
nucleus-retains needed acc (x ∷ xs) h with needed ≤? acc + x
... | yes le rewrite +-identityʳ x = le
... | no _ =
  subst (needed ≤_) (+-assoc acc x (mass (nucleus needed (acc + x) xs)))
    (nucleus-retains needed (acc + x) xs
      (subst (needed ≤_) (sym (+-assoc acc x (mass xs))) h))

topP-retains : ∀ needed xs → needed ≤ mass xs → needed ≤ mass (topP needed xs)
topP-retains needed xs h = nucleus-retains needed zero xs h

-- The nucleus never keeps more than there is.
nucleus-bounded : ∀ needed acc xs → mass (nucleus needed acc xs) ≤ mass xs
nucleus-bounded needed acc [] = ≤-refl
nucleus-bounded needed acc (x ∷ xs) with needed ≤? acc + x
... | yes _ = +-monoʳ-≤ x z≤n
... | no _ = +-monoʳ-≤ x (nucleus-bounded needed (acc + x) xs)

-- Conservativity in mass: a whole-mass target keeps the whole mass.
topP-conservative : ∀ xs → mass (topP (mass xs) xs) ≡ mass xs
topP-conservative xs =
  ≤-antisym (nucleus-bounded (mass xs) zero xs)
            (topP-retains (mass xs) xs ≤-refl)

-- Conservativity for top-k: a large enough count is the identity.
topK-all : ∀ k xs → length xs ≤ k → topK k xs ≡ xs
topK-all zero [] _ = refl
topK-all (suc k) [] _ = refl
topK-all (suc k) (x ∷ xs) (s≤s h) = cong (x ∷_) (topK-all k xs h)

-- The counterexample family: on the uniform measure (v tokens of weight u),
-- top-k retains exactly (k ⊓ v) * u of the total v * u — the share k/v,
-- arbitrarily small as v grows with k fixed.  No analogue of
-- nucleus-retains exists for topK.
topK-uniform : ∀ k v u → mass (topK k (replicate v u)) ≡ (k ⊓ v) * u
topK-uniform zero v u = refl
topK-uniform (suc k) zero u = refl
topK-uniform (suc k) (suc v) u = cong (u +_) (topK-uniform k v u)
