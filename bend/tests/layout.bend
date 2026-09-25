import Base
import ../Config.bend as C
import ../Train.bend as Tr
import ../Dense/Layout.bend as L


# Lay.floats (Nat, exact) equals Lay.total (U32) for every preset the
# trainer runs, at micro-batches and chunk lengths where U32 cannot wrap;
# then the context-2048 preset's store at the micro-batches that matter.

def one(+pre: String, +mb: Nat, +cc: Nat) -> String:
  +c = Tr.preset(pre)
  +got = L.Lay.floats(c, mb, cc)
  +want = U32.to_nat(L.Lay.total(L.Lay.of(c, L.Dm.of.cc(c, mb, U32.from_nat(cc)))))
  Bool.pick(String, Nat.is_eq(got, want), "ok ", "MISMATCH ") ++ pre ++ " micro " ++ Nat.show(mb) ++ " chunk " ++ Nat.show(cc)
    ++ ": " ++ Nat.show(got) ++ Bool.pick(String, Nat.is_eq(got, want), "", " (Lay.total " ++ Nat.show(want) ++ ")")

def by.cc(+p: String, +m: Nat, cs: List<&2, Nat>) -> List<&2, String>:
  match cs:
    case Nil{}:
      Nil{}
    case c <> more:
      one(p, m, c) <> by.cc(p, m, more)

def by.mb(+p: String, ms: List<&2, Nat>, +ccs: List<&2, Nat>) -> List<&2, String>:
  match ms:
    case Nil{}:
      Nil{}
    case +m <> more:
      List.append(&2, String, by.cc(p, m, ccs), by.mb(p, more, ccs))

def all(ps: List<&2, String>, +mbs: List<&2, Nat>, +ccs: List<&2, Nat>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      List.append(&2, String, by.mb(p, mbs, ccs), all(more, mbs, ccs))

def fits(+mb: Nat) -> String:
  +c = C.Config.fp100m()
  "fp100m micro " ++ Nat.show(mb) ++ ": " ++ Nat.show(L.Lay.floats(c, mb, 16n)) ++ " floats, "
    ++ Bool.pick(String, L.Lay.fits(c, mb, 16n), "fits one array", "past 2^31")

def say(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case x <> more:
      do IO<Unit>:
        IO.print(x)
        say(more)

def main() -> IO(Unit):
  do IO<Unit>:
    say(all(["tiny-v3", "small4-v3", "bpe10m-v3", "bpe100m-v3"], [1n, 2n, 4n, 8n, 32n], [16n, 64n]))
    say(all(["fp100m", "bpe460m"], [1n, 2n, 4n], [16n, 64n]))
    say([fits(4n), fits(5n), fits(6n), fits(12n), fits(16n)])
