import Base
import ../Num.bend as N
import ../Bytes.bend as B

def show_bytes(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> t:
      U32.show(h) ++ " " ++ show_bytes(t)

def fin(r: B.Cur & List<&2, U32>) -> IO(Unit):
  (c, xs) = r
  do IO<Unit>:
    IO.print(show_bytes(xs))
    B.Bytes.close(c)

def rest(r: B.Cur & List<&2, U32>) -> IO(Unit):
  (c, xs) = r
  do IO<Unit>:
    IO.print(B.Bytes.to_string(xs))
    s : B.Cur & List<&2, U32> <- B.Bytes.take(12n, c)
    fin(s)

def main() -> IO(Unit):
  do IO<Unit>:
    c : B.Cur <- B.Bytes.open("../run/pulled-root-65.95.12.163-44704-checkpoints/wiki-bpe100m-v3-global.checkpoint")
    r : B.Cur & List<&2, U32> <- B.Bytes.take(4n, c)
    rest(r)

