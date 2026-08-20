{-# OPTIONS --safe --without-K #-}

-- Speculative decoding's exactness theorem, division-free.
--
-- The scheme (Leviathan et al., arXiv 2211.17192; Chen et al., 2302.01318):
-- a cheap draft model proposes x ~ q, the target model accepts it with
-- probability min(1, p(x)/q(x)), and on rejection resamples from the
-- normalized residual (p − min(p,q)) / (1 − α), where α = Σ min(p,q) is the
-- acceptance rate.  The theorem is that the output is distributed EXACTLY
-- as p — the draft can only cost time, never correctness.  Notably q is
-- universally quantified: the theorem does not care where the draft came
-- from (an MTP head, a smaller checkpoint, an n-gram model).
--
-- Division is a sampling detail, not part of the mathematical content.  In
-- unnormalized form the accepted branch contributes q(x)·min(1,p(x)/q(x)) =
-- min(p(x), q(x)) mass at x and the rejected branch contributes the
-- residual (p(x) − min(p(x), q(x))) = (p(x) ∸ q(x)); exactness is then the
-- pointwise identity  min(p,q) + (p ∸ q) ≡ p,  which holds in ℕ with monus
-- and no side conditions.  So, as in Decoding.agda, measures are vectors of
-- naturals (a rational distribution put over a common denominator), and the
-- whole proof is finite algebra.  Vec rather than List because target and
-- draft are measures over the SAME vocabulary; the shared index is the
-- point of the statement.
--
--   exact             the merged accept/residual measure is p, pointwise
--   mass-exact        acceptance mass + residual mass = total target mass
--   residual-balanced with equal totals the two one-sided residuals have
--                     equal mass — that common value is the total-variation
--                     distance (times the common denominator), giving the
--                     corollary  α = mass p − TV(p, q)
--
-- What stays outside, stated as assumptions where the implementation meets
-- this spec: the papers' own caveat that exactness holds "within hardware
-- numerics" — the float gap is the same explicit trusted-base item as the
-- log-space gates — and the PRNG that realizes the accept/reject draws.

module FormalTransformer.Language.SpeculativeDecoding where

open import Data.Nat using (ℕ; zero; suc; _+_; _⊓_; _∸_)
open import Data.Nat.Properties using (+-assoc; +-comm; ⊓-comm; suc-injective)
open import Data.Vec using (Vec; []; _∷_; zipWith)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; cong; cong₂; sym; trans)

mass : ∀ {n} → Vec ℕ n → ℕ
mass [] = zero
mass (x ∷ xs) = x + mass xs

-- The mass the accept branch delivers at each token, and the unnormalized
-- residual the reject branch resamples from.
accepted : ∀ {n} → Vec ℕ n → Vec ℕ n → Vec ℕ n
accepted = zipWith _⊓_

residual : ∀ {n} → Vec ℕ n → Vec ℕ n → Vec ℕ n
residual = zipWith _∸_

-- The one-token core: min(p,q) + (p ∸ q) ≡ p.  An unconditional ℕ identity
-- — monus is exactly the clipped difference the residual measure needs.
⊓-∸-exact : ∀ m k → m ⊓ k + (m ∸ k) ≡ m
⊓-∸-exact zero    zero    = refl
⊓-∸-exact zero    (suc k) = refl
⊓-∸-exact (suc m) zero    = refl
⊓-∸-exact (suc m) (suc k) = cong suc (⊓-∸-exact m k)

-- Exactness: accepted and residual mass together reconstitute the target
-- measure pointwise.  This is the whole theorem; everything after it is
-- bookkeeping about totals.
exact : ∀ {n} (p q : Vec ℕ n) →
        zipWith _+_ (accepted p q) (residual p q) ≡ p
exact []      []      = refl
exact (x ∷ p) (y ∷ q) = cong₂ _∷_ (⊓-∸-exact x y) (exact p q)

private
  interchange : ∀ a b c d → (a + b) + (c + d) ≡ (a + c) + (b + d)
  interchange a b c d =
    trans (+-assoc a b (c + d))
      (trans (cong (a +_)
               (trans (sym (+-assoc b c d))
                 (trans (cong (_+ d) (+-comm b c)) (+-assoc c b d))))
        (sym (+-assoc a c (b + d))))

  +-cancel : ∀ a {b c} → a + b ≡ a + c → b ≡ c
  +-cancel zero    h = h
  +-cancel (suc a) h = +-cancel a (suc-injective h)

-- Totals: acceptance mass plus residual mass is the target's mass.  Read
-- normalized: α + (1 − α) = 1, with α = mass (accepted p q) over the common
-- denominator.
mass-exact : ∀ {n} (p q : Vec ℕ n) →
             mass (accepted p q) + mass (residual p q) ≡ mass p
mass-exact []      []      = refl
mass-exact (x ∷ p) (y ∷ q) =
  trans (interchange (x ⊓ y) (mass (accepted p q))
                     (x ∸ y) (mass (residual p q)))
    (cong₂ _+_ (⊓-∸-exact x y) (mass-exact p q))

accepted-comm : ∀ {n} (p q : Vec ℕ n) → accepted p q ≡ accepted q p
accepted-comm []      []      = refl
accepted-comm (x ∷ p) (y ∷ q) = cong₂ _∷_ (⊓-comm x y) (accepted-comm p q)

-- With equal totals (two genuine distributions over one denominator), the
-- two one-sided residuals carry the same mass.  That shared value is the
-- total-variation distance scaled by the denominator, so mass-exact reads
-- as the standard corollary: acceptance rate α = 1 − TV(p, q).
residual-balanced : ∀ {n} (p q : Vec ℕ n) → mass p ≡ mass q →
                    mass (residual p q) ≡ mass (residual q p)
residual-balanced p q h =
  +-cancel (mass (accepted p q))
    (trans (mass-exact p q)
      (trans h
        (trans (sym (mass-exact q p))
          (cong (_+ mass (residual q p))
            (cong mass (sym (accepted-comm p q)))))))
