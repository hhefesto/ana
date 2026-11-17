import Base
import ../Sys.bend as S
import ../DeLatex.bend as D

# bend/DeLatex.bend on a file: each line of dl.doc's reading, `#` for a spoilt one (a look at what goes).
#   bend tests/dlshow.bend -o /tmp/dlshow && /tmp/dlshow FILE

def ds.show(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Bool.pick(List<&2, U32>, S.infix(l, [0]), [35], l) <> ds.show(t)

def ds.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +f <> Nil{}:
      do IO<Unit>:
        t : List<&2, U32> <- S.read(f)
        IO.print(S.str(S.join(ds.show(D.dl.doc(D.dl.table(), t)), 10)))
    case _:
      IO.die(Unit, 2, "usage: dlshow FILE")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    ds.main(xs)
