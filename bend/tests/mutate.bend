import Base
import ../Sys.bend as S
import ../Agent/Spec.bend as A
import ../CorpusV2/Mutate.bend as Mu
import ../CorpusV2/MutOps.bend as M

# bend-corpus-v2 mutate (bend/CorpusV2/Mutate.bend, 2026-10-16) end to end on
# a unit set written here: a repository with a def that checks (f) and one
# that no longer does (g), a Nix unit and a held-out unit beside them.  The
# tool, run in this process (PROCS 1) with `bend` from the PATH and
# weights/code32k.bpe, must choose the two Bend units not held out, count g
# stale and mutate nothing of it, and turn f's rejected mutants into
# transcripts in format 2's repair layout: read back with Agent/Spec's reader
# each is User, Context, Type, an Attempt that is not f's body, the checker's
# failing answer, then f's own Term and the checker's pass; at most KEEP a
# unit, no operator twice; run again, it redoes nothing and writes the same
# bytes.  The error kinds and the keep rule (a new operator and a new kind,
# the held-back ones filling the room) are checked on their own.  Each check
# prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.  Run from bend/tests
# (compiled: the tokenizer's parse is too deep for the interpreter).

type MuCk is Data:
  MuCk{name: String, ok: Bool}

def mut.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "mutate: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def mut.say(cs: List<&2, MuCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      mut.end(Nat.is_eq(bad, 0n), bad, names)
    case MuCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        mut.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

# Error kinds and the keep rule (pure) ------------------------------------------------------------------

def mut.out(+s: String) -> List<&2, U32>:
  S.b("SOME PROOFS FAIL\nError:\n" ++ s ++ "\nLocation: f\n3 | def f(n: Nat) -> Nat:\n")

def mut.kinds() -> List<&2, MuCk>:
  [MuCk{"kind: affine", String.eq(Mu.mtt.kind(mut.out("- expected : x\n- observed : x (consumed more than once)")), "affine")},
   MuCk{"kind: unbound", String.eq(Mu.mtt.kind(mut.out("- expected : a defined name\n- observed : Nat.ad")), "unbound")},
   MuCk{"kind: missing-case", String.eq(Mu.mtt.kind(mut.out("- expected : cases for Succ\n- observed : \\{}")), "missing-case")},
   MuCk{"kind: termination", String.eq(Mu.mtt.kind(mut.out("- expected : a decreasing self-call (arguments are read left to right)\n- observed : f")), "termination")},
   MuCk{"kind: match", String.eq(Mu.mtt.kind(S.b("Error:\n- message  : 'n' can't be matched in this position (it is ...)\nLocation:\n4>|   match n:\n")), "match")},
   MuCk{"kind: parse (Location: alone)", String.eq(Mu.mtt.kind(S.b("Error:\n- expected : a term\n- observed : end of input\nLocation:\n4 |   Nat.add(a, b\n")), "parse")},
   MuCk{"kind: arity, both ways; two function types are a type error", Bool.and(Bool.and(String.eq(Mu.mtt.kind(mut.out("- expected : Nat\n- observed : @b:Nat -> Nat")), "arity"),
     String.eq(Mu.mtt.kind(mut.out("- expected : @b:Nat -> Nat\n- observed : Nat")), "arity")), String.eq(Mu.mtt.kind(mut.out("- expected : @_:Nat -> U32\n- observed : @x:Nat -> Nat")), "type"))},
   MuCk{"kind: an unknown constructor is unbound", String.eq(Mu.mtt.kind(S.b("Error:\n- message  : a declared constructor (unknown: HeapEntry)\nLocation:\n")), "unbound")},
   MuCk{"kind: a pattern's fields, a duplicate declaration (before parse: both say `Location:` alone)", Bool.and(
     String.eq(Mu.mtt.kind(S.b("Error:\n- message  : a Con pattern with 2 fields (Nil has 0)\nLocation:\n")), "pattern"),
     String.eq(Mu.mtt.kind(S.b("Error:\n- expected : a fresh constructor name (duplicate declaration: Text)\n- observed : 'Text'\nLocation:\n")), "duplicate"))},
   MuCk{"kind: type", String.eq(Mu.mtt.kind(mut.out("- expected : Nat\n- observed : U32")), "type")},
   MuCk{"kind: other", String.eq(Mu.mtt.kind(S.b("Segmentation fault\n")), "other")},
   MuCk{"kind: foreign (Bend 2.0.37 fails a file relying on foreign code), its Error line the reason", Bool.and(String.eq(Mu.mtt.kind(S.b("SOME PROOFS FAIL\nError: 3 defs rely on unsafe or foreign code:\n- noise\n")), "foreign"),
     String.eq(Mu.mtt.why(S.b("SOME PROOFS FAIL\nError: 3 defs rely on unsafe or foreign code:\n- noise\n")), "Error: 3 defs rely on unsafe or foreign code:"))}]

def mut.cfg(+dir: String, +keep: Nat) -> Mu.MttCfg:
  Mu.MttCfg{"bend", dir ++ "/src", 60n, keep, 8n, 2n, "weights/code32k.bpe", 2048n, 1n, 1n, dir ++ "/held.nul"}

def mut.try(+o: Nat) -> M.MtoTry:
  M.MtoTry{o, 0n, S.b("x" ++ Nat.show(o))}

def mut.ck(+e: U32, +s: String) -> List<&2, U32>:
  S.append(S.b(U32.show(e)), 31 <> mut.out(s))

# three rejected tries: a type error (swap-args), another (ctor-swap: same
# kind, held back), an unbound name (misspell); a passing and a timed-out
# one between them
def mut.judged() -> Mu.MttSt:
  +ty = {"- expected : Nat\n- observed : U32" : String}
  +s0 = {Mu.MttSt{Nil{}, Nil{}, 0n, 0n, Nil{}} : Mu.MttSt}
  +s1 = Mu.mtt.judge(mut.try(3n), 1, mut.ck(1, ty), 5n, s0)
  +s2 = Mu.mtt.judge(mut.try(1n), 0, mut.ck(0, ""), 5n, s1)
  +s3 = Mu.mtt.judge(mut.try(5n), 1, mut.ck(1, ty), 5n, s2)
  +s4 = Mu.mtt.judge(mut.try(2n), 124, mut.ck(124, ""), 5n, s3)
  Mu.mtt.judge(mut.try(10n), 1, mut.ck(1, "- expected : a defined name\n- observed : g"), 5n, s4)

def mut.nats.eq(xs: List<&2, Nat>, ys: List<&2, Nat>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(Nat.is_eq(x, y), mut.nats.eq(xt, yt))
    case _ _:
      False{}

def mut.st.kept(+s: Mu.MttSt) -> List<&2, Mu.MttK>:
  match s:
    case Mu.MttSt{k, b, n, ms, st}:
      k

def mut.st.back(+s: Mu.MttSt) -> List<&2, Mu.MttK>:
  match s:
    case Mu.MttSt{k, b, n, ms, st}:
      b

def mut.st.n(+s: Mu.MttSt) -> Nat:
  match s:
    case Mu.MttSt{k, b, n, ms, st}:
      n

def mut.st.st(+s: Mu.MttSt) -> List<&2, Mu.MttKv>:
  match s:
    case Mu.MttSt{k, b, n, ms, st}:
      st

def mut.rule() -> List<&2, MuCk>:
  +s = mut.judged()
  +c = mut.cfg("/x", 3n)
  [MuCk{"keep: a new operator with a new kind is kept, one with a kind kept already held back; passes and timeouts dropped",
     Bool.and(mut.nats.eq(Mu.mtt.ops.of(mut.st.kept(s)), [3n, 10n]), mut.nats.eq(Mu.mtt.ops.of(mut.st.back(s)), [5n]))},
   MuCk{"keep: the held-back fill the room left (KEEP 3), not past it (KEEP 2)",
     Bool.and(mut.nats.eq(Mu.mtt.ops.of(Mu.mtt.fill(mut.st.back(s), mut.st.kept(s), 3n)), [3n, 10n, 5n]),
       mut.nats.eq(Mu.mtt.ops.of(Mu.mtt.fill(mut.st.back(s), mut.st.kept(s), 2n)), [3n, 10n]))},
   MuCk{"keep: every check counted, by operator and outcome", Bool.and(Bool.and(Nat.is_eq(mut.st.n(s), 5n), Nat.is_eq(Mu.mtt.get(mut.st.st(s), "passed.swap-arms"), 1n)),
     Bool.and(Nat.is_eq(Mu.mtt.get(mut.st.st(s), "timeout.drop-line"), 1n), Nat.is_eq(Mu.mtt.get(mut.st.st(s), "rejected-kind.type"), 2n)))},
   MuCk{"keep: a check a signal ends (137, the OOM killer) is dropped and counted as a timeout, never kept",
     Bool.and(mut.nats.eq(Mu.mtt.ops.of(mut.st.kept(Mu.mtt.judge(mut.try(4n), 137, mut.ck(137, ""), 5n, s))), [3n, 10n]),
       Nat.is_eq(Mu.mtt.get(mut.st.st(Mu.mtt.judge(mut.try(4n), 137, mut.ck(137, ""), 5n, s)), "timeout.drop-arg"), 1n))},
   MuCk{"want: no try of an operator kept, none past TRIES or KEEP", Bool.and(Bool.and(Bool.not(Mu.mtt.want(c, s, mut.try(3n))), Mu.mtt.want(c, s, mut.try(4n))),
     Bool.and(Bool.not(Mu.mtt.want(mut.cfg("/x", 2n), s, mut.try(4n))), Bool.not(Mu.mtt.want(c, Mu.MttSt{Nil{}, Nil{}, 8n, 0n, Nil{}}, mut.try(4n)))))}]

# The fixture -------------------------------------------------------------------------------------------

def mut.head() -> String:
  "import Base\n\n"

def mut.f.pre() -> String:
  "def f(n: Nat) -> Nat:\n"

def mut.f.body() -> String:
  "  match n:\n    case 0n:\n      0n\n    case 1n+p:\n      Nat.add(p, 2n)\n"

def mut.g.pre() -> String:
  "def g(n: Nat) -> Nat:\n"

def mut.g.body() -> String:
  "  Nat.add(n)\n"

def mut.file() -> String:
  mut.head() ++ mut.f.pre() ++ mut.f.body() ++ "\n" ++ mut.g.pre() ++ mut.g.body()

def mut.ctx() -> String:
  "def Nat.add(a: Nat, b: Nat) -> Nat"

# a checked record: fields 0..14 (no hole, no type, no mutants)
def mut.rec(+lang: String, +name: String, +sig: String, +head: String, +pre: String, +body: String, +tail: String) -> List<&2, U32>:
  S.join([S.b(lang), S.b("type"), S.b(name), Nil{}, S.b(sig), S.b(head), S.b(pre), S.b(body), S.b(tail), S.b("Nat.add"), Nil{},
    S.append(S.b("0"), 31 <> S.b("All terms check.")), S.b(mut.ctx()), Nil{}, Nil{}], 30)

def mut.pair(+id: String, +rec: List<&2, U32>) -> List<&2, U32>:
  List.concat(&2, U32, [S.b(id), [0], rec, [0]])

def mut.fid() -> String:
  "own:repo/A.bend#f@3"

def mut.units() -> List<&2, U32>:
  +f = mut.rec("bend", "f", "def f(n: Nat) -> Nat:", mut.head(), mut.f.pre(), mut.f.body(), "\n" ++ mut.g.pre() ++ mut.g.body())
  +g = mut.rec("bend", "g", "def g(n: Nat) -> Nat:", mut.head() ++ mut.f.pre() ++ mut.f.body() ++ "\n", mut.g.pre(), mut.g.body(), "")
  List.concat(&2, U32, [mut.pair("own:repo/x.nix#x@1", mut.rec("nix", "x", "", "", "", "{ }\n", "")), mut.pair(mut.fid(), f), mut.pair("own:repo/A.bend#g@10", g),
    mut.pair("own:repo/A.bend#h@3", f)])

# The output read back -------------------------------------------------------------------------------------

type MuPr is Data:
  MuPr{id: List<&2, U32>, text: List<&2, U32>}

def mut.pairs(xs: List<&2, List<&2, U32>>) -> List<&2, MuPr>:
  match xs:
    case +i <> +t <> more:
      MuPr{i, t} <> mut.pairs(more)
    case _:
      Nil{}

def mut.roles(e: List<&2, A.Turn>) -> List<&2, Nat>:
  match e:
    case Nil{}:
      Nil{}
    case A.Turn{+r, x} <> t:
      A.ag.role.code(r) <> mut.roles(t)

# User, Context, Type (given), Attempt, the call, its echo, the Term (act), the call, its echo
def mut.layout() -> List<&2, Nat>:
  [0n, 1n, 1n, 2n, 4n, 5n, 3n, 4n, 5n]

def mut.nth.turn(e: List<&2, A.Turn>, i: Nat) -> List<&2, U32>:
  match e i:
    case A.Turn{r, x} <> t 0n:
      x
    case A.Turn{r, x} <> t 1n+j:
      mut.nth.turn(t, j)
    case Nil{} _:
      Nil{}

def mut.lead() -> String:
  "## User\n\nDefine `f`.\n\nThis attempt fails. Fix it.\n\n## Context\n\n```bend\n" ++ mut.ctx() ++ "\n```\n\n## Type\n\ntype\n```bend\ndef f(n: Nat) -> Nat:\n```\n\n## Attempt\n\n```bend\n"

def mut.f.term() -> String:
  "match n:\n  case 0n:\n    0n\n  case 1n+p:\n    Nat.add(p, 2n)\n"

# one transcript in the trained repair layout
def mut.shape(+p: MuPr) -> Bool:
  match p:
    case MuPr{+i, +t}:
      +e = A.ag.read.bytes(t)
      +atm = A.ag.code(mut.nth.turn(e, 3n))
      Bool.and(Bool.and(Bool.and(S.prefix(i, S.b("mut:" ++ mut.fid() ++ "/")), S.prefix(t, S.b(mut.lead()))), Bool.and(mut.nats.eq(mut.roles(e), mut.layout()), A.ag.solved(e))),
        Bool.and(Bool.and(Bool.not(A.ag.verdict(mut.nth.turn(e, 5n))), S.infix(mut.nth.turn(e, 5n), S.b("[exit 1]\n"))),
          Bool.and(S.eq(A.ag.answer.code(e), S.b(mut.f.term())), Bool.not(S.eq(atm, S.b(mut.f.term()))))))

def mut.all.shape(ps: List<&2, MuPr>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case +p <> t:
      Bool.and(mut.shape(p), mut.all.shape(t))

def mut.nodigits(+xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      mut.nodigits(t, M.mto.digit(M.mto.hd(t)))
    case _ _:
      xs

# the operator of an id `mut:f's id/OP-K`
def mut.op.of(+i: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, List.drop(&2, U32, i, S.len(S.b("mut:" ++ mut.fid() ++ "/"))))
  List.reverse(&2, U32, List.drop(&2, U32, mut.nodigits(r, M.mto.digit(M.mto.hd(r))), 1n))

def mut.ops(ps: List<&2, MuPr>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case MuPr{+i, t} <> more:
      mut.op.of(i) <> mut.ops(more)

def mut.distinct(xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> +t:
      Bool.and(Bool.not(M.mto.mem(t, x)), mut.distinct(t))

def mut.val(+xs: List<&2, U32>, +key: String) -> String:
  Mu.mtt.sel.val(S.split.lines(xs), key)

def mut.io(+dir: String) -> IO(List<&2, MuCk>):
  # OUT relative to the working directory, as a run from the repository root names it
  +out = {"mutate-out.tmp" : String}
  +res = out ++ "/accepted/bend-mut/transcripts.train.nul"
  do IO<List<&2, MuCk>>:
    S.rm(out)
    S.mkdir(dir ++ "/src/repo")
    S.write(dir ++ "/src/repo/A.bend", S.b(mut.file()))
    S.write(dir ++ "/units.nul", mut.units())
    S.write(dir ++ "/held.nul", mut.pair("own:repo/A.bend#h@3", S.b("bend")))
    Mu.mtt.run.with(mut.cfg(dir, 3n), dir ++ "/units.nul", out, "all", None{})
    +sel : List<&2, U32> <- S.read(out ++ "/work/select.txt")
    +kvs : List<&2, Mu.MttKv> <- Mu.mtt.stats(2n, out ++ "/work", 0n, Nil{})
    +first : List<&2, U32> <- S.read(res)
    Mu.mtt.run.with(mut.cfg(dir, 3n), dir ++ "/units.nul", out, "all", None{})
    +again : List<&2, U32> <- S.read(res)
    +ps : List<&2, MuPr> = mut.pairs(S.split(first, 0))
    +n : Nat = List.length(&2, MuPr, ps)
    return [MuCk{"select: the two Bend units not held out (of 3 Bend, 4 pairs; 1 held out)", Bool.and(Bool.and(String.eq(mut.val(sel, "selected"), "2"), String.eq(mut.val(sel, "bend"), "3")),
               Bool.and(String.eq(mut.val(sel, "held"), "1"), String.eq(mut.val(sel, "pairs"), "4")))},
            MuCk{"stale: g's original fails, it is counted and never mutated", Bool.and(Bool.and(Nat.is_eq(Mu.mtt.get(kvs, "units"), 2n), Nat.is_eq(Mu.mtt.get(kvs, "stale"), 1n)),
              Nat.is_eq(Mu.mtt.get(kvs, "checked"), 1n))},
            MuCk{"kept: f gives one to KEEP (3) transcripts, as many as the counts say", Bool.and(Bool.and(Nat.is_lt(0n, n), Nat.is_le(n, 3n)), Nat.is_eq(n, Mu.mtt.get(kvs, "kept")))},
            MuCk{"layout: User, Context, Type, Attempt (not f's body), its failing check, f's Term, its pass; ids mut:UNIT/OP-K", mut.all.shape(ps)},
            MuCk{"kept: no operator twice in a unit", mut.distinct(mut.ops(ps))},
            MuCk{"resume: a second run redoes nothing and writes the same bytes", S.eq(first, again)}]

def main() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    io : List<&2, MuCk> <- mut.io(dir)
    S.rm(dir)
    S.rm("mutate-out.tmp")
    mut.say(List.concat(&2, MuCk, [mut.kinds(), mut.rule(), io]), 0n, "")
