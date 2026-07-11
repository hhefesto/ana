{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Enriched.Bradley where

open import Level using (Level; _⊔_)
open import Data.Bool using (Bool)
open import Data.List using (List; []; _++_; length)
open import Data.Nat using (ℕ; _≤_)
open import Data.List.Properties using (++-assoc; ++-identityʳ)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; sym; trans; cong)

open import FormalTransformer.Foundation.Algebra
open import FormalTransformer.Language.Autoregressive

record Prefix {a} {A : Set a} (xs ys : List A) : Set a where
  constructor prefix
  field
    extension : List A
    extends : ys ≡ xs ++ extension

identityPrefix : ∀ {a} {A : Set a} (xs : List A) → Prefix xs xs
identityPrefix xs = prefix [] (sym (++-identityʳ xs))

composePrefix : ∀ {a} {A : Set a} {xs ys zs : List A} →
                Prefix xs ys → Prefix ys zs → Prefix xs zs
composePrefix (prefix us p) (prefix vs q) =
  prefix (us ++ vs) (trans q (trans (cong (_++ vs) p) (++-assoc _ us vs)))

-- Objects explicitly inhabit a finite cutoff and record whether they terminate.
record PrefixObject {a} (A : Set a) (cutoff : ℕ) : Set a where
  constructor object
  field
    tokens : List A
    within-cutoff : length tokens ≤ cutoff
    terminal : Bool

record BoundedPrefix {a} {A : Set a} {cutoff : ℕ}
                     (xs ys : PrefixObject A cutoff) : Set a where
  constructor bounded
  open PrefixObject
  field
    underlying : Prefix (tokens xs) (tokens ys)

identityBounded : ∀ {a} {A : Set a} {cutoff} (x : PrefixObject A cutoff) →
                  BoundedPrefix x x
identityBounded x = bounded (identityPrefix (PrefixObject.tokens x))

composeBounded : ∀ {a} {A : Set a} {cutoff}
                 {x y z : PrefixObject A cutoff} →
                 BoundedPrefix x y → BoundedPrefix y z → BoundedPrefix x z
composeBounded (bounded p) (bounded q) = bounded (composePrefix p q)

module _ {a w} {A : Set a} (R : Semiring w)
         (M : StateAlgebra A (Semiring.Carrier R)) where
  open Semiring R
  open StateAlgebra M
  open Prefix
  open BoundedPrefix

  -- The evidence supplies the extension; no arbitrary substring equality is used.
  prefixHom : ∀ {cutoff} {xs ys : PrefixObject A cutoff} →
              State → BoundedPrefix xs ys → Carrier
  prefixHom q p = pathWeight R M q (extension (underlying p))

  identity-hom : ∀ q {cutoff} (x : PrefixObject A cutoff) →
                 prefixHom q (identityBounded x) ≡ 1#
  identity-hom q x = refl

  composition-hom : ∀ q {cutoff} {x y z : PrefixObject A cutoff}
    (p : BoundedPrefix x y) (r : BoundedPrefix y z) →
    prefixHom q (composeBounded p r) ≡
    prefixHom q p *
    prefixHom (run R M q (extension (underlying p))) r
  composition-hom q p r =
    factorization R M q (extension (underlying p)) (extension (underlying r))
