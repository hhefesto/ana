{-# OPTIONS --safe --without-K --guardedness #-}

module FormalTransformer.Language.Trie where

open import Level using (Level; _⊔_)
open import Data.List using (List; []; _∷_; _++_; foldl)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; sym; trans)

open import FormalTransformer.Foundation.Fold using (foldl-++)
open import FormalTransformer.Language.Weighted using (Language; nu; delta)

-- Elliott's Automatic presentation: a weighted language given by its two
-- canonical observations, empty-word weight and one-token residual.
record Trie {a w : Level} (A : Set a) (W : Set w) : Set (a ⊔ w) where
  coinductive
  field
    nuT    : W
    deltaT : A → Trie A W
open Trie public

advanceT : ∀ {a w} {A : Set a} {W : Set w} → Trie A W → List A → Trie A W
advanceT = foldl deltaT

advanceT-append : ∀ {a w} {A : Set a} {W : Set w}
                  (t : Trie A W) (xs ys : List A) →
                  advanceT (advanceT t xs) ys ≡ advanceT t (xs ++ ys)
advanceT-append t xs ys = sym (foldl-++ deltaT t xs ys)

toLanguage : ∀ {a w} {A : Set a} {W : Set w} → Trie A W → Language A W
toLanguage t []       = nuT t
toLanguage t (x ∷ xs) = toLanguage (deltaT t x) xs

fromLanguage : ∀ {a w} {A : Set a} {W : Set w} → Language A W → Trie A W
nuT    (fromLanguage L)   = nu L
deltaT (fromLanguage L) x = fromLanguage (delta L x)

-- Status: proved; the cons case is the same reduction as `determination`.
to-from : ∀ {a w} {A : Set a} {W : Set w}
          (L : Language A W) (xs : List A) →
          toLanguage (fromLanguage L) xs ≡ L xs
to-from L []       = refl
to-from L (x ∷ xs) = to-from (delta L x) xs

-- Propositional equality between coinductive values is too strong under
-- --safe; bisimulation is the intended notion of trie equality.
record _≈_ {a w : Level} {A : Set a} {W : Set w}
           (s t : Trie A W) : Set (a ⊔ w) where
  coinductive
  field
    nu-≈    : nuT s ≡ nuT t
    delta-≈ : ∀ x → deltaT s x ≈ deltaT t x
open _≈_ public

≈-refl : ∀ {a w} {A : Set a} {W : Set w} {t : Trie A W} → t ≈ t
nu-≈    ≈-refl   = refl
delta-≈ ≈-refl x = ≈-refl

≈-sym : ∀ {a w} {A : Set a} {W : Set w} {s t : Trie A W} → s ≈ t → t ≈ s
nu-≈    (≈-sym p)   = sym (nu-≈ p)
delta-≈ (≈-sym p) x = ≈-sym (delta-≈ p x)

≈-trans : ∀ {a w} {A : Set a} {W : Set w} {s t u : Trie A W} →
          s ≈ t → t ≈ u → s ≈ u
nu-≈    (≈-trans p q)   = trans (nu-≈ p) (nu-≈ q)
delta-≈ (≈-trans p q) x = ≈-trans (delta-≈ p x) (delta-≈ q x)

-- Bisimulation coincides with extensional language equality.
≈-sound : ∀ {a w} {A : Set a} {W : Set w} {s t : Trie A W} →
          s ≈ t → ∀ xs → toLanguage s xs ≡ toLanguage t xs
≈-sound p []       = nu-≈ p
≈-sound p (x ∷ xs) = ≈-sound (delta-≈ p x) xs

≈-complete : ∀ {a w} {A : Set a} {W : Set w} {s t : Trie A W} →
             (∀ xs → toLanguage s xs ≡ toLanguage t xs) → s ≈ t
nu-≈    (≈-complete h)   = h []
delta-≈ (≈-complete h) x = ≈-complete (λ xs → h (x ∷ xs))

-- Status: proved up to bisimulation, the strongest honest statement here.
from-to : ∀ {a w} {A : Set a} {W : Set w}
          (t : Trie A W) → fromLanguage (toLanguage t) ≈ t
nu-≈    (from-to t)   = refl
delta-≈ (from-to t) x = from-to (deltaT t x)
