# Bend 2 translation of the Agda module Function.Base
# by agda2bend (bend/Agda2Bend.bend) from agda-export's elaboration; 34 Agda definitions
# 
import Base

# Agda: Function.Base.id
# Base.agda, line 29
def id(-A_u002e_a: Quant, -A: Kind(A_u002e_a), x: A) -> A:
  x

# Agda: Function.Base.const
# Base.agda, line 32
def const(-A_u002e_a: Quant, -A: Kind(A_u002e_a), -B_u002e_b: Quant, -B: Kind(B_u002e_b), x: A, -x_9: B) -> A:
  x

# Agda: Function.Base.constᵣ
# Base.agda, line 35
def const_u1d63(-A_u002e_a: Quant, -A: Kind(A_u002e_a), -B_u002e_b: Quant, -B: Kind(B_u002e_b), -x: A, x_9: B) -> B:
  id(B_u002e_b, B, x_9)

# Agda: Function.Base._∘_
# Base.agda, line 52
def comp(-a: Quant, -b: Quant, -c: Quant, -A: Kind(a), -B: A -> Kind(b), -C: @-x:A -> B(x) -> Kind(c), x: @-x:A -> @y:B(x) -> C(x, y), g: @x:A -> B(x), x_15: A) -> C(x_15, g(x_15)):
  x(x_15, g(x_15))

# Agda: Function.Base._∘₂_
# Base.agda, line 58
def comp_2(-a: Quant, -d: Quant, -b: Quant, -c: Quant, -A_1: Kind(a), -A_2: A_1 -> Kind(d), -B: @x:A_1 -> A_2(x) -> Kind(b), -C: @-x:A_1 -> @-y:A_2(x) -> B(x, y) -> Kind(c), x: @-x:A_1 -> @-y:A_2(x) -> @z:B(x, y) -> C(x, y, z), g: @x:A_1 -> @y:A_2(x) -> B(x, y), x_19: A_1, y: A_2(x_19)) -> C(x_19, y, g(x_19, y)):
  x(x_19, y, g(x_19, y))

# Agda: Function.Base.flip
# Base.agda, line 68
def flip(-a: Quant, -b: Quant, -c: Quant, -A: Kind(a), -B: Kind(b), -C: A -> B -> Kind(c), x: @x:A -> @y:B -> C(x, y), y: B, x_15: A) -> C(x_15, y):
  x(x_15, y)

# Agda: Function.Base._$_
# Base.agda, line 77
def dollar(-a: Quant, -b: Quant, -A: Kind(a), -B: A -> Kind(b), x: @x:A -> B(x), x_9: A) -> B(x_9):
  x(x_9)

# Agda: Function.Base._|>_
# Base.agda, line 84
def bar_gt(-a: Quant, -b: Quant, -A: Kind(a), -B: A -> Kind(b), a_8: A, x: @a_5:A -> B(a_5)) -> B(a_8):
  x(a_8)

# Agda: Function.Base._ˢ_
# Base.agda, line 93
def u02e2(-a: Quant, -b: Quant, -c: Quant, -A: Data, -B: A -> Kind(b), -C: @x:A -> B(x) -> Kind(c), x: @x:A -> @y:B(x) -> C(x, y), g: @x:A -> B(x), +x_15: A) -> C(x_15, g(x_15)):
  x(x_15, g(x_15))

# Agda: Function.Base._$-
# Base.agda, line 102
def dollar_2(-a: Quant, -b: Quant, -A: Kind(a), -B: A -> Kind(b), x: @x:A -> B(x), x_9: A) -> B(x_9):
  x(x_9)

# Agda: Function.Base.λ-
# Base.agda, line 106
def lam(-a: Quant, -b: Quant, -A: Kind(a), -B: A -> Kind(b), x: @-x:A -> B(x), x_9: A) -> B(x_9):
  x(x_9)

# Agda: Function.Base.case_returning_of_
# Base.agda, line 113
def case_returning_of(-a: Quant, -b: Quant, -A: Kind(a), x: A, -B: A -> Kind(b), x_10: @x_5:A -> B(x_5)) -> B(x):
  x_10(x)

# Agda: Function.Base._∘′_
# Base.agda, line 134
def comp_p(-B_u002e_b: Quant, -B: Kind(B_u002e_b), -C_u002e_c: Quant, -C: Kind(C_u002e_c), -A_u002e_a: Quant, -A: Kind(A_u002e_a), x: B -> C, x_13: A -> B, x_14: A) -> C:
  x(x_13(x_14))

# Agda: Function.Base._∘₂′_
# Base.agda, line 137
def comp_2_p(-C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), -A_u002e_a: Quant, -A: Kind(A_u002e_a), -B_u002e_b: Quant, -B: Kind(B_u002e_b), x: C -> D, x_17: A -> B -> C, x_18: A, x_19: B) -> D:
  comp_2(A_u002e_a, B_u002e_b, C_u002e_c, D_u002e_d, A, x_10 => B, x_10 => x_11 => C, x_10 => y => x_12 => D, x_10 => y => x, x_17, x_18, x_19)

# Agda: Function.Base.flip′
# Base.agda, line 142
def flip_p(-A_u002e_a: Quant, -A: Kind(A_u002e_a), -B_u002e_b: Quant, -B: Kind(B_u002e_b), -C_u002e_c: Quant, -C: Kind(C_u002e_c), x: A -> B -> C, x_13: B, x_14: A) -> C:
  x(x_14, x_13)

# Agda: Function.Base._$′_
# Base.agda, line 147
def dollar_p(-A_u002e_a: Quant, -A: Kind(A_u002e_a), -B_u002e_b: Quant, -B: Kind(B_u002e_b), x: A -> B, x_9: A) -> B:
  x(x_9)

# Agda: Function.Base._|>′_
# Base.agda, line 152
def bar_gt_p(-A_u002e_a: Quant, -A: Kind(A_u002e_a), -B_u002e_b: Quant, -B: Kind(B_u002e_b), x: A, x_9: A -> B) -> B:
  x_9(x)

# Agda: Function.Base.case_of_
# Base.agda, line 158
def case_of(-A_u002e_a: Quant, -A: Kind(A_u002e_a), -B_u002e_b: Quant, -B: Kind(B_u002e_b), x: A, x_9: A -> B) -> B:
  x_9(x)

# Agda: Function.Base._⟨_⟩_
# Base.agda, line 170
def la_ra(-A_u002e_a: Quant, -A: Kind(A_u002e_a), -B_u002e_b: Quant, -B: Kind(B_u002e_b), -C_u002e_c: Quant, -C: Kind(C_u002e_c), x: A, x_13: A -> B -> C, x_14: B) -> C:
  x_13(x, x_14)

# Agda: Function.Base._∋_
# Base.agda, line 176
def u220b(-a: Quant, -A: Kind(a), x: A) -> A:
  x

# Agda: Function.Base.it
# Base.agda, line 187
def it(-a: Quant, -A: Kind(a), x: A) -> A:
  x

# Agda: Function.Base._-⟪_⟫-_
# Base.agda, line 200
def u27ea_u27eb(-A_u002e_a: Quant, -A: Data, -B_u002e_b: Quant, -B: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), -E_u002e_e: Quant, -E: Kind(E_u002e_e), x: A -> B -> C, x_21: C -> D -> E, x_22: A -> B -> D, +x_23: A, +x_24: B) -> E:
  x_21(x(x_23, x_24), x_22(x_23, x_24))

# Agda: Function.Base._-⟪_∣
# Base.agda, line 205
def u27ea_div(-A_u002e_a: Quant, -A: Data, -B_u002e_b: Quant, -B: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), x: A -> B -> C, x_17: C -> B -> D, x_18: A, x_19: B) -> D:
  u27ea_u27eb(&2, A, &2, B, C_u002e_c, C, &2, B, D_u002e_d, D, x, x_17, eta1 => eta2 => const_u1d63(&2, A, &2, B, eta1, eta2), x_18, x_19)

# Agda: Function.Base.∣_⟫-_
# Base.agda, line 210
def div_u27eb(-A_u002e_a: Quant, -A: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), -B_u002e_b: Quant, -B: Data, x: A -> C -> D, x_17: A -> B -> C, x_18: A, x_19: B) -> D:
  u27ea_u27eb(&2, A, &2, B, &2, A, C_u002e_c, C, D_u002e_d, D, eta1 => eta2 => const(&2, A, &2, B, eta1, eta2), x, x_17, x_18, x_19)

# Agda: Function.Base._-⟨_∣
# Base.agda, line 215
def la_div(-A_u002e_a: Quant, -A: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -B_u002e_b: Quant, -B: Data, -D_u002e_d: Quant, -D: Kind(D_u002e_d), x: A -> C, x_17: C -> B -> D, x_18: A, x_19: B) -> D:
  u27ea_div(&2, A, &2, B, C_u002e_c, C, D_u002e_d, D, eta1 => eta2 => comp_2(&2, &2, &2, C_u002e_c, A, v => B, x_10 => x_11 => A, x_10 => y => x_12 => C, x_10 => y => x, eta1 => eta2 => const(&2, A, &2, B, eta1, eta2), eta1, eta2), x_17, x_18, x_19)

# Agda: Function.Base.∣_⟩-_
# Base.agda, line 220
def div_ra(-A_u002e_a: Quant, -A: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), -B_u002e_b: Quant, -B: Data, x: A -> C -> D, x_17: B -> C, x_18: A, x_19: B) -> D:
  div_u27eb(&2, A, C_u002e_c, C, D_u002e_d, D, &2, B, x, eta1 => eta2 => comp_2(&2, &2, &2, C_u002e_c, A, v => B, x_10 => x_11 => B, x_10 => y => x_12 => C, x_10 => y => x_17, eta1 => eta2 => const_u1d63(&2, A, &2, B, eta1, eta2), eta1, eta2), x_18, x_19)

# Agda: Function.Base._-⟪_⟩-_
# Base.agda, line 225
def u27ea_ra(-A_u002e_a: Quant, -A: Data, -B_u002e_b: Quant, -B: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), -E_u002e_e: Quant, -E: Kind(E_u002e_e), x: A -> B -> C, x_21: C -> D -> E, x_22: B -> D, x_23: A, x_24: B) -> E:
  u27ea_u27eb(&2, A, &2, B, C_u002e_c, C, D_u002e_d, D, E_u002e_e, E, x, x_21, eta1 => eta2 => div_ra(&2, A, D_u002e_d, D, D_u002e_d, D, &2, B, eta1 => eta2 => const_u1d63(&2, A, D_u002e_d, D, eta1, eta2), x_22, eta1, eta2), x_23, x_24)

# Agda: Function.Base._-⟨_⟫-_
# Base.agda, line 230
def la_u27eb(-A_u002e_a: Quant, -A: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), -E_u002e_e: Quant, -E: Kind(E_u002e_e), -B_u002e_b: Quant, -B: Data, x: A -> C, x_21: C -> D -> E, x_22: A -> B -> D, x_23: A, x_24: B) -> E:
  u27ea_u27eb(&2, A, &2, B, C_u002e_c, C, D_u002e_d, D, E_u002e_e, E, eta1 => eta2 => la_div(&2, A, C_u002e_c, C, &2, B, C_u002e_c, C, x, eta1 => eta2 => const(C_u002e_c, C, &2, B, eta1, eta2), eta1, eta2), x_21, x_22, x_23, x_24)

# Agda: Function.Base._-⟨_⟩-_
# Base.agda, line 235
def la_ra_2(-A_u002e_a: Quant, -A: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), -E_u002e_e: Quant, -E: Kind(E_u002e_e), -B_u002e_b: Quant, -B: Data, x: A -> C, x_21: C -> D -> E, x_22: B -> D, x_23: A, x_24: B) -> E:
  u27ea_u27eb(&2, A, &2, B, C_u002e_c, C, D_u002e_d, D, E_u002e_e, E, eta1 => eta2 => la_div(&2, A, C_u002e_c, C, &2, B, C_u002e_c, C, x, eta1 => eta2 => const(C_u002e_c, C, &2, B, eta1, eta2), eta1, eta2), x_21, eta1 => eta2 => div_ra(&2, A, D_u002e_d, D, D_u002e_d, D, &2, B, eta1 => eta2 => const_u1d63(&2, A, D_u002e_d, D, eta1, eta2), x_22, eta1, eta2), x_23, x_24)

# Agda: Function.Base._on₂_
# Base.agda, line 240
def on_2(~C_u002e_c: Quant, ~C: Kind(C_u002e_c), ~A_u002e_a: Quant, ~A: Data, ~B_u002e_b: Quant, ~B: Data, ~x_17: A -> B -> C, -D_u002e_d: Quant, -D: Kind(D_u002e_d), x: C -> C -> D, x_18: A, x_19: B) -> D:
  u27ea_u27eb(&2, A, &2, B, C_u002e_c, C, C_u002e_c, C, D_u002e_d, D, x_17, x, x_17, x_18, x_19)

# Agda: Function.Base._on_
# Base.agda, line 245
def on(~B_u002e_b: Quant, ~B: Kind(B_u002e_b), ~A_u002e_a: Quant, ~A: Data, ~x_13: A -> B, -C_u002e_c: Quant, -C: Kind(C_u002e_c), x: B -> B -> C, x_14: A, x_15: A) -> C:
  la_ra_2(&2, A, B_u002e_b, B, B_u002e_b, B, C_u002e_c, C, &2, A, x_13, x, x_13, x_14, x_15)

# Agda: Function.Base._-[_]-_
# Base.agda, line 257
def lb_rb(-A_u002e_a: Quant, -A: Data, -B_u002e_b: Quant, -B: Data, -C_u002e_c: Quant, -C: Kind(C_u002e_c), -D_u002e_d: Quant, -D: Kind(D_u002e_d), -E_u002e_e: Quant, -E: Kind(E_u002e_e), x: A -> B -> C, x_21: C -> D -> E, x_22: A -> B -> D, x_23: A, x_24: B) -> E:
  u27ea_u27eb(&2, A, &2, B, C_u002e_c, C, D_u002e_d, D, E_u002e_e, E, x, x_21, x_22, x_23, x_24)

# Agda: Function.Base.case_return_of_
# Base.agda, line 265
def case_return_of(-a: Quant, -b: Quant, -A: Kind(a), x: A, -B: A -> Kind(b), x_10: @x_5:A -> B(x_5)) -> B(x):
  x_10(x)
