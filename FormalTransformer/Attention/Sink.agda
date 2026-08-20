{-# OPTIONS --safe --without-K #-}

-- Attention sinks, as algebra: softmax₁ is ordinary softmax over the
-- vocabulary extended by one element that carries no value.
--
-- The "off-by-one" softmax  softmax₁(x)ᵢ = e^{xᵢ} / (1 + Σⱼ e^{xⱼ})  (Evan
-- Miller; StreamingLLM's learned-sink variant replaces the 1 by e^s for a
-- learned per-head logit s) is exactly softmax over V ⊎ {∗} with the
-- adjoined element's weight fixed — e⁰ = 1 becomes "adjoin unit mass" —
-- restricted back to V.  A head equipped with a sink can attend to
-- *nothing*: its token weights form a SUBdistribution whose deficiency is
-- precisely the sink's share.  Adjoining ∗ restores the total-mass law
-- (Language/Autoregressive.agda's `total-mass ≡ 1#` discipline): the sink
-- is where the conserved mass goes.
--
-- As everywhere in this spec's decoding corner (Language/Decoding.agda),
-- weights are naturals — the positive exponential weights put over a
-- common denominator — so every statement is finite algebra with the float
-- exp isolated outside the spec.  `withSink s w` is the extended measure;
-- restriction to V is literally "the tail of the list".
--
--   sink-total          extended mass = sink mass + token mass
--   sink-deficiency     what restriction to V loses is exactly s
--   sink-conservative   s = 0 recovers ordinary softmax (mass-identical)
--   token-mass-bounded  token mass never exceeds the extended total
--
-- The implementation contract (backend milestone: per-head learned sink
-- logits on the softmax layers): compute softmax over scores ++ [sink] and
-- drop the sink's weight — i.e. realize exactly this restriction.  Any
-- other phrasing (e.g. adding a constant to the denominator) must be
-- justified as equal to this one.

module FormalTransformer.Attention.Sink where

open import Data.List using (List; []; _∷_)
open import Data.Nat using (ℕ; zero; _+_; _∸_; _≤_)
open import Data.Nat.Properties using (m+n∸n≡m; m≤n+m)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)

open import FormalTransformer.Language.Decoding using (mass)

-- Adjoin the sink's mass to the token weights: the measure over V ⊎ {∗},
-- with ∗ listed first (it carries no value vector, only mass).
withSink : ℕ → List ℕ → List ℕ
withSink s w = s ∷ w

-- Total mass over the extended support splits as sink + tokens.
sink-total : ∀ s w → mass (withSink s w) ≡ s + mass w
sink-total s w = refl

-- Restriction to V is deficient by exactly the sink's mass: the token
-- weights are a subdistribution, and softmax₁'s "missing" 1/(1+Z) is this
-- deficiency stated over the common denominator.
sink-deficiency : ∀ s w → mass (withSink s w) ∸ mass w ≡ s
sink-deficiency s w = m+n∸n≡m s (mass w)

-- Conservativity: a zero sink is ordinary softmax.
sink-conservative : ∀ w → mass (withSink zero w) ≡ mass w
sink-conservative w = refl

-- Token mass never exceeds the extended total (equality iff the sink is
-- empty): a sink head can only shed attention mass, never mint it.
token-mass-bounded : ∀ s w → mass w ≤ mass (withSink s w)
token-mass-bounded s w = m≤n+m (mass w) s
