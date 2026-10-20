# Bend 2 translation of the Agda module A2bFix
# by agda2bend (bend/Agda2Bend.bend) from agda-export's elaboration; 15 Agda definitions
# 
import Base

# Agda: A2bFix.Void
# A2bFix.agda, line 9
type Void is Data:

# Agda: A2bFix.Wrap
# A2bFix.agda, line 11
type Wrap<-A: Type> is Type:
  wrap{unwrap: A}

# Agda: A2bFix.Wrap.unwrap
# A2bFix.agda, line 13
def Wrap.unwrap(-A: Type, r: Wrap<A>) -> A:
  match r:
    case wrap{f_unwrap}:
      f_unwrap

# Agda: A2bFix.Bot
# A2bFix.agda, line 16
def Bot() -> Type:
  Wrap<Void>

# Agda: A2bFix.elim
# A2bFix.agda, line 19
def elim(-W: Type, x: Bot()) -> W:
  match x:
    case wrap{x_f}:
      match x_f:

# Agda: A2bFix.Ite
# A2bFix.agda, line 22
def Ite(x: Bool, x_1: Type, x_2: Type) -> Type:
  match x:
    case True{}:
      x_1
    case False{}:
      x_2

# Agda: A2bFix.Refl
# A2bFix.agda, line 27
type Refl<-A: Type, -x: Bool> is Type:
  Refl.ofy{x_2: A, ix_eq: {x == True{} : Bool}}
  Refl.ofn{x_2: A -> Bot(), ix_eq: {x == False{} : Bool}}

# Agda: A2bFix.invert
# A2bFix.agda, line 31
def invert(-A: Type, -b: Bool, x: Refl<A, b>) -> Ite(b, A, A -> Bot()):
  match x:
    case Refl.ofy{a, x_2_eq}:
      x_2_eq_sym = Equal.sym(Bool, b, True{}, x_2_eq)
      %x_2_eq_sym : Ite(_, A, A -> Bot())
      a
    case Refl.ofn{n, x_2_eq}:
      x_2_eq_sym = Equal.sym(Bool, b, False{}, x_2_eq)
      %x_2_eq_sym : Ite(_, A, A -> Bot())
      n

# Agda: A2bFix.of
# A2bFix.agda, line 35
def of(-A: Type, b: Bool, x: Ite(b, A, A -> Bot())) -> Refl<A, b>:
  match b:
    case True{}:
      Refl.ofy{x, {==}}
    case False{}:
      Refl.ofn{x, {==}}

# Agda: A2bFix.twice
# A2bFix.agda, line 40
def twice(-A: Data, x: A -> A -> A, +x_3: A) -> A:
  x(x_3, x_3)
