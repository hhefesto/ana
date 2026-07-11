{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Foundation.Fold where

open import Level using (Level)
open import Data.List using (List; []; _∷_; _++_; foldl)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)

-- Status: proved for the standard left fold, without algebraic assumptions.
foldl-++ : ∀ {a b} {A : Set a} {B : Set b}
           (f : B → A → B) (z : B) (xs ys : List A) →
           foldl f z (xs ++ ys) ≡ foldl f (foldl f z xs) ys
foldl-++ f z []       ys = refl
foldl-++ f z (x ∷ xs) ys = foldl-++ f (f z x) xs ys
