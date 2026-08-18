{-# OPTIONS --safe --without-K #-}

-- What a tied output head can and cannot say.
--
-- The specification ties the unembedding to the token-embedding table
-- (Transformer.Specification.tiedUnembedding consumes tokenEmbedding).  For
-- a context-free reading of the model — the identity trunk that headProbe
-- in backend/gpu/Main.hs trains directly — the logit assigned to token b
-- after token a is a gated inner product of embedding rows,
--
--   gram E g a b = Σₖ E a k * g k * E b k
--
-- (g is the final RMS-norm gain; the per-row normalization of the query
-- embedding is a scalar c a applied outside the sum).  gram-sym proves this
-- kernel symmetric, and scaled-sym carries the symmetry through the row
-- rescaling: the head can weight pairs, not directions.  The skew part of
-- any bigram statistic — preferring a→b over b→a — is unrepresentable by
-- the tied head alone and must come from the trunk's context dependence.
-- Repetition is precisely the symmetric part (P(a→a), and P(a→b) = P(b→a)),
-- which is why the tied head is a structural suspect for repetitive
-- generation (hypothesis H2 in run/generation-samples.md); headProbe's
-- HEAD_TIE=0/1 A/B measures the gap this module proves exists.
--
-- Stated over any Semiring with commutative multiplication, taken as a
-- module parameter because Foundation.Algebra's Semiring does not carry it.

module FormalTransformer.Transformer.TiedHead where

open import Level using (Level; _⊔_)
open import Data.List using (List; []; _∷_; map)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; cong; cong₂; sym; trans)

open import FormalTransformer.Foundation.Algebra using (Semiring)
open import FormalTransformer.Language.Autoregressive using (listSum)

module _ {ℓ k : Level} (R : Semiring ℓ)
         (*-comm : ∀ x y → Semiring._*_ R x y ≡ Semiring._*_ R y x)
         {Token : Set ℓ} {Dim : Set k} where
  open Semiring R

  -- The gated Gram kernel of a tied head over the listed dimensions.
  gram : (Token → Dim → Carrier) → (Dim → Carrier) → List Dim →
         Token → Token → Carrier
  gram E g dims a b = listSum R (map (λ d → E a d * g d * E b d) dims)

  private
    term-sym : ∀ (E : Token → Dim → Carrier) (g : Dim → Carrier) a b d →
               E a d * g d * E b d ≡ E b d * g d * E a d
    term-sym E g a b d =
      trans (*-comm (E a d * g d) (E b d))
        (trans (cong (E b d *_) (*-comm (E a d) (g d)))
          (sym (*-assoc (E b d) (g d) (E a d))))

    sum-cong : ∀ {f h : Dim → Carrier} (dims : List Dim) →
               (∀ d → f d ≡ h d) →
               listSum R (map f dims) ≡ listSum R (map h dims)
    sum-cong [] _ = refl
    sum-cong (d ∷ dims) eq = cong₂ _+_ (eq d) (sum-cong dims eq)

  -- The kernel is symmetric: the tied head weights unordered pairs.
  gram-sym : ∀ E g dims a b → gram E g dims a b ≡ gram E g dims b a
  gram-sym E g dims a b = sum-cong dims (term-sym E g a b)

  -- Symmetry survives the per-row rescaling c: cross-multiplying the row
  -- scales exposes the same symmetric kernel, so no choice of c introduces
  -- skew — z(a→b) and z(b→a) are the same quantity in different row units.
  scaled-sym : ∀ (c : Token → Carrier) E g dims a b →
               c b * (c a * gram E g dims a b) ≡
               c a * (c b * gram E g dims b a)
  scaled-sym c E g dims a b =
    trans (cong (c b *_) (cong (c a *_) (gram-sym E g dims a b)))
      (trans (sym (*-assoc (c b) (c a) (gram E g dims b a)))
        (trans (cong (_* gram E g dims b a) (*-comm (c b) (c a)))
          (*-assoc (c a) (c b) (gram E g dims b a))))
