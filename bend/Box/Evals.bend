import Base
import ../Sys.bend as S
import ../CorpusV2/Steps.bend as St
import ../CorpusV2/Keyed.bend as K
import ../CorpusV2/Lib.bend as L2
import ./Local.bend as Lc

# Evals: a run's checkpoints on the three evals, paired (2026-10-15, the plan
# "all logic in Bend", Phase 4: run/v3/evalruns/eval-run3.sh and
# run/v2/evalruns/eval-run2.sh made generic; a run's evals are a tracked
# config file, not a new script).
#
#   bend-ops evals CFG            (TAGS: a subset of CFG's tags, in its order)
#
# CFG (tools/evals/run3.cfg is run 3's) holds a setting a line, its first
# word the key (blank lines and # comments skipped):
#   tag NAME CKPT DIR      a checkpoint and where its E1 and E5 go: DIR/both-NAME
#                          (gen + check, its .gen.log and .check.log) and
#                          DIR/agent-NAME (agent-eval, its .log)
#   evals KIND...          which, in order, each over every tag before the next
#                          (cheapest first: behaviour e1 e5)
#   deploy CMD...          E1's and E5's deploy (CMD corpus-v2 gen|check|agent-eval)
#   evalset FILE           the prompts (EVALSET)
#   e1-env K=V...          E1's environment (with EVALSET)
#   e5-env K=V...          E5's (with EVALSET and AGENT_DEPLOY, the deploy)
#   behaviour-deploy CMD   CMD corpus-v2 behaviour run CKPT NAME LANG... (BEHAVIOUR_DIR set)
#   behaviour-dir DIR      the harness (BEHAVIOUR_DIR): results in DIR/results/NAME/LANG/
#   behaviour-legacy DIR   read only: DIR/NAME/verdicts.tsv, the Haskell-only
#                          harness's results (eval-run3.sh's untracked copy, with
#                          bend-generate); when it holds a tag's Haskell verdicts
#                          they are the ones read, as eval-run3.sh paired them
#   behaviour-langs LANG...  the languages run and compared (haskell, as eval-run3.sh)
#   pair A B               a comparison
#   report FILE            the comparisons also written there
#   wait LOG MINUTES       a tag with an eval to run waits, up to MINUTES, until LOG (the
#                          chain's chain.log) says `pulled NAME.checkpoint` (eval-run2.sh's wait)
#
# An eval already done is skipped, as eval-run3.sh skipped it: behaviour when
# each language has its verdicts.tsv (or, Haskell alone, the legacy one), E1
# when DIR/both-NAME.check.log says `all pass`, E5 when DIR/agent-NAME/report.txt
# says `all solved`.  A tag with an eval to run must have its checkpoint, or
# nothing runs.  Then each pair, paired by prompt with the exact two-sided
# McNemar p (the binomial tail at 1/2 in big integers, printed %.2f), on:
# behaviour (verdicts.tsv `pass`), E1 (the ids of DIR/both-NAME/r.*.nul, the
# check groups that passed), E5 (agent.nul's solved field); then E5's retries
# (a Term written after a failing echo) and how many repeat the Term before,
# and E1 by language (report.txt's pass lines summed over direct and repair).
# Logs go to stderr, stamped UTC-6; the table to stdout.  Every def is
# prefixed `evr.`; the pure parts are tested in bend/tests/recipes.bend.

# The config (pure) ------------------------------------------------------------------------------

type EvKv is Data:
  EvKv{k: List<&2, U32>, ws: List<&2, List<&2, U32>>}

def evr.kv.ws(ws: List<&2, List<&2, U32>>) -> List<&2, EvKv>:
  match ws:
    case Nil{}:
      Nil{}
    case +k <> +t:
      Bool.pick(List<&2, EvKv>, S.head.is(k, 35), Nil{}, [EvKv{k, t}])

def evr.kv.line(+l: List<&2, U32>) -> List<&2, EvKv>:
  evr.kv.ws(K.kor.words(l))

def evr.kvs(ls: List<&2, List<&2, U32>>) -> List<&2, EvKv>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.append(&2, EvKv, evr.kv.line(l), evr.kvs(t))

def evr.cfg(+xs: List<&2, U32>) -> List<&2, EvKv>:
  evr.kvs(S.split.lines(xs))

# every value of a key, in order
def evr.all(kvs: List<&2, EvKv>, +key: String) -> List<&2, List<&2, List<&2, U32>>>:
  match kvs:
    case Nil{}:
      Nil{}
    case EvKv{+k, +ws} <> t:
      +r = evr.all(t, key)
      Bool.pick(List<&2, List<&2, List<&2, U32>>>, S.eq(k, S.b(key)), ws <> r, r)

# the last value of a key (its words), or d
def evr.get(+kvs: List<&2, EvKv>, +key: String, +d: List<&2, String>) -> List<&2, String>:
  +vs = evr.all(kvs, key)
  Bool.pick(List<&2, String>, Nat.is_eq(List.length(&2, List<&2, List<&2, U32>>, vs), 0n), d,
    K.kor.strs(Maybe.default(&2, List<&2, List<&2, U32>>, List.last(&2, List<&2, List<&2, U32>>, vs), Nil{})))

def evr.get1(+kvs: List<&2, EvKv>, +key: String, +d: String) -> String:
  K.kor.hd(evr.get(kvs, key, [d]))

type EvTag is Data:
  EvTag{name: String, ckpt: String, dir: String}

def evr.tag.name(+t: EvTag) -> String:
  match t:
    case EvTag{n, c, d}:
      n

def evr.tag.ckpt(+t: EvTag) -> String:
  match t:
    case EvTag{n, c, d}:
      c

def evr.tag.dir(+t: EvTag) -> String:
  match t:
    case EvTag{n, c, d}:
      d

def evr.tags.of(vs: List<&2, List<&2, List<&2, U32>>>) -> List<&2, EvTag>:
  match vs:
    case Nil{}:
      Nil{}
    case +ws <> t:
      EvTag{S.str(K.kor.field(ws, 0n)), S.str(K.kor.field(ws, 1n)), S.str(K.kor.field(ws, 2n))} <> evr.tags.of(t)

def evr.tags(+kvs: List<&2, EvKv>) -> List<&2, EvTag>:
  evr.tags.of(evr.all(kvs, "tag"))

def evr.tag.find(ts: List<&2, EvTag>, +n: String) -> Maybe<&2, EvTag>:
  match ts:
    case Nil{}:
      None{}
    case +t <> r:
      Bool.pick(Maybe<&2, EvTag>, String.eq(evr.tag.name(t), n), Some{t}, evr.tag.find(r, n))

def evr.pick.put(m: Maybe<&2, EvTag>, rest: List<&2, EvTag>) -> List<&2, EvTag>:
  match m:
    case Some{t}:
      t <> rest
    case None{}:
      rest

# TAGS (names) picked from the config's tags; a name the config lacks is dropped
def evr.pick(ns: List<&2, String>, +ts: List<&2, EvTag>) -> List<&2, EvTag>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> r:
      evr.pick.put(evr.tag.find(ts, n), evr.pick(r, ts))

type EvPair is Data:
  EvPair{a: String, b: String}

def evr.pairs.of(vs: List<&2, List<&2, List<&2, U32>>>) -> List<&2, EvPair>:
  match vs:
    case Nil{}:
      Nil{}
    case +ws <> t:
      EvPair{S.str(K.kor.field(ws, 0n)), S.str(K.kor.field(ws, 1n))} <> evr.pairs.of(t)

# McNemar, exact (pure) ----------------------------------------------------------------------------

# Σ_{i=0..k} C(n, i), C(n, i + 1) = C(n, i) (n - i) / (i + 1), in big integers
def evr.binom.go(k: Nat, +n: Nat, +i: Nat, +c: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      St.st.bn.add(acc, c)
    case 1n+j:
      +next = St.st.bn.fst(St.st.bn.divmod(St.st.bn.mul(c, St.st.bn.of(Nat.sub(n, i))), St.st.bn.of(1n+i)))
      evr.binom.go(j, n, 1n+i, next, St.st.bn.add(acc, c))

def evr.pow2(n: Nat, +acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+m:
      evr.pow2(m, St.st.bn.add(acc, acc))

# min(1, 2 Σ_{i<=min(b,c)} C(b+c, i) / 2^(b+c)) as the nearest double
def evr.mcnemar(+b: Nat, +c: Nat) -> St.StF:
  +n = Nat.add(b, c)
  +num = St.st.bn.mul([0, 1], evr.binom.go(Nat.min(b, c), n, 0n, [1], Nil{}))
  +den = evr.pow2(n, [1])
  Bool.pick(St.StF, Cmp.is_lt(St.st.bn.cmp(num, den)), St.st.f.round(False{}, num, den, St.st.f.bias()), St.st.f.of.nat(1n))

def evr.p(+b: Nat, +c: Nat) -> String:
  St.st.f.fixed(evr.mcnemar(b, c), 2n)

# Paired passes (pure) ------------------------------------------------------------------------------

def evr.in(+x: List<&2, U32>, ys: List<&2, List<&2, U32>>) -> Bool:
  match ys:
    case Nil{}:
      False{}
    case +y <> t:
      Bool.or(S.eq(x, y), evr.in(x, t))

# the passes of A and B (unique ids): both, A only, B only
def evr.both(xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> t:
      Nat.add(Bool.pick(Nat, evr.in(x, ys), 1n, 0n), evr.both(t, ys))

def evr.uniq(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> +t:
      +r = evr.uniq(t)
      Bool.pick(List<&2, List<&2, U32>>, evr.in(x, t), r, x <> r)

def evr.pad.l(+s: String, +w: Nat) -> String:
  String.concat(List.replicate(String, Nat.sub(w, String.length(s)), " ")) ++ s

def evr.pad.r(+s: String, +w: Nat) -> String:
  s ++ String.concat(List.replicate(String, Nat.sub(w, String.length(s)), " "))

def evr.d2(+n: Nat) -> String:
  evr.pad.l(Nat.show(n), 2n)

# a pair's line, pair.sh's: `KIND A B  A n  B n  both n  only A n  only B n  p x.xx`
def evr.line(+kind: String, +a: String, +b: String, +xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>) -> String:
  +ux = evr.uniq(xs)
  +uy = evr.uniq(ys)
  +both = evr.both(ux, uy)
  +na = List.length(&2, List<&2, U32>, ux)
  +nb = List.length(&2, List<&2, U32>, uy)
  +oa = Nat.sub(na, both)
  +ob = Nat.sub(nb, both)
  evr.pad.r(kind, 10n) ++ evr.pad.r(a, 15n) ++ " " ++ evr.pad.r(b, 15n) ++ "  A " ++ evr.d2(na) ++ "  B " ++ evr.d2(nb) ++ "  both " ++ evr.d2(both)
    ++ "  only A " ++ evr.d2(oa) ++ "  only B " ++ evr.d2(ob) ++ "  p " ++ evr.p(oa, ob)

# Readers (pure) ------------------------------------------------------------------------------------

# NUL fields' odd ones (ids)
def evr.odd(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case +a <> +b <> t:
      a <> evr.odd(t)
    case _:
      Nil{}

def evr.even(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case +a <> +b <> t:
      b <> evr.even(t)
    case _:
      Nil{}

# NUL text's fields (S.split: a final NUL ends the last, it adds no empty one)
def evr.nul(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  S.split(xs, 0)

# verdicts.tsv: the tasks that passed (`TASK TAB pass`), each as PRE TASK
def evr.tsv.pass(ls: List<&2, List<&2, U32>>, +pre: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +fs = S.split(l, 9)
      +r = evr.tsv.pass(t, pre)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(K.kor.field(fs, 1n), S.b("pass")), List.append(&2, U32, pre, K.kor.field(fs, 0n)) <> r, r)

# agent.nul: the episodes solved (field 5 of a record's \036 fields is 1)
def evr.solved(ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case +id <> +rec <> t:
      +r = evr.solved(t)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(K.kor.field(S.split(rec, 30), 4n), [49]), id <> r, r)
    case _:
      Nil{}

# copy.awk: an episode's Terms (each after "## Term\n\n", less its fence line,
# up to the next "\n```"); retries are the Terms after the first, copies those
# equal to the Term before
def evr.term.cut(+t: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case Some{+e}:
      List.take(&2, U32, t, e)
    case None{}:
      t

# a Term less its first line (`sub(/^[^\n]*\n/, "")`: a part without a
# newline stays), up to the first "\n```"
def evr.term(+p: List<&2, U32>) -> List<&2, U32>:
  +t = Bool.pick(List<&2, U32>, L2.v2.has(p, 10), L2.v2.after(p, 10), p)
  evr.term.cut(t, S.find(t, S.b("\n```"), 0n))

def evr.cp.go(ts: List<&2, List<&2, U32>>, +prev: List<&2, U32>, +r: Nat, +c: Nat) -> Nat & Nat:
  match ts:
    case Nil{}:
      (r, c)
    case +p <> t:
      +x = evr.term(p)
      evr.cp.go(t, x, 1n+r, Bool.pick(Nat, S.eq(x, prev), 1n+c, c))

def evr.cp.parts(ps: List<&2, List<&2, U32>>) -> Nat & Nat:
  match ps:
    case +a <> +first <> t:
      evr.cp.go(t, evr.term(first), 0n, 0n)
    case _:
      (0n, 0n)

def evr.cp.one(+ep: List<&2, U32>) -> Nat & Nat:
  evr.cp.parts(S.split.str(ep, S.b("## Term\n\n")))

def evr.cp.add(x: Nat & Nat, y: Nat & Nat) -> Nat & Nat:
  (a, b) = x
  (c, d) = y
  (Nat.add(a, c), Nat.add(b, d))

def evr.copies(eps: List<&2, List<&2, U32>>) -> Nat & Nat:
  match eps:
    case Nil{}:
      (0n, 0n)
    case +e <> t:
      evr.cp.add(evr.cp.one(e), evr.copies(t))

def evr.copy.line(+name: String, r: Nat & Nat) -> String:
  (+n, +c) = r
  +pct = Bool.pick(String, Nat.is_eq(n, 0n), "0", St.st.f.fixed(St.st.f.ratio(Nat.mul(100n, c), Nat.max(n, 1n)), 0n))
  evr.pad.r("E5 copy", 10n) ++ evr.pad.r(name, 15n) ++ "  retries " ++ Nat.show(n) ++ ", copies " ++ Nat.show(c) ++ " (" ++ pct ++ "%)"

# report.txt's `LANG SHAPE pass X/ Y` lines: per language, passes and prompts
type EvLp is Data:
  EvLp{l: List<&2, U32>, x: Nat, y: Nat}

def evr.slash(+w: List<&2, U32>) -> Nat:
  K.kor.nat(L2.v2.before(w, 47))

# X/ Y (two words) or X/Y (one)
def evr.lp.of(+ws: List<&2, List<&2, U32>>) -> Maybe<&2, EvLp>:
  +w3 = K.kor.field(ws, 3n)
  +after = L2.v2.after(w3, 47)
  +y = Bool.pick(Nat, Nat.is_eq(S.len(after), 0n), K.kor.nat(K.kor.field(ws, 4n)), K.kor.nat(after))
  Bool.pick(Maybe<&2, EvLp>, Bool.and(S.eq(K.kor.field(ws, 2n), S.b("pass")), L2.v2.has(w3, 47)), Some{EvLp{K.kor.field(ws, 0n), evr.slash(w3), y}}, None{})

def evr.lp.add(ps: List<&2, EvLp>, +p: EvLp) -> List<&2, EvLp>:
  match ps p:
    case Nil{} _:
      [p]
    case EvLp{+l, +x, +y} <> +t EvLp{+l2, +x2, +y2}:
      Bool.pick(List<&2, EvLp>, S.eq(l, l2), EvLp{l, Nat.add(x, x2), Nat.add(y, y2)} <> t, EvLp{l, x, y} <> evr.lp.add(t, EvLp{l2, x2, y2}))

# does the next line start with the word `all` (report.txt's `all pass N/M`)
def evr.lp.stop(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      S.eq(K.kor.field(K.kor.words(l), 0n), S.b("all"))

def evr.lp.put(m: Maybe<&2, EvLp>, ps: List<&2, EvLp>) -> List<&2, EvLp>:
  match m:
    case Some{p}:
      evr.lp.add(ps, p)
    case None{}:
      ps

# the pass lines before the `all pass` line
def evr.lp.lines(ls: List<&2, List<&2, U32>>, ps: List<&2, EvLp>, at: Bool) -> List<&2, EvLp>:
  match ls at:
    case Nil{} _:
      ps
    case _ True{}:
      ps
    case +l <> +t False{}:
      +ws = K.kor.words(l)
      evr.lp.lines(t, evr.lp.put(evr.lp.of(ws), ps), evr.lp.stop(t))

def evr.lp.get(ps: List<&2, EvLp>, +l: String) -> String:
  match ps:
    case Nil{}:
      "-"
    case EvLp{+k, +x, +y} <> t:
      Bool.pick(String, S.eq(k, S.b(l)), Nat.show(x) ++ "/" ++ Nat.show(y), evr.lp.get(t, l))

def evr.langs() -> List<&2, String>:
  ["haskell", "lean", "agda", "nix", "bend"]

def evr.lp.row(ls: List<&2, String>, +ps: List<&2, EvLp>) -> String:
  match ls:
    case Nil{}:
      ""
    case +l <> t:
      evr.pad.l(evr.lp.get(ps, l), 9n) ++ evr.lp.row(t, ps)

def evr.lp.head(ls: List<&2, String>) -> String:
  match ls:
    case Nil{}:
      ""
    case +l <> t:
      evr.pad.l(l, 9n) ++ evr.lp.head(t)

# `cut -f2 verdicts.tsv | sort | uniq -c`: each verdict and how many
def evr.verdicts(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      K.kor.field(S.split(l, 9), 1n) <> evr.verdicts(t)

# does the next verdict continue the run (or start the first)
def evr.runs.same(+xs: List<&2, List<&2, U32>>, +cur: List<&2, U32>, +n: Nat) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> t:
      Bool.or(Nat.is_eq(n, 0n), S.eq(x, cur))

# sorted verdicts as ` N VERDICT` runs (`uniq -c`)
def evr.runs(xs: List<&2, List<&2, U32>>, +cur: List<&2, U32>, +n: Nat, same: Bool) -> String:
  match xs same:
    case Nil{} _:
      Bool.pick(String, Nat.is_eq(n, 0n), "", " " ++ Nat.show(n) ++ " " ++ S.str(cur))
    case +x <> +t True{}:
      evr.runs(t, x, 1n+n, evr.runs.same(t, x, 1n+n))
    case +x <> +t False{}:
      " " ++ Nat.show(n) ++ " " ++ S.str(cur) ++ evr.runs(t, x, 1n, evr.runs.same(t, x, 1n))

def evr.counts(+xs: List<&2, U32>) -> String:
  +vs = Lc.lcl.sort(evr.verdicts(S.split.lines(xs)))
  evr.runs(vs, Nil{}, 0n, True{})

# Steps ----------------------------------------------------------------------------------------

def evr.str.in(+x: String, ys: List<&2, String>) -> Bool:
  match ys:
    case Nil{}:
      False{}
    case +y <> t:
      Bool.or(String.eq(x, y), evr.str.in(x, t))

def evr.some.b(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{x}:
      True{}
    case None{}:
      False{}

def evr.some.ls(m: Maybe<&2, List<&2, List<&2, U32>>>) -> Bool:
  match m:
    case Some{x}:
      True{}
    case None{}:
      False{}

def evr.joined.sp(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      " " ++ x ++ evr.joined.sp(t)

def evr.log(+msg: String) -> IO(Unit):
  K.kor.log("evals", msg)

def evr.has(+path: String, +what: String) -> IO(Bool):
  do IO<Bool>:
    +xs : List<&2, U32> <- S.read(path)
    return S.infix(xs, S.b(what))

# the line of a file holding `what` (the last such), or ""
def evr.line.with(ls: List<&2, List<&2, U32>>, +what: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      acc
    case +l <> t:
      evr.line.with(t, what, Bool.pick(List<&2, U32>, S.infix(l, what), l, acc))

def evr.grep(+path: String, +what: String) -> IO(String):
  do IO<String>:
    +xs : List<&2, U32> <- S.read(path)
    return S.str(evr.line.with(S.split.lines(xs), S.b(what), Nil{}))

def evr.abs(+pwd: String, +p: String) -> String:
  Bool.pick(String, S.head.is(S.b(p), 47), p, pwd ++ "/" ++ p)

# behaviour's verdicts.tsv for a tag and language: the legacy one when the
# config names it and it is there (Haskell alone: what eval-run3.sh ran and
# paired, kept for comparability), else the harness's
def evr.beh.file.got(old: Bool, new: Bool, +n: String, +o: String) -> Maybe<&2, String>:
  match old new:
    case True{} _:
      Some{o}
    case False{} True{}:
      Some{n}
    case False{} False{}:
      None{}

def evr.beh.file(+kvs: List<&2, EvKv>, +name: String, +lang: String) -> IO(Maybe<&2, String>):
  +n = evr.get1(kvs, "behaviour-dir", "tools/corpus-v2/behaviour") ++ "/results/" ++ name ++ "/" ++ lang ++ "/verdicts.tsv"
  +leg = evr.get1(kvs, "behaviour-legacy", "")
  +o = leg ++ "/" ++ name ++ "/verdicts.tsv"
  do IO<Maybe<&2, String>>:
    a : Bool <- S.exists(n)
    b : Bool <- S.exists(o)
    return evr.beh.file.got(Bool.and(b, Bool.and(String.eq(lang, "haskell"), Bool.not(String.is_empty(leg)))), a, n, o)

def evr.beh.join(m: Maybe<&2, String>, +ps: List<&2, List<&2, U32>>, rest: Maybe<&2, List<&2, List<&2, U32>>>) -> Maybe<&2, List<&2, List<&2, U32>>>:
  match m rest:
    case Some{f} Some{r}:
      Some{List.append(&2, List<&2, U32>, ps, r)}
    case _ _:
      None{}

# every language's verdicts as `LANG/TASK` passes (None: one language has none)
def evr.beh.passes(ls: List<&2, String>, +kvs: List<&2, EvKv>, +name: String) -> IO(Maybe<&2, List<&2, List<&2, U32>>>):
  match ls:
    case Nil{}:
      IO.pure(Maybe<&2, List<&2, List<&2, U32>>>, Some{Nil{}})
    case +l <> t:
      do IO<Maybe<&2, List<&2, List<&2, U32>>>>:
        +m : Maybe<&2, String> <- evr.beh.file(kvs, name, l)
        +xs : List<&2, U32> <- S.read(Maybe.default(&2, String, m, "/nonexistent"))
        rest : Maybe<&2, List<&2, List<&2, U32>>> <- evr.beh.passes(t, kvs, name)
        return evr.beh.join(m, evr.tsv.pass(S.split.lines(xs), S.b(l ++ "/")), rest)

# every language's verdicts.tsv text, joined (the log's counts)
def evr.beh.text(ls: List<&2, String>, +kvs: List<&2, EvKv>, +name: String) -> IO(List<&2, U32>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, U32>, Nil{})
    case +l <> t:
      do IO<List<&2, U32>>:
        m : Maybe<&2, String> <- evr.beh.file(kvs, name, l)
        +xs : List<&2, U32> <- S.read(Maybe.default(&2, String, m, "/nonexistent"))
        +rest : List<&2, U32> <- evr.beh.text(t, kvs, name)
        return List.append(&2, U32, xs, rest)

def evr.langs.of(+kvs: List<&2, EvKv>) -> List<&2, String>:
  evr.get(kvs, "behaviour-langs", ["haskell"])

# Is an eval done ------------------------------------------------------------------------------

# 0 behaviour, 1 e1, 2 e5, 3 none of them
def evr.kind(+k: String) -> Nat:
  Bool.pick(Nat, String.eq(k, "behaviour"), 0n, Bool.pick(Nat, String.eq(k, "e1"), 1n, Bool.pick(Nat, String.eq(k, "e5"), 2n, 3n)))

def evr.e1.name(+t: EvTag) -> String:
  evr.tag.dir(t) ++ "/both-" ++ evr.tag.name(t)

def evr.e5.name(+t: EvTag) -> String:
  evr.tag.dir(t) ++ "/agent-" ++ evr.tag.name(t)

def evr.done(k: Nat, +kvs: List<&2, EvKv>, +t: EvTag) -> IO(Bool):
  match k:
    case 0n:
      do IO<Bool>:
        m : Maybe<&2, List<&2, List<&2, U32>>> <- evr.beh.passes(evr.langs.of(kvs), kvs, evr.tag.name(t))
        return evr.some.ls(m)
    case 1n:
      evr.has(evr.e1.name(t) ++ ".check.log", "all pass")
    case 2n:
      evr.has(evr.e5.name(t) ++ "/report.txt", "all solved")
    case _:
      IO.pure(Bool, True{})

# Running one -----------------------------------------------------------------------------------

def evr.joined(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> Nil{}:
      x
    case +x <> t:
      x ++ " " ++ evr.joined(t)

def evr.run.beh(+kvs: List<&2, EvKv>, +t: EvTag, +pwd: String) -> IO(Unit):
  +name = evr.tag.name(t)
  +bdir = evr.get1(kvs, "behaviour-dir", "tools/corpus-v2/behaviour")
  +argv = List.concat(&2, String, [evr.get(kvs, "behaviour-deploy", ["nix", "run", ".#deploy", "--"]), ["corpus-v2", "behaviour", "run", evr.abs(pwd, evr.tag.ckpt(t)), name], evr.langs.of(kvs)])
  do IO<Unit>:
    S.mkdir(evr.tag.dir(t))
    +st : U32 <- K.kor.exec.log(argv, ["BEHAVIOUR_DIR=" ++ bdir], evr.tag.dir(t) ++ "/behaviour-" ++ name ++ ".log")
    +xs : List<&2, U32> <- evr.beh.text(evr.langs.of(kvs), kvs, name)
    evr.log("behaviour " ++ name ++ ":" ++ evr.counts(xs) ++ Bool.pick(String, U32.is_eq(st, 0), "", " (exit " ++ U32.show(st) ++ ")"))

def evr.run.e1(+kvs: List<&2, EvKv>, +t: EvTag) -> IO(Unit):
  +n = evr.e1.name(t)
  +d = evr.get(kvs, "deploy", ["run/v2/gcroot-deploy-agent/bin/deploy"])
  env = K.kor.l1(List.append(&2, String, evr.get(kvs, "e1-env", ["BEND_FT_THREADS=5", "PROCS=3", "THREADS=2"]), ["EVALSET=" ++ evr.get1(kvs, "evalset", "run/v2/evalset/prompts-both.nul")]))
  do IO<Unit>:
    +g : U32 <- K.kor.exec.log(List.append(&2, String, d, ["corpus-v2", "gen", evr.tag.ckpt(t), n, "2"]), env, n ++ ".gen.log")
    +c : U32 <- K.kor.exec.log(List.append(&2, String, d, ["corpus-v2", "check", n]), [], n ++ ".check.log")
    +xs : List<&2, U32> <- S.read(n ++ ".check.log")
    evr.log("E1 " ++ evr.tag.name(t) ++ ": " ++ S.str(S.chomp(Lc.lcl.nth(S.split.lines(S.chomp(xs)), Nat.sub(List.length(&2, List<&2, U32>, S.split.lines(S.chomp(xs))), 1n)))))

def evr.run.e5(+kvs: List<&2, EvKv>, +t: EvTag) -> IO(Unit):
  +n = evr.e5.name(t)
  +d = evr.get(kvs, "deploy", ["run/v2/gcroot-deploy-agent/bin/deploy"])
  env = K.kor.l1(List.append(&2, String, evr.get(kvs, "e5-env", ["BEND_FT_THREADS=4", "TOKENS=160", "AGENT_CALLS=4", "PROCS=2", "THREADS=2"]),
    ["EVALSET=" ++ evr.get1(kvs, "evalset", "run/v2/evalset/prompts-both.nul"), "AGENT_DEPLOY=" ++ evr.joined(d)]))
  do IO<Unit>:
    +st : U32 <- K.kor.exec.log(List.append(&2, String, d, ["corpus-v2", "agent-eval", evr.tag.ckpt(t), n, "2"]), env, n ++ ".log")
    +line : String <- evr.grep(n ++ "/report.txt", "all solved")
    evr.log("E5 " ++ evr.tag.name(t) ++ ": " ++ line)

def evr.run.one(k: Nat, +kvs: List<&2, EvKv>, +t: EvTag, +pwd: String) -> IO(Unit):
  match k:
    case 0n:
      evr.run.beh(kvs, t, pwd)
    case 1n:
      evr.run.e1(kvs, t)
    case 2n:
      evr.run.e5(kvs, t)
    case _:
      IO.pure(Unit, Unit{})

def evr.kind.name(+k: Nat) -> String:
  Bool.pick(String, Nat.is_eq(k, 0n), "behaviour", Bool.pick(String, Nat.is_eq(k, 1n), "E1", "E5"))

def evr.step(done: Bool, +k: Nat, +kvs: List<&2, EvKv>, +t: EvTag, +pwd: String) -> IO(Unit):
  match done:
    case True{}:
      evr.log(evr.kind.name(k) ++ " " ++ evr.tag.name(t) ++ ": done before, skipped")
    case False{}:
      evr.run.one(k, kvs, t, pwd)

def evr.kind.tags(ts: List<&2, EvTag>, +k: Nat, +kvs: List<&2, EvKv>, +pwd: String) -> IO(Unit):
  match ts:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +t <> r:
      do IO<Unit>:
        d : Bool <- evr.done(k, kvs, t)
        evr.step(d, k, kvs, t, pwd)
        evr.kind.tags(r, k, kvs, pwd)

def evr.kinds(ks: List<&2, String>, +ts: List<&2, EvTag>, +kvs: List<&2, EvKv>, +pwd: String) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +k <> r:
      do IO<Unit>:
        evr.kind.tags(ts, evr.kind(k), kvs, pwd)
        evr.kinds(r, ts, kvs, pwd)

# the tags with an eval to run whose checkpoint is missing
def evr.missing.kinds(ks: List<&2, String>, +kvs: List<&2, EvKv>, +t: EvTag) -> IO(Bool):
  match ks:
    case Nil{}:
      IO.pure(Bool, False{})
    case +k <> r:
      do IO<Bool>:
        d : Bool <- evr.done(evr.kind(k), kvs, t)
        more : Bool <- evr.missing.kinds(r, kvs, t)
        return Bool.or(Bool.not(d), more)

def evr.missing(ts: List<&2, EvTag>, +ks: List<&2, String>, +kvs: List<&2, EvKv>) -> IO(List<&2, String>):
  match ts:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +t <> r:
      do IO<List<&2, String>>:
        +pending : Bool <- evr.missing.kinds(ks, kvs, t)
        +there : Bool <- S.exists(evr.tag.ckpt(t))
        +rest : List<&2, String> <- evr.missing(r, ks, kvs)
        return Bool.pick(List<&2, String>, Bool.and(pending, Bool.not(there)), evr.tag.ckpt(t) <> rest, rest)

# `wait LOG MINUTES` (eval-run2.sh's): a tag with an eval to run waits until the
# chain's LOG says `pulled NAME.checkpoint`, every 30 s, up to MINUTES
def evr.pulled(+log: String, +ck: String) -> IO(Bool):
  evr.has(log, "pulled " ++ S.base(ck))

def evr.wait.one(fuel: Nat, ok: Bool, +log: String, +ck: String, +mins: String) -> IO(Unit):
  match fuel ok:
    case _ True{}:
      IO.pure(Unit, Unit{})
    case 0n False{}:
      K.kor.die("evals", "no pull of " ++ S.base(ck) ++ " in " ++ mins ++ " min")
    case 1n+f False{}:
      do IO<Unit>:
        IO.sleep(30000)
        ok2 : Bool <- evr.pulled(log, ck)
        evr.wait.one(f, ok2, log, ck, mins)

def evr.wait.if(pending: Bool, +log: String, +ck: String, +mins: String) -> IO(Unit):
  match pending:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        ok : Bool <- evr.pulled(log, ck)
        evr.wait.one(Nat.mul(2n, K.kor.nat(S.b(mins))), ok, log, ck, mins)

def evr.wait.tags(ts: List<&2, EvTag>, +ks: List<&2, String>, +kvs: List<&2, EvKv>, +log: String, +mins: String) -> IO(Unit):
  match ts:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +t <> r:
      do IO<Unit>:
        pending : Bool <- evr.missing.kinds(ks, kvs, t)
        evr.wait.if(pending, log, evr.tag.ckpt(t), mins)
        evr.wait.tags(r, ks, kvs, log, mins)

def evr.wait(+w: List<&2, String>, +ts: List<&2, EvTag>, +ks: List<&2, String>, +kvs: List<&2, EvKv>) -> IO(Unit):
  match w:
    case +log <> +mins <> _:
      evr.wait.tags(ts, ks, kvs, log, mins)
    case _:
      IO.pure(Unit, Unit{})

# The comparisons --------------------------------------------------------------------------------

def evr.some(m: Maybe<&2, List<&2, List<&2, U32>>>) -> Bool:
  match m:
    case Some{x}:
      True{}
    case None{}:
      False{}

# r.*.nul among a directory's names
def evr.r.files(ns: List<&2, List<&2, U32>>, +dir: String) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +r = evr.r.files(t, dir)
      Bool.pick(List<&2, String>, Bool.and(S.prefix(n, S.b("r.")), S.suffix(n, S.b(".nul"))), (dir ++ "/" ++ S.str(n)) <> r, r)

# each file's odd NUL fields (`cat FILES | awk -v RS='\0' 'NR % 2 == 1'`)
def evr.odd.all(fs: List<&2, String>) -> IO(List<&2, List<&2, U32>>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +f <> t:
      do IO<List<&2, List<&2, U32>>>:
        +xs : List<&2, U32> <- S.read(f)
        +rest : List<&2, List<&2, U32>> <- evr.odd.all(t)
        return List.append(&2, List<&2, U32>, evr.odd(evr.nul(xs)), rest)

def evr.e1.got(m: Maybe<&2, List<&2, List<&2, U32>>>, +dir: String) -> IO(Maybe<&2, List<&2, List<&2, U32>>>):
  match m:
    case None{}:
      IO.pure(Maybe<&2, List<&2, List<&2, U32>>>, None{})
    case Some{ns}:
      do IO<Maybe<&2, List<&2, List<&2, U32>>>>:
        +ids : List<&2, List<&2, U32>> <- evr.odd.all(evr.r.files(ns, dir))
        return Some{ids}

# E1's passes: the ids of DIR/both-NAME/r.*.nul (None: no such directory)
def evr.e1.passes(+t: EvTag) -> IO(Maybe<&2, List<&2, List<&2, U32>>>):
  +dir = evr.e1.name(t)
  do IO<Maybe<&2, List<&2, List<&2, U32>>>>:
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(dir)
    evr.e1.got(m, dir)

def evr.e5.of(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, List<&2, U32>>>:
  match m:
    case Some{+xs}:
      Some{evr.solved(evr.nul(xs))}
    case None{}:
      None{}

# E5's solved episodes (None: no agent.nul)
def evr.e5.passes(+t: EvTag) -> IO(Maybe<&2, List<&2, List<&2, U32>>>):
  do IO<Maybe<&2, List<&2, List<&2, U32>>>>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(evr.e5.name(t) ++ "/agent.nul")
    return evr.e5.of(m)

def evr.cmp.line(a: Maybe<&2, List<&2, List<&2, U32>>>, b: Maybe<&2, List<&2, List<&2, U32>>>, +kind: String, +na: String, +nb: String) -> String:
  match a b:
    case Some{+xs} Some{+ys}:
      evr.line(kind, na, nb, xs, ys)
    case _ _:
      evr.pad.r(kind, 10n) ++ evr.pad.r(na, 15n) ++ " " ++ evr.pad.r(nb, 15n) ++ "  (not run on both)"

def evr.find.or(m: Maybe<&2, EvTag>, +n: String) -> EvTag:
  match m:
    case Some{t}:
      t
    case None{}:
      EvTag{n, "", "/nonexistent"}

# a pair's three lines
def evr.pair(+kvs: List<&2, EvKv>, +ts: List<&2, EvTag>, +p: EvPair) -> IO(String):
  match p:
    case EvPair{+a, +b}:
      +ta = evr.find.or(evr.tag.find(ts, a), a)
      +tb = evr.find.or(evr.tag.find(ts, b), b)
      do IO<String>:
        ba : Maybe<&2, List<&2, List<&2, U32>>> <- evr.beh.passes(evr.langs.of(kvs), kvs, a)
        bb : Maybe<&2, List<&2, List<&2, U32>>> <- evr.beh.passes(evr.langs.of(kvs), kvs, b)
        ea : Maybe<&2, List<&2, List<&2, U32>>> <- evr.e1.passes(ta)
        eb : Maybe<&2, List<&2, List<&2, U32>>> <- evr.e1.passes(tb)
        fa : Maybe<&2, List<&2, List<&2, U32>>> <- evr.e5.passes(ta)
        fb : Maybe<&2, List<&2, List<&2, U32>>> <- evr.e5.passes(tb)
        return evr.cmp.line(ba, bb, "behaviour", a, b) ++ "\n" ++ evr.cmp.line(ea, eb, "E1", a, b) ++ "\n" ++ evr.cmp.line(fa, fb, "E5", a, b) ++ "\n"

def evr.pairs(ps: List<&2, EvPair>, +kvs: List<&2, EvKv>, +ts: List<&2, EvTag>) -> IO(String):
  match ps:
    case Nil{}:
      IO.pure(String, "")
    case +p <> t:
      do IO<String>:
        +x : String <- evr.pair(kvs, ts, p)
        +rest : String <- evr.pairs(t, kvs, ts)
        return x ++ rest

def evr.copy.of(m: Maybe<&2, List<&2, U32>>, +name: String) -> String:
  match m:
    case Some{+xs}:
      evr.copy.line(name, evr.copies(evr.even(evr.nul(xs)))) ++ "\n"
    case None{}:
      ""

# E5's retries and copies, a tag a line
def evr.copy(+t: EvTag) -> IO(String):
  do IO<String>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(evr.e5.name(t) ++ "/episodes.nul")
    return evr.copy.of(m, evr.tag.name(t))

def evr.copy.all(ts: List<&2, EvTag>) -> IO(String):
  match ts:
    case Nil{}:
      IO.pure(String, "")
    case +t <> r:
      do IO<String>:
        +x : String <- evr.copy(t)
        +rest : String <- evr.copy.all(r)
        return x ++ rest

def evr.lang.of(m: Maybe<&2, List<&2, U32>>, +name: String) -> String:
  match m:
    case Some{+xs}:
      evr.pad.r(name, 15n) ++ evr.lp.row(evr.langs(), evr.lp.lines(S.split.lines(xs), Nil{}, False{})) ++ "\n"
    case None{}:
      ""

# E1 by language, a tag a row
def evr.lang.row(+t: EvTag) -> IO(String):
  do IO<String>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(evr.e1.name(t) ++ "/report.txt")
    return evr.lang.of(m, evr.tag.name(t))

def evr.lang.all(ts: List<&2, EvTag>) -> IO(String):
  match ts:
    case Nil{}:
      IO.pure(String, "")
    case +t <> r:
      do IO<String>:
        +x : String <- evr.lang.row(t)
        +rest : String <- evr.lang.all(r)
        return x ++ rest

# the tags the pairs name, each once, in order
def evr.pair.tags(ps: List<&2, EvPair>, +ts: List<&2, EvTag>, +seen: List<&2, String>) -> List<&2, EvTag>:
  match ps:
    case Nil{}:
      Nil{}
    case EvPair{+a, +b} <> r:
      +sa = evr.str.in(a, seen)
      +s1 = Bool.pick(List<&2, String>, sa, seen, a <> seen)
      +sb = Bool.or(evr.str.in(b, s1), String.eq(a, b))
      +s2 = Bool.pick(List<&2, String>, sb, s1, b <> s1)
      +ta = Bool.pick(List<&2, EvTag>, sa, Nil{}, [evr.find.or(evr.tag.find(ts, a), a)])
      +tb = Bool.pick(List<&2, EvTag>, sb, Nil{}, [evr.find.or(evr.tag.find(ts, b), b)])
      List.concat(&2, EvTag, [ta, tb, evr.pair.tags(r, ts, s2)])

def evr.table(+kvs: List<&2, EvKv>, +ts: List<&2, EvTag>) -> IO(String):
  +ps = evr.pairs.of(evr.all(kvs, "pair"))
  do IO<String>:
    +a : String <- evr.pairs(ps, kvs, ts)
    +b : String <- evr.copy.all(evr.pair.tags(ps, ts, Nil{}))
    +c : String <- evr.lang.all(ts)
    return "paired by prompt (exact two-sided McNemar p):\n" ++ a ++ "\nE5 retries (a Term after a failing echo) and copies of the Term before:\n" ++ b
      ++ "\nE1 by language (direct and repair):\n" ++ evr.pad.r("tag", 15n) ++ evr.lp.head(evr.langs()) ++ "\n" ++ c

# Main -----------------------------------------------------------------------------------------

def evr.names(ts: List<&2, EvTag>) -> String:
  match ts:
    case Nil{}:
      ""
    case +t <> r:
      " " ++ evr.tag.name(t) ++ evr.names(r)

def evr.pick.env(+v: String, +ts: List<&2, EvTag>) -> List<&2, EvTag>:
  Bool.pick(List<&2, EvTag>, String.is_empty(v), ts, evr.pick(K.kor.strs(K.kor.words(S.b(v))), ts))

def evr.report(+path: String, +text: String) -> IO(Unit):
  Bool.pick(IO(Unit), String.is_empty(path), IO.pure(Unit, Unit{}), S.write(path, S.b(text)))

def evr.run(+cfg: String) -> IO(Unit):
  do IO<Unit>:
    +m : Maybe<&2, List<&2, U32>> <- S.slurp(cfg)
    Bool.pick(IO(Unit), evr.some.b(m), IO.pure(Unit, Unit{}), IO.die(Unit, 2, "evals: cannot read " ++ cfg))
    +kvs : List<&2, EvKv> = evr.cfg(S.slurp.or(m))
    +tv : String <- S.env("TAGS", "")
    +ts : List<&2, EvTag> = evr.pick.env(tv, evr.tags(kvs))
    +ks : List<&2, String> = evr.get(kvs, "evals", ["behaviour", "e1", "e5"])
    +pwd : String <- K.kor.pwd()
    evr.log("start:" ++ evr.names(ts))
    evr.wait(evr.get(kvs, "wait", Nil{}), ts, ks, kvs)
    +miss : List<&2, String> <- evr.missing(ts, ks, kvs)
    Bool.pick(IO(Unit), Nat.is_eq(List.length(&2, String, miss), 0n), IO.pure(Unit, Unit{}), K.kor.die("evals", "no checkpoint" ++ evr.joined.sp(miss)))
    evr.kinds(ks, ts, kvs, pwd)
    +t : String <- evr.table(kvs, evr.tags(kvs))
    IO.write(t)
    evr.report(evr.get1(kvs, "report", ""), t)
    evr.log("done")

def evr.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +cfg <> Nil{}:
      evr.run(cfg)
    case _:
      IO.die(Unit, 2, "usage: bend-ops evals CFG   (TAGS: some of CFG's tags)")


