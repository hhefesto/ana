{-# OPTIONS --safe --without-K --guardedness #-}

module FormalTransformer.Attention.LinearTrie where

open import Level using (lift; lower)
open import Data.Nat using (ℕ)
open import Data.Fin using (Fin)
open import Relation.Binary.PropositionalEquality using (_≡_; trans; cong)

open import FormalTransformer.Foundation.Algebra using (Semiring)
open import FormalTransformer.Language.Trie using (Trie; advanceT; toLanguage)
open import FormalTransformer.Language.AutoregressiveTrie
  using (observationTrie; observation-run; observation-denotes)
open import FormalTransformer.Attention.Linear using (module GLA)

-- The GLA state algebra instantiated at the observation trie: the first
-- concrete discharge of the proved KV-cache law. The cache state has the
-- fixed type Fin dk → Fin dv → Carrier, independent of prefix length.
module _ {a w} {A : Set a} (R : Semiring w) (dk dv : ℕ)
         (gate key : A → Fin dk → Semiring.Carrier R)
         (val : A → Fin dv → Semiring.Carrier R) where
  open Semiring R using (Carrier)
  open GLA R dk dv gate key val

  module Cache (emit : A → Matrix → Carrier) (obs : Matrix → Carrier) where
    open Packaged emit obs

    glaCache : Matrix → Trie A Carrier
    glaCache S = observationTrie R glaAlgebra (lift S)

    -- Incremental stepping of the cache equals whole-prefix evaluation,
    -- with the reached state given by the GLA recurrence itself.
    cache-run : ∀ S ts → advanceT (glaCache S) ts ≡ glaCache (runGLA S ts)
    cache-run S ts =
      trans (observation-run R glaAlgebra (lift S) ts)
            (cong (observationTrie R glaAlgebra) (run-runGLA S ts))

    cache-denotes : ∀ S ts →
      toLanguage (glaCache S) ts ≡ obs (runGLA S ts)
    cache-denotes S ts =
      trans (observation-denotes R glaAlgebra (lift S) ts)
            (cong (λ q → obs (lower q)) (run-runGLA S ts))
