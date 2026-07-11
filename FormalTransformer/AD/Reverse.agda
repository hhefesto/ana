{-# OPTIONS --safe --without-K #-}

module FormalTransformer.AD.Reverse where

open import Level using (Level; _⊔_; suc)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Relation.Binary.PropositionalEquality
open ≡-Reasoning

open import FormalTransformer.Foundation.Algebra

record AdditiveMap {a b} (A : AdditiveMonoid a) (B : AdditiveMonoid b) : Set (a ⊔ b) where
  private
    module A = AdditiveMonoid A
    module B = AdditiveMonoid B
  field
    apply : A.Carrier → B.Carrier
    preserves-zero : apply A.zero ≡ B.zero
    preserves-+ : ∀ x y → apply (A._+_ x y) ≡ B._+_ (apply x) (apply y)

-- A dual map reverses the direction of its primal map.
Dual : ∀ {a b} → AdditiveMonoid a → AdditiveMonoid b → Set (a ⊔ b)
Dual A B = AdditiveMap B A

identityMap : ∀ {a} (A : AdditiveMonoid a) → AdditiveMap A A
identityMap A = record
  { apply = λ x → x
  ; preserves-zero = refl
  ; preserves-+ = λ x y → refl
  }

_∘A_ : ∀ {a b c} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
       {C : AdditiveMonoid c} → AdditiveMap B C → AdditiveMap A B → AdditiveMap A C
g ∘A f = record
  { apply = λ x → AdditiveMap.apply g (AdditiveMap.apply f x)
  ; preserves-zero = trans (cong (AdditiveMap.apply g) (AdditiveMap.preserves-zero f))
                           (AdditiveMap.preserves-zero g)
  ; preserves-+ = λ x y →
      trans (cong (AdditiveMap.apply g) (AdditiveMap.preserves-+ f x y))
            (AdditiveMap.preserves-+ g (AdditiveMap.apply f x) (AdditiveMap.apply f y))
  }

productMonoid : ∀ {a b} → AdditiveMonoid a → AdditiveMonoid b → AdditiveMonoid (a ⊔ b)
productMonoid A B = record
  { Carrier = AdditiveMonoid.Carrier A × AdditiveMonoid.Carrier B
  ; zero = AdditiveMonoid.zero A , AdditiveMonoid.zero B
  ; _+_ = λ p q →
      AdditiveMonoid._+_ A (proj₁ p) (proj₁ q) ,
      AdditiveMonoid._+_ B (proj₂ p) (proj₂ q)
  ; +-assoc = λ x y z → cong₂ _,_ (AdditiveMonoid.+-assoc A _ _ _)
                                      (AdditiveMonoid.+-assoc B _ _ _)
  ; +-comm = λ x y → cong₂ _,_ (AdditiveMonoid.+-comm A _ _)
                                  (AdditiveMonoid.+-comm B _ _)
  ; +-identityˡ = λ x → cong₂ _,_ (AdditiveMonoid.+-identityˡ A _)
                                       (AdditiveMonoid.+-identityˡ B _)
  }

interchange : ∀ {a} (A : AdditiveMonoid a) (x y z t : AdditiveMonoid.Carrier A) →
  AdditiveMonoid._+_ A (AdditiveMonoid._+_ A x y) (AdditiveMonoid._+_ A z t) ≡
  AdditiveMonoid._+_ A (AdditiveMonoid._+_ A x z) (AdditiveMonoid._+_ A y t)
interchange A x y z t =
  let open AdditiveMonoid A in
  begin
    (x + y) + (z + t) ≡⟨ +-assoc x y (z + t) ⟩
    x + (y + (z + t)) ≡⟨ cong (x +_) (sym (+-assoc y z t)) ⟩
    x + ((y + z) + t) ≡⟨ cong (λ u → x + (u + t)) (+-comm y z) ⟩
    x + ((z + y) + t) ≡⟨ cong (x +_) (+-assoc z y t) ⟩
    x + (z + (y + t)) ≡⟨ sym (+-assoc x z (y + t)) ⟩
    (x + z) + (y + t) ∎

sumPullbacks : ∀ {a b c} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
               {C : AdditiveMonoid c} →
               AdditiveMap B A → AdditiveMap C A → AdditiveMap (productMonoid B C) A
sumPullbacks {A = A} f g = record
  { apply = λ p → AdditiveMonoid._+_ A (AdditiveMap.apply f (proj₁ p))
                                      (AdditiveMap.apply g (proj₂ p))
  ; preserves-zero =
      trans (cong₂ (AdditiveMonoid._+_ A) (AdditiveMap.preserves-zero f)
                    (AdditiveMap.preserves-zero g))
            (AdditiveMonoid.+-identityˡ A (AdditiveMonoid.zero A))
  ; preserves-+ = λ x y →
      trans (cong₂ (AdditiveMonoid._+_ A)
                   (AdditiveMap.preserves-+ f (proj₁ x) (proj₁ y))
                   (AdditiveMap.preserves-+ g (proj₂ x) (proj₂ y)))
            (interchange A _ _ _ _)
  }

-- An augmented reverse derivative returns a primal value and its dual pullback.
D : ∀ {a b} → AdditiveMonoid a → AdditiveMonoid b → Set (a ⊔ b)
D A B = AdditiveMonoid.Carrier A → AdditiveMonoid.Carrier B × Dual A B

identityD : ∀ {a} (A : AdditiveMonoid a) → D A A
identityD A x = x , identityMap A

composeD : ∀ {a b c} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
           {C : AdditiveMonoid c} → D B C → D A B → D A C
composeD g f x with f x
... | y , f* with g y
...   | z , g* = z , (f* ∘A g*)

pairD : ∀ {a b c} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
        {C : AdditiveMonoid c} → D A B → D A C → D A (productMonoid B C)
pairD f g x with f x | g x
... | y , f* | z , g* = (y , z) , sumPullbacks f* g*

identity-chain : ∀ {a} (A : AdditiveMonoid a) x → proj₁ (identityD A x) ≡ x
identity-chain A x = refl

identity-pullback : ∀ {a} (A : AdditiveMonoid a) x dx →
  AdditiveMap.apply (proj₂ (identityD A x)) dx ≡ dx
identity-pullback A x dx = refl

composition-primal : ∀ {a b c} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  {C : AdditiveMonoid c} (f : D A B) (g : D B C) x →
  proj₁ (composeD g f x) ≡ proj₁ (g (proj₁ (f x)))
composition-primal f g x with f x | g (proj₁ (f x))
... | y , f* | z , g* = refl

composition-chain : ∀ {a b c} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  {C : AdditiveMonoid c} (f : D A B) (g : D B C) x →
  AdditiveMap.apply (proj₂ (composeD g f x)) ≡
  (λ dz → AdditiveMap.apply (proj₂ (f x)) (AdditiveMap.apply (proj₂ (g (proj₁ (f x)))) dz))
composition-chain f g x with f x | g (proj₁ (f x))
... | y , f* | z , g* = refl

pairing-primal : ∀ {a b c} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  {C : AdditiveMonoid c} (f : D A B) (g : D A C) x →
  proj₁ (pairD f g x) ≡ (proj₁ (f x) , proj₁ (g x))
pairing-primal f g x with f x | g x
... | y , f* | z , g* = refl

pairing-chain : ∀ {a b c} {A : AdditiveMonoid a} {B : AdditiveMonoid b}
  {C : AdditiveMonoid c} (f : D A B) (g : D A C) x db dc →
  AdditiveMap.apply (proj₂ (pairD f g x)) (db , dc) ≡
  AdditiveMonoid._+_ A (AdditiveMap.apply (proj₂ (f x)) db)
                        (AdditiveMap.apply (proj₂ (g x)) dc)
pairing-chain f g x db dc with f x | g x
... | y , f* | z , g* = refl
