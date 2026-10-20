# Bend 2 translation of the Agda module Function.Base
# by agda2bend (bend/Agda2Bend.bend) from agda-export's elaboration; 34 Agda definitions
# 
import Base

# Agda: Function.Base.id
# Base.agda, line 29
def id(-A: Type, x: A) -> A:
  x

# Agda: Function.Base.const
# Base.agda, line 32
def const(-A: Type, -B: Type, x: A) -> B -> A:
  x_5 => x

# Agda: Function.Base.constᵣ
# Base.agda, line 35
def const_u1d63(-A: Type, -B: Type, x: A) -> B -> B:
  eta1 => id(B, eta1)

# Agda: Function.Base._∘_
# Base.agda, line 52
def comp(-A: Type, -B: A -> Type, -C: @-x:A -> B(x) -> Type, x: @-x:A -> @y:B(x) -> C(x, y), g: @x:A -> B(x)) -> @x:A -> C(x, g(x)):
  x_8 => x(x_8, g(x_8))

# Agda: Function.Base._∘₂_
# Base.agda, line 58
def comp_2(-A_1: Type, -A_2: A_1 -> Type, -B: @x:A_1 -> A_2(x) -> Type, -C: @-x:A_1 -> @-y:A_2(x) -> B(x, y) -> Type, x: @-x:A_1 -> @-y:A_2(x) -> @z:B(x, y) -> C(x, y, z), g: @x:A_1 -> @y:A_2(x) -> B(x, y)) -> @x:A_1 -> @y:A_2(x) -> C(x, y, g(x, y)):
  x_10 => y => x(x_10, y, g(x_10, y))

# Agda: Function.Base.flip
# Base.agda, line 68
def flip(-A: Type, -B: Type, -C: A -> B -> Type, x: @x:A -> @y:B -> C(x, y)) -> @y:B -> @x:A -> C(x, y):
  y => x_8 => x(x_8, y)

# Agda: Function.Base._$_
# Base.agda, line 77
def dollar(-A: Type, -B: A -> Type, x: @x:A -> B(x), x_9: A) -> B(x_9):
  x(x_9)

# Agda: Function.Base._|>_
# Base.agda, line 84
def bar_gt(-A: Type, -B: A -> Type) -> @a:A -> (@a_5:A -> B(a_5)) -> B(a):
  y => x => x(y)

# Agda: Function.Base._$-
# Base.agda, line 102
def dollar_2(-A: Type, -B: A -> Type, x: @x:A -> B(x), x_9: A) -> B(x_9):
  x(x_9)

# Agda: Function.Base.λ-
# Base.agda, line 106
def lam(-A: Type, -B: A -> Type, x: @-x:A -> B(x)) -> @x:A -> B(x):
  x_5 => x(x_5)

# Agda: Function.Base.case_returning_of_
# Base.agda, line 113
def case_returning_of(-A: Type, x: A, -B: A -> Type, x_10: @x_5:A -> B(x_5)) -> B(x):
  x_10(x)

# Agda: Function.Base._∘′_
# Base.agda, line 134
def comp_p(-B: Type, -C: Type, -A: Type, x: B -> C, x_13: A -> B) -> A -> C:
  x_8 => x(x_13(x_8))

# Agda: Function.Base._∘₂′_
# Base.agda, line 137
def comp_2_p(-C: Type, -D: Type, -A: Type, -B: Type, x: C -> D, x_17: A -> B -> C) -> A -> B -> D:
  comp_2(A, x_10 => B, x_10 => x_11 => C, x_10 => y => x_12 => D, x_10 => y => x, x_17)

# Agda: Function.Base.flip′
# Base.agda, line 142
def flip_p(-A: Type, -B: Type, -C: Type) -> (A -> B -> C) -> B -> A -> C:
  f => y => x => f(x, y)

# Agda: Function.Base._$′_
# Base.agda, line 147
def dollar_p(-A: Type, -B: Type) -> (A -> B) -> A -> B:
  f => f

# Agda: Function.Base._|>′_
# Base.agda, line 152
def bar_gt_p(-A: Type, -B: Type) -> A -> (A -> B) -> B:
  y => x => x(y)

# Agda: Function.Base.case_of_
# Base.agda, line 158
def case_of(-A: Type, -B: Type, x: A, x_9: A -> B) -> B:
  x_9(x)

# Agda: Function.Base._⟨_⟩_
# Base.agda, line 170
def la_ra(-A: Type, -B: Type, -C: Type, x: A, x_13: A -> B -> C, x_14: B) -> C:
  x_13(x, x_14)

# Agda: Function.Base._∋_
# Base.agda, line 176
def u220b(-A: Type, x: A) -> A:
  x

# Agda: Function.Base.it
# Base.agda, line 187
def it(-A: Type, x: A) -> A:
  x
