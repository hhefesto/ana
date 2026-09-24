import Base
import ../Config.bend as C
import ../Checkpoint.bend as K
import ../Dense/Layout.bend as L
import ../Dense/Ckpt.bend as Dk

# load then save is the identity on master's checkpoints: CKPT is read
# into a dense store (parameters, moments, Muon momentum over the owned
# matrices' m cells) and written back at its own step to OUT, which must
# equal CKPT byte for byte (the driver compares them). That checks the
# offsets, the verbatim header and tail, and that the matrices Muon owns
# here are the ones master's momentum covers.

def env.or(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      d

def env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env.or(r, d)

def fin(+out: String, +ly: L.Lay, +m: L.Dm, r: Array<F32> & Dk.Src) -> IO(Unit):
  (s, +src) = r
  do IO<Unit>:
    IO.print("step " ++ Nat.show(Dk.Src.step(src)) ++ " momentum " ++ Bool.show(Dk.Src.mom(src)))
    s2 : Array<F32> <- Dk.save(out, src, Dk.Src.step(src), ly, m, Dk.Src.mom(src), s)
    IO.print("wrote " ++ out)

def go(+path: String, +out: String, mh: K.Manifest & Nat) -> IO(Unit):
  (+man, +h) = mh
  +c = K.Manifest.cfg(man)
  +m = L.Dm.of.cc(c, 1n, 16)
  +ly = L.Lay.of(c, m)
  do IO<Unit>:
    IO.print("model " ++ C.Config.model_id(c) ++ ", header " ++ Nat.show(h) ++ " bytes, store " ++ U32.show(L.Lay.total(ly)))
    r : Array<F32> & Dk.Src <- Dk.load(path, man, h, "", ly, m, Array.new(F32, L.Lay.depth(ly), 0.0))
    fin(out, ly, m, r)

def main() -> IO(Unit):
  do IO<Unit>:
    +path : String <- env("CKPT", "run/market-20260902-confirm/mkt-v3-base.checkpoint")
    +out : String <- env("OUT", "/tmp/hot-roundtrip.checkpoint")
    mh : K.Manifest & Nat <- Dk.header(path)
    go(path, out, mh)
