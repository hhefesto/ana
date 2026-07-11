{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Transformer.Config where

open import Data.Nat using (ℕ; zero; _<_; _≤_; _*_; _+_)
open import Data.Nat.Divisibility using (_∣_)
open import Relation.Binary.PropositionalEquality using (_≡_)

record Config : Set where
  field
    vocab context model ff heads layers headDim : ℕ
    vocab-at-least-three : 3 ≤ vocab
    context-at-least-two : 2 ≤ context
    model-positive : zero < model
    ff-positive : zero < ff
    heads-positive : zero < heads
    layers-positive : zero < layers
    model-head-shape : model ≡ heads * headDim
    headDim-even : 2 ∣ headDim

open Config public

-- Flat count: tied embeddings, bias-free blocks, two RMS scales, final RMS scale.
paramCount : Config → ℕ
paramCount c =
  vocab c * model c +
  layers c *
    (4 * model c * model c + 3 * ff c * model c + 2 * model c) +
  model c
