{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Transformer.Config where

open import Data.Nat using (ℕ; zero; _<_; _≤_; _*_; _+_; _∸_)
open import Data.Nat.DivMod using (_/_)
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

-- Hybrid rule: of layers 0..L-1, the indices ≡ 3 (mod 4) are softmax full
-- attention (⌊L/4⌋ of them); the rest are gated linear attention blocks,
-- each carrying one extra model×model gate projection.
glaLayers : ℕ → ℕ
glaLayers L = L ∸ L / 4

-- Flat count: tied embeddings, bias-free blocks, two RMS scales, GLA gate
-- projections, final RMS scale.
paramCount : Config → ℕ
paramCount c =
  vocab c * model c +
  layers c *
    (4 * model c * model c + 3 * ff c * model c + 2 * model c) +
  glaLayers (layers c) * (model c * model c) +
  model c
