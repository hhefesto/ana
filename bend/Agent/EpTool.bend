import Base
import ../Sys.bend as S
import ./Episode.bend as E

# bend-episode: Agent/Episode.bend's log from the shell.
#
#   bend-episode text LOG     each record's text (the episode as ana read it), each followed by NUL
#   bend-episode why LOG K    a line a record: N END WHY TRIES CALLS (WHY `ok`, or why the record
#                             is not a training episode under at most K calls)
#
# A log that does not read (not a log, or a record cut short) exits 1.

def et.texts(rs: List<&2, E.EpRec>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      List.concat(&2, U32, [E.ep.text(E.EpRec.segs(r)), [0], et.texts(t)])

def et.why.line(+i: Nat, +k: Nat, +r: E.EpRec) -> String:
  +ss = E.EpRec.segs(r)
  +w = E.ep.why(ss, k)
  Nat.show(i) ++ " " ++ S.str(E.EpRec.end(r)) ++ " " ++ Bool.pick(String, String.is_empty(w), "ok", w) ++ " "
    ++ Nat.show(E.ep.tries(ss)) ++ " " ++ Nat.show(E.ep.calls(ss))

def et.whys(rs: List<&2, E.EpRec>, +i: Nat, +k: Nat) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> t:
      do IO<Unit>:
        IO.print(et.why.line(i, k, r))
        et.whys(t, 1n+i, k)

def et.with(mode: Nat, +k: Nat, m: Maybe<&2, List<&2, E.EpRec>>) -> IO(Unit):
  match mode m:
    case _ None{}:
      IO.die(Unit, 1, "bend-episode: not a log, or a record is cut short")
    case 0n Some{rs}:
      IO.write(S.str(et.texts(rs)))
    case _ Some{rs}:
      et.whys(rs, 0n, k)

def et.read(+mode: Nat, +k: Nat, +path: String) -> IO(Unit):
  do IO<Unit>:
    xs : List<&2, U32> <- S.read(path)
    et.with(mode, k, E.ep.get(xs))

def et.args(xs: List<String>) -> IO(Unit):
  match xs:
    case "text" <> +path <> Nil{}:
      et.read(0n, 0n, path)
    case "why" <> +path <> +k <> Nil{}:
      et.read(1n, S.env.nat.got(Nat.read(k), 4n), path)
    case _:
      IO.die(Unit, 2, "usage: bend-episode text LOG | bend-episode why LOG K")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    et.args(List.tail(&1, String, argv))
