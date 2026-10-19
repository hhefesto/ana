import Base
import ../Sys.bend as S
import ../CorpusV2/Steps.bend as St

# Checks: the verdicts of flake.nix's checks, in Bend (the user, 2026-10-14:
# all logic in Bend, sh only a thin shim).  Each subcommand runs its
# programs, reads what they print, says `ok LAW` or `FAIL LAW` for every law
# and exits 1 when one fails: a check's body only copies the sources and
# runs it (no awk, grep, cmp or diff decides).  The programs that judge
# themselves (tests/train.bend, dense.bend, decode-dense.bend,
# prefill-dense.bend) the checks run directly.  Every def is prefixed
# `chk.`.
#
#   suite            the unit tests of this directory, run from it (agent.bend
#                    compiled, weights/code32k.bpe beside it), each output
#                    against what the test must print
#   train-run TRAINER CORPUS
#                    30 steps of tiny-v3 on the tree trainer (bend-train): the
#                    validation loss falls by more than 0.3, and the checkpoint
#                    is BTC1
#   dense-run TRAINER CORPUS FROZEN GOLDENS
#                    the same on the dense trainer (bend-train-dense); a
#                    validation set smaller than a micro-batch scores above 0;
#                    six steps of small4-v3 on FROZEN with AdamW and with Muon
#                    give checkpoints whose `sha256sum` is GOLDENS byte for byte
#                    (bend/tests/dense-identity.sh wrote it; 2026-10-15: unwired,
#                    `bend-ops dense-identity` writes it)
#   bulk-cpu SRC     the CPU bulk ops' outputs byte for byte: SRC/gpu/GemmConf
#                    and EinsumConf on the JS lane, BEND_FT=loop on 1 thread
#                    and the default on 8; SRC/tests/bulk-cpu on BEND_FT=loop,
#                    BEND_FT=c and 1, 8 and 16 threads
#   same A B         the files A and B byte for byte (cmp's verdict)
#
# A number a program prints is read as awk read it: the decimal to the
# nearest double (CorpusV2/Steps.bend's StF, exact), compared as doubles.

# Laws -------------------------------------------------------------------------

type ChkLaw is Data:
  ChkLaw{ok: Bool, what: String}

def chk.laws.say(ls: List<&2, ChkLaw>, +bad: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, bad)
    case ChkLaw{+ok, what} <> more:
      do IO<Nat>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ what)
        chk.laws.say(more, Nat.add(bad, Bool.pick(Nat, ok, 0n, 1n)))

def chk.verdict.if(+name: String, +bad: Nat, +n: Nat, zero: Bool) -> IO(Unit):
  match zero:
    case True{}:
      IO.print("ok " ++ name ++ ": all " ++ Nat.show(n) ++ " laws hold")
    case False{}:
      IO.die(Unit, 1, name ++ ": " ++ Nat.show(bad) ++ " of " ++ Nat.show(n) ++ " laws failed")

# every law said; the exit status is 1 when one failed
def chk.verdict(+name: String, +ls: List<&2, ChkLaw>) -> IO(Unit):
  do IO<Unit>:
    +bad : Nat <- chk.laws.say(ls, 0n)
    chk.verdict.if(name, bad, List.length(&2, ChkLaw, ls), Nat.is_eq(bad, 0n))

# Processes --------------------------------------------------------------------

# a run's exit status, stdout and stderr (apart, unlike Sys.run)
type ChkRun is Data:
  ChkRun{status: U32, out: String, err: String}

def chk.st(+r: ChkRun) -> U32:
  match r:
    case ChkRun{s, o, e}:
      s

def chk.out(+r: ChkRun) -> String:
  match r:
    case ChkRun{s, o, e}:
      o

def chk.err(+r: ChkRun) -> String:
  match r:
    case ChkRun{s, o, e}:
      e

# what a run may print (stdout and stderr together), and how long it may take
def chk.cap() -> U32:
  268435456

def chk.ms() -> U32:
  86400000

def chk.got(+what: String, r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(ChkRun):
  match r:
    case Done{(code, (out, err))}:
      IO.pure(ChkRun, ChkRun{code, out, err})
    case Fail{(code, msg)}:
      IO.die(ChkRun, 1, what ++ " did not run (error " ++ U32.show(code) ++ "): " ++ msg)

# PROG ARGS with ENV (K=V each) added to the environment, from this directory
def chk.run(+what: String, env: List<String>, prog: String, args: List<String>) -> IO(ChkRun):
  do IO<ChkRun>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("env", List.append(&1, String, env, prog <> args), "", chk.cap(), chk.ms())
    chk.got(what, r)

# the same with stdout into the file `to` (an output too big to hold as
# text): `sh -c 'exec "$@" > "$0"' TO env ENV PROG ARGS`, a redirect only
def chk.run.to(+what: String, to: String, env: List<String>, prog: String, args: List<String>) -> IO(ChkRun):
  do IO<ChkRun>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", "exec \"$@\" > \"$0\"", to, "env"], List.append(&1, String, env, prog <> args)),
        "", chk.cap(), chk.ms())
    chk.got(what, r)

# what a run printed, into the check's log
def chk.show(+r: ChkRun) -> IO(Unit):
  do IO<Unit>:
    IO.write(chk.out(r))
    IO.write(chk.err(r))

def chk.must.if(ok: Bool, +what: String, +r: ChkRun) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, what ++ " failed (exit " ++ U32.show(chk.st(r)) ++ ")")

# a run that must exit 0, or the check stops
def chk.must(+what: String, +r: ChkRun) -> IO(Unit):
  chk.must.if(U32.is_eq(chk.st(r), 0), what, r)

# Text -------------------------------------------------------------------------

def chk.nil(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      False{}

# lines, each followed by its newline (what printf '%s\n' LINE... prints)
def chk.unlines(xs: List<&2, String>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.append(S.b(x), 10 <> chk.unlines(t))

def chk.oks(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      ("ok " ++ x) <> chk.oks(t)

# how many lines start with p
def chk.count.prefix(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case l <> t:
      Nat.add(Bool.pick(Nat, S.prefix(l, p), 1n, 0n), chk.count.prefix(t, p))

# does every line start with p
def chk.all.prefix(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      True{}
    case l <> t:
      Bool.and(S.prefix(l, p), chk.all.prefix(t, p))

# does some line hold p
def chk.any.infix(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case l <> t:
      Bool.or(S.infix(l, p), chk.any.infix(t, p))

# Numbers as awk reads them ----------------------------------------------------

def chk.col.put(hit: Bool, m: Maybe<&2, List<&2, U32>>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match hit m:
    case True{} Some{v}:
      v <> rest
    case True{} None{}:
      Nil{} <> rest
    case False{} _:
      rest

# field i (from 0) of every line holding pat: awk's /pat/ { v[++n] = $(i+1) }
# (a missing field is an empty one, which no number reads)
def chk.col(ls: List<&2, List<&2, U32>>, +pat: List<&2, U32>, +i: Nat) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      chk.col.put(S.infix(l, pat), St.st.nth(St.st.words(l), i), chk.col(more, pat, i))

def chk.kv.put(hit: Bool, v: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match hit:
    case True{}:
      v <> rest
    case False{}:
      rest

def chk.kv.fields(fs: List<&2, List<&2, U32>>, +key: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match fs:
    case Nil{}:
      rest
    case +f <> more:
      chk.kv.put(S.prefix(f, key), List.drop(&2, U32, f, S.len(key)), chk.kv.fields(more, key, rest))

# the value of every field `key...` on every line, in order: the dense
# trainer's `validation_loss=X`
def chk.kv(ls: List<&2, List<&2, U32>>, +key: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      chk.kv.fields(St.st.words(l), key, chk.kv(more, key))

# the values read as doubles; ok is whether every one was a number
type ChkNums is Data:
  ChkNums{ok: Bool, vs: List<&2, St.StF>}

def chk.nums.put(m: Maybe<&2, St.StF>, r: ChkNums) -> ChkNums:
  match m r:
    case Some{v} ChkNums{ok, vs}:
      ChkNums{ok, v <> vs}
    case None{} ChkNums{ok, vs}:
      ChkNums{False{}, vs}

def chk.nums(xs: List<&2, List<&2, U32>>) -> ChkNums:
  match xs:
    case Nil{}:
      ChkNums{True{}, Nil{}}
    case +x <> more:
      chk.nums.put(St.st.f.read(x), chk.nums(more))

def chk.f(+s: String) -> St.StF:
  Maybe.default(&2, St.StF, St.st.f.read(S.b(s)), St.st.f.zero())

def chk.last(xs: List<&2, St.StF>, d: St.StF) -> St.StF:
  match xs:
    case Nil{}:
      d
    case x <> t:
      chk.last(t, x)

def chk.fell.at(vs: List<&2, St.StF>) -> Bool:
  match vs:
    case Nil{}:
      False{}
    case +first <> rest:
      Cmp.is_lt(St.st.f.cmp(chk.last(rest, first), St.st.f.sub(first, chk.f("0.3"))))

# at least two values, and the last below the first less 0.3 (awk:
# n >= 2 && v[n] < v[1] - 0.3)
def chk.fell(+n: ChkNums) -> Bool:
  match n:
    case ChkNums{ok, +vs}:
      Bool.and(Bool.and(ok, Nat.is_le(2n, List.length(&2, St.StF, vs))), chk.fell.at(vs))

def chk.pos(vs: List<&2, St.StF>) -> Bool:
  match vs:
    case Nil{}:
      True{}
    case +v <> t:
      Bool.and(Cmp.is_gt(St.st.f.cmp(v, St.st.f.zero())), chk.pos(t))

# at least one value, and every one above 0
def chk.scored(+n: ChkNums) -> Bool:
  match n:
    case ChkNums{ok, +vs}:
      Bool.and(Bool.and(ok, Nat.is_le(1n, List.length(&2, St.StF, vs))), chk.pos(vs))

def chk.vals(+xs: List<&2, List<&2, U32>>) -> String:
  "(" ++ Nat.show(List.length(&2, List<&2, U32>, xs)) ++ " values: " ++ S.str(S.join(xs, 32)) ++ ")"

# a file's first line without its newline (`head -1`); nothing when the file
# cannot be opened
def chk.head.got(r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(List<&2, U32>):
  (f, x) = r
  do IO<List<&2, U32>>:
    File.close(f)
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return S.lines.first(xs)

def chk.head.opened(r: Result<&1, &1, U32 & String, File>) -> IO(List<&2, U32>):
  match r:
    case Fail{e}:
      IO.pure(List<&2, U32>, Nil{})
    case Done{f}:
      IO.bind(File & Result<&1, &1, U32 & String, List<&2, U32>>, List<&2, U32>, File.read_bytes(f, 4096), chk.head.got)

def chk.head(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    chk.head.opened(r)

def chk.btc1(+path: String, +h: List<&2, U32>) -> ChkLaw:
  ChkLaw{S.eq(h, S.b("BTC1")), path ++ "'s first line is BTC1" ++ Bool.pick(String, S.eq(h, S.b("BTC1")), "", " (it is `" ++ S.str(h) ++ "`)")}

# Two files byte for byte --------------------------------------------------------
#
# Each side a buffer read a chunk at a time; the common prefix of the two
# buffers is dropped while it agrees, and an emptied buffer refilled.  A
# buffer still empty after its refill is the end of its file.

def chk.chunk() -> U32:
  1048576

type ChkSd is Type:
  ChkSd{f: File, buf: List<&2, U32>, eof: Bool}

def chk.sd.got(r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(ChkSd):
  (g, x) = r
  do IO<ChkSd>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return ChkSd{g, xs, chk.nil(xs)}

def chk.sd.fill.if(f: File, buf: List<&2, U32>, eof: Bool, need: Bool) -> IO(ChkSd):
  match need:
    case True{}:
      IO.bind(File & Result<&1, &1, U32 & String, List<&2, U32>>, ChkSd, File.read_bytes(f, chk.chunk()), chk.sd.got)
    case False{}:
      IO.pure(ChkSd, ChkSd{f, buf, eof})

def chk.sd.fill(s: ChkSd) -> IO(ChkSd):
  match s:
    case ChkSd{f, +buf, +eof}:
      chk.sd.fill.if(f, buf, eof, Bool.and(chk.nil(buf), Bool.not(eof)))

# what is left of each list after their agreeing prefix, its length, and
# whether no byte differed
type ChkDr is Data:
  ChkDr{a: List<&2, U32>, b: List<&2, U32>, n: Nat, same: Bool}

def chk.heq(+xs: List<&2, U32>, +ys: List<&2, U32>) -> Bool:
  match xs ys:
    case x <> xt y <> yt:
      U32.is_eq(x, y)
    case _ _:
      True{}

def chk.drop(xs: List<&2, U32>, ys: List<&2, U32>, +n: Nat, eq: Bool) -> ChkDr:
  match xs ys eq:
    case x <> +xt y <> +yt True{}:
      chk.drop(xt, yt, 1n+n, chk.heq(xt, yt))
    case x <> xt y <> yt False{}:
      ChkDr{x <> xt, y <> yt, n, False{}}
    case Nil{} r _:
      ChkDr{Nil{}, r, n, True{}}
    case r Nil{} _:
      ChkDr{r, Nil{}, n, True{}}

# the comparison so far: both sides, bytes agreed, whether to read on, and
# whether they are still the same
type ChkCs is Type:
  ChkCs{a: ChkSd, b: ChkSd, off: Nat, more: Bool, same: Bool}

def chk.cs.dr(+off: Nat, fa: File, fb: File, ea: Bool, eb: Bool, na: Bool, nb: Bool, d: ChkDr) -> ChkCs:
  match na nb d:
    case True{} True{} ChkDr{ra, rb, n, s}:
      ChkCs{ChkSd{fa, ra, ea}, ChkSd{fb, rb, eb}, off, False{}, True{}}
    case True{} False{} ChkDr{ra, rb, n, s}:
      ChkCs{ChkSd{fa, ra, ea}, ChkSd{fb, rb, eb}, off, False{}, False{}}
    case False{} True{} ChkDr{ra, rb, n, s}:
      ChkCs{ChkSd{fa, ra, ea}, ChkSd{fb, rb, eb}, off, False{}, False{}}
    case False{} False{} ChkDr{ra, rb, n, +s}:
      ChkCs{ChkSd{fa, ra, ea}, ChkSd{fb, rb, eb}, Nat.add(off, n), s, s}

def chk.cs.at(+off: Nat, a: ChkSd, b: ChkSd) -> ChkCs:
  match a b:
    case ChkSd{fa, +xa, ea} ChkSd{fb, +xb, eb}:
      chk.cs.dr(off, fa, fb, ea, eb, chk.nil(xa), chk.nil(xb), chk.drop(xa, xb, 0n, chk.heq(xa, xb)))

def chk.cs.step(+off: Nat, a: ChkSd, b: ChkSd) -> IO(ChkCs):
  do IO<ChkCs>:
    a2 : ChkSd <- chk.sd.fill(a)
    b2 : ChkSd <- chk.sd.fill(b)
    return chk.cs.at(off, a2, b2)

# every step reads at least one chunk: a file's size is a U32
def chk.cs.go(fuel: Nat, cs: ChkCs) -> IO(ChkCs):
  match fuel cs:
    case 1n+p ChkCs{a, b, off, True{}, s}:
      IO.bind(ChkCs, ChkCs, chk.cs.step(off, a, b), chk.cs.go(p))
    case _ ChkCs{a, b, off, False{}, s}:
      IO.pure(ChkCs, ChkCs{a, b, off, False{}, s})
    case 0n ChkCs{a, b, off, True{}, s}:
      IO.pure(ChkCs, ChkCs{a, b, off, False{}, False{}})

# the verdict, and where it failed: a side with nothing left had ended (cmp's
# EOF), else the first byte left differs (offsets count from 0)
def chk.cs.fin(+what: String, cs: ChkCs) -> IO(ChkLaw):
  match cs:
    case ChkCs{ChkSd{fa, +ra, ea}, ChkSd{fb, +rb, eb}, +off, m, +s}:
      do IO<ChkLaw>:
        File.close(fa)
        File.close(fb)
        return ChkLaw{s, what ++ Bool.pick(String, s, "", Bool.pick(String, Bool.or(chk.nil(ra), chk.nil(rb)),
          " (one ends after " ++ Nat.show(off) ++ " bytes, the other goes on)", " (they differ at byte offset " ++ Nat.show(off) ++ ")"))}

# do the files a and b hold the same bytes (`cmp a b`)
def chk.same(+a: String, +b: String) -> IO(ChkLaw):
  do IO<ChkLaw>:
    fa : File <- IO.try(File, File.open(a, "r"))
    fb : File <- IO.try(File, File.open(b, "r"))
    cs : ChkCs <- chk.cs.go(U32.to_nat(10000), ChkCs{ChkSd{fa, Nil{}, False{}}, ChkSd{fb, Nil{}, False{}}, 0n, True{}, True{}})
    chk.cs.fin(a ++ " and " ++ b ++ " are the same bytes", cs)

# suite ------------------------------------------------------------------------
#
# What a unit test must print (its stdout; it must exit 0 too):
#   RExact   exactly these lines
#   ROks     only `ok ` lines, n of them
#   RLayout  n `ok ` lines and no line holding MISMATCH
#   RHead    these first lines, and a line starting with `also`

type ChkRule is Data:
  RExact{want: List<&2, String>}
  ROks{n: Nat}
  RLayout{n: Nat}
  RHead{want: List<&2, String>, also: String}

# a test: its file, whether it runs compiled, its rule
type ChkTest is Data:
  ChkTest{file: String, bin: Bool, rule: ChkRule}

def chk.tests() -> List<&2, ChkTest>:
  [ChkTest{"sha.bend", False{}, RExact{["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
     "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
     "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"]}},
   ChkTest{"num.bend", False{}, RExact{["236d88fe5618cf00", "9bde02468acf1357", "0000000048d159e2", "0000000000000001", "ffffffffffffffff", "1.5"]}},
   # the exact store size (Nat) equals Lay.of's U32 total wherever U32
   # cannot wrap
   ChkTest{"layout.bend", False{}, RLayout{52n}},
   # the unit extractor: unit counts per language, and every unit rebuilds
   # its file byte for byte; the Term turn's indentation
   ChkTest{"units.bend", False{}, RExact{chk.oks(["term bend", "term haskell-instance", "term haskell", "term lean", "haskell 2", "agda 1", "lean 2", "bend 2", "nix 1", "lagda 1"])}},
   # the transcript renderer's format 2 (docs/CORPUS-V2.md): each shape's
   # turns, the direct shape byte for byte, every Term the original, a
   # unit's presentations distinct, Nix never direct
   ChkTest{"transcript.bend", False{}, RExact{chk.oks(["direct", "turns 0", "turns 1", "turns 2", "turns 3", "turns 4", "turns 5", "terms", "copies repo:x/A.hs#twice@1", "copies repo:x/a.nix#file@1"])}},
   # E5 reads ana's output as a transcript less ana's closing newline: a
   # passing last echo is solved (it never was before)
   ChkTest{"agent-eval.bend", False{}, RExact{chk.oks(["a passing last echo is solved", "read with the closing newline it is not (the bug)",
     "a failing echo then a stopped call is not", "one call answered", "one answered, the stopped one not"])}},
   # the corpus tools' libraries: processes and text (Sys), JSON strings as
   # jq decodes and writes them (Json), POSIX cksum
   ChkTest{"sys.bend", False{}, RExact{chk.oks(["run", "merge", "timeout", "cwd", "env", "stdin", "clean", "parent", "root", "chomp", "split", "replace", "nul", "slurp", "exists", "to", "feed", "from", "glob", "bytes"])}},
   ChkTest{"json.bend", False{}, RExact{chk.oks(["escapes", "space", "trailing", "bad-escape", "unpaired-high", "lone-low", "raw-tab", "unclosed", "quote", "doc", "doc-order", "doc-extra", "nonul", "line"])}},
   ChkTest{"cksum.bend", False{}, ROks{5n}},
   # the drivers' own rules: the mix's rounding and ids, the extractor's
   # UTF-8, license and holdout verdicts
   ChkTest{"mix.bend", False{}, ROks{12n}},
   ChkTest{"extract.bend", False{}, ROks{32n}},
   # the cleaner's MinHash: one word apart agrees in 90+ of 128
   ChkTest{"clean.bend", False{}, RExact{chk.oks(["near", "far", "self", "grams", "short", "key"])}},
   # legere: forward-backward and Viterbi equal the enumeration
   # (Legere/Spec.bend) in Nat and Bool, within 1e-4 in logp and maxp; the
   # cues' gold and mask; the sum over b of P(b | h) is 1; sections give the
   # lines back
   ChkTest{"legere.bend", False{}, RExact{chk.oks(["score", "bool", "marginals", "boundaries", "logp", "posteriors", "bposteriors", "viterbi", "cues", "ngram", "roundtrip"])}},
   # an episode as the loop writes it (Agent/Episode.bend): the log reads
   # back any bytes and refuses a cut record, the loop's newest-first fold
   # is the text in order, and the training grammar: a solved chain holds;
   # drift, an unsolved end, a call past the cap and a tool byte not read as
   # echo fail, each with its reason
   ChkTest{"episode.bend", False{}, RExact{chk.oks(["log roundtrip", "newest", "chain (ok)", "drift (drift)", "unsolved (unsolved)", "calls (calls)",
     "authors (authors)", "tries", "solved"])}},
   # ana's episodes (Agent/Spec.bend): each shape's roles, reading's round
   # trip, every call answered, weight 0 exactly on attempts, tries and
   # echoes, the loop's unfold, multi-turn chains (every rejected Term a
   # try), the reader before tries agreeing on every format-2 shape, and a
   # code32k window's weights (compiled: the interpreter's stack is too
   # small for the tokenizer's parse)
   ChkTest{"agent.bend", True{}, RHead{chk.oks(["direct", "repair", "term-to-type", "verify", "trap", "weights direct", "weights repair", "unfold",
     "chain", "chain-repair", "label drift", "tries weigh 0", "v1 direct", "v1 repair", "v1 term-to-type", "v1 verify", "v1 trap", "verdict"]), "ok window"}},
   # bend-ops' primitives (bend/Box): its parsers on run 3's files
   # (chain.log, the sha256 listings, a trainer's log) and on vastai's --raw
   # JSON, the lint's rules and flake bodies, st.f.floor, and the processes
   # (background, which, find, stat, sha256sum, markers); reads fixtures/ops
   ChkTest{"ops.bend", False{}, ROks{70n}},
   # collect's pure parts (bend/CorpusV2/Collect.bend): the config grammar,
   # the repo rules and excludes, the loader-verdict classes, notbase, growth
   # routing and the vault quarter; the hub (2026-10-16): its listing, the newest of a
   # name, PINS over the choice, plain paths, the manifest and its hash
   ChkTest{"collect.bend", False{}, ROks{69n}},
   # bend-box's and `bend-ops stage`'s readers (bend/Box/OnBox.bend,
   # Stage.bend) against fp.sh's awk, grep, sort, tail and sed on real logs
   # (gate.log, time.log, dmon.txt, a plan; reads fixtures/box)
   ChkTest{"box.bend", False{}, ROks{21n}},
   # the run recipes (bend/CorpusV2/{Keyed,S2,ActSet,Steady,Recipes}.bend,
   # bend/Box/{Drive,Evals}.bend): keyed-order against sha256sum's order,
   # s2's share and McNemar's p against awk's, NLR against run 3's lr= at
   # its boundary, the rest of a plan against awk's lines, REST_STEPS's cap and a
   # hot-started S1's NLR (run 4); s2's act directories gathered for real (2026-10-16:
   # one named twice gives its pairs then the same texts with /e2 after each id, no id
   # twice; named once, cat's bytes) (reads fixtures/box, fixtures/recipes)
   ChkTest{"recipes.bend", False{}, ROks{57n}},
   # bend-ops chain and watch (bend/Box/Chain.bend, Watch.bend): their
   # decisions on run 3's chain.log, s2.log and sha256 listings (the per-poll
   # line and the eval line byte for byte), follow, verify, HOLD, the watch's
   # due/silent/safe; bend-sim's ssh reading and the scenarios' event lines; from= (run 4:
   # its parse, the saves the prune keeps, what a start leaves to delete or to pull)
   ChkTest{"chain.bend", False{}, ROks{59n}},
   # the act round's pure parts (bend/Box/Act.bend, ActBox.bend, CorpusV2/AgentAct.bend,
   # bend-episode langs) against act-box.sh, agent-act.sh, s2-driver.sh and move.sh: PROCS
   # under a cgroup quota, the check's verdict on run 3's check.txt, the per-language table on
   # round 1's eplog head, setup's unit and tree rules, the frame and pair cuts, agent-act's
   # command lines; reads fixtures/act (compiled: the interpreter's stack is too small for the
   # eplog's parse)
   ChkTest{"act.bend", True{}, ROks{46n}},
   # the run drivers' pure parts (bend/Box/RunCfg, Unit, Guard, Handover, Move: Phase 4b)
   # against run 3's boot-guard.sh, s2-driver.sh and move.sh: the config, the systemd-run
   # line and its record, what the guard starts, the hand-over's counts, stage line and
   # stage.env checks on run 3's s2-driver.out, the move's save, push and STAGES rewrite on
   # run 3's files; run 4's plan-base wait and control line; reads fixtures/drive and
   # fixtures/ops/chain.log
   ChkTest{"drive.bend", False{}, ROks{66n}},
   # bend-corpus-v2 unused (bend/CorpusV2/Unused.bend, run 4): a line's id as J.first.at reads it,
   # hex and twelve-digit numbers in sort's order, POOL=OUT... SEEN... arguments, and the whole tool
   # (spools, `LC_ALL=C sort`, the merge; two pools in one call) against the set difference on
   # small fixtures, in one process (PROCS 1: no bend-corpus-v2 to spawn here)
   ChkTest{"unused.bend", False{}, ROks{15n}},
   # bend-corpus-v2 mutate's operators (bend/CorpusV2/MutOps.bend, 2026-10-16): the tokens joined
   # are the text, each of the 13 operators gives exactly its mutants on three bodies and none
   # where it does not apply, every mutant differs from its body, a unit's tries (cap an
   # operator, each text once, the operators in turn, the k-th from the key's rotation)
   ChkTest{"mutops.bend", False{}, ROks{61n}},
   # bend-corpus-v2 mutate end to end (bend/CorpusV2/Mutate.bend), in one process with `bend`
   # and weights/code32k.bpe: the error kinds and the keep rule, then a unit set written here (a
   # unit that checks, a stale one, a Nix one, a held-out one): the selection, stale counted,
   # every transcript format 2's repair read back by Agent/Spec (User, Context, Type, Attempt,
   # its failing check, the Term, its pass), no operator twice, a second run the same bytes
   # (compiled: the tokenizer's parse; the tool prints its summary, so only the ok count is held)
   ChkTest{"mutate.bend", True{}, RLayout{23n}},
   # bend-corpus-v2 decl-new (bend/CorpusV2/Decl.bend, 2026-10-16): a unit's file, its file's text and its
   # declaration key (the pool's), the held=/seen= words; the tool on units written here, one a rule
   # (a v2 held-out repository and path, a held file's id, its text in another file, a listed key, a
   # held declaration, a seen one, a duplicate): OUT exactly the kept pairs, OUT.dropped, the stats; a
   # cap=PREFIX:N (every stride-th unit of a capped file, the first N), cap words, sel's spread
   ChkTest{"decl.bend", False{}, ROks{20n}},
   # bend-corpus-v2 port's renames (bend/CorpusV2/PortOps.bend, 2026-10-16): declarations and the
   # header as the loader reads them, import paths through a sibling link, fresh names; the own,
   # alias and binder renames on modules written here (strings and comments untouched, an importer
   # following its module, Base's own dotted name kept); the seg join; failures read back; an error's
   # line; a repair transcript read back by Agent/Spec (Port.bend's render: the layout, solved, the port)
   ChkTest{"portops.bend", False{}, ROks{24n}},
   # the raw slicer run for real (raw-build's first step): slice 2 comes through a FIFO that dd
   # fills; the tail it replaced held Process.run's pipes and every slice past the first timed out
   # (the slicer's own lines first: K, the documents kept, the last)
   ChkTest{"slice.bend", False{}, RExact{["slice 1 20 documents ", "slice 2 20 documents ", "slice 3 0 documents (the last)",
     "slice 1 21 documents ", "slice 2 19 documents ", "slice 3 0 documents (the last)",
     "ok a line's start: slice 1 is the lines starting before SIZE",
     "ok a line's start: slice 2 (through the FIFO) is the lines starting in [SIZE, 2 SIZE)",
     "ok a line's start: slices 1 and 2 are the file up to the first line starting at 2 SIZE or past it",
     "ok a line's start: slice 3, the last, keeps whole 2,000s of lines: none of its few",
     "ok mid-line: slice 1 is the lines starting before SIZE",
     "ok mid-line: slice 2 (through the FIFO) is the lines starting in [SIZE, 2 SIZE)",
     "ok mid-line: slices 1 and 2 are the file up to the first line starting at 2 SIZE or past it",
     "ok mid-line: slice 3, the last, keeps whole 2,000s of lines: none of its few"]}}]

def chk.rule(r: ChkRule, +out: List<&2, U32>) -> Bool:
  match r:
    case RExact{want}:
      S.eq(out, chk.unlines(want))
    case ROks{+n}:
      +ls = S.split.lines(out)
      Bool.and(chk.all.prefix(ls, S.b("ok ")), Nat.is_eq(chk.count.prefix(ls, S.b("ok ")), n))
    case RLayout{+n}:
      +ls = S.split.lines(out)
      Bool.and(Bool.not(chk.any.infix(ls, S.b("MISMATCH"))), Nat.is_eq(chk.count.prefix(ls, S.b("ok ")), n))
    case RHead{+want, +also}:
      Bool.and(S.eq(S.lines.take(out, List.length(&2, String, want)), chk.unlines(want)), Nat.is_ne(chk.count.prefix(S.split.lines(out), S.b(also)), 0n))

def chk.rule.show(r: ChkRule) -> String:
  match r:
    case RExact{want}:
      "it must print exactly:\n" ++ S.str(chk.unlines(want))
    case ROks{n}:
      "it must print only `ok ` lines, " ++ Nat.show(n) ++ " of them"
    case RLayout{n}:
      "it must print " ++ Nat.show(n) ++ " `ok ` lines and no MISMATCH"
    case RHead{+want, also}:
      "its first " ++ Nat.show(List.length(&2, String, want)) ++ " lines must be:\n" ++ S.str(chk.unlines(want)) ++ "and a line must start with `" ++ also ++ "`"

def chk.test.ran.if(ok: Bool, c: ChkRun, +exe: String) -> IO(ChkRun):
  match ok:
    case True{}:
      chk.run(exe, [], exe, [])
    case False{}:
      IO.pure(ChkRun, c)

# a compiled test: built, then run (a failed build answers for the test)
def chk.test.ran(+c: ChkRun, +exe: String) -> IO(ChkRun):
  chk.test.ran.if(U32.is_eq(chk.st(c), 0), c, exe)

def chk.test.run(+file: String, bin: Bool) -> IO(ChkRun):
  match bin:
    case False{}:
      chk.run("bend " ++ file, [], "bend", [file])
    case True{}:
      do IO<ChkRun>:
        c : ChkRun <- chk.run("bend " ++ file ++ " -o", [], "bend", [file, "-o", file ++ ".bin"])
        chk.test.ran(c, "./" ++ file ++ ".bin")

def chk.test.say(ok: Bool, +file: String, +rule: ChkRule, +r: ChkRun) -> IO(ChkLaw):
  match ok:
    case True{}:
      IO.pure(ChkLaw, ChkLaw{True{}, file})
    case False{}:
      do IO<ChkLaw>:
        IO.print("---- " ++ file ++ " exited " ++ U32.show(chk.st(r)) ++ " and printed:")
        chk.show(r)
        IO.print("---- " ++ chk.rule.show(rule))
        return ChkLaw{False{}, file}

def chk.test.got(+file: String, +rule: ChkRule, +r: ChkRun) -> IO(ChkLaw):
  chk.test.say(Bool.and(U32.is_eq(chk.st(r), 0), chk.rule(rule, S.b(chk.out(r)))), file, rule, r)

def chk.test(t: ChkTest) -> IO(ChkLaw):
  match t:
    case ChkTest{+file, bin, +rule}:
      do IO<ChkLaw>:
        +r : ChkRun <- chk.test.run(file, bin)
        chk.test.got(file, rule, r)

def chk.suite.go(ts: List<&2, ChkTest>) -> IO(List<&2, ChkLaw>):
  match ts:
    case Nil{}:
      IO.pure(List<&2, ChkLaw>, Nil{})
    case t <> more:
      do IO<List<&2, ChkLaw>>:
        l : ChkLaw <- chk.test(t)
        ls : List<&2, ChkLaw> <- chk.suite.go(more)
        return l <> ls

def chk.suite(xs: List<String>) -> IO(Unit):
  do IO<Unit>:
    ls : List<&2, ChkLaw> <- chk.suite.go(chk.tests())
    chk.verdict("suite", ls)

# train-run --------------------------------------------------------------------

# the tree trainer prints `step N validation loss X`: X is field 5
def chk.train.verdict(+out: String, +h: List<&2, U32>) -> IO(Unit):
  +vs = chk.col(S.split.lines(S.b(out)), S.b("validation loss"), 4n)
  chk.verdict("train-run", [ChkLaw{chk.fell(chk.nums(vs)), "the validation loss falls by more than 0.3 " ++ chk.vals(vs)}, chk.btc1("tiny.btc", h)])

def chk.train.run.go(+trainer: String, +corpus: String) -> IO(Unit):
  do IO<Unit>:
    +r : ChkRun <- chk.run("bend-train", ["CORPUS=" ++ corpus, "PRESET=tiny-v3", "TRAIN_STEPS=30", "TRAIN_BATCH=8", "TRAIN_LR=3e-3",
      "TRAIN_WARMUP=5", "OUT=tiny.btc"], trainer, ["--threads", "4"])
    chk.show(r)
    chk.must("bend-train", r)
    h : List<&2, U32> <- chk.head("tiny.btc")
    chk.train.verdict(chk.out(r), h)

def chk.train.run(xs: List<String>) -> IO(Unit):
  match xs:
    case trainer <> corpus <> Nil{}:
      chk.train.run.go(trainer, corpus)
    case _:
      IO.die(Unit, 2, "usage: Checks.bend train-run TRAINER CORPUS")

# dense-run --------------------------------------------------------------------

def chk.dense.vals(+r: ChkRun) -> List<&2, List<&2, U32>>:
  chk.kv(S.split.lines(S.b(chk.out(r))), S.b("validation_loss="))

# six steps of small4-v3 on the frozen corpus with optimizer opt
def chk.ident(+trainer: String, +frozen: String, +opt: String) -> IO(Unit):
  do IO<Unit>:
    +r : ChkRun <- chk.run("bend-train-dense " ++ opt, ["CORPUS=" ++ frozen, "PRESET=small4-v3", "TRAIN_STEPS=6", "TRAIN_BATCH=8", "TRAIN_MICRO=4",
      "TRAIN_LR=3e-3", "TRAIN_WARMUP=2", "TRAIN_OPT=" ++ opt, "EVAL_EVERY=3", "OUT=" ++ opt ++ ".btc"], trainer, ["--gpu", "off", "--threads", "4"])
    chk.show(r)
    chk.must("bend-train-dense " ++ opt, r)

def chk.sums(+got: List<&2, U32>, +want: List<&2, U32>, +goldens: String) -> ChkLaw:
  ChkLaw{S.eq(got, want), "the six-step trajectories' checkpoints match " ++ goldens
    ++ Bool.pick(String, S.eq(got, want), "", ": sha256sum printed\n" ++ S.str(got) ++ "where the goldens are\n" ++ S.str(want))}

# the dense trainer prints `validation_loss=X` fields
def chk.dense.verdict(+r: ChkRun, +h: List<&2, U32>, +q: ChkRun, +sums: List<&2, U32>, +g: List<&2, U32>, +goldens: String) -> IO(Unit):
  +vs = chk.dense.vals(r)
  +ws = chk.dense.vals(q)
  chk.verdict("dense-run", [ChkLaw{chk.fell(chk.nums(vs)), "the validation loss falls by more than 0.3 " ++ chk.vals(vs)},
    chk.btc1("tiny.btc", h),
    ChkLaw{chk.scored(chk.nums(ws)), "a validation set smaller than a micro-batch scores above 0 " ++ chk.vals(ws)},
    chk.sums(sums, g, goldens)])

def chk.dense.run.go(+trainer: String, +corpus: String, +frozen: String, +goldens: String) -> IO(Unit):
  do IO<Unit>:
    +r : ChkRun <- chk.run("bend-train-dense", ["CORPUS=" ++ corpus, "PRESET=tiny-v3", "TRAIN_STEPS=30", "TRAIN_BATCH=8", "TRAIN_LR=3e-3",
      "TRAIN_WARMUP=5", "OUT=tiny.btc"], trainer, ["--threads", "4"])
    chk.show(r)
    chk.must("bend-train-dense", r)
    h : List<&2, U32> <- chk.head("tiny.btc")
    # a validation set smaller than a micro-batch is scored, not 0 (run 2,
    # step 32,250: a shard's 3 windows at micro 4 logged loss 0, and
    # best_validation_loss stayed 0 for the rest of the run)
    +q : ChkRun <- chk.run("bend-train-dense (3 validation windows)", ["CORPUS=" ++ corpus, "PRESET=tiny-v3", "TRAIN_STEPS=2", "TRAIN_BATCH=8",
      "TRAIN_MICRO=4", "TRAIN_LR=3e-3", "TRAIN_WARMUP=1", "EVAL_EVERY=1", "EVAL_WINDOWS=3", "OUT=short.btc"], trainer, ["--gpu", "off", "--threads", "4"])
    chk.show(q)
    chk.must("bend-train-dense (3 validation windows)", q)
    # the trajectory itself, byte for byte: six steps of small4-v3, batch 8
    # in micro-batches of 4, AdamW and Muon, on a corpus nothing edits. A
    # layout change must leave these parameters unchanged.
    chk.ident(trainer, frozen, "adamw")
    chk.ident(trainer, frozen, "muon")
    +s : ChkRun <- chk.run("sha256sum", [], "sha256sum", ["adamw.btc", "muon.btc"])
    chk.must("sha256sum", s)
    g : List<&2, U32> <- S.read(goldens)
    chk.dense.verdict(r, h, q, S.b(chk.out(s)), g, goldens)

def chk.dense.run(xs: List<String>) -> IO(Unit):
  match xs:
    case trainer <> corpus <> frozen <> goldens <> Nil{}:
      chk.dense.run.go(trainer, corpus, frozen, goldens)
    case _:
      IO.die(Unit, 2, "usage: Checks.bend dense-run TRAINER CORPUS FROZEN GOLDENS")

# bulk-cpu ---------------------------------------------------------------------

# a run whose stdout goes to the file `to`: its stderr into the log, and it
# must exit 0
def chk.to(+what: String, +to: String, env: List<String>, prog: String, args: List<String>) -> IO(Unit):
  do IO<Unit>:
    +r : ChkRun <- chk.run.to(what, to, env, prog, args)
    IO.write(chk.err(r))
    chk.must(what, r)

def chk.build(+file: String, +exe: String) -> IO(Unit):
  do IO<Unit>:
    +r : ChkRun <- chk.run("bend " ++ file ++ " -o", [], "bend", [file, "-o", exe])
    chk.show(r)
    chk.must("bend " ++ file ++ " -o " ++ exe, r)

# a conformance program (Array.gemm, Array.einsum): its JS lane, its C build
# on the reference loops and on the fast kernels, the same bytes
def chk.conf(+src: String, +name: String) -> IO(List<&2, ChkLaw>):
  +file = src ++ "/gpu/" ++ name ++ ".bend"
  +exe = "./" ++ name ++ ".bin"
  do IO<List<&2, ChkLaw>>:
    chk.to("bend " ++ file, name ++ ".js", [], "bend", [file])
    chk.build(file, exe)
    chk.to(name ++ " BEND_FT=loop", name ++ ".loop", ["BEND_FT=loop"], exe, ["--gpu", "off", "--threads", "1"])
    a : ChkLaw <- chk.same(name ++ ".js", name ++ ".loop")
    chk.to(name ++ " on 8 threads", name ++ ".fast", [], exe, ["--gpu", "off", "--threads", "8"])
    b : ChkLaw <- chk.same(name ++ ".loop", name ++ ".fast")
    return [a, b]

def chk.bulk.threads(+exe: String, +t: String) -> IO(ChkLaw):
  do IO<ChkLaw>:
    chk.to("bulk-cpu on " ++ t ++ " threads", "actual." ++ t, [], exe, ["--gpu", "off", "--threads", t])
    chk.same("reference", "actual." ++ t)

# the seeded and adversarial cases: the reference loops against the C
# kernels and the default on 1, 8 and 16 threads
def chk.bulk(+src: String) -> IO(List<&2, ChkLaw>):
  +exe = {"./bulk-cpu.bin" : String}
  do IO<List<&2, ChkLaw>>:
    chk.build(src ++ "/tests/bulk-cpu.bend", exe)
    chk.to("bulk-cpu BEND_FT=loop", "reference", ["BEND_FT=loop"], exe, ["--gpu", "off", "--threads", "1"])
    chk.to("bulk-cpu BEND_FT=c", "actual.c", ["BEND_FT=c"], exe, ["--gpu", "off", "--threads", "8"])
    c : ChkLaw <- chk.same("reference", "actual.c")
    t1 : ChkLaw <- chk.bulk.threads(exe, "1")
    t8 : ChkLaw <- chk.bulk.threads(exe, "8")
    t16 : ChkLaw <- chk.bulk.threads(exe, "16")
    return [c, t1, t8, t16]

def chk.bulk.cpu.go(+src: String) -> IO(Unit):
  do IO<Unit>:
    g : List<&2, ChkLaw> <- chk.conf(src, "GemmConf")
    e : List<&2, ChkLaw> <- chk.conf(src, "EinsumConf")
    b : List<&2, ChkLaw> <- chk.bulk(src)
    chk.verdict("bulk-cpu", List.concat(&2, ChkLaw, [g, e, b]))

def chk.bulk.cpu(xs: List<String>) -> IO(Unit):
  match xs:
    case src <> Nil{}:
      chk.bulk.cpu.go(src)
    case _:
      IO.die(Unit, 2, "usage: Checks.bend bulk-cpu SRC")

# same A B: the two files byte for byte (cmp's verdict) ------------------------

def chk.same.cmd(xs: List<String>) -> IO(Unit):
  match xs:
    case +a <> +b <> Nil{}:
      do IO<Unit>:
        l : ChkLaw <- chk.same(a, b)
        chk.verdict("same", [l])
    case _:
      IO.die(Unit, 2, "usage: Checks.bend same A B")

# Main -------------------------------------------------------------------------

def chk.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend Checks.bend suite | train-run TRAINER CORPUS | dense-run TRAINER CORPUS FROZEN GOLDENS | bulk-cpu SRC | same A B")

# the subcommand's number (a match cannot scrutinize a computed value)
def chk.code(+c: String) -> Nat:
  Bool.pick(Nat, String.eq(c, "suite"), 1n, Bool.pick(Nat, String.eq(c, "train-run"), 2n,
    Bool.pick(Nat, String.eq(c, "dense-run"), 3n, Bool.pick(Nat, String.eq(c, "bulk-cpu"), 4n,
    Bool.pick(Nat, String.eq(c, "same"), 5n, 0n)))))

def chk.cmd(k: Nat, xs: List<String>) -> IO(Unit):
  match k:
    case 1n:
      chk.suite(xs)
    case 2n:
      chk.train.run(xs)
    case 3n:
      chk.dense.run(xs)
    case 4n:
      chk.bulk.cpu(xs)
    case 5n:
      chk.same.cmd(xs)
    case _:
      chk.usage()

def chk.args(xs: List<String>) -> IO(Unit):
  match xs:
    case +c <> more:
      chk.cmd(chk.code(c), more)
    case _:
      chk.usage()

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked
    argv : List<String> <- IO.args()
    chk.args(List.tail(&1, String, argv))
