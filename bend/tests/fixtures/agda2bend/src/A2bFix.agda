{-# OPTIONS --without-K --safe #-}
-- agda2bend's fixture for indexed families, absurd clauses, Data kinds and eta records
-- (bend/tests/agda2bend.bend); export it with agda-export into the parent
-- directory, which holds Agda.Builtin.Bool's and Agda.Primitive's exports.
module A2bFix where

open import Agda.Builtin.Bool

data Void : Set where

record Wrap (A : Set) : Set where
  constructor wrap
  field unwrap : A

-- empty because its one field is (as the stdlib's ⊥ = Irrelevant Empty)
Bot : Set
Bot = Wrap Void

elim : {W : Set} → Bot → W
elim ()

Ite : Bool → Set → Set → Set
Ite true  x y = x
Ite false x y = y

-- an indexed family (the stdlib's Reflects)
data Refl (A : Set) : Bool → Set where
  ofy : A → Refl A true
  ofn : (A → Bot) → Refl A false

invert : {A : Set} {b : Bool} → Refl A b → Ite b A (A → Bot)
invert (ofy a) = a
invert (ofn n) = n

of : {A : Set} (b : Bool) → Ite b A (A → Bot) → Refl A b
of true  a = ofy a
of false n = ofn n

-- a value of a type parameter used twice (-A: Data)
twice : {A : Set} → (A → A → A) → A → A
twice f x = f x x

-- a record with eta (as Σ): a type-valued function that matches it is
-- written with its projections (Bend has no record eta), a function with a
-- value keeps its match, and a header that applies one is unfolded there
record Pair (A B : Set) : Set where
  constructor _,_
  field
    fst : A
    snd : B
open Pair

Both : {A B : Set} → (A → Set) → (B → Set) → Pair A B → Set
Both P Q (a , b) = Pair (P a) (Q b)

apply : {A B : Set} → Pair (A → B) A → B
apply (f , a) = f a

applied : {A B : Set} {P : A → Set} {Q : B → Set} (x : Pair (A → B) A) →
          Both (λ f → (a : A) → P a → Q (f a)) P x → Q (apply x)
applied x (k , p) = k (snd x) p
