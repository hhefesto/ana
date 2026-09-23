import Base
import ../Bytes.bend as B
import ../Config.bend as C
import ../Checkpoint.bend as K

def report(r: B.Cur & K.Manifest) -> IO(Unit):
  (c, +m) = r
  do IO<Unit>:
    IO.print(C.Config.model_id(K.Manifest.cfg(m)))
    IO.print(Nat.show(C.Config.params(K.Manifest.cfg(m))))
    IO.print(K.Manifest.tokenizer_id(m))
    IO.print(Nat.show(K.Manifest.total_steps(m)))
    IO.print("problem: [" ++ K.Manifest.problem(m) ++ "]")
    B.Bytes.close(c)

def main() -> IO(Unit):
  do IO<Unit>:
    path : String <- IO.try(String, IO.get_env("CKPT"))
    c : B.Cur <- B.Bytes.open(path)
    r : B.Cur & K.Manifest <- K.Load.header()(c)
    report(r)
