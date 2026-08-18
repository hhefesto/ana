{-# OPTIONS --safe --without-K #-}

-- Why residual streams are stable by construction — and what any widened
-- residual stream must satisfy to stay that way.
--
-- Manifold-Constrained Hyper-Connections (DeepSeek-AI, arXiv 2512.24880;
-- docs/PAPER-2512.24880-FINDINGS.md) widen the residual stream to n lanes
-- mixed per layer by a matrix H, and restore training stability by
-- constraining H to be doubly stochastic.  The load-bearing algebra is
-- semiring-level and is proved here:
--
--   mass-conserved     the total signal across lanes is invariant under a
--                      column-stochastic mixing step (sum interchange plus
--                      factoring; no order, no subtraction, no reals);
--   compose-stochastic column-stochastic mixes are closed under
--                      composition, so conservation holds at every depth —
--                      the paper's "compositional closure" argument;
--   singleton-rigid    at n = 1 the constraint forces H ≡ 1: the classic
--                      residual connection x + F(x) is the unique
--                      manifold-constrained mixing at expansion rate 1, and
--   singleton-identity its mixing step is the identity mapping.
--
-- The model this project ships has a single-lane residual stream, so by
-- singleton-rigid it sits inside the constraint manifold permanently; the
-- instability mHC exists to repair cannot arise.  Should a future run widen
-- the stream, these lemmas are the acceptance criterion: any proposed
-- lane-mixing map must land in the stochastic submonoid.
--
-- Conventions: H i j is the weight of source lane j in target lane i, so
-- mass conservation is the column half of "doubly stochastic".  The row
-- half (preservation of the constant vector, i.e. of the mean signal) is
-- the same theorem applied to the transpose mixing (λ i j → H j i); the
-- spectral-norm bound (‖H‖₂ ≤ 1, via Birkhoff's theorem) needs order and
-- analysis and is deliberately out of scope.  Multiplication commutativity
-- is not needed: a plain Semiring suffices.

module FormalTransformer.Transformer.ResidualStream where

open import Level using (Level; _⊔_)
open import Data.List using (List; []; _∷_; map)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; cong; cong₂; sym; trans)

open import FormalTransformer.Foundation.Algebra using (Semiring)
open import FormalTransformer.Language.Autoregressive using (listSum)

module _ {ℓ k : Level} (R : Semiring ℓ) {Lane : Set k} where
  open Semiring R

  -- A residual stream assigns a signal to each lane; a mix is the per-layer
  -- lane-coupling matrix.  Lanes are enumerated by an explicit list, in the
  -- style of Distribution's vocabulary and TiedHead's dimension list.
  Stream : Set (ℓ ⊔ k)
  Stream = Lane → Carrier

  Mix : Set (ℓ ⊔ k)
  Mix = Lane → Lane → Carrier

  mass : List Lane → Stream → Carrier
  mass lanes x = listSum R (map x lanes)

  apply : List Lane → Mix → Stream → Stream
  apply lanes H x i = listSum R (map (λ j → H i j * x j) lanes)

  colSum : List Lane → Mix → Lane → Carrier
  colSum lanes H j = listSum R (map (λ i → H i j) lanes)

  ColumnStochastic : List Lane → Mix → Set (ℓ ⊔ k)
  ColumnStochastic lanes H = ∀ j → colSum lanes H j ≡ 1#

  compose : List Lane → Mix → Mix → Mix
  compose lanes H G i j = listSum R (map (λ m → H i m * G m j) lanes)

  private
    +-identityʳ : ∀ x → x + 0# ≡ x
    +-identityʳ x = trans (+-comm x 0#) (+-identityˡ x)

    +-interchange : ∀ a b c d → (a + b) + (c + d) ≡ (a + c) + (b + d)
    +-interchange a b c d =
      trans (+-assoc a b (c + d))
        (trans (cong (a +_)
                 (trans (sym (+-assoc b c d))
                   (trans (cong (_+ d) (+-comm b c)) (+-assoc c b d))))
          (sym (+-assoc a c (b + d))))

    sum-cong : ∀ {f h : Lane → Carrier} (xs : List Lane) →
               (∀ a → f a ≡ h a) →
               listSum R (map f xs) ≡ listSum R (map h xs)
    sum-cong [] _ = refl
    sum-cong (x ∷ xs) eq = cong₂ _+_ (eq x) (sum-cong xs eq)

    sum-zero : ∀ (xs : List Lane) → listSum R (map (λ _ → 0#) xs) ≡ 0#
    sum-zero [] = refl
    sum-zero (x ∷ xs) = trans (+-identityˡ _) (sum-zero xs)

    sum-split : ∀ (f g : Lane → Carrier) (xs : List Lane) →
                listSum R (map (λ a → f a + g a) xs) ≡
                listSum R (map f xs) + listSum R (map g xs)
    sum-split f g [] = sym (+-identityˡ 0#)
    sum-split f g (x ∷ xs) =
      trans (cong ((f x + g x) +_) (sum-split f g xs))
        (+-interchange (f x) (g x) (listSum R (map f xs))
          (listSum R (map g xs)))

    -- Σᵢ Σⱼ f i j ≡ Σⱼ Σᵢ f i j — the sum interchange behind both theorems.
    sum-swap : ∀ (f : Lane → Lane → Carrier) (is js : List Lane) →
               listSum R (map (λ i → listSum R (map (f i) js)) is) ≡
               listSum R (map (λ j → listSum R (map (λ i → f i j) is)) js)
    sum-swap f [] js = sym (sum-zero js)
    sum-swap f (i ∷ is) js =
      trans (cong (listSum R (map (f i) js) +_) (sum-swap f is js))
        (sym (sum-split (f i)
               (λ j → listSum R (map (λ i′ → f i′ j) is)) js))

    -- Σₐ (f a * c) ≡ (Σₐ f a) * c — distribʳ folded over the lane list.
    sum-factorʳ : ∀ (f : Lane → Carrier) (c : Carrier) (xs : List Lane) →
                  listSum R (map (λ a → f a * c) xs) ≡
                  listSum R (map f xs) * c
    sum-factorʳ f c [] = sym (zeroˡ c)
    sum-factorʳ f c (x ∷ xs) =
      trans (cong (f x * c +_) (sum-factorʳ f c xs))
        (sym (distribʳ (f x) (listSum R (map f xs)) c))

    -- One stochastic column absorbs into the signal it weights.
    column-collapse : ∀ (lanes : List Lane) (H : Mix) (x : Stream) →
                      ColumnStochastic lanes H →
                      ∀ j → listSum R (map (λ i → H i j * x j) lanes) ≡ x j
    column-collapse lanes H x stochastic j =
      trans (sum-factorʳ (λ i → H i j) (x j) lanes)
        (trans (cong (_* x j) (stochastic j)) (*-identityˡ (x j)))

  -- The total signal in the residual stream is invariant under a
  -- column-stochastic mixing step.
  mass-conserved : ∀ (lanes : List Lane) (H : Mix) (x : Stream) →
                   ColumnStochastic lanes H →
                   mass lanes (apply lanes H x) ≡ mass lanes x
  mass-conserved lanes H x stochastic =
    trans (sum-swap (λ i j → H i j * x j) lanes lanes)
      (sum-cong lanes (column-collapse lanes H x stochastic))

  -- Column-stochastic mixes compose to a column-stochastic mix, so mass
  -- conservation holds across any depth by construction.
  compose-stochastic : ∀ (lanes : List Lane) (H G : Mix) →
                       ColumnStochastic lanes H →
                       ColumnStochastic lanes G →
                       ColumnStochastic lanes (compose lanes H G)
  compose-stochastic lanes H G sH sG j =
    trans (sum-swap (λ i m → H i m * G m j) lanes lanes)
      (trans (sum-cong lanes (column-collapse lanes H (λ m → G m j) sH))
        (sG j))

  -- At expansion rate 1 the constraint forces the mix to be 1: the plain
  -- residual connection is the unique manifold-constrained mixing.
  singleton-rigid : ∀ (H : Mix) (l : Lane) →
                    ColumnStochastic (l ∷ []) H → H l l ≡ 1#
  singleton-rigid H l stochastic =
    trans (sym (+-identityʳ (H l l))) (stochastic l)

  -- ...and its mixing step is the identity mapping on the stream.
  singleton-identity : ∀ (H : Mix) (l : Lane) (x : Stream) →
                       ColumnStochastic (l ∷ []) H →
                       apply (l ∷ []) H x l ≡ x l
  singleton-identity H l x stochastic =
    trans (+-identityʳ (H l l * x l))
      (trans (cong (_* x l) (singleton-rigid H l stochastic))
        (*-identityˡ (x l)))
