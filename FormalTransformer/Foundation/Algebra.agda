{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Foundation.Algebra where

open import Level using (Level; _⊔_; suc)
open import Relation.Binary.PropositionalEquality using (_≡_)

-- Status: deliberately minimal law-carrying structures used by later modules.
record Semiring (ℓ : Level) : Set (suc ℓ) where
  infixl 6 _+_
  infixl 7 _*_
  field
    Carrier : Set ℓ
    0# 1# : Carrier
    _+_ _*_ : Carrier → Carrier → Carrier
    +-assoc : ∀ x y z → (x + y) + z ≡ x + (y + z)
    +-comm : ∀ x y → x + y ≡ y + x
    +-identityˡ : ∀ x → 0# + x ≡ x
    *-assoc : ∀ x y z → (x * y) * z ≡ x * (y * z)
    *-identityˡ : ∀ x → 1# * x ≡ x
    *-identityʳ : ∀ x → x * 1# ≡ x
    distribˡ : ∀ x y z → x * (y + z) ≡ (x * y) + (x * z)
    distribʳ : ∀ x y z → (x + y) * z ≡ (x * z) + (y * z)
    zeroˡ : ∀ x → 0# * x ≡ 0#
    zeroʳ : ∀ x → x * 0# ≡ 0#

record OrderedMultiplicative (ℓ : Level) : Set (suc ℓ) where
  infix 4 _≤_
  infixl 7 _∙_
  field
    Carrier : Set ℓ
    ε : Carrier
    _∙_ : Carrier → Carrier → Carrier
    _≤_ : Carrier → Carrier → Set ℓ
    ≤-refl : ∀ {x} → x ≤ x
    ≤-trans : ∀ {x y z} → x ≤ y → y ≤ z → x ≤ z
    ∙-assoc : ∀ x y z → (x ∙ y) ∙ z ≡ x ∙ (y ∙ z)
    ∙-identityˡ : ∀ x → ε ∙ x ≡ x
    ∙-identityʳ : ∀ x → x ∙ ε ≡ x
    ∙-mono : ∀ {x x′ y y′} → x ≤ x′ → y ≤ y′ → (x ∙ y) ≤ (x′ ∙ y′)

record AdditiveMonoid (ℓ : Level) : Set (suc ℓ) where
  infixl 6 _+_
  field
    Carrier : Set ℓ
    zero : Carrier
    _+_ : Carrier → Carrier → Carrier
    +-assoc : ∀ x y z → (x + y) + z ≡ x + (y + z)
    +-comm : ∀ x y → x + y ≡ y + x
    +-identityˡ : ∀ x → zero + x ≡ x
