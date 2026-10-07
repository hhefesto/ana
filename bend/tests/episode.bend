import Base
import ../Agent/Spec.bend as A
import ../Agent/Episode.bend as E

# Agent/Episode.bend on small episodes: the log reads back what was written
# (any bytes: NUL, RS, a byte that is not UTF-8, empty texts, records one
# after another), the loop's newest-first fold is the text in order, and the
# grammar of a training episode: a solved chain holds; drift to another
# heading, an unsolved end, a call past the cap, and a tool's byte that does
# not read as echo each fail with their reason.  Each line prints `ok NAME`
# or `FAIL NAME`.

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

def b(s: String) -> List<&2, U32>:
  A.ag.ascii(s)

def seg(+who: Nat, +tool: String, +code: U32, +text: String) -> E.EpSeg:
  E.EpSeg{who, b(tool), code, b(text)}

def prompt() -> E.EpSeg:
  seg(0n, "", 0, "## User\n\nDefine `f`.\n\n## Type\n\ntype\n```haskell\nf :: Int -> Int\n```\n\n## Term\n\n```haskell\n")

def bad() -> String:
  "Unit.hs:3:5: error: No instance for (Num [a0])"

def chain() -> List<&2, E.EpSeg>:
  [prompt(), seg(1n, "", 0, "f = (++ 1)\n```\n\n## ghc\n"), seg(2n, "ghc", 1, "\n```\n" ++ bad() ++ "\n```\n\n"),
   seg(1n, "", 0, "## Term\n\n```haskell\nf = (+ 1)\n```\n\n## ghc\n"), seg(2n, "ghc", 0, "\n```\n[exit 0]\n```\n\n")]

def drift() -> List<&2, E.EpSeg>:
  [prompt(), seg(1n, "", 0, "f = (++ 1)\n```\n\n## ghc\n"), seg(2n, "ghc", 1, "\n```\n" ++ bad() ++ "\n```\n\n"),
   seg(1n, "", 0, "## Type\n\n```haskell\nf :: Int\n```\n\n## ghc\n"), seg(2n, "ghc", 1, "\n```\n" ++ bad() ++ "\n```\n\n"),
   seg(1n, "", 0, "## Term\n\n```haskell\nf = (+ 1)\n```\n\n## ghc\n"), seg(2n, "ghc", 0, "\n```\n[exit 0]\n```\n\n")]

def unsolved() -> List<&2, E.EpSeg>:
  [prompt(), seg(1n, "", 0, "f = (++ 1)\n```\n\n## ghc\n"), seg(2n, "ghc", 1, "\n```\n" ++ bad() ++ "\n```\n\n")]

# the tool's turn split so that part of its echo is written by ana
def authors() -> List<&2, E.EpSeg>:
  [prompt(), seg(1n, "", 0, "f = (+ 1)\n```\n\n## ghc\n\n```\n"), seg(2n, "ghc", 0, "[exit 0]\n```\n\n")]

def why(+name: String, +ss: List<&2, E.EpSeg>, +k: Nat, +want: String) -> String:
  +w = E.ep.why(ss, k)
  verdict(name ++ " (" ++ Bool.pick(String, String.is_empty(w), "ok", w) ++ ")", String.eq(w, want))

def segs.eq(xs: List<&2, E.EpSeg>, ys: List<&2, E.EpSeg>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case E.EpSeg{w, t, c, x} <> s E.EpSeg{w2, t2, c2, x2} <> r:
      Bool.and(Bool.and(Bool.and(Nat.is_eq(w, w2), A.ag.eq(t, t2)), Bool.and(U32.is_eq(c, c2), A.ag.eq(x, x2))), segs.eq(s, r))
    case _ _:
      False{}

def recs.eq(xs: List<&2, E.EpRec>, ys: List<&2, E.EpRec>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case E.EpRec{m, e, s} <> t E.EpRec{m2, e2, s2} <> r:
      Bool.and(Bool.and(A.ag.eq(m, m2), A.ag.eq(e, e2)), Bool.and(segs.eq(s, s2), recs.eq(t, r)))
    case _ _:
      False{}

def got.eq(m: Maybe<&2, List<&2, E.EpRec>>, want: List<&2, E.EpRec>) -> Bool:
  match m:
    case Some{rs}:
      recs.eq(rs, want)
    case None{}:
      False{}

def got.none(m: Maybe<&2, List<&2, E.EpRec>>) -> Bool:
  match m:
    case Some{rs}:
      False{}
    case None{}:
      True{}

def raw(+who: Nat, +tool: List<&2, U32>, +code: U32, +xs: List<&2, U32>) -> E.EpSeg:
  E.EpSeg{who, tool, code, xs}

def rec(+m: List<&2, U32>, +e: List<&2, U32>, +ss: List<&2, E.EpSeg>) -> E.EpRec:
  E.EpRec{m, e, ss}

def roundtrip() -> String:
  +odd = raw(2n, b("lean"), 1, [0, 30, 255, 10, 31, 0])
  +empty = raw(1n, Nil{}, 0, Nil{})
  +r1 = rec(b("unit=u1\nseed=0\n"), b("solved"), chain())
  +r2 = rec(Nil{}, b("calls"), [prompt(), odd, empty])
  +r3 = rec(b("k=4\n"), Nil{}, Nil{})
  +log = List.concat(&2, U32, [E.ep.put(b("unit=u1\nseed=0\n"), b("solved"), chain()), E.ep.put(Nil{}, b("calls"), [prompt(), odd, empty]),
    E.ep.put(b("k=4\n"), Nil{}, Nil{})])
  +ok = got.eq(E.ep.get(log), [r1, r2, r3])
  +cut = got.none(E.ep.get(List.take(&2, U32, log, Nat.sub(List.length(&2, U32, log), 3n))))
  verdict("log roundtrip", Bool.and(ok, cut))

def newest() -> String:
  +ss = chain()
  verdict("newest", A.ag.eq(E.ep.text.newest(E.ep.rev(ss, Nil{}), Nil{}), E.ep.text(ss)))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(roundtrip())
    IO.print(newest())
    IO.print(why("chain", chain(), 4n, ""))
    IO.print(why("drift", drift(), 4n, "drift"))
    IO.print(why("unsolved", unsolved(), 4n, "unsolved"))
    IO.print(why("calls", chain(), 1n, "calls"))
    IO.print(why("authors", authors(), 4n, "authors"))
    IO.print(verdict("tries", Nat.is_eq(E.ep.tries(chain()), 1n)))
    IO.print(verdict("solved", Bool.and(E.ep.solved(chain()), Bool.not(E.ep.solved(unsolved())))))
    return Unit{}
