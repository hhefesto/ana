import Base
import ../Sys.bend as S
import ../CorpusV2/MutOps.bend as M

# The mutation operators of bend-corpus-v2 mutate (bend/CorpusV2/MutOps.bend,
# 2026-10-16) against their meaning, on small bodies written here: the
# tokens joined are the text byte for byte; each operator gives exactly the
# mutants its comment says, in the order of the place each changes, and none
# where it does not apply (a match of one arm, a binder used once, the `+`
# of `1n+p`, a body without imports); every mutant of every operator differs
# from its body; a unit's tries take at most `cap` an operator, each text
# once, never the body, the operators in turn, and the k-th try of operator
# o is its mutants' rotation's k-th.  Each check prints `ok NAME` or `FAIL
# NAME`; any FAIL exits 1.  Run from bend/tests.

type MtCk is Data:
  MtCk{name: String, ok: Bool}

def mt.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "mutops: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def mt.say(cs: List<&2, MtCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      mt.end(Nat.is_eq(bad, 0n), bad, names)
    case MtCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        mt.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def mt.texts.eq(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(S.eq(x, y), mt.texts.eq(xt, yt))
    case _ _:
      False{}

# the body with its first `a` written `b`
def mt.rep(+body: String, +a: String, +b: String) -> List<&2, U32>:
  S.replace.first(S.b(body), S.b(a), S.b(b))

type MtRp is Data:
  MtRp{a: String, b: String}

def mt.reps(+body: String, ps: List<&2, MtRp>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case MtRp{a, b} <> t:
      mt.rep(body, a, b) <> mt.reps(body, t)

# operator o of a unit gives exactly these
def mt.op.is(+b: String, +o: Nat, +u: M.MtoU, +want: List<&2, List<&2, U32>>) -> MtCk:
  MtCk{b ++ " " ++ M.mto.op.name(o) ++ ": " ++ Nat.show(List.length(&2, List<&2, U32>, want)) ++ " mutants, as said", mt.texts.eq(M.mto.op(o, u), want)}

# Bodies ---------------------------------------------------------------------------------------------

def mt.b1() -> String:
  "  match n:\n    case 0n:\n      0n\n    case 1n+p:\n      Nat.add(p, 2n)\n"

def mt.u1() -> M.MtoU:
  M.MtoU{S.b("import Base\n\n"), S.b("def f(n: Nat) -> Nat:\n"), S.b(mt.b1()), False{}}

def mt.b2() -> String:
  "  do IO<Unit>:\n    +xs : List<&2, U32> <- S.read(path)\n    S.write(path, xs)\n    S.add(path, xs)\n    IO.pure(Unit, Unit{})\n"

def mt.u2() -> M.MtoU:
  M.MtoU{S.b("import Base\nimport ./Sys.bend as S\n\n"), S.b("def g(+path: String, ok: Bool) -> IO(Unit):\n"), S.b(mt.b2()), False{}}

def mt.b3() -> String:
  "  match x:\n    case Some{v}:\n      Bool.pick(U32, b, v, 0)\n    case None{}:\n      1\n"

def mt.u3() -> M.MtoU:
  M.MtoU{S.b("import Base\n\n"), S.b("def h(b: Bool, x: Maybe<&2, U32>) -> U32:\n"), S.b(mt.b3()), False{}}

def mt.b4() -> String:
  "def z(n):\n  Nat.add(n, 0n)\n"

def mt.u4(+prop: Bool) -> M.MtoU:
  M.MtoU{S.b("import Base\n\n"), S.b("law z:\n  for n: Nat\n  Nat\n\n"), S.b(mt.b4()), prop}

def mt.plain(+body: String) -> M.MtoU:
  M.MtoU{S.b("import Base\n\n"), S.b("def k(y: Nat) -> Nat:\n"), S.b(body), False{}}

# Tokens ---------------------------------------------------------------------------------------------

type MtTk is Data:
  MtTk{k: Nat, s: String}

def mt.tks.eq(ts: List<&2, M.MtoTk>, ws: List<&2, MtTk>) -> Bool:
  match ts ws:
    case Nil{} Nil{}:
      True{}
    case M.MtoTk{+k, +t} <> tt MtTk{+j, +s} <> wt:
      Bool.and(Bool.and(Nat.is_eq(k, j), S.eq(t, S.b(s))), mt.tks.eq(tt, wt))
    case _ _:
      False{}

def mt.round(+s: String) -> Bool:
  S.eq(M.mto.unlex(M.mto.lex(S.b(s))), S.b(s))

def mt.odd() -> String:
  "  S.print(\"a \\\"b\\\" # c\") # note, 'q'\n  'x' <> '\\n' 1.5 a.b. x->y\n\t\"open\n  é → ok_2(3n)+1n+p"

def mt.lex() -> List<&2, MtCk>:
  [MtCk{"lex: Nat.add(x, 1n+p) is a name, punctuation, a number ...", mt.tks.eq(M.mto.lex(S.b("Nat.add(x, 1n+p)")),
     [MtTk{1n, "Nat.add"}, MtTk{5n, "("}, MtTk{1n, "x"}, MtTk{5n, ","}, MtTk{0n, " "}, MtTk{2n, "1n"}, MtTk{5n, "+"}, MtTk{1n, "p"}, MtTk{5n, ")"}])},
   MtCk{"lex: strings, comments and char literals are one token each; <> and -> are one; a trailing `.` is not a name's",
     mt.tks.eq(M.mto.lex(S.b("S.p(\"a \\\"b\\\" # c\") # n\n'x' <> '\\n' 1.5 a.b. x->y")),
       [MtTk{1n, "S.p"}, MtTk{5n, "("}, MtTk{3n, "\"a \\\"b\\\" # c\""}, MtTk{5n, ")"}, MtTk{0n, " "}, MtTk{4n, "# n"}, MtTk{0n, "\n"}, MtTk{6n, "'x'"}, MtTk{0n, " "}, MtTk{5n, "<>"}, MtTk{0n, " "},
        MtTk{6n, "'\\n'"}, MtTk{0n, " "}, MtTk{2n, "1.5"}, MtTk{0n, " "}, MtTk{1n, "a.b"}, MtTk{5n, "."}, MtTk{0n, " "}, MtTk{1n, "x"}, MtTk{5n, "->"}, MtTk{1n, "y"}])},
   MtCk{"lex: the tokens joined are the text (an unclosed string, UTF-8, tabs)", Bool.and(Bool.and(mt.round(mt.odd()), mt.round(mt.b1())),
     Bool.and(Bool.and(mt.round(mt.b2()), mt.round(mt.b3())), Bool.and(mt.round(""), mt.round("\"\\"))))}]

# Each operator on each body ---------------------------------------------------------------------------

def mt.ops1() -> List<&2, MtCk>:
  +b = mt.b1()
  +u = mt.u1()
  [mt.op.is("body 1", 0n, u, mt.reps(b, [MtRp{"    case 0n:\n      0n\n", ""}, MtRp{"    case 1n+p:\n      Nat.add(p, 2n)\n", ""}])),
   mt.op.is("body 1", 1n, u, [S.b("  match n:\n    case 0n:\n      Nat.add(p, 2n)\n    case 1n+p:\n      0n\n")]),
   mt.op.is("body 1", 2n, u, Nil{}),
   mt.op.is("body 1", 3n, u, mt.reps(b, [MtRp{"Nat.add(p, 2n)", "Nat.add(2n, p)"}])),
   mt.op.is("body 1", 4n, u, mt.reps(b, [MtRp{"Nat.add(p, 2n)", "Nat.add(2n)"}, MtRp{"Nat.add(p, 2n)", "Nat.add(p)"}])),
   mt.op.is("body 1", 5n, u, Nil{}),
   mt.op.is("body 1", 6n, u, Nil{}),
   mt.op.is("body 1", 7n, u, mt.reps(b, [MtRp{"case 0n:", "case 1n:"}, MtRp{"case 1n+p", "case 0n+p"}])),
   mt.op.is("body 1", 8n, u, mt.reps(b, [MtRp{"case 0n:", "case 0:"}, MtRp{"      0n\n", "      0\n"}, MtRp{"1n+p", "1+p"}, MtRp{"2n)", "2)"}])),
   mt.op.is("body 1", 9n, u, mt.reps(b, [MtRp{"Nat.add(p,", "Nat.add(n,"}])),
   mt.op.is("body 1", 10n, u, mt.reps(b, [MtRp{"Nat.add", "Nat.ad"}, MtRp{"Nat.add", "Nat_add"}])),
   mt.op.is("body 1", 11n, u, Nil{}),
   mt.op.is("body 1", 12n, u, Nil{})]

def mt.ops2() -> List<&2, MtCk>:
  +b = mt.b2()
  +u = mt.u2()
  [mt.op.is("body 2", 0n, u, Nil{}),
   mt.op.is("body 2", 1n, u, Nil{}),
   mt.op.is("body 2", 2n, u, mt.reps(b, [MtRp{"    +xs : List<&2, U32> <- S.read(path)\n", ""}, MtRp{"    S.write(path, xs)\n", ""}, MtRp{"    S.add(path, xs)\n", ""}, MtRp{"    IO.pure(Unit, Unit{})\n", ""}])),
   mt.op.is("body 2", 3n, u, mt.reps(b, [MtRp{"S.write(path, xs)", "S.write(xs, path)"}, MtRp{"S.add(path, xs)", "S.add(xs, path)"}, MtRp{"IO.pure(Unit, Unit{})", "IO.pure(Unit{}, Unit)"}])),
   mt.op.is("body 2", 4n, u, mt.reps(b, [MtRp{"S.write(path, xs)", "S.write(xs)"}, MtRp{"S.write(path, xs)", "S.write(path)"}, MtRp{"S.add(path, xs)", "S.add(xs)"}, MtRp{"S.add(path, xs)", "S.add(path)"},
     MtRp{"IO.pure(Unit, Unit{})", "IO.pure(Unit{})"}, MtRp{"IO.pure(Unit, Unit{})", "IO.pure(Unit)"}])),
   mt.op.is("body 2", 5n, u, Nil{}),
   mt.op.is("body 2", 6n, u, mt.reps(b, [MtRp{"+xs", "xs"}])),
   mt.op.is("body 2", 7n, u, Nil{}),
   mt.op.is("body 2", 8n, u, mt.reps(b, [MtRp{"&2", "&2n"}])),
   mt.op.is("body 2", 9n, u, mt.reps(b, [MtRp{"S.read(path)", "S.read(ok)"}, MtRp{"S.write(path, xs)", "S.write(ok, xs)"}, MtRp{"S.write(path, xs)", "S.write(path, ok)"},
     MtRp{"S.add(path, xs)", "S.add(ok, xs)"}, MtRp{"S.add(path, xs)", "S.add(path, ok)"}])),
   mt.op.is("body 2", 10n, u, mt.reps(b, [MtRp{"S.read", "S.rea"}, MtRp{"S.read", "S.reda"}, MtRp{"S.read", "S_read"}, MtRp{"S.write", "S.writ"}, MtRp{"S.write", "S.wriet"}, MtRp{"S.write", "S_write"},
     MtRp{"S.add", "S.ad"}, MtRp{"S.add", "S_add"}, MtRp{"IO.pure", "IO.pur"}, MtRp{"IO.pure", "IO.puer"}, MtRp{"IO.pure", "IO_pure"}])),
   mt.op.is("body 2", 11n, u, mt.reps(b, [MtRp{"IO<Unit>", "IO<Bool>"}, MtRp{"U32>", "Nat>"}, MtRp{"IO.pure(Unit,", "IO.pure(Bool,"}])),
   mt.op.is("body 2", 12n, u, mt.reps(b, [MtRp{"S.read", "read"}, MtRp{"S.write", "write"}, MtRp{"S.add", "add"}]))]

def mt.ops3() -> List<&2, MtCk>:
  +b = mt.b3()
  +u = mt.u3()
  [mt.op.is("body 3", 0n, u, mt.reps(b, [MtRp{"    case Some{v}:\n      Bool.pick(U32, b, v, 0)\n", ""}, MtRp{"    case None{}:\n      1\n", ""}])),
   mt.op.is("body 3", 1n, u, [S.b("  match x:\n    case Some{v}:\n      1\n    case None{}:\n      Bool.pick(U32, b, v, 0)\n")]),
   mt.op.is("body 3", 2n, u, Nil{}),
   mt.op.is("body 3", 3n, u, mt.reps(b, [MtRp{"pick(U32, b, v, 0)", "pick(b, U32, v, 0)"}, MtRp{"pick(U32, b, v, 0)", "pick(U32, v, b, 0)"}, MtRp{"pick(U32, b, v, 0)", "pick(U32, b, 0, v)"}])),
   mt.op.is("body 3", 4n, u, mt.reps(b, [MtRp{"pick(U32, b, v, 0)", "pick(b, v, 0)"}, MtRp{"pick(U32, b, v, 0)", "pick(U32, v, 0)"}, MtRp{"pick(U32, b, v, 0)", "pick(U32, b, 0)"},
     MtRp{"pick(U32, b, v, 0)", "pick(U32, b, v)"}])),
   mt.op.is("body 3", 5n, u, mt.reps(b, [MtRp{"case Some{v}", "case None{v}"}, MtRp{"case None{}", "case Some{}"}])),
   mt.op.is("body 3", 6n, u, Nil{}),
   mt.op.is("body 3", 7n, u, Nil{}),
   mt.op.is("body 3", 8n, u, mt.reps(b, [MtRp{", 0)", ", 0n)"}, MtRp{"      1\n", "      1n\n"}])),
   mt.op.is("body 3", 9n, u, mt.reps(b, [MtRp{"match x", "match b"}, MtRp{"pick(U32, b,", "pick(U32, x,"}, MtRp{"b, v, 0", "b, x, 0"}])),
   mt.op.is("body 3", 10n, u, mt.reps(b, [MtRp{"Bool.pick", "Bool.pic"}, MtRp{"Bool.pick", "Bool.pikc"}, MtRp{"Bool.pick", "Bool_pick"}])),
   mt.op.is("body 3", 11n, u, mt.reps(b, [MtRp{"pick(U32", "pick(Nat"}])),
   mt.op.is("body 3", 12n, u, Nil{})]

# where an operator does not apply, and a proof's literals
def mt.edges() -> List<&2, MtCk>:
  [MtCk{"lit-value: in a proof every literal, else only a pattern's", Bool.and(mt.texts.eq(M.mto.op(7n, mt.u4(True{})), mt.reps(mt.b4(), [MtRp{"0n)", "1n)"}])),
     mt.texts.eq(M.mto.op(7n, mt.u4(False{})), Nil{}))},
   MtCk{"affine: a binder used once more is no mutant; used twice more, its + dropped",
     Bool.and(mt.texts.eq(M.mto.op(6n, mt.plain("  +x = f(y)\n  g(x)\n")), Nil{}), mt.texts.eq(M.mto.op(6n, mt.plain("  +x = f(y)\n  g(x, x)\n")), [S.b("  x = f(y)\n  g(x, x)\n")]))},
   MtCk{"affine: the + of 1n+p and of a +b binds nothing", Bool.and(mt.texts.eq(M.mto.op(6n, mt.plain("  match y:\n    case 1n+p:\n      g(p, p)\n")), Nil{}),
     mt.texts.eq(M.mto.op(6n, mt.plain("  a +b\n  g(b, b)\n")), Nil{}))},
   MtCk{"affine: a pattern's and a tuple's binders", mt.texts.eq(M.mto.op(6n, mt.plain("  (+a, b) = y\n  match b:\n    case +h <> t:\n      g(a, a, h, h)\n")),
     [S.b("  (a, b) = y\n  match b:\n    case +h <> t:\n      g(a, a, h, h)\n"), S.b("  (+a, b) = y\n  match b:\n    case h <> t:\n      g(a, a, h, h)\n")])},
   MtCk{"drop-case and swap-arms: a match of one arm gives none", Bool.and(mt.texts.eq(M.mto.op(0n, mt.plain("  match y:\n    case _:\n      y\n")), Nil{}),
     mt.texts.eq(M.mto.op(1n, mt.plain("  match y:\n    case _:\n      y\n")), Nil{}))},
   MtCk{"swap-arms: two arms with the same body give none", mt.texts.eq(M.mto.op(1n, mt.plain("  match y:\n    case 0n:\n      y\n    case _:\n      y\n")), Nil{})},
   MtCk{"drop-line: a let line and the expression after it; a continuation line goes with its statement",
     mt.texts.eq(M.mto.op(2n, mt.plain("  +a = f(y,\n    y)\n  g(a, a)\n")), [S.b("  g(a, a)\n"), S.b("  +a = f(y,\n    y)\n")])},
   MtCk{"swap-args and drop-arg: a type's arguments are one argument (List<&2, U32>), a call of one argument gives none",
     Bool.and(mt.texts.eq(M.mto.op(3n, mt.plain("  f(List<&2, U32>, y)\n")), [S.b("  f(y, List<&2, U32>)\n")]), mt.texts.eq(M.mto.op(4n, mt.plain("  f(g(y, y))\n")),
       [S.b("  f(g(y))\n"), S.b("  f(g(y))\n")]))},
   MtCk{"swap-args: equal arguments are no mutant", mt.texts.eq(M.mto.op(3n, mt.plain("  f(y, y)\n")), Nil{})},
   MtCk{"alias-drop: no `import ... as` in the head, no mutant", mt.texts.eq(M.mto.op(12n, M.MtoU{S.b("import Base\nimport ./X.bend\n\n"), Nil{}, S.b("  X.f(y)\n"), False{}}), Nil{})},
   MtCk{"ctor-swap: True and False; a qualified constructor keeps its prefix", mt.texts.eq(M.mto.op(5n, mt.plain("  g(True{}, M.Nil{})\n")),
     [S.b("  g(False{}, M.Nil{})\n"), S.b("  g(True{}, M.Con{})\n")])},
   MtCk{"misspell: a one-letter name only swaps nothing and drops nothing", mt.texts.eq(M.mto.op(10n, mt.plain("  g(y)\n")), Nil{})},
   MtCk{"comments and strings are never mutated", mt.texts.eq(M.mto.op(10n, mt.plain("  # f(y)\n  \"g(y)\"\n")), Nil{})}]

# every mutant of every operator differs from its body
def mt.differs(xs: List<&2, List<&2, U32>>, +b: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> t:
      Bool.and(Bool.not(S.eq(x, b)), mt.differs(t, b))

def mt.all.differ(os: List<&2, Nat>, +u: M.MtoU) -> Bool:
  match os:
    case Nil{}:
      True{}
    case +o <> t:
      Bool.and(mt.differs(M.mto.op(o, u), M.mto.u.body(u)), mt.all.differ(t, u))

def mt.op.list() -> List<&2, Nat>:
  M.mto.order(M.mto.op.count(), 0n, M.mto.op.count())

# Tries ----------------------------------------------------------------------------------------------------

def mt.key() -> List<&2, U32>:
  S.b("2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")

def mt.count.op(ts: List<&2, M.MtoTry>, +o: Nat) -> Nat:
  match ts:
    case Nil{}:
      0n
    case +t <> more:
      Nat.add(Bool.pick(Nat, Nat.is_eq(M.mto.try.op(t), o), 1n, 0n), mt.count.op(more, o))

def mt.capped(os: List<&2, Nat>, +ts: List<&2, M.MtoTry>, +cap: Nat) -> Bool:
  match os:
    case Nil{}:
      True{}
    case +o <> t:
      Bool.and(Nat.is_le(mt.count.op(ts, o), cap), mt.capped(t, ts, cap))

def mt.texts.of(ts: List<&2, M.MtoTry>) -> List<&2, List<&2, U32>>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> more:
      M.mto.try.text(t) <> mt.texts.of(more)

def mt.distinct(xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> +t:
      Bool.and(Bool.not(M.mto.mem(t, x)), mt.distinct(t))

def mt.nth(xs: List<&2, List<&2, U32>>, i: Nat) -> List<&2, U32>:
  match xs i:
    case x <> t 0n:
      x
    case x <> t 1n+j:
      mt.nth(t, j)
    case Nil{} _:
      Nil{}

# the k-th try of operator o is its rotation's k-th
def mt.rotated(ts: List<&2, M.MtoTry>, +u: M.MtoU) -> Bool:
  match ts:
    case Nil{}:
      True{}
    case +t <> more:
      +o = M.mto.try.op(t)
      +r = M.mto.rotate(M.mto.op(o, u), M.mto.key.at(mt.key(), Nat.mul(4n, o)))
      Bool.and(S.eq(M.mto.try.text(t), mt.nth(r, M.mto.try.k(t))), mt.rotated(more, u))

def mt.ops.of(ts: List<&2, M.MtoTry>) -> List<&2, Nat>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> more:
      M.mto.try.op(t) <> mt.ops.of(more)

def mt.nats.eq(xs: List<&2, Nat>, ys: List<&2, Nat>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(Nat.is_eq(x, y), mt.nats.eq(xt, yt))
    case _ _:
      False{}

# the operators that give a mutant, in turn from s
def mt.giving(os: List<&2, Nat>, +u: M.MtoU) -> List<&2, Nat>:
  match os:
    case Nil{}:
      Nil{}
    case +o <> t:
      +rest = mt.giving(t, u)
      Bool.pick(List<&2, Nat>, List.is_empty(&2, List<&2, U32>, M.mto.op(o, u)), rest, o <> rest)

def mt.tries() -> List<&2, MtCk>:
  +u = mt.u2()
  +ts = M.mto.tries(mt.key(), 2n, u)
  +m = M.mto.op.count()
  +first = mt.giving(M.mto.order(m, M.mto.key.at(mt.key(), 52n), m), u)
  [MtCk{"tries: at most cap (2) an operator", mt.capped(mt.op.list(), ts, 2n)},
   MtCk{"tries: every text once, none the body", Bool.and(mt.distinct(mt.texts.of(ts)), mt.differs(mt.texts.of(ts), S.b(mt.b2())))},
   MtCk{"tries: operator o's k-th is the k-th of its mutants rotated by the key's digits 4o..4o+3", mt.rotated(ts, u)},
   MtCk{"tries: the operators in turn from the key's digits 52..55 (each giving one its 0th first)",
     mt.nats.eq(mt.ops.of(List.take(&2, M.MtoTry, ts, List.length(&2, Nat, first))), first)},
   MtCk{"tries: a cap of 0 tries nothing", List.is_empty(&2, M.MtoTry, M.mto.tries(mt.key(), 0n, u))}]

def main() -> IO(Unit):
  do IO<Unit>:
    +diff : MtCk = MtCk{"every operator's mutants differ from the body (four bodies)", Bool.and(Bool.and(mt.all.differ(mt.op.list(), mt.u1()), mt.all.differ(mt.op.list(), mt.u2())),
      Bool.and(mt.all.differ(mt.op.list(), mt.u3()), mt.all.differ(mt.op.list(), mt.u4(True{}))))}
    mt.say(List.concat(&2, MtCk, [mt.lex(), mt.ops1(), mt.ops2(), mt.ops3(), mt.edges(), [diff], mt.tries()]), 0n, "")
