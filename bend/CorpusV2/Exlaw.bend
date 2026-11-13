import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../Clock.bend as Ck
import ../Units.bend as U
import ../Transcript.bend as T
import ../Check/Bend.bend as Bd
import ../Check/Lib.bend as Cl
import ./Eval.bend as Ev
import ./Mutate.bend as Mu
import ./MutOps.bend as M
import ./Combine.bend as Cb
import ./ExlawText.bend as X

# exlaw: a Bend unit's laws, from running its original (2026-11-13;
# docs/form2/KINDS.md "3. Laws").  The user, 11-13: laws "Example laws from
# running the original, plus the file's own general laws when it has them".
#
#   bend-corpus-v2 exlaw UNITS OUT
#
# UNITS is a checked unit file (NUL pairs: an id, then bend-check's record,
# fields joined by 0x1E: a run/v*/transcripts-*/bend/results.train.nul, or a
# part of one).  OUT gets every pair of UNITS, in order: a unit given laws
# with them in field 14 (Bend's type field, always empty for Bend; a check
# holds 0x1F, laws never do) and its new mutants after its old ones; every
# other unit as it was.  OUT.log: a line a unit; OUT.stats: the counts.
#
# A Bend unit whose original passes (field 11 exits 0), not a proposition,
# whose declaration `def NAME(PARAMS) -> RESULT:` has only Base data in its
# parameters and result (Nat, U32, Bool, Char, String, `List<&2, T>` and
# `A & B` of them; no type parameters), is checked as bend-check checks it
# (Check/Bend.bend's layout: the head, the declaration's pre, the body, as
# Unit.bend beside its file in a copy of its repository's .bend files, `bend
# Unit.bend --check-only` under TIMEOUT (30) s, BEND as mutate's), in its
# source tree: the first of BEND_SRC's roots (`:` between, in order) whose
# copy of the unit's file holds its body (else Eval.bend's ev.bend.src when
# BEND_SRC is unset; none: the unit is passed over, `no-source`):
#
# 1. Probe: up to 3 calls of NAME on inputs from small pools (chosen by the
#    unit's id), one check of the file with
#        law NAME.exlaw_probe:
#          for d: R & R & R
#          {(NAME(a), NAME(b), NAME(c)) == d : R & R & R}
#    Bend's `- expected` is what the left side computes, in its own syntax.
#    A value that is not a literal (a stuck call, a lambda) or is over 160
#    bytes is dropped.
# 2. The file's own laws: the `law` pieces right after the declaration in the
#    source (field 8) that use NAME, each with its proof's `def`.
# 3. Verify: the file with the examples (`law NAME.exK: {NAME(a) == v : R}`,
#    `def NAME.exK(): {==}`) and the file's laws checks (exit 0), else with
#    the examples only, else the unit gets none.
# 4. Law mutants: MutOps' operators that keep a program well-typed
#    (swap-arms, drop-line, swap-args, ctor-swap, lit-value, var-swap), the
#    unit's tries in mutate's order, at most TRIES (6) checks, each with the
#    laws in the file: one the checker rejects at one of the laws (its
#    `Location:` a law's name) is kept, at most 2.
# 5. A form mix-up: the body's first `(&2, ` written `(` (else its first
#    `(~` written `(`), kept as an ordinary mutant when the checker rejects
#    it (exit 1), at most 1.
#
# A thin shim runs it on parts in parallel (run/v9/f3.sh).  Every def is
# prefixed `ex.`; the texts (pure) and their laws are CorpusV2/ExlawText.bend.

# The checks (IO) ------------------------------------------------------------------------------

type ExCf is Data:
  ExCf{bend: String, src: String, t: Nat, tries: Nat}

def ExCf.bend(+c: ExCf) -> String:
  match c:
    case ExCf{b, s, t, n}:
      b

def ExCf.src(+c: ExCf) -> String:
  match c:
    case ExCf{b, s, t, n}:
      s

def ExCf.t(+c: ExCf) -> Nat:
  match c:
    case ExCf{b, s, t, n}:
      t

def ExCf.tries(+c: ExCf) -> Nat:
  match c:
    case ExCf{b, s, t, n}:
      n

type ExCx is Data:
  ExCx{c: ExCf, roots: List<&2, String>, home: String, tmp: String}

def ExCx.c(+x: ExCx) -> ExCf:
  match x:
    case ExCx{c, r, h, t}:
      c

def ExCx.roots(+x: ExCx) -> List<&2, String>:
  match x:
    case ExCx{c, r, h, t}:
      r

def ExCx.home(+x: ExCx) -> String:
  match x:
    case ExCx{c, r, h, t}:
      h

def ExCx.tmp(+x: ExCx) -> String:
  match x:
    case ExCx{c, r, h, t}:
      t

# a placed unit: its check's setting, its copy's directories, its record
type ExP is Data:
  ExP{cf: Bd.Cf, tdir: String, udir: String, u: Cl.U}

def ex.check(+p: ExP, +body: List<&2, U32>) -> IO(S.Out):
  match p:
    case ExP{+cf, td, +ud, +u}:
      Bd.run(cf, ud, u, body)

def ex.ck(+p: ExP, +o: S.Out) -> List<&2, U32>:
  match p:
    case ExP{cf, +td, ud, u}:
      Bd.check.of(td, 100n, o)

def ex.udir(+p: ExP) -> String:
  match p:
    case ExP{cf, td, ud, u}:
      ud

# a unit's outcome: its record, its counts' keys, its log line
type ExU is Data:
  ExU{rec: List<&2, U32>, st: List<&2, String>, line: String}

def ex.same(+uid: List<&2, U32>, +rec: List<&2, U32>, +why: String) -> ExU:
  ExU{rec, [why], S.str(uid) ++ ": " ++ why}

# one try: [its text, its check] when it is a law mutant (none: not tried, or not one)
def ex.mut.try(go: Bool, +p: ExP, +x: List<&2, U32>, +laws: List<&2, U32>, +lns: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match go:
    case False{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case True{}:
      do IO<List<&2, List<&2, U32>>>:
        +o : S.Out <- ex.check(p, S.append(x, laws))
        +ck : List<&2, U32> = ex.ck(p, o)
        return Bool.pick(List<&2, List<&2, U32>>, X.ex.at.law(S.Out.status(o), ck, lns), [x, ck], Nil{})

# the tries in order, at most left checks, at most 2 kept (kept: their fields)
def ex.muts(ts: List<&2, M.MtoTry>, +p: ExP, +laws: List<&2, U32>, +lns: List<&2, List<&2, U32>>, +left: Nat, +kept: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match ts:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, kept)
    case +t <> more:
      +go = Bool.and(Bool.and(Nat.is_lt(0n, left), Nat.is_lt(X.ex.count(kept), 4n)), X.ex.typed.op(M.mto.try.op(t)))
      do IO<List<&2, List<&2, U32>>>:
        got : List<&2, List<&2, U32>> <- ex.mut.try(go, p, M.mto.try.text(t), laws, lns)
        ex.muts(more, p, laws, lns, Bool.pick(Nat, go, Nat.sub(left, 1n), left), List.append(&2, List<&2, U32>, kept, got))

# the form mix-up: [its text, its check] when the checker rejects it (exit 1)
def ex.form.try(go: Bool, +p: ExP, +x: List<&2, U32>, +laws: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  match go:
    case False{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case True{}:
      do IO<List<&2, List<&2, U32>>>:
        +o : S.Out <- ex.check(p, S.append(x, laws))
        return Bool.pick(List<&2, List<&2, U32>>, U32.is_eq(S.Out.status(o), 1), [x, ex.ck(p, o)], Nil{})

# the laws stand: the mutants, then the record
def ex.done(+cx: ExCx, +p: ExP, +uid: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +laws: List<&2, U32>, +nfl: Nat, +nex: Nat, +how: String) -> IO(ExU):
  +mu = {M.MtoU{T.field(fs, 5n), T.field(fs, 6n), T.field(fs, 7n), False{}} : M.MtoU}
  +ts = M.mto.tries(S.b(Mu.mtt.key(uid)), 2n, mu)
  +fm = X.ex.form.of(T.field(fs, 7n))
  do IO<ExU>:
    +lm : List<&2, List<&2, U32>> <- ex.muts(ts, p, laws, T.f3.names(laws), ExCf.tries(ExCx.c(cx)), Nil{})
    +nl : Nat = Nat.div(X.ex.count(lm), 2n)
    +fm2 : List<&2, List<&2, U32>> <- ex.form.try(Bool.not(T.empty(fm)), p, fm, laws)
    +nf : Nat = Nat.div(X.ex.count(fm2), 2n)
    +ks : List<&2, String> = List.concat(&2, String, [["laws", how], X.ex.reps(nex, "examples"), X.ex.reps(nfl, "file-laws"), X.ex.reps(nl, "law-mutants"), X.ex.reps(nf, "form-mutants")])
    return ExU{X.ex.with(fs, laws, List.append(&2, List<&2, U32>, lm, fm2)), ks,
      S.str(uid) ++ ": " ++ how ++ ", " ++ Nat.show(nex) ++ " examples, " ++ Nat.show(nfl) ++ " file laws, " ++ Nat.show(nl) ++ " law mutants, " ++ Nat.show(nf) ++ " form"}

def ex.only.ok(ok: Bool, +cx: ExCx, +p: ExP, +uid: List<&2, U32>, +rec: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +few: List<&2, U32>, +nex: Nat) -> IO(ExU):
  match ok:
    case True{}:
      ex.done(cx, p, uid, fs, few, 0n, nex, "verified.examples-only")
    case False{}:
      IO.pure(ExU, ex.same(uid, rec, "laws-fail"))

def ex.try.only(go: Bool, +cx: ExCx, +p: ExP, +uid: List<&2, U32>, +rec: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +few: List<&2, U32>, +nex: Nat) -> IO(ExU):
  match go:
    case True{}:
      do IO<ExU>:
        +o : S.Out <- ex.check(p, S.append(T.field(fs, 7n), few))
        ex.only.ok(U32.is_eq(S.Out.status(o), 0), cx, p, uid, rec, fs, few, nex)
    case False{}:
      IO.pure(ExU, ex.same(uid, rec, "laws-fail"))

def ex.all.ok(ok: Bool, +cx: ExCx, +p: ExP, +uid: List<&2, U32>, +rec: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +full: List<&2, U32>, +few: List<&2, U32>, +nfl: Nat, +nex: Nat) -> IO(ExU):
  match ok:
    case True{}:
      ex.done(cx, p, uid, fs, full, nfl, nex, "verified")
    case False{}:
      ex.try.only(Bool.and(Nat.is_lt(0n, nfl), Nat.is_lt(0n, nex)), cx, p, uid, rec, fs, few, nex)

def ex.try.all(go: Bool, +cx: ExCx, +p: ExP, +uid: List<&2, U32>, +rec: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +full: List<&2, U32>, +few: List<&2, U32>, +nfl: Nat, +nex: Nat) -> IO(ExU):
  match go:
    case True{}:
      do IO<ExU>:
        +o : S.Out <- ex.check(p, S.append(T.field(fs, 7n), full))
        ex.all.ok(U32.is_eq(S.Out.status(o), 0), cx, p, uid, rec, fs, full, few, nfl, nex)
    case False{}:
      IO.pure(ExU, ex.same(uid, rec, "no-examples"))

# the probe's check done: its values as examples, the file's laws
def ex.probed(+cx: ExCx, +p: ExP, +uid: List<&2, U32>, +rec: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +sig: X.ExSig, +cs: List<&2, List<&2, U32>>, +o: S.Out) -> IO(ExU):
  +vs = X.ex.values(S.Out.text(o), X.ex.count(cs))
  +eg = X.ex.examples(cs, vs, 0n, T.field(fs, 2n), X.ex.tyt(X.ExSig.r(sig)), 1n)
  +fl = X.ex.flaws(fs)
  +full = X.ex.laws.text(List.append(&2, List<&2, U32>, fl, eg))
  ex.try.all(Bool.not(T.empty(full)), cx, p, uid, rec, fs, full, X.ex.laws.text(eg), X.ex.count(fl), X.ex.count(eg))

def ex.placed(+cx: ExCx, +src: String, +uid: List<&2, U32>, +rec: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +sig: X.ExSig, +rel: List<&2, U32>) -> IO(ExU):
  +c = ExCx.c(cx)
  +tdir = ExCx.tmp(cx) ++ "/t" ++ String.take(H.sha256(S.b(src)), 8n)
  +repo = S.str(Bd.repo.of(rel))
  +udir = tdir ++ "/src/" ++ S.str(Cl.before.last(rel, [47]))
  +cf = {Bd.Cf{ExCf.bend(c), src, U32.from_nat(ExCf.t(c)), 100n} : Bd.Cf}
  +u = {Cl.U{0n, uid, List.take(&2, List<&2, U32>, fs, 11n)} : Cl.U}
  +p = {ExP{cf, tdir, udir, u} : ExP}
  +cs = X.ex.calls(T.field(fs, 2n), X.ExSig.ps(sig), T.roll(uid, 31n, 5n))
  do IO<ExU>:
    +h : Bool <- S.exists(tdir ++ "/src/" ++ repo)
    Mu.mtt.copy(h, src, tdir, repo)
    +o : S.Out <- ex.check(p, S.append(T.field(fs, 7n), X.ex.probe(T.field(fs, 2n), cs, X.ExSig.r(sig))))
    r : ExU <- ex.probed(cx, p, uid, rec, fs, sig, cs, o)
    S.rm(udir ++ "/Unit.bend")
    return r

def ex.found(ok: Bool, +cx: ExCx, +src: String, +uid: List<&2, U32>, +rec: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +sig: X.ExSig, +rel: List<&2, U32>) -> IO(ExU):
  match ok:
    case False{}:
      IO.pure(ExU, ex.same(uid, rec, "no-source"))
    case True{}:
      ex.placed(cx, src, uid, rec, fs, sig, rel)

# BEND_SRC's roots (`:` between) in order: the first that has the unit's
# file holding its body (none: "")
def ex.root.got(has: Bool, +r: String, +rel: List<&2, U32>, +body: List<&2, U32>) -> IO(Bool):
  match has:
    case False{}:
      IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        xs : List<&2, U32> <- S.read(r ++ "/" ++ S.str(rel))
        return U.infix(xs, S.chomp(body))

def ex.roots(rs: List<&2, List<&2, U32>>, +rel: List<&2, U32>, +body: List<&2, U32>) -> IO(String):
  match rs:
    case Nil{}:
      IO.pure(String, "")
    case +r <> more:
      do IO<String>:
        +has : Bool <- S.exists(S.str(r) ++ "/" ++ S.str(rel))
        +ok : Bool <- ex.root.got(has, S.str(r), rel, body)
        Bool.pick(IO(String), ok, S.realpath(S.str(r)), ex.roots(more, rel, body))

def ex.src(+cx: ExCx, +uid: List<&2, U32>, +rel: List<&2, U32>, +body: List<&2, U32>) -> IO(String):
  +fixed = ExCf.src(ExCx.c(cx))
  Bool.pick(IO(String), String.is_empty(fixed), Ev.ev.bend.src(ExCx.roots(cx), ExCx.home(cx), uid, body), ex.roots(S.split(S.b(fixed), 58), rel, body))

def ex.unit.on(go: Bool, +cx: ExCx, +uid: List<&2, U32>, +rec: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +sig: X.ExSig) -> IO(ExU):
  match go:
    case False{}:
      IO.pure(ExU, ex.same(uid, rec, S.str(X.ex.skip(fs, sig))))
    case True{}:
      +rel = Bd.rel.of(uid, T.field(fs, 2n))
      do IO<ExU>:
        +src : String <- ex.src(cx, uid, rel, T.field(fs, 7n))
        +ok : Bool <- Bool.pick(IO(Bool), String.is_empty(src), IO.pure(Bool, False{}), S.exists(src ++ "/" ++ S.str(rel)))
        ex.found(ok, cx, src, uid, rec, fs, sig, rel)

def ex.unit(+cx: ExCx, +uid: List<&2, U32>, +rec: List<&2, U32>) -> IO(ExU):
  +fs = Ev.ev.split(rec, 30)
  +sig = X.ex.sig(fs)
  ex.unit.on(T.empty(X.ex.skip(fs, sig)), cx, uid, rec, fs, sig)

# The run ---------------------------------------------------------------------------------------

def ex.put(+out: String, +k: List<&2, U32>, u: ExU, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match u:
    case ExU{+rec, +ks, +line}:
      do IO<List<&2, Mu.MttKv>>:
        S.add(out ++ ".tmp", T.cat([k, [0], rec, [0]]))
        S.add(out ++ ".log", S.b(line ++ "\n"))
        return Mu.mtt.bumps(Mu.mtt.bump(st, "units", 1n), ks)

def ex.all(kvs: List<&2, Ev.EvKv>, +cx: ExCx, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match kvs:
    case Nil{}:
      IO.pure(List<&2, Mu.MttKv>, st)
    case Ev.EvKv{+k, +v} <> more:
      do IO<List<&2, Mu.MttKv>>:
        u : ExU <- ex.unit(cx, k, v)
        st2 : List<&2, Mu.MttKv> <- ex.put(out, k, u, st)
        ex.all(more, cx, out, st2)

def ex.go(+inp: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +bend : String <- Mu.mtt.bend()
    +src : String <- S.env("BEND_SRC", "")
    +t : Nat <- S.env.nat("TIMEOUT", 30n)
    +tries : Nat <- S.env.nat("TRIES", 6n)
    +roots : List<&2, String> <- Ev.ev.roots()
    +home : String <- S.env("HOME", "")
    S.rm(out ++ ".d")
    S.mkdir(out ++ ".d")
    +tmp : String <- S.realpath(out ++ ".d")
    S.write(out ++ ".tmp", Nil{})
    S.write(out ++ ".log", Nil{})
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(inp)
    +cx : ExCx = ExCx{ExCf{bend, src, t, tries}, roots, Cb.cb.path(home, "src"), tmp}
    +st : List<&2, Mu.MttKv> <- ex.all(kvs, cx, out, Nil{})
    S.mv(out ++ ".tmp", out)
    S.write(out ++ ".stats", Mu.mtt.kv.bytes(st))
    S.rm(out ++ ".d")
    IO.print("exlaw " ++ inp ++ ": " ++ Nat.show(Mu.mtt.get(st, "units")) ++ " units, " ++ Nat.show(Mu.mtt.get(st, "laws")) ++ " given laws ("
      ++ Nat.show(Mu.mtt.get(st, "examples")) ++ " examples, " ++ Nat.show(Mu.mtt.get(st, "file-laws")) ++ " file laws), "
      ++ Nat.show(Mu.mtt.get(st, "law-mutants")) ++ " law mutants, " ++ Nat.show(Mu.mtt.get(st, "form-mutants")) ++ " form mutants")

def ex.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +inp <> +out <> Nil{}:
      ex.go(inp, out)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 exlaw UNITS OUT")
