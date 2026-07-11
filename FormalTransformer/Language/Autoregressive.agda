{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Language.Autoregressive where

open import Level using (Level; _⊔_; suc)
open import Data.List using (List; []; _∷_; _++_; map)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; cong; sym)

open import FormalTransformer.Foundation.Algebra
open import FormalTransformer.Language.Weighted using (Language; residual)

listSum : ∀ {w} (R : Semiring w) → List (Semiring.Carrier R) → Semiring.Carrier R
listSum R []       = Semiring.0# R
listSum R (x ∷ xs) = Semiring._+_ R x (listSum R xs)

-- The mass law is finite and ranges exactly over the supplied vocabulary list.
record Distribution {a w : Level} {A : Set a}
                    (R : Semiring w) (vocabulary : List A) : Set (a ⊔ w) where
  open Semiring R
  field
    terminalWeight : Carrier
    tokenWeight : A → Carrier
    total-mass : terminalWeight + listSum R (map tokenWeight vocabulary) ≡ 1#

record StateAlgebra {a w : Level} (A : Set a) (W : Set w) : Set (suc (a ⊔ w)) where
  field
    State : Set (a ⊔ w)
    out : State → W
    step : State → A → W × State

record ProperStateAlgebra {a w : Level} {A : Set a}
                          (R : Semiring w) (vocabulary : List A) : Set (suc (a ⊔ w)) where
  open Semiring R
  field
    State : Set (a ⊔ w)
    out : State → Distribution R vocabulary
    step : State → A → Carrier × State
    token-agrees : ∀ q token →
      Distribution.tokenWeight (out q) token ≡ proj₁ (step q token)

forgetProper : ∀ {a w} {A : Set a} {R : Semiring w} {vocabulary : List A} →
               ProperStateAlgebra R vocabulary → StateAlgebra A (Semiring.Carrier R)
forgetProper P = record
  { State = ProperStateAlgebra.State P
  ; out = λ q → Distribution.terminalWeight (ProperStateAlgebra.out P q)
  ; step = ProperStateAlgebra.step P
  }

module _ {a w} {A : Set a} (R : Semiring w) (M : StateAlgebra A (Semiring.Carrier R)) where
  open Semiring R
  open StateAlgebra M

  run : State → List A → State
  run q []       = q
  run q (x ∷ xs) = run (proj₂ (step q x)) xs

  pathWeight : State → List A → Carrier
  pathWeight q []       = 1#
  pathWeight q (x ∷ xs) = proj₁ (step q x) * pathWeight (proj₂ (step q x)) xs

  run-append : ∀ q xs ys → run q (xs ++ ys) ≡ run (run q xs) ys
  run-append q []       ys = refl
  run-append q (x ∷ xs) ys = run-append (proj₂ (step q x)) xs ys

  factorization : ∀ q xs ys →
                  pathWeight q (xs ++ ys) ≡
                  pathWeight q xs * pathWeight (run q xs) ys
  factorization q []       ys = sym (*-identityˡ (pathWeight q ys))
  factorization q (x ∷ xs) ys =
    let wx = proj₁ (step q x)
        q′ = proj₂ (step q x)
    in
    Relation.Binary.PropositionalEquality.trans
      (cong (wx *_) (factorization q′ xs ys))
      (sym (*-assoc wx (pathWeight q′ xs) (pathWeight (run q′ xs) ys)))

  unnormalized : State → Language A Carrier
  unnormalized q xs = pathWeight q xs * out (run q xs)

  -- A residual is the reached continuation scaled by the consumed path.
  residual-continuation : ∀ q xs ys →
    residual (unnormalized q) xs ys ≡
    pathWeight q xs * unnormalized (run q xs) ys
  residual-continuation q xs ys
    rewrite run-append q xs ys | factorization q xs ys =
      *-assoc (pathWeight q xs) (pathWeight (run q xs) ys)
        (out (run (run q xs) ys))

-- Normalization is intentionally separate from the unnormalized state algebra.
record Normalization {a w : Level} (A : Set a) (W : Set w) : Set (suc (a ⊔ w)) where
  field
    normalize : Language A W → Language A W
