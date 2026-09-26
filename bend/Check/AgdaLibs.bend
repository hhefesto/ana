import Base
import ../Sys.bend as S
import ../Clock.bend as Ck

# bend-check agda-libs [precompile]: the Agda libraries the Agda checker
# (Check/Agda.bend) checks units against, set up once (idempotent).  Run it
# from the repository root.
#
# 1. Fetches what the sources need and the corpus does not hold, into
#    run/check-cache/agda/: standard library v2.4 (agda-categories pins it)
#    and the formal ledger's dependencies at the revisions its flake.lock
#    pins (agda-stdlib-classes, agda-stdlib-meta, agda-sets, iog-agda-prelude).
# 2. Pins, in the checkouts under run/code-sources (never in ~/src): every
#    unversioned `standard-library` dependency becomes standard-library-2.3,
#    the one Agda 2.8.0 ships with in nixpkgs (prebuilt in the store), except
#    for the libraries built on agda-categories, which take its 2.4; the
#    corpus's own agda-stdlib is 3.0 and serves its own units. HoTT-Agda's
#    three .agda-lib files, which share one directory (Agda refuses that),
#    move into their include directories.
# 3. Writes run/check-cache/agda/libraries, the --library-file the checker
#    passes.
# 4. With `precompile`: type-checks every module of every library once, in
#    interaction sessions of 300 files per library (interfaces stay in memory
#    between files), so a unit's check loads interfaces instead of checking
#    its imports. Libraries run one after another; a module that fails is
#    left without an interface and every unit importing it fails later.
#
# Environment: AGDA (the nixpkgs wrapper, default agda on the PATH; the real
# binary it execs is what runs, with this library file instead of the
# wrapper's), AGDA_BIN (that binary itself, for tests).

def cs() -> String:
  "run/code-sources"

def cache() -> String:
  "run/check-cache/agda"

# Text ---------------------------------------------------------------------

def say(+msg: String) -> IO(Unit):
  Ck.log(msg)

# `dirname`: the path without its last component ("." when it has none)
def dirname(+p: String) -> String:
  +par = S.parent(p)
  Bool.pick(String, Bool.not(S.infix(S.b(p), [47])), ".", Bool.pick(String, String.is_empty(par), "/", par))

# the lines of a text and whether its last one ends in a newline, and back
def ends.nl(+xs: List<&2, U32>) -> Bool:
  S.suffix(xs, [10])

def unlines(ls: List<&2, List<&2, U32>>, nl: Bool) -> List<&2, U32>:
  match nl:
    case True{}:
      S.append(S.join(ls, 10), [10])
    case False{}:
      S.join(ls, 10)

def lines.all(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      List.append(&2, U32, l, 10 <> lines.all(more))

def strs(xs: List<&2, List<&2, U32>>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      S.str(x) <> strs(more)

def byteses(xs: List<&2, String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      S.b(x) <> byteses(more)

def need(ok: Bool, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, msg)

# The agda binary and the prebuilt standard library ----------------------------

# the text up to the next quote on the line (None: the line or text ends first)
def quoted(xs: List<&2, U32>, +acc: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      None{}
    case +h <> t:
      Bool.pick(Maybe<&2, List<&2, U32>>, U32.is_eq(h, 34), Some{List.reverse(&2, U32, acc)},
        Bool.pick(Maybe<&2, List<&2, U32>>, U32.is_eq(h, 10), None{}, quoted(t, h <> acc)))

def bin.at(q: Maybe<&2, List<&2, U32>>, r: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match q:
    case Some{+x}:
      Bool.pick(Maybe<&2, List<&2, U32>>, S.suffix(x, S.b("/bin/agda")), Some{x}, r)
    case None{}:
      r

# `grep -o '"/nix/store/[^"]*/bin/agda"' | head -n 1`, without the quotes:
# the real agda the nixpkgs wrapper execs
def store.bin(xs: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      None{}
    case +h <> +t:
      bin.at(Bool.pick(Maybe<&2, List<&2, U32>>, S.prefix(h <> t, S.b("\"/nix/store/")), quoted(t, Nil{}), None{}), store.bin(t))

# the value of the first `--library-file=[^ "]*` up to its first `=` (cut -f2)
def lf.value(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, Bool.or(Bool.or(U32.is_eq(h, 32), U32.is_eq(h, 34)), Bool.or(U32.is_eq(h, 10), U32.is_eq(h, 61))), Nil{}, h <> lf.value(t))

def lib.file(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, S.prefix(h <> t, S.b("--library-file=")), lf.value(List.drop(&2, U32, h <> t, 15n)), lib.file(t))

def suf23() -> List<&2, U32>:
  S.b("standard-library-2.3/standard-library.agda-lib")

def word23.at(+rev: List<&2, U32>, m: Maybe<&2, Nat>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      None{}
    case Some{+j}:
      Some{List.reverse(&2, U32, List.drop(&2, U32, rev, j))}

# in one word: from its first /nix/store/ to the end of its last suffix
def word23(+w: List<&2, U32>, m: Maybe<&2, Nat>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      None{}
    case Some{+i}:
      +x = List.drop(&2, U32, w, i)
      +rev = List.reverse(&2, U32, x)
      word23.at(rev, S.find(rev, List.reverse(&2, U32, suf23()), 0n))

def first.of(a: Maybe<&2, List<&2, U32>>, b: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match a:
    case Some{x}:
      Some{x}
    case None{}:
      b

def words23(ws: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      None{}
    case +w <> more:
      first.of(word23(w, S.find(w, S.b("/nix/store/"), 0n)), words23(more))

# `grep -o '/nix/store/[^ ]*standard-library-2.3/standard-library.agda-lib' | head -n 1`
def lines23(ls: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      None{}
    case +l <> more:
      first.of(words23(S.split(l, 32)), lines23(more))

def or.empty(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case Some{x}:
      x
    case None{}:
      Nil{}

# Fetching ---------------------------------------------------------------------

def is.dir(+p: String) -> IO(Bool):
  do IO<Bool>:
    +o : S.Out <- S.run(".", [], 60, "test", ["-d", p], Nil{})
    return U32.is_eq(S.Out.status(o), 0)

def is.file(+p: String) -> IO(Bool):
  do IO<Bool>:
    +o : S.Out <- S.run(".", [], 60, "test", ["-f", p], Nil{})
    return U32.is_eq(S.Out.status(o), 0)

def fetch.run(there: Bool, +dir: String, +url: String, +rev: String) -> IO(Unit):
  match there:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      +d = cache() ++ "/" ++ dir
      do IO<Unit>:
        a : List<&2, U32> <- S.must("git init " ++ d, "git", ["init", "-q", d])
        b : List<&2, U32> <- S.must("git fetch " ++ url ++ " " ++ rev, "git", ["-C", d, "fetch", "-q", "--depth", "1", url, rev])
        c : List<&2, U32> <- S.must("git checkout in " ++ d, "git", ["-C", d, "checkout", "-q", "FETCH_HEAD"])
        return Unit{}

def fetch(+dir: String, +url: String, +rev: String) -> IO(Unit):
  do IO<Unit>:
    +there : Bool <- is.dir(cache() ++ "/" ++ dir)
    fetch.run(there, dir, url, rev)

# HoTT-Agda: one library per directory ------------------------------------------

def sp.drop(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      sp.drop(t, S.head.is(t, 32))
    case Nil{} _:
      Nil{}
    case h <> t False{}:
      h <> t

def all.sp(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.and(U32.is_eq(h, 32), all.sp(t))

# `^include: *LIB *$`
def hott.hit(+lib: List<&2, U32>, +l: List<&2, U32>) -> Bool:
  +a = List.drop(&2, U32, l, 8n)
  +c = sp.drop(a, S.head.is(a, 32))
  Bool.and(S.prefix(l, S.b("include:")), Bool.and(S.prefix(c, lib), all.sp(List.drop(&2, U32, c, S.len(lib)))))

def hott.lines(+lib: List<&2, U32>, ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      Bool.pick(List<&2, U32>, hott.hit(lib, l), S.b("include: ."), l) <> hott.lines(lib, more)

def hott.move(there: Bool, +lib: String) -> IO(Unit):
  match there:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      +h = cs() ++ "/repos/HoTT-Agda"
      +from = h ++ "/hott-" ++ lib ++ ".agda-lib"
      do IO<Unit>:
        +xs : List<&2, U32> <- S.read(from)
        S.write(h ++ "/" ++ lib ++ "/hott-" ++ lib ++ ".agda-lib", unlines(hott.lines(S.b(lib), S.split.lines(xs)), ends.nl(xs)))
        a : List<&2, U32> <- S.must("rm " ++ from, "rm", [from])
        return Unit{}

def hott(+lib: String) -> IO(Unit):
  do IO<Unit>:
    +there : Bool <- is.file(cs() ++ "/repos/HoTT-Agda/hott-" ++ lib ++ ".agda-lib")
    hott.move(there, lib)

# The library files ---------------------------------------------------------------

def libs.find() -> List<String>:
  +c = cs()
  [c ++ "/repos", c ++ "/own", c ++ "/curated", cache(), "-name", "*.agda-lib",
    "-not", "-path", "*/.git/*", "-not", "-path", "*/_build/*", "-not", "-path", c ++ "/repos/agda/*",
    "-not", "-path", c ++ "/repos/1lab/*", "-not", "-path", "*/tests/_config/*", "-not", "-path", "*stdlib*/dev/*",
    "-not", "-path", "*stdlib*/doc/*", "-not", "-path", c ++ "/repos/cubical/*", "-not", "-path", "*/standard-library/*"]

# grep -l '^name:': a library without a name breaks the whole library file
def named(+xs: List<&2, U32>) -> Bool:
  Bool.or(S.prefix(xs, S.b("name:")), S.infix(xs, S.b("\nname:")))

def named.all(ps: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +p <> more:
      do IO<List<&2, List<&2, U32>>>:
        +xs : List<&2, U32> <- S.read(S.str(p))
        +rest : List<&2, List<&2, U32>> <- named.all(more)
        return Bool.pick(List<&2, List<&2, U32>>, named(xs), p <> rest, rest)

def sorted(+xs: List<&2, List<&2, U32>>, +uniq: Bool) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    o : S.Out <- S.run(".", [], 600, "sort", Bool.pick(List<String>, uniq, ["-u"], []), lines.all(xs))
    return S.split.lines(S.Out.text(o))

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

# a command's stdout; its stderr passes through to ours
def out.got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(S.Out):
  match r:
    case Done{p}:
      out.done(p)
    case Fail{(code, msg)}:
      IO.die(S.Out, 1, "agda-libs: could not run sh: " ++ msg)

def out.only(prog: String, args: List<String>) -> IO(S.Out):
  do IO<S.Out>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", List.append(&1, String, ["-c", "cd \"$1\" && shift && exec \"$@\"", "sh", ".", "timeout", "3600", prog], args),
        "", S.cap.bytes(), 3630000)
    out.got(r)

def libs.got(+o: S.Out) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    need(U32.is_eq(S.Out.status(o), 0), "agda-libs: find failed (exit " ++ U32.show(S.Out.status(o)) ++ ")")
    +ps : List<&2, List<&2, U32>> <- named.all(S.split.lines(S.Out.text(o)))
    sorted(ps, False{})

def libs() -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +o : S.Out <- out.only("find", libs.find())
    libs.got(o)

# The pins ----------------------------------------------------------------------

def space(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(Bool.or(U32.is_eq(c, 10), U32.is_eq(c, 11)), Bool.or(U32.is_eq(c, 12), U32.is_eq(c, 13))))

def sl() -> List<&2, U32>:
  S.b("standard-library")

# `([[:space:]]|$)` after the name
def after.ok(+r: List<&2, U32>) -> Bool:
  match r:
    case Nil{}:
      True{}
    case +h <> t:
      space(h)

def at.sl(+r: List<&2, U32>) -> Bool:
  Bool.and(S.prefix(r, sl()), after.ok(List.drop(&2, U32, r, 16n)))

# what matches at this position: 1 `^standard-library`, 2 a space or colon
# before it, 0 nothing
def pin.kind(+r: List<&2, U32>, start: Bool) -> Nat:
  match r:
    case Nil{}:
      0n
    case +h <> +t:
      Bool.pick(Nat, Bool.and(start, at.sl(h <> t)), 1n, Bool.pick(Nat, Bool.and(Bool.or(space(h), U32.is_eq(h, 58)), at.sl(t)), 2n, 0n))

# `sed -E 's/(^|[[:space:]:])standard-library([[:space:]]|$)/\1WANT\2/'` on
# one line: the leftmost match only
def pin.go(r: List<&2, U32>, acc: List<&2, U32>, +want: List<&2, U32>, kind: Nat) -> List<&2, U32>:
  match r kind:
    case +x 1n:
      List.append(&2, U32, List.reverse(&2, U32, acc), List.append(&2, U32, want, List.drop(&2, U32, x, 16n)))
    case c <> +x 2n:
      List.append(&2, U32, List.reverse(&2, U32, acc), c <> List.append(&2, U32, want, List.drop(&2, U32, x, 16n)))
    case Nil{} _:
      List.reverse(&2, U32, acc)
    case h <> +t _:
      pin.go(t, h <> acc, want, pin.kind(t, False{}))

def pin.line(+want: List<&2, U32>, +l: List<&2, U32>) -> List<&2, U32>:
  pin.go(l, Nil{}, want, pin.kind(l, True{}))

def pin.lines(+want: List<&2, U32>, ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      pin.line(want, l) <> pin.lines(want, more)

def pin.write(same: Bool, +f: String, +ys: List<&2, U32>) -> IO(Unit):
  match same:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      S.write(f, ys)

def pin.file(skip: Bool, +f: String) -> IO(Unit):
  match skip:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        +xs : List<&2, U32> <- S.read(f)
        +want : List<&2, U32> = S.b(Bool.pick(String, S.infix(xs, S.b("agda-categories")), "standard-library-2.4", "standard-library-2.3"))
        +ys : List<&2, U32> = unlines(pin.lines(want, S.split.lines(xs)), ends.nl(xs))
        pin.write(S.eq(xs, ys), f, ys)

# an unversioned standard-library becomes 2.3, or 2.4 for the libraries on
# agda-categories (one program cannot hold two stdlibs)
def pins(fs: List<&2, List<&2, U32>>) -> IO(Unit):
  match fs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +f <> more:
      do IO<Unit>:
        pin.file(Bool.or(S.infix(f, S.b("/agda-stdlib/")), S.infix(f, S.b("/stdlib-2.4/"))), S.str(f))
        pins(more)

def inc.name(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, Bool.or(U32.is_eq(h, 45), Bool.and(U32.is_le(97, h), U32.is_le(h, 122))), inc.name(t, 1n+n), n)

# Precompiling ------------------------------------------------------------------

# the include directories of a library file: `include:`'s value and the
# lines after it up to the next field, cut at spaces, each trimmed of tabs
def inc.field(+l: List<&2, U32>) -> Bool:
  +n = inc.name(l, 0n)
  Bool.and(Nat.is_lt(0n, n), S.head.is(List.drop(&2, U32, l, n), 58))

def sp.tab.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      Bool.or(Bool.or(U32.is_eq(h, 32), U32.is_eq(h, 9)), Bool.or(U32.is_eq(h, 10), Bool.or(U32.is_eq(h, 11), Bool.or(U32.is_eq(h, 12), U32.is_eq(h, 13)))))
    case Nil{}:
      False{}

def sp.tab.drop(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      sp.tab.drop(t, sp.tab.head(t))
    case Nil{} _:
      Nil{}
    case h <> t False{}:
      h <> t

def tab.head(+xs: List<&2, U32>) -> Bool:
  Bool.or(S.head.is(xs, 9), S.head.is(xs, 32))

def tab.lead(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      tab.lead(t, tab.head(t))
    case Nil{} _:
      Nil{}
    case h <> t False{}:
      h <> t

def tab.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  +a = tab.lead(xs, tab.head(xs))
  +r = List.reverse(&2, U32, a)
  List.reverse(&2, U32, tab.lead(r, tab.head(r)))

# the tokens of one printed line: cut at spaces, empty pieces dropped, each
# trimmed as `read -r` trims (a piece of tabs alone becomes empty)
def tokens(ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      +r = tokens(more)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(p), 0n), r, tab.trim(p) <> r)

def inc.go(ls: List<&2, List<&2, U32>>, inc: Bool) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +isinc = S.prefix(l, S.b("include:"))
      +a = List.drop(&2, U32, l, 8n)
      +x = Bool.pick(List<&2, U32>, isinc, sp.tab.drop(a, sp.tab.head(a)), l)
      +on = Bool.and(Bool.or(inc, isinc), Bool.not(Bool.and(inc.field(x), Bool.not(S.prefix(x, S.b("include:"))))))
      +r = inc.go(more, on)
      Bool.pick(List<&2, List<&2, U32>>, on, List.append(&2, List<&2, U32>, tokens(S.split.str(x, [32])), r), r)

def roots(+d: String, ts: List<&2, List<&2, U32>>) -> List<String>:
  match ts:
    case Nil{}:
      Nil{}
    case t <> more:
      (d ++ "/" ++ S.str(t)) <> roots(d, more)

def module.find(rs: List<String>) -> List<String>:
  List.append(&1, String, rs, ["-type", "f", "(", "-name", "*.agda", "-o", "-name", "*.lagda.md", "-o", "-name", "*.lagda", "-o", "-name", "*.lagda.tex", ")",
    "-not", "-path", "*/_build/*", "-not", "-name", "FTUnit*"])

def modules.of(+ts: List<&2, List<&2, U32>>, +d: String) -> IO(List<&2, List<&2, U32>>):
  match ts:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case t <> more:
      do IO<List<&2, List<&2, U32>>>:
        o : S.Out <- S.run.quiet(".", [], 3600, "find", module.find(roots(d, t <> more)), Nil{})
        sorted(S.split.lines(S.Out.text(o)), True{})

# the modules of a library: every Agda source under its include directories
def modules(+f: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +xs : List<&2, U32> <- S.read(f)
    modules.of(inc.go(S.split.lines(xs), False{}), dirname(f))

def cmd.lines(ps: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      List.append(&2, U32, S.b("IOTCM \""), List.append(&2, U32, p, List.append(&2, U32, S.b("\" None Indirect (Cmd_load \""),
        List.append(&2, U32, p, List.append(&2, U32, S.b("\" [])\n"), cmd.lines(more))))))

# realpath over many files, a few hundred per call
def real.go(fuel: Nat, ps: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match fuel ps:
    case 0n _:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case _ Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case 1n+f +p <> +more:
      do IO<List<&2, List<&2, U32>>>:
        +xs : List<&2, U32> <- S.must("realpath", "realpath", "-m" <> strs(List.take(&2, List<&2, U32>, p <> more, 256n)))
        rest : List<&2, List<&2, U32>> <- real.go(f, List.drop(&2, List<&2, U32>, p <> more, 256n))
        return List.append(&2, List<&2, U32>, S.split.lines(xs), rest)

def real.all(+ps: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  real.go(1n+List.length(&2, List<&2, U32>, ps), ps)

def pad3(+k: Nat) -> String:
  +s = Nat.show(k)
  Bool.pick(String, Nat.is_lt(k, 10n), "00" ++ s, Bool.pick(String, Nat.is_lt(k, 100n), "0" ++ s, s))

# `split -l 300 -d -a 3`: the batch files, in order
def batches(fuel: Nat, ls: List<&2, List<&2, U32>>, +pre: String, +k: Nat) -> IO(List<&2, String>):
  match fuel ls:
    case 0n _:
      IO.pure(List<&2, String>, Nil{})
    case _ Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case 1n+f +l <> +more:
      +path = pre ++ pad3(k)
      do IO<List<&2, String>>:
        S.write(path, lines.all(List.take(&2, List<&2, U32>, l <> more, 300n)))
        rest : List<&2, String> <- batches(f, List.drop(&2, List<&2, U32>, l <> more, 300n), pre, 1n+k)
        return path <> rest

def session.sh() -> String:
  "cd \"$1\" && i=$2 && o=$3 && shift 3 && exec \"$@\" < \"$i\" >> \"$o\" 2>&1"

def session(+dir: String, +inp: String, +out: String, +bin: String, +libfile: String) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", ["-c", session.sh(), "sh", dir, inp, out, "timeout", "4000000", bin, "--library-file=" ++ libfile, "--interaction", "+RTS", "-M10G", "-RTS"],
        "", S.cap.bytes(), 4000030000)
    return Unit{}

def sessions(bs: List<&2, String>, +dir: String, +out: String, +bin: String, +libfile: String) -> IO(Unit):
  match bs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +b <> more:
      do IO<Unit>:
        session(dir, b, out, bin, libfile)
        sessions(more, dir, out, bin, libfile)

def rm.all(bs: List<&2, String>) -> IO(Unit):
  match bs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +b <> more:
      do IO<Unit>:
        S.rm(b)
        rm.all(more)

# grep -c: the lines holding p
type Cn is Type:
  Cn{rd: S.Rd, n: Nat, go: Bool}

def cn.got(rd: S.Rd, +n: Nat, +p: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> Cn:
  match m:
    case None{}:
      Cn{rd, n, False{}}
    case Some{+l}:
      Cn{rd, Bool.pick(Nat, S.infix(l, p), 1n+n, n), True{}}

def cn.pair(+n: Nat, +p: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> Cn:
  (rd, m) = r
  cn.got(rd, n, p, m)

def cn.step(+p: List<&2, U32>, c: Cn) -> IO(Cn):
  match c:
    case Cn{rd, +n, g}:
      do IO<Cn>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        return cn.pair(n, p, r)

def cn.go(fuel: Nat, +p: List<&2, U32>, c: Cn) -> IO(Nat):
  match fuel c:
    case 1n+q Cn{rd, n, True{}}:
      IO.bind(Cn, Nat, cn.step(p, Cn{rd, n, True{}}), cn.go(q, p))
    case _ Cn{rd, n, g}:
      do IO<Nat>:
        S.Rd.close(rd)
        return n

def count(+path: String, +p: List<&2, U32>) -> IO(Nat):
  do IO<Nat>:
    rd : S.Rd <- S.Rd.lines(path)
    cn.go(4000000000n, p, Cn{rd, 0n, True{}})

def pre.run(+f: String, +out: String, +name: String, +repo: String, +bin: String) -> IO(Unit):
  do IO<Unit>:
    +ms : List<&2, List<&2, U32>> <- modules(f)
    +n : Nat = List.length(&2, List<&2, U32>, ms)
    say("precompile: " ++ name ++ ": " ++ Nat.show(n) ++ " modules")
    +rs : List<&2, List<&2, U32>> <- real.all(ms)
    S.write(out ++ ".cmds", cmd.lines(rs))
    S.rm(out ++ ".tmp")
    o : S.Out <- S.run(".", [], 600, "find", [dirname(out), "-maxdepth", "1", "-name", S.base(out) ++ ".batch.*", "-delete"], Nil{})
    S.write(out ++ ".tmp", Nil{})
    +bs : List<&2, String> <- batches(1n+n, S.split.lines(cmd.lines(rs)), repo ++ "/" ++ out ++ ".batch.", 0n)
    sessions(bs, dirname(f), repo ++ "/" ++ out ++ ".tmp", bin, repo ++ "/" ++ cache() ++ "/libraries")
    rm.all(bs)
    +ok : Nat <- count(out ++ ".tmp", S.b("(agda2-status-action \"Checked\")"))
    S.mv(out ++ ".tmp", out)
    say("precompile: " ++ name ++ ": " ++ Nat.show(ok) ++ " of " ++ Nat.show(n) ++ " modules checked")

def pre.if(done: Bool, +f: String, +out: String, +name: String, +repo: String, +bin: String) -> IO(Unit):
  match done:
    case True{}:
      say("precompile: " ++ name ++ " done already")
    case False{}:
      pre.run(f, out, name, repo, bin)

def pre.lib(skip: Bool, +f: String, +repo: String, +bin: String) -> IO(Unit):
  match skip:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      +name = S.base(f)
      +stem = Bool.pick(String, Bool.and(S.suffix(S.b(name), S.b(".agda-lib")), Bool.not(String.eq(name, ".agda-lib"))),
        S.str(List.take(&2, U32, S.b(name), Nat.sub(S.len(S.b(name)), 9n))), name)
      +out = cache() ++ "/precompile-" ++ stem ++ ".log"
      do IO<Unit>:
        +sz : Nat <- S.size(out)
        pre.if(Nat.is_lt(0n, sz), f, out, name, repo, bin)

def pre.skip(+f: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(S.infix(f, S.b("/stdlib-2.4/")), S.infix(f, S.b("/tests/"))), Bool.or(S.infix(f, S.b("/dev/")), S.infix(f, S.b("/doc/"))))

def pre.all(fs: List<&2, List<&2, U32>>, +repo: String, +bin: String) -> IO(Unit):
  match fs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +f <> more:
      do IO<Unit>:
        pre.lib(pre.skip(f), S.str(f), repo, bin)
        pre.all(more, repo, bin)

def precompile(go: Bool, +repo: String, +bin: String) -> IO(Unit):
  match go:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        +xs : List<&2, U32> <- S.read(cache() ++ "/libraries")
        pre.all(List.drop(&2, List<&2, U32>, S.split.lines(xs), 1n), repo, bin)

# The whole ------------------------------------------------------------------------

def bin.of(+over: String, m: Maybe<&2, List<&2, U32>>) -> String:
  match m:
    case Some{x}:
      Bool.pick(String, String.is_empty(over), S.str(x), over)
    case None{}:
      over

def run(pre: Bool) -> IO(Unit):
  do IO<Unit>:
    +r0 : String <- S.realpath(".")
    S.mkdir(cache())
    +a : String <- S.env("AGDA", "agda")
    w0 : List<&2, U32> <- S.must("command -v " ++ a, "sh", ["-c", "command -v \"$1\"", "sh", a])
    +wt : List<&2, U32> <- S.read(S.str(S.chomp(w0)))
    +over : String <- S.env("AGDA_BIN", "")
    +bin : String = bin.of(over, store.bin(wt))
    lt : List<&2, U32> <- S.read(S.str(lib.file(wt)))
    +std23 : String = dirname(S.str(or.empty(lines23(S.split.lines(lt)))))
    fetch("stdlib-2.4", "https://github.com/agda/agda-stdlib", "v2.4")
    fetch("stdlib-classes", "https://github.com/agda/agda-stdlib-classes", "e732956fb01eb616bb3429f290d9434f4ab59b6a")
    fetch("stdlib-meta", "https://github.com/agda/agda-stdlib-meta", "ba0159a198c99185bda86541362f8e0a4a82538a")
    fetch("agda-sets", "https://github.com/input-output-hk/agda-sets", "bc721845dba3208ce0aca59b09242f06d659fd97")
    fetch("iog-prelude", "https://github.com/input-output-hk/iog-agda-prelude", "c6d5b0a46c60680e1ac11cec8b3a7749e9943839")
    hott("core")
    hott("theorems")
    hott("test")
    +ls : List<&2, List<&2, U32>> <- libs()
    pins(ls)
    +rs : List<&2, List<&2, U32>> <- real.all(ls)
    S.write(cache() ++ "/libraries", lines.all(S.b(std23 ++ "/standard-library.agda-lib") <> rs))
    say("agda-libs: " ++ Nat.show(1n+List.length(&2, List<&2, U32>, rs)) ++ " libraries in " ++ cache() ++ "/libraries")
    precompile(pre, r0, bin)
