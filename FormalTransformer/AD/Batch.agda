{-# OPTIONS --safe --without-K #-}

module FormalTransformer.AD.Batch where

open import Data.List using (List; []; _∷_; map)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Relation.Binary.PropositionalEquality

open import FormalTransformer.Foundation.Algebra
open import FormalTransformer.AD.Reverse

-- Pointwise sum of additive maps sharing a source; closure under
-- preserves-+ is the interchange law already proved in AD.Reverse.
_+M_ : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b} →
       AdditiveMap A B → AdditiveMap A B → AdditiveMap A B
_+M_ {B = B} f g = record
  { apply = λ x → AdditiveMonoid._+_ B (AdditiveMap.apply f x)
                                       (AdditiveMap.apply g x)
  ; preserves-zero =
      trans (cong₂ (AdditiveMonoid._+_ B)
                   (AdditiveMap.preserves-zero f)
                   (AdditiveMap.preserves-zero g))
            (AdditiveMonoid.+-identityˡ B (AdditiveMonoid.zero B))
  ; preserves-+ = λ x y →
      trans (cong₂ (AdditiveMonoid._+_ B)
                   (AdditiveMap.preserves-+ f x y)
                   (AdditiveMap.preserves-+ g x y))
            (interchange B _ _ _ _)
  }

zeroMap : ∀ {a b} (A : AdditiveMonoid a) (B : AdditiveMonoid b) →
          AdditiveMap A B
zeroMap A B = record
  { apply = λ _ → AdditiveMonoid.zero B
  ; preserves-zero = refl
  ; preserves-+ = λ _ _ →
      sym (AdditiveMonoid.+-identityˡ B (AdditiveMonoid.zero B))
  }

-- The reverse derivative of addition: primal sum, pullback the diagonal.
plusD : ∀ {b} (B : AdditiveMonoid b) → D (productMonoid B B) B
plusD B p = AdditiveMonoid._+_ B (proj₁ p) (proj₂ p) , record
  { apply = λ db → db , db
  ; preserves-zero = refl
  ; preserves-+ = λ _ _ → refl
  }

-- Sum of two loss maps: pullbacks of the SAME cotangent accumulate into
-- the parameter monoid.  This is the gradient-buffer addition.
addD : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b} →
       D A B → D A B → D A B
addD {B = B} f g x =
  AdditiveMonoid._+_ B (proj₁ (f x)) (proj₁ (g x)) ,
  (proj₂ (f x) +M proj₂ (g x))

zeroD : ∀ {a b} (A : AdditiveMonoid a) (B : AdditiveMonoid b) → D A B
zeroD A B x = AdditiveMonoid.zero B , zeroMap B A

addD-primal : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  (f g : D A B) x →
  proj₁ (addD f g x) ≡ AdditiveMonoid._+_ B (proj₁ (f x)) (proj₁ (g x))
addD-primal f g x = refl

addD-pullback : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  (f g : D A B) x db →
  AdditiveMap.apply (proj₂ (addD f g x)) db ≡
  AdditiveMonoid._+_ A (AdditiveMap.apply (proj₂ (f x)) db)
                       (AdditiveMap.apply (proj₂ (g x)) db)
addD-pullback f g x db = refl

-- addD is not ad hoc: it factors through the proved pairD and plusD.
addD-factor-primal : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  (f g : D A B) x →
  proj₁ (addD f g x) ≡ proj₁ (composeD (plusD B) (pairD f g) x)
addD-factor-primal f g x with f x | g x
... | y , f* | z , g* = refl

addD-factor-pullback : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  (f g : D A B) x db →
  AdditiveMap.apply (proj₂ (addD f g x)) db ≡
  AdditiveMap.apply (proj₂ (composeD (plusD B) (pairD f g) x)) db
addD-factor-pullback f g x db with f x | g x
... | y , f* | z , g* = refl

listSumM : ∀ {b} (B : AdditiveMonoid b) →
           List (AdditiveMonoid.Carrier B) → AdditiveMonoid.Carrier B
listSumM B []       = AdditiveMonoid.zero B
listSumM B (x ∷ xs) = AdditiveMonoid._+_ B x (listSumM B xs)

batchD : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b} →
         List (D A B) → D A B
batchD {A = A} {B = B} []       = zeroD A B
batchD                 (f ∷ fs) = addD f (batchD fs)

batch-primal : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  (fs : List (D A B)) x →
  proj₁ (batchD fs x) ≡ listSumM B (map (λ f → proj₁ (f x)) fs)
batch-primal          []       x = refl
batch-primal {B = B} (f ∷ fs) x =
  cong (AdditiveMonoid._+_ B (proj₁ (f x))) (batch-primal fs x)

-- The micro-batch theorem: the pullback of the summed loss is the sum of
-- the per-microbatch pullbacks of one shared cotangent.
batch-pullback : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  (fs : List (D A B)) x db →
  AdditiveMap.apply (proj₂ (batchD fs x)) db ≡
  listSumM A (map (λ f → AdditiveMap.apply (proj₂ (f x)) db) fs)
batch-pullback          []       x db = refl
batch-pullback {A = A} (f ∷ fs) x db =
  cong (AdditiveMonoid._+_ A (AdditiveMap.apply (proj₂ (f x)) db))
       (batch-pullback fs x db)

-- Mean loss: the scaling arrives as an additive map that is its own
-- pullback.  Self-duality is an explicit assumption of the caller, true
-- of multiplication by a fixed scalar such as 1/n.
scaleD : ∀ {b} {B : AdditiveMonoid b} → AdditiveMap B B → D B B
scaleD σ y = AdditiveMap.apply σ y , σ

meanD : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b} →
        AdditiveMap B B → List (D A B) → D A B
meanD σ fs = composeD (scaleD σ) (batchD fs)

mean-pullback : ∀ {a b} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  (σ : AdditiveMap B B) (fs : List (D A B)) x db →
  AdditiveMap.apply (proj₂ (meanD σ fs x)) db ≡
  listSumM A (map (λ f → AdditiveMap.apply (proj₂ (f x))
                            (AdditiveMap.apply σ db)) fs)
mean-pullback σ fs x db =
  trans (cong (λ h → h db) (composition-chain (batchD fs) (scaleD σ) x))
        (batch-pullback fs x (AdditiveMap.apply σ db))
