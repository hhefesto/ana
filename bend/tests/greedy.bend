import Base
import ../Bytes.bend as B
import ../Config.bend as C
import ../Checkpoint.bend as K
import ../Model.bend as Md
import ../Sample.bend as S
import ../Tensor.bend as T

def Out.logits(o: Md.Out) -> T.V:
  match o:
    case Md.Out{l, s}:
      l

def Out.sts(o: Md.Out) -> List<&2, Md.LState>:
  match o:
    case Md.Out{l, s}:
      s

# feed the prompt, then n greedy tokens; answer the chosen tokens
def run(n: Nat, prompt: List<&2, U32>, +dm: Md.Dims, +w: Md.Weights, sts: List<&2, Md.LState>, +pos: Nat, +last: U32) -> List<&2, U32>:
  match n prompt:
    case _ t <> rest:
      +o = Md.decode(dm, w, sts, pos, t)
      run(n, rest, dm, w, Out.sts(o), 1n+pos, S.argmax(Md.Dims.dv(dm), Out.logits(o)))
    case 0n Nil{}:
      Nil{}
    case 1n+p Nil{}:
      +o = Md.decode(dm, w, sts, pos, last)
      last <> run(p, Nil{}, dm, w, Out.sts(o), 1n+pos, S.argmax(Md.Dims.dv(dm), Out.logits(o)))

def show(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> t:
      U32.show(h) ++ "," ++ show(t)

def go(r: B.Cur & Md.Weights, +c: C.Config) -> IO(Unit):
  (cur, +w) = r
  +dm = Md.Dims.of(c)
  do IO<Unit>:
    IO.print("loaded")
    IO.print(show(run(8n, [0, 447, 2049, 278], dm, w, Md.states.zero(C.Config.layers(c), dm, 0n), 0n, 0)))
    B.Bytes.close(cur)

def after(r: B.Cur & K.Manifest) -> IO(Unit):
  (cur, +m) = r
  do IO<Unit>:
    IO.print("problem: [" ++ K.Manifest.problem(m) ++ "]")
    rw : B.Cur & Md.Weights <- Md.Load.weights(K.Manifest.cfg(m))(cur)
    go(rw, K.Manifest.cfg(m))

def main() -> IO(Unit):
  do IO<Unit>:
    path : String <- IO.try(String, IO.get_env("CKPT"))
    c : B.Cur <- B.Bytes.open(path)
    r : B.Cur & K.Manifest <- K.Load.header()(c)
    after(r)
