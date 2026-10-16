import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ../Sha256.bend as H
import ./Lib.bend as L
import ./Steps.bend as St
import ./Holdout.bend as Ho
import ./Raw.bend as R

# collect: new Bend code for the corpus, driven by a config file (2026-10-14,
# the user: "all logic in bend"), the Bend path of tools/corpus-v2/raw-new3.sh
# made generic: the next addition is a new config, not a new script.
#
#   bend-corpus-v2 collect CFG STEP...     STEP: fetch list gate-bend nul keys pre gate split check, or all
#
# Run from the repository root.  Every path below is the config's (relative
# to the cwd); the work is in OUT/stage, the outputs in OUT.
#
# The config (tracked text, one directive a line, a word starting with `#`
# starts a comment; words are separated by spaces):
#
#   out DIR                   the outputs (DIR/stage: every step's work)
#   src DIR                   the clones, one directory a repository (OWNER__NAME), the
#                             sibling links and the upstream's changed files
#   lang bend                 the language (only Bend)
#   pins FILE                 `repository TAB commit TAB commit date TAB licence` a line: a
#                             repository with a row is cloned at that commit (the last row
#                             naming it); fetch appends a row for every other one (its HEAD,
#                             the licence from `gh api repos/R`, recorded, never a filter)
#   known FILE...             earlier collections' PINS files: a `growth` repository whose
#                             commit is still the known one has nothing new
#   bend2 DIR                 a checkout of bendlang/bend (remote origin): the upstream's
#                             changes and Base's head (notbase)
#   upstream OWNER/NAME BASE  the upstream's .bend files added or changed from BASE to its pin
#                             (`git diff --diff-filter=AM`; the pin: PINS's row, else
#                             origin/main after `git fetch origin`), as SRC/OWNER__NAME
#   repo OWNER/NAME RULE [exclude PREFIX...]
#                             a new repository; RULE all, lt100k (files under 100 KB) or
#                             novendor (not vendor/); a path under an excluded prefix is out
#   growth OWNER/NAME RULE [exclude PREFIX...]
#                             a repository an earlier collection took: only paths the corpus
#                             never had (pre's path rule), routed by its earlier assignment
#                             (vault-known: the vault; else the C3 rule on its units with its
#                             directory split frozen by big-known), never a vault candidate
#   hub URL RULE [exclude PREFIX...]
#                             BendHub's packages (2026-10-16; URL https://hub.bend-lang.com):
#                             the newest version of every name and every unnamed package, each
#                             a new repository SRC/hub__NAME (SRC/hub__0xHASH), RULE and the
#                             excluded prefixes as a repository's; PINS gets a row a package
#                             (`hub/NAME TAB 0xHASH TAB publish date TAB licence TAB
#                             NAME@VERSION`, the licence recorded, never a filter) and a pinned
#                             one is taken at its pin; the section "The hub" says how
#   sibling OWNER/NAME LINK   SRC/LINK -> OWNER__NAME, for the loader's `../Link/x.bend` imports
#   loader PATH               the Bend 2 loader the gate runs (`bend` on PATH)
#   loader-secs N             its limit a file (60)
#   verdicts FILE [CLASS...]  an earlier bend.check.tsv: its rows of those classes (all when
#                             none) are the verdict for the same file, the loader is not run
#                             (a replay over the same clones names its run's timeouts: a
#                             timeout says how loaded the machine was, not what the file is)
#   procs N                   processes at once: loader runs, key pieces, the raw gate (4)
#   order find|bytes          a repository's files in `find`'s order (the filesystem's, as
#                             run 3) or sorted bytewise (the default: the same on any machine)
#   big N                     a file over N bytes is out (1000000)
#   vault quarter|none        a quarter of the eligible new repositories (>= vault-min files
#                             past the corpus's paths and keys, no stream holds the name, not
#                             the upstream, not growth) go to the vault, first by sha256(name)
#   vault-min N               (3)
#   vault-known FILE...       repository names (one a line) already in the vault
#   big-known FILE...         repository names an earlier collection split by directory
#   corpus FILE...            what the new files must not repeat (JSONL or NUL id/text files):
#                             their (repository, path) pairs and content keys (L.v2.key)
#   streams FILE              stream-index.json: the names a training stream holds
#   keycache DIR              the corpus files' keys, kept by each file's size and mtime
#                             (OUT/stage/keys/cache)
#   raw-cap NAME=CPS...       RAW_CAP_REPOS for the gate (none)
#
# The steps (`all`: in this order; each reads what the one before wrote):
#
#   fetch      clones (shallow, blobless, sparse `*.bend`) at their pins, PINS rows for the
#              new ones, the sibling links, the upstream's files, the hub's packages
#              (SRC/HUB.tsv)
#   list       each repository's .bend files (`find`, .git pruned), less vendored directories,
#              `*_generated*`, files over `big` (lt100k: 100 KB or more) and excluded
#              prefixes: stage/list.tsv (`file TAB id`, id repo:OWNER__NAME/PATH, the
#              repositories in the config's order, the upstream, then the hub's packages in
#              HUB.tsv's order) and stage/list.counts
#   gate-bend  copies of Base (a base.bend whose first 4 lines are the upstream's
#              bend2/base.bend's, the upstream's own excepted) out; then the loader,
#              `cd DIR && timeout SECS LOADER FILE --check-only`, procs at once: exit 0 pass,
#              124 timeout, a `^Location: [^ ]`, `rel(y|ies) on unsafe or foreign code` or
#              `TODOs? found` line checked (a def's own error), else load (parse, import, name
#              clash, bare operator), which drops the file: stage/bend.check.tsv (`file TAB
#              class TAB the first ^(Error: .|- (message|expected|observed) ) line's first
#              160 bytes`, sorted by file), stage/bend.ok.tsv, stage/bend.counts (list.counts,
#              the copies of Base, the classes)
#   nul        files with a NUL byte, and files `iconv -f UTF-8 -t UTF-8` refuses, out; the
#              rest as JSON lines (nul-jsonl's): stage/in/bend.jsonl, stage/in/bend.counts
#   keys       the corpus files' keys (`keys`, cached), their (repository, path) pairs,
#              content keys and ids sorted (stage/keys/corpus.{paths,sha,ids}); the new
#              records' keys (stage/keys/bend.keys, a line a record)
#   pre        C3 on the new records: a repository with more than 300 distinct paths (the
#              corpus's and the new ones) is split by directory (growth: as big-known says),
#              2% of the units held out (Ho.ho.held); the vault; each record routed: a path
#              the corpus has, a content key it has, held out (to holdout), vault (to vault),
#              a key a held-out or vault record has, else train: stage/cand/{train,holdout,
#              vault}/bend.jsonl, stage/pre.counts, stage/pre/{big.repos,units,held.units,
#              bend.repos,vault.cands,vault.repos}
#   gate       `bend-corpus-v2 raw` on each candidate file (the holdout lists, filler, copies,
#              long lines, generated markers): stage/gate/{train,holdout,vault}
#   split      OUT/bend.jsonl, OUT/vault/bend.jsonl, OUT/holdout/bend.jsonl,
#              OUT/holdout/units.txt, OUT/vault/repos.txt, OUT/summary.txt
#   check      no id twice among the outputs or with the corpus, no output path or key the
#              corpus has, no train key a held-out or vault file has
#
# Against raw-new3.sh (whose Bend outputs the run-3 replay config reproduces): the
# routing, the vault and the bigness see only the Bend records (raw-new3 also counted
# its Lean and Agda sources' paths; no Bend repository shared a name with them); the
# counts files' reasons come in one fixed order (awk's hash order before); a repository
# is cloned at HEAD when no row pins it (unchanged).
#
# A Bend process evaluates on one thread, so the heavy work is processes: the loader,
# iconv, `keys` on pieces of the corpus (`split -n l/K/N`), the projections of their keys
# (`collect --project KEYS BASE`, internal), sort/comm/join on the big sets, the raw gate.
#
# Every def is prefixed `col.`.

# Basics ---------------------------------------------------------------------------

def col.fuel() -> Nat:
  U32.to_nat(4294967295)

def col.log(+msg: String) -> IO(Unit):
  Ck.log("collect: " ++ msg)

def col.l1(xs: List<&2, String>) -> List<String>:
  Ho.ho.l1(xs)

# bytes as a set key, one char a byte
def col.k(+xs: List<&2, U32>) -> String:
  St.st.key(xs)

def col.in(+s: Set(), +xs: List<&2, U32>) -> Bool:
  L.v2.in(s, col.k(xs))

def col.set.go(xss: List<&2, List<&2, U32>>, s: Set()) -> Set():
  match xss:
    case Nil{}:
      s
    case +x <> more:
      col.set.go(more, Set.add(s, col.k(x)))

def col.set(xss: List<&2, List<&2, U32>>) -> Set():
  col.set.go(xss, Set.new())

def col.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  S.split.lines(xs)

def col.unlines.go(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xss:
    case Nil{}:
      Nil{}
    case x <> more:
      List.append(&2, U32, x, 10 <> col.unlines.go(more))

# lines, each with its newline
def col.unlines(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  col.unlines.go(xss)

def col.nonempty(xss: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.filter(~List<&2, U32>, ~(x => Bool.not(Nat.is_eq(S.len(x), 0n))), xss)

def col.nat(+xs: List<&2, U32>) -> Nat:
  S.env.nat.got(Nat.read(S.str(S.chomp(xs))), 0n)

def col.b2n(b: Bool) -> Nat:
  match b:
    case True{}:
      1n
    case False{}:
      0n

def col.le(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  R.rw.le(a, b)

def col.sort(xss: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.sort(~List<&2, U32>, ~col.le, xss)

def col.uniq.keep(same: Bool, x: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match same:
    case True{}:
      rest
    case False{}:
      x <> rest

# a sorted list without its repeats (adjacent equal lines)
def col.uniq.go(xss: List<&2, List<&2, U32>>, +prev: List<&2, U32>, first: Bool) -> List<&2, List<&2, U32>>:
  match xss first:
    case Nil{} _:
      Nil{}
    case +x <> more True{}:
      x <> col.uniq.go(more, x, False{})
    case +x <> more False{}:
      col.uniq.keep(S.eq(x, prev), x, col.uniq.go(more, x, False{}))

def col.uniq(xss: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  col.uniq.go(col.sort(xss), Nil{}, True{})

# Python-free number formatting: n in w columns, right-aligned
def col.right(+s: String, +w: Nat) -> String:
  R.rw.spaces(Nat.sub(w, String.length(s))) ++ s

def col.left(+s: String, +w: Nat) -> String:
  s ++ R.rw.spaces(Nat.sub(w, String.length(s)))

# bytes as MB with one decimal (half up)
def col.mb(+b: Nat) -> String:
  +t = Nat.div(Nat.add(b, 50000n), 100000n)
  Nat.show(Nat.div(t, 10n)) ++ "." ++ Nat.show(Nat.mod(t, 10n))

# Processes -------------------------------------------------------------------------

# a command that must succeed: its output
def col.must(+what: String, prog: String, args: List<&2, String>) -> IO(List<&2, U32>):
  S.must(what, prog, col.l1(args))

def col.git(+dir: String, +args: List<&2, String>) -> IO(List<&2, U32>):
  col.must("git -C " ++ dir ++ " " ++ String.join(args, " "), "git", "-C" <> dir <> args)

# the standard output into a file: `cd DIR && timeout SECS env K=V.. PROG
# ARGS.. > OUT` (OUT relative to DIR), the errors answered (S.run.to, which
# this module's own shell line became on 2026-10-15)
def col.run.in(+dir: String, env: List<&2, String>, +secs: U32, prog: String, args: List<&2, String>, +outp: String) -> IO(S.Out):
  S.run.to(dir, col.l1(env), secs, prog, col.l1(args), outp)

# prog's standard output into the file outp (from the cwd)
def col.run.to(+secs: U32, prog: String, args: List<&2, String>, outp: String) -> IO(S.Out):
  col.run.in(".", Nil{}, secs, prog, args, outp)

def col.ok.if(ok: Bool, +what: String, +o: S.Out) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "collect: " ++ what ++ " failed (exit " ++ U32.show(S.Out.status(o)) ++ "): " ++ S.str(S.lines.take(S.Out.text(o), 20n)))

def col.to(+what: String, prog: String, args: List<&2, String>, outp: String) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- col.run.to(86400, prog, args, outp)
    col.ok.if(U32.is_eq(S.Out.status(o), 0), what, o)

# `LC_ALL=C sort ARGS -o OUT INS...` (byte order)
def col.sortf(+tmp: String, +flags: List<&2, String>, +outp: String, ins: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 86400, "sort", col.l1(List.append(&2, String, flags, List.append(&2, String, ["-S", "1G", "-T", tmp, "-o", outp], ins))), Nil{})
    col.ok.if(U32.is_eq(S.Out.status(o), 0), "sort into " ++ outp, o)

# `LC_ALL=C prog args > outp` (comm, join)
def col.c.to(+what: String, prog: String, args: List<&2, String>, outp: String) -> IO(Unit):
  col.to(what, "env", List.append(&2, String, ["LC_ALL=C", prog], args), outp)

def col.cp(+a: String, +b: String) -> IO(Unit):
  do IO<Unit>:
    +o : List<&2, U32> <- col.must("cp " ++ a, "cp", ["-f", a, b])
    return Unit{}

# a file's lines (`wc -l`)
def col.wc(+f: String) -> IO(Nat):
  do IO<Nat>:
    +o : List<&2, U32> <- col.must("wc -l " ++ f, "wc", ["-l", f])
    return col.nat(L.v2.before(o, 32))

def col.self.of(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      "bend-corpus-v2"
    case x <> more:
      x

def col.self() -> IO(String):
  do IO<String>:
    argv : List<String> <- IO.args()
    return col.self.of(argv)

# The pool: PROCS threads, each running a job's commands one after another -----------
#
# A command runs in its directory with its environment and limit; its output is
# answered (out "", errors merged) or its standard output written to the file out
# (its errors answered).  A job's result keeps its status and, by mode, nothing (0)
# or the loader's verdict (1).

type ColCmd is Data:
  ColCmd{dir: String, env: List<&2, String>, secs: U32, prog: String, args: List<&2, String>, out: String}

type ColJob is Data:
  ColJob{n: Nat, mode: Nat, cmds: List<&2, ColCmd>}

type ColRes is Data:
  ColRes{n: Nat, status: U32, text: List<&2, U32>}

def col.res.n(+r: ColRes) -> Nat:
  match r:
    case ColRes{n, s, t}:
      n

def col.res.status(+r: ColRes) -> U32:
  match r:
    case ColRes{n, s, t}:
      s

def col.res.text(+r: ColRes) -> List<&2, U32>:
  match r:
    case ColRes{n, s, t}:
      t

def col.res.le(a: ColRes, b: ColRes) -> Bool:
  match a b:
    case ColRes{+x, s, t} ColRes{+y, u, v}:
      Nat.is_le(x, y)

def col.cmd.go(cap: Bool, dir: String, env: List<&2, String>, +secs: U32, prog: String, args: List<&2, String>, out: String) -> IO(S.Out):
  match cap:
    case True{}:
      S.run(dir, col.l1(env), secs, prog, col.l1(args), Nil{})
    case False{}:
      col.run.in(dir, env, secs, prog, args, out)

def col.cmd.run(c: ColCmd) -> IO(S.Out):
  match c:
    case ColCmd{dir, env, secs, prog, args, +out}:
      col.cmd.go(String.is_empty(out), dir, env, secs, prog, args, out)

# the commands in order until one fails: the last one's output
def col.cmds.go(cs: List<&2, ColCmd>, ok: Bool, +last: S.Out) -> IO(S.Out):
  match cs ok:
    case c <> more True{}:
      do IO<S.Out>:
        +o : S.Out <- col.cmd.run(c)
        col.cmds.go(more, U32.is_eq(S.Out.status(o), 0), o)
    case _ _:
      IO.pure(S.Out, last)

# The loader's verdict ---------------------------------------------------------------

# `^Location: [^ ]`
def col.loc(+l: List<&2, U32>) -> Bool:
  Bool.and(S.prefix(l, S.b("Location: ")), Bool.and(Nat.is_lt(10n, S.len(l)), Bool.not(U32.is_eq(L.v2.byte.at(l, 10n), 32))))

def col.checked.line(+l: List<&2, U32>) -> Bool:
  Bool.or(col.loc(l), Bool.or(Bool.or(S.infix(l, S.b("rely on unsafe or foreign code")), S.infix(l, S.b("relies on unsafe or foreign code"))),
    Bool.or(S.infix(l, S.b("TODO found")), S.infix(l, S.b("TODOs found")))))

def col.checked(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      Bool.or(col.checked.line(l), col.checked(more))

# `^(Error: .|- (message|expected|observed) )`
def col.msg.line(+l: List<&2, U32>) -> Bool:
  Bool.or(Bool.and(S.prefix(l, S.b("Error: ")), Nat.is_lt(7n, S.len(l))),
    Bool.or(S.prefix(l, S.b("- message ")), Bool.or(S.prefix(l, S.b("- expected ")), S.prefix(l, S.b("- observed ")))))

def col.msg.at(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      col.msg.line(l)

def col.msg.go(ls: List<&2, List<&2, U32>>, hit: Bool) -> List<&2, U32>:
  match ls hit:
    case Nil{} _:
      Nil{}
    case l <> more True{}:
      l
    case l <> +more False{}:
      col.msg.go(more, col.msg.at(more))

def col.msg(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  col.msg.go(ls, col.msg.at(ls))

def col.class(+st: U32, +ls: List<&2, List<&2, U32>>) -> String:
  Bool.pick(String, U32.is_eq(st, 0), "pass", Bool.pick(String, U32.is_eq(st, 124), "timeout", Bool.pick(String, col.checked(ls), "checked", "load")))

# `class TAB message`
def col.verdict(+st: U32, +text: List<&2, U32>) -> List<&2, U32>:
  +ls = S.split.lines(text)
  S.append(S.b(col.class(st, ls)), 9 <> List.take(&2, U32, col.msg(ls), 160n))

def col.post(mode: Nat, +st: U32, +text: List<&2, U32>) -> List<&2, U32>:
  match mode:
    case 1n:
      col.verdict(st, text)
    case _:
      Nil{}

def col.wk.got(+res: Chan(ColRes), m: Maybe<&1, ColJob>) -> IO(Bool):
  match m:
    case None{}:
      IO.pure(Bool, False{})
    case Some{ColJob{n, mode, cs}}:
      do IO<Bool>:
        +o : S.Out <- col.cmds.go(cs, True{}, S.Out{0, Nil{}})
        ok : Result<&1, &1, ColRes, Unit> <- Chan.send(ColRes, res, ColRes{n, S.Out.status(o), col.post(mode, S.Out.status(o), S.Out.text(o))})
        return True{}

def col.wk(fuel: Nat, +jobs: Chan(ColJob), +res: Chan(ColRes), go: Bool) -> IO(Unit):
  match fuel go:
    case 1n+f True{}:
      do IO<Unit>:
        m : Maybe<&1, ColJob> <- Chan.recv(ColJob, jobs)
        g : Bool <- col.wk.got(res, m)
        col.wk(f, jobs, res, g)
    case _ _:
      IO.pure(Unit, Unit{})

def col.fork(n: Nat, +jobs: Chan(ColJob), +res: Chan(ColRes)) -> IO(List<Chan(Unit)>):
  match n:
    case 0n:
      IO.pure(List<Chan(Unit)>, Nil{})
    case 1n+m:
      do IO<List<Chan(Unit)>>:
        ch : Chan(Unit) <- IO.fork(Unit, col.wk(col.fuel(), jobs, res, True{}))
        rest : List<Chan(Unit)> <- col.fork(m, jobs, res)
        return ch <> rest

def col.send(+jobs: Chan(ColJob), js: List<&2, ColJob>) -> IO(Unit):
  match js:
    case Nil{}:
      Chan.close(ColJob, jobs)
    case j <> more:
      do IO<Unit>:
        ok : Result<&1, &1, ColJob, Unit> <- Chan.send(ColJob, jobs, j)
        col.send(jobs, more)

def col.join(chs: List<Chan(Unit)>) -> IO(Unit):
  match chs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +ch <> more:
      do IO<Unit>:
        u : Unit <- IO.join(Unit, ch)
        col.join(more)

def col.got(m: Maybe<&1, ColRes>) -> IO(ColRes):
  match m:
    case Some{r}:
      IO.pure(ColRes, r)
    case None{}:
      IO.die(ColRes, 1, "collect: the results channel closed early")

def col.tick(every: Bool, +what: String, +done: Nat, +total: Nat) -> IO(Unit):
  match every:
    case True{}:
      col.log(what ++ ": " ++ Nat.show(done) ++ " of " ++ Nat.show(total))
    case False{}:
      IO.pure(Unit, Unit{})

def col.collect(k: Nat, +what: String, +total: Nat, +res: Chan(ColRes), acc: List<&2, ColRes>) -> IO(List<&2, ColRes>):
  match k:
    case 0n:
      IO.pure(List<&2, ColRes>, acc)
    case 1n+(+j):
      do IO<List<&2, ColRes>>:
        m : Maybe<&1, ColRes> <- Chan.recv(ColRes, res)
        r : ColRes <- col.got(m)
        +done : Nat = Nat.sub(total, j)
        col.tick(Bool.and(Nat.is_eq(Nat.mod(done, 250n), 0n), Nat.is_lt(done, total)), what, done, total)
        col.collect(j, what, total, res, r <> acc)

# the jobs, PROCS at a time; the results in the jobs' order
def col.pool(+what: String, +procs: Nat, +js: List<&2, ColJob>) -> IO(List<&2, ColRes>):
  +n = List.length(&2, ColJob, js)
  do IO<List<&2, ColRes>>:
    +jobs : Chan(ColJob) <- Chan.new(ColJob, U32.from_nat(1n+n))
    +res : Chan(ColRes) <- Chan.new(ColRes, U32.from_nat(1n+n))
    col.send(jobs, js)
    ws : List<Chan(Unit)> <- col.fork(Nat.max(procs, 1n), jobs, res)
    +rs : List<&2, ColRes> <- col.collect(n, what, n, res, Nil{})
    col.join(ws)
    return List.sort(~ColRes, ~col.res.le, rs)

def col.bad(rs: List<&2, ColRes>) -> Nat:
  match rs:
    case Nil{}:
      0n
    case +r <> more:
      Nat.add(col.b2n(Bool.not(U32.is_eq(col.res.status(r), 0))), col.bad(more))

def col.pool.ok(+what: String, +procs: Nat, js: List<&2, ColJob>) -> IO(Unit):
  do IO<Unit>:
    +rs : List<&2, ColRes> <- col.pool(what, procs, js)
    +b : Nat = col.bad(rs)
    col.ok.if(Nat.is_eq(b, 0n), what ++ " (" ++ Nat.show(b) ++ " jobs)", S.Out{1, Nil{}})

# The config -------------------------------------------------------------------------

def ColCfg() -> Data:
  List<&2, List<&2, List<&2, U32>>>

def col.cf.word(hash: Bool, w: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match hash:
    case True{}:
      Nil{}
    case False{}:
      w <> rest

# a line's words up to the one that starts a comment
def col.cf.words(ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> more:
      col.cf.word(S.head.is(w, 35), w, col.cf.words(more))

def col.cf.line(ws: List<&2, List<&2, U32>>, rest: ColCfg()) -> ColCfg():
  match ws:
    case Nil{}:
      rest
    case w <> t:
      (w <> t) <> rest

def col.cf.lines(ls: List<&2, List<&2, U32>>) -> ColCfg():
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      col.cf.line(col.cf.words(St.st.words(l)), col.cf.lines(more))

def col.cf.put(ws: List<&2, List<&2, U32>>, +d: List<&2, U32>, +rest: ColCfg()) -> ColCfg():
  match ws:
    case Nil{}:
      rest
    case +w <> t:
      Bool.pick(ColCfg(), S.eq(w, d), t <> rest, rest)

# the words after directive d, a list a line that opens with it
def col.cf.args(cs: ColCfg(), +d: List<&2, U32>) -> ColCfg():
  match cs:
    case Nil{}:
      Nil{}
    case ws <> more:
      col.cf.put(ws, d, col.cf.args(more, d))

def col.cf.head(ws: List<&2, List<&2, U32>>, dflt: List<&2, U32>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      dflt
    case w <> t:
      w

def col.cf.first(xss: ColCfg(), dflt: List<&2, U32>) -> List<&2, U32>:
  match xss:
    case Nil{}:
      dflt
    case ws <> more:
      col.cf.head(ws, dflt)

# the first word after d (its first line), or dflt
def col.cf.one(+cs: ColCfg(), +d: String, dflt: String) -> List<&2, U32>:
  col.cf.first(col.cf.args(cs, S.b(d)), S.b(dflt))

def col.cf.str(+cs: ColCfg(), +d: String, dflt: String) -> String:
  S.str(col.cf.one(cs, d, dflt))

def col.cf.nat(+cs: ColCfg(), +d: String, +dflt: Nat) -> Nat:
  S.env.nat.got(Nat.read(col.cf.str(cs, d, Nat.show(dflt))), dflt)

def col.cf.concat(xss: ColCfg()) -> List<&2, List<&2, U32>>:
  match xss:
    case Nil{}:
      Nil{}
    case ws <> more:
      List.append(&2, List<&2, U32>, ws, col.cf.concat(more))

# every word on every line d opens
def col.cf.all(+cs: ColCfg(), +d: String) -> List<&2, List<&2, U32>>:
  col.cf.concat(col.cf.args(cs, S.b(d)))

def col.strs(xss: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xss:
    case Nil{}:
      Nil{}
    case x <> more:
      S.str(x) <> col.strs(more)

def col.cf.files(+cs: ColCfg(), +d: String) -> List<&2, String>:
  col.strs(col.cf.all(cs, d))

# The repositories --------------------------------------------------------------------
#
# kind: 0 a new repository, 1 growth, 2 the upstream; rule: 0 all, 1 lt100k,
# 2 novendor, 9 not a rule

type ColRepo is Data:
  ColRepo{name: List<&2, U32>, dir: List<&2, U32>, rule: Nat, excl: List<&2, List<&2, U32>>, kind: Nat}

def col.r.name(+r: ColRepo) -> List<&2, U32>:
  match r:
    case ColRepo{n, d, u, e, k}:
      n

def col.r.dir(+r: ColRepo) -> List<&2, U32>:
  match r:
    case ColRepo{n, d, u, e, k}:
      d

def col.r.rule(+r: ColRepo) -> Nat:
  match r:
    case ColRepo{n, d, u, e, k}:
      u

def col.r.excl(+r: ColRepo) -> List<&2, List<&2, U32>>:
  match r:
    case ColRepo{n, d, u, e, k}:
      e

def col.r.kind(+r: ColRepo) -> Nat:
  match r:
    case ColRepo{n, d, u, e, k}:
      k

# OWNER/NAME as a directory, OWNER__NAME
def col.dir.of(+name: List<&2, U32>) -> List<&2, U32>:
  S.replace.first(name, [47], [95, 95])

# the folded name the corpus knows the repository by (L.v2.repo.of)
def col.r.fold(+r: ColRepo) -> List<&2, U32>:
  L.v2.repo.of(L.v2.concat([S.b("repo:"), col.r.dir(r), [47]]))

def col.rule(+w: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.eq(w, S.b("all")), 0n, Bool.pick(Nat, S.eq(w, S.b("lt100k")), 1n, Bool.pick(Nat, S.eq(w, S.b("novendor")), 2n, 9n)))

def col.excl(ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.filter(~List<&2, U32>, ~(w => Bool.not(S.eq(w, S.b("exclude")))), ws)

def col.repo.of(+kind: Nat, ws: List<&2, List<&2, U32>>) -> ColRepo:
  match ws:
    case +r <> rl <> rest:
      ColRepo{r, col.dir.of(r), col.rule(rl), col.excl(rest), kind}
    case +r <> Nil{}:
      ColRepo{r, col.dir.of(r), 9n, Nil{}, kind}
    case Nil{}:
      ColRepo{Nil{}, Nil{}, 9n, Nil{}, kind}

def col.kind.of(+w: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.eq(w, S.b("repo")), 0n, Bool.pick(Nat, S.eq(w, S.b("growth")), 1n, 3n))

def col.repos.kind(k: Nat, t: List<&2, List<&2, U32>>, rest: List<&2, ColRepo>) -> List<&2, ColRepo>:
  match k:
    case 0n:
      col.repo.of(0n, t) <> rest
    case 1n:
      col.repo.of(1n, t) <> rest
    case _:
      rest

def col.repos.put(ws: List<&2, List<&2, U32>>, rest: List<&2, ColRepo>) -> List<&2, ColRepo>:
  match ws:
    case Nil{}:
      rest
    case +w <> t:
      col.repos.kind(col.kind.of(w), t, rest)

def col.repos.go(cs: ColCfg()) -> List<&2, ColRepo>:
  match cs:
    case Nil{}:
      Nil{}
    case ws <> more:
      col.repos.put(ws, col.repos.go(more))

def col.up.line(ws: List<&2, List<&2, U32>>) -> List<&2, ColRepo>:
  match ws:
    case +r <> rest:
      [ColRepo{r, col.dir.of(r), 0n, Nil{}, 2n}]
    case Nil{}:
      Nil{}

def col.up.of(xss: ColCfg()) -> List<&2, ColRepo>:
  match xss:
    case Nil{}:
      Nil{}
    case ws <> more:
      col.up.line(ws)

def col.up.base.of(ws: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ws:
    case r <> b <> rest:
      b
    case _:
      Nil{}

def col.up.base(xss: ColCfg()) -> List<&2, U32>:
  match xss:
    case Nil{}:
      Nil{}
    case ws <> more:
      col.up.base.of(ws)

# the upstream (none: an empty list)
def col.up(+cs: ColCfg()) -> List<&2, ColRepo>:
  col.up.of(col.cf.args(cs, S.b("upstream")))

# the repositories in the config's order, the upstream last
def col.repos(+cs: ColCfg()) -> List<&2, ColRepo>:
  List.append(&2, ColRepo, col.repos.go(cs), col.up(cs))

def col.bad.rules(rs: List<&2, ColRepo>) -> List<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(col.r.rule(r), 9n), [col.r.name(r)], Nil{}), col.bad.rules(more))

# PINS -------------------------------------------------------------------------------

def col.pin.row(fs: List<&2, List<&2, U32>>, +r: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match fs:
    case +a <> c <> rest:
      Bool.pick(List<&2, U32>, S.eq(a, r), c, acc)
    case _:
      acc

# a repository's commit in PINS lines: the last row naming it (Nil: none)
def col.pin.go(ls: List<&2, List<&2, U32>>, +r: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      acc
    case +l <> more:
      col.pin.go(more, r, col.pin.row(S.split(l, 9), r, acc))

def col.pin(+ls: List<&2, List<&2, U32>>, +r: List<&2, U32>) -> List<&2, U32>:
  col.pin.go(ls, r, Nil{})

def col.read.lines(+path: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +xs : List<&2, U32> <- S.read(path)
    return S.split.lines(xs)

def col.files.lines(ps: List<&2, String>) -> IO(List<&2, List<&2, U32>>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +p <> more:
      do IO<List<&2, List<&2, U32>>>:
        +a : List<&2, List<&2, U32>> <- col.read.lines(p)
        +b : List<&2, List<&2, U32>> <- col.files.lines(more)
        return List.append(&2, List<&2, U32>, a, b)

# The context ------------------------------------------------------------------------

type ColCx is Data:
  ColCx{cfg: ColCfg(), out: String, src: String, self: String, procs: Nat}

def col.cx.cfg(+c: ColCx) -> ColCfg():
  match c:
    case ColCx{f, o, s, x, p}:
      f

def col.cx.out(+c: ColCx) -> String:
  match c:
    case ColCx{f, o, s, x, p}:
      o

def col.cx.src(+c: ColCx) -> String:
  match c:
    case ColCx{f, o, s, x, p}:
      s

def col.cx.self(+c: ColCx) -> String:
  match c:
    case ColCx{f, o, s, x, p}:
      x

def col.cx.procs(+c: ColCx) -> Nat:
  match c:
    case ColCx{f, o, s, x, p}:
      p

def col.st(+c: ColCx, +p: String) -> String:
  col.cx.out(c) ++ "/stage/" ++ p

def col.cx.str(+c: ColCx, +d: String, dflt: String) -> String:
  col.cf.str(col.cx.cfg(c), d, dflt)

def col.cx.pins(+c: ColCx) -> String:
  col.cx.str(c, "pins", col.cx.src(c) ++ "/PINS.tsv")

def col.cx.bend2(+c: ColCx) -> String:
  col.cx.str(c, "bend2", "")

# Fetch ------------------------------------------------------------------------------

def col.lic.of(+o: S.Out) -> String:
  Bool.pick(String, U32.is_eq(S.Out.status(o), 0), S.str(S.chomp(S.Out.text(o))), "?")

# the licence GitHub names (recorded, never a filter)
def col.lic(+name: String) -> IO(String):
  do IO<String>:
    +o : S.Out <- S.run.quiet(".", [], 120, "gh", ["api", "repos/" ++ name, "--jq", ".license.spdx_id // \"-\""], Nil{})
    return col.lic.of(o)

def col.pin.add(+pins: String, +name: String, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +lic : String <- col.lic(name)
    +h : List<&2, U32> <- col.git(dir, ["rev-parse", "HEAD"])
    +t : List<&2, U32> <- col.git(dir, ["log", "-1", "--format=%cI"])
    S.add(pins, S.b(name ++ "\t" ++ S.str(S.chomp(h)) ++ "\t" ++ S.str(S.chomp(t)) ++ "\t" ++ lic ++ "\n"))
    col.log("fetch: " ++ name ++ " pinned at " ++ S.str(S.chomp(h)) ++ " (" ++ lic ++ ")")

def col.clone.pin(fresh: Bool, +pins: String, +name: String, +dir: String) -> IO(Unit):
  match fresh:
    case True{}:
      col.pin.add(pins, name, dir)
    case False{}:
      IO.pure(Unit, Unit{})

def col.clone.move(move: Bool, +dir: String, +p: String) -> IO(Unit):
  match move:
    case True{}:
      do IO<Unit>:
        +a : List<&2, U32> <- col.git(dir, ["fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", p])
        +b : List<&2, U32> <- col.git(dir, ["checkout", "-q", "--detach", p])
        return Unit{}
    case False{}:
      do IO<Unit>:
        o : S.Out <- S.run(".", [], 600, "git", ["-C", dir, "checkout", "-q"], Nil{})
        return Unit{}

def col.clone.at(ok: Bool, +pins: String, +name: String, +dir: String, +p: List<&2, U32>) -> IO(Unit):
  match ok:
    case True{}:
      do IO<Unit>:
        +s : List<&2, U32> <- col.git(dir, ["sparse-checkout", "set", "--no-cone", "*.bend"])
        +h : List<&2, U32> <- col.git(dir, ["rev-parse", "HEAD"])
        +pinned : Bool = Bool.not(Nat.is_eq(S.len(p), 0n))
        col.clone.move(Bool.and(pinned, Bool.not(S.eq(S.chomp(h), p))), dir, S.str(p))
        col.clone.pin(Bool.not(pinned), pins, name, dir)
    case False{}:
      IO.pure(Unit, Unit{})

def col.clone.got(ok: Bool, +name: String, +dir: String, +o: S.Out) -> IO(Bool):
  match ok:
    case True{}:
      IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        col.log("fetch: clone failed: " ++ name ++ ": " ++ S.str(S.lines.take(S.Out.text(o), 3n)))
        S.rm(dir)
        return False{}

def col.clone.new(has: Bool, +name: String, +dir: String) -> IO(Bool):
  match has:
    case True{}:
      IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        +o : S.Out <- S.run(".", [], 1800, "git", ["clone", "-q", "--depth", "1", "--filter=blob:none", "--no-checkout", "https://github.com/" ++ name, dir], Nil{})
        col.clone.got(U32.is_eq(S.Out.status(o), 0), name, dir, o)

# clone OWNER/NAME into SRC/OWNER__NAME at its pin (else HEAD, pinned now)
def col.clone(+pins: String, +src: String, +r: ColRepo) -> IO(Unit):
  +name = S.str(col.r.name(r))
  +dir = src ++ "/" ++ S.str(col.r.dir(r))
  do IO<Unit>:
    +ls : List<&2, List<&2, U32>> <- col.read.lines(pins)
    +p : List<&2, U32> = col.pin(ls, col.r.name(r))
    has : Bool <- S.exists(dir ++ "/.git")
    ok : Bool <- col.clone.new(has, name, dir)
    col.clone.at(ok, pins, name, dir, p)

def col.clone.kind(up: Bool, +pins: String, +src: String, +r: ColRepo) -> IO(Unit):
  match up:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      col.clone(pins, src, r)

def col.clones(+pins: String, +src: String, rs: List<&2, ColRepo>) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> more:
      do IO<Unit>:
        col.clone.kind(Nat.is_eq(col.r.kind(r), 2n), pins, src, r)
        col.clones(pins, src, more)

# the upstream's .bend files added or changed from base to its pin
def col.up.files(ps: List<&2, List<&2, U32>>, +b2: String, +pin: String, +dir: String) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> more:
      do IO<Unit>:
        S.mkdir(S.parent(dir ++ "/" ++ S.str(p)))
        col.to("git show " ++ S.str(p), "git", ["-C", b2, "show", pin ++ ":" ++ S.str(p)], dir ++ "/" ++ S.str(p))
        col.up.files(more, b2, pin, dir)

def col.up.pin.new(none: Bool, +pins: String, +name: String, +b2: String) -> IO(Unit):
  match none:
    case True{}:
      do IO<Unit>:
        +f : List<&2, U32> <- col.git(b2, ["fetch", "-q", "origin"])
        +h : List<&2, U32> <- col.git(b2, ["rev-parse", "origin/main"])
        +t : List<&2, U32> <- col.git(b2, ["log", "-1", "--format=%cI", S.str(S.chomp(h))])
        +lic : String <- col.lic(name)
        S.add(pins, S.b(name ++ "\t" ++ S.str(S.chomp(h)) ++ "\t" ++ S.str(S.chomp(t)) ++ "\t" ++ lic ++ "\n"))
        col.log("fetch: upstream " ++ name ++ " pinned at " ++ S.str(S.chomp(h)) ++ " (" ++ lic ++ ")")
    case False{}:
      IO.pure(Unit, Unit{})

def col.up.fetch.go(rs: List<&2, ColRepo>, +c: ColCx) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> more:
      +pins = col.cx.pins(c)
      +b2 = col.cx.bend2(c)
      +name = S.str(col.r.name(r))
      +dir = col.cx.src(c) ++ "/" ++ S.str(col.r.dir(r))
      +base = S.str(col.up.base(col.cf.args(col.cx.cfg(c), S.b("upstream"))))
      do IO<Unit>:
        +l0 : List<&2, List<&2, U32>> <- col.read.lines(pins)
        col.up.pin.new(Nat.is_eq(S.len(col.pin(l0, col.r.name(r))), 0n), pins, name, b2)
        +ls : List<&2, List<&2, U32>> <- col.read.lines(pins)
        +pin : String = S.str(col.pin(ls, col.r.name(r)))
        col.log("fetch: upstream " ++ name ++ " .bend files added or changed " ++ base ++ ".." ++ pin)
        S.rm(dir)
        S.mkdir(dir)
        +d : List<&2, U32> <- col.git(b2, ["diff", "--name-only", "--diff-filter=AM", base, pin, "--", "*.bend"])
        col.up.files(col.nonempty(S.split.lines(d)), b2, pin, dir)

def col.sib.one(ws: List<&2, List<&2, U32>>, +src: String) -> IO(Unit):
  match ws:
    case +r <> +l <> rest:
      do IO<Unit>:
        +o : List<&2, U32> <- col.must("ln " ++ S.str(l), "ln", ["-sfn", S.str(col.dir.of(r)), src ++ "/" ++ S.str(l)])
        return Unit{}
    case _:
      IO.die(Unit, 1, "collect: sibling OWNER/NAME LINK")

def col.sibs(xss: ColCfg(), +src: String) -> IO(Unit):
  match xss:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case ws <> more:
      do IO<Unit>:
        col.sib.one(ws, src)
        col.sibs(more, src)

# The hub (2026-10-16) -------------------------------------------------------------------
#
# `hub URL RULE [exclude PREFIX...]`: BendHub's packages (`bend FILE --publish`), each
# taken as a repository SRC/hub__NAME (an unnamed package: SRC/hub__0xHASH) that every
# later step treats like a clone; RULE and the excluded prefixes as a repository's.
#
#   the listing   URL/packages.json?sort=new&limit=100&after=K, page by page until the
#                 listing's total (SRC/.hub/packages-K.json): each package's hash, name,
#                 version, publish time and licence
#   the choice    the newest version of every name (versions compared as numbers, a part
#                 at a time, then the publish time) and every unnamed package; PINS keeps a
#                 package's hash under hub/NAME (hub/0xHASH), so a fetch again takes the
#                 pinned one; a new row gives the hash, the publish date (UTC), the licence
#                 (the listing's id; LICENSE for a licence file without one; MIT-0 (default)
#                 for none, the hub's terms) and NAME@VERSION, recorded, never a filter
#   the files     URL/0xHASH/manifest (`SHA256 PATH` a line), which must hash to the
#                 package's hash (the hash is its sha256's first 32 hex digits) and name
#                 only plain relative paths (parts of [A-Za-z0-9._-], none . or ..), then
#                 every file it names (curl) and `sha256sum -c` on them; a package that
#                 fails is logged and left out; a complete one gets SRC/hub__X/.hub (its
#                 hash), and a fetch again keeps a directory whose .hub is the chosen hash
#   SRC/HUB.tsv   `DIR TAB hub/NAME TAB HASH TAB VERSION TAB LICENCE` a complete package,
#                 sorted by DIR: the repositories `list` adds after the config's
#
# The packages are new repositories to the later steps (the vault's quarter, C3's units).

type ColHub is Data:
  ColHub{hash: List<&2, U32>, name: List<&2, U32>, version: List<&2, U32>, ts: Nat, lic: List<&2, U32>}

type ColHubCf is Data:
  ColHubCf{url: List<&2, U32>, rule: Nat, excl: List<&2, List<&2, U32>>}

def col.hub.lic.none() -> List<&2, U32>:
  S.b("MIT-0 (default)")

def col.hub.empty() -> ColHub:
  ColHub{Nil{}, Nil{}, Nil{}, 0n, col.hub.lic.none()}

def col.hub.hash(+h: ColHub) -> List<&2, U32>:
  match h:
    case ColHub{a, n, v, t, l}:
      a

def col.hub.name(+h: ColHub) -> List<&2, U32>:
  match h:
    case ColHub{a, n, v, t, l}:
      n

def col.hub.version(+h: ColHub) -> List<&2, U32>:
  match h:
    case ColHub{a, n, v, t, l}:
      v

def col.hub.ts(+h: ColHub) -> Nat:
  match h:
    case ColHub{a, n, v, t, l}:
      t

def col.hub.lic(+h: ColHub) -> List<&2, U32>:
  match h:
    case ColHub{a, n, v, t, l}:
      l

def col.hub.named(+h: ColHub) -> Bool:
  Nat.is_lt(0n, S.len(col.hub.name(h)))

# the package as a repository: hub/NAME (hub/0xHASH), its directory hub__NAME
def col.hub.repo(+h: ColHub) -> List<&2, U32>:
  S.append(S.b("hub/"), Bool.pick(List<&2, U32>, col.hub.named(h), col.hub.name(h), col.hub.hash(h)))

def col.hub.dir(+h: ColHub) -> List<&2, U32>:
  col.dir.of(col.hub.repo(h))

# NAME@VERSION, or the hash
def col.hub.label(+h: ColHub) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, col.hub.named(h), L.v2.concat([col.hub.name(h), [64], col.hub.version(h)]), col.hub.hash(h))

# The config line

def col.hub.cf.of(ws: List<&2, List<&2, U32>>) -> List<&2, ColHubCf>:
  match ws:
    case +u <> rl <> rest:
      [ColHubCf{u, col.rule(rl), col.excl(rest)}]
    case u <> Nil{}:
      [ColHubCf{u, 9n, Nil{}}]
    case Nil{}:
      Nil{}

def col.hub.cf.first(xss: ColCfg()) -> List<&2, ColHubCf>:
  match xss:
    case Nil{}:
      Nil{}
    case ws <> more:
      col.hub.cf.of(ws)

# the hub line (its first; none: an empty list)
def col.hub.cf(+cs: ColCfg()) -> List<&2, ColHubCf>:
  col.hub.cf.first(col.cf.args(cs, S.b("hub")))

def col.hub.cf.rules(hs: List<&2, ColHubCf>) -> List<&2, List<&2, U32>>:
  match hs:
    case Nil{}:
      Nil{}
    case ColHubCf{+u, +r, e} <> more:
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(r, 9n), [S.append(S.b("hub "), u)], Nil{})

# URL without a trailing /
def col.hub.base(+u: List<&2, U32>) -> String:
  S.str(Bool.pick(List<&2, U32>, S.suffix(u, [47]), List.take(&2, U32, u, Nat.sub(S.len(u), 1n)), u))

def col.hub.page.url(+base: String, +after: Nat) -> String:
  base ++ "/packages.json?sort=new&limit=100&after=" ++ Nat.show(after)

# The listing: st.js.values' leaves at [packages, K, FIELD, ...], a package a K

# a field's code: 1 hash, 2 name, 3 version, 4 ts, 5 license.file, 6 license.id, 0 other
def col.hub.sub(+rest: List<&2, St.StJk>) -> List<&2, U32>:
  match rest:
    case St.StJkK{k} <> Nil{}:
      k
    case _:
      [0]

def col.hub.code(+f: List<&2, U32>, +rest: List<&2, St.StJk>) -> Nat:
  +top = Nat.is_eq(List.length(&2, St.StJk, rest), 0n)
  +lic = S.eq(f, S.b("license"))
  Bool.pick(Nat, Bool.and(top, S.eq(f, S.b("hash"))), 1n,
    Bool.pick(Nat, Bool.and(top, S.eq(f, S.b("name"))), 2n,
      Bool.pick(Nat, Bool.and(top, S.eq(f, S.b("version"))), 3n,
        Bool.pick(Nat, Bool.and(top, S.eq(f, S.b("ts"))), 4n,
          Bool.pick(Nat, Bool.and(lic, S.eq(col.hub.sub(rest), S.b("file"))), 5n,
            Bool.pick(Nat, Bool.and(lic, S.eq(col.hub.sub(rest), S.b("id"))), 6n, 0n))))))

# a string value as json.loads gives it; anything else (null) empty
def col.hub.str(v: St.StTk) -> List<&2, U32>:
  match v:
    case St.StTkS{r}:
      St.st.js.key(r)
    case _:
      Nil{}

def col.hub.set(code: Nat, v: St.StTk, h: ColHub) -> ColHub:
  match code h:
    case 1n ColHub{a, n, ver, t, l}:
      ColHub{col.hub.str(v), n, ver, t, l}
    case 2n ColHub{a, n, ver, t, l}:
      ColHub{a, col.hub.str(v), ver, t, l}
    case 3n ColHub{a, n, ver, t, l}:
      ColHub{a, n, col.hub.str(v), t, l}
    case 4n ColHub{a, n, ver, t, l}:
      ColHub{a, n, ver, col.nat(St.st.js.text(v)), l}
    case 5n ColHub{a, n, ver, t, +l}:
      ColHub{a, n, ver, t, Bool.pick(List<&2, U32>, S.eq(l, col.hub.lic.none()), S.b("LICENSE"), l)}
    case 6n ColHub{a, n, ver, t, +l}:
      +s = col.hub.str(v)
      ColHub{a, n, ver, t, Bool.pick(List<&2, U32>, Nat.is_eq(S.len(s), 0n), l, s)}
    case _ h2:
      h2

type ColHi is Data:
  ColHi{i: Nat, code: Nat, v: St.StTk}

def col.hub.item(+p: List<&2, St.StJk>, v: St.StTk) -> List<&2, ColHi>:
  match p:
    case St.StJkK{+top} <> St.StJkI{+i} <> St.StJkK{+f} <> +rest:
      Bool.pick(List<&2, ColHi>, S.eq(top, S.b("packages")), [ColHi{i, col.hub.code(f, rest), v}], Nil{})
    case _:
      Nil{}

def col.hub.items(vs: List<&2, St.StJv>) -> List<&2, ColHi>:
  match vs:
    case Nil{}:
      Nil{}
    case St.StJv{p, v} <> more:
      List.append(&2, ColHi, col.hub.item(p, v), col.hub.items(more))

def col.hub.same(+xs: List<&2, ColHi>, +k: Nat) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case ColHi{+i, c, v} <> more:
      Nat.is_eq(i, k)

def col.hub.close(open: Bool, h: ColHub, rest: List<&2, ColHub>) -> List<&2, ColHub>:
  match open:
    case True{}:
      h <> rest
    case False{}:
      rest

# the items grouped by K, each group folded into a package
def col.hub.grp(xs: List<&2, ColHi>, same: Bool, +k: Nat, cur: ColHub, open: Bool) -> List<&2, ColHub>:
  match xs same:
    case Nil{} _:
      col.hub.close(open, cur, Nil{})
    case ColHi{i, c, v} <> +more True{}:
      col.hub.grp(more, col.hub.same(more, k), k, col.hub.set(c, v, cur), True{})
    case ColHi{+i, c, v} <> +more False{}:
      col.hub.close(open, cur, col.hub.grp(more, col.hub.same(more, i), i, col.hub.set(c, v, col.hub.empty()), True{}))

def col.hub.of.values(m: Maybe<&2, List<&2, St.StJv>>) -> Maybe<&2, List<&2, ColHub>>:
  match m:
    case None{}:
      None{}
    case Some{vs}:
      Some{col.hub.grp(col.hub.items(vs), False{}, 0n, col.hub.empty(), False{})}

# a listing page's packages (None: the page is not JSON)
def col.hub.listing(+json: List<&2, U32>) -> Maybe<&2, List<&2, ColHub>>:
  col.hub.of.values(St.st.js.values(json))

def col.hub.total.of(m: Maybe<&2, List<&2, St.StJv>>) -> Nat:
  match m:
    case None{}:
      0n
    case Some{vs}:
      col.nat(St.st.js.text(Maybe.default(&2, St.StTk, St.st.js.at(vs, [St.StJkK{S.b("total")}]), St.StTkV{S.b("0")})))

# the listing's total
def col.hub.total(+json: List<&2, U32>) -> Nat:
  col.hub.total.of(St.st.js.values(json))

# The choice

def col.hub.nats(xss: List<&2, List<&2, U32>>) -> List<&2, Nat>:
  match xss:
    case Nil{}:
      Nil{}
    case +x <> more:
      col.nat(x) <> col.hub.nats(more)

# a version's numbers: 0.1.11.0 is [0, 1, 11, 0]
def col.hub.ver(+v: List<&2, U32>) -> List<&2, Nat>:
  col.hub.nats(S.split(v, 46))

# compare number lists a part at a time: 0 less, 1 equal, 2 greater (a prefix is less)
def col.hub.vcmp(a: List<&2, Nat>, b: List<&2, Nat>) -> Nat:
  match a b:
    case Nil{} Nil{}:
      1n
    case Nil{} y <> yt:
      0n
    case x <> xt Nil{}:
      2n
    case +x <> xt +y <> yt:
      +r = col.hub.vcmp(xt, yt)
      Bool.pick(Nat, Nat.is_lt(x, y), 0n, Bool.pick(Nat, Nat.is_lt(y, x), 2n, r))

# version v at time t is at least as new as version w at time u: greater, or the same
# and published no earlier
def col.hub.newer(+v: List<&2, U32>, +t: Nat, +w: List<&2, U32>, +u: Nat) -> Bool:
  +c = col.hub.vcmp(col.hub.ver(v), col.hub.ver(w))
  Bool.or(Nat.is_eq(c, 2n), Bool.and(Nat.is_eq(c, 1n), Nat.is_le(u, t)))

# by name, the newest of a name first
def col.hub.le(a: ColHub, b: ColHub) -> Bool:
  match a b:
    case ColHub{h1, +x, v, t, l1} ColHub{h2, +y, w, u, l2}:
      Bool.pick(Bool, S.eq(x, y), col.hub.newer(v, t, w, u), col.le(x, y))

def col.hub.dir.le(a: ColHub, b: ColHub) -> Bool:
  col.le(col.hub.dir(a), col.hub.dir(b))

def col.hub.first.go(xs: List<&2, ColHub>, +prev: List<&2, U32>, first: Bool) -> List<&2, ColHub>:
  match xs first:
    case Nil{} _:
      Nil{}
    case +x <> more True{}:
      x <> col.hub.first.go(more, col.hub.name(x), False{})
    case +x <> more False{}:
      List.append(&2, ColHub, Bool.pick(List<&2, ColHub>, S.eq(col.hub.name(x), prev), Nil{}, [x]), col.hub.first.go(more, col.hub.name(x), False{}))

def col.hub.hashes.go(xs: List<&2, ColHub>, +seen: Set()) -> List<&2, ColHub>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      +k = col.k(col.hub.hash(x))
      List.append(&2, ColHub, Bool.pick(List<&2, ColHub>, L.v2.in(seen, k), Nil{}, [x]), col.hub.hashes.go(more, Set.add(seen, k)))

# a listing without a hash twice (paging while the hub publishes can show one twice)
def col.hub.uniq(xs: List<&2, ColHub>) -> List<&2, ColHub>:
  col.hub.hashes.go(xs, Set.new())

# the packages to take: the newest of every name and every unnamed one, by directory
def col.hub.choose(+xs: List<&2, ColHub>) -> List<&2, ColHub>:
  +named = List.filter(~ColHub, ~(h => col.hub.named(h)), xs)
  +unnamed = List.filter(~ColHub, ~(h => Bool.not(col.hub.named(h))), xs)
  List.sort(~ColHub, ~col.hub.dir.le, List.append(&2, ColHub, col.hub.first.go(List.sort(~ColHub, ~col.hub.le, named), Nil{}, True{}), unnamed))

def col.hub.find(xs: List<&2, ColHub>, +hash: List<&2, U32>) -> Maybe<&2, ColHub>:
  match xs:
    case Nil{}:
      None{}
    case +x <> more:
      +rest = col.hub.find(more, hash)
      Bool.pick(Maybe<&2, ColHub>, S.eq(col.hub.hash(x), hash), Some{x}, rest)

def col.hub.pin.got(+h: ColHub, +p: List<&2, U32>, m: Maybe<&2, ColHub>) -> ColHub:
  match m:
    case Some{x}:
      x
    case None{}:
      ColHub{p, col.hub.name(h), S.b("?"), 0n, S.b("?")}

# the choice under PINS: a pinned package's hash is the pinned one (its listing row when
# the listing has it)
def col.hub.pinned(+all: List<&2, ColHub>, +pins: List<&2, List<&2, U32>>, +h: ColHub) -> ColHub:
  +p = col.pin(pins, col.hub.repo(h))
  Bool.pick(ColHub, Bool.or(Nat.is_eq(S.len(p), 0n), S.eq(p, col.hub.hash(h))), h, col.hub.pin.got(h, p, col.hub.find(all, p)))

def col.hub.pins(hs: List<&2, ColHub>, +all: List<&2, ColHub>, +pins: List<&2, List<&2, U32>>) -> List<&2, ColHub>:
  match hs:
    case Nil{}:
      Nil{}
    case h <> more:
      col.hub.pinned(all, pins, h) <> col.hub.pins(more, all, pins)

# ms since the epoch as an ISO date in UTC
def col.hub.date(+ms: Nat) -> String:
  +s = U32.from_nat(Nat.mod(Nat.div(ms, 1000n), 86400n))
  Ck.civil(U32.from_nat(Nat.div(ms, 86400000n))) ++ "T" ++ Ck.pad2(U32.div(s, 3600)) ++ ":" ++ Ck.pad2(U32.div(U32.mod(s, 3600), 60)) ++ ":" ++ Ck.pad2(U32.mod(s, 60)) ++ "Z"

# a PINS row: hub/NAME TAB HASH TAB DATE TAB LICENCE TAB NAME@VERSION
def col.hub.pin.row(+h: ColHub) -> List<&2, U32>:
  L.v2.concat([col.hub.repo(h), [9], col.hub.hash(h), [9], S.b(col.hub.date(col.hub.ts(h))), [9], col.hub.lic(h), [9], col.hub.label(h), [10]])

# a HUB.tsv row: DIR TAB hub/NAME TAB HASH TAB VERSION TAB LICENCE
def col.hub.row(+h: ColHub) -> List<&2, U32>:
  L.v2.concat([col.hub.dir(h), [9], col.hub.repo(h), [9], col.hub.hash(h), [9], col.hub.version(h), [9], col.hub.lic(h), [10]])

# The manifest

type ColHf is Data:
  ColHf{sha: List<&2, U32>, path: List<&2, U32>}

def col.hub.hf.path(+f: ColHf) -> List<&2, U32>:
  match f:
    case ColHf{s, p}:
      p

def col.hub.in(+c: U32, +lo: U32, +hi: U32) -> Bool:
  Bool.and(U32.is_le(lo, c), U32.is_le(c, hi))

def col.hub.byte.ok(+c: U32) -> Bool:
  Bool.or(Bool.or(col.hub.in(c, 97, 122), col.hub.in(c, 65, 90)), Bool.or(col.hub.in(c, 48, 57), Bool.or(Bool.or(U32.is_eq(c, 46), U32.is_eq(c, 95)), U32.is_eq(c, 45))))

def col.hub.hex.byte(+c: U32) -> Bool:
  Bool.or(col.hub.in(c, 48, 57), col.hub.in(c, 97, 102))

def col.hub.bytes.ok(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> more:
      Bool.and(col.hub.byte.ok(c), col.hub.bytes.ok(more))

def col.hub.hex.ok(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> more:
      Bool.and(col.hub.hex.byte(c), col.hub.hex.ok(more))

def col.hub.part.ok(+p: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(Nat.is_lt(0n, S.len(p)), col.hub.bytes.ok(p)), Bool.not(Bool.or(S.eq(p, [46]), S.eq(p, [46, 46]))))

def col.hub.parts.ok(ps: List<&2, List<&2, U32>>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case +p <> more:
      Bool.and(col.hub.part.ok(p), col.hub.parts.ok(more))

# a plain relative path: parts of [A-Za-z0-9._-] joined by single slashes, none . or ..
def col.hub.path.ok(+p: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(Nat.is_lt(0n, S.len(p)), Bool.not(S.suffix(p, [47]))), col.hub.parts.ok(S.split(p, 47)))

# a manifest line, `SHA256 PATH` (Nil: not one)
def col.hub.man.line(+l: List<&2, U32>) -> List<&2, ColHf>:
  +sha = L.v2.before(l, 32)
  +p = L.v2.after(l, 32)
  Bool.pick(List<&2, ColHf>, Bool.and(Bool.and(L.v2.has(l, 32), Nat.is_eq(S.len(sha), 64n)), Bool.and(col.hub.hex.ok(sha), col.hub.path.ok(p))), [ColHf{sha, p}], Nil{})

def col.hub.man.go(ls: List<&2, List<&2, U32>>) -> List<&2, ColHf>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      List.append(&2, ColHf, col.hub.man.line(l), col.hub.man.go(more))

# a manifest's files (None: a line that is not one, or no file)
def col.hub.man(+xs: List<&2, U32>) -> Maybe<&2, List<&2, ColHf>>:
  +ls = col.nonempty(S.split.lines(xs))
  +fs = col.hub.man.go(ls)
  +n = List.length(&2, ColHf, fs)
  Bool.pick(Maybe<&2, List<&2, ColHf>>, Bool.and(Nat.is_lt(0n, n), Nat.is_eq(n, List.length(&2, List<&2, U32>, ls))), Some{fs}, None{})

# the manifest is the package's: its sha256 starts with the hash's 32 hex digits
def col.hub.man.ok(+hash: List<&2, U32>, +xs: List<&2, U32>) -> Bool:
  +h = List.drop(&2, U32, hash, 2n)
  Bool.and(Bool.and(S.prefix(hash, S.b("0x")), Nat.is_eq(S.len(h), 32n)), S.prefix(S.b(H.sha256(xs)), h))

# sha256sum's check file: `SHA256  PATH` a line
def col.hub.sums(fs: List<&2, ColHf>) -> List<&2, U32>:
  match fs:
    case Nil{}:
      Nil{}
    case ColHf{s, p} <> more:
      L.v2.concat([s, [32, 32], p, [10], col.hub.sums(more)])

def col.hub.curl.flags() -> List<&2, String>:
  ["-fsS", "--retry", "3", "--retry-delay", "2", "--connect-timeout", "30"]

# curl's arguments for every file: -o PATH URL/0xHASH/PATH
def col.hub.gets(fs: List<&2, ColHf>, +base: String, +hash: String) -> List<&2, String>:
  match fs:
    case Nil{}:
      Nil{}
    case +f <> more:
      +p = S.str(col.hub.hf.path(f))
      "-o" <> p <> (base ++ "/" ++ hash ++ "/" ++ p) <> col.hub.gets(more, base, hash)

# HUB.tsv's rows as repositories (kind 3: a hub package), with the hub line's rule
def col.hub.repos.of(ls: List<&2, List<&2, U32>>, +rule: Nat, +excl: List<&2, List<&2, U32>>) -> List<&2, ColRepo>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +fs = S.split(l, 9)
      List.append(&2, ColRepo, Bool.pick(List<&2, ColRepo>, Nat.is_lt(1n, List.length(&2, List<&2, U32>, fs)), [ColRepo{L.v2.nth(fs, 1n), L.v2.nth(fs, 0n), rule, excl, 3n}], Nil{}), col.hub.repos.of(more, rule, excl))

# The fetch

def col.hub.src(+c: ColCx) -> String:
  col.cx.src(c) ++ "/HUB.tsv"

def col.hub.pages.got(m: Maybe<&2, List<&2, ColHub>>, +page: String) -> IO(List<&2, ColHub>):
  match m:
    case Some{ps}:
      IO.pure(List<&2, ColHub>, ps)
    case None{}:
      IO.die(List<&2, ColHub>, 1, "collect: hub: " ++ page ++ " is not a package listing")

# the listing, a page at a time from AFTER, until a page is empty or the total is reached
def col.hub.pages(fuel: Nat, go: Bool, +base: String, +dir: String, +after: Nat, acc: List<&2, ColHub>) -> IO(List<&2, ColHub>):
  match fuel go:
    case 1n+f True{}:
      +page = dir ++ "/packages-" ++ Nat.show(after) ++ ".json"
      do IO<List<&2, ColHub>>:
        col.to("curl " ++ col.hub.page.url(base, after), "curl", List.append(&2, String, col.hub.curl.flags(), ["--max-time", "120", col.hub.page.url(base, after)]), page)
        +xs : List<&2, U32> <- S.read(page)
        +ps : List<&2, ColHub> <- col.hub.pages.got(col.hub.listing(xs), page)
        +n : Nat = List.length(&2, ColHub, ps)
        +total : Nat = col.hub.total(xs)
        col.log("fetch: hub listing after " ++ Nat.show(after) ++ ": " ++ Nat.show(n) ++ " packages (total " ++ Nat.show(total) ++ ")")
        col.hub.pages(f, Bool.and(Nat.is_lt(0n, n), Nat.is_lt(Nat.add(after, n), total)), base, dir, Nat.add(after, n), List.append(&2, ColHub, acc, ps))
    case _ _:
      IO.pure(List<&2, ColHub>, acc)

def col.hub.pin.new(fresh: Bool, +pins: String, +h: ColHub) -> IO(Unit):
  match fresh:
    case True{}:
      S.add(pins, col.hub.pin.row(h))
    case False{}:
      IO.pure(Unit, Unit{})

def col.hub.pin.all(hs: List<&2, ColHub>, +pins: String, +old: List<&2, List<&2, U32>>) -> IO(Unit):
  match hs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +h <> more:
      do IO<Unit>:
        col.hub.pin.new(Nat.is_eq(S.len(col.pin(old, col.hub.repo(h))), 0n), pins, h)
        col.hub.pin.all(more, pins, old)

# a directory whose .hub is the hash is complete
def col.hub.done(+dir: String, +hash: List<&2, U32>) -> IO(Bool):
  do IO<Bool>:
    there : Bool <- S.exists(dir ++ "/.hub")
    +xs : List<&2, U32> <- S.read(dir ++ "/.hub")
    return Bool.and(there, S.eq(S.chomp(xs), hash))

def col.hub.todo.keep(done: Bool, h: ColHub, rest: List<&2, ColHub>) -> List<&2, ColHub>:
  match done:
    case True{}:
      rest
    case False{}:
      h <> rest

# the chosen packages not complete yet (each emptied and made again)
def col.hub.todo(hs: List<&2, ColHub>, +src: String) -> IO(List<&2, ColHub>):
  match hs:
    case Nil{}:
      IO.pure(List<&2, ColHub>, Nil{})
    case +h <> more:
      +dir = src ++ "/" ++ S.str(col.hub.dir(h))
      do IO<List<&2, ColHub>>:
        done : Bool <- col.hub.done(dir, col.hub.hash(h))
        +rest : List<&2, ColHub> <- col.hub.todo(more, src)
        return col.hub.todo.keep(done, h, rest)

def col.hub.fresh(hs: List<&2, ColHub>, +src: String) -> IO(Unit):
  match hs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +h <> more:
      +dir = src ++ "/" ++ S.str(col.hub.dir(h))
      do IO<Unit>:
        S.rm(dir)
        S.mkdir(dir)
        col.hub.fresh(more, src)

def col.hub.man.jobs(hs: List<&2, ColHub>, +base: String, +src: String, +k: Nat) -> List<&2, ColJob>:
  match hs:
    case Nil{}:
      Nil{}
    case +h <> more:
      +hash = S.str(col.hub.hash(h))
      +out = src ++ "/" ++ S.str(col.hub.dir(h)) ++ "/.hub.manifest"
      ColJob{k, 0n, [ColCmd{".", Nil{}, 300, "curl", List.append(&2, String, col.hub.curl.flags(), ["--max-time", "120", base ++ "/" ++ hash ++ "/manifest"]), out}]} <> col.hub.man.jobs(more, base, src, 1n+k)

# A package on its way: its row, its directory, its files (None: refused)
type ColHp is Data:
  ColHp{h: ColHub, dir: String, fs: Maybe<&2, List<&2, ColHf>>}

def col.hub.hp.ok(+p: ColHp) -> Bool:
  match p:
    case ColHp{h, d, Some{fs}}:
      True{}
    case ColHp{h, d, None{}}:
      False{}

def col.hub.man.note(ok: Bool, +good: Bool, +h: ColHub) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      col.log("fetch: hub: " ++ S.str(col.hub.label(h)) ++ ": " ++ Bool.pick(String, good, "a manifest line is not `SHA256 PATH` with a plain relative path", "the manifest does not hash to the package's hash") ++ "; left out")

def col.hub.man.read(ok: Bool, +h: ColHub, +dir: String) -> IO(ColHp):
  match ok:
    case True{}:
      do IO<ColHp>:
        +xs : List<&2, U32> <- S.read(dir ++ "/.hub.manifest")
        +good : Bool = col.hub.man.ok(col.hub.hash(h), xs)
        +m : Maybe<&2, List<&2, ColHf>> = Bool.pick(Maybe<&2, List<&2, ColHf>>, good, col.hub.man(xs), None{})
        col.hub.man.note(col.hub.hp.ok(ColHp{h, dir, m}), good, h)
        return ColHp{h, dir, m}
    case False{}:
      do IO<ColHp>:
        col.log("fetch: hub: " ++ S.str(col.hub.label(h)) ++ ": no manifest")
        return ColHp{h, dir, None{}}

# the manifests read (the pool's results in the packages' order)
def col.hub.hps(hs: List<&2, ColHub>, rs: List<&2, ColRes>, +src: String) -> IO(List<&2, ColHp>):
  match hs rs:
    case +h <> more +r <> rt:
      do IO<List<&2, ColHp>>:
        +p : ColHp <- col.hub.man.read(U32.is_eq(col.res.status(r), 0), h, src ++ "/" ++ S.str(col.hub.dir(h)))
        +rest : List<&2, ColHp> <- col.hub.hps(more, rt, src)
        return p <> rest
    case _ _:
      IO.pure(List<&2, ColHp>, Nil{})

def col.hub.file.jobs(ps: List<&2, ColHp>, +base: String, +k: Nat) -> List<&2, ColJob>:
  match ps:
    case Nil{}:
      Nil{}
    case ColHp{+h, +dir, Some{+fs}} <> more:
      +hash = S.str(col.hub.hash(h))
      ColJob{k, 0n, [ColCmd{dir, Nil{}, 3600, "curl", List.append(&2, String, col.hub.curl.flags(), List.append(&2, String, ["--max-time", "3000", "--create-dirs"], col.hub.gets(fs, base, hash))), ""},
        ColCmd{dir, Nil{}, 600, "sha256sum", ["--quiet", "--strict", "-c", ".hub.sha256"], ""}]} <> col.hub.file.jobs(more, base, 1n+k)
    case ColHp{h, dir, None{}} <> more:
      col.hub.file.jobs(more, base, k)

def col.hub.sums.write(ps: List<&2, ColHp>) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case ColHp{h, +dir, Some{fs}} <> more:
      do IO<Unit>:
        S.write(dir ++ "/.hub.sha256", col.hub.sums(fs))
        col.hub.sums.write(more)
    case ColHp{h, dir, None{}} <> more:
      col.hub.sums.write(more)

def col.hub.oks(ps: List<&2, ColHp>) -> List<&2, ColHp>:
  List.filter(~ColHp, ~(p => col.hub.hp.ok(p)), ps)

def col.hub.end(ok: Bool, +h: ColHub, +dir: String, +r: ColRes) -> IO(Unit):
  match ok:
    case True{}:
      S.write(dir ++ "/.hub", S.append(col.hub.hash(h), [10]))
    case False{}:
      do IO<Unit>:
        col.log("fetch: hub: " ++ S.str(col.hub.label(h)) ++ " failed (exit " ++ U32.show(col.res.status(r)) ++ "): " ++ S.str(S.lines.take(col.res.text(r), 3n)))
        S.rm(dir)

def col.hub.ends(ps: List<&2, ColHp>, rs: List<&2, ColRes>) -> IO(Unit):
  match ps rs:
    case ColHp{+h, +dir, m} <> more +r <> rt:
      do IO<Unit>:
        col.hub.end(U32.is_eq(col.res.status(r), 0), h, dir, r)
        col.hub.ends(more, rt)
    case _ _:
      IO.pure(Unit, Unit{})

def col.hub.rows(hs: List<&2, ColHub>, +src: String) -> IO(List<&2, U32>):
  match hs:
    case Nil{}:
      IO.pure(List<&2, U32>, Nil{})
    case +h <> more:
      do IO<List<&2, U32>>:
        done : Bool <- col.hub.done(src ++ "/" ++ S.str(col.hub.dir(h)), col.hub.hash(h))
        +rest : List<&2, U32> <- col.hub.rows(more, src)
        return S.append(Bool.pick(List<&2, U32>, done, col.hub.row(h), Nil{}), rest)

def col.hub.fetch.go(+c: ColCx, +hc: ColHubCf) -> IO(Unit):
  match hc:
    case ColHubCf{+u, r, e}:
      +base = col.hub.base(u)
      +src = col.cx.src(c)
      +pins = col.cx.pins(c)
      do IO<Unit>:
        S.mkdir(src ++ "/.hub")
        +all0 : List<&2, ColHub> <- col.hub.pages(col.fuel(), True{}, base, src ++ "/.hub", 0n, Nil{})
        +all : List<&2, ColHub> = col.hub.uniq(all0)
        +old : List<&2, List<&2, U32>> <- col.read.lines(pins)
        +chosen : List<&2, ColHub> = col.hub.pins(col.hub.choose(all), all, old)
        +nn : Nat = List.length(&2, ColHub, List.filter(~ColHub, ~(h => col.hub.named(h)), chosen))
        col.log("fetch: hub " ++ base ++ ": " ++ Nat.show(List.length(&2, ColHub, all)) ++ " packages listed; " ++ Nat.show(nn) ++ " names (the newest of each), " ++ Nat.show(Nat.sub(List.length(&2, ColHub, chosen), nn)) ++ " unnamed")
        col.hub.pin.all(chosen, pins, old)
        +todo : List<&2, ColHub> <- col.hub.todo(chosen, src)
        col.log("fetch: hub: " ++ Nat.show(List.length(&2, ColHub, todo)) ++ " packages to fetch (the rest complete in " ++ src ++ ")")
        col.hub.fresh(todo, src)
        +mr : List<&2, ColRes> <- col.pool("fetch: hub manifests", col.cx.procs(c), col.hub.man.jobs(todo, base, src, 0n))
        +hps : List<&2, ColHp> <- col.hub.hps(todo, mr, src)
        +oks : List<&2, ColHp> = col.hub.oks(hps)
        col.hub.sums.write(oks)
        +fr : List<&2, ColRes> <- col.pool("fetch: hub files", col.cx.procs(c), col.hub.file.jobs(oks, base, 0n))
        col.hub.ends(oks, fr)
        +rows : List<&2, U32> <- col.hub.rows(chosen, src)
        S.write(col.hub.src(c), rows)
        +n : Nat = List.length(&2, List<&2, U32>, col.nonempty(S.split.lines(rows)))
        col.log("fetch: hub: " ++ Nat.show(n) ++ " of " ++ Nat.show(List.length(&2, ColHub, chosen)) ++ " packages complete (" ++ col.hub.src(c) ++ ")")

def col.hub.fetch.all(+c: ColCx, hs: List<&2, ColHubCf>) -> IO(Unit):
  match hs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +h <> more:
      col.hub.fetch.go(c, h)

def col.hub.fetch(+c: ColCx) -> IO(Unit):
  col.hub.fetch.all(c, col.hub.cf(col.cx.cfg(c)))

def col.hub.repos.got(there: Bool, +c: ColCx, +hc: ColHubCf) -> IO(List<&2, ColRepo>):
  match there hc:
    case True{} ColHubCf{u, +r, +e}:
      do IO<List<&2, ColRepo>>:
        +ls : List<&2, List<&2, U32>> <- col.read.lines(col.hub.src(c))
        return col.hub.repos.of(ls, r, e)
    case False{} h:
      IO.die(List<&2, ColRepo>, 1, "collect: " ++ col.hub.src(c) ++ " is missing (the hub's packages: run fetch first)")

def col.hub.repos.all(+c: ColCx, hs: List<&2, ColHubCf>) -> IO(List<&2, ColRepo>):
  match hs:
    case Nil{}:
      IO.pure(List<&2, ColRepo>, Nil{})
    case +h <> more:
      do IO<List<&2, ColRepo>>:
        there : Bool <- S.exists(col.hub.src(c))
        col.hub.repos.got(there, c, h)

# the hub's packages as repositories (none without a hub line)
def col.hub.repos(+c: ColCx) -> IO(List<&2, ColRepo>):
  col.hub.repos.all(c, col.hub.cf(col.cx.cfg(c)))

def col.fetch(+c: ColCx) -> IO(Unit):
  +rs = col.repos(col.cx.cfg(c))
  do IO<Unit>:
    S.mkdir(col.cx.src(c))
    S.mkdir(S.parent(col.cx.pins(c)))
    S.add(col.cx.pins(c), Nil{})
    col.log("fetch: " ++ Nat.show(List.length(&2, ColRepo, rs)) ++ " repositories into " ++ col.cx.src(c))
    col.clones(col.cx.pins(c), col.cx.src(c), rs)
    col.sibs(col.cf.args(col.cx.cfg(c), S.b("sibling")), col.cx.src(c))
    col.up.fetch.go(col.up(col.cx.cfg(c)), c)
    col.hub.fetch(c)
    +pl : List<&2, List<&2, U32>> <- col.read.lines(col.cx.pins(c))
    col.log("fetch: done (" ++ Nat.show(List.length(&2, List<&2, U32>, col.nonempty(pl))) ++ " pinned)")

# List ---------------------------------------------------------------------------------

type ColF is Data:
  ColF{path: List<&2, U32>, size: Nat}

def col.f.le(a: ColF, b: ColF) -> Bool:
  match a b:
    case ColF{+p, s} ColF{+q, t}:
      col.le(p, q)

def col.f.of(fs: List<&2, List<&2, U32>>) -> List<&2, ColF>:
  match fs:
    case +p <> +z <> rest:
      [ColF{p, col.nat(z)}]
    case _:
      Nil{}

# find's `PATH TAB SIZE` lines
def col.fs.of(ls: List<&2, List<&2, U32>>) -> List<&2, ColF>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      List.append(&2, ColF, col.f.of(S.split(l, 9)), col.fs.of(more))

def col.vendored.names() -> List<&2, List<&2, U32>>:
  [S.b("vendor"), S.b("vendored"), S.b("third_party"), S.b("third-party"), S.b("node_modules"), S.b(".lake"),
   S.b("lake-packages"), S.b("_build"), S.b("dist-newstyle"), S.b(".stack-work"), S.b("_opam")]

def col.vendored.one(+c: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case +n <> more:
      Bool.or(S.eq(c, n), col.vendored.one(c, more))

def col.vendored.go(cs: List<&2, List<&2, U32>>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case c <> Nil{}:
      False{}
    case +c <> more:
      Bool.or(col.vendored.one(c, col.vendored.names()), col.vendored.go(more))

# a directory of the path is a vendored one: `(^|/)(vendor|...)/`
def col.vendored(+p: List<&2, U32>) -> Bool:
  col.vendored.go(S.split(p, 47))

def col.prefixed(+p: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +x <> more:
      Bool.or(S.prefix(p, x), col.prefixed(p, more))

# why a file is out: 0 kept, 1 excluded, 2 vendored, 3 generated name, 4 size
def col.why(+rule: Nat, +excl: List<&2, List<&2, U32>>, +big: Nat, +f: ColF) -> Nat:
  match f:
    case ColF{+p, +z}:
      Bool.pick(Nat, col.prefixed(p, excl), 1n,
        Bool.pick(Nat, Bool.or(col.vendored(p), Bool.and(Nat.is_eq(rule, 2n), S.prefix(p, S.b("vendor/")))), 2n,
          Bool.pick(Nat, S.infix(p, S.b("_generated")), 3n,
            Bool.pick(Nat, Bool.or(Bool.and(Nat.is_eq(rule, 1n), Nat.is_le(100000n, z)), Nat.is_lt(big, z)), 4n, 0n))))

type ColLs is Data:
  ColLs{kept: List<&2, List<&2, U32>>, ex: Nat, ve: Nat, ge: Nat, sz: Nat}

def col.ls.add(why: Nat, +line: List<&2, U32>, s: ColLs) -> ColLs:
  match why s:
    case 0n ColLs{k, a, b, g, z}:
      ColLs{line <> k, a, b, g, z}
    case 1n ColLs{k, a, b, g, z}:
      ColLs{k, 1n+a, b, g, z}
    case 2n ColLs{k, a, b, g, z}:
      ColLs{k, a, 1n+b, g, z}
    case 3n ColLs{k, a, b, g, z}:
      ColLs{k, a, b, 1n+g, z}
    case _ ColLs{k, a, b, g, z}:
      ColLs{k, a, b, g, 1n+z}

def col.f.path(+f: ColF) -> List<&2, U32>:
  match f:
    case ColF{p, z}:
      p

def col.ls.line(+file: List<&2, U32>, +id: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  L.v2.concat([file, p, [9], id, p])

def col.ls.go(fs: List<&2, ColF>, +rule: Nat, +excl: List<&2, List<&2, U32>>, +big: Nat, +file: List<&2, U32>, +id: List<&2, U32>, s: ColLs) -> ColLs:
  match fs:
    case Nil{}:
      s
    case +f <> more:
      col.ls.go(more, rule, excl, big, file, id, col.ls.add(col.why(rule, excl, big, f), col.ls.line(file, id, col.f.path(f)), s))

def col.count.line(+dir: List<&2, U32>, +why: String, +n: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(n, 0n), Nil{}, L.v2.concat([S.b("bend "), dir, [9], S.b(why), [9], S.b(Nat.show(n)), [10]]))

def col.ls.counts(+dir: List<&2, U32>, s: ColLs) -> List<&2, U32>:
  match s:
    case ColLs{k, a, b, g, z}:
      L.v2.concat([col.count.line(dir, "excluded", a), col.count.line(dir, "vendored", b), col.count.line(dir, "generated name", g), col.count.line(dir, "size", z)])

def col.ls.kept(s: ColLs) -> List<&2, List<&2, U32>>:
  match s:
    case ColLs{k, a, b, g, z}:
      List.reverse(&2, List<&2, U32>, k)

def col.order(bytes: Bool, fs: List<&2, ColF>) -> List<&2, ColF>:
  match bytes:
    case True{}:
      List.sort(~ColF, ~col.f.le, fs)
    case False{}:
      fs

# one repository's files: list.tsv lines and counts
def col.list.found(+c: ColCx, +r: ColRepo, +o: S.Out) -> IO(Unit):
  +dir = col.r.dir(r)
  +file = L.v2.concat([S.b(col.cx.src(c)), [47], dir, [47]])
  +id = L.v2.concat([S.b("repo:"), dir, [47]])
  +bytes = Bool.not(S.eq(col.cf.one(col.cx.cfg(c), "order", "bytes"), S.b("find")))
  +fs = col.order(bytes, col.fs.of(S.split.lines(S.Out.text(o))))
  +s = col.ls.go(fs, col.r.rule(r), col.r.excl(r), col.cf.nat(col.cx.cfg(c), "big", 1000000n), file, id, ColLs{Nil{}, 0n, 0n, 0n, 0n})
  do IO<Unit>:
    col.ok.if(U32.is_eq(S.Out.status(o), 0), "find in " ++ S.str(dir), o)
    S.add(col.st(c, "list.tsv"), col.unlines(col.ls.kept(s)))
    S.add(col.st(c, "list.counts"), col.ls.counts(dir, s))

def col.list.there(there: Bool, +c: ColCx, +r: ColRepo) -> IO(Unit):
  match there:
    case True{}:
      do IO<Unit>:
        +o : S.Out <- S.run(col.cx.src(c) ++ "/" ++ S.str(col.r.dir(r)), [], 600, "find", [".", "-path", "./.git", "-prune", "-o", "-type", "f", "-name", "*.bend", "-printf", "%P\\t%s\\n"], Nil{})
        col.list.found(c, r, o)
    case False{}:
      S.add(col.st(c, "list.counts"), L.v2.concat([S.b("missing "), col.r.dir(r), [10]]))

# a growth repository whose pin is still the known one has nothing new
def col.list.one(same: Bool, +c: ColCx, +r: ColRepo, +pin: List<&2, U32>) -> IO(Unit):
  match same:
    case True{}:
      S.add(col.st(c, "list.counts"), L.v2.concat([S.b("bend "), col.r.dir(r), S.b("\tunchanged since "), pin, [10]]))
    case False{}:
      do IO<Unit>:
        there : Bool <- S.exists(col.cx.src(c) ++ "/" ++ S.str(col.r.dir(r)))
        col.list.there(there, c, r)

def col.list.go(rs: List<&2, ColRepo>, +c: ColCx, +pins: List<&2, List<&2, U32>>, +known: List<&2, List<&2, U32>>) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> more:
      +pin = col.pin(pins, col.r.name(r))
      +old = col.pin(known, col.r.name(r))
      do IO<Unit>:
        col.list.one(Bool.and(Nat.is_eq(col.r.kind(r), 1n), Bool.and(Bool.not(Nat.is_eq(S.len(pin), 0n)), S.eq(pin, old))), c, r, pin)
        col.list.go(more, c, pins, known)

def col.list(+c: ColCx) -> IO(Unit):
  do IO<Unit>:
    +hub : List<&2, ColRepo> <- col.hub.repos(c)
    +rs : List<&2, ColRepo> = List.append(&2, ColRepo, col.repos(col.cx.cfg(c)), hub)
    S.mkdir(col.cx.out(c) ++ "/stage")
    S.write(col.st(c, "list.tsv"), Nil{})
    S.write(col.st(c, "list.counts"), Nil{})
    +pins : List<&2, List<&2, U32>> <- col.read.lines(col.cx.pins(c))
    +known : List<&2, List<&2, U32>> <- col.files.lines(col.cf.files(col.cx.cfg(c), "known"))
    col.list.go(rs, c, pins, known)
    +ls : List<&2, List<&2, U32>> <- col.read.lines(col.st(c, "list.tsv"))
    col.log("list: " ++ Nat.show(List.length(&2, List<&2, U32>, ls)) ++ " files from " ++ Nat.show(List.length(&2, ColRepo, rs)) ++ " repositories")

# Gate: copies of Base, then the loader ----------------------------------------------

type ColPair is Data:
  ColPair{file: List<&2, U32>, id: List<&2, U32>}

def col.pair.file(+p: ColPair) -> List<&2, U32>:
  match p:
    case ColPair{f, i}:
      f

def col.pair.id(+p: ColPair) -> List<&2, U32>:
  match p:
    case ColPair{f, i}:
      i

def col.pairs.go(ls: List<&2, List<&2, U32>>) -> List<&2, ColPair>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      List.append(&2, ColPair, Bool.pick(List<&2, ColPair>, Nat.is_eq(S.len(l), 0n), Nil{}, [ColPair{L.v2.before(l, 9), L.v2.after(l, 9)}]), col.pairs.go(more))

def col.read.pairs(+path: String) -> IO(List<&2, ColPair>):
  do IO<List<&2, ColPair>>:
    +ls : List<&2, List<&2, U32>> <- col.read.lines(path)
    return col.pairs.go(ls)

def col.pair.line(+p: ColPair) -> List<&2, U32>:
  L.v2.concat([col.pair.file(p), [9], col.pair.id(p)])

def col.pairs.lines(ps: List<&2, ColPair>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      col.pair.line(p) <> col.pairs.lines(more)

# the first 4 lines as `$(head -4 f)` gives them
def col.head4(+xs: List<&2, U32>) -> List<&2, U32>:
  S.chomp(S.lines.take(xs, 4n))

def col.base.read(look: Bool, +h: List<&2, U32>, +f: String) -> IO(Bool):
  match look:
    case True{}:
      do IO<Bool>:
        +xs : List<&2, U32> <- S.read(f)
        return S.eq(col.head4(xs), h)
    case False{}:
      IO.pure(Bool, False{})

# is the file a copy of Base: a base.bend, not the upstream's, whose head is Base's
def col.base.is(+on: Bool, +h: List<&2, U32>, +up: List<&2, U32>, +p: ColPair) -> IO(Bool):
  +f = S.str(col.pair.file(p))
  col.base.read(Bool.and(on, Bool.and(String.eq(S.base(f), "base.bend"), Bool.not(S.prefix(col.pair.id(p), up)))), h, f)

def col.base.note(copy: Bool, +c: ColCx, +p: ColPair) -> IO(Unit):
  match copy:
    case True{}:
      S.add(col.st(c, "bend.counts"), L.v2.concat([S.b("bend vendored Base copy\t"), col.pair.id(p), [10]]))
    case False{}:
      IO.pure(Unit, Unit{})

def col.base.keep(copy: Bool, p: ColPair, rest: List<&2, ColPair>) -> List<&2, ColPair>:
  match copy:
    case True{}:
      rest
    case False{}:
      p <> rest

# the files less the copies of Base (each noted in bend.counts, in the list's order)
def col.base.go(ps: List<&2, ColPair>, +c: ColCx, +on: Bool, +h: List<&2, U32>, +up: List<&2, U32>) -> IO(List<&2, ColPair>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, ColPair>, Nil{})
    case +p <> more:
      do IO<List<&2, ColPair>>:
        +copy : Bool <- col.base.is(on, h, up, p)
        col.base.note(copy, c, p)
        +rest : List<&2, ColPair> <- col.base.go(more, c, on, h, up)
        return col.base.keep(copy, p, rest)

def col.up.head.of(on: Bool, +b2: String, +pin: String) -> IO(List<&2, U32>):
  match on:
    case True{}:
      do IO<List<&2, U32>>:
        +xs : List<&2, U32> <- col.git(b2, ["show", pin ++ ":bend2/base.bend"])
        return col.head4(xs)
    case False{}:
      IO.pure(List<&2, U32>, Nil{})

def col.loader.job(+c: ColCx, +loader: String, +secs: U32, ps: List<&2, ColPair>, +k: Nat) -> List<&2, ColJob>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      +f = S.str(col.pair.file(p))
      ColJob{k, 1n, [ColCmd{S.parent(f), ["LC_ALL=C"], secs, loader, [S.base(f), "--check-only"], ""}]} <> col.loader.job(c, loader, secs, more, 1n+k)

def col.check.rows(ps: List<&2, ColPair>, rs: List<&2, ColRes>) -> List<&2, List<&2, U32>>:
  match ps rs:
    case +p <> more +r <> rt:
      L.v2.concat([col.pair.file(p), [9], col.res.text(r)]) <> col.check.rows(more, rt)
    case _ _:
      Nil{}

def col.load.is(+v: List<&2, U32>) -> Bool:
  S.prefix(v, S.b("load\t"))

def col.check.kept(ps: List<&2, ColPair>, rs: List<&2, ColRes>) -> List<&2, ColPair>:
  match ps rs:
    case +p <> more +r <> rt:
      List.append(&2, ColPair, Bool.pick(List<&2, ColPair>, col.load.is(col.res.text(r)), Nil{}, [p]), col.check.kept(more, rt))
    case _ _:
      Nil{}

def col.class.n(rs: List<&2, ColRes>, +cls: List<&2, U32>) -> Nat:
  match rs:
    case Nil{}:
      0n
    case +r <> more:
      Nat.add(col.b2n(S.prefix(col.res.text(r), S.append(cls, [9]))), col.class.n(more, cls))

def col.class.line(+cls: String, +n: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(n, 0n), Nil{}, S.b("bend check " ++ cls ++ "\t" ++ Nat.show(n) ++ "\n"))

def col.class.lines(+rs: List<&2, ColRes>) -> List<&2, U32>:
  L.v2.concat([col.class.line("checked", col.class.n(rs, S.b("checked"))), col.class.line("load", col.class.n(rs, S.b("load"))),
    col.class.line("pass", col.class.n(rs, S.b("pass"))), col.class.line("timeout", col.class.n(rs, S.b("timeout")))])

def col.up.dir(rs: List<&2, ColRepo>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      col.r.dir(r)

def col.up.name(rs: List<&2, ColRepo>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      col.r.name(r)

# Recorded verdicts (`verdicts FILE [CLASS...]`): an earlier bend.check.tsv's rows, those
# of the classes named (all when none), taken for the same file instead of a loader run.
# A replay over the same clones names its run's timeouts: a timeout is the clock's
# verdict (how loaded the machine was), not the file's.
def col.vm.put(take: Bool, m: Map<&2, List<&2, U32>>, +key: String, +v: List<&2, U32>) -> Map<&2, List<&2, U32>>:
  match take:
    case True{}:
      Map.set(&2, List<&2, U32>, m, key, v)
    case False{}:
      m

def col.vm.rows(ls: List<&2, List<&2, U32>>, +cls: Set(), +all: Bool, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      m
    case +l <> more:
      +v = L.v2.after(l, 9)
      +take = Bool.and(Bool.not(Nat.is_eq(S.len(v), 0n)), Bool.or(all, col.in(cls, L.v2.before(v, 9))))
      col.vm.rows(more, cls, all, col.vm.put(take, m, col.k(L.v2.before(l, 9)), v))

def col.vm.load(xss: ColCfg(), m: Map<&2, List<&2, U32>>) -> IO(Map<&2, List<&2, U32>>):
  match xss:
    case Nil{}:
      IO.pure(Map<&2, List<&2, U32>>, m)
    case +ws <> more:
      do IO<Map<&2, List<&2, U32>>>:
        +ls : List<&2, List<&2, U32>> <- col.read.lines(S.str(col.cf.head(ws, Nil{})))
        +cls : List<&2, List<&2, U32>> = List.drop(&2, List<&2, U32>, ws, 1n)
        col.vm.load(more, col.vm.rows(ls, col.set(cls), Nat.is_eq(List.length(&2, List<&2, U32>, cls), 0n), m))

# each file's recorded verdict (Nil: none)
def col.vs.of(ps: List<&2, ColPair>, +m: Map<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      Ho.ho.snd.l(Map.get(List<&2, U32>, Nil{}, m, col.k(col.pair.file(p)))) <> col.vs.of(more, m)

# the files without one: the loader's
def col.misses(ps: List<&2, ColPair>, vs: List<&2, List<&2, U32>>) -> List<&2, ColPair>:
  match ps vs:
    case +p <> more Con{Nil{}, vt}:
      p <> col.misses(more, vt)
    case p <> more Con{Con{h, t}, vt}:
      col.misses(more, vt)
    case _ _:
      Nil{}

# the verdicts in the files' order: the recorded one, else the loader's next
def col.merge(vs: List<&2, List<&2, U32>>, rs: List<&2, ColRes>, +i: Nat) -> List<&2, ColRes>:
  match vs rs:
    case Con{Con{h, t}, more} rs2:
      ColRes{i, 0, h <> t} <> col.merge(more, rs2, 1n+i)
    case Con{Nil{}, more} Con{r, rt}:
      r <> col.merge(more, rt, 1n+i)
    case _ _:
      Nil{}

def col.gate.bend(+c: ColCx) -> IO(Unit):
  +cfg = col.cx.cfg(c)
  +ups = col.up(cfg)
  +on = Bool.not(Nat.is_eq(List.length(&2, ColRepo, ups), 0n))
  +updir = col.up.dir(ups)
  +loader = col.cf.str(cfg, "loader", "bend")
  +secs = U32.from_nat(col.cf.nat(cfg, "loader-secs", 60n))
  do IO<Unit>:
    +lc : List<&2, U32> <- S.read(col.st(c, "list.counts"))
    S.write(col.st(c, "bend.counts"), lc)
    +ps : List<&2, ColPair> <- col.read.pairs(col.st(c, "list.tsv"))
    +pins : List<&2, List<&2, U32>> <- col.read.lines(col.cx.pins(c))
    +pin : String = S.str(col.pin(pins, col.up.name(ups)))
    +h : List<&2, U32> <- col.up.head.of(on, col.cx.bend2(c), pin)
    +qs : List<&2, ColPair> <- col.base.go(ps, c, on, h, L.v2.concat([S.b("repo:"), updir, [47]]))
    +vm : Map<&2, List<&2, U32>> <- col.vm.load(col.cf.args(cfg, S.b("verdicts")), Map.new(&2, List<&2, U32>))
    +vs : List<&2, List<&2, U32>> = col.vs.of(qs, vm)
    +miss : List<&2, ColPair> = col.misses(qs, vs)
    col.log("gate-bend: " ++ Nat.show(Nat.sub(List.length(&2, ColPair, ps), List.length(&2, ColPair, qs))) ++ " copies of Base out; " ++ Nat.show(Nat.sub(List.length(&2, ColPair, qs), List.length(&2, ColPair, miss))) ++ " recorded verdicts; the loader (" ++ loader ++ ", " ++ U32.show(secs) ++ " s) on " ++ Nat.show(List.length(&2, ColPair, miss)) ++ " files, " ++ Nat.show(col.cx.procs(c)) ++ " at once")
    +rs0 : List<&2, ColRes> <- col.pool("gate-bend", col.cx.procs(c), col.loader.job(c, loader, secs, miss, 0n))
    +rs : List<&2, ColRes> = col.merge(vs, rs0, 0n)
    S.write(col.st(c, "bend.check.u"), col.unlines(col.check.rows(qs, rs)))
    col.sortf(col.cx.out(c) ++ "/stage", ["-t", "\t", "-k1,1"], col.st(c, "bend.check.tsv"), [col.st(c, "bend.check.u")])
    S.rm(col.st(c, "bend.check.u"))
    S.add(col.st(c, "bend.counts"), col.class.lines(rs))
    +ok : List<&2, ColPair> = col.check.kept(qs, rs)
    S.write(col.st(c, "bend.ok.tsv"), col.unlines(col.pairs.lines(ok)))
    col.log("gate-bend: " ++ Nat.show(List.length(&2, ColPair, ok)) ++ " kept, " ++ Nat.show(col.class.n(rs, S.b("load"))) ++ " the loader rejects")

# Nul: NUL bytes, invalid UTF-8, then JSON lines -------------------------------------

def col.iconv.jobs(ps: List<&2, ColPair>, +k: Nat) -> List<&2, ColJob>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      ColJob{k, 0n, [ColCmd{".", Nil{}, 600, "iconv", ["-f", "UTF-8", "-t", "UTF-8", S.str(col.pair.file(p))], "/dev/null"}]} <> col.iconv.jobs(more, 1n+k)

def col.nul.at(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      U32.is_eq(h, 0)

def col.has.nul.go(xs: List<&2, U32>, at: Bool) -> Bool:
  match xs at:
    case _ True{}:
      True{}
    case Nil{} False{}:
      False{}
    case h <> +t False{}:
      col.has.nul.go(t, col.nul.at(t))

# a NUL byte in xs (`grep -lPa '\x00'`)
def col.has.nul(+xs: List<&2, U32>) -> Bool:
  col.has.nul.go(xs, col.nul.at(xs))

type ColNs is Type:
  ColNs{o: File, nul: Nat, utf: Nat, kept: Nat}

def col.ns.put(why: Nat, +p: ColPair, +xs: List<&2, U32>, s: ColNs) -> IO(ColNs):
  match why s:
    case 1n ColNs{o, n, u, k}:
      IO.pure(ColNs, ColNs{o, 1n+n, u, k})
    case 2n ColNs{o, n, u, k}:
      IO.pure(ColNs, ColNs{o, n, 1n+u, k})
    case _ ColNs{o, n, u, k}:
      do IO<ColNs>:
        o2 : File <- S.emit(o, L.v2.py.line(St.st.u8.fix(col.pair.id(p)), St.st.u8.fix(xs)))
        return ColNs{o2, n, u, 1n+k}

def col.ns.go(ps: List<&2, ColPair>, rs: List<&2, ColRes>, s: ColNs) -> IO(ColNs):
  match ps rs:
    case +p <> more +r <> rt:
      do IO<ColNs>:
        +xs : List<&2, U32> <- S.read(S.str(col.pair.file(p)))
        +why : Nat = Bool.pick(Nat, col.has.nul(xs), 1n, Bool.pick(Nat, U32.is_eq(col.res.status(r), 0), 0n, 2n))
        s2 : ColNs <- col.ns.put(why, p, xs, s)
        col.ns.go(more, rt, s2)
    case _ _:
      IO.pure(ColNs, s)

def col.count.kv(+what: String, +n: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(n, 0n), Nil{}, S.b(what ++ "\t" ++ Nat.show(n) ++ "\n"))

def col.ns.fin(+c: ColCx, s: ColNs) -> IO(Unit):
  match s:
    case ColNs{o, +n, +u, +k}:
      do IO<Unit>:
        File.close(o)
        S.write(col.st(c, "in/bend.counts"), L.v2.concat([col.count.kv("NUL bytes", n), col.count.kv("invalid UTF-8", u), S.b("kept\t" ++ Nat.show(k) ++ "\n")]))
        col.log("nul: " ++ Nat.show(k) ++ " records; NUL bytes " ++ Nat.show(n) ++ ", invalid UTF-8 " ++ Nat.show(u))

def col.nul(+c: ColCx) -> IO(Unit):
  do IO<Unit>:
    +ps : List<&2, ColPair> <- col.read.pairs(col.st(c, "bend.ok.tsv"))
    S.mkdir(col.st(c, "in"))
    +rs : List<&2, ColRes> <- col.pool("nul: iconv", col.cx.procs(c), col.iconv.jobs(ps, 0n))
    o : File <- IO.try(File, File.open(col.st(c, "in/bend.jsonl"), "w"))
    s : ColNs <- col.ns.go(ps, rs, ColNs{o, 0n, 0n, 0n})
    col.ns.fin(c, s)

# Keys -----------------------------------------------------------------------------------
#
# A file's keys: `keys` on N pieces (`split -n l/K/N`, a JSONL file) or whole (a NUL
# file), concatenated in order.  The corpus's are cached by the file's `size mtime`.

def col.pieces(+jsonl: Bool, +size: Nat) -> Nat:
  Bool.pick(Nat, jsonl, Nat.max(1n, Nat.div(Nat.add(size, 63999999n), 64000000n)), 1n)

# (a piece keeps the .jsonl suffix: `keys` reads a file by it)
def col.piece.cmds(+self: String, +f: String, +tmp: String, +k: Nat, +n: Nat, +jsonl: Bool) -> List<&2, ColCmd>:
  +piece = tmp ++ "." ++ Nat.show(k) ++ ".jsonl"
  +keys = tmp ++ "." ++ Nat.show(k) ++ ".keys"
  Bool.pick(List<&2, ColCmd>, jsonl,
    [ColCmd{".", Nil{}, 86400, "split", ["-n", "l/" ++ Nat.show(k) ++ "/" ++ Nat.show(n), f], piece},
     ColCmd{".", Nil{}, 86400, self, ["keys", piece], keys},
     ColCmd{".", Nil{}, 600, "rm", ["-f", piece], ""}],
    [ColCmd{".", Nil{}, 86400, self, ["keys", f], keys}])

# the pieces' jobs, numbered from j
def col.piece.jobs(r: Nat, +self: String, +f: String, +tmp: String, +n: Nat, +jsonl: Bool, +j: Nat) -> List<&2, ColJob>:
  match r:
    case 0n:
      Nil{}
    case 1n+(+q):
      +k = Nat.sub(n, q)
      ColJob{Nat.add(j, k), 0n, col.piece.cmds(self, f, tmp, k, n, jsonl)} <> col.piece.jobs(q, self, f, tmp, n, jsonl, j)

def col.piece.names(r: Nat, +tmp: String, +n: Nat) -> List<&2, String>:
  match r:
    case 0n:
      Nil{}
    case 1n+(+q):
      (tmp ++ "." ++ Nat.show(Nat.sub(n, q)) ++ ".keys") <> col.piece.names(q, tmp, n)

# A file to key: its path, where its keys go, its pieces' prefix and count
type ColKf is Data:
  ColKf{f: String, keys: String, tmp: String, n: Nat, jsonl: Bool, stamp: List<&2, U32>}

def col.kf.jobs(ks: List<&2, ColKf>, +self: String, +j: Nat) -> List<&2, ColJob>:
  match ks:
    case Nil{}:
      Nil{}
    case ColKf{+f, k, +tmp, +n, +jsonl, s} <> more:
      List.append(&2, ColJob, col.piece.jobs(n, self, f, tmp, n, jsonl, j), col.kf.jobs(more, self, Nat.add(j, n)))

def col.kf.cat(ks: List<&2, ColKf>) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case ColKf{f, +k, +tmp, +n, jsonl, +s} <> more:
      +ps = col.piece.names(n, tmp, n)
      do IO<Unit>:
        col.to("cat into " ++ k, "cat", ps, k ++ ".tmp")
        S.mv(k ++ ".tmp", k)
        +o : List<&2, U32> <- col.must("rm pieces", "rm", "-f" <> ps)
        S.write(k ++ ".stamp", s)
        col.kf.cat(more)

# key the files (the pool), each into its keys file
def col.kf.run(+what: String, +c: ColCx, ks: List<&2, ColKf>) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +k <> +more:
      do IO<Unit>:
        col.pool.ok(what, col.cx.procs(c), col.kf.jobs(k <> more, col.cx.self(c), 0n))
        col.kf.cat(k <> more)

def col.stamp(+f: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    +o : List<&2, U32> <- col.must("stat " ++ f, "stat", ["-L", "-c", "%s %Y", f])
    return S.chomp(o)

# the cache's base name of a corpus file: c.<path, / as _>
def col.cache.base(+kc: String, +f: String) -> String:
  kc ++ "/c." ++ S.str(S.replace(S.b(f), [47], [95]))

def col.kf.of(+kc: String, +f: String) -> IO(ColKf):
  +base = col.cache.base(kc, f)
  do IO<ColKf>:
    +s : List<&2, U32> <- col.stamp(f)
    return ColKf{f, base ++ ".keys", base ++ ".piece", col.pieces(S.suffix(S.b(f), S.b(".jsonl")), col.nat(L.v2.before(s, 32))), S.suffix(S.b(f), S.b(".jsonl")), s}

def col.kf.stale(+k: ColKf) -> IO(Bool):
  match k:
    case ColKf{f, +keys, tmp, n, j, +s}:
      do IO<Bool>:
        +old : List<&2, U32> <- S.read(keys ++ ".stamp")
        there : Bool <- S.exists(keys)
        return Bool.not(Bool.and(there, S.eq(old, s)))

def col.kf.keep(stale: Bool, +k: ColKf, rest: List<&2, ColKf>) -> List<&2, ColKf>:
  match stale:
    case True{}:
      k <> rest
    case False{}:
      rest

def col.kf.all(fs: List<&2, String>, +kc: String) -> IO(List<&2, ColKf>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, ColKf>, Nil{})
    case +f <> more:
      do IO<List<&2, ColKf>>:
        k : ColKf <- col.kf.of(kc, f)
        +rest : List<&2, ColKf> <- col.kf.all(more, kc)
        return k <> rest

def col.kf.stales(ks: List<&2, ColKf>) -> IO(List<&2, ColKf>):
  match ks:
    case Nil{}:
      IO.pure(List<&2, ColKf>, Nil{})
    case +k <> more:
      do IO<List<&2, ColKf>>:
        st : Bool <- col.kf.stale(k)
        +rest : List<&2, ColKf> <- col.kf.stales(more)
        return col.kf.keep(st, k, rest)

def col.kf.keys(ks: List<&2, ColKf>) -> List<&2, String>:
  match ks:
    case Nil{}:
      Nil{}
    case ColKf{f, k, t, n, j, s} <> more:
      k <> col.kf.keys(more)

# a projection of a keys file: KEYS.paths, KEYS.sha, KEYS.ids (`collect --project`),
# made again when KEYS.pstamp is not the file's stamp
def col.pj.jobs(ks: List<&2, ColKf>, +self: String, +n: Nat) -> List<&2, ColJob>:
  match ks:
    case Nil{}:
      Nil{}
    case ColKf{f, +k, t, z, j, s} <> more:
      ColJob{n, 0n, [ColCmd{".", Nil{}, 86400, self, ["collect", "--project", k, k], ""}]} <> col.pj.jobs(more, self, 1n+n)

def col.pj.stale(+k: ColKf) -> IO(Bool):
  match k:
    case ColKf{f, +keys, tmp, n, j, +s}:
      do IO<Bool>:
        +old : List<&2, U32> <- S.read(keys ++ ".pstamp")
        return Bool.not(S.eq(old, s))

def col.pj.stales(ks: List<&2, ColKf>) -> IO(List<&2, ColKf>):
  match ks:
    case Nil{}:
      IO.pure(List<&2, ColKf>, Nil{})
    case +k <> more:
      do IO<List<&2, ColKf>>:
        st : Bool <- col.pj.stale(k)
        +rest : List<&2, ColKf> <- col.pj.stales(more)
        return col.kf.keep(st, k, rest)

def col.pj.done(ks: List<&2, ColKf>) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case ColKf{f, k, t, n, j, s} <> more:
      do IO<Unit>:
        S.write(k ++ ".pstamp", s)
        col.pj.done(more)

def col.with(ks: List<&2, String>, +ext: String) -> List<&2, String>:
  match ks:
    case Nil{}:
      Nil{}
    case k <> more:
      (k ++ ext) <> col.with(more, ext)

def col.keys(+c: ColCx) -> IO(Unit):
  +kd = col.st(c, "keys")
  +kc = col.cx.str(c, "keycache", kd ++ "/cache")
  +fs = col.cf.files(col.cx.cfg(c), "corpus")
  do IO<Unit>:
    S.mkdir(kd)
    S.mkdir(kc)
    +all : List<&2, ColKf> <- col.kf.all(fs, kc)
    +stale : List<&2, ColKf> <- col.kf.stales(all)
    col.log("keys: " ++ Nat.show(List.length(&2, String, fs)) ++ " corpus files, " ++ Nat.show(List.length(&2, ColKf, stale)) ++ " to key (the rest cached in " ++ kc ++ ")")
    col.kf.run("keys: the corpus", c, stale)
    +pstale : List<&2, ColKf> <- col.pj.stales(all)
    col.log("keys: the corpus's paths, content keys and ids (" ++ Nat.show(List.length(&2, ColKf, pstale)) ++ " projections to make)")
    col.pool.ok("keys: projections", col.cx.procs(c), col.pj.jobs(pstale, col.cx.self(c), 0n))
    col.pj.done(pstale)
    col.sortf(kd, ["-u"], kd ++ "/corpus.paths", col.with(col.kf.keys(all), ".paths"))
    col.sortf(kd, ["-u"], kd ++ "/corpus.sha", col.with(col.kf.keys(all), ".sha"))
    col.sortf(kd, ["-u"], kd ++ "/corpus.ids", col.with(col.kf.keys(all), ".ids"))
    +s : List<&2, U32> <- col.stamp(col.st(c, "in/bend.jsonl"))
    col.log("keys: the new records")
    col.kf.run("keys: the new records", c, [ColKf{col.st(c, "in/bend.jsonl"), kd ++ "/bend.keys", kd ++ "/bend.piece", col.pieces(True{}, col.nat(L.v2.before(s, 32))), True{}, s}])
    +a : Nat <- col.wc(col.st(c, "in/bend.jsonl"))
    +b : Nat <- col.wc(kd ++ "/bend.keys")
    col.ok.if(Nat.is_eq(a, b), "keys: the new records' keys are misaligned", S.Out{1, Nil{}})
    col.log("keys: " ++ Nat.show(b) ++ " new records keyed")

# --project KEYS BASE: the 4-field lines' `repository TAB path`, key and id
type ColPj is Type:
  ColPj{r: S.Rd, p: File, k: File, i: File, go: Bool}

def col.pj.rec(fs: List<&2, List<&2, U32>>, p: File, k: File, i: File) -> IO(File & (File & File)):
  match fs:
    case +id <> +repo <> +path <> +key <> Nil{}:
      do IO<File & (File & File)>:
        p2 : File <- S.emit(p, L.v2.concat([repo, [9], path, [10]]))
        k2 : File <- S.emit(k, S.append(key, [10]))
        i2 : File <- S.emit(i, S.append(id, [10]))
        return (p2, (k2, i2))
    case _:
      IO.pure(File & (File & File), (p, (k, i)))

def col.pj.fin3(r: S.Rd, x: File & (File & File)) -> IO(ColPj):
  (p, ki) = x
  (k, i) = ki
  IO.pure(ColPj, ColPj{r, p, k, i, True{}})

def col.pj.line(r: S.Rd, p: File, k: File, i: File, m: Maybe<&2, List<&2, U32>>) -> IO(ColPj):
  match m:
    case None{}:
      IO.pure(ColPj, ColPj{r, p, k, i, False{}})
    case Some{+l}:
      IO.bind(File & (File & File), ColPj, col.pj.rec(S.split(l, 9), p, k, i), col.pj.fin3(r))

def col.pj.got(p: File, k: File, i: File, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(ColPj):
  (r, m) = x
  col.pj.line(r, p, k, i, m)

def col.pj.step(s: ColPj) -> IO(ColPj):
  match s:
    case ColPj{r, p, k, i, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, ColPj, S.Rd.next(r), col.pj.got(p, k, i))

def col.pj.go(fuel: Nat, s: ColPj) -> IO(ColPj):
  match fuel s:
    case 1n+f ColPj{r, p, k, i, True{}}:
      IO.bind(ColPj, ColPj, col.pj.step(ColPj{r, p, k, i, True{}}), col.pj.go(f))
    case _ s2:
      IO.pure(ColPj, s2)

def col.pj.fin(s: ColPj) -> IO(Unit):
  match s:
    case ColPj{r, p, k, i, g}:
      do IO<Unit>:
        S.Rd.close(r)
        File.close(p)
        File.close(k)
        File.close(i)

def col.project(+keys: String, +base: String) -> IO(Unit):
  do IO<Unit>:
    r : S.Rd <- S.Rd.lines(keys)
    p : File <- IO.try(File, File.open(base ++ ".paths", "w"))
    k : File <- IO.try(File, File.open(base ++ ".sha", "w"))
    i : File <- IO.try(File, File.open(base ++ ".ids", "w"))
    s : ColPj <- col.pj.go(col.fuel(), ColPj{r, p, k, i, True{}})
    col.pj.fin(s)

# Pre: C3, the vault, each record routed -------------------------------------------------

# a keys line: repository, path, content key (ok: it has the 4 fields)
type ColK is Data:
  ColK{ok: Bool, repo: List<&2, U32>, path: List<&2, U32>, key: List<&2, U32>}

def col.k.of(fs: List<&2, List<&2, U32>>) -> ColK:
  match fs:
    case id <> repo <> path <> key <> Nil{}:
      ColK{True{}, repo, path, key}
    case _:
      ColK{False{}, Nil{}, Nil{}, Nil{}}

def col.ks.of(ls: List<&2, List<&2, U32>>) -> List<&2, ColK>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      col.k.of(S.split(l, 9)) <> col.ks.of(more)

def col.k.rp(+repo: List<&2, U32>, +path: List<&2, U32>) -> List<&2, U32>:
  L.v2.concat([repo, [9], path])

# what each record gives (records without the 4 fields give nothing): 0 repository
# TAB path, 1 repository, 2 content key
def col.k.field(ks: List<&2, ColK>, +w: Nat) -> List<&2, List<&2, U32>>:
  match ks:
    case Nil{}:
      Nil{}
    case ColK{True{}, +r, +p, +k} <> more:
      Bool.pick(List<&2, U32>, Nat.is_eq(w, 0n), col.k.rp(r, p), Bool.pick(List<&2, U32>, Nat.is_eq(w, 1n), r, k)) <> col.k.field(more, w)
    case ColK{False{}, r, p, k} <> more:
      col.k.field(more, w)

# Runs of a sorted list's first fields: each name and how many lines it has
type ColRn is Data:
  ColRn{name: List<&2, U32>, n: Nat}

def col.rn.name(+x: ColRn) -> List<&2, U32>:
  match x:
    case ColRn{a, n}:
      a

def col.rn.n(+x: ColRn) -> Nat:
  match x:
    case ColRn{a, n}:
      n

def col.rn.put(+cur: List<&2, U32>, +n: Nat, +acc: List<&2, ColRn>) -> List<&2, ColRn>:
  Bool.pick(List<&2, ColRn>, Nat.is_eq(n, 0n), acc, ColRn{cur, n} <> acc)

def col.rn.same(+ls: List<&2, List<&2, U32>>, +cur: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      S.eq(L.v2.before(l, 9), cur)

def col.rn.go(ls: List<&2, List<&2, U32>>, same: Bool, +cur: List<&2, U32>, +n: Nat, acc: List<&2, ColRn>) -> List<&2, ColRn>:
  match ls same:
    case Nil{} _:
      List.reverse(&2, ColRn, col.rn.put(cur, n, acc))
    case l <> +more True{}:
      col.rn.go(more, col.rn.same(more, cur), cur, 1n+n, acc)
    case +l <> +more False{}:
      +r = L.v2.before(l, 9)
      col.rn.go(more, col.rn.same(more, r), r, 1n, col.rn.put(cur, n, acc))

def col.runs(+ls: List<&2, List<&2, U32>>) -> List<&2, ColRn>:
  col.rn.go(ls, False{}, Nil{}, 0n, Nil{})

def col.rn.names(xs: List<&2, ColRn>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      col.rn.name(x) <> col.rn.names(more)

def col.rn.over(xs: List<&2, ColRn>, +min: Nat) -> List<&2, ColRn>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      List.append(&2, ColRn, Bool.pick(List<&2, ColRn>, Nat.is_le(min, col.rn.n(x)), [x], Nil{}), col.rn.over(more, min))

def col.rn.lines(xs: List<&2, ColRn>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      L.v2.concat([col.rn.name(x), [9], S.b(Nat.show(col.rn.n(x)))]) <> col.rn.lines(more)

def col.keep.in(xs: List<&2, List<&2, U32>>, +s: Set(), +want: Bool) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, Bool.not(Bool.xor(col.in(s, x), want)), [x], Nil{}), col.keep.in(more, s, want))

def col.firsts(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      L.v2.before(x, 9) <> col.firsts(more)

def col.growth.names(rs: List<&2, ColRepo>) -> List<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(col.r.kind(r), 1n), [col.r.fold(r)], Nil{}), col.growth.names(more))

# the unit a file belongs to: a big repository's directory, else the repository
def col.unit(+bigs: Set(), +repo: List<&2, U32>, +path: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, col.in(bigs, repo), L.v2.concat([repo, [47], L.v2.parent(path, 47)]), repo)

def col.units(ls: List<&2, List<&2, U32>>, +bigs: Set()) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      col.unit(bigs, L.v2.before(l, 9), L.v2.after(l, 9)) <> col.units(more, bigs)

def col.held(us: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.filter(~List<&2, U32>, ~(u => Ho.ho.held(u)), us)

# the quoted strings of stream-index.json (grep -o '"[^"]*"'): the odd pieces between quotes
def col.quoted(ps: List<&2, List<&2, U32>>, odd: Bool) -> List<&2, List<&2, U32>>:
  match ps odd:
    case Nil{} _:
      Nil{}
    case p <> more True{}:
      p <> col.quoted(more, False{})
    case p <> more False{}:
      col.quoted(more, True{})

def col.hashed(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      L.v2.concat([S.b(H.sha256(x)), [9], x]) <> col.hashed(more)

def col.vault.n(+mode: List<&2, U32>, +n: Nat) -> Nat:
  Bool.pick(Nat, S.eq(mode, S.b("none")), 0n, Nat.div(Nat.add(n, 3n), 4n))

# the records' keys whose unit is held or whose repository goes to the vault
def col.routed(ks: List<&2, ColK>, +bigs: Set(), +held: Set(), +vr: Set()) -> List<&2, List<&2, U32>>:
  match ks:
    case Nil{}:
      Nil{}
    case ColK{True{}, +r, +p, +k} <> more:
      List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, Bool.or(col.in(held, col.unit(bigs, r, p)), col.in(vr, r)), [k], Nil{}), col.routed(more, bigs, held, vr))
    case ColK{False{}, r, p, k} <> more:
      col.routed(more, bigs, held, vr)

# the repositories of the records whose path and key the corpus lacks
def col.k.fresh(ks: List<&2, ColK>, +inp: Set(), +ins: Set()) -> List<&2, List<&2, U32>>:
  match ks:
    case Nil{}:
      Nil{}
    case ColK{True{}, +r, +p, +k} <> more:
      List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, Bool.or(col.in(inp, col.k.rp(r, p)), col.in(ins, k)), Nil{}, [r]), col.k.fresh(more, inp, ins))
    case ColK{False{}, r, p, k} <> more:
      col.k.fresh(more, inp, ins)

def col.up.fold(rs: List<&2, ColRepo>) -> List<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      [col.r.fold(r)]

def col.after.tabs(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      L.v2.after(x, 9) <> col.after.tabs(more)

# The sets the routing reads
type ColSets is Data:
  ColSets{bigs: Set(), inp: Set(), ins: Set(), held: Set(), vr: Set(), routed: Set()}

# a record's fate, the reasons in their sorted order: 0 a key a held-out or vault
# record has, 1 a content key the corpus has, 2 held out, 3 not a record, 4 a path the
# corpus has, 5 train, 6 vault
def col.fate(+z: ColSets, +k: ColK) -> Nat:
  match z k:
    case ColSets{+bigs, +inp, +ins, +held, +vr, +routed} ColK{+ok, +r, +p, +key}:
      Bool.pick(Nat, Bool.not(ok), 3n,
        Bool.pick(Nat, col.in(inp, col.k.rp(r, p)), 4n,
          Bool.pick(Nat, col.in(ins, key), 1n,
            Bool.pick(Nat, col.in(held, col.unit(bigs, r, p)), 2n,
              Bool.pick(Nat, col.in(vr, r), 6n,
                Bool.pick(Nat, col.in(routed, key), 0n, 5n))))))

def col.reason(n: Nat) -> String:
  match n:
    case 0n:
      "copy of a held-out or vault file"
    case 1n:
      "copy of the corpus"
    case 2n:
      "held out (C3 rule, new unit)"
    case 3n:
      "not a record"
    case 4n:
      "path in the corpus"
    case 5n:
      "train"
    case _:
      "vault"

type ColRt is Type:
  ColRt{r: S.Rd, t: File, h: File, v: File, cnt: List<&2, Nat>}

def col.rt.emit(why: Nat, t: File, h: File, v: File, +line: List<&2, U32>) -> IO(File & (File & File)):
  match why:
    case 5n:
      do IO<File & (File & File)>:
        t2 : File <- S.emit(t, line)
        return (t2, (h, v))
    case 2n:
      do IO<File & (File & File)>:
        h2 : File <- S.emit(h, line)
        return (t, (h2, v))
    case 6n:
      do IO<File & (File & File)>:
        v2 : File <- S.emit(v, line)
        return (t, (h, v2))
    case _:
      IO.pure(File & (File & File), (t, (h, v)))

def col.rt.fin3(r: S.Rd, +cnt: List<&2, Nat>, x: File & (File & File)) -> IO(ColRt):
  (t, hv) = x
  (h, v) = hv
  IO.pure(ColRt, ColRt{r, t, h, v, cnt})

def col.rt.line(+z: ColSets, +k: ColK, s: ColRt, m: Maybe<&2, List<&2, U32>>) -> IO(ColRt):
  match s m:
    case ColRt{r, t, h, v, cnt} Some{+l}:
      +why = col.fate(z, k)
      IO.bind(File & (File & File), ColRt, col.rt.emit(why, t, h, v, S.append(l, [10])), col.rt.fin3(r, R.rw.bump(cnt, why)))
    case ColRt{r, t, h, v, cnt} None{}:
      do IO<ColRt>:
        S.Rd.close(r)
        File.close(t)
        File.close(h)
        File.close(v)
        IO.die(ColRt, 1, "collect: pre: the records end before their keys")

def col.rt.got(+z: ColSets, +k: ColK, t: File, h: File, v: File, +cnt: List<&2, Nat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(ColRt):
  (r, m) = x
  col.rt.line(z, k, ColRt{r, t, h, v, cnt}, m)

def col.rt.go(ks: List<&2, ColK>, +z: ColSets, s: ColRt) -> IO(ColRt):
  match ks s:
    case Nil{} s2:
      IO.pure(ColRt, s2)
    case +k <> more ColRt{r, t, h, v, cnt}:
      do IO<ColRt>:
        x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(r)
        s2 : ColRt <- col.rt.got(z, k, t, h, v, cnt, x)
        col.rt.go(more, z, s2)

def col.cnt.lines(cs: List<&2, Nat>, +i: Nat) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case +n <> more:
      List.append(&2, U32, Bool.pick(List<&2, U32>, Nat.is_eq(n, 0n), Nil{}, S.b("bend\t" ++ col.reason(i) ++ "\t" ++ Nat.show(n) ++ "\n")), col.cnt.lines(more, 1n+i))

def col.rt.left(m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{l}:
      IO.die(Unit, 1, "collect: pre: more records than keys")

def col.rt.end(x: S.Rd & Maybe<&2, List<&2, U32>>, t: File, h: File, v: File) -> IO(Unit):
  (r, m) = x
  do IO<Unit>:
    S.Rd.close(r)
    File.close(t)
    File.close(h)
    File.close(v)
    col.rt.left(m)

def col.rt.fin(+c: ColCx, s: ColRt) -> IO(Unit):
  match s:
    case ColRt{r, t, h, v, +cnt}:
      do IO<Unit>:
        x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(r)
        col.rt.end(x, t, h, v)
        S.write(col.st(c, "pre.counts"), col.cnt.lines(cnt, 0n))
        col.log("pre: " ++ S.str(S.chomp(S.replace(col.cnt.lines(cnt, 0n), [10], S.b("; ")))))

def col.file.create(+p: String) -> IO(File):
  IO.try(File, File.open(p, "w"))

def col.pre(+c: ColCx) -> IO(Unit):
  +pd = col.st(c, "pre")
  +kd = col.st(c, "keys")
  +cfg = col.cx.cfg(c)
  +rs = col.repos(cfg)
  +growth = col.set(col.growth.names(rs))
  +upname = col.up.fold(col.up(cfg))
  do IO<Unit>:
    S.mkdir(pd)
    +kl : List<&2, List<&2, U32>> <- col.read.lines(kd ++ "/bend.keys")
    +ks : List<&2, ColK> = col.ks.of(kl)
    S.write(pd ++ "/new.paths.u", col.unlines(col.k.field(ks, 0n)))
    S.write(pd ++ "/new.repos.u", col.unlines(col.k.field(ks, 1n)))
    S.write(pd ++ "/new.sha.u", col.unlines(col.k.field(ks, 2n)))
    col.sortf(pd, ["-u"], pd ++ "/new.paths", [pd ++ "/new.paths.u"])
    col.sortf(pd, ["-u"], pd ++ "/new.repos", [pd ++ "/new.repos.u"])
    col.sortf(pd, ["-u"], pd ++ "/new.sha", [pd ++ "/new.sha.u"])
    col.c.to("join", "join", ["-t", "\t", pd ++ "/new.repos", kd ++ "/corpus.paths"], pd ++ "/corpus.sub")
    col.c.to("comm paths", "comm", ["-12", pd ++ "/new.paths", kd ++ "/corpus.paths"], pd ++ "/in.paths")
    col.c.to("comm keys", "comm", ["-12", pd ++ "/new.sha", kd ++ "/corpus.sha"], pd ++ "/in.sha")
    col.sortf(pd, ["-u", "-m"], pd ++ "/all.paths", [pd ++ "/corpus.sub", pd ++ "/new.paths"])
    +sub : List<&2, List<&2, U32>> <- col.read.lines(pd ++ "/corpus.sub")
    +allp : List<&2, List<&2, U32>> <- col.read.lines(pd ++ "/all.paths")
    +newp : List<&2, List<&2, U32>> <- col.read.lines(pd ++ "/new.paths")
    +newr : List<&2, List<&2, U32>> <- col.read.lines(pd ++ "/new.repos")
    +inp : List<&2, List<&2, U32>> <- col.read.lines(pd ++ "/in.paths")
    +ins : List<&2, List<&2, U32>> <- col.read.lines(pd ++ "/in.sha")
    +bk : List<&2, List<&2, U32>> <- col.files.lines(col.cf.files(cfg, "big-known"))
    +vk : List<&2, List<&2, U32>> <- col.files.lines(col.cf.files(cfg, "vault-known"))
    +computed : List<&2, List<&2, U32>> = col.keep.in(col.rn.names(col.rn.over(col.runs(allp), 301n)), growth, False{})
    +frozen : List<&2, List<&2, U32>> = col.keep.in(col.keep.in(col.uniq(col.growth.names(rs)), col.set(bk), True{}), col.set(newr), True{})
    +bigl : List<&2, List<&2, U32>> = col.uniq(List.append(&2, List<&2, U32>, computed, frozen))
    +bigs : Set() = col.set(bigl)
    S.write(pd ++ "/big.repos", col.unlines(bigl))
    +units : List<&2, List<&2, U32>> = col.uniq(col.units(newp, bigs))
    +held : List<&2, List<&2, U32>> = col.held(units)
    S.write(pd ++ "/units", col.unlines(units))
    S.write(pd ++ "/held.units", col.unlines(held))
    col.log("pre: " ++ Nat.show(List.length(&2, List<&2, U32>, units)) ++ " units (" ++ Nat.show(List.length(&2, List<&2, U32>, bigl)) ++ " repositories split by directory), " ++ Nat.show(List.length(&2, List<&2, U32>, held)) ++ " held out by C3's rule")
    +inps : Set() = col.set(inp)
    +inss : Set() = col.set(ins)
    +brs : List<&2, ColRn> = col.runs(col.sort(col.k.fresh(ks, inps, inss)))
    S.write(pd ++ "/bend.repos", col.unlines(col.rn.lines(brs)))
    +cands0 : List<&2, List<&2, U32>> = col.keep.in(col.keep.in(col.rn.names(col.rn.over(brs, col.cf.nat(cfg, "vault-min", 3n))), growth, False{}), col.set(upname), False{})
    +cands1 : List<&2, List<&2, U32>> = col.keep.in(cands0, col.set(col.firsts(sub)), False{})
    +si : List<&2, U32> <- S.read(col.cf.str(cfg, "streams", "run/v2/holdout/stream-index.json"))
    +hits : Set() = col.set(col.keep.in(col.quoted(S.split(si, 34), False{}), col.set(cands1), True{}))
    +cands : List<&2, List<&2, U32>> = col.sort(col.hashed(col.keep.in(cands1, hits, False{})))
    +nv : Nat = col.vault.n(col.cf.one(cfg, "vault", "quarter"), List.length(&2, List<&2, U32>, cands))
    +picks : List<&2, List<&2, U32>> = col.sort(col.after.tabs(List.take(&2, List<&2, U32>, cands, nv)))
    S.write(pd ++ "/vault.cands", col.unlines(cands))
    S.write(pd ++ "/vault.repos", col.unlines(picks))
    col.log("pre: vault " ++ Nat.show(nv) ++ " of " ++ Nat.show(List.length(&2, List<&2, U32>, cands)) ++ " eligible new repositories: " ++ S.str(S.join(picks, 32)))
    +vr : Set() = col.set(List.append(&2, List<&2, U32>, picks, col.nonempty(vk)))
    +heldset : Set() = col.set(held)
    +z : ColSets = ColSets{bigs, inps, inss, heldset, vr, col.set(col.routed(ks, bigs, heldset, vr))}
    S.mkdir(col.st(c, "cand/train"))
    S.mkdir(col.st(c, "cand/holdout"))
    S.mkdir(col.st(c, "cand/vault"))
    r : S.Rd <- S.Rd.lines(col.st(c, "in/bend.jsonl"))
    t : File <- col.file.create(col.st(c, "cand/train/bend.jsonl"))
    h : File <- col.file.create(col.st(c, "cand/holdout/bend.jsonl"))
    v : File <- col.file.create(col.st(c, "cand/vault/bend.jsonl"))
    s : ColRt <- col.rt.go(ks, z, ColRt{r, t, h, v, R.rw.nzeros(7n)})
    col.rt.fin(c, s)

# Gate: bend-corpus-v2 raw on each candidate file -----------------------------------------

def col.gate.env(+c: ColCx) -> List<&2, String>:
  +caps = col.cf.all(col.cx.cfg(c), "raw-cap")
  List.append(&2, String, ["JOBS=" ++ Nat.show(col.cx.procs(c)), "RAW_CHUNK=100000000"],
    Bool.pick(List<&2, String>, Nat.is_eq(List.length(&2, List<&2, U32>, caps), 0n), Nil{}, ["RAW_CAP_REPOS=" ++ S.str(S.join(caps, 44))]))

def col.gate.run(go: Bool, +c: ColCx, +k: String, +cand: String, +g: String) -> IO(Unit):
  match go:
    case True{}:
      do IO<Unit>:
        col.log("gate: " ++ k ++ " (" ++ cand ++ ")")
        +st : U32 <- S.run.log(".", col.l1(col.gate.env(c)), 2000000, col.cx.self(c), ["raw", g, cand], g ++ ".log")
        col.ok.if(U32.is_eq(st, 0), "gate " ++ k ++ " (see " ++ g ++ ".log)", S.Out{st, Nil{}})
        +sm : List<&2, U32> <- S.read(g ++ "/summary.txt")
        col.log("gate: " ++ k ++ ": " ++ S.str(S.chomp(sm)))
    case False{}:
      do IO<Unit>:
        S.rm(g)
        col.log("gate: " ++ k ++ ": no candidates")

def col.gate.one(+c: ColCx, +k: String) -> IO(Unit):
  +cand = col.st(c, "cand/" ++ k ++ "/bend.jsonl")
  do IO<Unit>:
    z : Nat <- S.size(cand)
    col.gate.run(Nat.is_lt(0n, z), c, k, cand, col.st(c, "gate/" ++ k))

def col.gate(+c: ColCx) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(col.st(c, "gate"))
    col.gate.one(c, "train")
    col.gate.one(c, "holdout")
    col.gate.one(c, "vault")

# Split: the outputs ------------------------------------------------------------------------

def col.cp.if(there: Bool, +a: String, +b: String) -> IO(Unit):
  match there:
    case True{}:
      col.cp(a, b)
    case False{}:
      S.rm(b)

def col.cp.maybe(+a: String, +b: String) -> IO(Unit):
  do IO<Unit>:
    there : Bool <- S.exists(a)
    col.cp.if(there, a, b)

def col.sum.line(there: Bool, +out: String, +name: String) -> IO(List<&2, U32>):
  match there:
    case True{}:
      do IO<List<&2, U32>>:
        n : Nat <- col.wc(out ++ "/" ++ name)
        z : Nat <- S.size(out ++ "/" ++ name)
        return S.b(col.left(name, 24n) ++ " " ++ col.right(Nat.show(n), 8n) ++ " files " ++ col.right(col.mb(z), 9n) ++ " MB JSONL\n")
    case False{}:
      IO.pure(List<&2, U32>, Nil{})

def col.sum.one(+out: String, +name: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    there : Bool <- S.exists(out ++ "/" ++ name)
    col.sum.line(there, out, name)

def col.prefix.all(xs: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      S.append(p, x) <> col.prefix.all(more, p)

def col.sum.gate(+c: ColCx, +k: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    +xs : List<&2, U32> <- S.read(col.st(c, "gate/" ++ k ++ "/summary.txt"))
    return col.unlines(col.prefix.all(col.nonempty(S.split.lines(xs)), S.b("  " ++ k ++ ": ")))

def col.split(+c: ColCx) -> IO(Unit):
  +out = col.cx.out(c)
  +g = col.st(c, "gate")
  do IO<Unit>:
    S.mkdir(out ++ "/vault")
    S.mkdir(out ++ "/holdout")
    col.cp.maybe(g ++ "/train/bend.jsonl", out ++ "/bend.jsonl")
    col.cp.maybe(g ++ "/vault/bend.jsonl", out ++ "/vault/bend.jsonl")
    col.cp.maybe(g ++ "/holdout/bend.jsonl", out ++ "/holdout/bend.jsonl")
    col.cp(col.st(c, "pre/held.units"), out ++ "/holdout/units.txt")
    col.cp(col.st(c, "pre/vault.repos"), out ++ "/vault/repos.txt")
    +a : List<&2, U32> <- col.sum.one(out, "bend.jsonl")
    +b : List<&2, U32> <- col.sum.one(out, "vault/bend.jsonl")
    +d : List<&2, U32> <- col.sum.one(out, "holdout/bend.jsonl")
    +e : List<&2, U32> <- col.sum.gate(c, "train")
    +f : List<&2, U32> <- col.sum.gate(c, "holdout")
    +h : List<&2, U32> <- col.sum.gate(c, "vault")
    +text : List<&2, U32> = L.v2.concat([a, b, d, S.b("\ngate (bend-corpus-v2 raw), kept and dropped by reason:\n"), e, f, h])
    S.write(out ++ "/summary.txt", text)
    IO.print(S.str(S.chomp(text)))

# Check ---------------------------------------------------------------------------------------

def col.dups(xs: List<&2, List<&2, U32>>, +prev: List<&2, U32>, +first: Bool) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> more:
      Nat.add(col.b2n(Bool.and(Bool.not(first), S.eq(x, prev))), col.dups(more, x, False{}))

def col.ids.of(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      L.v2.before(l, 9) <> col.ids.of(more)

# an output's keys (stage/check/NAME.keys): their lines
def col.check.keys(+c: ColCx, +f: String, +name: String) -> IO(List<&2, List<&2, U32>>):
  +kd = col.st(c, "check")
  do IO<List<&2, List<&2, U32>>>:
    +s : List<&2, U32> <- col.stamp(f)
    col.kf.run("check: keys of " ++ f, c, [ColKf{f, kd ++ "/" ++ name ++ ".keys", kd ++ "/" ++ name ++ ".piece", col.pieces(True{}, col.nat(L.v2.before(s, 32))), True{}, s}])
    col.read.lines(kd ++ "/" ++ name ++ ".keys")

# how many of xs (sorted, unique, written to tmp) the sorted file `against` has
def col.comm.n(+tmp: String, xs: List<&2, List<&2, U32>>, +against: String) -> IO(Nat):
  do IO<Nat>:
    S.write(tmp, col.unlines(col.uniq(xs)))
    col.c.to("comm " ++ against, "comm", ["-12", tmp, against], tmp ++ ".hit")
    n : Nat <- col.wc(tmp ++ ".hit")
    return n

def col.check.one(there: Bool, +c: ColCx, +f: String, +name: String) -> IO(List<&2, List<&2, U32>> & List<&2, U32>):
  match there:
    case True{}:
      do IO<List<&2, List<&2, U32>> & List<&2, U32>>:
        +ls : List<&2, List<&2, U32>> <- col.check.keys(c, f, name)
        +ks : List<&2, ColK> = col.ks.of(ls)
        np : Nat <- col.comm.n(col.st(c, "check/" ++ name ++ ".paths"), col.k.field(ks, 0n), col.st(c, "keys/corpus.paths"))
        nk : Nat <- col.comm.n(col.st(c, "check/" ++ name ++ ".sha"), col.k.field(ks, 2n), col.st(c, "keys/corpus.sha"))
        return (ls, S.b(col.left(name, 28n) ++ " " ++ col.right(Nat.show(List.length(&2, List<&2, U32>, ls)), 8n) ++ " records; corpus paths " ++ Nat.show(np) ++ ", corpus keys " ++ Nat.show(nk) ++ "\n"))
    case False{}:
      IO.pure(List<&2, List<&2, U32>> & List<&2, U32>, (Nil{}, Nil{}))

def col.check.out(+c: ColCx, +f: String, +name: String) -> IO(List<&2, List<&2, U32>> & List<&2, U32>):
  do IO<List<&2, List<&2, U32>> & List<&2, U32>>:
    there : Bool <- S.exists(f)
    col.check.one(there, c, f, name)

def col.check.fin(+c: ColCx, a: List<&2, List<&2, U32>> & List<&2, U32>, b: List<&2, List<&2, U32>> & List<&2, U32>, d: List<&2, List<&2, U32>> & List<&2, U32>) -> IO(Unit):
  (+ta, la) = a
  (+tb, lb) = b
  (+td, ld) = d
  +ck = col.st(c, "check")
  +ids = col.sort(col.ids.of(List.append(&2, List<&2, U32>, ta, List.append(&2, List<&2, U32>, tb, td))))
  +held = col.set(col.k.field(col.ks.of(List.append(&2, List<&2, U32>, tb, td)), 2n))
  +leak = List.length(&2, List<&2, U32>, col.keep.in(col.k.field(col.ks.of(ta), 2n), held, True{}))
  do IO<Unit>:
    nc : Nat <- col.comm.n(ck ++ "/ids", ids, col.st(c, "keys/corpus.ids"))
    +text : List<&2, U32> = L.v2.concat([la, lb, ld, S.b("duplicate ids among the outputs: " ++ Nat.show(col.dups(ids, Nil{}, True{})) ++ "\n"),
      S.b("output ids the corpus has: " ++ Nat.show(nc) ++ "\n"), S.b("train records whose key a vault/holdout file has: " ++ Nat.show(leak) ++ "\n")])
    S.write(ck ++ "/report.txt", text)
    IO.print(S.str(S.chomp(text)))

def col.check(+c: ColCx) -> IO(Unit):
  +out = col.cx.out(c)
  do IO<Unit>:
    S.mkdir(col.st(c, "check"))
    a : List<&2, List<&2, U32>> & List<&2, U32> <- col.check.out(c, out ++ "/bend.jsonl", "bend.jsonl")
    b : List<&2, List<&2, U32>> & List<&2, U32> <- col.check.out(c, out ++ "/vault/bend.jsonl", "vault_bend.jsonl")
    d : List<&2, List<&2, U32>> & List<&2, U32> <- col.check.out(c, out ++ "/holdout/bend.jsonl", "holdout_bend.jsonl")
    col.check.fin(c, a, b, d)

# The entry -----------------------------------------------------------------------------------

def col.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-corpus-v2 collect CFG STEP...   (STEP: fetch list gate-bend nul keys pre gate split check all; see bend/CorpusV2/Collect.bend)")

def col.step.code(+s: String) -> Nat:
  Bool.pick(Nat, String.eq(s, "fetch"), 1n, Bool.pick(Nat, String.eq(s, "list"), 2n, Bool.pick(Nat, String.eq(s, "gate-bend"), 3n,
    Bool.pick(Nat, String.eq(s, "nul"), 4n, Bool.pick(Nat, String.eq(s, "keys"), 5n, Bool.pick(Nat, String.eq(s, "pre"), 6n,
      Bool.pick(Nat, String.eq(s, "gate"), 7n, Bool.pick(Nat, String.eq(s, "split"), 8n, Bool.pick(Nat, String.eq(s, "check"), 9n,
        Bool.pick(Nat, String.eq(s, "all"), 10n, 0n))))))))))

def col.all(+c: ColCx) -> IO(Unit):
  do IO<Unit>:
    col.fetch(c)
    col.list(c)
    col.gate.bend(c)
    col.nul(c)
    col.keys(c)
    col.pre(c)
    col.gate(c)
    col.split(c)
    col.check(c)

def col.step(k: Nat, +c: ColCx) -> IO(Unit):
  match k:
    case 1n:
      col.fetch(c)
    case 2n:
      col.list(c)
    case 3n:
      col.gate.bend(c)
    case 4n:
      col.nul(c)
    case 5n:
      col.keys(c)
    case 6n:
      col.pre(c)
    case 7n:
      col.gate(c)
    case 8n:
      col.split(c)
    case 9n:
      col.check(c)
    case 10n:
      col.all(c)
    case _:
      col.usage()

def col.steps(xs: List<String>, +c: ColCx) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +s <> more:
      do IO<Unit>:
        col.log("step " ++ s)
        col.step(col.step.code(s), c)
        col.steps(more, c)

def col.cfg.got(+path: String, m: Maybe<&2, List<&2, U32>>) -> IO(List<&2, U32>):
  match m:
    case Some{xs}:
      IO.pure(List<&2, U32>, xs)
    case None{}:
      IO.die(List<&2, U32>, 2, "collect: cannot read the config " ++ path)

def col.load(+path: String) -> IO(ColCfg()):
  do IO<ColCfg()>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(path)
    +xs : List<&2, U32> <- col.cfg.got(path, m)
    return col.cf.lines(S.split.lines(xs))

def col.validate(+c: ColCx) -> IO(Unit):
  +cs = col.cx.cfg(c)
  +bad = List.append(&2, List<&2, U32>, col.bad.rules(col.repos(cs)), col.hub.cf.rules(col.hub.cf(cs)))
  +ok = Bool.and(Bool.and(Bool.not(String.is_empty(col.cx.out(c))), Bool.not(String.is_empty(col.cx.src(c)))),
    Bool.and(String.eq(col.cf.str(cs, "lang", "bend"), "bend"), Nat.is_eq(List.length(&2, List<&2, U32>, bad), 0n)))
  Bool.pick(IO(Unit), ok, IO.pure(Unit, Unit{}),
    IO.die(Unit, 2, "collect: the config needs out, src, lang bend and every repository's RULE one of all, lt100k, novendor (not: " ++ S.str(S.join(bad, 32)) ++ ")"))

def col.run(+path: String, steps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +cs : ColCfg() <- col.load(path)
    self : String <- col.self()
    +c : ColCx = ColCx{cs, col.cf.str(cs, "out", ""), col.cf.str(cs, "src", ""), self, col.cf.nat(cs, "procs", 4n)}
    col.validate(c)
    col.steps(steps, c)

def col.project.args(xs: List<String>) -> IO(Unit):
  match xs:
    case k <> b <> Nil{}:
      col.project(k, b)
    case _:
      col.usage()

def col.main.mode(proj: Bool, +a: String, more: List<String>) -> IO(Unit):
  match proj:
    case True{}:
      col.project.args(more)
    case False{}:
      col.run(a, more)

# `collect CFG STEP...` (and the internal `collect --project KEYS BASE`)
def col.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +a <> more:
      col.main.mode(String.eq(a, "--project"), a, more)
    case Nil{}:
      col.usage()
