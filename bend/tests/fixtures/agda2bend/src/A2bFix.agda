{-# OPTIONS --without-K --safe #-}
-- agda2bend's fixture for indexed families, absurd clauses and Data kinds
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
