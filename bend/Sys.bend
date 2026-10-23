import Base
import ./Tokenizer.bend as Tk
import ./Nul.bend as Ns

# Sys: what the corpus tools need from the operating system, over the one
# primitive that reaches it, Process.run (Base's).
#
# Meaning.  `run(dir, env, secs, prog, args, input)` is what the shell line
#
#   cd DIR && timeout SECS env K=V.. PROG ARGS.. <INPUT 2>&1
#
# prints and exits with: Out{status, text}.  It is exactly that line, run
# through `sh -c` (the one shell shim the tools keep), because Process.run
# has no working directory, no environment of its own and keeps stderr
# apart; coreutils `timeout` gives the scripts' timeout semantics (status
# 124, the output so far kept, the command's process group killed).
# Process.run's own limit, SECS + 30 s, is only a backstop (status 124, no
# text).  Text is bytes (List<&2, U32>, UTF-8) everywhere here; Process.run
# speaks Strings, so its output is re-encoded, and bytes that are not UTF-8
# arrive as U+FFFD.  Output past `cap.bytes()` answers status 125.

# Text as bytes ------------------------------------------------------------

def b(s: String) -> List<&2, U32>:
  Tk.utf8.bytes(s)

def str.tail(t: String, n: Nat) -> String:
  match n:
    case 0n:
      t
    case 1n+k:
      t ++ "\u{FFFD}"

def str.fin(d: Tk.Dec) -> String:
  match d:
    case Tk.Dec{t, p}:
      str.tail(t, List.length(&2, U32, p))

def str(+xs: List<&2, U32>) -> String:
  str.fin(Tk.utf8.decode(1n+List.length(&2, U32, xs), xs, Tk.utf8.mode(xs)))

def append(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, xs, ys)

def len(+xs: List<&2, U32>) -> Nat:
  List.length(&2, U32, xs)

def eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(U32.is_eq(x, y), eq(xt, yt))
    case _ _:
      False{}

# does xs start with p
def prefix(xs: List<&2, U32>, p: List<&2, U32>) -> Bool:
  match xs p:
    case _ Nil{}:
      True{}
    case Nil{} _:
      False{}
    case +x <> xt +y <> pt:
      Bool.and(U32.is_eq(x, y), prefix(xt, pt))

# xs without the prefix p (xs when it does not start with p)
def strip(+xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, prefix(xs, p), List.drop(&2, U32, xs, List.length(&2, U32, p)), xs)

def head.is(+xs: List<&2, U32>, +c: U32) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, c)
    case Nil{}:
      False{}

# xs with every occurrence of p replaced by r, left to right, the way
# `sed s|p|r|g` does it: skip counts the bytes of a match still to drop,
# hit is whether p starts here
def replace.go(xs: List<&2, U32>, +p: List<&2, U32>, +r: List<&2, U32>, +n: Nat, skip: Nat, hit: Bool) -> List<&2, U32>:
  match xs skip hit:
    case Nil{} _ _:
      Nil{}
    case h <> +t 1n+s _:
      replace.go(t, p, r, n, s, prefix(t, p))
    case h <> +t 0n True{}:
      List.append(&2, U32, r, replace.go(t, p, r, n, Nat.sub(n, 1n), prefix(t, p)))
    case h <> +t 0n False{}:
      h <> replace.go(t, p, r, n, 0n, prefix(t, p))

def replace.n(+xs: List<&2, U32>, +p: List<&2, U32>, +r: List<&2, U32>, n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      xs
    case 1n+k:
      replace.go(xs, p, r, 1n+k, 0n, prefix(xs, p))

def replace(+xs: List<&2, U32>, +p: List<&2, U32>, +r: List<&2, U32>) -> List<&2, U32>:
  replace.n(xs, p, r, len(p))

# does xs end with p
def suffix(+xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  prefix(List.reverse(&2, U32, xs), List.reverse(&2, U32, p))

# does p occur in xs
def infix(xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      Nat.is_eq(List.length(&2, U32, p), 0n)
    case +h <> +t:
      Bool.or(prefix(h <> t, p), infix(t, p))

# the position of the first p in xs, counting from k
def find(xs: List<&2, U32>, +p: List<&2, U32>, +k: Nat) -> Maybe<&2, Nat>:
  match xs:
    case Nil{}:
      None{}
    case +h <> +t:
      Bool.pick(Maybe<&2, Nat>, prefix(h <> t, p), Some{k}, find(t, p, 1n+k))

def replace.first.at(+xs: List<&2, U32>, +p: List<&2, U32>, +r: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case Some{+k}:
      List.append(&2, U32, List.take(&2, U32, xs, k), List.append(&2, U32, r, List.drop(&2, U32, xs, Nat.add(k, len(p)))))
    case None{}:
      xs

# xs with its first p replaced by r (`sed s|p|r|`)
def replace.first(+xs: List<&2, U32>, +p: List<&2, U32>, +r: List<&2, U32>) -> List<&2, U32>:
  replace.first.at(xs, p, r, find(xs, p, 0n))

# the first n lines (a line ends after its newline; a last line may lack one)
def lines.take(xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  match xs n:
    case _ 0n:
      Nil{}
    case Nil{} _:
      Nil{}
    case +h <> t 1n+k:
      h <> lines.take(t, Bool.pick(Nat, U32.is_eq(h, 10), k, 1n+k))

# xs (reversed text) without its leading newlines
def drop.nls(xs: List<&2, U32>, nl: Bool) -> List<&2, U32>:
  match xs nl:
    case h <> +t True{}:
      drop.nls(t, head.is(t, 10))
    case Nil{} _:
      Nil{}
    case h <> t False{}:
      h <> t

def first.line(xs: List<&2, U32>, nl: Bool) -> List<&2, U32>:
  match xs nl:
    case h <> +t False{}:
      h <> first.line(t, head.is(t, 10))
    case _ _:
      Nil{}

# the first line, without its newline
def lines.first(+xs: List<&2, U32>) -> List<&2, U32>:
  first.line(xs, head.is(xs, 10))

# without its trailing newlines, as a shell's $(...) strips them
def chomp(+xs: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, xs)
  List.reverse(&2, U32, drop.nls(r, head.is(r, 10)))

def no.nul(xs: List<&2, U32>) -> List<&2, U32>:
  List.filter(~U32, ~(c => U32.is_ne(c, 0)), xs)

# the directory above a path (the path itself when it has no slash)
def parent.go(xs: List<&2, U32>, cut: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      List.reverse(&2, U32, cut)
    case +h <> t:
      parent.go(t, Bool.pick(List<&2, U32>, U32.is_eq(h, 47), acc, cut), h <> acc)

# the last component of a path
def base.go(xs: List<&2, U32>, cur: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      List.reverse(&2, U32, cur)
    case +h <> t:
      base.go(t, Bool.pick(List<&2, U32>, U32.is_eq(h, 47), Nil{}, h <> cur))

def base(+p: String) -> String:
  str(base.go(b(p), Nil{}))

def parent(+p: String) -> String:
  +xs = b(p)
  str(parent.go(xs, List.reverse(&2, U32, xs), Nil{}))

# What the scripts' `$(... | sed "s|DIR/||g" | head -n N)` kept of an
# output: the work directory's path removed, the first n lines, no NUL
# bytes and no trailing newlines.  The directory above it (the run's own
# temporary directory, which a relative import like ../../lib/x.nix
# reaches) is removed too: the scripts left its random name in the text.
# (the first n lines are taken first: the paths hold no newline, so the
# lines are the same, and a flood of output is not scanned whole)
def clean(+dir: String, +n: Nat, +xs: List<&2, U32>) -> List<&2, U32>:
  +ys = replace(replace(lines.take(xs, n), b(dir ++ "/"), Nil{}), b(parent(dir) ++ "/"), Nil{})
  chomp(no.nul(ys))

def split.put(h: U32, r: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match r:
    case Nil{}:
      [[h]]
    case l <> more:
      (h <> l) <> more

# the pieces between occurrences of sep (non-empty): n occurrences, n + 1
# pieces, as awk's RS splits a file (hit: sep starts here)
def split.str.go(xs: List<&2, U32>, +sep: List<&2, U32>, +n: Nat, skip: Nat, hit: Bool) -> List<&2, List<&2, U32>>:
  match xs skip hit:
    case Nil{} _ _:
      [Nil{}]
    case h <> +t 1n+k _:
      split.str.go(t, sep, n, k, prefix(t, sep))
    case h <> +t 0n True{}:
      Nil{} <> split.str.go(t, sep, n, Nat.sub(n, 1n), prefix(t, sep))
    case h <> +t 0n False{}:
      split.put(h, split.str.go(t, sep, n, 0n, prefix(t, sep)))

def split.str(+xs: List<&2, U32>, +sep: List<&2, U32>) -> List<&2, List<&2, U32>>:
  split.str.go(xs, sep, len(sep), 0n, prefix(xs, sep))

# The pieces between separator bytes: a piece ends at a separator or at the
# end; an empty input has no pieces and a trailing separator adds none
# (`a\n\nb` is a, "", b; `a\n` is a).  mid: inside a piece; at: the next
# byte is a separator.
def split.go(xs: List<&2, U32>, +sep: U32, mid: Bool, at: Bool) -> List<&2, List<&2, U32>>:
  match xs mid at:
    case Nil{} True{} _:
      [Nil{}]
    case Nil{} False{} _:
      Nil{}
    case h <> +t _ True{}:
      Nil{} <> split.go(t, sep, False{}, head.is(t, sep))
    case h <> +t _ False{}:
      split.put(h, split.go(t, sep, True{}, head.is(t, sep)))

def split(+xs: List<&2, U32>, +sep: U32) -> List<&2, List<&2, U32>>:
  split.go(xs, sep, False{}, head.is(xs, sep))

# lines, each without its newline
def split.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  split(xs, 10)

# the pieces joined by one separator byte
def join(xss: List<&2, List<&2, U32>>, +sep: U32) -> List<&2, U32>:
  match xss:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      x
    case x <> more:
      List.append(&2, U32, x, sep <> join(more, sep))

# Processes -----------------------------------------------------------------

type Out is Data:
  Out{status: U32, text: List<&2, U32>}

def Out.status(+o: Out) -> U32:
  match o:
    case Out{s, t}:
      s

def Out.text(+o: Out) -> List<&2, U32>:
  match o:
    case Out{s, t}:
      t

def cap.bytes() -> U32:
  67108864

def shim() -> String:
  "cd \"$1\" && shift && exec \"$@\" 2>&1"

def argv.env(env: List<String>, rest: List<String>) -> List<String>:
  match env:
    case Nil{}:
      rest
    case e <> more:
      "env" <> List.append(&1, String, e <> more, rest)

def run.fail.if(late: Bool, big: Bool, msg: String) -> IO(Out):
  match late big:
    case True{} _:
      IO.pure(Out, Out{124, Nil{}})
    case False{} True{}:
      IO.pure(Out, Out{125, b("sys: the output passed the cap")})
    case False{} False{}:
      IO.die(Out, 1, "sys: could not run sh: " ++ msg)

def run.got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(Out):
  match r:
    case Done{(code, (out, err))}:
      IO.pure(Out, Out{code, b(out ++ err)})
    case Fail{(+code, msg)}:
      run.fail.if(U32.is_eq(code, 110), U32.is_eq(code, 27), msg)

def run.with(sh: String, dir: String, env: List<String>, +secs: U32, prog: String, args: List<String>, input: List<&2, U32>) -> IO(Out):
  do IO<Out>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", sh, "sh", dir, "timeout", U32.show(secs)], argv.env(env, prog <> args)),
        str(input), cap.bytes(), U32.mul(U32.add(secs, 30), 1000))
    run.got(r)

def run(dir: String, env: List<String>, +secs: U32, prog: String, args: List<String>, input: List<&2, U32>) -> IO(Out):
  run.with(shim(), dir, env, secs, prog, args, input)

# the same with stderr dropped (`2>/dev/null`)
def run.quiet(dir: String, env: List<String>, +secs: U32, prog: String, args: List<String>, input: List<&2, U32>) -> IO(Out):
  run.with("cd \"$1\" && shift && exec \"$@\" 2>/dev/null", dir, env, secs, prog, args, input)

# the same with the output into the file log, not back (a long run's
# log is there to watch while it runs); the answer is the exit status
def run.log(dir: String, env: List<String>, +secs: U32, prog: String, args: List<String>, log: String) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", "cd \"$1\" && o=$2 && shift 2 && exec \"$@\" > \"$o\" 2>&1", "sh", dir, log, "timeout", U32.show(secs)], argv.env(env, prog <> args)),
        "", cap.bytes(), U32.mul(U32.add(secs, 30), 1000))
    +o : Out <- run.got(r)
    return Out.status(o)

# Redirections (2026-10-15, the plan's Phase 7: the shell strings the tools
# handed sh became these and plain process calls).  Each line is one exec
# with one redirection whose file is $0, so no shell logic rides along;
# `env -C DIR` is the cd, and a relative file is taken from DIR, as after
# `cd DIR`.

def at.dir(+dir: String, +p: String) -> String:
  Bool.pick(String, Bool.or(String.eq(dir, "."), prefix(b(p), [47])), p, dir ++ "/" ++ p)

def argv.in(+dir: String, +secs: U32, env: List<String>, prog: String, args: List<String>) -> List<String>:
  List.append(&1, String, ["timeout", U32.show(secs), "env", "-C", dir], List.append(&1, String, env, prog <> args))

# `cd DIR && timeout SECS env K=V.. PROG ARGS.. > OUT`: the standard output
# into the file OUT, the standard error back as the text
def run.to(+dir: String, env: List<String>, +secs: U32, prog: String, args: List<String>, +out: String) -> IO(Out):
  do IO<Out>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", "exec \"$@\" > \"$0\"", at.dir(dir, out)], argv.in(dir, secs, env, prog, args)),
        "", cap.bytes(), U32.mul(U32.add(secs, 30), 1000))
    run.got(r)

# `cd DIR && timeout SECS env K=V.. PROG ARGS.. >> LOG 2>&1` with INPUT on its
# standard input (as `< FILE` gave a file's bytes): the exit status
def run.feed(+dir: String, env: List<String>, +secs: U32, prog: String, args: List<String>, +log: String, input: List<&2, U32>) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", "exec \"$@\" >> \"$0\" 2>&1", at.dir(dir, log)], argv.in(dir, secs, env, prog, args)),
        str(input), cap.bytes(), U32.mul(U32.add(secs, 30), 1000))
    +o : Out <- run.got(r)
    return Out.status(o)

# `cd DIR && timeout SECS env K=V.. PROG ARGS.. < IN 2>/dev/null`: the
# standard output (the file's bytes go in unread by this process)
def run.from(+dir: String, env: List<String>, +secs: U32, prog: String, args: List<String>, +inp: String) -> IO(Out):
  do IO<Out>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", "exec \"$@\" < \"$0\" 2>/dev/null", at.dir(dir, inp)], argv.in(dir, secs, env, prog, args)),
        "", cap.bytes(), U32.mul(U32.add(secs, 30), 1000))
    run.got(r)

# a command that must succeed: its output, or the tool stops
def must.if(ok: Bool, +o: Out, +what: String) -> IO(List<&2, U32>):
  match ok:
    case True{}:
      IO.pure(List<&2, U32>, Out.text(o))
    case False{}:
      IO.die(List<&2, U32>, 1, what ++ " failed (exit " ++ U32.show(Out.status(o)) ++ "): " ++ str(lines.take(Out.text(o), 20n)))

def must(+what: String, prog: String, args: List<String>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    +o : Out <- run(".", [], 86400, prog, args, Nil{})
    must.if(U32.is_eq(Out.status(o), 0), o, what)

def mkdir(+p: String) -> IO(Unit):
  do IO<Unit>:
    o : List<&2, U32> <- must("mkdir " ++ p, "mkdir", ["-p", p])
    return Unit{}

def rm(+p: String) -> IO(Unit):
  do IO<Unit>:
    o : List<&2, U32> <- must("rm " ++ p, "rm", ["-rf", p])
    return Unit{}

def mv(+a: String, +c: String) -> IO(Unit):
  do IO<Unit>:
    o : List<&2, U32> <- must("mv " ++ a, "mv", ["-f", a, c])
    return Unit{}

# a fresh directory under $TMPDIR (or /tmp)
def mktemp() -> IO(String):
  do IO<String>:
    o : List<&2, U32> <- must("mktemp", "mktemp", ["-d"])
    return str(chomp(o))

def realpath(+p: String) -> IO(String):
  do IO<String>:
    o : List<&2, U32> <- must("realpath " ++ p, "realpath", ["-m", p])
    return str(chomp(o))

# Environment ---------------------------------------------------------------

def env.got(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      d

# $name, or d when it is unset
def env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env.got(r, d)

def env.nat.got(m: Maybe<&2, Nat>, +d: Nat) -> Nat:
  match m:
    case Some{n}:
      n
    case None{}:
      d

# $name as a natural number, or d when it is unset or not a number
def env.nat(name: String, +d: Nat) -> IO(Nat):
  do IO<Nat>:
    s : String <- env(name, "")
    return env.nat.got(Nat.read(s), d)

# Files ---------------------------------------------------------------------

def chunk() -> U32:
  1048576

# A whole file read chunk by chunk: the handle, the bytes so far (newest
# chunk first, reversed) and whether to read on.
type Sl is Type:
  Sl{f: File, acc: List<&2, U32>, more: Bool}

def slurp.res(g: File, x: Result<&1, &1, U32 & String, List<&2, U32>>, acc: List<&2, U32>) -> IO(Sl):
  match x:
    case Fail{(c, m)}:
      do IO<Sl>:
        File.close(g)
        IO.die(Sl, 1, "sys: read failed: " ++ m)
    case Done{+xs}:
      IO.pure(Sl, Sl{g, List.reverse.go(&2, U32, xs, acc), Bool.not(Nat.is_eq(List.length(&2, U32, xs), 0n))})

def slurp.got(acc: List<&2, U32>, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Sl):
  (g, x) = r
  slurp.res(g, x, acc)

def slurp.step(s: Sl) -> IO(Sl):
  match s:
    case Sl{f, acc, m}:
      do IO<Sl>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, chunk())
        slurp.got(acc, r)

def slurp.go(fuel: Nat, s: Sl) -> IO(List<&2, U32>):
  match fuel s:
    case 1n+p Sl{f, acc, True{}}:
      IO.bind(Sl, List<&2, U32>, slurp.step(Sl{f, acc, True{}}), slurp.go(p))
    case _ Sl{f, acc, False{}}:
      do IO<List<&2, U32>>:
        File.close(f)
        return List.reverse(&2, U32, acc)
    case 0n Sl{f, acc, True{}}:
      do IO<List<&2, U32>>:
        File.close(f)
        IO.die(List<&2, U32>, 1, "sys: a file past the 4 GiB a whole read allows")

def slurp.opened(r: Result<&1, &1, U32 & String, File>) -> IO(Maybe<&2, List<&2, U32>>):
  match r:
    case Fail{e}:
      IO.pure(Maybe<&2, List<&2, U32>>, None{})
    case Done{f}:
      do IO<Maybe<&2, List<&2, U32>>>:
        xs : List<&2, U32> <- slurp.go(4096n, Sl{f, Nil{}, True{}})
        return Some{xs}

# A whole file: None when it cannot be opened.  Reads until an empty read,
# so /proc files and pipes (which report size 0) work too.
def slurp(path: String) -> IO(Maybe<&2, List<&2, U32>>):
  do IO<Maybe<&2, List<&2, U32>>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    slurp.opened(r)

def slurp.or(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case Some{xs}:
      xs
    case None{}:
      Nil{}

# a whole file, or nothing when it cannot be opened
def read(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    m : Maybe<&2, List<&2, U32>> <- slurp(path)
    return slurp.or(m)

def exists.got(r: Result<&1, &1, U32 & String, File>) -> IO(Bool):
  match r:
    case Fail{e}:
      IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        File.close(f)
        return True{}

# can path be opened for reading (a file or a directory)
def exists(path: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    exists.got(r)

def size.of(x: Result<&1, &1, U32 & String, U32>) -> Nat:
  match x:
    case Done{n}:
      U32.to_nat(n)
    case Fail{e}:
      0n

def size.got(r: File & Result<&1, &1, U32 & String, U32>) -> IO(Nat):
  (f, x) = r
  do IO<Nat>:
    File.close(f)
    return size.of(x)

def size.opened(r: Result<&1, &1, U32 & String, File>) -> IO(Nat):
  match r:
    case Fail{e}:
      IO.pure(Nat, 0n)
    case Done{f}:
      do IO<Nat>:
        g : File & Result<&1, &1, U32 & String, U32> <- File.size(f)
        size.got(g)

# a file's size in bytes, 0 when it cannot be opened (`[[ -s ]]` is 0 < size)
def size(path: String) -> IO(Nat):
  do IO<Nat>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    size.opened(r)

def put.fin(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, e) = r
  do IO<Unit>:
    u : Unit <- IO.pass(Unit, e)
    File.close(f)

def put(path: String, mode: String, xs: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, mode))
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(f, xs)
    put.fin(r)

def write(path: String, xs: List<&2, U32>) -> IO(Unit):
  put(path, "w", xs)

def add(path: String, xs: List<&2, U32>) -> IO(Unit):
  put(path, "a", xs)

# an open output file: a write hands the handle back
def emit.fin(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(File):
  (f, e) = r
  do IO<File>:
    u : Unit <- IO.pass(Unit, e)
    return f

def emit(f: File, xs: List<&2, U32>) -> IO(File):
  do IO<File>:
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(f, xs)
    emit.fin(r)

# A framed stream, a field at a time -----------------------------------------

# A reader over a file of fields that each end with a separator byte (NUL
# for the id/text streams, a newline for JSON lines): the bytes read but
# not handed out yet, and whether the file has ended.  Memory is a chunk
# plus the longest field, so a file of any size streams.
type Rd is Type:
  Rd{f: File, sep: U32, buf: List<&2, U32>, eof: Bool}

def Rd.of(path: String, +sep: U32) -> IO(Rd):
  do IO<Rd>:
    f : File <- IO.try(File, File.open(path, "r"))
    return Rd{f, sep, Nil{}, False{}}

# a NUL-framed file: every field ends with a NUL
def Rd.open(path: String) -> IO(Rd):
  Rd.of(path, 0)

# a text file a line at a time (a last line without its newline counts)
def Rd.lines(path: String) -> IO(Rd):
  Rd.of(path, 10)

def Rd.close(r: Rd) -> IO(Unit):
  match r:
    case Rd{f, s, b, e}:
      File.close(f)

# the bytes up to the first sep, the bytes after it, and whether there was one
def cut.go(+xs: List<&2, U32>, +sep: U32, at: Bool) -> Ns.Field:
  match xs at:
    case h <> +t False{}:
      Ns.Field.put(h, cut.go(t, sep, head.is(t, sep)))
    case h <> t True{}:
      Ns.Field{Nil{}, t, True{}}
    case Nil{} _:
      Ns.Field{Nil{}, Nil{}, False{}}

def cut(+xs: List<&2, U32>, +sep: U32) -> Ns.Field:
  cut.go(xs, sep, head.is(xs, sep))

# One attempt: the reader, whether to read on, and the field if one ended.
type Rq is Type:
  Rq{f: File, sep: U32, buf: List<&2, U32>, eof: Bool, more: Bool, got: Maybe<&2, List<&2, U32>>}

def Rd.filled(+sep: U32, buf: List<&2, U32>, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Rq):
  (f, x) = r
  do IO<Rq>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return Rq{f, sep, List.append(&2, U32, buf, xs), Nat.is_eq(List.length(&2, U32, xs), 0n), True{}, None{}}

# the stream ends inside a field: a last line counts, a last NUL field not
def Rd.last(f: File, +sep: U32, lines: Bool, x: List<&2, U32>) -> IO(Rq):
  match lines:
    case True{}:
      IO.pure(Rq, Rq{f, sep, Nil{}, True{}, False{}, Some{x}})
    case False{}:
      do IO<Rq>:
        File.close(f)
        IO.die(Rq, 1, "sys: the stream ends inside a field (no final NUL)")

def Rd.cut(f: File, +sep: U32, eof: Bool, fl: Ns.Field) -> IO(Rq):
  match eof fl:
    case _ Ns.Field{x, rest, True{}}:
      IO.pure(Rq, Rq{f, sep, rest, eof, False{}, Some{x}})
    case True{} Ns.Field{Nil{}, rest, False{}}:
      IO.pure(Rq, Rq{f, sep, Nil{}, True{}, False{}, None{}})
    case True{} Ns.Field{x, rest, False{}}:
      Rd.last(f, sep, U32.is_eq(sep, 10), x)
    case False{} Ns.Field{x, rest, False{}}:
      do IO<Rq>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, chunk())
        Rd.filled(sep, x, r)

def Rd.try(q: Rq) -> IO(Rq):
  match q:
    case Rq{f, +sep, +buf, eof, m, g}:
      Rd.cut(f, sep, eof, cut(buf, sep))

def Rd.go(fuel: Nat, q: Rq) -> IO(Rd & Maybe<&2, List<&2, U32>>):
  match fuel q:
    case 1n+p Rq{f, sep, buf, eof, True{}, g}:
      IO.bind(Rq, Rd & Maybe<&2, List<&2, U32>>, Rd.try(Rq{f, sep, buf, eof, True{}, g}), Rd.go(p))
    case _ Rq{f, sep, buf, eof, False{}, g}:
      IO.pure(Rd & Maybe<&2, List<&2, U32>>, (Rd{f, sep, buf, eof}, g))
    case 0n Rq{f, sep, buf, eof, True{}, g}:
      do IO<Rd & Maybe<&2, List<&2, U32>>>:
        File.close(f)
        IO.die(Rd & Maybe<&2, List<&2, U32>>, 1, "sys: a field past 4 GiB")

# the next field (without its separator), or None at the end of the stream
def Rd.next(r: Rd) -> IO(Rd & Maybe<&2, List<&2, U32>>):
  match r:
    case Rd{f, sep, buf, eof}:
      Rd.go(4096n, Rq{f, sep, buf, eof, True{}, None{}})

# Background processes and the PATH -----------------------------------------
#
# `background(dir, env, log, append, prog, args)` starts PROG in the
# background and answers its pid: the shell line
#
#   cd DIR; nohup env K=V.. PROG ARGS.. > LOG 2>&1 < /dev/null & echo $!
#
# (>> LOG when append).  Process.run returns when its direct child (this
# sh) has exited and, since Bend 2.0.37 (upstream 3f80b064), only once its
# stdout and stderr have closed: a program left holding either pipe would
# hold the call until it exits.  The started program holds none of sh's
# pipes (the redirections above), so the call returns at once and the
# program outlives it; `nohup` keeps it from a hangup.  `background.setsid`
# also gives it a session of its own (`nohup setsid ...`), so a signal to
# our process group or session does not reach it.  sh is not a group leader
# there, so setsid execs in place and $! stays the program's pid.  A line
# that does not answer a pid (DIR missing, PROG not found by sh) stops the
# tool: a launch that failed must not read as one that ran.  sh ignores a
# hangup before it forks (2026-10-14, bend-box): the program is born
# ignoring it, so a hangup that comes the moment the call returns (`ssh -t`
# ending), before nohup or setsid ran, does not kill it either.

def bg.line(sid: Bool, append: Bool) -> String:
  "trap '' HUP; cd \"$1\" || exit 97; o=$2; shift 2; " ++ Bool.pick(String, sid, "nohup setsid", "nohup") ++ " \"$@\" "
    ++ Bool.pick(String, append, ">>", ">") ++ " \"$o\" 2>&1 < /dev/null & echo $!"

def bg.all.digits(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), bg.all.digits(t))

def bg.digits(+xs: List<&2, U32>) -> Bool:
  Bool.and(Nat.is_ne(len(xs), 0n), bg.all.digits(xs))

def bg.fin(ok: Bool, +pid: List<&2, U32>, +o: Out, +prog: String) -> IO(String):
  match ok:
    case True{}:
      IO.pure(String, str(pid))
    case False{}:
      IO.die(String, 1, "sys: could not start " ++ prog ++ " in the background (exit " ++ U32.show(Out.status(o)) ++ "): "
        ++ str(lines.take(Out.text(o), 5n)))

def bg.got(+pid: List<&2, U32>, +o: Out, +prog: String) -> IO(String):
  bg.fin(bg.digits(pid), pid, o, prog)

def bg.run(sid: Bool, append: Bool, dir: String, env: List<String>, log: String, +prog: String, args: List<String>) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", bg.line(sid, append), "sh", dir, log], argv.env(env, prog <> args)),
        "", cap.bytes(), 60000)
    +o : Out <- run.got(r)
    bg.got(chomp(lines.first(Out.text(o))), o, prog)

def background(dir: String, env: List<String>, log: String, append: Bool, +prog: String, args: List<String>) -> IO(String):
  bg.run(False{}, append, dir, env, log, prog, args)

def background.setsid(dir: String, env: List<String>, log: String, append: Bool, +prog: String, args: List<String>) -> IO(String):
  bg.run(True{}, append, dir, env, log, prog, args)

# the places a name is found on $PATH, in order (an empty entry is the
# current directory); a name with a slash is itself.  A candidate counts
# when it opens for reading (Bend has no stat: the execute bit is not seen)
def which.all(ds: List<&2, List<&2, U32>>, +name: String) -> IO(List<&2, String>):
  match ds:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +d <> t:
      +p = Bool.pick(String, Nat.is_eq(len(d), 0n), ".", str(d)) ++ "/" ++ name
      do IO<List<&2, String>>:
        ok : Bool <- exists(p)
        +rest : List<&2, String> <- which.all(t, name)
        return Bool.pick(List<&2, String>, ok, p <> rest, rest)

def which.first(ps: List<&2, String>) -> Maybe<&2, String>:
  match ps:
    case Nil{}:
      None{}
    case p <> t:
      Some{p}

# `command -v NAME`, over $PATH (Some: the first hit)
def which.go(slash: Bool, +name: String) -> IO(Maybe<&2, String>):
  match slash:
    case True{}:
      do IO<Maybe<&2, String>>:
        ok : Bool <- exists(name)
        return Bool.pick(Maybe<&2, String>, ok, Some{name}, None{})
    case False{}:
      do IO<Maybe<&2, String>>:
        path : String <- env("PATH", "")
        ps : List<&2, String> <- which.all(split(b(path), 58), name)
        return which.first(ps)

def which(+name: String) -> IO(Maybe<&2, String>):
  which.go(infix(b(name), [47]), name)

# Order and globs (2026-10-15, Phase 7) --------------------------------------

def bytes.hd(+xs: List<&2, U32>) -> U32:
  match xs:
    case Nil{}:
      0
    case +h <> t:
      U32.add(h, 1)

def bytes.le.go(a: List<&2, U32>, b: List<&2, U32>, lt: Bool, gt: Bool) -> Bool:
  match a b lt gt:
    case Nil{} _ _ _:
      True{}
    case _ Nil{} _ _:
      False{}
    case _ _ True{} _:
      True{}
    case _ _ False{} True{}:
      False{}
    case x <> +xt y <> +yt False{} False{}:
      bytes.le.go(xt, yt, U32.is_lt(bytes.hd(xt), bytes.hd(yt)), U32.is_lt(bytes.hd(yt), bytes.hd(xt)))

# bytewise order (a prefix first), as `LC_ALL=C sort` puts lines
def bytes.le(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  +x = a
  +y = b
  bytes.le.go(x, y, U32.is_lt(bytes.hd(x), bytes.hd(y)), U32.is_lt(bytes.hd(y), bytes.hd(x)))

def bytes.sort(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.sort(~List<&2, U32>, ~bytes.le, xs)

# `glob(PATS)` is what the shell line
#
#   for f in PATS; do if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\n' "$f"; fi; done
#
# prints, a pattern after another (PATS: patterns split at spaces): the paths
# matching a pattern, `*` any run of bytes and `?` one byte within a path's
# component (brackets are not read: a [ is itself), a name with a leading dot
# only for a pattern component with one, a component without either named
# when it is there (a dangling link too).  Each directory is listed by
# `find -H DIR -mindepth 1 -maxdepth 1 -printf '%f\0'` (a link to a directory
# is followed, as the shell's glob follows it); a missing directory lists
# nothing.  Within a pattern the order is find's: callers sort.

def glob.wild(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      Bool.or(Bool.or(U32.is_eq(c, 42), U32.is_eq(c, 63)), glob.wild(t))

# p matches n; st: p starts with a star.  A star tries the rest of p here and
# itself one byte on; any other byte must match one of n's.
def glob.m(p: List<&2, U32>, n: List<&2, U32>, st: Bool) -> Bool:
  match p n st:
    case Nil{} Nil{} _:
      True{}
    case Nil{} _ _:
      False{}
    case c <> +pt Nil{} True{}:
      glob.m(pt, Nil{}, head.is(pt, 42))
    case c <> pt Nil{} False{}:
      False{}
    case +c <> +pt +h <> +nt True{}:
      Bool.or(glob.m(pt, h <> nt, head.is(pt, 42)), glob.m(c <> pt, nt, True{}))
    case +c <> +pt +h <> +nt False{}:
      Bool.and(Bool.or(U32.is_eq(c, 63), U32.is_eq(c, h)), glob.m(pt, nt, head.is(pt, 42)))

def glob.name(+p: List<&2, U32>, +n: List<&2, U32>) -> Bool:
  Bool.and(Bool.or(Bool.not(head.is(n, 46)), head.is(p, 46)), glob.m(p, n, head.is(p, 42)))

def glob.join(+p: List<&2, U32>, +n: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(len(p), 0n), n, Bool.pick(List<&2, U32>, suffix(p, [47]), List.append(&2, U32, p, n), List.append(&2, U32, p, 47 <> n)))

def glob.ls.got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> List<&2, List<&2, U32>>:
  match r:
    case Done{(+code, (out, err))}:
      Bool.pick(List<&2, List<&2, U32>>, U32.is_eq(code, 0), split(b(out), 0), Nil{})
    case Fail{e}:
      Nil{}

# the names in DIR (nothing when it is not a directory)
def glob.ls(+dir: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("find", ["-H", Bool.pick(String, Nat.is_eq(len(dir), 0n), ".", str(dir)), "-mindepth", "1", "-maxdepth", "1", "-printf", "%f\\0"],
        "", cap.bytes(), 600000)
    return glob.ls.got(r)

def glob.keep(ns: List<&2, List<&2, U32>>, +p: List<&2, U32>, +pat: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +rest = glob.keep(t, p, pat)
      Bool.pick(List<&2, List<&2, U32>>, glob.name(pat, n), glob.join(p, n) <> rest, rest)

def glob.one(look: Bool, +p: List<&2, U32>, +pat: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  match look:
    case False{}:
      IO.pure(List<&2, List<&2, U32>>, [glob.join(p, pat)])
    case True{}:
      do IO<List<&2, List<&2, U32>>>:
        ns : List<&2, List<&2, U32>> <- glob.ls(p)
        return glob.keep(ns, p, pat)

# the paths so far, each taken one component on (look: list the directory)
def glob.dirs(ps: List<&2, List<&2, U32>>, +pat: List<&2, U32>, +look: Bool) -> IO(List<&2, List<&2, U32>>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +p <> t:
      do IO<List<&2, List<&2, U32>>>:
        a : List<&2, List<&2, U32>> <- glob.one(look, p, pat)
        rest : List<&2, List<&2, U32>> <- glob.dirs(t, pat, look)
        return List.append(&2, List<&2, U32>, a, rest)

def glob.go(cs: List<&2, List<&2, U32>>, ps: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match cs:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, ps)
    case +c <> +t:
      do IO<List<&2, List<&2, U32>>>:
        qs : List<&2, List<&2, U32>> <- glob.dirs(ps, c, Bool.or(glob.wild(c), Nat.is_eq(List.length(&2, List<&2, U32>, t), 0n)))
        glob.go(t, qs)

def glob.pat(+pat: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  glob.go(List.filter(~List<&2, U32>, ~(c => Nat.is_ne(len(c), 0n)), split(pat, 47)), [Bool.pick(List<&2, U32>, head.is(pat, 47), [47], Nil{})])

def glob.all(ps: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +p <> t:
      do IO<List<&2, List<&2, U32>>>:
        a : List<&2, List<&2, U32>> <- glob.pat(p)
        rest : List<&2, List<&2, U32>> <- glob.all(t)
        return List.append(&2, List<&2, U32>, a, rest)

def glob(+pats: String) -> IO(List<&2, List<&2, U32>>):
  glob.all(List.filter(~List<&2, U32>, ~(c => Nat.is_ne(len(c), 0n)), split(b(pats), 32)))
