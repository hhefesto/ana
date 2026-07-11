{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Transformer.Specification where

open import Level using (Level; suc)
open import Data.Nat using (ℕ; _≤_; _*_; _+_)
open import Data.Fin using (Fin)
open import Data.List using (List; []; _∷_)
open import Data.Vec using (Vec)

open import FormalTransformer.Transformer.Config

private
  shape1 : ℕ → List ℕ
  shape1 m = m ∷ []

  shape2 : ℕ → ℕ → List ℕ
  shape2 m n = m ∷ n ∷ []

-- Status: signatures only; tensor semantics and calculus belong to an implementation.
record TensorPrimitives (c : Config) (ℓ : Level) : Set (suc ℓ) where
  field
    Scalar : Set ℓ
    Tensor : List ℕ → Set ℓ
    preRMSNorm : Tensor (shape1 (model c)) → Tensor (shape1 (model c)) →
                 Tensor (shape1 (model c))
    RoPE : Fin (context c) → Tensor (shape1 (model c)) →
           Tensor (shape1 (model c))
    causalAttention : (n : ℕ) → n ≤ context c →
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

record LayerParameters {ℓ} (c : Config) (T : List ℕ → Set ℓ) : Set ℓ where
  field
    query key value output : T (shape2 (model c) (model c))
    gate up : T (shape2 (model c) (ff c))
    down : T (shape2 (ff c) (model c))
    attentionNorm feedForwardNorm : T (shape1 (model c))

record ModelParameters {ℓ} (c : Config) (T : List ℕ → Set ℓ) : Set ℓ where
  field
    -- The same table is consumed by tiedUnembedding; it is not counted twice.
    tokenEmbedding : T (shape2 (vocab c) (model c))
    blocks : Vec (LayerParameters c T) (layers c)
    finalNorm : T (shape1 (model c))
