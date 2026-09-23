import Base
import ../Sha256.bend as H

def bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      c <> bytes(t)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(H.sha256(bytes("")))
    IO.print(H.sha256(bytes("abc")))
    IO.print(H.sha256(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
