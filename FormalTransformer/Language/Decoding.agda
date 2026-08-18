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

open import Data.Bool using (true; false; T; if_then_else_)
open import Data.Empty using (⊥-elim)
open import Data.Unit using (tt)
open import Data.List using (List; []; _∷_; take; length; replicate)
open import Data.Nat
  using (ℕ; zero; suc; _+_; _*_; _⊓_; _⊔_; _≤_; _≤ᵇ_; z≤n; s≤s)
open import Data.Nat.Properties
  using (+-assoc; +-identityʳ; +-monoʳ-≤; ≤-refl; ≤-antisym; ≤-trans; _≤?_;
         ⊔-sel; m≤m+n; m≤n+m; *-monoˡ-≤; ≤ᵇ⇒≤; ≤⇒≤ᵇ)
open import Data.Sum using (inj₁; inj₂)
open import Relation.Nullary using (yes; no)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; cong; sym; subst; trans)

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

------------------------------------------------------------------------
-- min-p: the third truncation (Nguyen et al., arXiv 2407.01082).  Keep a
-- token iff its weight clears a fraction of the maximum weight; the
-- threshold scales with the model's own confidence — aggressive when the
-- distribution is peaked, permissive when it is flat.  The fraction
-- pBase = num/den is carried as a pair of naturals, so the keep test
-- num · max ≤ den · x is division-free.
--
-- The structural properties that motivate adopting it (the paper's
-- headline quality gains did not replicate; see the design notes §3.11):
--
--   minP-retains       retained mass ≥ the maximum weight — in particular
--                      the argmax always survives when num ≤ den, so
--                      renormalization is total: min-p has no empty-support
--                      edge case, unlike a mass target that exceeds the
--                      total.
--   minP-conservative  pBase = 0 keeps everything.
--   minP-antitone      raising pBase only shrinks the kept mass.
--   minP/topP-incomparable (the two *-keeps/*-drops pairs): min-p and
--                      top-p refine each other in neither direction.

maxW : List ℕ → ℕ
maxW [] = zero
maxW (x ∷ xs) = x ⊔ maxW xs

-- Threshold filtering over the boolean order test, so every keep/drop
-- decision reduces definitionally (the Dec-valued _≤?_ is stuck on the
-- same boolean anyway, one wrapper deeper).
keep : ℕ → ℕ → List ℕ → List ℕ
keep t den [] = []
keep t den (x ∷ xs) = if t ≤ᵇ den * x then x ∷ keep t den xs else keep t den xs

minP : ℕ → ℕ → List ℕ → List ℕ
minP num den xs = keep (num * maxW xs) den xs

-- The maximum survives filtering whenever it passes its own test.  Stated
-- with the reference maximum M abstracted, because the threshold is a
-- whole-list quantity while the induction walks the list.
private
  keep-max : ∀ t den M xs → t ≤ den * M → maxW xs ≡ M →
             M ≤ mass (keep t den xs)
  keep-max t den M [] pass eq rewrite sym eq = z≤n
  keep-max t den M (x ∷ xs) pass eq
    with ⊔-sel x (maxW xs) | t ≤ᵇ den * x in kept
  ... | inj₁ x-max | true =
    subst (λ z → M ≤ z + mass (keep t den xs))
      (sym (trans (sym x-max) eq))
      (m≤m+n M (mass (keep t den xs)))
  ... | inj₁ x-max | false =
    ⊥-elim (subst T kept (≤⇒≤ᵇ
      (subst (λ z → t ≤ den * z) (sym (trans (sym x-max) eq)) pass)))
  ... | inj₂ rest-max | true =
    ≤-trans (keep-max t den M xs pass (trans (sym rest-max) eq))
      (m≤n+m (mass (keep t den xs)) x)
  ... | inj₂ rest-max | false =
    keep-max t den M xs pass (trans (sym rest-max) eq)

minP-retains : ∀ num den xs → num ≤ den → maxW xs ≤ mass (minP num den xs)
minP-retains num den xs h =
  keep-max (num * maxW xs) den (maxW xs) xs (*-monoˡ-≤ (maxW xs) h) refl

-- pBase = 0 is the identity: 0 · max ≤ den · x always holds.
minP-conservative : ∀ den xs → minP zero den xs ≡ xs
minP-conservative den [] = refl
minP-conservative den (x ∷ xs) = cong (x ∷_) (minP-conservative den xs)

-- Raising the threshold fraction only shrinks the kept mass.
private
  keep-antitone : ∀ t t′ den xs → t ≤ t′ →
                  mass (keep t′ den xs) ≤ mass (keep t den xs)
  keep-antitone t t′ den [] h = ≤-refl
  keep-antitone t t′ den (x ∷ xs) h
    with t′ ≤ᵇ den * x in kept′ | t ≤ᵇ den * x in kept
  ... | true  | true  = +-monoʳ-≤ x (keep-antitone t t′ den xs h)
  ... | true  | false =
    ⊥-elim (subst T kept (≤⇒≤ᵇ
      (≤-trans h (≤ᵇ⇒≤ t′ (den * x) (subst T (sym kept′) tt)))))
  ... | false | true  =
    ≤-trans (keep-antitone t t′ den xs h) (m≤n+m (mass (keep t den xs)) x)
  ... | false | false = keep-antitone t t′ den xs h

minP-antitone : ∀ num num′ den xs → num ≤ num′ →
                mass (minP num′ den xs) ≤ mass (minP num den xs)
minP-antitone num num′ den xs h =
  keep-antitone (num * maxW xs) (num′ * maxW xs) den xs
    (*-monoˡ-≤ (maxW xs) h)

-- Incomparability, both directions, by computation.  On (5, 5, 1) a
-- mass-10 nucleus drops the 1 while min-p at 1/10 keeps it; on (5, 3) a
-- mass-8 nucleus keeps the 3 while min-p at 9/10 drops it.  Neither
-- truncation refines the other.
minP-keeps-tail : minP 1 10 (5 ∷ 5 ∷ 1 ∷ []) ≡ 5 ∷ 5 ∷ 1 ∷ []
minP-keeps-tail = refl

topP-drops-tail : topP 10 (5 ∷ 5 ∷ 1 ∷ []) ≡ 5 ∷ 5 ∷ []
topP-drops-tail = refl

topP-keeps-runner-up : topP 8 (5 ∷ 3 ∷ []) ≡ 5 ∷ 3 ∷ []
topP-keeps-runner-up = refl

minP-drops-runner-up : minP 9 10 (5 ∷ 3 ∷ []) ≡ 5 ∷ []
minP-drops-runner-up = refl
