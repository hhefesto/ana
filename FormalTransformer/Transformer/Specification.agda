{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Transformer.Specification where

open import Level using (Level; suc)
open import Data.Bool using (Bool; true; false; if_then_else_)
open import Data.Nat using (ℕ; _≤_; _*_; _+_; _≡ᵇ_)
open import Data.Nat.DivMod using (_%_)
open import Data.Fin using (Fin; toℕ)
open import Data.List using (List; []; _∷_)

open import FormalTransformer.Transformer.Config

private
  shape1 : ℕ → List ℕ
  shape1 m = m ∷ []

  shape2 : ℕ → ℕ → List ℕ
  shape2 m n = m ∷ n ∷ []

-- The hybrid attention rule as data: every fourth layer is softmax full
-- attention (no positional encoding), the rest are gated linear attention
-- whose data-dependent gates carry position.  The GLA semantics is stated
-- and proved in FormalTransformer.Attention.Linear; softmax attention has
-- no bounded-state presentation and remains a signature here.
data LayerKind : Set where
  glaKind softmaxKind : LayerKind

kindOf : ℕ → LayerKind
kindOf i = if i % 4 ≡ᵇ 3 then softmaxKind else glaKind

-- Status: signatures only; tensor semantics and calculus belong to an implementation.
record TensorPrimitives (c : Config) (ℓ : Level) : Set (suc ℓ) where
  field
    Scalar : Set ℓ
    Tensor : List ℕ → Set ℓ
    preRMSNorm : Tensor (shape1 (model c)) → Tensor (shape1 (model c)) →
                 Tensor (shape1 (model c))
    causalAttention : (n : ℕ) → n ≤ context c →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 n (model c)) → Tensor (shape2 n (model c))
    -- Query, key, value, gate projection, output; the implementation must
    -- satisfy the recurrent≡parallel law of Attention.Linear.
    glaAttention : (n : ℕ) → n ≤ context c →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 (model c) (model c)) →
      Tensor (shape2 n (model c)) → Tensor (shape2 n (model c))
    SwiGLU :
      Tensor (shape2 (model c) (ff c)) →
      Tensor (shape2 (model c) (ff c)) →
      Tensor (shape2 (ff c) (model c)) →
      Tensor (shape1 (model c)) → Tensor (shape1 (model c))
    tiedUnembedding : Tensor (shape2 (vocab c) (model c)) →
                      Tensor (shape1 (model c)) → Tensor (shape1 (vocab c))
    crossEntropy : Tensor (shape1 (vocab c)) → Fin (vocab c) → Scalar

record SoftmaxLayer {ℓ} (c : Config) (T : List ℕ → Set ℓ) : Set ℓ where
  field
    query key value output : T (shape2 (model c) (model c))
    gate up : T (shape2 (model c) (ff c))
    down : T (shape2 (ff c) (model c))
    attentionNorm feedForwardNorm : T (shape1 (model c))

record GlaLayer {ℓ} (c : Config) (T : List ℕ → Set ℓ) : Set ℓ where
  field
    query key value output gateProjection : T (shape2 (model c) (model c))
    gate up : T (shape2 (model c) (ff c))
    down : T (shape2 (ff c) (model c))
    attentionNorm feedForwardNorm : T (shape1 (model c))

LayerFor : ∀ {ℓ} → Config → (List ℕ → Set ℓ) → LayerKind → Set ℓ
LayerFor c T glaKind = GlaLayer c T
LayerFor c T softmaxKind = SoftmaxLayer c T

record ModelParameters {ℓ} (c : Config) (T : List ℕ → Set ℓ) : Set ℓ where
  field
    -- The same table is consumed by tiedUnembedding; it is not counted twice.
    tokenEmbedding : T (shape2 (vocab c) (model c))
    -- Each block's parameter record is determined by its index's kind, so a
    -- gate projection cannot be allocated for a softmax layer or omitted
    -- from a GLA layer.
    blocks : (i : Fin (layers c)) → LayerFor c T (kindOf (toℕ i))
    finalNorm : T (shape1 (model c))
