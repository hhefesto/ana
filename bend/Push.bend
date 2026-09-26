import Base
import ./Sys.bend as S

# bend-push: stream the sharded corpus to a rented box, in the order the
# trainer consumes it.
#
#   bend-push [user@]host [port]
#   bend-push link [user@]host [port] [megabytes]
#
# Run it from the repository root.  The corpus is the largest thing that has
# to reach a card billed by the hour, so the plan and the tokenizer go first
# and then the shards in the plan's order (never a glob's: `ls` puts shard-100
# before shard-10).  The dense Bend trainer (TrainDense.bend) reads a shard
# when its segment starts and stops at one that is not there, so start it
# once the push is done or well ahead of it.
#
# Settings: TRAIN_ENV_FILE (default run/train-cloud.env) is read first, as
# KEY=VALUE lines (`export`, quotes and `#` comments allowed; no `$` expansion),
# and wins over the environment, as sourcing it did:
#   RUN_DIR SIZE TRAIN_BATCH SHARD_ARTICLES PLAN TOKENIZER_FILE
#                    the corpus (PLAN defaults to
#                    RUN_DIR/plan-SIZE-bTRAIN_BATCH-sSHARD_ARTICLES.tsv)
#   REMOTE_DIR       remote repo path      (default formalTransformer)
#   MAX_SHARDS       0 = all; N = send only the first N shards still missing
#   COMPRESS         1 = rsync -z --compress-level=1  (default 0: on a link
#                    faster than one core's gzip the CPU is the bottleneck;
#                    measured, a shard compresses by only 25%)
#   SKIP_LINK_CHECK  1 = skip `bend-push link`
#   DRY_RUN          1 = print the transfer order and exit, touching no network
#
# The acceptance test is the byte count on the box, never rsync's exit
# status.  rsync keeps partial files under --partial-dir, so a shard's name
# appears only when the file is whole.  One multiplexed ssh connection
# serves the whole run.  rsync's own progress is shown once each transfer
# ends (its output comes back whole).
#
# `link` refuses to start a deploy against a link that cannot carry it:
# boxes have accepted ssh and then reset every sustained transfer, so the
# test is a sustained MEGABYTES (20) transfer, not a login; it fails under
# MIN_KBS (500) kB/s.  Exit 0 = usable, 1 = do not deploy against this box.

# Text ---------------------------------------------------------------------------

def need(ok: Bool, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, msg)

def blank(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9))

def blank.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      blank(h)
    case Nil{}:
      False{}

def blank.drop(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      blank.drop(t, blank.head(t))
    case Nil{} _:
      Nil{}
    case h <> t False{}:
      h <> t

def ltrim(+xs: List<&2, U32>) -> List<&2, U32>:
  blank.drop(xs, blank.head(xs))

def nonempty(xss: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xss:
    case Nil{}:
      Nil{}
    case +x <> more:
      +r = nonempty(more)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(x), 0n), r, x <> r)

def tabs.sp(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, U32.is_eq(h, 9), 32, h) <> tabs.sp(t)

# the words of a line, as `read` splits them
def words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  nonempty(S.split(tabs.sp(xs), 32))

def nth(xs: List<&2, List<&2, U32>>, n: Nat) -> List<&2, U32>:
  match xs n:
    case x <> more 0n:
      x
    case x <> more 1n+k:
      nth(more, k)
    case Nil{} _:
      Nil{}

# the lines `while read` sees: a last line without its newline is not one
def lines.nl(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ls = S.split.lines(xs)
  Bool.pick(List<&2, List<&2, U32>>, S.suffix(xs, [10]), ls, List.take(&2, List<&2, U32>, ls, Nat.sub(List.length(&2, List<&2, U32>, ls), 1n)))

def no.cr(xs: List<&2, U32>) -> List<&2, U32>:
  List.filter(~U32, ~(c => U32.is_ne(c, 13)), xs)

def nat.of(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n)

# `dirname`: the path without its last component ("." when it has none)
def dirname(+p: String) -> String:
  +par = S.parent(p)
  Bool.pick(String, Bool.not(S.infix(S.b(p), [47])), ".", Bool.pick(String, String.is_empty(par), "/", par))

def strs(xs: List<&2, List<&2, U32>>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      S.str(x) <> strs(more)

def sum(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case x <> more:
      Nat.add(x, sum(more))

# Numbers as awk and printf wrote them ---------------------------------------------

def gib() -> Nat:
  Nat.mul(32768n, 32768n)

# n decimal digits of r / 2^30 (r < 2^30), the first first
def frac.digits(n: Nat, +r: Nat) -> List<&2, Nat>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      +t = Nat.mul(r, 10n)
      Nat.div(t, gib()) <> frac.digits(k, Nat.mod(t, gib()))

def int.digits(fuel: Nat, +q: Nat, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match fuel:
    case 0n:
      acc
    case 1n+f:
      Bool.pick(List<&2, Nat>, Nat.is_eq(q, 0n), acc, int.digits(f, Nat.div(q, 10n), Nat.mod(q, 10n) <> acc))

def first.nz(ds: List<&2, Nat>, +i: Nat) -> Maybe<&2, Nat>:
  match ds:
    case Nil{}:
      None{}
    case +d <> more:
      Bool.pick(Maybe<&2, Nat>, Nat.is_eq(d, 0n), first.nz(more, 1n+i), Some{i})

def any.nz(ds: List<&2, Nat>) -> Bool:
  match ds:
    case Nil{}:
      False{}
    case +d <> more:
      Bool.or(Bool.not(Nat.is_eq(d, 0n)), any.nz(more))

def head.nat(ns: List<&2, Nat>) -> Nat:
  match ns:
    case Nil{}:
      0n
    case x <> more:
      x

def value(ds: List<&2, Nat>, +acc: Nat) -> Nat:
  match ds:
    case Nil{}:
      acc
    case d <> more:
      value(more, Nat.add(Nat.mul(acc, 10n), d))

def pow10(n: Nat) -> Nat:
  match n:
    case 0n:
      1n
    case 1n+k:
      Nat.mul(10n, pow10(k))

def is.odd(+n: Nat) -> Bool:
  Nat.is_eq(Nat.mod(n, 2n), 1n)

def pow2mod100(n: Nat) -> Nat:
  match n:
    case 0n:
      1n
    case 1n+k:
      Nat.mod(Nat.mul(2n, pow2mod100(k)), 100n)

def pow2(n: Nat) -> Nat:
  match n:
    case 0n:
      1n
    case 1n+k:
      Nat.mul(2n, pow2(k))

# the largest t with 100 * 2^t <= k (k >= 100)
def log2.up(fuel: Nat, +k: Nat, +t: Nat) -> Nat:
  match fuel:
    case 0n:
      t
    case 1n+f:
      Bool.pick(Nat, Nat.is_le(Nat.mul(100n, pow2(1n+t)), k), log2.up(f, k, 1n+t), t)

# the smallest s >= 1 with k * 2^s >= 100 (k < 100)
def log2.down(fuel: Nat, +k: Nat, +s: Nat) -> Nat:
  match fuel:
    case 0n:
      s
    case 1n+f:
      Bool.pick(Nat, Nat.is_le(100n, Nat.mul(k, pow2(s))), s, log2.down(f, k, 1n+s))

# A tie at one decimal: the value is k / 100 (k ends in 5).  bash's printf
# reads the text as a double and rounds that: up when the nearest double
# lies above k / 100, down below, to even when k / 100 is exact.  (k * 2^e)
# mod 100 says which, e putting the 53-bit significand in [2^52, 2^53).
def tie.up(+k: Nat, +q: Nat) -> Bool:
  +e = Bool.pick(Nat, Nat.is_le(100n, k), Nat.sub(52n, log2.up(30n, k, 0n)), Nat.add(52n, log2.down(10n, k, 1n)))
  +res = Nat.mod(Nat.mul(Nat.mod(k, 100n), pow2mod100(e)), 100n)
  Bool.pick(Bool, Nat.is_eq(res, 0n), is.odd(q), Nat.is_lt(50n, res))

# printf %.1f of k / 10^f: the tenths
def tenths.at(+k: Nat, +g: Nat) -> Nat:
  +p = pow10(g)
  +q = Nat.div(k, p)
  +rm = Nat.mod(k, p)
  +half = Nat.div(p, 2n)
  Bool.pick(Nat, Nat.is_lt(half, rm), 1n+q, Bool.pick(Nat, Nat.is_lt(rm, half), q,
    Bool.pick(Nat, tie.up(Nat.add(Nat.mul(q, 10n), 5n), q), 1n+q, q)))

def tenths.big(big: Bool, +k: Nat, +g: Nat) -> Nat:
  match big:
    case True{}:
      0n
    case False{}:
      tenths.at(k, g)

def tenths(+k: Nat, f: Nat) -> Nat:
  match f:
    case 0n:
      Nat.mul(k, 10n)
    case 1n:
      k
    case 2n+(+g):
      tenths.big(Nat.is_le(8n, 1n+g), k, 1n+g)

# awk's %.6g of ds (ip integer digits): six significant digits, rounded half
# to even on the exact value, as k / 10^f
def six(+ds: List<&2, Nat>, +ip: Nat, +s: Nat) -> Nat & Nat:
  +c = Nat.add(s, 6n)
  +k = value(List.take(&2, Nat, ds, c), 0n)
  +rd = head.nat(List.drop(&2, Nat, ds, c))
  +up = Bool.or(Nat.is_lt(5n, rd), Bool.and(Nat.is_eq(rd, 5n), Bool.or(any.nz(List.drop(&2, Nat, ds, 1n+c)), is.odd(k))))
  (Bool.pick(Nat, up, 1n+k, k), Nat.sub(c, ip))

def gb.show(+t: Nat) -> String:
  Nat.show(Nat.div(t, 10n)) ++ "." ++ Nat.show(Nat.mod(t, 10n))

def gb.six(r: Nat & Nat) -> String:
  (k, f) = r
  gb.show(tenths(k, f))

def gb.at(+ds: List<&2, Nat>, +ip: Nat, m: Maybe<&2, Nat>) -> String:
  match m:
    case None{}:
      "0.0"
    case Some{+s}:
      gb.six(six(ds, ip, s))

# `printf %.1f "$(awk -v b=N 'BEGIN{print b/1073741824}')"`: bytes as GiB
def gb(+n: Nat) -> String:
  +ids = int.digits(20n, Nat.div(n, gib()), Nil{})
  +ds = List.append(&2, Nat, ids, frac.digits(40n, Nat.mod(n, gib())))
  gb.at(ds, List.length(&2, Nat, ids), first.nz(ds, 0n))

# Settings -------------------------------------------------------------------------

type Kv is Data:
  Kv{k: List<&2, U32>, v: List<&2, U32>}

def name.ok(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.and(Bool.or(Bool.or(U32.is_eq(h, 95), Bool.and(U32.is_le(48, h), U32.is_le(h, 57))),
        Bool.or(Bool.and(U32.is_le(65, h), U32.is_le(h, 90)), Bool.and(U32.is_le(97, h), U32.is_le(h, 122)))), name.ok(t))

def upto(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), Nil{}, h <> upto(t, c))

def word.end(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, blank(h), Nil{}, h <> word.end(t))

# a value: quoted, up to its closing quote; else up to the first blank
def val.of(+v: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.head.is(v, 34), upto(List.drop(&2, U32, v, 1n), 34),
    Bool.pick(List<&2, U32>, S.head.is(v, 39), upto(List.drop(&2, U32, v, 1n), 39), word.end(v)))

def digit.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.and(U32.is_le(48, h), U32.is_le(h, 57))

def env.kv(+l: List<&2, U32>) -> Maybe<&2, Kv>:
  +a = ltrim(l)
  +x = Bool.pick(List<&2, U32>, S.prefix(a, S.b("export ")), ltrim(List.drop(&2, U32, a, 7n)), a)
  +k = upto(x, 61)
  +ok = Bool.and(Bool.and(Nat.is_lt(0n, S.len(k)), name.ok(k)), Bool.and(Bool.not(S.head.is(k, 35)), Nat.is_lt(S.len(k), S.len(x))))
  Bool.pick(Maybe<&2, Kv>, Bool.and(ok, Bool.not(digit.head(k))),
    Some{Kv{k, val.of(List.drop(&2, U32, x, 1n+S.len(k)))}}, None{})

def env.put(m: Maybe<&2, Kv>, acc: List<&2, Kv>) -> List<&2, Kv>:
  match m:
    case Some{kv}:
      kv <> acc
    case None{}:
      acc

# the file's settings, the last first
def env.kvs(ls: List<&2, List<&2, U32>>, acc: List<&2, Kv>) -> List<&2, Kv>:
  match ls:
    case Nil{}:
      acc
    case +l <> more:
      env.kvs(more, env.put(env.kv(l), acc))

def kv.get(kvs: List<&2, Kv>, +k: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      None{}
    case Kv{+x, +v} <> more:
      Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(x, k), Some{v}, kv.get(more, k))

def or.default(+v: String, +d: String) -> String:
  Bool.pick(String, String.is_empty(v), d, v)

def setting.got(m: Maybe<&2, List<&2, U32>>, +name: String, +d: String) -> IO(String):
  match m:
    case Some{v}:
      IO.pure(String, or.default(S.str(v), d))
    case None{}:
      do IO<String>:
        +e : String <- S.env(name, "")
        return or.default(e, d)

# `${NAME:-d}` after sourcing the file: the file's value, else the
# environment's, else d (an empty value counts as none)
def setting(kvs: List<&2, Kv>, +name: String, +d: String) -> IO(String):
  setting.got(kv.get(kvs, S.b(name)), name, d)

# Processes ------------------------------------------------------------------------

def is.dir(+p: String) -> IO(Bool):
  do IO<Bool>:
    +o : S.Out <- S.run(".", [], 60, "test", ["-d", p], Nil{})
    return U32.is_eq(S.Out.status(o), 0)

def is.file(+p: String) -> IO(Bool):
  do IO<Bool>:
    +o : S.Out <- S.run(".", [], 60, "test", ["-f", p], Nil{})
    return U32.is_eq(S.Out.status(o), 0)

def err.say(quiet: Bool, +err: String) -> IO(Unit):
  match quiet:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print_err(S.str(S.chomp(S.b(err))))

def out.pair(+code: U32, oe: String & String) -> IO(S.Out):
  (out, +err) = oe
  do IO<S.Out>:
    err.say(String.is_empty(err), err)
    return S.Out{code, S.b(out)}

def out.done(p: U32 & (String & String)) -> IO(S.Out):
  (code, oe) = p
  out.pair(code, oe)

def out.got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(S.Out):
  match r:
    case Done{p}:
      out.done(p)
    case Fail{(+code, msg)}:
      IO.pure(S.Out, S.Out{Bool.pick(U32, U32.is_eq(code, 110), 124, 125), Nil{}})

# a command's stdout; its stderr passes through to ours
def out.only(+secs: U32, prog: String, args: List<String>) -> IO(S.Out):
  do IO<S.Out>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", "cd \"$1\" && shift && exec \"$@\"", "sh", ".", "timeout", U32.show(secs), prog], args),
        "", S.cap.bytes(), U32.mul(U32.add(secs, 30), 1000))
    out.got(r)

# a command whose output is only shown
def shown(+o: S.Out) -> IO(U32):
  +t = S.chomp(S.Out.text(o))
  do IO<U32>:
    err.say(Nat.is_eq(S.len(t), 0n), S.str(t))
    return S.Out.status(o)

# Link check ---------------------------------------------------------------------

def link.opts(+port: String) -> List<String>:
  ["-p", port, "-o", "BatchMode=yes", "-o", "ConnectTimeout=25", "-o", "ServerAliveInterval=15"]

def last.line(ls: List<&2, List<&2, U32>>, +d: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      d
    case l <> more:
      last.line(more, l)

def pad2(+n: Nat) -> String:
  Bool.pick(String, Nat.is_lt(n, 10n), "0" ++ Nat.show(n), Nat.show(n))

# round(a / b), halves up (b > 0)
def rdiv(+a: Nat, +b: Nat) -> Nat:
  Nat.div(Nat.add(Nat.mul(a, 2n), b), Nat.mul(b, 2n))

def link.ok.line(+mb: String, +cs: Nat, +kbs: Nat) -> String:
  "check-link: OK — " ++ mb ++ " MB in " ++ Nat.show(Nat.div(cs, 100n)) ++ "." ++ pad2(Nat.mod(cs, 100n)) ++ " s (" ++ Nat.show(kbs) ++ " kB/s)"

# The link's verdict: whether it is usable, the line for stdout, the lines
# for stderr.
type Lk is Data:
  Lk{ok: Bool, out: String, err: String}

def link.rate(+mb: String, +want: Nat, +ms: Nat, +min: Nat) -> Lk:
  +cs = Nat.max(rdiv(ms, 10n), 1n)
  +kbs = Nat.max(rdiv(Nat.mul(want, 100n), Nat.mul(1024n, cs)), 1n)
  +hours = rdiv(Nat.mul(15728640n, 10n), Nat.mul(kbs, 3600n))
  Bool.pick(Lk, Nat.is_lt(kbs, min),
    Lk{False{}, link.ok.line(mb, cs, kbs), "check-link: WARNING — under " ++ Nat.show(min) ++ " kB/s.\n  The 15 GB corpus would take " ++ gb.show(hours) ++ " hours at this rate."},
    Lk{True{}, link.ok.line(mb, cs, kbs), ""})

def link.after(+host: String, +port: String, +mb: String, +want: Nat, +ms: Nat, +min: Nat, +o: S.Out) -> IO(Lk):
  +got = S.str(last.line(S.split.lines(no.cr(S.Out.text(o))), Nil{}))
  do IO<Lk>:
    rm : S.Out <- S.run.quiet(".", [], 60, "ssh", List.append(&1, String, link.opts(port), [host, "rm -f /tmp/.link-probe"]), Nil{})
    return Bool.pick(Lk, String.eq(or.default(got, "0"), Nat.show(want)), link.rate(mb, want, ms, min),
      Lk{False{}, "", "check-link: FAILED — " ++ got ++ " of " ++ Nat.show(want) ++ " bytes arrived. Destroy this box."})

def link.sent.if(ok: Bool, +host: String, +port: String, +mb: String, +want: Nat, +t0: Nat, +min: Nat, +o: S.Out) -> IO(Lk):
  match ok:
    case False{}:
      IO.pure(Lk, Lk{False{}, "", "check-link: FAILED — the transfer did not complete.\n  This box will not carry the closure or the corpus. Destroy it."})
    case True{}:
      do IO<Lk>:
        +t1 : Nat <- IO.time()
        link.after(host, port, mb, want, Nat.sub(t1, t0), min, o)

def link.check(+host: String, +port: String, +mb: String) -> IO(Lk):
  +want = Nat.mul(nat.of(S.b(mb)), 1048576n)
  do IO<Lk>:
    +min : Nat <- S.env.nat("MIN_KBS", 500n)
    IO.print("check-link: sustained " ++ mb ++ " MB transfer to " ++ host ++ ":" ++ port ++ " ...")
    +t0 : Nat <- IO.time()
    +o : S.Out <- S.run.quiet(".", [], 300, "sh", List.append(&1, String,
      ["-c", "dd if=/dev/zero bs=1M count=\"$1\" 2>/dev/null | { shift; exec \"$@\"; }", "sh", mb, "ssh"],
      List.append(&1, String, link.opts(port), [host, "cat > /tmp/.link-probe && stat -c %s /tmp/.link-probe"])), Nil{})
    link.sent.if(U32.is_eq(S.Out.status(o), 0), host, port, mb, want, t0, min, o)

def say.out(quiet: Bool, +s: String) -> IO(Unit):
  match quiet:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print(s)

def lk.ok(+l: Lk) -> Bool:
  match l:
    case Lk{ok, o, e}:
      ok

def Lk.out(+l: Lk) -> String:
  match l:
    case Lk{ok, o, e}:
      o

def Lk.err(+l: Lk) -> String:
  match l:
    case Lk{ok, o, e}:
      e

def link.fin(ok: Bool, +err: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, err)

def link.exit(+l: Lk) -> IO(Unit):
  do IO<Unit>:
    say.out(String.is_empty(Lk.out(l)), Lk.out(l))
    link.fin(lk.ok(l), Lk.err(l))

def link(+host: String, +port: String, +mb: String) -> IO(Unit):
  do IO<Unit>:
    +l : Lk <- link.check(host, port, mb)
    link.exit(l)

# The push ---------------------------------------------------------------------------

type Pc is Data:
  Pc{host: String, port: String, size: String, rd: String, plan: String, tok: String, remote: String, max: Nat, comp: Bool, skip: Bool, dry: Bool}

def Pc.host(+p: Pc) -> String:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      h

def Pc.port(+p: Pc) -> String:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      po

def Pc.size(+p: Pc) -> String:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      s

def Pc.rd(+p: Pc) -> String:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      r

def Pc.plan(+p: Pc) -> String:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      pl

def Pc.tok(+p: Pc) -> String:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      t

def Pc.remote(+p: Pc) -> String:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      re

def Pc.max(+p: Pc) -> Nat:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      m

def Pc.comp(+p: Pc) -> Bool:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      c

def Pc.skip(+p: Pc) -> Bool:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      sk

def Pc.dry(+p: Pc) -> Bool:
  match p:
    case Pc{h, po, s, r, pl, t, re, m, c, sk, d}:
      d

# the shard indices, in the plan's order: field 2 of each `segment` row
def plan.shards(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +ws = words(l)
      +r = plan.shards(more)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(nth(ws, 0n), S.b("segment")), nth(ws, 1n) <> r, r)

def shard.path(+rd: String, +size: String, +k: List<&2, U32>) -> String:
  rd ++ "/shard-" ++ S.str(k) ++ "-" ++ size ++ ".corpus"

def shard.paths(+rd: String, +size: String, ks: List<&2, List<&2, U32>>) -> List<String>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> more:
      shard.path(rd, size, k) <> shard.paths(rd, size, more)

def exist.all(ps: List<String>) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> more:
      do IO<Unit>:
        +there : Bool <- is.file(p)
        need(there, "push-corpus: local corpus missing: " ++ p ++ "\n  The local corpus is incomplete; rebuild it before pushing.")
        exist.all(more)

def nats(ls: List<&2, List<&2, U32>>) -> List<&2, Nat>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      nat.of(l) <> nats(more)

def sizes.got(+o: S.Out) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    need(U32.is_eq(S.Out.status(o), 0), "push-corpus: stat failed (exit " ++ U32.show(S.Out.status(o)) ++ ")")
    return nats(S.split.lines(S.Out.text(o)))

# the sizes of files, in bytes
def sizes.of(ps: List<String>) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    +o : S.Out <- out.only(600, "stat", "-c" <> "%s" <> ps)
    sizes.got(o)

type It is Data:
  It{k: List<&2, U32>, bytes: Nat}

def items(ks: List<&2, List<&2, U32>>, ns: List<&2, Nat>) -> List<&2, It>:
  match ks ns:
    case k <> km n <> nm:
      It{k, n} <> items(km, nm)
    case _ _:
      Nil{}

def dry.list(its: List<&2, It>, +rd: String, +size: String, +n: Nat) -> IO(Unit):
  match its:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case It{+k, +b} <> more:
      do IO<Unit>:
        IO.print("  " ++ Nat.show(n) ++ ". " ++ shard.path(rd, size, k) ++ " (" ++ Nat.show(b) ++ " bytes)")
        dry.list(more, rd, size, 1n+n)

def dry.run(+pc: Pc, its: List<&2, It>) -> IO(Unit):
  do IO<Unit>:
    IO.print("push-corpus: DRY_RUN — transfer order:")
    IO.print("  1. " ++ Pc.plan(pc))
    IO.print("  2. " ++ Pc.tok(pc))
    dry.list(its, Pc.rd(pc), Pc.size(pc), 3n)

# The transfer: one ssh master connection, rsync with --partial-dir, the
# byte count on the box as the test.
type Cx is Data:
  Cx{host: String, ssh: List<&2, String>, sshcmd: String, ropts: List<&2, String>}

def Cx.host(+c: Cx) -> String:
  match c:
    case Cx{h, s, sc, r}:
      h

def to1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> to1(more)

def Cx.ssh(+c: Cx) -> List<String>:
  match c:
    case Cx{h, s, sc, r}:
      to1(s)

def Cx.sshcmd(+c: Cx) -> String:
  match c:
    case Cx{h, s, sc, r}:
      sc

def Cx.ropts(+c: Cx) -> List<String>:
  match c:
    case Cx{h, s, sc, r}:
      to1(r)

def when(ok: Bool, act: IO(U32), +st: U32) -> IO(U32):
  match ok:
    case True{}:
      act
    case False{}:
      IO.pure(U32, st)

def ssh.args(+c: Cx, +cmd: String) -> List<String>:
  List.append(&1, String, Cx.ssh(c), [Cx.host(c), cmd])

def rsync(+c: Cx, +src: String, +dest: String) -> IO(U32):
  do IO<U32>:
    +o : S.Out <- out.only(86400, "rsync", List.append(&1, String, Cx.ropts(c), ["-e", Cx.sshcmd(c), src, dest]))
    +t : List<&2, U32> = S.chomp(S.Out.text(o))
    say.out(Nat.is_eq(S.len(t), 0n), S.str(t))
    return S.Out.status(o)

def retry.next(fuel: Nat, ok: Bool, over: Bool, +c: Cx, +src: String, +dest: String, +attempt: Nat) -> IO(U32):
  match fuel ok over:
    case _ True{} _:
      IO.pure(U32, 0)
    case _ False{} True{}:
      do IO<U32>:
        IO.print_err("push-corpus: transfer failed after 8 attempts")
        return 1
    case 0n _ _:
      IO.pure(U32, 1)
    case 1n+f False{} False{}:
      do IO<U32>:
        IO.print_err("push-corpus: interrupted, resuming (" ++ Nat.show(1n+attempt) ++ "/8)...")
        IO.sleep(5000)
        +st : U32 <- rsync(c, src, dest)
        retry.next(f, U32.is_eq(st, 0), Nat.is_lt(8n, 2n+attempt), c, src, dest, 1n+attempt)

# rsync until it succeeds, eight attempts at most
def retry(+c: Cx, +src: String, +dest: String) -> IO(U32):
  do IO<U32>:
    +st : U32 <- rsync(c, src, dest)
    retry.next(9n, U32.is_eq(st, 0), False{}, c, src, dest, 1n)

def verify.say(conn: Bool, same: Bool, +st: U32, +remote: String, +actual: String, +want: Nat) -> IO(U32):
  match conn same:
    case False{} _:
      IO.pure(U32, st)
    case True{} True{}:
      IO.pure(U32, 0)
    case True{} False{}:
      do IO<U32>:
        IO.print_err("push-corpus: " ++ remote ++ " is " ++ actual ++ " bytes on the box, expected " ++ Nat.show(want))
        return 1

def verify.got(+remote: String, +want: Nat, +o: S.Out) -> IO(U32):
  +actual = S.str(S.chomp(no.cr(S.Out.text(o))))
  verify.say(U32.is_eq(S.Out.status(o), 0), String.eq(actual, Nat.show(want)), S.Out.status(o), remote, actual, want)

# the acceptance test: the byte count on the box
def verify(+c: Cx, +remote: String, +want: Nat) -> IO(U32):
  do IO<U32>:
    +o : S.Out <- out.only(3600, "ssh", ssh.args(c, "stat -c %s '" ++ remote ++ "' 2>/dev/null || echo 0"))
    verify.got(remote, want, o)

# what the box already holds: `name bytes` for each shard there
def have.of(ls: List<&2, List<&2, U32>>) -> List<&2, Kv>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +ws = words(l)
      +r = have.of(more)
      Bool.pick(List<&2, Kv>, Nat.is_eq(S.len(nth(ws, 0n)), 0n), r, Kv{nth(ws, 0n), nth(ws, 1n)} <> r)

def have.get(kvs: List<&2, Kv>, +k: List<&2, U32>, +d: List<&2, U32>) -> List<&2, U32>:
  match kvs:
    case Nil{}:
      d
    case Kv{+x, +v} <> more:
      have.get(more, k, Bool.pick(List<&2, U32>, S.eq(x, k), v, d))

type Ps is Data:
  Ps{go: Bool, st: U32, sent: Nat, sbytes: Nat, skipped: Nat}

def landed(first: Bool, +k: List<&2, U32>) -> IO(Unit):
  match first:
    case True{}:
      IO.print("push-corpus: shard " ++ S.str(k) ++ " has landed.")
    case False{}:
      IO.pure(Unit, Unit{})

def one.sent(+k: List<&2, U32>, +b: Nat, +sent: Nat, +sb: Nat, +sk: Nat, +st: U32) -> IO(Ps):
  do IO<Ps>:
    landed(Bool.and(U32.is_eq(st, 0), Nat.is_eq(sent, 0n)), k)
    return Ps{U32.is_eq(st, 0), st, 1n+sent, Nat.add(sb, b), sk}

def one.push(+c: Cx, +rrun: String, +base: String, +local: String, +k: List<&2, U32>, +b: Nat, +n: Nat, +total: Nat, +sent: Nat, +sb: Nat, +sk: Nat) -> IO(Ps):
  do IO<Ps>:
    IO.print("push-corpus: shard " ++ S.str(k) ++ " (" ++ Nat.show(Nat.add(Nat.add(sent, sk), 1n)) ++ " of " ++ Nat.show(n) ++ ", " ++ gb(sb) ++ " of " ++ gb(total) ++ " GB)")
    +s1 : U32 <- retry(c, local, Cx.host(c) ++ ":" ++ rrun ++ "/")
    +s2 : U32 <- when(U32.is_eq(s1, 0), verify(c, rrun ++ "/" ++ base, b), s1)
    one.sent(k, b, sent, sb, sk, s2)

def one.at(there: Bool, stop: Bool, +c: Cx, +pc: Pc, +rrun: String, +base: String, +k: List<&2, U32>, +b: Nat, +n: Nat, +total: Nat, +sent: Nat, +sb: Nat, +sk: Nat) -> IO(Ps):
  match there stop:
    case True{} _:
      IO.pure(Ps, Ps{True{}, 0, sent, Nat.add(sb, b), 1n+sk})
    case False{} True{}:
      do IO<Ps>:
        IO.print("push-corpus: reached MAX_SHARDS=" ++ Nat.show(Pc.max(pc)) ++ " — stopping.")
        return Ps{False{}, 0, sent, sb, sk}
    case False{} False{}:
      one.push(c, rrun, base, shard.path(Pc.rd(pc), Pc.size(pc), k), k, b, n, total, sent, sb, sk)

def one(+c: Cx, +pc: Pc, +have: List<&2, Kv>, +n: Nat, +total: Nat, it: It, +sent: Nat, +sb: Nat, +sk: Nat) -> IO(Ps):
  match it:
    case It{+k, +b}:
      +base = "shard-" ++ S.str(k) ++ "-" ++ Pc.size(pc) ++ ".corpus"
      +rrun = Pc.remote(pc) ++ "/" ++ Pc.rd(pc)
      one.at(S.eq(have.get(have, S.b(base), S.b("0")), S.b(Nat.show(b))), Bool.and(Nat.is_lt(0n, Pc.max(pc)), Nat.is_le(Pc.max(pc), sent)),
        c, pc, rrun, base, k, b, n, total, sent, sb, sk)

def loop(its: List<&2, It>, +c: Cx, +pc: Pc, +have: List<&2, Kv>, +n: Nat, +total: Nat, ps: Ps) -> IO(Ps):
  match its ps:
    case it <> more Ps{True{}, st, sent, sb, sk}:
      IO.bind(Ps, Ps, one(c, pc, have, n, total, it, sent, sb, sk), loop(more, c, pc, have, n, total))
    case _ other:
      IO.pure(Ps, other)

def done.say(+pc: Pc, +sent: Nat, +sk: Nat) -> IO(Unit):
  +rd = Pc.rd(pc)
  do IO<Unit>:
    IO.print("push-corpus: done — " ++ Nat.show(sent) ++ " shard(s) sent, " ++ Nat.show(sk) ++ " already present.")
    IO.print("")
    IO.print("On the box, from ~/" ++ Pc.remote(pc) ++ ", point the dense Bend trainer at what landed")
    IO.print("(bend/gpu/hot.sh sets the rest of its environment):")
    IO.print("")
    IO.print("  PLAN=" ++ rd ++ "/" ++ S.base(Pc.plan(pc)) ++ " RUN_DIR=" ++ rd ++ " SHARD_SIZE=" ++ Pc.size(pc) ++ " TOKENIZER_FILE=" ++ Pc.tok(pc))

def fin.if(ok: Bool, +pc: Pc, +sent: Nat, +sk: Nat, +st: U32) -> IO(U32):
  match ok:
    case True{}:
      do IO<U32>:
        done.say(pc, sent, sk)
        return 0
    case False{}:
      IO.pure(U32, st)

def loop.fin(+pc: Pc, ps: Ps) -> IO(U32):
  match ps:
    case Ps{g, +st, +sent, sb, +sk}:
      fin.if(U32.is_eq(st, 0), pc, sent, sk, st)

def shards.push(+c: Cx, +pc: Pc, its: List<&2, It>, +n: Nat, +total: Nat) -> IO(U32):
  +rrun = Pc.remote(pc) ++ "/" ++ Pc.rd(pc)
  do IO<U32>:
    +o : S.Out <- out.only(3600, "ssh", ssh.args(c, "find '" ++ rrun ++ "' -maxdepth 1 -name 'shard-*-" ++ Pc.size(pc) ++ ".corpus' -printf '%f %s\\n' 2>/dev/null || true"))
    +have : List<&2, Kv> = have.of(S.split.lines(no.cr(S.Out.text(o))))
    ps : Ps <- loop(its, c, pc, have, n, total, Ps{True{}, 0, 0n, 0n, 0n})
    loop.fin(pc, ps)

# the plan and the tokenizer go first, so the box can start the moment
# shard 0 lands
def plan.first(+c: Cx, +pc: Pc, +rrun: String) -> IO(U32):
  do IO<U32>:
    IO.print("push-corpus: plan + tokenizer -> " ++ rrun)
    retry(c, Pc.plan(pc), Cx.host(c) ++ ":" ++ rrun ++ "/")

def body.go(+c: Cx, +pc: Pc, its: List<&2, It>, +n: Nat, +total: Nat, +pt: List<&2, Nat>) -> IO(U32):
  +rrun = Pc.remote(pc) ++ "/" ++ Pc.rd(pc)
  +rtok = Pc.remote(pc) ++ "/" ++ dirname(Pc.tok(pc))
  do IO<U32>:
    +o0 : S.Out <- S.run(".", [], 3600, "ssh", ssh.args(c, "mkdir -p '" ++ rrun ++ "' '" ++ rtok ++ "'"), Nil{})
    +s0 : U32 <- shown(o0)
    +s1 : U32 <- when(U32.is_eq(s0, 0), plan.first(c, pc, rrun), s0)
    +s2 : U32 <- when(U32.is_eq(s1, 0), retry(c, Pc.tok(pc), Cx.host(c) ++ ":" ++ rtok ++ "/"), s1)
    +s3 : U32 <- when(U32.is_eq(s2, 0), verify(c, rrun ++ "/" ++ S.base(Pc.plan(pc)), head.nat(pt)), s2)
    +s4 : U32 <- when(U32.is_eq(s3, 0), verify(c, rtok ++ "/" ++ S.base(Pc.tok(pc)), head.nat(List.drop(&2, Nat, pt, 1n))), s3)
    when(U32.is_eq(s4, 0), shards.push(c, pc, its, n, total), s4)

def cleanup(+c: Cx, +dir: String) -> IO(Unit):
  do IO<Unit>:
    o : S.Out <- S.run.quiet(".", [], 60, "ssh", List.append(&1, String, Cx.ssh(c), ["-O", "exit", Cx.host(c)]), Nil{})
    S.rm(dir)

def exit.with(+st: U32) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(st, 0), IO.pure(Unit, Unit{}), IO.die(Unit, st, "push-corpus: stopped (exit " ++ U32.show(st) ++ ")"))

def real.go(+pc: Pc, its: List<&2, It>, +n: Nat, +total: Nat) -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    +port : String = Pc.port(pc)
    +ctl : String = "ControlPath=" ++ dir ++ "/%r@%h:%p"
    +ssh : List<&2, String> = ["-p", port, "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "ControlMaster=auto", "-o", "ControlPersist=60", "-o", ctl]
    +sshcmd : String = "ssh -p " ++ port ++ " -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ControlMaster=auto -o ControlPersist=60 -o " ++ ctl
    +ropts : List<&2, String> = List.append(&2, String, List.append(&2, String, ["-a", "--timeout=120", "--info=progress2"],
      Bool.pick(List<&2, String>, Pc.comp(pc), ["-z", "--compress-level=1"], [])), ["--partial-dir=.rsync-partial"])
    +c : Cx = Cx{Pc.host(pc), ssh, sshcmd, ropts}
    +pt : List<&2, Nat> <- sizes.of([Pc.plan(pc), Pc.tok(pc)])
    +st : U32 <- body.go(c, pc, its, n, total, pt)
    cleanup(c, dir)
    exit.with(st)

def link.gate(skip: Bool, +pc: Pc) -> IO(Unit):
  match skip:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        +l : Lk <- link.check(Pc.host(pc), Pc.port(pc), "20")
        say.out(String.is_empty(Lk.out(l)), Lk.out(l))
        err.say(String.is_empty(Lk.err(l)), Lk.err(l))
        need(lk.ok(l), "push-corpus: aborting — this box cannot carry 15 GB.")

def mode(dry: Bool, +pc: Pc, its: List<&2, It>, +n: Nat, +total: Nat) -> IO(Unit):
  match dry:
    case True{}:
      dry.run(pc, its)
    case False{}:
      do IO<Unit>:
        link.gate(Pc.skip(pc), pc)
        real.go(pc, its, n, total)

def push.go(+pc: Pc) -> IO(Unit):
  +rd = Pc.rd(pc)
  +plan = Pc.plan(pc)
  +tok = Pc.tok(pc)
  do IO<Unit>:
    need(Bool.not(S.prefix(S.b(rd), [47])), "push-corpus: RUN_DIR must be relative to the repo root: " ++ rd)
    +d : Bool <- is.dir(rd)
    need(d, "push-corpus: run dir not found: " ++ rd)
    +p : Bool <- is.file(plan)
    need(p, "push-corpus: plan not found: " ++ plan)
    +t : Bool <- is.file(tok)
    need(t, "push-corpus: tokenizer not found: " ++ tok)
    +ptxt : List<&2, U32> <- S.read(plan)
    +ks : List<&2, List<&2, U32>> = plan.shards(lines.nl(ptxt))
    +n : Nat = List.length(&2, List<&2, U32>, ks)
    need(Nat.is_lt(0n, n), "push-corpus: no segment rows in " ++ plan)
    exist.all(shard.paths(rd, Pc.size(pc), ks))
    +ns : List<&2, Nat> <- sizes.of(shard.paths(rd, Pc.size(pc), ks))
    +total : Nat = sum(ns)
    IO.print("push-corpus: " ++ Nat.show(n) ++ " shards, " ++ gb(total) ++ " GB, plan order from " ++ plan)
    mode(Pc.dry(pc), pc, items(ks, ns), n, total)

def read.if(there: Bool, +p: String) -> IO(List<&2, U32>):
  match there:
    case True{}:
      S.read(p)
    case False{}:
      IO.pure(List<&2, U32>, Nil{})

def push(+host: String, +port: String) -> IO(Unit):
  do IO<Unit>:
    +ef0 : String <- S.env("TRAIN_ENV_FILE", "")
    +ef : String = or.default(ef0, "run/train-cloud.env")
    +isf : Bool <- is.file(ef)
    +etxt : List<&2, U32> <- read.if(isf, ef)
    +kvs : List<&2, Kv> = env.kvs(S.split.lines(etxt), Nil{})
    +size : String <- setting(kvs, "SIZE", "bpe100m")
    +rd : String <- setting(kvs, "RUN_DIR", "run/mixed-bpe100m-s32000")
    +batch : String <- setting(kvs, "TRAIN_BATCH", "64")
    +sa : String <- setting(kvs, "SHARD_ARTICLES", "32000")
    +plan : String <- setting(kvs, "PLAN", rd ++ "/plan-" ++ size ++ "-b" ++ batch ++ "-s" ++ sa ++ ".tsv")
    +tok : String <- setting(kvs, "TOKENIZER_FILE", "run/enwiki-fineweb-32k.bpe")
    +remote : String <- setting(kvs, "REMOTE_DIR", "formalTransformer")
    +mx : String <- setting(kvs, "MAX_SHARDS", "0")
    +comp : String <- setting(kvs, "COMPRESS", "0")
    +skip : String <- setting(kvs, "SKIP_LINK_CHECK", "0")
    +dry : String <- setting(kvs, "DRY_RUN", "0")
    push.go(Pc{host, port, size, rd, plan, tok, remote, nat.of(S.b(mx)), String.eq(comp, "1"), String.eq(skip, "1"), String.eq(dry, "1")})

# Main -------------------------------------------------------------------------------

def usage() -> IO(Unit):
  IO.die(Unit, 1, "usage: bend-push [user@]host [port] | bend-push link [user@]host [port] [megabytes]")

def args.link(xs: List<String>) -> IO(Unit):
  match xs:
    case +h <> Nil{}:
      link(h, "22", "20")
    case +h <> +p <> Nil{}:
      link(h, p, "20")
    case +h <> +p <> +m <> Nil{}:
      link(h, p, m)
    case _:
      usage()

def args.go(lk: Bool, xs: List<String>) -> IO(Unit):
  match lk xs:
    case True{} x <> more:
      args.link(more)
    case False{} +h <> Nil{}:
      push(h, "22")
    case False{} +h <> +p <> Nil{}:
      push(h, p)
    case _ _:
      usage()

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case +x <> more:
      args.go(String.eq(x, "link"), x <> more)
    case Nil{}:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args(xs)
