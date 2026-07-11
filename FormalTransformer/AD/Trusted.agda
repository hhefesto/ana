{-# OPTIONS --safe --without-K #-}

module FormalTransformer.AD.Trusted where

open import Level using (Level; suc)
open import Relation.Binary.PropositionalEquality using (_≡_)

-- Trusted means analytic validity is supplied explicitly by a backend/model.
record TrustedAnalytic {ℓ : Level} (Scalar : Set ℓ) : Set (suc ℓ) where
  field
    _HasDerivative_ : (Scalar → Scalar) → (Scalar → Scalar) → Set ℓ
    _*_ : Scalar → Scalar → Scalar
    rsqrtScale : Scalar
    exp rsqrt : Scalar → Scalar
    exp′ rsqrt′ : Scalar → Scalar
    trusted-exp-derivative : exp HasDerivative exp′
    trusted-rsqrt-derivative : rsqrt HasDerivative rsqrt′
    trusted-exp′-law : ∀ x → exp′ x ≡ exp x
    trusted-rsqrt′-law : ∀ x →
      rsqrt′ x ≡ ((rsqrtScale * rsqrt x) * rsqrt x) * rsqrt x
