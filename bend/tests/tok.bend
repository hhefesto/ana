import Base
import ../Bytes.bend as B
import ../Tokenizer.bend as Tk

def show(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> t:
      U32.show(h) ++ "," ++ show(t)

def dec(+b: Tk.Bpe, xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      List.append(&2, U32, Tk.Bpe.decode(b, h), dec(b, t))

def bytes2str(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case h <> t:
      SCon{Chr{h}, bytes2str(t)}

def enc(+b: Tk.Bpe, s: String) -> String:
  +ids = Tk.Bpe.encode(b, Tk.str.bytes(s))
  show(ids) ++ " -> [" ++ bytes2str(dec(b, ids)) ++ "]"

def go(m: Maybe<&2, Tk.Bpe>) -> IO(Unit):
  match m:
    case None{}:
      IO.print("parse failed")
    case Some{+b}:
      do IO<Unit>:
        IO.print(Tk.Bpe.identity(b))
        IO.print(enc(b, "The history of"))
        IO.print(enc(b, "Albert Einstein was"))
        IO.print(enc(b, "In mathematics, a group is"))
        IO.print(enc(b, "The city of Paris"))
        IO.print(enc(b, "Water is"))
        IO.print(enc(b, "  two  spaces\nand a newline"))

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<&2, U32> <- B.Bytes.read_all("../weights/enwiki-fineweb-32k.bpe")
    go(Tk.Bpe.parse(xs))
