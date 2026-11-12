import Base
import ../Sys.bend as S
import ../Transcript.bend as T
import ../Agent/Spec.bend as A
import ./Lib.bend as L
import ./Combine.bend as C
import ../Check/Lib.bend as Cl
import ../Clock.bend as Ck
import ./Eval.bend as Ev

# ana's tool loop in the mugen shape (docs/MUGEN-SHAPE.md; 2026-11-03): the
# tool `ana --agent` calls when she ends a call with `## echo` (Agent/Loop.bend
# calls on that heading as on a format-2 tool's).
#
#   agent-mugen TASK TOOL < EPISODE
#       TASK is a task file (below), TOOL the loop's name for the call
#       (`echo`), EPISODE the session so far: the `## user` ask, then ana's
#       calls (`## read`, `## edit`, `## shell`) each with its echo, the last
#       call's echo only its heading.  The tool plays mugen on the unit's
#       file: it starts from the file the shape gives (direct: the head;
#       fill: the head, the declaration and `?goal`; repair-M: mutant M in
#       place of the body), applies ana's earlier edits in order (one that
#       does not apply changes nothing, as mugen's), runs the last call on
#       the file that gives, and prints its echo as the renderer writes
#       echoes (Transcript.bend "Format mugen", from the empty line after
#       `## echo`).  The calls:
#         read PATH FROM LIMIT   mugen's read (`[lines A-B of N]`)
#         edit PATH -old +new    the old lines must occur once; the echo is
#                                mugen's diff, else mugen's refusal
#         shell bend PATH --check-only   bend on the file in the unit's tree
#                                (BEND, the unit's repository copied under
#                                AGENT_WORK, else a temporary directory,
#                                once; the file as Unit.bend beside the
#                                original, as bend-check writes a variant)
#         shell grep -nE '^(def|law) (A|B)[(:]' PATH   on the file
#         shell bend base A | head -1, for n in A B; do bend base $n | head -1; done
#       Any other command is refused (exit 127 in its echo): this is an
#       evaluation, not a shell.  Exit 0 (solved): the call was the check,
#       it passed, and the file still opens with the unit's head and its
#       declaration's first part, with a body after them (a direct task the
#       check passes without its definition is not solved).  Exit 1: ana goes
#       on.  Exit 2: the task does not read.
#
# A task file is one pair: id UNIT; text SRC RS SHAPE RS RECORD (SRC the
# unit's class tree, Eval.bend `ev.bend.src`; SHAPE direct, fill or
# repair-M; RECORD the unit's checked record, Transcript.bend's fields, last
# since it holds RS).

def am.task.bytes(+u: List<&2, U32>, +src: String, +shape: List<&2, U32>, +rec: List<&2, U32>) -> List<&2, U32>:
  L.v2.concat([u, [0], S.join([S.b(src), shape, rec], 30), [0]])

type AmT is Data:
  AmT{id: List<&2, U32>, src: String, shape: List<&2, U32>, fs: List<&2, List<&2, U32>>}

def AmT.id(+t: AmT) -> List<&2, U32>:
  match t:
    case AmT{i, s, h, f}:
      i

def AmT.src(+t: AmT) -> String:
  match t:
    case AmT{i, s, h, f}:
      s

def AmT.shape(+t: AmT) -> List<&2, U32>:
  match t:
    case AmT{i, s, h, f}:
      h

def AmT.fs(+t: AmT) -> List<&2, List<&2, U32>>:
  match t:
    case AmT{i, s, h, f}:
      f

def am.task.of(+xs: List<&2, U32>) -> AmT:
  +ps = S.split(xs, 0)
  +fs = S.split(T.field(ps, 1n), 30)
  AmT{T.field(ps, 0n), S.str(T.field(fs, 0n)), T.field(fs, 1n), List.drop(&2, List<&2, U32>, fs, 2n)}

# the unit's file path as the asks name it (the id after its class, before `#`)
def am.path(+t: AmT) -> List<&2, U32>:
  T.mg.path(AmT.id(t))

# the file the shape starts from
def am.f0(+t: AmT) -> List<&2, U32>:
  +fs = AmT.fs(t)
  +sh = AmT.shape(t)
  Bool.pick(List<&2, U32>, S.eq(sh, S.b("direct")), T.mg.head(fs),
    Bool.pick(List<&2, U32>, S.eq(sh, S.b("fill")), T.mg.with(fs, T.field(fs, 10n)),
      T.mg.with(fs, T.mutant(fs, C.cb.nat(S.strip(sh, S.b("repair-")))))))

# whether a file holds the unit's definition: the head and the declaration's
# first part, then a body
def am.done(+t: AmT, +f: List<&2, U32>) -> Bool:
  +fs = AmT.fs(t)
  +pre = T.mg.with(fs, Nil{})
  Bool.and(S.prefix(f, pre), Bool.not(S.eq(S.chomp(f), S.chomp(pre))))

# The calls --------------------------------------------------------------------------

def am.keep.on(keep: Bool, +x: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match keep:
    case True{}:
      x <> rest
    case False{}:
      rest

# ana's calls, in order: the blocks under `## read`, `## edit`, `## shell`
def am.calls(bs: List<&2, A.Blk>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case A.Blk{+c, +x} <> t:
      am.keep.on(A.ag.is.call(c), x, am.calls(t))

def am.lead.go(xs: List<&2, U32>, nl: Bool) -> List<&2, U32>:
  match xs nl:
    case h <> +t True{}:
      am.lead.go(t, S.head.is(t, 10))
    case _ _:
      xs

# without its leading and trailing newlines
def am.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  S.chomp(am.lead.go(xs, S.head.is(xs, 10)))

# a call's label (`read`) and its body (the text after the heading's empty line)
def am.label(+x: List<&2, U32>) -> List<&2, U32>:
  S.chomp(List.drop(&2, U32, A.ag.line1(10, x), 3n))

# without a closing code fence on its last line (11-11: her `ana-type` call
# came as the command, an empty line, then a fence, and the one-line rule
# refused it)
def am.unfence.on(cut: Bool, +xs: List<&2, U32>) -> List<&2, U32>:
  match cut:
    case True{}:
      S.chomp(List.take(&2, U32, xs, Nat.sub(S.len(xs), 3n)))
    case False{}:
      xs

def am.unfence(+xs: List<&2, U32>) -> List<&2, U32>:
  am.unfence.on(Bool.or(S.eq(xs, S.b("```")), S.suffix(xs, S.b("\n```"))), xs)

def am.body(+x: List<&2, U32>) -> List<&2, U32>:
  am.unfence(am.trim(A.ag.after1(10, x)))

def am.last.or(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      x
    case x <> +t:
      am.last.or(t)

def am.init(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      Nil{}
    case x <> +t:
      x <> am.init(t)

# Edits -------------------------------------------------------------------------------

def am.drop1(+l: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, l, 1n)

def am.signed.on(hit: Bool, +l: List<&2, U32>, rest: List<&2, U32>) -> List<&2, U32>:
  match hit:
    case True{}:
      S.append(S.append(am.drop1(l), [10]), rest)
    case False{}:
      rest

# the lines a sign opens, each without it and with its newline (the rest
# once: Bool.pick takes both of its branches)
def am.signed(ls: List<&2, List<&2, U32>>, +sign: U32) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      am.signed.on(S.head.is(l, sign), l, am.signed(t, sign))

# an edit's outcome: the file after it, and mugen's refusal (empty: applied)
type AmE is Data:
  AmE{f: List<&2, U32>, why: List<&2, U32>}

def AmE.f(+e: AmE) -> List<&2, U32>:
  match e:
    case AmE{f, w}:
      f

def AmE.why(+e: AmE) -> List<&2, U32>:
  match e:
    case AmE{f, w}:
      w

def am.edit.why(+path: List<&2, U32>, +why: String) -> List<&2, U32>:
  T.cat([S.b("Edit 1 ("), path, S.b("): " ++ why ++ ". No file was changed.")])

# mugen's edit on the file: the old text must occur there once (Tools.bend
# tl.edit.apply's reasons)
def am.edit(+t: AmT, +f: List<&2, U32>, +body: List<&2, U32>) -> AmE:
  +ls = S.split(body, 10)
  +path = T.field(ls, 0n)
  +rest = List.drop(&2, List<&2, U32>, ls, 1n)
  +old = am.signed(rest, 45)
  +new = am.signed(rest, 43)
  +there = S.eq(path, am.path(t))
  +n = Bool.pick(Nat, T.empty(old), 0n, T.mg.count(f, old))
  +why = Bool.pick(String, Bool.not(there), "no such file", Bool.pick(String, Nat.is_eq(n, 0n), "old was not found",
    Bool.pick(String, Nat.is_lt(1n, n), "old matches more than once; give more context, or all", "")))
  Bool.pick(AmE, String.eq(why, ""), AmE{S.replace.first(f, old, new), Nil{}}, AmE{f, am.edit.why(path, why)})

# the file after the earlier calls' edits
def am.replay(cs: List<&2, List<&2, U32>>, +t: AmT, +f: List<&2, U32>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      f
    case +x <> more:
      am.replay(more, t, Bool.pick(List<&2, U32>, S.eq(am.label(x), S.b("edit")), AmE.f(am.edit(t, f, am.body(x))), f))

# The echoes ---------------------------------------------------------------------------

# a call's answer: its echo's text, and whether it solved the task
type AmO is Data:
  AmO{echo: List<&2, U32>, solved: Bool}

def AmO.echo(+o: AmO) -> List<&2, U32>:
  match o:
    case AmO{e, s}:
      e

def am.nat.or(+w: List<&2, U32>, +d: Nat) -> Nat:
  Bool.pick(Nat, T.empty(w), d, C.cb.nat(w))

def am.read(+t: AmT, +f: List<&2, U32>, +body: List<&2, U32>) -> AmO:
  +ws = T.mg.words(body)
  +path = T.field(ws, 0n)
  Bool.pick(AmO, S.eq(path, am.path(t)),
    AmO{T.mg.read.echo(f, Nat.max(1n, am.nat.or(T.field(ws, 1n), 1n)), am.nat.or(T.field(ws, 2n), 2000n)), False{}},
    AmO{T.cat([S.b("ENOENT: no such file or directory, open '"), path, S.b("'")]), False{}})

def am.edit.echo(+t: AmT, +f: List<&2, U32>, +body: List<&2, U32>) -> AmO:
  +e = am.edit(t, f, body)
  Bool.pick(AmO, T.empty(AmE.why(e)), AmO{T.mg.diff(am.path(t), f, AmE.f(e)), False{}}, AmO{AmE.why(e), False{}})

def am.code(+ok: Bool) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, ok, S.b("0"), S.b("1"))

def am.before.at(+xs: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case Some{k}:
      List.take(&2, U32, xs, k)
    case None{}:
      xs

# xs before the first p (all of xs when it has none)
def am.before.str(+xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  am.before.at(xs, S.find(xs, p, 0n))

def am.unesc(ns: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> more:
      S.replace(n, [92, 46], [46]) <> am.unesc(more)

# grep -nE '^(def|law) (A|B)[(:]' PATH, on the file
def am.grep(+t: AmT, +f: List<&2, U32>, +cmd: List<&2, U32>) -> AmO:
  +rest = S.strip(cmd, S.b("grep -nE '^(def|law) ("))
  +ns0 = am.before.str(rest, S.b(")[(:]' "))
  +path = L.v2.after.str(rest, S.b(")[(:]' "))
  +ns = am.unesc(S.split(ns0, 124))
  +hits = T.mg.grep.go(T.split(f, 10), ns, 1n)
  Bool.pick(AmO, S.eq(path, am.path(t)),
    AmO{T.mg.shell.echo(T.mg.join(hits, [10]), am.code(Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, hits), 0n)))), False{}},
    AmO{T.mg.shell.echo(T.cat([S.b("grep: "), path, S.b(": No such file or directory")]), S.b("2")), False{}})

# the names a `bend base` command asks for
def am.base.names(+cmd: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, S.prefix(cmd, S.b("for n in ")),
    T.mg.words(am.before.str(S.strip(cmd, S.b("for n in ")), S.b(";"))),
    T.mg.words(am.before.str(S.strip(cmd, S.b("bend base ")), S.b("|"))))

def am.base.go(ns: List<&2, List<&2, U32>>, +bend: String) -> IO(List<&2, List<&2, U32>>):
  match ns:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +n <> more:
      do IO<List<&2, List<&2, U32>>>:
        +o : S.Out <- S.run(".", ["BEND_NO_TELEMETRY=1"], 60, bend, ["base", S.str(n)], Nil{})
        r : List<&2, List<&2, U32>> <- am.base.go(more, bend)
        return S.lines.first(S.Out.text(o)) <> r

def am.base(+cmd: List<&2, U32>, +bend: String) -> IO(AmO):
  do IO<AmO>:
    ls : List<&2, List<&2, U32>> <- am.base.go(am.base.names(cmd), bend)
    return AmO{T.mg.shell.echo(T.mg.join(ls, [10]), S.b("0")), False{}}

# bend on the file in the unit's tree: the repository copied under the work
# directory once (Check/Bend.bend's `copy`), the file as Unit.bend beside
# the original
def am.copy(have: Bool, +src: String, +work: String, +repo: String) -> IO(Unit):
  match have:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        S.mkdir(work ++ "/src")
        o : S.Out <- S.run(src, [], 3600, "find", [repo, "-name", "*.bend", "-not", "-path", "*/node_modules/*",
          "-exec", "cp", "--parents", "{}", work ++ "/src/", ";"], Nil{})
        return Unit{}

# (secs: the check's time limit)
def am.check.for(+secs: U32, +t: AmT, +f: List<&2, U32>, +work: String, +bend: String) -> IO(AmO):
  +rel = L.v2.after(L.v2.before(AmT.id(t), 35), 58)
  +repo = S.str(L.v2.before(rel, 47))
  +udir = work ++ "/src/" ++ S.str(Cl.before.last(rel, [47]))
  do IO<AmO>:
    h : Bool <- S.exists(work ++ "/src/" ++ repo)
    am.copy(h, AmT.src(t), work, repo)
    S.write(udir ++ "/Unit.bend", f)
    +o : S.Out <- S.run(udir, ["BEND_NO_TELEMETRY=1"], secs, bend, ["Unit.bend", "--check-only"], Nil{})
    S.rm(udir ++ "/Unit.bend")
    +st : U32 = S.Out.status(o)
    return AmO{T.mg.shell.echo(S.clean(work, 100n, S.Out.text(o)), S.b(U32.show(st))), Bool.and(U32.is_eq(st, 0), am.done(t, f))}

def am.check.in(+t: AmT, +f: List<&2, U32>, +work: String, +bend: String) -> IO(AmO):
  am.check.for(180, t, f, work, bend)

def am.check.at(made: Bool, +t: AmT, +f: List<&2, U32>, +work: String, +bend: String) -> IO(AmO):
  match made:
    case True{}:
      do IO<AmO>:
        +dir : String <- S.mktemp()
        r : AmO <- am.check.in(t, f, dir, bend)
        S.rm(dir)
        return r
    case False{}:
      am.check.in(t, f, work, bend)

def am.check.if(there: Bool, +t: AmT, +f: List<&2, U32>, +path: List<&2, U32>, +bend: String, +work: String) -> IO(AmO):
  match there:
    case True{}:
      am.check.at(String.eq(work, ""), t, f, work, bend)
    case False{}:
      IO.pure(AmO, AmO{T.mg.shell.echo(T.cat([S.b("bend: no such file: "), path]), S.b("1")), False{}})

def am.check(+t: AmT, +f: List<&2, U32>, +path: List<&2, U32>, +bend: String, +work: String) -> IO(AmO):
  am.check.if(S.eq(path, am.path(t)), t, f, path, bend, work)

def am.refuse() -> AmO:
  AmO{T.mg.shell.echo(S.b("mugen (ana's evaluation): this shell runs only `bend PATH --check-only`, `grep -nE` and `bend base`"), S.b("127")), False{}}

def am.shell.base(bs: Bool, +cmd: List<&2, U32>, +bend: String) -> IO(AmO):
  match bs:
    case True{}:
      am.base(cmd, bend)
    case False{}:
      IO.pure(AmO, am.refuse())

def am.shell.grep(gr: Bool, +t: AmT, +f: List<&2, U32>, +cmd: List<&2, U32>, +bend: String) -> IO(AmO):
  match gr:
    case True{}:
      IO.pure(AmO, am.grep(t, f, cmd))
    case False{}:
      am.shell.base(Bool.or(S.prefix(cmd, S.b("bend base ")), Bool.and(S.prefix(cmd, S.b("for n in ")), S.infix(cmd, S.b("bend base $n")))), cmd, bend)

def am.shell.check(chk: Bool, +t: AmT, +f: List<&2, U32>, +cmd: List<&2, U32>, +bend: String, +work: String) -> IO(AmO):
  match chk:
    case True{}:
      am.check(t, f, S.strip(List.take(&2, U32, cmd, Nat.sub(S.len(cmd), 13n)), S.b("bend ")), bend, work)
    case False{}:
      am.shell.grep(S.prefix(cmd, S.b("grep -nE '^(def|law) (")), t, f, cmd, bend)

def am.shell(+t: AmT, +f: List<&2, U32>, +cmd: List<&2, U32>, +bend: String, +work: String) -> IO(AmO):
  am.shell.check(Bool.and(S.prefix(cmd, S.b("bend ")), S.suffix(cmd, S.b(" --check-only"))), t, f, cmd, bend, work)

# the last call, run on the file the earlier calls left
def am.run.edit(ed: Bool, +t: AmT, +f: List<&2, U32>, +body: List<&2, U32>, +bend: String, +work: String) -> IO(AmO):
  match ed:
    case True{}:
      IO.pure(AmO, am.edit.echo(t, f, body))
    case False{}:
      am.shell(t, f, body, bend, work)

def am.run.read(rd: Bool, +lb: List<&2, U32>, +t: AmT, +f: List<&2, U32>, +body: List<&2, U32>, +bend: String, +work: String) -> IO(AmO):
  match rd:
    case True{}:
      IO.pure(AmO, am.read(t, f, body))
    case False{}:
      am.run.edit(S.eq(lb, S.b("edit")), t, f, body, bend, work)

def am.run.if(none: Bool, +x: List<&2, U32>, +t: AmT, +f: List<&2, U32>, +bend: String, +work: String) -> IO(AmO):
  match none:
    case True{}:
      IO.pure(AmO, AmO{S.b("mugen (ana's evaluation): no call before `## echo`"), False{}})
    case False{}:
      am.run.read(S.eq(am.label(x), S.b("read")), am.label(x), t, f, am.body(x), bend, work)

# work: where the unit's repository is copied for the check ("": a fresh
# temporary directory a check)
def am.run(+t: AmT, +cs: List<&2, List<&2, U32>>, +bend: String, +work: String) -> IO(AmO):
  +x = am.last.or(cs)
  am.run.if(T.empty(x), x, t, am.replay(am.init(cs), t, am.f0(t)), bend, work)

# solved: AGENT_WORK/SOLVED is left for the evaluation (the loop's own word
# on how the episode ended is on its stderr, which the job pool drops)
def am.mark(none: Bool, +work: String) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      S.write(work ++ "/SOLVED", Nil{})

def am.end(s: Bool, +work: String) -> IO(Unit):
  match s:
    case True{}:
      am.mark(String.eq(work, ""), work)
    case False{}:
      IO.die(Unit, 1, "agent-mugen: not solved yet")

# What mugen does to a tool's output past 30,000 characters (its Tools.bend tl.clip): the first
# 15,000, the number cut, the last 14,936.  Here in bytes, no character split at a cut.  A check's
# error can print a 2.3 MB term (11-04: repair-0 of bend-collections' keypair_if), and feeding that
# to the decoder took over an hour on the CPU, so one episode held the eval and /ana would hang.
def am.clip.cont(+c: U32) -> Bool:
  Bool.and(U32.is_le(128, c), U32.is_le(c, 191))

def am.clip.front(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> +t:
      Bool.pick(List<&2, U32>, am.clip.cont(c), am.clip.front(t), c <> t)

# the end of a head: a last character the cut split goes
def am.clip.lead(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> +t:
      Bool.pick(List<&2, U32>, U32.is_le(192, c), t, c <> t)

def am.clip.head(+xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, am.clip.lead(am.clip.front(List.reverse(&2, U32, List.take(&2, U32, xs, 15000n)))))

def am.clip.big(big: Bool, +xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  match big:
    case False{}:
      xs
    case True{}:
      S.append(am.clip.head(xs), S.append(S.b("\n[... " ++ Nat.show(Nat.sub(Nat.sub(n, 15000n), 14936n)) ++ " characters cut ...]\n"), am.clip.front(List.drop(&2, U32, xs, Nat.sub(n, 14936n)))))

def am.clip(+xs: List<&2, U32>) -> List<&2, U32>:
  +n = S.len(xs)
  am.clip.big(Nat.is_lt(30000n, n), xs, n)

# the echo as the loop appends it: the renderer's echo turn after its heading line
def am.say(o: AmO, +work: String) -> IO(Unit):
  match o:
    case AmO{+e, s}:
      do IO<Unit>:
        IO.write(S.str(A.ag.after1(10, T.mg.echo(am.clip(e)))))
        am.end(s, work)

# The report's check (tool name `mugen`, 11-11; Agent/Loop.bend's held
# report, AGENT_REPORT=1): her `## mugen` report stands (exit 0) when the
# file her edits leave solves the task; else the tool writes the report the
# session earned (exit 1), as the loop writes it after the heading line.
# Nothing is marked solved here: only a passing check call solves a task.
def am.report.why(+t: AmT, +f: List<&2, U32>, +echo: List<&2, U32>) -> List<&2, U32>:
  +path = am.path(t)
  +what = Bool.pick(List<&2, U32>, S.eq(f, am.f0(t)), T.cat([S.b("Nothing was done: no edit applied, so "), path, S.b(" is as it was given.")]),
    Bool.pick(List<&2, U32>, S.suffix(echo, S.b("(exit 0)")), T.cat([S.b("Not done: "), path, S.b(" passes its check without the definition the task asks for.")]),
      S.b("Not done: the check fails.")))
  T.cat([S.b("\n"), what, S.b("\n\n`bend "), path, S.b(" --check-only` now:\n\n```\n"), S.chomp(S.lines.take(echo, 8n)), S.b("\n```\n\n")])

def am.report.on(s: Bool, +t: AmT, +f: List<&2, U32>, +echo: List<&2, U32>) -> IO(Unit):
  match s:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        IO.write(S.str(am.report.why(t, f, echo)))
        IO.die(Unit, 1, "agent-mugen: her report does not stand")

def am.report.say(o: AmO, +t: AmT, +f: List<&2, U32>) -> IO(Unit):
  match o:
    case AmO{+e, s}:
      am.report.on(s, t, f, e)

def am.report.check(+t: AmT, +ex: List<&2, U32>, +bend: String, +work: String) -> IO(Unit):
  +f = am.replay(am.calls(A.ag.blocks(10, A.ag.hds.bytes(), ex)), t, am.f0(t))
  do IO<Unit>:
    o : AmO <- am.check(t, f, am.path(t), bend, work)
    am.report.say(o, t, f)

def am.tool.go(report: Bool, t: Maybe<&2, List<&2, U32>>, ep: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match report t ep:
    case True{} Some{+tx} Some{+ex}:
      do IO<Unit>:
        +bend : String <- S.env("BEND", "bend")
        +work : String <- S.env("AGENT_WORK", "")
        am.report.check(am.task.of(tx), ex, bend, work)
    case False{} Some{+tx} Some{+ex}:
      +task = am.task.of(tx)
      do IO<Unit>:
        +bend : String <- S.env("BEND", "bend")
        +work : String <- S.env("AGENT_WORK", "")
        o : AmO <- am.run(task, am.calls(A.ag.blocks(10, A.ag.hds.bytes(), ex)), bend, work)
        am.say(o, work)
    case _ _ _:
      IO.die(Unit, 2, "agent-mugen: cannot read the task or the episode")

# xs: the arguments after `agent-mugen`
def am.tool(xs: List<String>) -> IO(Unit):
  match xs:
    case +task <> +tool <> Nil{}:
      do IO<Unit>:
        t : Maybe<&2, List<&2, U32>> <- S.slurp(task)
        ep : Maybe<&2, List<&2, U32>> <- S.slurp("/dev/stdin")
        am.tool.go(String.eq(tool, "mugen"), t, ep)
    case _:
      IO.die(Unit, 2, "usage: agent-mugen TASK TOOL < EPISODE")

# The live tool -------------------------------------------------------------------------
#
#   agent-mugen-live TOOL < EPISODE
#       mugen's `/ana TASK` (mugen 0.13.0, 2026-11-03): `ana-mugen` runs ana's
#       loop on the ask with this tool, and her calls run for real, on the
#       files under the directory it runs in.  The episode's last call:
#         read PATH FROM LIMIT   the file's lines, as mugen's read
#         edit PATH -old +new    written when the old lines occur once in the
#                                file; the echo is mugen's diff, else its refusal
#         shell bend PATH --check-only, grep -nE '^(def|law) (A|B)[(:]' PATH,
#                                bend base A | head -1 (the evaluation's three);
#                                the other languages' calls her sessions make
#                                (docs/MUGEN-SHAPE.md): ghc -fno-code -w PATH,
#                                agda PATH, lake env lean PATH, nix-instantiate
#                                --eval --strict PATH, ana-type PATH NAME...,
#                                ana-goal PATH (bend/Look.bend)
#       A PATH that starts with `/` or holds `..` is refused, as is any other
#       command (exit 127 in its echo): ana gets no general shell, and a call's
#       words reach the program as its arguments, through no shell.  A checker
#       still runs what its file asks it to at check time (Template Haskell,
#       Lean's #eval): `/ana` is for files you would check yourself.  After its
#       echo the tool exits 1, so ana goes on until she reports (`## mugen`)
#       and ends, or spends her calls; 2 when the episode does not read.

# a path under the directory the tool runs in
def am.live.ok(+p: List<&2, U32>) -> Bool:
  Bool.and(Bool.not(T.empty(p)), Bool.and(Bool.not(S.head.is(p, 47)), Bool.not(S.infix(p, S.b("..")))))

def am.live.open(ok: Bool, +path: List<&2, U32>) -> IO(Maybe<&2, List<&2, U32>>):
  match ok:
    case True{}:
      S.slurp(S.str(path))
    case False{}:
      IO.pure(Maybe<&2, List<&2, U32>>, None{})

def am.live.refuse() -> AmO:
  AmO{T.mg.shell.echo(S.b("mugen (ana's tool): this shell runs only the checker on a path under its directory (`bend PATH --check-only`, `ghc -fno-code -w PATH`, `agda PATH`, `lake env lean PATH`, `nix-instantiate --eval --strict PATH`), `ana-type PATH NAME...`, `ana-goal PATH`, `grep -nE` and `bend base`"), S.b("127")), False{}}

def am.live.enoent(+path: List<&2, U32>) -> List<&2, U32>:
  T.cat([S.b("ENOENT: no such file or directory, open '"), path, S.b("'")])

def am.live.read.got(m: Maybe<&2, List<&2, U32>>, +path: List<&2, U32>, +ws: List<&2, List<&2, U32>>) -> AmO:
  match m:
    case Some{+f}:
      AmO{T.mg.read.echo(f, Nat.max(1n, am.nat.or(T.field(ws, 1n), 1n)), am.nat.or(T.field(ws, 2n), 2000n)), False{}}
    case None{}:
      AmO{am.live.enoent(path), False{}}

def am.live.read(+body: List<&2, U32>) -> IO(AmO):
  +ws = T.mg.words(body)
  +path = T.field(ws, 0n)
  do IO<AmO>:
    m : Maybe<&2, List<&2, U32>> <- am.live.open(am.live.ok(path), path)
    return am.live.read.got(m, path, ws)

# mugen's edit on the file f (Tools.bend tl.edit.apply's reasons)
def am.live.edit(+path: List<&2, U32>, +f: List<&2, U32>, +rest: List<&2, List<&2, U32>>) -> AmE:
  +old = am.signed(rest, 45)
  +new = am.signed(rest, 43)
  +n = Bool.pick(Nat, T.empty(old), 0n, T.mg.count(f, old))
  +why = Bool.pick(String, Nat.is_eq(n, 0n), "old was not found",
    Bool.pick(String, Nat.is_lt(1n, n), "old matches more than once; give more context, or all", ""))
  Bool.pick(AmE, String.eq(why, ""), AmE{S.replace.first(f, old, new), Nil{}}, AmE{f, am.edit.why(path, why)})

def am.live.edit.if(ok: Bool, +path: List<&2, U32>, +f: List<&2, U32>, +f2: List<&2, U32>, +why: List<&2, U32>) -> IO(AmO):
  match ok:
    case True{}:
      do IO<AmO>:
        S.write(S.str(path), f2)
        return AmO{T.mg.diff(path, f, f2), False{}}
    case False{}:
      IO.pure(AmO, AmO{why, False{}})

def am.live.edit.put(e: AmE, +path: List<&2, U32>, +f: List<&2, U32>) -> IO(AmO):
  match e:
    case AmE{+f2, +why}:
      am.live.edit.if(T.empty(why), path, f, f2, why)

def am.live.edit.got(m: Maybe<&2, List<&2, U32>>, +path: List<&2, U32>, +rest: List<&2, List<&2, U32>>) -> IO(AmO):
  match m:
    case Some{+f}:
      am.live.edit.put(am.live.edit(path, f, rest), path, f)
    case None{}:
      IO.pure(AmO, AmO{am.edit.why(path, "no such file"), False{}})

def am.live.edit.call(+body: List<&2, U32>) -> IO(AmO):
  +ls = S.split(body, 10)
  +path = T.field(ls, 0n)
  +rest = List.drop(&2, List<&2, U32>, ls, 1n)
  do IO<AmO>:
    m : Maybe<&2, List<&2, U32>> <- am.live.open(am.live.ok(path), path)
    am.live.edit.got(m, path, rest)

def am.live.check(ok: Bool, +path: List<&2, U32>, +bend: String) -> IO(AmO):
  match ok:
    case True{}:
      do IO<AmO>:
        +o : S.Out <- S.run(".", ["BEND_NO_TELEMETRY=1"], 180, bend, [S.str(path), "--check-only"], Nil{})
        return AmO{T.mg.shell.echo(S.chomp(S.lines.take(S.Out.text(o), 100n)), S.b(U32.show(S.Out.status(o)))), False{}}
    case False{}:
      IO.pure(AmO, am.live.refuse())

def am.live.grep.got(m: Maybe<&2, List<&2, U32>>, +ns: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> AmO:
  match m:
    case Some{+f}:
      +hits = T.mg.grep.go(T.split(f, 10), ns, 1n)
      AmO{T.mg.shell.echo(T.mg.join(hits, [10]), am.code(Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, hits), 0n)))), False{}}
    case None{}:
      AmO{T.mg.shell.echo(T.cat([S.b("grep: "), path, S.b(": No such file or directory")]), S.b("2")), False{}}

# grep -nE '^(def|law) (A|B)[(:]' PATH, on the file
def am.live.grep(+cmd: List<&2, U32>) -> IO(AmO):
  +rest = S.strip(cmd, S.b("grep -nE '^(def|law) ("))
  +ns0 = am.before.str(rest, S.b(")[(:]' "))
  +path = L.v2.after.str(rest, S.b(")[(:]' "))
  +ns = am.unesc(S.split(ns0, 124))
  do IO<AmO>:
    m : Maybe<&2, List<&2, U32>> <- am.live.open(am.live.ok(path), path)
    return am.live.grep.got(m, ns, path)

# The other languages' calls: cmd's words (the program's name first, a quoted
# name unquoted) when it is one of them on a path under the directory, else none
def am.live.argv.one(+cmd: List<&2, U32>, +p: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +path = S.strip(cmd, p)
  Bool.pick(List<&2, List<&2, U32>>, Bool.and(am.live.ok(path), Bool.not(S.infix(path, [32]))), T.mg.words(cmd), Nil{})

def am.live.unq(+n: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Bool.or(S.head.is(n, 39), S.head.is(n, 34)), List.take(&2, U32, List.drop(&2, U32, n, 1n), Nat.sub(S.len(n), 2n)), n)

def am.live.unqs(ns: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      am.live.unq(n) <> am.live.unqs(t)

def am.live.argv.type(+cmd: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ws = T.mg.words(cmd)
  Bool.pick(List<&2, List<&2, U32>>, am.live.ok(T.field(ws, 1n)), am.live.unqs(ws), Nil{})

def am.live.argv.lean(+cmd: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +nix = S.b("nix-instantiate --eval --strict ")
  Bool.pick(List<&2, List<&2, U32>>, S.prefix(cmd, S.b("lake env lean ")), am.live.argv.one(cmd, S.b("lake env lean ")),
    Bool.pick(List<&2, List<&2, U32>>, S.prefix(cmd, nix), am.live.argv.one(cmd, nix), Nil{}))

def am.live.argv.at(+cmd: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ghc = S.b("ghc -fno-code -w ")
  Bool.pick(List<&2, List<&2, U32>>, S.prefix(cmd, ghc), am.live.argv.one(cmd, ghc),
    Bool.pick(List<&2, List<&2, U32>>, S.prefix(cmd, S.b("agda ")), am.live.argv.one(cmd, S.b("agda ")),
      Bool.pick(List<&2, List<&2, U32>>, S.prefix(cmd, S.b("ana-goal ")), am.live.argv.one(cmd, S.b("ana-goal ")),
        Bool.pick(List<&2, List<&2, U32>>, S.prefix(cmd, S.b("ana-type ")), am.live.argv.type(cmd), am.live.argv.lean(cmd)))))

def am.live.argv(+cmd: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, S.infix(cmd, [10]), Nil{}, am.live.argv.at(cmd))

def am.live.strs(xs: List<&2, List<&2, U32>>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      S.str(x) <> am.live.strs(t)

def am.live.lang(xs: List<&2, List<&2, U32>>) -> IO(AmO):
  match xs:
    case Nil{}:
      IO.pure(AmO, am.live.refuse())
    case +prog <> args:
      do IO<AmO>:
        +o : S.Out <- S.run(".", ["BEND_NO_TELEMETRY=1"], 300, S.str(prog), am.live.strs(args), Nil{})
        return AmO{T.mg.shell.echo(S.chomp(S.lines.take(S.Out.text(o), 100n)), S.b(U32.show(S.Out.status(o)))), False{}}

def am.live.base(bs: Bool, +cmd: List<&2, U32>, +bend: String) -> IO(AmO):
  match bs:
    case True{}:
      am.base(cmd, bend)
    case False{}:
      am.live.lang(am.live.argv(cmd))

def am.live.shell.grep(gr: Bool, +cmd: List<&2, U32>, +bend: String) -> IO(AmO):
  match gr:
    case True{}:
      am.live.grep(cmd)
    case False{}:
      am.live.base(Bool.or(S.prefix(cmd, S.b("bend base ")), Bool.and(S.prefix(cmd, S.b("for n in ")), S.infix(cmd, S.b("bend base $n")))), cmd, bend)

def am.live.shell.check(chk: Bool, +cmd: List<&2, U32>, +bend: String) -> IO(AmO):
  match chk:
    case True{}:
      +path = S.strip(List.take(&2, U32, cmd, Nat.sub(S.len(cmd), 13n)), S.b("bend "))
      am.live.check(am.live.ok(path), path, bend)
    case False{}:
      am.live.shell.grep(S.prefix(cmd, S.b("grep -nE '^(def|law) (")), cmd, bend)

def am.live.shell(+cmd: List<&2, U32>, +bend: String) -> IO(AmO):
  am.live.shell.check(Bool.and(S.prefix(cmd, S.b("bend ")), S.suffix(cmd, S.b(" --check-only"))), cmd, bend)

def am.live.run.edit(ed: Bool, +body: List<&2, U32>, +bend: String) -> IO(AmO):
  match ed:
    case True{}:
      am.live.edit.call(body)
    case False{}:
      am.live.shell(body, bend)

def am.live.run.read(rd: Bool, +lb: List<&2, U32>, +body: List<&2, U32>, +bend: String) -> IO(AmO):
  match rd:
    case True{}:
      am.live.read(body)
    case False{}:
      am.live.run.edit(S.eq(lb, S.b("edit")), body, bend)

def am.live.run.if(none: Bool, +x: List<&2, U32>, +bend: String) -> IO(AmO):
  match none:
    case True{}:
      IO.pure(AmO, AmO{S.b("mugen (ana's tool): no call before `## echo`"), False{}})
    case False{}:
      am.live.run.read(S.eq(am.label(x), S.b("read")), am.label(x), am.body(x), bend)

# the echo as the loop appends it; exit 1: ana goes on
def am.live.say(o: AmO) -> IO(Unit):
  match o:
    case AmO{+e, s}:
      do IO<Unit>:
        IO.write(S.str(A.ag.after1(10, T.mg.echo(am.clip(e)))))
        IO.die(Unit, 1, "agent-mugen-live: ana goes on")

# The report's check for /ana (tool name `mugen`, 11-11): her report stands
# (exit 0) when an edit applied and the last check she ran passes now, run
# again on the files as they are; else the tool writes what is true (exit 1).
def am.live.is.check(+cmd: List<&2, U32>) -> Bool:
  Bool.or(Bool.and(S.prefix(cmd, S.b("bend ")), S.suffix(cmd, S.b(" --check-only"))),
    Bool.or(S.prefix(cmd, S.b("ghc -fno-code -w ")), Bool.or(S.prefix(cmd, S.b("agda ")),
      Bool.or(S.prefix(cmd, S.b("lake env lean ")), S.prefix(cmd, S.b("nix-instantiate --eval --strict "))))))

# what her session did: whether an edit applied (its echo is not a
# refusal), and the last check she ran (empty: none); prev the last call
def am.live.did(bs: List<&2, A.Blk>, +prev: List<&2, U32>, +ch: Bool, +chk: List<&2, U32>) -> Bool & List<&2, U32>:
  match bs:
    case Nil{}:
      (ch, chk)
    case A.Blk{+c, +x} <> t:
      +lb = am.label(prev)
      +echo = Nat.is_eq(c, 7n)
      +ch2 = Bool.or(ch, Bool.and(Bool.and(echo, S.eq(lb, S.b("edit"))), Bool.not(S.infix(x, S.b("No file was changed.")))))
      +chk2 = Bool.pick(List<&2, U32>, Bool.and(Bool.and(echo, S.eq(lb, S.b("shell"))), am.live.is.check(am.body(prev))), am.body(prev), chk)
      am.live.did(t, Bool.pick(List<&2, U32>, A.ag.is.call(c), x, prev), ch2, chk2)

def am.live.report.why(+ch: Bool, +chk: List<&2, U32>, +echo: List<&2, U32>) -> List<&2, U32>:
  +ran = Bool.not(T.empty(chk))
  +what = Bool.pick(List<&2, U32>, Bool.not(ch), S.b("Nothing was done: no edit applied, so no file was changed."),
    Bool.pick(List<&2, U32>, Bool.not(ran), S.b("Not checked: the edits applied, but no check ran."), S.b("Not done: the last check fails.")))
  +now = Bool.pick(List<&2, U32>, ran, T.cat([S.b("\n\n`"), chk, S.b("` now:\n\n```\n"), S.chomp(S.lines.take(echo, 8n)), S.b("\n```")]), Nil{})
  T.cat([S.b("\n"), what, now, S.b("\n\n")])

def am.live.report.say(stands: Bool, +ch: Bool, +chk: List<&2, U32>, +echo: List<&2, U32>) -> IO(Unit):
  match stands:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        IO.write(S.str(am.live.report.why(ch, chk, echo)))
        IO.die(Unit, 1, "agent-mugen-live: her report does not stand")

def am.live.report.run(ran: Bool, +chk: List<&2, U32>, +bend: String) -> IO(AmO):
  match ran:
    case True{}:
      am.live.shell(chk, bend)
    case False{}:
      IO.pure(AmO, AmO{Nil{}, False{}})

def am.live.report.go(did: Bool & List<&2, U32>) -> IO(Unit):
  (+ch, +chk) = did
  do IO<Unit>:
    +bend : String <- S.env("BEND", "bend")
    o : AmO <- am.live.report.run(Bool.not(T.empty(chk)), chk, bend)
    +echo : List<&2, U32> = AmO.echo(o)
    am.live.report.say(Bool.and(Bool.and(ch, Bool.not(T.empty(chk))), S.suffix(echo, S.b("(exit 0)"))), ch, chk, echo)

def am.live.report(+ex: List<&2, U32>) -> IO(Unit):
  am.live.report.go(am.live.did(A.ag.blocks(10, A.ag.hds.bytes(), ex), Nil{}, False{}, Nil{}))

def am.live.go(report: Bool, ep: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match report ep:
    case True{} Some{+ex}:
      am.live.report(ex)
    case False{} Some{+ex}:
      +x = am.last.or(am.calls(A.ag.blocks(10, A.ag.hds.bytes(), ex)))
      do IO<Unit>:
        +bend : String <- S.env("BEND", "bend")
        o : AmO <- am.live.run.if(T.empty(x), x, bend)
        am.live.say(o)
    case _ None{}:
      IO.die(Unit, 2, "agent-mugen-live: cannot read the episode")

# xs: the arguments after `agent-mugen-live`
def am.live(xs: List<String>) -> IO(Unit):
  match xs:
    case +tool <> Nil{}:
      do IO<Unit>:
        ep : Maybe<&2, List<&2, U32>> <- S.slurp("/dev/stdin")
        am.live.go(String.eq(tool, "mugen"), ep)
    case _:
      IO.die(Unit, 2, "usage: agent-mugen-live TOOL < EPISODE")

# The evaluation ------------------------------------------------------------------------
#
#   agent-mugen-eval CKPT DIR [K]
#   agent-mugen-eval selftest DIR [K]
#       Each checked unit of AGENT_RESULTS (run/v2/results/bend.holdout.nul,
#       the units every run held out) in each shape it has (direct; fill when
#       it has a hole; repair-0 when it has a mutant) as a task: the ask as
#       the renderer writes it (the `## user` turn), the tool above.  First
#       the task's reference session (the ask, the edit that gives the
#       unit's own body, the check) runs through the tool; a task it does
#       not solve under today's Bend is left out and counted (stale).  Then
#       (not with selftest) each task is an episode: `ana --agent`
#       (AGENT_BIN, run/gcroot-bend-generate-agent's bend-generate, +RTS --threads
#       THREADS (5) -RTS) with CKPT, TEMPERATURE (0), TOKENS (512) a stretch,
#       AGENT_CALLS (8), PROCS (3) at a time; K: only the first K units.
#       The unit's source tree is AGENT_SRC, else Eval.bend's (run/code-sources*,
#       then ~/src).  Writes DIR/task.N.nul, DIR/prompt.N, DIR/ref.N (the
#       reference session), DIR/episodes.nul (N, the episode), DIR/mugen.nul
#       (UNIT/SHAPE; N RS UNIT RS SHAPE RS SOLVED RS CALLS RS SECS) and
#       DIR/report.txt: a line a shape, solved, then all.

def am.ask(+sh: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.eq(sh, S.b("direct")), T.mg.ask.direct(fs, path),
    Bool.pick(List<&2, U32>, S.eq(sh, S.b("fill")), T.mg.ask.fill(fs, path), T.mg.ask.repair(fs, path)))

def am.prompt(+t: AmT) -> List<&2, U32>:
  T.mg.user(am.ask(AmT.shape(t), AmT.fs(t), am.path(t)))

# the reference session up to its check's `## echo`
def am.ref(+t: AmT) -> List<&2, U32>:
  +fs = AmT.fs(t)
  +path = am.path(t)
  T.cat([am.prompt(t), T.mg.edit(path, am.f0(t), T.mg.with(fs, T.field(fs, 7n))),
    T.turn(S.b("shell"), T.cat([S.b("bend "), path, S.b(" --check-only\n")])), S.b("## echo\n")])

def am.shapes(+fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  +fill = Bool.not(T.empty(T.field(fs, 13n)))
  +rep = Nat.is_lt(0n, T.mutant.count(fs))
  S.b("direct") <> am.keep.on(fill, S.b("fill"), am.keep.on(rep, S.b("repair-0"), Nil{}))

# a task to run: its number, unit, shape, and the first call made for her
type AmQ is Data:
  AmQ{n: Nat, unit: List<&2, U32>, shape: List<&2, U32>, first: List<&2, U32>}

def AmQ.n(+q: AmQ) -> Nat:
  match q:
    case AmQ{n, u, s, f}:
      n

def am.q.nth(qs: List<&2, AmQ>, +i: Nat) -> AmQ:
  match qs:
    case Nil{}:
      AmQ{i, Nil{}, Nil{}, Nil{}}
    case +q <> more:
      Bool.pick(AmQ, Nat.is_eq(AmQ.n(q), i), q, am.q.nth(more, i))

def AmO.solved(+o: AmO) -> Bool:
  match o:
    case AmO{e, s}:
      s

# A task's files, and whether its reference session solves it
def am.prep.one(+n: Nat, +dir: String, +u: List<&2, U32>, +src: String, +sh: List<&2, U32>, +rec: List<&2, U32>, +bend: String) -> IO(Bool):
  +tb = am.task.bytes(u, src, sh, rec)
  +t = am.task.of(tb)
  +ref = am.ref(t)
  do IO<Bool>:
    S.write(dir ++ "/task." ++ Nat.show(n) ++ ".nul", tb)
    S.write(dir ++ "/prompt." ++ Nat.show(n), am.prompt(t))
    S.write(dir ++ "/ref." ++ Nat.show(n), ref)
    +w : String = dir ++ "/rwork." ++ Nat.show(n)
    S.mkdir(w)
    o : AmO <- am.run(t, am.calls(A.ag.blocks(10, A.ag.hds.bytes(), ref)), bend, w)
    S.rm(w)
    return AmO.solved(o)

type AmP is Data:
  AmP{n: Nat, qs: List<&2, AmQ>, stale: Nat}

def am.prep.keep(ok: Bool, +n: Nat, +u: List<&2, U32>, +sh: List<&2, U32>, +first: List<&2, U32>, p: AmP) -> AmP:
  match ok p:
    case True{} AmP{k, qs, st}:
      AmP{1n+k, AmQ{n, u, sh, first} <> qs, st}
    case False{} AmP{k, qs, st}:
      AmP{1n+k, qs, 1n+st}

# The first call made for her (AM_FIRST=1, the default since 11-11; the
# loop's AGENT_FIRST): the call her sessions open with for the shape
# (Transcript.bend's mg.direct, mg.fill, mg.repair): an added definition,
# a read of the head's last 24 lines; a hole or a fix, the check
def am.first(+t: AmT) -> List<&2, U32>:
  +path = am.path(t)
  +n = List.length(&2, List<&2, U32>, T.mg.rows(am.f0(t)))
  +from = Bool.pick(Nat, Nat.is_lt(n, 25n), 1n, Nat.sub(n, 23n))
  Bool.pick(List<&2, U32>, S.eq(AmT.shape(t), S.b("direct")),
    T.cat([T.turn(S.b("read"), T.cat([path, S.b(" "), T.mg.n(from), S.b(" "), T.mg.n(Nat.sub(Nat.add(n, 1n), from)), S.b("\n")])), S.b("## echo\n")]),
    T.cat([T.turn(S.b("shell"), T.cat([S.b("bend "), path, S.b(" --check-only\n")])), S.b("## echo\n")]))

def am.prep.shapes(ss: List<&2, List<&2, U32>>, +dir: String, +u: List<&2, U32>, +src: String, +rec: List<&2, U32>, +bend: String, p: AmP) -> IO(AmP):
  match ss p:
    case Nil{} _:
      IO.pure(AmP, p)
    case +sh <> more AmP{+k, qs, st}:
      do IO<AmP>:
        +ok : Bool <- am.prep.one(k, dir, u, src, sh, rec, bend)
        Ck.log("agent-mugen-eval: task " ++ Nat.show(k) ++ " " ++ S.str(u) ++ " " ++ S.str(sh) ++ Bool.pick(String, ok, "", " STALE (its own body does not pass)"))
        am.prep.shapes(more, dir, u, src, rec, bend, am.prep.keep(ok, k, u, sh, am.first(am.task.of(am.task.bytes(u, src, sh, rec))), AmP{k, qs, st}))

def am.src(+given: String, +roots: List<&2, String>, +home: String, +u: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> IO(String):
  Bool.pick(IO(String), String.eq(given, ""), Ev.ev.src.if(True{}, roots, home, u, T.field(fs, 7n)), IO.pure(String, given))

def am.prep(kvs: List<&2, Ev.EvKv>, +dir: String, +given: String, +roots: List<&2, String>, +home: String, +bend: String, p: AmP) -> IO(AmP):
  match kvs:
    case Nil{}:
      IO.pure(AmP, p)
    case Ev.EvKv{+u, +rec} <> more:
      +fs = S.split(rec, 30)
      do IO<AmP>:
        +src : String <- am.src(given, roots, home, u, fs)
        p2 : AmP <- am.prep.shapes(am.shapes(fs), dir, u, src, rec, bend, p)
        am.prep(more, dir, given, roots, home, bend, p2)

def am.kv.on(keep: Bool, +x: Ev.EvKv, rest: List<&2, Ev.EvKv>) -> List<&2, Ev.EvKv>:
  match keep:
    case True{}:
      x <> rest
    case False{}:
      rest

def am.bend.only(kvs: List<&2, Ev.EvKv>) -> List<&2, Ev.EvKv>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+u, +rec} <> more:
      am.kv.on(S.eq(T.field(S.split(rec, 30), 0n), S.b("bend")), Ev.EvKv{u, rec}, am.bend.only(more))

# The stricter score -------------------------------------------------------------
#
#   agent-mugen-score DIR
#       (11-11.)  The check alone let wrong code count: at step 99,500, 21
#       of the 58 "solved" were not the unit's behaviour (a `nonzero` that
#       never says None, `go` with and for xor, swapped assert bodies).  For
#       each episode of the evaluation in DIR that solved its task
#       (mugen.nul), the file her edits leave (her calls in episodes.nul
#       replayed on the shape's file) is held to the unit's own definition:
#         same      her file is the unit's own
#         proof     the unit is a proof (a law, or a def whose type is an
#                   equation): any proof the check passes is right
#         right     on test inputs her definition gives what the original
#                   gives: `{f(x) == f.orig_(x) : R}` by `{==}`, for each x
#         wrong     it does not, or it does not check against them
#         slow      her tests timed out where the original's passed
#         untested  no inputs for a parameter's type (a record, an array,
#                   IO, ...), a result that cannot be compared (IO, a
#                   function), or tests that fail on the original itself
#       The tests run on the original first (the unit's own file with
#       them), so a broken test leaves a task untested, never wrong.  Inputs:
#       Nat 0n 1n 2n 5n; U32 0 1 2 7 4294967295; Bool; String "" "a" "ab c";
#       Unit; lists, Maybe, Result and pairs of those; their products, at
#       most 16 cases, each file's check 180 s at most, as the tool's.  Writes
#       DIR/score.tsv (N, shape, verdict, unit) and DIR/score.txt; the
#       evaluation runs it after report.txt.

def am.sc.lstrip(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> +t:
      Bool.pick(List<&2, U32>, Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 10)), am.sc.lstrip(t), c <> t)

# without spaces and newlines at either end
def am.sc.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, am.sc.lstrip(List.reverse(&2, U32, am.sc.lstrip(xs))))

def am.sc.opens(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 40), U32.is_eq(c, 60)), Bool.or(U32.is_eq(c, 91), U32.is_eq(c, 123)))

def am.sc.closes(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 41), U32.is_eq(c, 62)), Bool.or(U32.is_eq(c, 93), U32.is_eq(c, 125)))

# `->` and `=>` masked, so their `>` closes no bracket
def am.sc.mask(+xs: List<&2, U32>) -> List<&2, U32>:
  S.replace(S.replace(xs, S.b("->"), [1, 1]), S.b("=>"), [2, 2])

def am.sc.unmask(+xs: List<&2, U32>) -> List<&2, U32>:
  S.replace(S.replace(xs, [1, 1], S.b("->")), [2, 2], S.b("=>"))

# xs cut at each sep outside brackets ((), <>, [], {}; d the depth), each
# piece trimmed
def am.sc.cut(xs: List<&2, U32>, +sep: U32, +d: Nat, +cur: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, am.sc.trim(List.reverse(&2, U32, cur)) <> acc)
    case +c <> t:
      +hit = Bool.and(U32.is_eq(c, sep), Nat.is_eq(d, 0n))
      +d2 = Nat.sub(Nat.add(d, Bool.pick(Nat, am.sc.opens(c), 1n, 0n)), Bool.pick(Nat, am.sc.closes(c), 1n, 0n))
      am.sc.cut(t, sep, Bool.pick(Nat, hit, d, d2), Bool.pick(List<&2, U32>, hit, Nil{}, c <> cur),
        Bool.pick(List<&2, List<&2, U32>>, hit, am.sc.trim(List.reverse(&2, U32, cur)) <> acc, acc))

def am.sc.cuts(+xs: List<&2, U32>, +sep: U32) -> List<&2, List<&2, U32>>:
  am.sc.cut(xs, sep, 0n, Nil{}, Nil{})

def am.sc.len(+xs: List<&2, List<&2, U32>>) -> Nat:
  List.length(&2, List<&2, U32>, xs)

# A type's inputs ------------------------------------------------------------

# what a type is, for its inputs
type AmK is Type:
  AmKLeaf{vs: List<&2, List<&2, U32>>}
  AmKList{x: List<&2, U32>}
  AmKMaybe{x: List<&2, U32>}
  AmKPair{a: List<&2, U32>, b: List<&2, U32>}
  AmKRes{e: List<&2, U32>, a: List<&2, U32>}

def am.sc.is(+ty: List<&2, U32>, +open: List<&2, U32>) -> Bool:
  Bool.and(S.prefix(ty, open), S.suffix(ty, S.b(">")))

# the text between `open` and the last `>`
def am.sc.within(+ty: List<&2, U32>, +open: List<&2, U32>) -> List<&2, U32>:
  am.sc.trim(List.take(&2, U32, S.strip(ty, open), Nat.sub(Nat.sub(S.len(ty), S.len(open)), 1n)))

# that, less a leading region (`&2, `)
def am.sc.inner(+ty: List<&2, U32>, +open: List<&2, U32>) -> List<&2, U32>:
  +x = am.sc.within(ty, open)
  Bool.pick(List<&2, U32>, S.head.is(x, 38), am.sc.trim(L.v2.after.str(x, S.b(","))), x)

def am.sc.leaf(+ty: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, S.eq(ty, S.b("Nat")), [S.b("0n"), S.b("1n"), S.b("2n"), S.b("5n")],
    Bool.pick(List<&2, List<&2, U32>>, S.eq(ty, S.b("U32")), [S.b("0"), S.b("1"), S.b("2"), S.b("7"), S.b("4294967295")],
      Bool.pick(List<&2, List<&2, U32>>, S.eq(ty, S.b("Bool")), [S.b("True{}"), S.b("False{}")],
        Bool.pick(List<&2, List<&2, U32>>, S.eq(ty, S.b("String")), [S.b("\"\""), S.b("\"a\""), S.b("\"ab c\"")],
          Bool.pick(List<&2, List<&2, U32>>, S.eq(ty, S.b("Unit")), [S.b("Unit{}")], Nil{})))))

# a pair at the top (`A & B`), else a list, a Maybe, a Result, else a leaf
# (no inputs: none)
def am.sc.kind(+ty0: List<&2, U32>) -> AmK:
  +ty = am.sc.trim(ty0)
  +amp = am.sc.cuts(ty, 38)
  +res = am.sc.cuts(am.sc.within(ty, S.b("Result<")), 44)
  +nr = am.sc.len(res)
  Bool.pick(AmK, Nat.is_eq(am.sc.len(amp), 2n), AmKPair{T.field(amp, 0n), T.field(amp, 1n)},
    Bool.pick(AmK, am.sc.is(ty, S.b("List<")), AmKList{am.sc.inner(ty, S.b("List<"))},
      Bool.pick(AmK, am.sc.is(ty, S.b("Maybe<")), AmKMaybe{am.sc.inner(ty, S.b("Maybe<"))},
        Bool.pick(AmK, Bool.and(am.sc.is(ty, S.b("Result<")), Nat.is_le(2n, nr)), AmKRes{T.field(res, Nat.sub(nr, 2n)), T.field(res, Nat.sub(nr, 1n))},
          AmKLeaf{am.sc.leaf(ty)}))))

# the second input (the first when there is one) and the last
def am.sc.a(+vs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  T.field(vs, Nat.min(1n, Nat.sub(am.sc.len(vs), 1n)))

def am.sc.z(+vs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  T.field(vs, Nat.sub(am.sc.len(vs), 1n))

# out, when vs has inputs
def am.sc.if(+vs: List<&2, List<&2, U32>>, +out: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(am.sc.len(vs), 0n), Nil{}, out)

def am.sc.lists(+vs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  +a = am.sc.a(vs)
  +z = am.sc.z(vs)
  am.sc.if(vs, [S.b("[]"), T.cat([S.b("["), a, S.b("]")]), T.cat([S.b("["), a, S.b(", "), z, S.b("]")]), T.cat([S.b("["), z, S.b(", "), a, S.b(", "), z, S.b("]")])])

def am.sc.maybes(+vs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  am.sc.if(vs, [S.b("None{}"), T.cat([S.b("Some{"), am.sc.a(vs), S.b("}")]), T.cat([S.b("Some{"), am.sc.z(vs), S.b("}")])])

def am.sc.results(+es: List<&2, List<&2, U32>>, +xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  am.sc.if(es, am.sc.if(xs, [T.cat([S.b("Done{"), T.field(xs, 0n), S.b("}")]), T.cat([S.b("Done{"), am.sc.z(xs), S.b("}")]), T.cat([S.b("Fail{"), T.field(es, 0n), S.b("}")])]))

def am.sc.pair(+x: List<&2, U32>, +y: List<&2, U32>) -> List<&2, U32>:
  T.cat([S.b("("), x, S.b(", "), y, S.b(")")])

def am.sc.pairs(+xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  am.sc.if(xs, am.sc.if(ys, [am.sc.pair(T.field(xs, 0n), T.field(ys, 0n)), am.sc.pair(am.sc.a(xs), am.sc.z(ys)), am.sc.pair(am.sc.z(xs), am.sc.a(ys))]))

# a type's inputs, as text (none: no inputs for it); fuel the nesting
def am.sc.vals(fuel: Nat, k: AmK) -> List<&2, List<&2, U32>>:
  match fuel k:
    case 0n _:
      Nil{}
    case 1n+p AmKLeaf{+vs}:
      vs
    case 1n+p AmKList{+x}:
      am.sc.lists(am.sc.vals(p, am.sc.kind(x)))
    case 1n+p AmKMaybe{+x}:
      am.sc.maybes(am.sc.vals(p, am.sc.kind(x)))
    case 1n+(+p) AmKPair{+a, +b}:
      am.sc.pairs(am.sc.vals(p, am.sc.kind(a)), am.sc.vals(p, am.sc.kind(b)))
    case 1n+(+p) AmKRes{+e, +a}:
      am.sc.results(am.sc.vals(p, am.sc.kind(e)), am.sc.vals(p, am.sc.kind(a)))

# The declaration ------------------------------------------------------------

# a def's head: its name, its parameters' types, its result type, and
# whether it reads (`def NAME(PARAMS) -> TYPE:`, no type parameters)
type AmD is Data:
  AmD{name: List<&2, U32>, tys: List<&2, List<&2, U32>>, ret: List<&2, U32>, ok: Bool}

def am.sc.tys(ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      am.sc.trim(L.v2.after.str(p, S.b(":"))) <> am.sc.tys(t)

def am.sc.colon(+x: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.suffix(x, S.b(":")), List.take(&2, U32, x, Nat.sub(S.len(x), 1n)), x)

def am.sc.decl(+d0: List<&2, U32>) -> AmD:
  +d = am.sc.mask(S.chomp(d0))
  +rest = S.strip(d, S.b("def "))
  +name = am.before.str(rest, S.b("("))
  +pieces = am.sc.cuts(List.drop(&2, U32, rest, Nat.add(S.len(name), 1n)), 41)
  +args = T.field(pieces, 0n)
  +ret = am.sc.unmask(am.sc.trim(am.sc.colon(am.sc.trim(S.strip(T.field(pieces, 1n), [1, 1])))))
  +ok = Bool.and(Bool.and(S.prefix(d, S.b("def ")), Nat.is_eq(am.sc.len(pieces), 2n)),
    Bool.not(Bool.or(Bool.or(S.infix(name, S.b("<")), S.infix(name, S.b(" "))), T.empty(name))))
  AmD{name, am.sc.tys(Bool.pick(List<&2, List<&2, U32>>, T.empty(args), Nil{}, am.sc.cuts(args, 44))), ret, ok}

# a proof: a law that states an equation, or a def whose type is one
def am.sc.proof.def(d: AmD) -> Bool:
  match d:
    case AmD{n, t, +r, +ok}:
      Bool.and(ok, S.prefix(r, S.b("{")))

def am.sc.proof(+fs: List<&2, List<&2, U32>>) -> Bool:
  +d6 = T.field(fs, 6n)
  Bool.or(Bool.and(S.prefix(d6, S.b("law ")), S.infix(d6, S.b("=="))), am.sc.proof.def(am.sc.decl(d6)))

# The tests ------------------------------------------------------------------

# whether c ends a name (is not a letter, a digit, `_` or `.`)
def am.sc.edge(+c: U32) -> Bool:
  Bool.not(Bool.or(Bool.or(Bool.and(U32.is_le(97, c), U32.is_le(c, 122)), Bool.and(U32.is_le(65, c), U32.is_le(c, 90))),
    Bool.or(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), Bool.or(U32.is_eq(c, 95), U32.is_eq(c, 46)))))

# xs with `.orig_` after each call of the name (p: the name and `(`, n its
# length; ins: the name's bytes still to copy before it, prev the last byte)
def am.sc.ren.go(xs: List<&2, U32>, +p: List<&2, U32>, +n: Nat, +ins: Nat, +prev: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      +left = Bool.pick(Nat, Bool.and(Nat.is_eq(ins, 0n), Bool.and(am.sc.edge(prev), S.prefix(h <> t, p))), n, ins)
      +rest = am.sc.ren.go(t, p, n, Nat.sub(left, 1n), h)
      h <> Bool.pick(List<&2, U32>, Nat.is_eq(left, 1n), S.append(S.b(".orig_"), rest), rest)

def am.sc.ren(+xs: List<&2, U32>, +name: List<&2, U32>) -> List<&2, U32>:
  am.sc.ren.go(xs, S.append(name, S.b("(")), S.len(name), 0n, 10)

def am.sc.join(xs: List<&2, List<&2, U32>>, +sep: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      x
    case x <> more:
      T.cat([x, sep, am.sc.join(more, sep)])

def am.sc.conss(+v: List<&2, U32>, rs: List<&2, List<&2, List<&2, U32>>>) -> List<&2, List<&2, List<&2, U32>>>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      (v <> r) <> am.sc.conss(v, t)

def am.sc.cross(vs: List<&2, List<&2, U32>>, +rs: List<&2, List<&2, List<&2, U32>>>) -> List<&2, List<&2, List<&2, U32>>>:
  match vs:
    case Nil{}:
      Nil{}
    case +v <> t:
      List.append(&2, List<&2, List<&2, U32>>, am.sc.conss(v, rs), am.sc.cross(t, rs))

# every choice of one input a parameter
def am.sc.prod(vls: List<&2, List<&2, List<&2, U32>>>) -> List<&2, List<&2, List<&2, U32>>>:
  match vls:
    case Nil{}:
      [Nil{}]
    case +vs <> t:
      am.sc.cross(vs, am.sc.prod(t))

def am.sc.valss(tys: List<&2, List<&2, U32>>) -> List<&2, List<&2, List<&2, U32>>>:
  match tys:
    case Nil{}:
      Nil{}
    case +ty <> t:
      am.sc.vals(4n, am.sc.kind(ty)) <> am.sc.valss(t)

def am.sc.all.some(vls: List<&2, List<&2, List<&2, U32>>>) -> Bool:
  match vls:
    case Nil{}:
      True{}
    case +vs <> t:
      Bool.and(Bool.not(Nat.is_eq(am.sc.len(vs), 0n)), am.sc.all.some(t))

def am.sc.keep(keep: Bool, +x: List<&2, List<&2, U32>>, rest: List<&2, List<&2, List<&2, U32>>>) -> List<&2, List<&2, List<&2, U32>>>:
  match keep:
    case True{}:
      x <> rest
    case False{}:
      rest

# every step-th case, from the first
def am.sc.thin(xs: List<&2, List<&2, List<&2, U32>>>, +step: Nat, +c: Nat) -> List<&2, List<&2, List<&2, U32>>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      am.sc.keep(Nat.is_eq(c, 0n), x, am.sc.thin(t, step, Bool.pick(Nat, Nat.is_eq(1n+c, step), 0n, 1n+c)))

def am.sc.test(+name: List<&2, U32>, +ret: List<&2, U32>, +i: Nat, +args: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +call = T.cat([S.b("("), am.sc.join(args, S.b(", ")), S.b(")")])
  T.cat([S.b("def "), name, S.b(".t"), T.mg.n(i), S.b("_() -> {"), name, call, S.b(" == "), name, S.b(".orig_"), call, S.b(" : "), ret, S.b("}:\n  {==}\n\n")])

def am.sc.tests(xss: List<&2, List<&2, List<&2, U32>>>, +name: List<&2, U32>, +ret: List<&2, U32>, +i: Nat) -> List<&2, U32>:
  match xss:
    case Nil{}:
      Nil{}
    case +a <> t:
      S.append(am.sc.test(name, ret, i, a), am.sc.tests(t, name, ret, 1n+i))

# the text appended to a file to test its definition against the original
# (`NAME.orig_`, its own calls renamed; then the cases), empty when none
def am.sc.plan.of(d: AmD, +d6: List<&2, U32>, +body: List<&2, U32>) -> List<&2, U32>:
  match d:
    case AmD{+name, +tys, +ret, +ok}:
      +vls = am.sc.valss(tys)
      +cs = am.sc.prod(vls)
      +step = Nat.add(Nat.div(List.length(&2, List<&2, List<&2, U32>>, cs), 16n), 1n)
      +bad = Bool.or(Bool.or(S.prefix(ret, S.b("IO(")), S.infix(ret, S.b("->"))), Bool.or(S.prefix(ret, S.b("{")), T.empty(ret)))
      +orig = T.cat([S.replace.first(d6, T.cat([S.b("def "), name, S.b("(")]), T.cat([S.b("def "), name, S.b(".orig_(")])), am.sc.ren(body, name)])
      Bool.pick(List<&2, U32>, Bool.and(Bool.and(ok, am.sc.all.some(vls)), Bool.not(bad)),
        T.cat([S.b("\n"), orig, S.b("\n"), am.sc.tests(am.sc.thin(cs, step, 0n), name, ret, 0n)]), Nil{})

def am.sc.plan(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +d6 = T.field(fs, 6n)
  am.sc.plan.of(am.sc.decl(d6), d6, T.field(fs, 7n))

# The verdicts ---------------------------------------------------------------

def am.sc.tested(+hers: AmO) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, AmO.solved(hers), S.b("right"), Bool.pick(List<&2, U32>, S.suffix(AmO.echo(hers), S.b("(exit 124)")), S.b("slow"), S.b("wrong")))

def am.sc.hers(sane: Bool, +t: AmT, +f: List<&2, U32>, +plan: List<&2, U32>, +work: String, +bend: String) -> IO(List<&2, U32>):
  match sane:
    case False{}:
      IO.pure(List<&2, U32>, S.b("untested"))
    case True{}:
      do IO<List<&2, U32>>:
        b : AmO <- am.check.in(t, S.append(f, plan), work, bend)
        return am.sc.tested(b)

def am.sc.run(has: Bool, +t: AmT, +f: List<&2, U32>, +orig: List<&2, U32>, +plan: List<&2, U32>, +work: String, +bend: String) -> IO(List<&2, U32>):
  match has:
    case False{}:
      IO.pure(List<&2, U32>, S.b("untested"))
    case True{}:
      do IO<List<&2, U32>>:
        a : AmO <- am.check.in(t, S.append(orig, plan), work, bend)
        am.sc.hers(AmO.solved(a), t, f, plan, work, bend)

def am.sc.judge.go(same: Bool, proof: Bool, +t: AmT, +f: List<&2, U32>, +orig: List<&2, U32>, +plan: List<&2, U32>, +work: String, +bend: String) -> IO(List<&2, U32>):
  match same proof:
    case True{} _:
      IO.pure(List<&2, U32>, S.b("same"))
    case False{} True{}:
      IO.pure(List<&2, U32>, S.b("proof"))
    case False{} False{}:
      am.sc.run(Bool.not(T.empty(plan)), t, f, orig, plan, work, bend)

def am.sc.judge(m: Maybe<&2, List<&2, U32>>, +ep: List<&2, U32>, +work: String, +bend: String) -> IO(List<&2, U32>):
  match m:
    case None{}:
      IO.pure(List<&2, U32>, S.b("untested"))
    case Some{+tx}:
      +t = am.task.of(tx)
      +fs = AmT.fs(t)
      +f = am.replay(am.calls(A.ag.blocks(10, A.ag.hds.bytes(), ep)), t, am.f0(t))
      +orig = T.mg.with(fs, T.field(fs, 7n))
      am.sc.judge.go(S.eq(S.chomp(f), S.chomp(orig)), am.sc.proof(fs), t, f, orig, am.sc.plan(fs), work, bend)

# an episode's verdict: its number, shape, verdict, unit
type AmV is Data:
  AmV{n: List<&2, U32>, shape: List<&2, U32>, v: List<&2, U32>, unit: List<&2, U32>}

# episode n's text in episodes.nul
def am.sc.ep(kvs: List<&2, Ev.EvKv>, +n: List<&2, U32>) -> List<&2, U32>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+k, +v} <> t:
      Bool.pick(List<&2, U32>, S.eq(k, n), v, am.sc.ep(t, n))

# a mugen.nul record (N, UNIT, SHAPE, SOLVED, CALLS, SECS) judged when solved
def am.sc.one(solved: Bool, +r: List<&2, List<&2, U32>>, +dir: String, +eps: List<&2, Ev.EvKv>, +work: String, +bend: String) -> IO(List<&2, AmV>):
  match solved:
    case False{}:
      IO.pure(List<&2, AmV>, Nil{})
    case True{}:
      +n = T.field(r, 0n)
      do IO<List<&2, AmV>>:
        m : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/task." ++ S.str(n) ++ ".nul")
        +v : List<&2, U32> <- am.sc.judge(m, am.sc.ep(eps, n), work, bend)
        Ck.log("agent-mugen-score: " ++ S.str(n) ++ " " ++ S.str(T.field(r, 2n)) ++ " " ++ S.str(v) ++ " " ++ S.str(T.field(r, 1n)))
        return [AmV{n, T.field(r, 2n), v, T.field(r, 1n)}]

def am.sc.each(rs: List<&2, Ev.EvKv>, +dir: String, +eps: List<&2, Ev.EvKv>, +work: String, +bend: String, +acc: List<&2, AmV>) -> IO(List<&2, AmV>):
  match rs:
    case Nil{}:
      IO.pure(List<&2, AmV>, List.reverse(&2, AmV, acc))
    case Ev.EvKv{k, +v} <> t:
      +r = S.split(v, 30)
      do IO<List<&2, AmV>>:
        x : List<&2, AmV> <- am.sc.one(S.eq(T.field(r, 3n), S.b("1")), r, dir, eps, work, bend)
        am.sc.each(t, dir, eps, work, bend, List.append(&2, AmV, x, acc))

# how many verdicts v (empty: any) in shape sh (empty: all)
def am.sc.n(xs: List<&2, AmV>, +sh: List<&2, U32>, +v: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case AmV{n, +s, +w, u} <> t:
      Nat.add(Bool.pick(Nat, Bool.and(Bool.or(T.empty(sh), S.eq(s, sh)), Bool.or(T.empty(v), S.eq(w, v))), 1n, 0n), am.sc.n(t, sh, v))

# how many tasks in shape sh (empty: all)
def am.sc.tasks(rs: List<&2, Ev.EvKv>, +sh: List<&2, U32>) -> Nat:
  match rs:
    case Nil{}:
      0n
    case Ev.EvKv{k, +v} <> t:
      Nat.add(Bool.pick(Nat, Bool.or(T.empty(sh), S.eq(T.field(S.split(v, 30), 2n), sh)), 1n, 0n), am.sc.tasks(t, sh))

def am.sc.c(+xs: List<&2, AmV>, +sh: List<&2, U32>, +v: String) -> String:
  Nat.show(am.sc.n(xs, sh, S.b(v)))

def am.sc.line(+xs: List<&2, AmV>, +rs: List<&2, Ev.EvKv>, +label: String, +sh: List<&2, U32>) -> String:
  +right = Nat.add(Nat.add(am.sc.n(xs, sh, S.b("same")), am.sc.n(xs, sh, S.b("proof"))), am.sc.n(xs, sh, S.b("right")))
  label ++ " right " ++ Nat.show(right) ++ "/" ++ Nat.show(am.sc.tasks(rs, sh)) ++ " (of " ++ Nat.show(am.sc.n(xs, sh, Nil{})) ++ " solved: same " ++ am.sc.c(xs, sh, "same") ++ ", proof " ++ am.sc.c(xs, sh, "proof")
    ++ ", tested right " ++ am.sc.c(xs, sh, "right") ++ ", wrong " ++ am.sc.c(xs, sh, "wrong") ++ ", slow " ++ am.sc.c(xs, sh, "slow") ++ ", untested " ++ am.sc.c(xs, sh, "untested") ++ ")\n"

def am.sc.tsv(xs: List<&2, AmV>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case AmV{+n, +s, +v, +u} <> t:
      T.cat([S.join([n, s, v, u], 9), [10], am.sc.tsv(t)])

def am.score(+dir: String) -> IO(Unit):
  do IO<Unit>:
    +bend : String <- S.env("BEND", "bend")
    +rs : List<&2, Ev.EvKv> <- Ev.ev.nul(dir ++ "/mugen.nul")
    +eps : List<&2, Ev.EvKv> <- Ev.ev.nul(dir ++ "/episodes.nul")
    +work : String <- S.mktemp()
    +xs : List<&2, AmV> <- am.sc.each(rs, dir, eps, work, bend, Nil{})
    S.rm(work)
    S.write(dir ++ "/score.tsv", am.sc.tsv(xs))
    +txt : String = am.sc.line(xs, rs, "direct", S.b("direct")) ++ am.sc.line(xs, rs, "fill", S.b("fill")) ++ am.sc.line(xs, rs, "repair", S.b("repair-0")) ++ am.sc.line(xs, rs, "all", Nil{})
    S.write(dir ++ "/score.txt", S.b(txt))
    IO.print(txt)

# xs: the arguments after `agent-mugen-score`
def am.score.cmd(xs: List<String>) -> IO(Unit):
  match xs:
    case +d <> Nil{}:
      am.score(d)
    case _:
      IO.die(Unit, 2, "usage: agent-mugen-score DIR")

# The episodes -------------------------------------------------------------------

def am.job(+dir: String, +env0: List<&2, String>, +dep: String, +threads: String, +tag: Nat, +bin: String, +fon: Bool, q: AmQ) -> C.CbJob:
  match q:
    case AmQ{+i, u, s, f}:
      +task = dir ++ "/task." ++ Nat.show(i) ++ ".nul"
      C.CbJob{i, List.append(&2, String, env0, {["AGENT_TOOL=" ++ dep ++ " corpus-v2 agent-mugen " ++ task, "AGENT_WORK=" ++ dir ++ "/work." ++ Nat.show(i),
        "AGENT_FIRST=" ++ Bool.pick(String, fon, S.str(f), ""),
        "CHECK_TAG=" ++ Nat.show(Nat.add(tag, i)), "AGENT_LOG=" ++ dir ++ "/ep." ++ Nat.show(i) ++ ".log",
        "AGENT_META=n=" ++ Nat.show(i) ++ "\nlang=bend\nunit=" ++ S.str(u) ++ "\n"] : List<&2, String>}), bin,
        {["+RTS", "--threads", threads, "-RTS", "--agent", "--prompt-file", dir ++ "/prompt." ++ Nat.show(i)] : List<&2, String>}}

def am.jobs(qs: List<&2, AmQ>, +dir: String, +env0: List<&2, String>, +dep: String, +threads: String, +tag: Nat, +bin: String, +fon: Bool) -> IO(List<&2, C.CbJob>):
  match qs:
    case Nil{}:
      IO.pure(List<&2, C.CbJob>, Nil{})
    case +q <> more:
      do IO<List<&2, C.CbJob>>:
        S.mkdir(dir ++ "/work." ++ Nat.show(AmQ.n(q)))
        js : List<&2, C.CbJob> <- am.jobs(more, dir, env0, dep, threads, tag, bin, fon)
        return am.job(dir, env0, dep, threads, tag, bin, fon, q) <> js

# an episode's outcome
type AmR is Data:
  AmR{shape: List<&2, U32>, solved: Bool, calls: Nat}

def am.ncalls(bs: List<&2, A.Blk>) -> Nat:
  match bs:
    case Nil{}:
      0n
    case A.Blk{+c, x} <> t:
      Nat.add(Bool.pick(Nat, A.ag.is.call(c), 1n, 0n), am.ncalls(t))

def am.one(+count: Nat, +dir: String, +q: AmQ, r: C.CbRes) -> IO(AmR):
  match q r:
    case AmQ{+i, +u, +sh, f} C.CbRes{j, o, +ms}:
      +ep = S.no.nul(S.Out.text(o))
      +secs = Ev.ev.secs(ms)
      +nc = am.ncalls(A.ag.blocks(10, A.ag.hds.bytes(), ep))
      do IO<AmR>:
        +ok : Bool <- S.exists(dir ++ "/work." ++ Nat.show(i) ++ "/SOLVED")
        S.add(dir ++ "/episodes.nul", L.v2.concat([Ev.ev.show(i), [0], ep, [0]]))
        S.add(dir ++ "/mugen.nul", L.v2.concat([u, S.b("/"), sh, [0], S.join([Ev.ev.show(i), u, sh, S.b(Bool.pick(String, ok, "1", "0")), Ev.ev.show(nc), S.b(secs)], 30), [0]]))
        Ck.log(Nat.show(count) ++ " " ++ S.str(sh) ++ " " ++ Bool.pick(String, ok, "solved", "unsolved") ++ ", " ++ Nat.show(nc) ++ " calls, " ++ secs ++ " s")
        return AmR{sh, ok, nc}

def am.loop(n: Nat, +done: Nat, +res: Chan(C.CbRes), +qs: List<&2, AmQ>, +dir: String, acc: List<&2, AmR>) -> IO(List<&2, AmR>):
  match n:
    case 0n:
      IO.pure(List<&2, AmR>, acc)
    case 1n+k:
      do IO<List<&2, AmR>>:
        +r : C.CbRes <- C.cb.pool.next(res)
        x : AmR <- am.one(1n+done, dir, am.q.nth(qs, C.cb.res.i(r)), r)
        am.loop(k, 1n+done, res, qs, dir, x <> acc)

def am.count(xs: List<&2, AmR>, +sh: List<&2, U32>, +all: Bool, +n: Nat, +m: Nat) -> Nat & Nat:
  match xs:
    case Nil{}:
      (n, m)
    case AmR{+s, +ok, c} <> more:
      +mine = Bool.or(all, S.eq(s, sh))
      am.count(more, sh, all, Nat.add(n, Bool.pick(Nat, Bool.and(mine, ok), 1n, 0n)), Nat.add(m, Bool.pick(Nat, mine, 1n, 0n)))

def am.frac(p: Nat & Nat) -> String:
  (a, b) = p
  Nat.show(a) ++ "/" ++ Nat.show(b)

def am.report(+xs: List<&2, AmR>, +stale: Nat) -> String:
  "direct solved " ++ am.frac(am.count(xs, S.b("direct"), False{}, 0n, 0n)) ++ "\nfill solved " ++ am.frac(am.count(xs, S.b("fill"), False{}, 0n, 0n))
    ++ "\nrepair solved " ++ am.frac(am.count(xs, S.b("repair-0"), False{}, 0n, 0n)) ++ "\nall solved " ++ am.frac(am.count(xs, Nil{}, True{}, 0n, 0n))
    ++ "\nstale tasks left out " ++ Nat.show(stale) ++ "\n"

def am.fin(+n: Nat, +qs: List<&2, AmQ>, +dir: String, +stale: Nat, x: Chan(C.CbRes) & C.CbPool) -> IO(Unit):
  (res, p) = x
  do IO<Unit>:
    +xs : List<&2, AmR> <- am.loop(n, 0n, res, qs, dir, Nil{})
    C.cb.pool.close(p)
    S.write(dir ++ "/report.txt", S.b(am.report(xs, stale)))
    IO.print(am.report(xs, stale))
    Ck.log("agent-mugen-eval: " ++ Nat.show(n) ++ " episodes in " ++ dir ++ "; the stricter score next")
    am.score(dir)

def am.episodes(self: Bool, +ckpt: String, +dir: String, +qs: List<&2, AmQ>, +stale: Nat) -> IO(Unit):
  match self:
    case True{}:
      do IO<Unit>:
        +txt : String = "selftest: " ++ Nat.show(List.length(&2, AmQ, qs)) ++ " tasks pass their reference session; stale tasks left out " ++ Nat.show(stale) ++ "\n"
        S.write(dir ++ "/report.txt", S.b(txt))
        IO.print(txt)
    case False{}:
      do IO<Unit>:
        +temp : String <- S.env("TEMPERATURE", "0")
        +tokens : String <- S.env("TOKENS", "512")
        +calls : String <- S.env("AGENT_CALLS", "8")
        +threads : String <- S.env("THREADS", "5")
        +procs : Nat <- S.env.nat("PROCS", 3n)
        +tag : Nat <- S.env.nat("AGENT_TAG", 300000n)
        +dep : String <- S.env("AGENT_DEPLOY", "nix run .#deploy --")
        +bend : String <- S.env("BEND", "bend")
        +bin : String <- S.env("AGENT_BIN", "run/gcroot-bend-generate-agent/bin/bend-generate")
        +first : String <- S.env("AM_FIRST", "1")
        +rep : String <- S.env("AM_REPEAT", "128")
        +report : String <- S.env("AM_REPORT", "1")
        +env0 : List<&2, String> = {["CKPT=" ++ ckpt, "TOKENS=" ++ tokens, "AGENT_CALLS=" ++ calls, "TEMPERATURE=" ++ temp, "TOKENIZER_FILE=weights/code32k.bpe",
          "BEND=" ++ bend, "BEND_NO_TELEMETRY=1", "AGENT_REPEAT=" ++ rep, "AGENT_REPORT=" ++ report] : List<&2, String>}
        Ck.log("agent-mugen-eval: " ++ Nat.show(List.length(&2, AmQ, qs)) ++ " episodes, " ++ Nat.show(procs) ++ " at a time, " ++ calls ++ " calls, " ++ tokens ++ " tokens a stretch, temperature " ++ temp
          ++ "; first call made for her " ++ first ++ ", repetition cut " ++ rep ++ ", report check " ++ report)
        S.add(dir ++ "/episodes.nul", Nil{})
        S.add(dir ++ "/mugen.nul", Nil{})
        +js : List<&2, C.CbJob> <- am.jobs(List.reverse(&2, AmQ, qs), dir, env0, dep, threads, tag, bin, String.eq(first, "1"))
        p : C.CbPool <- C.cb.pool.open(procs, js)
        am.fin(List.length(&2, C.CbJob, js), qs, dir, stale, C.cb.pool.res(p))

def am.eval.go(+ckpt: String, +dir: String, p: AmP) -> IO(Unit):
  match p:
    case AmP{n, qs, st}:
      am.episodes(String.eq(ckpt, "selftest"), ckpt, dir, qs, st)

def am.eval.run(+ckpt: String, +dir: String, +k: Nat) -> IO(Unit):
  do IO<Unit>:
    +rp : String <- S.env("AGENT_RESULTS", "run/v2/results/bend.holdout.nul")
    +given : String <- S.env("AGENT_SRC", "")
    +bend : String <- S.env("BEND", "bend")
    kvs0 : List<&2, Ev.EvKv> <- Ev.ev.nul(rp)
    +kvs : List<&2, Ev.EvKv> = am.bend.only(kvs0)
    +kvk : List<&2, Ev.EvKv> = Bool.pick(List<&2, Ev.EvKv>, Nat.is_eq(k, 0n), kvs, List.take(&2, Ev.EvKv, kvs, k))
    +roots : List<&2, String> <- Ev.ev.roots()
    +home : String <- S.env("HOME", "")
    S.mkdir(dir)
    Ck.log("agent-mugen-eval: " ++ Nat.show(List.length(&2, Ev.EvKv, kvk)) ++ " units of " ++ rp ++ ", their reference sessions first")
    p : AmP <- am.prep(kvk, dir, given, roots, C.cb.path(home, "src"), bend, AmP{0n, Nil{}, 0n})
    am.eval.go(ckpt, dir, p)

# xs: the arguments after `agent-mugen-eval`
def am.eval(xs: List<String>) -> IO(Unit):
  match xs:
    case c <> d <> Nil{}:
      am.eval.run(c, d, 0n)
    case c <> d <> +k <> Nil{}:
      am.eval.run(c, d, C.cb.nat(S.b(k)))
    case _:
      IO.die(Unit, 2, "usage: agent-mugen-eval CKPT|selftest DIR [K]")
