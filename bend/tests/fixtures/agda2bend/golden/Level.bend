# Bend 2 translation of the Agda module Level
# by agda2bend (bend/Agda2Bend.bend) from agda-export's elaboration; 8 Agda definitions
# 
import Base

# Agda: Level.Lift
# Level.agda, line 19
type Lift<-a: Quant, -l: Quant, -A: Kind(a)> is Kind(a):
  lift{lower: A}

# Agda: Level.Lift.lower
# Level.agda, line 21
def Lift.lower(-a: Quant, -l: Quant, -A: Kind(a), r: Lift<a, l, A>) -> A:
  match r:
    case lift{f_lower}:
      f_lower
