{-# OPTIONS --safe --without-K --guardedness #-}

module FormalTransformer.Language.AutoregressiveTrie where

open import Data.List using (List; []; _∷_)
open import Data.Product using (proj₁; proj₂)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; sym; trans; cong)

open import FormalTransformer.Foundation.Algebra using (Semiring)
open import FormalTransformer.Language.Weighted using (residual)
open import FormalTransformer.Language.Autoregressive
  using (StateAlgebra; run; pathWeight; unnormalized; residual-continuation)
open import FormalTransformer.Language.Trie

module _ {a w} {A : Set a} (R : Semiring w)
         (M : StateAlgebra A (Semiring.Carrier R)) where
  open Semiring R
  open StateAlgebra M

  -- The observation trie is the denotational KV cache: the state's entire
  -- observable future, presented by nu and delta alone.
  observationTrie : State → Trie A Carrier
  nuT    (observationTrie q)   = out q
  deltaT (observationTrie q) x = observationTrie (proj₂ (step q x))

  -- Incremental stepping equals whole-prefix evaluation, refl per step.
  observation-run : ∀ q xs →
    advanceT (observationTrie q) xs ≡ observationTrie (run R M q xs)
  observation-run q []       = refl
  observation-run q (x ∷ xs) = observation-run (proj₂ (step q x)) xs

  observation-denotes : ∀ q xs →
    toLanguage (observationTrie q) xs ≡ out (run R M q xs)
  observation-denotes q []       = refl
  observation-denotes q (x ∷ xs) = observation-denotes (proj₂ (step q x)) xs

  -- The weighted trie carries the consumed path weight as an accumulator.
  -- A corecursive call under _*_ would not be guarded; the accumulator
  -- keeps every copattern clause guarded.
  weightedTrie : Carrier → State → Trie A Carrier
  nuT    (weightedTrie c q)   = c * out q
  deltaT (weightedTrie c q) x =
    weightedTrie (c * proj₁ (step q x)) (proj₂ (step q x))

  stateTrie : State → Trie A Carrier
  stateTrie = weightedTrie 1#

  -- The weighted trie denotes exactly the unnormalized state language.
  weighted-denotes : ∀ c q xs →
    toLanguage (weightedTrie c q) xs ≡ c * unnormalized R M q xs
  weighted-denotes c q []       = cong (c *_) (sym (*-identityˡ (out q)))
  weighted-denotes c q (x ∷ xs) =
    let wx = proj₁ (step q x)
        q′ = proj₂ (step q x)
        p  = pathWeight R M q′ xs
        o  = out (run R M q′ xs)
    in trans (weighted-denotes (c * wx) q′ xs)
         (trans (*-assoc c wx (p * o))
                (cong (c *_) (sym (*-assoc wx p o))))

  stateTrie-denotes : ∀ q xs →
    toLanguage (stateTrie q) xs ≡ unnormalized R M q xs
  stateTrie-denotes q xs =
    trans (weighted-denotes 1# q xs) (*-identityˡ (unnormalized R M q xs))

  -- Run homomorphism: advancing the trie reaches the continuation state
  -- with the consumed path weight folded into the accumulator.
  weighted-run : ∀ c q xs →
    advanceT (weightedTrie c q) xs ≡
    weightedTrie (c * pathWeight R M q xs) (run R M q xs)
  weighted-run c q []       =
    cong (λ u → weightedTrie u q) (sym (*-identityʳ c))
  weighted-run c q (x ∷ xs) =
    let wx = proj₁ (step q x)
        q′ = proj₂ (step q x)
    in trans (weighted-run (c * wx) q′ xs)
         (cong (λ u → weightedTrie u (run R M q′ xs))
               (*-assoc c wx (pathWeight R M q′ xs)))

  -- Agreement with the extensional residual law already proved.
  trie-residual : ∀ q xs ys →
    toLanguage (advanceT (stateTrie q) xs) ys ≡
    residual (unnormalized R M q) xs ys
  trie-residual q xs ys =
    trans (cong (λ t → toLanguage t ys) (weighted-run 1# q xs))
      (trans (weighted-denotes (1# * pathWeight R M q xs) (run R M q xs) ys)
        (trans (cong (_* unnormalized R M (run R M q xs) ys)
                     (*-identityˡ (pathWeight R M q xs)))
               (sym (residual-continuation R M q xs ys))))
