{-# OPTIONS --safe --without-K #-}

module FormalTransformer.Attention.Linear where

open import Level using (Lift; lift; lower)
open import Data.Nat using (ℕ; zero; suc)
open import Data.Fin as Fin using (Fin)
open import Data.List using (List; []; _∷_; _++_; map)
open import Data.Product using (_×_; _,_; proj₁; proj₂)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; sym; trans; cong; module ≡-Reasoning)

open import FormalTransformer.Foundation.Algebra using (Semiring)
open import FormalTransformer.Language.Autoregressive
  using (StateAlgebra; run; pathWeight; listSum)

-- A denotational semantics for linear attention. Attention variants are one
-- recurrent form o_t = q_tᵀ (Σ_{j≤t} (∏_{s=j+1..t} A_s) k_j v_jᵀ), classified
-- by the transition family A_s (Kimi Linear, arXiv:2510.26692, Table 6).
-- Softmax attention is the exp-kernel instance whose only state is the whole
-- prefix. Gated linear attention (GLA) takes A_s diagonal and data-dependent,
-- so the state is one dk×dv matrix: S_t = diag(gate t)·S_{t-1} + key t (val t)ᵀ.
-- Diagonal transitions keep every product of transitions diagonal, which is
-- why this module needs only scalar semiring algebra and no matrix products;
-- the delta rule (I − βkkᵀ) needs subtraction and is future Ring-level work.
module GLA {a w} {A : Set a} (R : Semiring w) (dk dv : ℕ)
           (gate key : A → Fin dk → Semiring.Carrier R)
           (val : A → Fin dv → Semiring.Carrier R) where
  open Semiring R

  private
    +-identityʳ : ∀ x → x + 0# ≡ x
    +-identityʳ x = trans (+-comm x 0#) (+-identityˡ x)

  Vector : ℕ → Set w
  Vector n = Fin n → Carrier

  -- The state type is fixed by dk and dv alone; no prefix length appears.
  Matrix : Set w
  Matrix = Fin dk → Fin dv → Carrier

  outer : Vector dk → Vector dv → Matrix
  outer k v i j = k i * v j

  stepGLA : A → Matrix → Matrix
  stepGLA t S i j = gate t i * S i j + outer (key t) (val t) i j

  -- Recurrent form: one step per token.
  runGLA : Matrix → List A → Matrix
  runGLA S []       = S
  runGLA S (t ∷ ts) = runGLA (stepGLA t S) ts

  -- Diagonal of the transition product over ts. Later tokens multiply on the
  -- left; the accumulation order matters because _*_ is not assumed
  -- commutative.
  gateProd : List A → Vector dk
  gateProd []       i = 1#
  gateProd (t ∷ ts) i = gateProd ts i * gate t i

  -- Σ over tokens of (∏ gates strictly after the token) · key valᵀ.
  contrib : List A → Matrix
  contrib []       i j = 0#
  contrib (t ∷ ts) i j =
    gateProd ts i * outer (key t) (val t) i j + contrib ts i j

  -- Parallel form: every token's contribution, decayed by the gates after it.
  closedGLA : Matrix → List A → Matrix
  closedGLA S ts i j = gateProd ts i * S i j + contrib ts i j

  -- The recurrent and parallel forms are one function. This is the semantic
  -- license for chunkwise/parallel execution of the same meaning, stated
  -- pointwise so no function extensionality is needed.
  recurrent≡parallel : ∀ S ts i j → runGLA S ts i j ≡ closedGLA S ts i j
  recurrent≡parallel S [] i j =
    sym (trans (+-identityʳ (1# * S i j)) (*-identityˡ (S i j)))
  recurrent≡parallel S (t ∷ ts) i j =
    let g  = gateProd ts i
        gt = gate t i
        kv = outer (key t) (val t) i j
        c  = contrib ts i j
        open ≡-Reasoning
    in begin
      runGLA (stepGLA t S) ts i j
        ≡⟨ recurrent≡parallel (stepGLA t S) ts i j ⟩
      g * (gt * S i j + kv) + c
        ≡⟨ cong (_+ c) (distribˡ g (gt * S i j) kv) ⟩
      (g * (gt * S i j) + g * kv) + c
        ≡⟨ +-assoc (g * (gt * S i j)) (g * kv) c ⟩
      g * (gt * S i j) + (g * kv + c)
        ≡⟨ cong (_+ (g * kv + c)) (sym (*-assoc g gt (S i j))) ⟩
      (g * gt) * S i j + (g * kv + c)
        ∎

  -- Chunk boundary law, refl per step: running a concatenation is running
  -- the chunks in order.
  runGLA-++ : ∀ S ts us → runGLA S (ts ++ us) ≡ runGLA (runGLA S ts) us
  runGLA-++ S []       us = refl
  runGLA-++ S (t ∷ ts) us = runGLA-++ (stepGLA t S) ts us

  gateProd-++ : ∀ ts us i →
    gateProd (ts ++ us) i ≡ gateProd us i * gateProd ts i
  gateProd-++ []       us i = sym (*-identityʳ (gateProd us i))
  gateProd-++ (t ∷ ts) us i =
    trans (cong (_* gate t i) (gateProd-++ ts us i))
          (*-assoc (gateProd us i) (gateProd ts i) (gate t i))

  -- The chunkwise recurrence: a chunk acts on the state reached by the
  -- previous chunks through its own gate product and contribution only.
  chunk-closed : ∀ S ts us i j →
    runGLA S (ts ++ us) i j ≡
    gateProd us i * runGLA S ts i j + contrib us i j
  chunk-closed S ts us i j =
    trans (cong (λ M → M i j) (runGLA-++ S ts us))
          (recurrent≡parallel (runGLA S ts) us i j)

  -- Each token paired with its strict suffix, making the Σ literal.
  suffixes : List A → List (A × List A)
  suffixes []       = []
  suffixes (t ∷ ts) = (t , ts) ∷ suffixes ts

  contrib-sum : ∀ ts i j →
    contrib ts i j ≡
    listSum R (map (λ p → gateProd (proj₂ p) i *
                          outer (key (proj₁ p)) (val (proj₁ p)) i j)
                   (suffixes ts))
  contrib-sum []       i j = refl
  contrib-sum (t ∷ ts) i j =
    cong (gateProd ts i * outer (key t) (val t) i j +_) (contrib-sum ts i j)

  sumFin : ∀ n → (Fin n → Carrier) → Carrier
  sumFin zero    f = 0#
  sumFin (suc n) f = f Fin.zero + sumFin n (λ i → f (Fin.suc i))

  -- The attention output is a query-dependent readout of the state; scalar
  -- observations of the state factor through readouts like this one.
  readout : Vector dk → Matrix → Vector dv
  readout q S j = sumFin dk (λ i → q i * S i j)

  -- The per-step emitted weight and the state observation are supplied, not
  -- derived: normalization is deliberately separate, as elsewhere in this
  -- development.
  module Packaged (emit : A → Matrix → Carrier) (obs : Matrix → Carrier) where

    glaAlgebra : StateAlgebra A Carrier
    glaAlgebra = record
      { State = Lift a Matrix
      ; out   = λ q → obs (lower q)
      ; step  = λ q t → emit t (lower q) , lift (stepGLA t (lower q))
      }

    -- The generic run is the GLA recurrence, refl per step.
    run-runGLA : ∀ S ts → run R glaAlgebra (lift S) ts ≡ lift (runGLA S ts)
    run-runGLA S []       = refl
    run-runGLA S (t ∷ ts) = run-runGLA (stepGLA t S) ts

    run-closed : ∀ S ts i j →
      lower (run R glaAlgebra (lift S) ts) i j ≡ closedGLA S ts i j
    run-closed S ts i j =
      trans (cong (λ q → lower q i j) (run-runGLA S ts))
            (recurrent≡parallel S ts i j)

  -- The pure state machine: weight 1# per step, so the path weight is
  -- trivial and the unnormalized language collapses to the observation.
  module Machine (obs : Matrix → Carrier) where
    open Packaged (λ _ _ → 1#) obs public

    pathWeight-triv : ∀ S ts → pathWeight R glaAlgebra (lift S) ts ≡ 1#
    pathWeight-triv S []       = refl
    pathWeight-triv S (t ∷ ts) =
      trans (*-identityˡ (pathWeight R glaAlgebra (lift (stepGLA t S)) ts))
            (pathWeight-triv (stepGLA t S) ts)
