import Base
import ./Sys.bend as S
import ./Clock.bend as Ck
import ./ToBend/Sexp.bend as X
import ./Agda2Bend/Ast.bend as A
import ./Agda2Bend/Cata.bend as C
import ./ToBend/Ast.bend as T
import ./ToBend/Print.bend as P
import ./ToBend/Names.bend as N
import ./ToBend/Order.bend as O
import ./ToBend/Gate.bend as G
import ./ToBend/Copy.bend as Q

# agda2bend: Agda in, Bend 2 out.  Agda elaborates (agda-export writes its
# elaborated definitions as S-expressions, tools/agda-export/FORMAT.md);
# everything after that is here: the parser of Agda (ToBend/Sexp.bend,
# Agda2Bend/Ast.bend), the translation, a fold over the parsed Agda into a
# Bend syntax tree, the Bend-side passes, the printer, the check gate and
# the ledger the translator is improved from (the plan of 2026-10-19).
#
#   agda2bend translate FILE.agda OUT
#       Agda code in, Bend out: agda-export elaborates FILE (AGDA_EXPORT,
#       AGDA_DIR) into OUT/export, then emit translates its module's cone
#
#   agda2bend emit DIR OUT [MODULE...]
#       translate the export in DIR (agda-export's --export-dir): the modules
#       named and every module they import, or all of DIR's; in import order,
#       each to OUT/src/<its path>.bend (Agda2Bend/Cata.bend's fold, printed by
#       ToBend/Print.bend), logging per module the definitions read, the items
#       written and the places the fold could not fill (?TODO), by reason;
#       OUT/raw/<path>.bend holds every item before the gate (what failed)
#
#   agda2bend report OUT
#       the ledger summed up, and the causes ranked by the items they block
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
  IO.die(Unit, 2, "usage: agda2bend translate FILE.agda OUT | emit DIR OUT [MODULE...] | report OUT | decode FILE.sexp...")

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

# emit -------------------------------------------------------------------------

# A module of the export: its name, its file, the modules it imports.
type A2bMod is Data:
  A2bMod{name: List<&2, U32>, file: List<&2, U32>, imports: List<&2, List<&2, U32>>}

def a2b.mod0() -> A2bMod:
  A2bMod{Nil{}, Nil{}, Nil{}}

def a2b.hdr.of(+file: List<&2, U32>, t: A.AgTop) -> Maybe<&2, A2bMod>:
  match t:
    case A.AgTopMod{A.AgMod{nm, f, im, op, n}}:
      Some{A2bMod{nm, file, im}}
    case _:
      None{}

def a2b.hdr.got(+file: List<&2, U32>, r: X.TsxRd & Maybe<&2, X.Sx>) -> IO(Maybe<&2, A2bMod>):
  (rd, m) = r
  match m:
    case Some{x}:
      do IO<Maybe<&2, A2bMod>>:
        X.tsx.shut(rd)
        return a2b.hdr.of(file, A.aas.top(x))
    case None{}:
      do IO<Maybe<&2, A2bMod>>:
        X.tsx.shut(rd)
        return None{}

# a file's module header (its first expression)
def a2b.hdr(+file: List<&2, U32>) -> IO(Maybe<&2, A2bMod>):
  do IO<Maybe<&2, A2bMod>>:
    rd : X.TsxRd <- X.tsx.open(S.str(file))
    r : X.TsxRd & Maybe<&2, X.Sx> <- X.tsx.next(rd)
    a2b.hdr.got(file, r)

def a2b.mods.put(m: Maybe<&2, A2bMod>, ms: Map<&2, A2bMod>) -> Map<&2, A2bMod>:
  match m:
    case Some{A2bMod{+n, f, im}}:
      Map.set(&2, A2bMod, ms, S.str(n), A2bMod{n, f, im})
    case None{}:
      ms

# every module of the export by name (the index file is not a module)
def a2b.mods(fs: List<&2, List<&2, U32>>, ms: Map<&2, A2bMod>) -> IO(Map<&2, A2bMod>):
  match fs:
    case Nil{}:
      IO.pure(Map<&2, A2bMod>, ms)
    case +f <> t:
      do IO<Map<&2, A2bMod>>:
        m : Maybe<&2, A2bMod> <- a2b.hdr(f)
        a2b.mods(t, a2b.mods.put(m, ms))

def a2b.mod.got(r: Map<&2, A2bMod> & A2bMod) -> A2bMod:
  (m, x) = r
  x

def a2b.mod.get(+ms: Map<&2, A2bMod>, +n: List<&2, U32>) -> A2bMod:
  a2b.mod.got(Map.get(A2bMod, a2b.mod0(), ms, S.str(n)))

def a2b.has.got(r: Map<&2, Bool> & Bool) -> Bool:
  (m, b) = r
  b

def a2b.has(+seen: Map<&2, Bool>, +n: List<&2, U32>) -> Bool:
  a2b.has.got(Map.has(&2, Bool, seen, S.str(n)))

def a2b.known.got(r: Map<&2, A2bMod> & Bool) -> Bool:
  (m, b) = r
  b

def a2b.known(+ms: Map<&2, A2bMod>, +n: List<&2, U32>) -> Bool:
  a2b.known.got(Map.has(&2, A2bMod, ms, S.str(n)))

# Import order: a depth-first walk that writes a module after everything
# it imports.  A frame is a module to visit, or one whose imports are done.
type A2bFr is Data:
  A2bFr{n: List<&2, U32>, done: Bool}

type A2bDfs is Data:
  A2bDfs{stack: List<&2, A2bFr>, seen: Map<&2, Bool>, out: List<&2, List<&2, U32>>}

def a2b.frames.put(k: Bool, n: List<&2, U32>, rest: List<&2, A2bFr>) -> List<&2, A2bFr>:
  match k:
    case True{}:
      A2bFr{n, False{}} <> rest
    case False{}:
      rest

def a2b.frames(ns: List<&2, List<&2, U32>>, +ms: Map<&2, A2bMod>, rest: List<&2, A2bFr>) -> List<&2, A2bFr>:
  match ns:
    case Nil{}:
      rest
    case +n <> t:
      a2b.frames.put(a2b.known(ms, n), n, a2b.frames(t, ms, rest))

def a2b.mod.imports(m: A2bMod) -> List<&2, List<&2, U32>>:
  match m:
    case A2bMod{n, f, im}:
      im

def a2b.visit(seen: Bool, +n: List<&2, U32>, rest: List<&2, A2bFr>, sn: Map<&2, Bool>, out: List<&2, List<&2, U32>>, +ms: Map<&2, A2bMod>) -> A2bDfs:
  match seen:
    case True{}:
      A2bDfs{rest, sn, out}
    case False{}:
      A2bDfs{a2b.frames(a2b.mod.imports(a2b.mod.get(ms, n)), ms, A2bFr{n, True{}} <> rest), Map.set(&2, Bool, sn, S.str(n), True{}), out}

def a2b.dfs(fuel: Nat, s: A2bDfs, +ms: Map<&2, A2bMod>) -> A2bDfs:
  match fuel s:
    case 1n+p A2bDfs{A2bFr{n, True{}} <> rest, sn, out}:
      a2b.dfs(p, A2bDfs{rest, sn, n <> out}, ms)
    case 1n+p A2bDfs{A2bFr{+n, False{}} <> rest, +sn, out}:
      a2b.dfs(p, a2b.visit(a2b.has(sn, n), n, rest, sn, out, ms), ms)
    case _ s:
      s

def a2b.order.of(s: A2bDfs) -> List<&2, List<&2, U32>>:
  match s:
    case A2bDfs{st, sn, out}:
      List.reverse(&2, List<&2, U32>, out)

# the modules to translate, each after its imports
def a2b.order(roots: List<&2, List<&2, U32>>, +ms: Map<&2, A2bMod>) -> List<&2, List<&2, U32>>:
  a2b.order.of(a2b.dfs(100000000n, A2bDfs{a2b.frames(roots, ms, Nil{}), Map.new(&2, Bool), Nil{}}, ms))

# Aliases: a module's shortest name suffix (two parts at least, each a Bend
# name, joined by `_`) that no other module of the export shares.
def a2b.parts.go(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case p <> t:
      S.b(N.tnm.part(S.str(p))) <> a2b.parts.go(t)

def a2b.parts(+n: List<&2, U32>) -> List<&2, List<&2, U32>>:
  a2b.parts.go(S.split(n, 46))

def a2b.suffix(+k: Nat, +ps: List<&2, List<&2, U32>>) -> List<&2, U32>:
  S.join(List.drop(&2, List<&2, U32>, ps, Nat.sub(List.length(&2, List<&2, U32>, ps), k)), 95)

def a2b.suffix.count(+k: Nat, +s: List<&2, U32>, all: List<&2, List<&2, List<&2, U32>>>) -> Nat:
  match all:
    case Nil{}:
      0n
    case ps <> t:
      Nat.add(Bool.pick(Nat, S.eq(a2b.suffix(k, ps), s), 1n, 0n), a2b.suffix.count(k, s, t))

def a2b.alias.try(fuel: Nat, +k: Nat, +ps: List<&2, List<&2, U32>>, +all: List<&2, List<&2, List<&2, U32>>>, uniq: Bool) -> List<&2, U32>:
  match fuel uniq:
    case _ True{}:
      a2b.suffix(k, ps)
    case 0n False{}:
      a2b.suffix(k, ps)
    case 1n+p False{}:
      a2b.alias.try(p, 1n+k, ps, all, Nat.is_le(a2b.suffix.count(1n+k, a2b.suffix(1n+k, ps), all), 1n))

def a2b.alias.k0(+ps: List<&2, List<&2, U32>>) -> Nat:
  Bool.pick(Nat, Nat.is_lt(List.length(&2, List<&2, U32>, ps), 2n), 1n, 2n)

def a2b.alias(+ps: List<&2, List<&2, U32>>, +all: List<&2, List<&2, List<&2, U32>>>) -> List<&2, U32>:
  a2b.alias.try(List.length(&2, List<&2, U32>, ps), a2b.alias.k0(ps), ps, all, Nat.is_le(a2b.suffix.count(a2b.alias.k0(ps), a2b.suffix(a2b.alias.k0(ps), ps), all), 1n))

def a2b.aliases.go(ns: List<&2, List<&2, U32>>, +all: List<&2, List<&2, List<&2, U32>>>, al: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      al
    case +n <> t:
      a2b.aliases.go(t, all, Map.set(&2, List<&2, U32>, al, S.str(n), a2b.alias(a2b.parts(n), all)))

def a2b.all.parts(ns: List<&2, List<&2, U32>>) -> List<&2, List<&2, List<&2, U32>>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      a2b.parts(n) <> a2b.all.parts(t)

def a2b.aliases(+ns: List<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  a2b.aliases.go(ns, a2b.all.parts(ns), Map.new(&2, List<&2, U32>))

# A module's definitions, read one expression at a time.
type A2bRd is Type:
  A2bRd{rd: X.TsxRd, ds: List<&2, A.AgDecl>, more: Bool}

def a2b.rd.add(t: A.AgTop, ds: List<&2, A.AgDecl>) -> List<&2, A.AgDecl>:
  match t:
    case A.AgTopDef{d}:
      d <> ds
    case _:
      ds

def a2b.rd.got(ds: List<&2, A.AgDecl>, r: X.TsxRd & Maybe<&2, X.Sx>) -> IO(A2bRd):
  (rd, m) = r
  match m:
    case Some{x}:
      IO.pure(A2bRd, A2bRd{rd, a2b.rd.add(A.aas.top(x), ds), True{}})
    case None{}:
      IO.pure(A2bRd, A2bRd{rd, ds, False{}})

def a2b.rd.step(rd: X.TsxRd, ds: List<&2, A.AgDecl>) -> IO(A2bRd):
  do IO<A2bRd>:
    r : X.TsxRd & Maybe<&2, X.Sx> <- X.tsx.next(rd)
    a2b.rd.got(ds, r)

def a2b.rd.go(fuel: Nat, s: A2bRd) -> IO(A2bRd):
  match fuel s:
    case 1n+p A2bRd{rd, ds, True{}}:
      IO.bind(A2bRd, A2bRd, a2b.rd.step(rd, ds), a2b.rd.go(p))
    case _ s:
      IO.pure(A2bRd, s)

def a2b.rd.fin(s: A2bRd) -> IO(List<&2, A.AgDecl>):
  match s:
    case A2bRd{rd, ds, more}:
      do IO<List<&2, A.AgDecl>>:
        X.tsx.shut(rd)
        return List.reverse(&2, A.AgDecl, ds)

def a2b.decls(+file: List<&2, U32>) -> IO(List<&2, A.AgDecl>):
  do IO<List<&2, A.AgDecl>>:
    rd : X.TsxRd <- X.tsx.open(S.str(file))
    s : A2bRd <- a2b.rd.go(1000000n, A2bRd{rd, Nil{}, True{}})
    a2b.rd.fin(s)

# A definition's Bend name, unique in its module: the second and later of
# a name get _2, _3, ... (ToBend/Names.bend maps several Agda names to one).
def a2b.count(+x: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      Nat.add(Bool.pick(Nat, S.eq(h, x), 1n, 0n), a2b.count(x, t))

def a2b.uniq.of(+n: Nat, +b: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(n, 0n), b, List.append(&2, U32, b, 95 <> S.b(Nat.show(1n+n))))

def a2b.uniq(+b: List<&2, U32>, +used: List<&2, List<&2, U32>>) -> List<&2, U32>:
  a2b.uniq.of(a2b.count(b, used), b)

def a2b.dq(d: A.AgDecl) -> A.AgQ:
  match d:
    case A.AgDecl{q, qn, md, f, l, l0, l1, k, m, fl, lang, ty, dd}:
      q

# The module's symbols added to the table, and its definitions by key.
type A2bTabs is Data:
  A2bTabs{tab: Map<&2, C.ActSym>, unf: Map<&2, C.ActCopy>, dm: Map<&2, A.AgDecl>, used: List<&2, List<&2, U32>>, nk: Map<&2, String>}

# what the modules after this one see: the symbol table, the unfoldings,
# and the names that passed their module's gate (alias-qualified)
type A2bG is Data:
  A2bG{tab: Map<&2, C.ActSym>, unf: Map<&2, C.ActCopy>, kept: Map<&2, Bool>}

def a2b.unf.put(m: Maybe<&2, C.ActCopy>, +k: String, u: Map<&2, C.ActCopy>) -> Map<&2, C.ActCopy>:
  match m:
    case Some{c}:
      Map.set(&2, C.ActCopy, u, k, c)
    case None{}:
      u

# a definition's symbol; a constructor copy's is its original's (an
# earlier module's, already in the table)
def a2b.sym.src(m: Maybe<&2, A.AgQ>, +top: List<&2, U32>, +nm: List<&2, U32>, +d: A.AgDecl, +tab: Map<&2, C.ActSym>, +unf: Map<&2, C.ActCopy>) -> C.ActSym:
  match m:
    case Some{q}:
      C.act.sym.got(Map.get(C.ActSym, C.act.sym.of(top, nm, d, unf), tab, C.act.key(q)))
    case None{}:
      C.act.sym.of(top, nm, d, unf)

def a2b.sym.for(+top: List<&2, U32>, +nm: List<&2, U32>, +d: A.AgDecl, +tab: Map<&2, C.ActSym>, +unf: Map<&2, C.ActCopy>) -> C.ActSym:
  a2b.sym.src(C.act.con.src(d), top, nm, d, tab, unf)

def a2b.syms.one(+top: List<&2, U32>, +d: A.AgDecl, +nm: List<&2, U32>, t: A2bTabs) -> A2bTabs:
  match t:
    case A2bTabs{+tab, +unf, dm, used, nk}:
      A2bTabs{Map.set(&2, C.ActSym, tab, C.act.key(a2b.dq(d)), a2b.sym.for(top, nm, d, tab, unf)), a2b.unf.put(C.act.unf.of(d, unf), C.act.key(a2b.dq(d)), unf), Map.set(&2, A.AgDecl, dm, C.act.key(a2b.dq(d)), d), nm <> used, Map.set(&2, String, nk, S.str(nm), C.act.key(a2b.dq(d)))}

def a2b.syms(ds: List<&2, A.AgDecl>, +top: List<&2, U32>, t: A2bTabs) -> A2bTabs:
  match ds t:
    case Nil{} t:
      t
    case +d <> rest A2bTabs{tab, unf, dm, +used, nk}:
      a2b.syms(rest, top, a2b.syms.one(top, d, a2b.uniq(C.act.local(top, C.act.qs(a2b.dq(d))), used), A2bTabs{tab, unf, dm, used, nk}))

def a2b.items(ds: List<&2, A.AgDecl>, +env: C.ActEnv, +dm: Map<&2, A.AgDecl>) -> List<&2, T.BItem>:
  match ds:
    case Nil{}:
      Nil{}
    case d <> t:
      List.append(&2, T.BItem, C.act.items(d, env, dm), a2b.items(t, env, dm))

def a2b.fold.items(its: List<&2, T.BItem>, todo: Bool, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match its todo:
    case Nil{} _:
      acc
    case it <> t True{}:
      T.tba.item.fold(~T.tba.todos, it, a2b.fold.items(t, True{}, acc))
    case it <> t False{}:
      T.tba.item.fold(~T.tba.refs, it, a2b.fold.items(t, False{}, acc))

def a2b.head.of(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case h <> t:
      h
    case Nil{}:
      Nil{}

# Imports: the modules whose alias starts a name the items use, once each.
def a2b.head.part(+n: List<&2, U32>) -> List<&2, U32>:
  a2b.head.of(S.split(n, 46))

def a2b.imp.new(dup: Bool, +m: List<&2, U32>, seen: Map<&2, Bool>, acc: List<&2, List<&2, U32>>) -> Map<&2, Bool> & List<&2, List<&2, U32>>:
  match dup:
    case True{}:
      (seen, acc)
    case False{}:
      (Map.set(&2, Bool, seen, S.str(m), True{}), m <> acc)

def a2b.imp.add(+m: List<&2, U32>, found: Bool, +seen: Map<&2, Bool>, acc: List<&2, List<&2, U32>>) -> Map<&2, Bool> & List<&2, List<&2, U32>>:
  match found:
    case True{}:
      a2b.imp.new(a2b.has(seen, m), m, seen, acc)
    case False{}:
      (seen, acc)

def a2b.ral.got(r: Map<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, U32>:
  (m, x) = r
  x

def a2b.imp.step(+ral: Map<&2, List<&2, U32>>, +n: List<&2, U32>, st: Map<&2, Bool> & List<&2, List<&2, U32>>) -> Map<&2, Bool> & List<&2, List<&2, U32>>:
  (seen, acc) = st
  +m = a2b.ral.got(Map.get(List<&2, U32>, Nil{}, ral, S.str(a2b.head.part(n))))
  a2b.imp.add(m, Bool.not(S.eq(m, Nil{})), seen, acc)

def a2b.imps(ns: List<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, st: Map<&2, Bool> & List<&2, List<&2, U32>>) -> Map<&2, Bool> & List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      st
    case n <> t:
      a2b.imps(t, ral, a2b.imp.step(ral, n, st))

def a2b.snd(st: Map<&2, Bool> & List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  (seen, acc) = st
  List.reverse(&2, List<&2, U32>, acc)

def a2b.slashes(xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +h <> t:
      Nat.add(Bool.pick(Nat, U32.is_eq(h, 47), 1n, 0n), a2b.slashes(t))

def a2b.ups.more(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      List.append(&2, U32, S.b("../"), a2b.ups.more(p))

def a2b.ups(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      S.b("./")
    case 1n+p:
      List.append(&2, U32, S.b("../"), a2b.ups.more(p))

def a2b.import.of(+from: List<&2, U32>, +al: Map<&2, List<&2, U32>>, +m: List<&2, U32>) -> T.BImport:
  T.BImport{List.append(&2, U32, a2b.ups(a2b.slashes(C.act.path(from))), C.act.path(m)), a2b.ral.got(Map.get(List<&2, U32>, Nil{}, al, S.str(m)))}

def a2b.imports(ms: List<&2, List<&2, U32>>, +from: List<&2, U32>, +al: Map<&2, List<&2, U32>>) -> List<&2, T.BImport>:
  match ms:
    case Nil{}:
      Nil{}
    case m <> t:
      a2b.import.of(from, al, m) <> a2b.imports(t, from, al)

# the gaps' reasons, each with its count
type A2bCnt is Data:
  A2bCnt{k: List<&2, U32>, n: Nat}

# whether the first count is r's
def a2b.tally.hd(xs: List<&2, A2bCnt>, +r: List<&2, U32>) -> Bool:
  match xs:
    case A2bCnt{k, n} <> t:
      S.eq(k, r)
    case Nil{}:
      False{}

# one more of r (hit: the first count is r's, decided by the caller)
def a2b.tally.add(xs: List<&2, A2bCnt>, +r: List<&2, U32>, hit: Bool) -> List<&2, A2bCnt>:
  match xs hit:
    case Nil{} _:
      [A2bCnt{r, 1n}]
    case A2bCnt{k, +n} <> t True{}:
      A2bCnt{k, 1n+n} <> t
    case c <> +t False{}:
      c <> a2b.tally.add(t, r, a2b.tally.hd(t, r))

def a2b.tally.add.of(+r: List<&2, U32>, +acc: List<&2, A2bCnt>) -> List<&2, A2bCnt>:
  a2b.tally.add(acc, r, a2b.tally.hd(acc, r))

def a2b.tally(rs: List<&2, List<&2, U32>>, acc: List<&2, A2bCnt>) -> List<&2, A2bCnt>:
  match rs:
    case Nil{}:
      acc
    case r <> t:
      a2b.tally(t, a2b.tally.add.of(r, acc))

def a2b.tally.show(xs: List<&2, A2bCnt>) -> String:
  match xs:
    case Nil{}:
      ""
    case A2bCnt{k, n} <> t:
      "; " ++ Nat.show(n) ++ " " ++ S.str(k) ++ a2b.tally.show(t)

def a2b.defs.n(its: List<&2, T.BItem>) -> Nat:
  match its:
    case Nil{}:
      0n
    case T.BiDef{n, ps, r, b, d} <> t:
      1n+a2b.defs.n(t)
    case T.BiType{n, ps, d, cs, doc} <> t:
      1n+a2b.defs.n(t)
    case i <> t:
      a2b.defs.n(t)

def a2b.head.doc(+m: List<&2, U32>, +nd: Nat) -> List<&2, List<&2, U32>>:
  [List.append(&2, U32, S.b("Bend 2 translation of the Agda module "), m), S.b("by agda2bend (bend/Agda2Bend.bend) from agda-export's elaboration; " ++ Nat.show(nd) ++ " Agda definitions"), Nil{}]

# the ledger's lines for a module: every kept item, then every dropped one
# with its reason (module, Bend name, Agda name, status, reason; tabs)
def a2b.ledger.kept(+m: List<&2, U32>, its: List<&2, T.BItem>) -> List<&2, U32>:
  match its:
    case Nil{}:
      Nil{}
    case +it <> t:
      List.append(&2, U32, S.join([m, G.tgt.name(it), G.tgt.agda(it), S.b("checked"), Nil{}], 9), 10 <> a2b.ledger.kept(m, t))

def a2b.ledger.drops(+m: List<&2, U32>, ds: List<&2, G.TgtDrop>) -> List<&2, U32>:
  match ds:
    case Nil{}:
      Nil{}
    case G.TgtDrop{n, a, w, d} <> t:
      List.append(&2, U32, S.join([m, n, a, S.b(Bool.pick(String, d, "dependent", "dropped")), w], 9), 10 <> a2b.ledger.drops(m, t))

def a2b.dropped.n(ds: List<&2, G.TgtDrop>, +dep: Bool) -> Nat:
  match ds:
    case Nil{}:
      0n
    case G.TgtDrop{n, a, w, +d} <> t:
      Nat.add(Bool.pick(Nat, Bool.or(Bool.and(d, dep), Bool.and(Bool.not(d), Bool.not(dep))), 1n, 0n), a2b.dropped.n(t, dep))

# the names a module's kept items give the modules after it, as they write
# them: its alias, a dot, the item's name (a type's constructors too)
def a2b.kept.ctors(+a: List<&2, U32>, cs: List<&2, T.BCtor>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      acc
    case T.BCtor{c, fs} <> t:
      List.append(&2, U32, a, 46 <> c) <> a2b.kept.ctors(a, t, acc)

def a2b.kept.of(+a: List<&2, U32>, its: List<&2, T.BItem>) -> List<&2, List<&2, U32>>:
  match its:
    case Nil{}:
      Nil{}
    case T.BiType{n, ps, d, cs, doc} <> t:
      List.append(&2, U32, a, 46 <> n) <> a2b.kept.ctors(a, cs, a2b.kept.of(a, t))
    case T.BiDef{n, ps, ret, body, doc} <> t:
      List.append(&2, U32, a, 46 <> n) <> a2b.kept.of(a, t)
    case i <> t:
      a2b.kept.of(a, t)

def a2b.kept.add(ns: List<&2, List<&2, U32>>, k: Map<&2, Bool>) -> Map<&2, Bool>:
  match ns:
    case Nil{}:
      k
    case n <> t:
      a2b.kept.add(t, Map.set(&2, Bool, k, S.str(n), True{}))

def a2b.gated(+out: String, +m: List<&2, U32>, +a: List<&2, U32>, +nd: Nat, +gaps: List<&2, List<&2, U32>>, +nits: Nat, r: G.TgtRun) -> IO(List<&2, List<&2, U32>>):
  match r:
    case G.TgtRun{G.TgtSt{+its, +ds}, done, checks}:
      do IO<List<&2, List<&2, U32>>>:
        S.add(out ++ "/ledger.tsv", List.append(&2, U32, a2b.ledger.kept(m, its), a2b.ledger.drops(m, List.reverse(&2, G.TgtDrop, ds))))
        Ck.log("emit " ++ S.str(m) ++ ": " ++ Nat.show(nd) ++ " definitions, " ++ Nat.show(nits) ++ " items: " ++ Nat.show(List.length(&2, T.BItem, its)) ++ " check, " ++ Nat.show(a2b.dropped.n(ds, False{})) ++ " dropped, " ++ Nat.show(a2b.dropped.n(ds, True{})) ++ " dependents (" ++ Nat.show(checks) ++ " checks); gaps " ++ Nat.show(List.length(&2, List<&2, U32>, gaps)) ++ a2b.tally.show(a2b.tally(gaps, Nil{})))
        return a2b.kept.of(a, its)

# A module's items through the gate: first those using another module's
# dropped names go (G.tgt.ext), then the checks.  The file before the gate
# is OUT/raw/<path>.bend.
def a2b.em.write(+out: String, +m: List<&2, U32>, +a: List<&2, U32>, +kept: Map<&2, Bool>, +ral: Map<&2, List<&2, U32>>, +its: List<&2, T.BItem>, +ims: List<&2, T.BImport>, +nd: Nat, +gaps: List<&2, List<&2, U32>>, +nits: Nat) -> IO(List<&2, List<&2, U32>>):
  +path = out ++ "/src/" ++ S.str(C.act.path(m))
  +raw = out ++ "/raw/" ++ S.str(C.act.path(m))
  do IO<List<&2, List<&2, U32>>>:
    S.mkdir(S.parent(path))
    S.mkdir(S.parent(raw))
    S.write(raw, P.tpr.file(T.BFile{a2b.head.doc(m, nd), ims, its}))
    +bend : String <- S.env("BEND", "bend")
    r : G.TgtRun <- G.tgt.gate(bend, 900, path, a2b.head.doc(m, nd), ims, G.tgt.ext(its, kept, ral))
    a2b.gated(out, m, a, nd, gaps, nits, r)

def a2b.em.items(+out: String, +m: List<&2, U32>, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, +kept: Map<&2, Bool>, +nd: Nat, +its: List<&2, T.BItem>) -> IO(List<&2, List<&2, U32>>):
  a2b.em.write(out, m, a2b.ral.got(Map.get(List<&2, U32>, Nil{}, al, S.str(m))), kept, ral, its, a2b.imports(a2b.snd(a2b.imps(a2b.fold.items(its, False{}, Nil{}), ral, (Map.new(&2, Bool), Nil{}))), m, al), nd, a2b.fold.items(its, True{}, Nil{}), a2b.defs.n(its))

# The quantity rounds (ToBend/Copy.bend): the module is translated, each
# def's parameters' modes are read off its body and put into its symbol,
# and while any rose the module is translated again, so its calls pass
# templates as such; modes only rise, so a few rounds settle.  The items
# then get their lambdas and pattern variables marked and templates first.
type A2bRe is Data:
  A2bRe{tab: Map<&2, C.ActSym>, changed: Bool}

def a2b.nk.got(r: Map<&2, String> & String) -> String:
  (m, k) = r
  k

def a2b.re.set(+k: String, r: C.ActSym & Bool, tab: Map<&2, C.ActSym>, ch: Bool) -> A2bRe:
  (s, c) = r
  A2bRe{Map.set(&2, C.ActSym, tab, k, s), Bool.or(c, ch)}

def a2b.re.one(+k: String, +hdr: List<&2, T.BMode>, r: A2bRe) -> A2bRe:
  match r:
    case A2bRe{+tab, ch}:
      a2b.re.set(k, C.act.sym.remode(C.act.sym.got(Map.get(C.ActSym, C.act.sym0(), tab, k)), hdr), tab, ch)

def a2b.re.items(its: List<&2, T.BItem>, +nk: Map<&2, String>, +datas: List<&2, List<&2, U32>>, r: A2bRe) -> A2bRe:
  match its:
    case Nil{}:
      r
    case T.BiDef{+n, ps, ret, body, doc} <> t:
      a2b.re.items(t, nk, datas, a2b.re.one(a2b.nk.got(Map.get(String, "", nk, S.str(n))), Q.tcp.decide(T.BiDef{n, ps, ret, body, doc}, datas), r))
    case i <> t:
      a2b.re.items(t, nk, datas, r)

type A2bRound is Data:
  A2bRound{tab: Map<&2, C.ActSym>, its: List<&2, T.BItem>}

# a round's state: the table, the items of the last translation, whether
# that round changed a mode (the first round starts as changed)
type A2bRst is Data:
  A2bRst{tab: Map<&2, C.ActSym>, its: List<&2, T.BItem>, changed: Bool}

def a2b.rst.of(r: A2bRe, its: List<&2, T.BItem>) -> A2bRst:
  match r:
    case A2bRe{tab, c}:
      A2bRst{tab, its, c}

def a2b.round(fuel: Nat, +ds: List<&2, A.AgDecl>, +m: List<&2, U32>, +al: Map<&2, List<&2, U32>>, +unf: Map<&2, C.ActCopy>, +dm: Map<&2, A.AgDecl>, +nk: Map<&2, String>, st: A2bRst) -> A2bRound:
  match fuel st:
    case 1n+p A2bRst{+tab, its, True{}}:
      +its2 = a2b.items(ds, C.ActEnv{m, tab, al, unf}, dm)
      a2b.round(p, ds, m, al, unf, dm, nk, a2b.rst.of(a2b.re.items(its2, nk, Q.tcp.datas(its2), A2bRe{tab, False{}}), its2))
    case _ A2bRst{tab, its, c}:
      A2bRound{tab, its}

def a2b.finish(its: List<&2, T.BItem>, +datas: List<&2, List<&2, U32>>) -> List<&2, T.BItem>:
  match its:
    case Nil{}:
      Nil{}
    case +it <> t:
      Q.tcp.finish(it, Q.tcp.decide(it, datas)) <> a2b.finish(t, datas)

def a2b.finish.of(+its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  a2b.finish(its, Q.tcp.datas(its))

def a2b.em.round(+out: String, +m: List<&2, U32>, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, +nd: Nat, +kept: Map<&2, Bool>, +unf: Map<&2, C.ActCopy>, r: A2bRound) -> IO(A2bG):
  match r:
    case A2bRound{+tab, its}:
      do IO<A2bG>:
        kn : List<&2, List<&2, U32>> <- a2b.em.items(out, m, al, ral, kept, nd, O.tor.order(a2b.finish.of(its)))
        return A2bG{tab, unf, a2b.kept.add(kn, kept)}

def a2b.em.tabs(+out: String, +m: List<&2, U32>, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, +ds: List<&2, A.AgDecl>, +kept: Map<&2, Bool>, t: A2bTabs) -> IO(A2bG):
  match t:
    case A2bTabs{tab, +unf, +dm, used, +nk}:
      a2b.em.round(out, m, al, ral, List.length(&2, A.AgDecl, ds), kept, unf, a2b.round(5n, ds, m, al, unf, dm, nk, A2bRst{tab, Nil{}, True{}}))

# A module's translation without the gate, the tests' entry: its items in
# Bend's order and the state the modules after it see (the kept names as
# they were: only the gate adds to them).
type A2bTr is Data:
  A2bTr{its: List<&2, T.BItem>, g: A2bG}

def a2b.mod.items.fin(+kept: Map<&2, Bool>, +unf: Map<&2, C.ActCopy>, r: A2bRound) -> A2bTr:
  match r:
    case A2bRound{tab, its}:
      A2bTr{O.tor.order(a2b.finish.of(its)), A2bG{tab, unf, kept}}

def a2b.mod.items.of(+m: List<&2, U32>, +al: Map<&2, List<&2, U32>>, +ds: List<&2, A.AgDecl>, +kept: Map<&2, Bool>, t: A2bTabs) -> A2bTr:
  match t:
    case A2bTabs{tab, +unf, +dm, used, +nk}:
      a2b.mod.items.fin(kept, unf, a2b.round(5n, ds, m, al, unf, dm, nk, A2bRst{tab, Nil{}, True{}}))

def a2b.mod.items(+m: List<&2, U32>, +al: Map<&2, List<&2, U32>>, +ds: List<&2, A.AgDecl>, g: A2bG) -> A2bTr:
  match g:
    case A2bG{tab, unf, +kept}:
      a2b.mod.items.of(m, al, ds, kept, a2b.syms(ds, m, A2bTabs{tab, unf, Map.new(&2, A.AgDecl), Nil{}, Map.new(&2, String)}))

# the text of a module's file before the gate (OUT/raw/<path>.bend)
def a2b.raw.text(+m: List<&2, U32>, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, +nd: Nat, +its: List<&2, T.BItem>) -> List<&2, U32>:
  P.tpr.file(T.BFile{a2b.head.doc(m, nd), a2b.imports(a2b.snd(a2b.imps(a2b.fold.items(its, False{}, Nil{}), ral, (Map.new(&2, Bool), Nil{}))), m, al), its})

def a2b.mod.file(m: A2bMod) -> List<&2, U32>:
  match m:
    case A2bMod{n, f, im}:
      f

# one module: its definitions read, its symbols added, its file written;
# the table with its symbols for the modules after it
def a2b.em.mod(+out: String, +ms: Map<&2, A2bMod>, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, +m: List<&2, U32>, g: A2bG) -> IO(A2bG):
  match g:
    case A2bG{tab, unf, +kept}:
      do IO<A2bG>:
        +ds : List<&2, A.AgDecl> <- a2b.decls(a2b.mod.file(a2b.mod.get(ms, m)))
        a2b.em.tabs(out, m, al, ral, ds, kept, a2b.syms(ds, m, A2bTabs{tab, unf, Map.new(&2, A.AgDecl), Nil{}, Map.new(&2, String)}))

def a2b.em.mods(order: List<&2, List<&2, U32>>, +out: String, +ms: Map<&2, A2bMod>, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, g: A2bG) -> IO(Unit):
  match order:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case m <> t:
      do IO<Unit>:
        g2 : A2bG <- a2b.em.mod(out, ms, al, ral, m, g)
        a2b.em.mods(t, out, ms, al, ral, g2)

# alias -> module, the reverse of the aliases
def a2b.ral(ns: List<&2, List<&2, U32>>, +al: Map<&2, List<&2, U32>>, acc: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      acc
    case +n <> t:
      a2b.ral(t, al, Map.set(&2, List<&2, U32>, acc, S.str(a2b.ral.got(Map.get(List<&2, U32>, Nil{}, al, S.str(n)))), n))

def a2b.not.index(+f: List<&2, U32>) -> Bool:
  Bool.not(S.suffix(f, S.b("/_index.sexp")))

def a2b.names(ms: List<&2, A2bMod>) -> List<&2, List<&2, U32>>:
  match ms:
    case Nil{}:
      Nil{}
    case A2bMod{n, f, im} <> t:
      n <> a2b.names(t)

def a2b.emit.go(+out: String, roots: List<&2, List<&2, U32>>, +ms: Map<&2, A2bMod>) -> IO(Unit):
  +order = a2b.order(roots, ms)
  +al = a2b.aliases(order)
  do IO<Unit>:
    Ck.log("emit: " ++ Nat.show(List.length(&2, List<&2, U32>, order)) ++ " modules in import order, to " ++ out ++ "/src")
    a2b.em.mods(order, out, ms, al, a2b.ral(order, al, Map.new(&2, List<&2, U32>)), A2bG{Map.new(&2, C.ActSym), Map.new(&2, C.ActCopy), Map.new(&2, Bool)})

def a2b.strs(xs: List<String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      S.b(h) <> a2b.strs(t)

def a2b.roots(+want: List<&2, List<&2, U32>>, ms: Map<&2, A2bMod>) -> List<&2, List<&2, U32>>:
  match want:
    case Nil{}:
      a2b.names(Map.values(&2, A2bMod, ms))
    case h <> t:
      h <> t

def a2b.emit(xs: List<String>) -> IO(Unit):
  match xs:
    case dir <> +out <> more:
      do IO<Unit>:
        fs : List<&2, List<&2, U32>> <- S.glob(dir ++ "/*.sexp")
        +ms : Map<&2, A2bMod> <- a2b.mods(List.filter(~List<&2, U32>, ~(f => a2b.not.index(f)), fs), Map.new(&2, A2bMod))
        a2b.emit.go(out, a2b.roots(a2b.strs(more), ms), ms)
    case _:
      a2b.usage()

# report -----------------------------------------------------------------------
#
#   agda2bend report OUT
#
# The ledger (OUT/ledger.tsv) summed up: items checked, dropped and
# dependent; then the causes, ranked by the items each blocks: a drop's
# reason (its class: the variable names a checker message mentions differ
# from item to item) blocks the item and every item that depends on it,
# within its module and across modules (a dependent's reason names what it
# uses, and where); each cause with its count and one item it failed, the
# smallest example to fix first.

# a ledger row: module, Bend name, Agda name, status, reason
type A2bRow is Data:
  A2bRow{mod: List<&2, U32>, name: List<&2, U32>, agda: List<&2, U32>, st: List<&2, U32>, why: List<&2, U32>}

def a2b.rp.nth(n: Nat, xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match n xs:
    case 0n h <> t:
      h
    case 1n+p h <> t:
      a2b.rp.nth(p, t)
    case _ Nil{}:
      Nil{}

def a2b.rp.row(+fs: List<&2, List<&2, U32>>) -> A2bRow:
  A2bRow{a2b.rp.nth(0n, fs), a2b.rp.nth(1n, fs), a2b.rp.nth(2n, fs), a2b.rp.nth(3n, fs), a2b.rp.nth(4n, fs)}

def a2b.rp.rows.go(ls: List<&2, List<&2, U32>>) -> List<&2, A2bRow>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      a2b.rp.row(S.split(l, 9)) <> a2b.rp.rows.go(t)

# the ledger's rows (its lines, empty ones aside)
def a2b.rp.rows(ls: List<&2, List<&2, U32>>) -> List<&2, A2bRow>:
  a2b.rp.rows.go(List.filter(~List<&2, U32>, ~(l => Bool.not(S.eq(l, Nil{}))), ls))

def a2b.rp.key(+m: List<&2, U32>, +n: List<&2, U32>) -> String:
  S.str(m) ++ "|" ++ S.str(n)

def a2b.rp.map(rs: List<&2, A2bRow>, acc: Map<&2, A2bRow>) -> Map<&2, A2bRow>:
  match rs:
    case Nil{}:
      acc
    case A2bRow{+m, +n, a, s, w} <> t:
      a2b.rp.map(t, Map.set(&2, A2bRow, acc, a2b.rp.key(m, n), A2bRow{m, n, a, s, w}))

def a2b.rp.cut.go(xs: List<&2, U32>, +stop: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case Nil{} _:
      Nil{}
    case h <> t True{}:
      Nil{}
    case h <> +t False{}:
      h <> a2b.rp.cut.go(t, stop, S.prefix(t, stop))

# What a dependent uses, as a key: "uses NAME in MODULE, ..." (another
# module's) or "uses NAME" (its own module's); empty when the reason is
# not a use.
def a2b.rp.cut(+xs: List<&2, U32>, +stop: List<&2, U32>) -> List<&2, U32>:
  a2b.rp.cut.go(xs, stop, S.prefix(xs, stop))

def a2b.rp.after.of(m: Maybe<&2, Nat>, +xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  match m:
    case Some{i}:
      List.drop(&2, U32, xs, Nat.add(i, n))
    case None{}:
      Nil{}

def a2b.rp.after(+xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  a2b.rp.after.of(S.find(xs, p, 0n), xs, S.len(p))

def a2b.rp.target.of(cross: Bool, +m: List<&2, U32>, +u: List<&2, U32>) -> String:
  match cross:
    case True{}:
      a2b.rp.key(a2b.rp.cut(a2b.rp.after(u, S.b(" in ")), S.b(", which")), a2b.rp.cut(u, S.b(" in ")))
    case False{}:
      a2b.rp.key(m, u)

def a2b.rp.target(+m: List<&2, U32>, +why: List<&2, U32>) -> String:
  a2b.rp.target.of(S.infix(why, S.b(", which dropped it")), m, S.strip(why, S.b("uses ")))

# A reason's class: what a checker message says, without the names it
# mentions.
def a2b.rp.class(+w: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.infix(w, S.b("consumed more than once")), S.b("a value used twice (consumed more than once)"),
  Bool.pick(List<&2, U32>, Bool.and(S.prefix(w, S.b("expected : -")), S.infix(w, S.b("observed : "))), S.b("an erased binder used live (expected -x, observed x)"),
  Bool.pick(List<&2, U32>, S.prefix(w, S.b("gap: a name the symbol table does not have")), S.b("gap: a name the symbol table does not have"),
  Bool.pick(List<&2, U32>, S.prefix(w, S.b("gap: a constructor")), S.b("gap: a constructor the symbol table does not have"),
  Bool.pick(List<&2, U32>, S.prefix(w, S.b("uses ")), S.b("uses a name its module never emitted"),
  List.take(&2, U32, w, 72n))))))

def a2b.rp.empty() -> A2bRow:
  A2bRow{Nil{}, Nil{}, Nil{}, Nil{}, Nil{}}

def a2b.rp.st.is(+s: String, r: A2bRow) -> Bool:
  match r:
    case A2bRow{m, n, a, st, w}:
      S.eq(st, S.b(s))

def a2b.rp.row.got(r: Map<&2, A2bRow> & A2bRow) -> A2bRow:
  (x, y) = r
  y

def a2b.rp.row.get(+m: Map<&2, A2bRow>, +k: String) -> A2bRow:
  a2b.rp.row.got(Map.get(A2bRow, A2bRow{Nil{}, Nil{}, Nil{}, Nil{}, Nil{}}, m, k))

def a2b.rp.next.of(dep: Bool, +r: A2bRow, +m: Map<&2, A2bRow>) -> A2bRow:
  match dep r:
    case True{} A2bRow{+mo, n, a, s, +w}:
      a2b.rp.row.get(m, a2b.rp.target(mo, w))
    case False{} r:
      a2b.rp.empty()

# the row a dependent uses (the empty row for any other)
def a2b.rp.next(+r: A2bRow, +m: Map<&2, A2bRow>) -> A2bRow:
  a2b.rp.next.of(a2b.rp.st.is("dependent", r), r, m)

# the root of a row: what its dependents' chain of uses ends at (nx: the
# row r uses, decided by the caller; fuel bounds the chain)
def a2b.rp.root(fuel: Nat, r: A2bRow, nx: A2bRow, +m: Map<&2, A2bRow>) -> A2bRow:
  match fuel nx:
    case 1n+p A2bRow{Nil{}, n, a, s, w}:
      r
    case 1n+p A2bRow{+mo, +n, +a, +s, +w}:
      a2b.rp.root(p, A2bRow{mo, n, a, s, w}, a2b.rp.next(A2bRow{mo, n, a, s, w}, m), m)
    case 0n nx:
      r

# A cause's tally: its class, the items it blocks, the drops at its root,
# and an example root.
type A2bCause is Data:
  A2bCause{cls: List<&2, U32>, blocked: Nat, roots: Nat, ex: A2bRow}

def a2b.rp.is.root(+r: A2bRow, +x: A2bRow) -> Bool:
  match r x:
    case A2bRow{m1, n1, a1, s1, w1} A2bRow{m2, n2, a2, s2, w2}:
      Bool.and(S.eq(m1, m2), S.eq(n1, n2))

def a2b.rp.hd(cs: List<&2, A2bCause>, +cls: List<&2, U32>) -> Bool:
  match cs:
    case A2bCause{c, b, n, e} <> t:
      S.eq(c, cls)
    case Nil{}:
      False{}

# one more item for the cause cls (hit: the first tally is cls's, decided
# by the caller)
def a2b.rp.add(+cls: List<&2, U32>, +self: Bool, +ex: A2bRow, cs: List<&2, A2bCause>, hit: Bool) -> List<&2, A2bCause>:
  match cs hit:
    case Nil{} _:
      [A2bCause{cls, 1n, Bool.pick(Nat, self, 1n, 0n), ex}]
    case A2bCause{c, +b, +n, e} <> t True{}:
      A2bCause{c, 1n+b, Nat.add(n, Bool.pick(Nat, self, 1n, 0n)), e} <> t
    case x <> +t False{}:
      x <> a2b.rp.add(cls, self, ex, t, a2b.rp.hd(t, cls))

def a2b.rp.add.of(+cls: List<&2, U32>, +self: Bool, +ex: A2bRow, +cs: List<&2, A2bCause>) -> List<&2, A2bCause>:
  a2b.rp.add(cls, self, ex, cs, a2b.rp.hd(cs, cls))

def a2b.rp.tally.root(+r: A2bRow, +root: A2bRow, cs: List<&2, A2bCause>) -> List<&2, A2bCause>:
  match root:
    case A2bRow{m, n, a, s, +w}:
      a2b.rp.add.of(a2b.rp.class(w), a2b.rp.is.root(r, A2bRow{m, n, a, s, w}), A2bRow{m, n, a, s, w}, cs)

def a2b.rp.tally.row(+r: A2bRow, +m: Map<&2, A2bRow>, cs: List<&2, A2bCause>) -> List<&2, A2bCause>:
  a2b.rp.tally.root(r, a2b.rp.root(64n, r, a2b.rp.next(r, m), m), cs)

def a2b.rp.tally.one(chk: Bool, +r: A2bRow, +m: Map<&2, A2bRow>, cs: List<&2, A2bCause>) -> List<&2, A2bCause>:
  match chk:
    case True{}:
      cs
    case False{}:
      a2b.rp.tally.row(r, m, cs)

def a2b.rp.tally(rs: List<&2, A2bRow>, +m: Map<&2, A2bRow>, cs: List<&2, A2bCause>) -> List<&2, A2bCause>:
  match rs:
    case Nil{}:
      cs
    case +r <> t:
      a2b.rp.tally(t, m, a2b.rp.tally.one(a2b.rp.st.is("checked", r), r, m, cs))

def a2b.rp.status(+s: String, rs: List<&2, A2bRow>) -> Nat:
  match rs:
    case Nil{}:
      0n
    case A2bRow{m, n, a, +st, w} <> t:
      Nat.add(Bool.pick(Nat, S.eq(st, S.b(s)), 1n, 0n), a2b.rp.status(s, t))

# causes by blocked count, the most first (insertion sort)
def a2b.rp.blocked(c: A2bCause) -> Nat:
  match c:
    case A2bCause{cl, b, n, e}:
      b

def a2b.rp.first(+b: Nat, cs: List<&2, A2bCause>) -> Bool:
  match cs:
    case c <> t:
      Nat.is_ge(b, a2b.rp.blocked(c))
    case Nil{}:
      True{}

# c into cs (sorted, the most blocked first); here: c goes in front,
# decided by the caller
def a2b.rp.ins(cs: List<&2, A2bCause>, +b: Nat, c: A2bCause, here: Bool) -> List<&2, A2bCause>:
  match cs here:
    case cs True{}:
      c <> cs
    case h <> +t False{}:
      h <> a2b.rp.ins(t, b, c, a2b.rp.first(b, t))
    case Nil{} False{}:
      [c]

def a2b.rp.ins.of(+c: A2bCause, +cs: List<&2, A2bCause>) -> List<&2, A2bCause>:
  a2b.rp.ins(cs, a2b.rp.blocked(c), c, a2b.rp.first(a2b.rp.blocked(c), cs))

def a2b.rp.sort(cs: List<&2, A2bCause>) -> List<&2, A2bCause>:
  match cs:
    case Nil{}:
      Nil{}
    case c <> t:
      a2b.rp.ins.of(c, a2b.rp.sort(t))

def a2b.rp.show(cs: List<&2, A2bCause>) -> IO(Unit):
  match cs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case A2bCause{c, b, n, A2bRow{m, nm, a, s, w}} <> t:
      do IO<Unit>:
        IO.print("  " ++ Nat.show(b) ++ " blocked, " ++ Nat.show(n) ++ " at the root: " ++ S.str(c))
        IO.print("      e.g. " ++ S.str(m) ++ " " ++ S.str(nm) ++ " (" ++ S.str(a) ++ "): " ++ S.str(List.take(&2, U32, w, 160n)))
        a2b.rp.show(t)

def a2b.report.of(+rs: List<&2, A2bRow>) -> IO(Unit):
  do IO<Unit>:
    IO.print("agda2bend report: " ++ Nat.show(List.length(&2, A2bRow, rs)) ++ " items: " ++ Nat.show(a2b.rp.status("checked", rs)) ++ " checked, " ++ Nat.show(a2b.rp.status("dropped", rs)) ++ " dropped, " ++ Nat.show(a2b.rp.status("dependent", rs)) ++ " dependents")
    IO.print("causes, by the items they block (the drop itself and its dependents):")
    a2b.rp.show(List.take(&2, A2bCause, a2b.rp.sort(a2b.rp.tally(rs, a2b.rp.map(rs, Map.new(&2, A2bRow)), Nil{})), 40n))

def a2b.report(xs: List<String>) -> IO(Unit):
  match xs:
    case out <> more:
      do IO<Unit>:
        +t : List<&2, U32> <- S.read(out ++ "/ledger.tsv")
        a2b.report.of(a2b.rp.rows(S.split.lines(t)))
    case _:
      a2b.usage()

# translate --------------------------------------------------------------------
#
#   agda2bend translate FILE.agda OUT
#
# Agda code in, Bend out: agda-export (AGDA_EXPORT, its AGDA_DIR naming the
# libraries) elaborates FILE and writes its module and every module it
# imports to OUT/export, from FILE's library root (the nearest directory
# up with an .agda-lib, as agda is run); then `emit` translates that
# module's cone into OUT/src, gated, with OUT/ledger.tsv.  Modules already
# exported are kept (agda-export --export-skip-existing).

def a2b.libs.got(xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      True{}

def a2b.root.of(fuel: Nat, +dir: String, has: Bool) -> IO(String):
  match fuel has:
    case _ True{}:
      IO.pure(String, dir)
    case 0n False{}:
      IO.die(String, 1, "agda2bend: no .agda-lib above the file")
    case 1n+p False{}:
      do IO<String>:
        +up : String = S.parent(dir)
        ls : List<&2, List<&2, U32>> <- S.glob(up ++ "/*.agda-lib")
        a2b.root.of(p, up, a2b.libs.got(ls))

# the nearest directory at or above dir holding an .agda-lib
def a2b.root(+dir: String) -> IO(String):
  do IO<String>:
    ls : List<&2, List<&2, U32>> <- S.glob(dir ++ "/*.agda-lib")
    a2b.root.of(64n, dir, a2b.libs.got(ls))

def a2b.file.mod(ms: List<&2, A2bMod>, +file: List<&2, U32>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      Nil{}
    case A2bMod{+n, +f, im} <> t:
      Bool.pick(List<&2, U32>, S.eq(f, file), n, a2b.file.mod(t, file))

def a2b.translate.ok(ok: Bool, +file: String, +out: String, +o: S.Out) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "agda2bend: agda-export failed:\n" ++ S.str(S.Out.text(o)))
    case True{}:
      do IO<Unit>:
        fs : List<&2, List<&2, U32>> <- S.glob(out ++ "/export/*.sexp")
        +ms : Map<&2, A2bMod> <- a2b.mods(List.filter(~List<&2, U32>, ~(f => a2b.not.index(f)), fs), Map.new(&2, A2bMod))
        +m : List<&2, U32> = a2b.file.mod(Map.values(&2, A2bMod, ms), S.b(file))
        a2b.emit.go(out, [m], ms)

def a2b.translate.exported(+file: String, +out: String, +o: S.Out) -> IO(Unit):
  a2b.translate.ok(U32.is_eq(S.Out.status(o), 0), file, out, o)

def a2b.translate.go(+file: String, +out: String, +root: String) -> IO(Unit):
  do IO<Unit>:
    +agda : String <- S.env("AGDA_EXPORT", "agda-export")
    Ck.log("translate: agda-export " ++ file ++ " from " ++ root)
    o : S.Out <- S.run(root, Nil{}, 86400, agda, ["--export-dir=" ++ out ++ "/export", "--export-skip-existing", file], Nil{})
    a2b.translate.exported(file, out, o)

def a2b.translate(xs: List<String>) -> IO(Unit):
  match xs:
    case f <> +out <> more:
      do IO<Unit>:
        +file : String <- S.realpath(f)
        +o : String <- S.realpath(out)
        S.mkdir(o)
        +root : String <- a2b.root(S.parent(file))
        a2b.translate.go(file, o, root)
    case _:
      a2b.usage()

# main -------------------------------------------------------------------------

def a2b.args(xs: List<String>) -> IO(Unit):
  match xs:
    case "translate" <> more:
      a2b.translate(more)
    case "emit" <> more:
      a2b.emit(more)
    case "decode" <> more:
      a2b.decode(more)
    case "report" <> more:
      a2b.report(more)
    case _:
      a2b.usage()

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked
    argv : List<String> <- IO.args()
    a2b.args(List.tail(&1, String, argv))
