{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Language.Weighted where

open import Level using (_⊔_)
open import Data.List using (List; []; _∷_; _++_; foldl)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)

Language : ∀ {a w} → Set a → Set w → Set (a ⊔ w)
Language A W = List A → W

nu : ∀ {a w} {A : Set a} {W : Set w} → Language A W → W
nu L = L []

residual : ∀ {a w} {A : Set a} {W : Set w} →
           Language A W → List A → Language A W
residual L prefix suffix = L (prefix ++ suffix)

delta : ∀ {a w} {A : Set a} {W : Set w} →
        Language A W → A → Language A W
delta L token = residual L (token ∷ [])

residual-empty : ∀ {a w} {A : Set a} {W : Set w}
                 (L : Language A W) → residual L [] ≡ L
residual-empty L = refl

residual-append : ∀ {a w} {A : Set a} {W : Set w}
                  (L : Language A W) (xs ys : List A) →
                  residual (residual L xs) ys ≡ residual L (xs ++ ys)
residual-append L []       ys = refl
residual-append L (x ∷ xs) ys = residual-append (residual L (x ∷ [])) xs ys

advance : ∀ {a w} {A : Set a} {W : Set w} → Language A W → A → Language A W
advance = delta

scoreByFold : ∀ {a w} {A : Set a} {W : Set w} → Language A W → List A → W
scoreByFold L xs = nu (foldl advance L xs)

-- Status: every weighted language is determined by nu and singleton residuals.
determination : ∀ {a w} {A : Set a} {W : Set w}
                (L : Language A W) (xs : List A) → scoreByFold L xs ≡ L xs
determination L []       = refl
determination L (x ∷ xs) = determination (advance L x) xs
