import Base
import ./Sys.bend as S
import ./Clock.bend as Ck
import ./ToBend/Sexp.bend as X
import ./Agda2Bend/Ast.bend as A

# agda2bend: Agda in, Bend 2 out.  Agda elaborates (agda-export writes its
# elaborated definitions as S-expressions, tools/agda-export/FORMAT.md);
# everything after that is here: the parser of Agda (ToBend/Sexp.bend,
# Agda2Bend/Ast.bend), the translation, a fold over the parsed Agda into a
# Bend syntax tree, the Bend-side passes, the printer, the check gate and
# the ledger the translator is improved from (the plan of 2026-10-19).
#
#   agda2bend decode FILE.sexp...
#       parse and decode every expression of each export file: per file the
#       module, its definitions against the count its header announced,
#       and the forms kept raw outside the cubical helpers (which must be
#       none: the decoder is total on Agda's non-cubical syntax), and the
#       totals
#
# Logs go to stderr, stamped in UTC-6.  Every def is prefixed `a2b.`.

def a2b.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: agda2bend decode FILE.sexp...")

# decode -----------------------------------------------------------------------

# A file's tally: the module headers, definitions, the count the header
# announced, raw forms outside and inside the cubical helpers (flag
# no-compilation), and definitions by kind (functions, records, data
# types, constructors, others).
type A2bDc is Data:
  A2bDc{mods: Nat, defs: Nat, want: Nat, raws: Nat, cub: Nat, fun: Nat, rec: Nat, dat: Nat, con: Nat, oth: Nat}

def a2b.dc0() -> A2bDc:
  A2bDc{0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n}

def a2b.nocomp(fl: List<&2, A.AgKw>) -> Bool:
  match fl:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(A.aas.kw.eq(h, A.AkNoCompilation{}), a2b.nocomp(t))

def a2b.dc.kind.of(k: A.AgKw, mo: Nat, de: Nat, wa: Nat, ra: Nat, cu: Nat, fu: Nat, re: Nat, da: Nat, co: Nat, ot: Nat) -> A2bDc:
  match k:
    case A.AkFunction{}:
      A2bDc{mo, de, wa, ra, cu, 1n+fu, re, da, co, ot}
    case A.AkRecord{}:
      A2bDc{mo, de, wa, ra, cu, fu, 1n+re, da, co, ot}
    case A.AkData{}:
      A2bDc{mo, de, wa, ra, cu, fu, re, 1n+da, co, ot}
    case A.AkConstructor{}:
      A2bDc{mo, de, wa, ra, cu, fu, re, da, 1n+co, ot}
    case _:
      A2bDc{mo, de, wa, ra, cu, fu, re, da, co, 1n+ot}

def a2b.dc.kind(k: A.AgKw, s: A2bDc) -> A2bDc:
  match s:
    case A2bDc{mo, de, wa, ra, cu, fu, re, da, co, ot}:
      a2b.dc.kind.of(k, mo, de, wa, ra, cu, fu, re, da, co, ot)

def a2b.dc.raw(cub: Bool, +n: Nat, s: A2bDc) -> A2bDc:
  match cub s:
    case True{} A2bDc{mo, de, wa, ra, cu, fu, re, da, co, ot}:
      A2bDc{mo, de, wa, ra, Nat.add(cu, n), fu, re, da, co, ot}
    case False{} A2bDc{mo, de, wa, ra, cu, fu, re, da, co, ot}:
      A2bDc{mo, de, wa, Nat.add(ra, n), cu, fu, re, da, co, ot}

def a2b.dc.def(s: A2bDc, d: A.AgDecl) -> A2bDc:
  match s d:
    case A2bDc{mo, de, wa, ra, cu, fu, re, da, co, ot} A.AgDecl{q, nm, md, f, l, l0, l1, +k, m, fl, lang, +ty, +dd}:
      a2b.dc.raw(a2b.nocomp(fl), Nat.add(A.aas.raws(ty), A.aas.d.raws(dd)), a2b.dc.kind(k, A2bDc{mo, 1n+de, wa, ra, cu, fu, re, da, co, ot}))

def a2b.dc.add(s: A2bDc, t: A.AgTop) -> A2bDc:
  match s t:
    case A2bDc{mo, de, wa, ra, cu, fu, re, da, co, ot} A.AgTopMod{A.AgMod{nm, f, im, op, n}}:
      A2bDc{1n+mo, de, Nat.add(wa, n), ra, cu, fu, re, da, co, ot}
    case s A.AgTopDef{d}:
      a2b.dc.def(s, d)
    case s A.AgTopOther{}:
      s

def a2b.dc.sum(a: A2bDc, b: A2bDc) -> A2bDc:
  match a b:
    case A2bDc{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10} A2bDc{b1, b2, b3, b4, b5, b6, b7, b8, b9, b10}:
      A2bDc{Nat.add(a1, b1), Nat.add(a2, b2), Nat.add(a3, b3), Nat.add(a4, b4), Nat.add(a5, b5), Nat.add(a6, b6), Nat.add(a7, b7), Nat.add(a8, b8), Nat.add(a9, b9), Nat.add(a10, b10)}

def a2b.dc.show(s: A2bDc) -> String:
  match s:
    case A2bDc{mo, +de, +wa, ra, cu, fu, re, da, co, ot}:
      Nat.show(de) ++ "/" ++ Nat.show(wa) ++ " defs (" ++ Nat.show(fu) ++ " functions, " ++ Nat.show(re) ++ " records, "
        ++ Nat.show(da) ++ " data, " ++ Nat.show(co) ++ " constructors, " ++ Nat.show(ot) ++ " other), raw "
        ++ Nat.show(ra) ++ " (cubical helpers " ++ Nat.show(cu) ++ ")" ++ Bool.pick(String, Nat.is_eq(de, wa), "", " COUNT MISMATCH")

# A file streamed one expression at a time: the reader, the tally, and
# whether the file may have more.
type A2bDf is Type:
  A2bDf{rd: X.TsxRd, s: A2bDc, more: Bool}

def a2b.dc.got(s: A2bDc, r: X.TsxRd & Maybe<&2, X.Sx>) -> IO(A2bDf):
  (rd, m) = r
  match m:
    case Some{x}:
      IO.pure(A2bDf, A2bDf{rd, a2b.dc.add(s, A.aas.top(x)), True{}})
    case None{}:
      IO.pure(A2bDf, A2bDf{rd, s, False{}})

def a2b.dc.step(rd: X.TsxRd, s: A2bDc) -> IO(A2bDf):
  do IO<A2bDf>:
    r : X.TsxRd & Maybe<&2, X.Sx> <- X.tsx.next(rd)
    a2b.dc.got(s, r)

# The fuel bounds the expressions of one file (6,611 definitions is the
# most seen in a module); the loop stops at the end of the file.
def a2b.dc.go(fuel: Nat, f: A2bDf) -> IO(A2bDf):
  match fuel f:
    case 1n+p A2bDf{rd, s, True{}}:
      IO.bind(A2bDf, A2bDf, a2b.dc.step(rd, s), a2b.dc.go(p))
    case _ f:
      IO.pure(A2bDf, f)

def a2b.dc.fin(+path: String, f: A2bDf) -> IO(A2bDc):
  match f:
    case A2bDf{rd, +s, more}:
      do IO<A2bDc>:
        X.tsx.shut(rd)
        Ck.log("decode " ++ S.base(path) ++ ": " ++ a2b.dc.show(s))
        return s

def a2b.dc.file(+path: String) -> IO(A2bDc):
  do IO<A2bDc>:
    rd : X.TsxRd <- X.tsx.open(path)
    f : A2bDf <- a2b.dc.go(1000000n, A2bDf{rd, a2b.dc0(), True{}})
    a2b.dc.fin(path, f)

def a2b.dc.files(ps: List<String>, acc: A2bDc) -> IO(A2bDc):
  match ps:
    case Nil{}:
      IO.pure(A2bDc, acc)
    case p <> t:
      do IO<A2bDc>:
        s : A2bDc <- a2b.dc.file(p)
        a2b.dc.files(t, a2b.dc.sum(acc, s))

def a2b.decode(ps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +s : A2bDc <- a2b.dc.files(ps, a2b.dc0())
    Ck.log("decode total: " ++ a2b.dc.show(s))

# main -------------------------------------------------------------------------

def a2b.args(xs: List<String>) -> IO(Unit):
  match xs:
    case "decode" <> more:
      a2b.decode(more)
    case _:
      a2b.usage()

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked
    argv : List<String> <- IO.args()
    a2b.args(List.tail(&1, String, argv))
