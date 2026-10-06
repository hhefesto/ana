import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Lib.bend as L
import ./Combine.bend as C
import ./Eval.bend as Ev
import ../Agent/Spec.bend as A

# E5 (docs/AGENT.md): ana's tool loop on the evaluation's held-out units.
#
#   agent-tool TASK TOOL < EPISODE
#       The tool `ana --agent` calls for a held-out unit (AGENT_TOOL).  TASK
#       is a task file (below).  ana's answer (the episode's act turn, read
#       with Agent/Spec.bend) is lifted into the unit's body as the check
#       stage lifts it (Eval.bend `ev.lift`) and given to the unit's own
#       checker as the unit's one mutant (`bend-check LANG`, the unit's hole
#       left out): every training echo after an `## Attempt` was made that
#       way.  A kept mutant is a failure, its check the echo (exit 1); none
#       kept, the answer passed, the unit's own verdict the echo (exit 0).
#       Spec's `ag.echo` renders it (held to Transcript.bend's `checker` by
#       bend-agent-laws).  An answer that cannot be lifted, a timeout, or a
#       unit whose own original fails is the tool's failure (exit 2).
#
#   agent-eval CKPT DIR FORMAT [K]
#       Each prompt of EVALSET (run/v2/evalset/prompts.nul; FORMAT 1 asks
#       repairs with prompt1, as `gen`) as an episode: `ana --agent`
#       (run/gcroot-bend-generate-agent's bend-generate, --threads THREADS
#       (5)) with CKPT, TEMPERATURE=0, TOKENS (160) a stretch, AGENT_CALLS (4)
#       and agent-tool on the prompt's task (run as AGENT_DEPLOY, default
#       `nix run .#deploy --`, then `corpus-v2 agent-tool TASK`: a built
#       deploy pins the tools for a long run), PROCS (3) at a time; K: only
#       the first K prompts of each language and shape.  The outcome is read
#       from the episode's text (Spec `ag.solved`: its last turn an echo
#       ending `[exit 0]`; its calls, the tool's answers after the prompt's
#       own: a repair prompt holds the attempt's check, and a call the quota
#       stopped has no answer).  Writes DIR/task.N.nul and
#       DIR/prompt.N, DIR/episodes.nul (id N; the episode), DIR/agent.nul (id
#       UNIT/SHAPE; N RS LANG RS UNIT RS SHAPE RS SOLVED RS CALLS RS SECS)
#       and DIR/report.txt: a line a language and shape, solved within 1 to
#       AGENT_CALLS calls, then all.  A DIR whose agent.nul already holds
#       episodes resumes: those prompts are skipped and counted in the
#       report.
#
# A task file is one pair: id UNIT; text LANG RS SRC RS REF RS RECORD (SRC
# Bend's source tree, as `check` finds it, else empty; REF the reference
# term as the transcript shows it; RECORD the unit's checked record from
# run/v2/results/LANG.holdout.nul, last since it holds RS).

# Tasks -------------------------------------------------------------------------

def ea.task.bytes(+u: List<&2, U32>, +lang: List<&2, U32>, +src: String, +ref: List<&2, U32>, +rec: List<&2, U32>) -> List<&2, U32>:
  L.v2.concat([u, [0], S.join([lang, S.b(src), ref, rec], 30), [0]])

def ea.env(+src: String) -> List<String>:
  Bool.pick(List<String>, String.eq(src, ""), ["KEEP_WORK="], ["BEND_SRC=" ++ src, "KEEP_WORK="])

# the unit with ana's term as its one mutant: fields 0..9, no hole, the term
def ea.unit.rec(+rfs: List<&2, List<&2, U32>>, +t: List<&2, U32>) -> List<&2, U32>:
  S.join(List.append(&2, List<&2, U32>, List.take(&2, List<&2, U32>, rfs, 10n), [Nil{}, t]), 30)

# The tool ------------------------------------------------------------------------

def ea.say(ok: Bool, +echo: List<&2, U32>) -> IO(Unit):
  match ok:
    case True{}:
      IO.write(S.str(echo))
    case False{}:
      do IO<Unit>:
        IO.write(S.str(echo))
        IO.die(Unit, 1, "agent-tool: the check failed")

def ea.verdict.if(failed: Bool, timeout: Bool, +rf: List<&2, List<&2, U32>>) -> IO(Unit):
  match failed timeout:
    case True{} _:
      ea.say(False{}, A.ag.echo(Ev.ev.nth(rf, 16n)))
    case False{} True{}:
      IO.die(Unit, 2, "agent-tool: the check timed out")
    case False{} False{}:
      ea.say(True{}, A.ag.echo(Ev.ev.nth(rf, 11n)))

# the checked unit: its kept mutant (fields 15, 16) is a failure; none kept
# and no timeout counted, a pass
def ea.verdict(+rec: List<&2, U32>, +stats: List<&2, U32>) -> IO(Unit):
  +rf = Ev.ev.split(rec, 30)
  ea.verdict.if(Nat.is_lt(16n, List.length(&2, List<&2, U32>, rf)), S.infix(stats, S.b("timeout")), rf)

def ea.out.if(has: Bool, +rec: List<&2, U32>, +stats: List<&2, U32>, +log: List<&2, U32>) -> IO(Unit):
  match has:
    case True{}:
      ea.verdict(rec, stats)
    case False{}:
      IO.die(Unit, 2, "agent-tool: the unit's own original did not check (" ++ S.str(stats) ++ ")\n" ++ S.str(List.take(&2, U32, log, 2000n)))

def ea.out(+xs: List<&2, U32>, +stats: List<&2, U32>, +log: List<&2, U32>) -> IO(Unit):
  +ps = S.split(xs, 0)
  ea.out.if(Nat.is_lt(1n, List.length(&2, List<&2, U32>, ps)), Ev.ev.nth(ps, 1n), stats, log)

def ea.or.empty(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case Some{x}:
      x
    case None{}:
      Nil{}

def ea.tool.check(+lang: String, +src: String, +u: List<&2, U32>, +rfs: List<&2, List<&2, U32>>, m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 2, "agent-tool: the answer does not fit the unit's body (no lift)")
    case Some{+t}:
      do IO<Unit>:
        +dir : String <- S.mktemp()
        S.write(dir ++ "/units.nul", L.v2.concat([u, [0], ea.unit.rec(rfs, t), [0]]))
        +o : S.Out <- S.run(".", ea.env(src), 3600, "bend-check", [lang, dir ++ "/units.nul", dir ++ "/out.nul", "1"], Nil{})
        r : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/out.nul")
        st : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/out.nul.stats")
        S.rm(dir)
        ea.out(ea.or.empty(r), ea.or.empty(st), S.Out.text(o))

def ea.tool.go(t: Maybe<&2, List<&2, U32>>, ep: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match t ep:
    case Some{+tx} Some{+ex}:
      +ps = S.split(tx, 0)
      +fs = Ev.ev.split(Ev.ev.nth(ps, 1n), 30)
      +rfs = Ev.ev.split(Ev.ev.rest(fs, 3n), 30)
      +te = A.ag.answer.code(A.ag.read.bytes(ex))
      ea.tool.check(S.str(Ev.ev.nth(fs, 0n)), S.str(Ev.ev.nth(fs, 1n)), Ev.ev.nth(ps, 0n), rfs, Ev.ev.lift(Ev.ev.nth(fs, 2n), Ev.ev.nth(rfs, 7n), te))
    case _ _:
      IO.die(Unit, 2, "agent-tool: cannot read the task or the episode")

# xs: the arguments after `agent-tool` (the tool's name is the loop's; the
# task names the checker)
def ea.tool(xs: List<String>) -> IO(Unit):
  match xs:
    case +task <> tool <> Nil{}:
      do IO<Unit>:
        t : Maybe<&2, List<&2, U32>> <- S.slurp(task)
        ep : Maybe<&2, List<&2, U32>> <- S.slurp("/dev/stdin")
        ea.tool.go(t, ep)
    case _:
      IO.die(Unit, 2, "usage: agent-tool TASK TOOL < EPISODE")

# The evaluation ----------------------------------------------------------------

def ea.bin() -> String:
  "run/gcroot-bend-generate-agent/bin/bend-generate"

def ea.units(qs: List<&2, Ev.EvQ>) -> List<&2, String>:
  match qs:
    case Nil{}:
      Nil{}
    case Ev.EvQ{id, l, u, s, p, p1, r} <> more:
      S.str(u) <> ea.units(more)

def ea.prep.one(+i: Nat, +fmt1: Bool, +dir: String, +recs: List<&2, Ev.EvKv>, +roots: List<&2, String>, +home: String,
                +env0: List<&2, String>, +threads: String, +dep: String, q: Ev.EvQ) -> IO(C.CbJob):
  match q:
    case Ev.EvQ{id, +l, +u, s, +p, +p1, +r}:
      +asked = Bool.pick(List<&2, U32>, Bool.and(fmt1, Nat.is_lt(0n, S.len(p1))), p1, p)
      +rec = ea.or.empty(Ev.ev.kv.get(recs, u))
      +task = dir ++ "/task." ++ Nat.show(i) ++ ".nul"
      +pf = dir ++ "/prompt." ++ Nat.show(i)
      do IO<C.CbJob>:
        +src : String <- Ev.ev.src.if(S.eq(l, S.b("bend")), roots, home, u, Ev.ev.nth(Ev.ev.split(rec, 30), 7n))
        S.write(task, ea.task.bytes(u, l, src, r, rec))
        S.write(pf, asked)
        return C.CbJob{i, List.append(&2, String, env0, {["AGENT_TOOL=" ++ dep ++ " corpus-v2 agent-tool " ++ task] : List<&2, String>}), ea.bin(),
          {["--threads", threads, "--agent", "--prompt-file", pf] : List<&2, String>}}

def ea.has(xs: List<&2, Nat>, +i: Nat) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(Nat.is_eq(h, i), ea.has(t, i))

# a prompt's job, or none when a resumed run already holds its episode
def ea.prep.if(done: Bool, +i: Nat, +fmt1: Bool, +dir: String, +recs: List<&2, Ev.EvKv>, +roots: List<&2, String>, +home: String,
               +env0: List<&2, String>, +threads: String, +dep: String, q: Ev.EvQ, acc: List<&2, C.CbJob>) -> IO(List<&2, C.CbJob>):
  match done:
    case True{}:
      IO.pure(List<&2, C.CbJob>, acc)
    case False{}:
      do IO<List<&2, C.CbJob>>:
        j : C.CbJob <- ea.prep.one(i, fmt1, dir, recs, roots, home, env0, threads, dep, q)
        return j <> acc

def ea.prep(qs: List<&2, Ev.EvQ>, +i: Nat, +fmt1: Bool, +dir: String, +recs: List<&2, Ev.EvKv>, +roots: List<&2, String>, +home: String,
            +env0: List<&2, String>, +threads: String, +dep: String, +done: List<&2, Nat>, acc: List<&2, C.CbJob>) -> IO(List<&2, C.CbJob>):
  match qs:
    case Nil{}:
      IO.pure(List<&2, C.CbJob>, List.reverse(&2, C.CbJob, acc))
    case +q <> more:
      do IO<List<&2, C.CbJob>>:
        acc2 : List<&2, C.CbJob> <- ea.prep.if(ea.has(done, i), i, fmt1, dir, recs, roots, home, env0, threads, dep, q, acc)
        ea.prep(more, 1n+i, fmt1, dir, recs, roots, home, env0, threads, dep, done, acc2)

# an episode's outcome
type EaR is Data:
  EaR{lang: List<&2, U32>, shape: List<&2, U32>, solved: Bool, calls: Nat}

def EaR.solved(+x: EaR) -> Bool:
  match x:
    case EaR{l, s, ok, c}:
      ok

def EaR.calls(+x: EaR) -> Nat:
  match x:
    case EaR{l, s, ok, c}:
      c

# the calls the tool answered: echoes holding its fenced answer (Spec
# `ag.echo`); a call the quota stopped has none, or a lone newline
def ea.answered(e: List<&2, A.Turn>) -> Nat:
  match e:
    case Nil{}:
      0n
    case A.Turn{+r, +x} <> t:
      Nat.add(Bool.pick(Nat, Bool.and(Nat.is_eq(A.ag.role.code(r), 5n), A.ag.prefix(x, A.ag.ascii("\n```"))), 1n, 0n), ea.answered(t))

# ana's calls: the answers in the episode after those its prompt held
def ea.r.of(+q: Ev.EvQ, +e: List<&2, A.Turn>, +asked: List<&2, A.Turn>) -> EaR:
  match q:
    case Ev.EvQ{id, l, u, s, p, p1, r}:
      EaR{l, s, A.ag.solved(e), Nat.sub(ea.answered(e), ea.answered(asked))}

def ea.rec.bytes(+i: Nat, +q: Ev.EvQ, +x: EaR, +secs: String) -> List<&2, U32>:
  match q x:
    case Ev.EvQ{id, l, u, s, p, p1, r} EaR{xl, xs, ok, c}:
      L.v2.concat([id, [0], S.join([Ev.ev.show(i), l, u, s, S.b(Bool.pick(String, ok, "1", "0")), Ev.ev.show(c), S.b(secs)], 30), [0]])

def ea.one(+count: Nat, +dir: String, +q: Ev.EvQ, r: C.CbRes) -> IO(EaR):
  match r:
    case C.CbRes{+i, o, +ms}:
      +ep = S.no.nul(S.Out.text(o))
      +secs = Ev.ev.secs(ms)
      do IO<EaR>:
        pm : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/prompt." ++ Nat.show(i))
        +x : EaR = ea.r.of(q, A.ag.read.bytes(ep), A.ag.read.bytes(S.slurp.or(pm)))
        S.add(dir ++ "/episodes.nul", L.v2.concat([Ev.ev.show(i), [0], ep, [0]]))
        S.add(dir ++ "/agent.nul", ea.rec.bytes(i, q, x, secs))
        Ck.log(Nat.show(count) ++ " " ++ Ev.ev.q.lang(q) ++ " " ++ Bool.pick(String, EaR.solved(x), "solved", "unsolved") ++ ", " ++ Nat.show(EaR.calls(x)) ++ " calls, " ++ secs ++ " s")
        return x

def ea.loop(n: Nat, +done: Nat, +res: Chan(C.CbRes), +qs: List<&2, Ev.EvQ>, +dir: String, acc: List<&2, EaR>) -> IO(List<&2, EaR>):
  match n:
    case 0n:
      IO.pure(List<&2, EaR>, acc)
    case 1n+k:
      do IO<List<&2, EaR>>:
        +r : C.CbRes <- C.cb.pool.next(res)
        x : EaR <- ea.one(1n+done, dir, Ev.ev.q.nth(qs, C.cb.res.i(r)), r)
        ea.loop(k, 1n+done, res, qs, dir, x <> acc)

# the episodes of a language and shape solved within k calls, and all of them
def ea.count(xs: List<&2, EaR>, +l: List<&2, U32>, +s: List<&2, U32>, +k: Nat, +n: Nat, +m: Nat) -> Nat & Nat:
  match xs:
    case Nil{}:
      (n, m)
    case EaR{+xl, +xs2, +ok, +c} <> more:
      +mine = Bool.and(S.eq(xl, l), S.eq(xs2, s))
      ea.count(more, l, s, k, Nat.add(n, Bool.pick(Nat, Bool.and(mine, Bool.and(ok, Nat.is_le(c, k))), 1n, 0n)), Nat.add(m, Bool.pick(Nat, mine, 1n, 0n)))

def ea.frac(+k: Nat, p: Nat & Nat) -> String:
  (a, b) = p
  " " ++ Nat.show(k) ++ ":" ++ Nat.show(a) ++ "/" ++ Nat.show(b)

def ea.within(+xs: List<&2, EaR>, +l: List<&2, U32>, +s: List<&2, U32>, ks: List<&2, Nat>) -> String:
  match ks:
    case Nil{}:
      ""
    case +k <> more:
      ea.frac(k, ea.count(xs, l, s, k, 0n, 0n)) ++ ea.within(xs, l, s, more)

def ea.all(xs: List<&2, EaR>, +n: Nat, +m: Nat) -> Nat & Nat:
  match xs:
    case Nil{}:
      (n, m)
    case EaR{l, s, +ok, c} <> more:
      ea.all(more, Nat.add(n, Bool.pick(Nat, ok, 1n, 0n)), 1n+m)

# 1, 2, ... n
def ea.ks(n: Nat, +i: Nat) -> List<&2, Nat>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      (1n+i) <> ea.ks(p, 1n+i)

def ea.lines(+xs: List<&2, EaR>, ls: List<&2, String>, +calls: Nat) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      ("  " ++ l ++ " direct, solved within" ++ ea.within(xs, S.b(l), S.b("direct"), ea.ks(calls, 0n)))
        <> ("  " ++ l ++ " repair, solved within" ++ ea.within(xs, S.b(l), S.b("repair"), ea.ks(calls, 0n)))
        <> ea.lines(xs, more, calls)

def ea.total(p: Nat & Nat) -> String:
  (a, b) = p
  " " ++ Nat.show(a) ++ "/" ++ Nat.show(b)

def ea.report(+xs: List<&2, EaR>, +calls: Nat) -> String:
  String.join(ea.lines(xs, Ev.ev.langs(), calls), "\n") ++ "\nall solved" ++ ea.total(ea.all(xs, 0n, 0n)) ++ "\n"

# A resumed run: the episodes agent.nul already holds (id, then N RS LANG RS
# UNIT RS SHAPE RS SOLVED RS CALLS RS SECS), as prompt indices and outcomes
type EaP is Data:
  EaP{i: Nat, r: EaR}

def ea.prior.one(+fs: List<&2, List<&2, U32>>) -> EaP:
  EaP{C.cb.nat(Ev.ev.nth(fs, 0n)), EaR{Ev.ev.nth(fs, 1n), Ev.ev.nth(fs, 3n), S.eq(Ev.ev.nth(fs, 4n), S.b("1")), C.cb.nat(Ev.ev.nth(fs, 5n))}}

def ea.prior.if(empty: Bool, +f: List<&2, U32>, acc: List<&2, EaP>) -> List<&2, EaP>:
  match empty:
    case True{}:
      acc
    case False{}:
      ea.prior.one(Ev.ev.split(f, 30)) <> acc

# the fields: every second NUL-separated part
def ea.prior.go(xs: List<&2, List<&2, U32>>, acc: List<&2, EaP>) -> List<&2, EaP>:
  match xs:
    case id <> +f <> more:
      ea.prior.go(more, ea.prior.if(Nat.is_eq(S.len(f), 0n), f, acc))
    case _:
      acc

def ea.prior(+m: Maybe<&2, List<&2, U32>>) -> List<&2, EaP>:
  ea.prior.go(Ev.ev.split(S.slurp.or(m), 0), Nil{})

def ea.prior.is(ps: List<&2, EaP>) -> List<&2, Nat>:
  match ps:
    case Nil{}:
      Nil{}
    case EaP{i, r} <> more:
      i <> ea.prior.is(more)

def ea.prior.rs(ps: List<&2, EaP>) -> List<&2, EaR>:
  match ps:
    case Nil{}:
      Nil{}
    case EaP{i, r} <> more:
      r <> ea.prior.rs(more)

def ea.fin(+n: Nat, +qs: List<&2, Ev.EvQ>, +dir: String, +calls: Nat, +prior: List<&2, EaR>, x: Chan(C.CbRes) & C.CbPool) -> IO(Unit):
  (res, p) = x
  do IO<Unit>:
    +xs : List<&2, EaR> <- ea.loop(n, List.length(&2, EaR, prior), res, qs, dir, prior)
    C.cb.pool.close(p)
    S.write(dir ++ "/report.txt", S.b(ea.report(xs, calls)))
    IO.print(ea.report(xs, calls))
    Ck.log("agent-eval: " ++ Nat.show(n) ++ " episodes in " ++ dir)

def ea.eval.run(+ckpt: String, +dir: String, +fmt1: Bool, +k: Nat) -> IO(Unit):
  do IO<Unit>:
    +es : String <- Ev.ev.evalset.path()
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(es)
    +qs : List<&2, Ev.EvQ> = Ev.ev.cut.k(k, Ev.ev.qs.of(kvs))
    recs : List<&2, Ev.EvKv> <- Ev.ev.holdout(Ev.ev.langs(), Set.from_list(ea.units(qs)), Nil{})
    +roots : List<&2, String> <- Ev.ev.roots()
    +home : String <- S.env("HOME", "")
    +tokens : String <- S.env("TOKENS", "160")
    +calls : String <- S.env("AGENT_CALLS", "4")
    +threads : String <- S.env("THREADS", "5")
    +procs : Nat <- S.env.nat("PROCS", 3n)
    +dep : String <- S.env("AGENT_DEPLOY", "nix run .#deploy --")
    S.mkdir(dir)
    S.add(dir ++ "/episodes.nul", Nil{})
    pm : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/agent.nul")
    +prior : List<&2, EaP> = ea.prior(pm)
    S.add(dir ++ "/agent.nul", Nil{})
    Ck.log("agent-eval: " ++ Nat.show(List.length(&2, Ev.EvQ, qs)) ++ " prompts of " ++ es ++ " (" ++ Nat.show(List.length(&2, EaP, prior)) ++ " done before), " ++ Nat.show(procs) ++ " at a time, " ++ calls ++ " calls, " ++ tokens ++ " tokens a stretch")
    +env0 : List<&2, String> = {["CKPT=" ++ ckpt, "TOKENS=" ++ tokens, "AGENT_CALLS=" ++ calls, "TEMPERATURE=0", "TOKENIZER_FILE=weights/code32k.bpe"] : List<&2, String>}
    +js : List<&2, C.CbJob> <- ea.prep(qs, 0n, fmt1, dir, List.reverse(&2, Ev.EvKv, recs), roots, C.cb.path(home, "src"), env0, threads, dep, ea.prior.is(prior), Nil{})
    +n : Nat = List.length(&2, C.CbJob, js)
    p : C.CbPool <- C.cb.pool.open(procs, js)
    ea.fin(n, qs, dir, C.cb.nat(S.b(calls)), ea.prior.rs(prior), C.cb.pool.res(p))

# xs: the arguments after `agent-eval`
def ea.eval(xs: List<String>) -> IO(Unit):
  match xs:
    case c <> d <> +f <> Nil{}:
      ea.eval.run(c, d, String.eq(f, "1"), 0n)
    case c <> d <> +f <> +k <> Nil{}:
      ea.eval.run(c, d, String.eq(f, "1"), C.cb.nat(S.b(k)))
    case _:
      IO.die(Unit, 2, "usage: agent-eval CKPT DIR FORMAT [K]")
