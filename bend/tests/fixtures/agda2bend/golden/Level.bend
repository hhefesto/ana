# Bend 2 translation of the Agda module Level
# by agda2bend (bend/Agda2Bend.bend) from agda-export's elaboration; 8 Agda definitions
# 
import Base

# Agda: Level.Lift
# Level.agda, line 19
type Lift<-A: Type> is Type:
  lift{lower: A}

# Agda: Level.Lift.lower
# Level.agda, line 21
def Lift.lower(-A: Type, r: Lift<A>) -> A:
  match r:
    case lift{f_lower}:
      f_lower
