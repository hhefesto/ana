import Base
import ../Sys.bend as S
import ../Sha256.bend as Sh
import ../Cksum.bend as Ck
import ./Lib.bend as L

# GHC checks Haskell units.  GHC (default run/check-cache/ghc-harness/bin/ghc,
# `nix build .#ghc-harness -o run/check-cache/ghc-harness`) is GHC 9.10.3
# with the packages in deploy/check/ghc-packages.txt.
#
# A unit is checked inside its own package.  Its file id names a file: a
# Hackage package's (hackage:PKG/path, unpacked from its tarball under
# run/check-cache/hs/src) or a repository's (repo:, own:, curated: under
# run/code-sources).  The package is the nearest directory above the file
# holding a .cabal file (else the repository).  Two ways to see it:
#
#   installed  the package, at the source's version, is in GHC's database
#              (GHC's own libraries, whose sources carry a .cabal.in, and
#              any Hackage package the harness has): -package NAME
#   tree       otherwise: the package's source directories are the import
#              path (-i: the .cabal's hs-source-dirs, and the roots the
#              unit files' own module names imply), with the .cabal's
#              default-extensions, default-language, include-dirs and
#              cpp-options, and only its build-depends visible; interfaces
#              go to run/check-cache/hs/hi/<package>.
#
# A job is one package (bend-check dispatches a package's units, wherever
# they sit in UNITS.nul, to one worker, largest package first), so its
# interfaces are written by one process.  Every variant is written as
# Unit.hs in the worker's directory: the file with its module renamed Unit,
# the variant in the body's place.
#
#   check    ghc -fno-code -w -fdiagnostics-color=never
#                -fno-show-valid-hole-fits -fwrite-interface Unit.hs
#   Context  `:type NAME` in GHCi on the original, for each name the body
#            uses; a name GHCi cannot type (a local variable) is left out
#   hole     the hole's load in GHCi fails: its errors
#   type     the original without its signature, loaded with
#            -Wmissing-signatures: the warning for the name is GHC's own
#            type for it
#   mutants  the first two GHCi rejects, from a start the unit's id picks
#            (POSIX cksum of the id and a newline)
#
# GHCi has no two-way pipe here: one GHCi run per batch of a package's
# units (at most 50) is fed the whole command script at once, each variant
# copied over Unit.hs by `:!cp` before its `:load`, each command followed by
# `:!echo @@@END`, and the output is cut at those markers.  A batch that
# times out or dies is halved; a single unit is then run command by command
# (an original that times out drops the unit, a mutant that times out is
# not kept).  Checks made in GHCi have status `-`.  A file without a
# `module` line is skipped: a Main module needs `main`.

type Hc is Data:
  Hc{ghc: String, cs: String, hc: String, t: U32, cap: Nat, have: Set(), hide: List<&2, String>, tar: Map<&2, String>}

def Hc.ghc(+c: Hc) -> String:
  match c:
    case Hc{g, s, h, t, n, v, d, r}:
      g

def Hc.cs(+c: Hc) -> String:
  match c:
    case Hc{g, s, h, t, n, v, d, r}:
      s

def Hc.hc(+c: Hc) -> String:
  match c:
    case Hc{g, s, h, t, n, v, d, r}:
      h

def Hc.t(+c: Hc) -> U32:
  match c:
    case Hc{g, s, h, t, n, v, d, r}:
      t

def Hc.cap(+c: Hc) -> Nat:
  match c:
    case Hc{g, s, h, t, n, v, d, r}:
      n

def Hc.have(+c: Hc) -> Set():
  match c:
    case Hc{g, s, h, t, n, v, d, r}:
      v

def Hc.hide(+c: Hc) -> List<&2, String>:
  match c:
    case Hc{g, s, h, t, n, v, d, r}:
      d

def Hc.tar(+c: Hc) -> Map<&2, String>:
  match c:
    case Hc{g, s, h, t, n, v, d, r}:
      r

def has.fin(r: Set() & Bool) -> Bool:
  (s, b) = r
  b

def has(+c: Hc, +name: String) -> Bool:
  has.fin(Set.has(Hc.have(c), name))

def FLAGS() -> List<&2, String>:
  ["-fno-code", "-w", "-fdiagnostics-color=never", "-fno-show-valid-hole-fits", "+RTS", "-M2G", "-RTS"]

def relist(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> relist(more)

# Bytes and paths -------------------------------------------------------------

def upto.go(xs: List<&2, U32>, +c: U32, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> +t False{}:
      h <> upto.go(t, c, S.head.is(t, c))
    case _ _:
      Nil{}

# the bytes before the first c
def upto(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  upto.go(xs, c, S.head.is(xs, c))

def after.go(+xs: List<&2, U32>, ys: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match ys:
    case Nil{}:
      xs
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), t, after.go(xs, t, c))

# the bytes after the first c (all of xs when there is none)
def after(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  after.go(xs, xs, c)

def tar.get(r: Map<&2, String> & String) -> String:
  (m, v) = r
  v

# the directory of a group (empty: none; a Hackage package's is where its
# tarball unpacks)
def group.dir(+c: Hc, +g: List<&2, U32>) -> String:
  +cs = Hc.cs(c)
  +name = S.str(S.strip(g, S.b("hackage:")))
  +b = tar.get(Map.get(String, "", Hc.tar(c), name))
  Bool.pick(String, S.prefix(g, S.b("repo:")), cs ++ "/repos/" ++ S.str(S.strip(g, S.b("repo:"))),
    Bool.pick(String, S.prefix(g, S.b("own:")), cs ++ "/own/" ++ S.str(S.strip(g, S.b("own:"))),
      Bool.pick(String, S.prefix(g, S.b("curated:")), cs ++ "/curated/" ++ S.str(S.strip(g, S.b("curated:"))),
        Bool.pick(String, Bool.and(S.prefix(g, S.b("hackage:")), Bool.not(String.is_empty(b))), Hc.hc(c) ++ "/src/" ++ b, ""))))

def sha16(+s: String) -> String:
  String.take(Sh.sha256(S.b(s)), 16n)

# The package ----------------------------------------------------------------

# A unit's package: its mode (installed, tree or none), name, key (the first
# 16 hex digits of its directory's sha256), interface directory and flags.
type Pkg is Data:
  Pkg{mode: String, name: String, key: String, hi: String, flags: List<&2, String>}

def Pkg.key(+p: Pkg) -> String:
  match p:
    case Pkg{m, n, k, h, f}:
      k

def Pkg.mode(+p: Pkg) -> String:
  match p:
    case Pkg{m, n, k, h, f}:
      m

def Pkg.hi(+p: Pkg) -> String:
  match p:
    case Pkg{m, n, k, h, f}:
      h

def Pkg.flags(+p: Pkg) -> List<&2, String>:
  match p:
    case Pkg{m, n, k, h, f}:
      f

def none() -> Pkg:
  Pkg{"none", "", "none", "", Nil{}}

# the .cabal (else .cabal.in) files of a directory, `%Y %f` lines, sorted as
# the shell's glob sorts them
def cabal.names(ls: List<&2, List<&2, U32>>, +ext: String) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +r = cabal.names(more, ext)
      Bool.pick(List<&2, List<&2, U32>>, Bool.and(S.prefix(l, S.b("f ")), S.suffix(l, S.b(ext))), List.drop(&2, U32, l, 2n) <> r, r)

def sorted(+xs: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    o : S.Out <- S.run(".", [], 60, "sort", [], S.append(S.join(xs, 10), [10]))
    return S.split.lines(S.Out.text(o))

def first.or(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case x <> more:
      x
    case Nil{}:
      Nil{}

def cabal.pick(+dir: String, cs: List<&2, List<&2, U32>>, ins: List<&2, List<&2, U32>>) -> IO(String):
  match cs ins:
    case Nil{} Nil{}:
      IO.pure(String, "")
    case +x <> xt _:
      do IO<String>:
        s : List<&2, List<&2, U32>> <- sorted(x <> xt)
        return dir ++ "/" ++ S.str(first.or(s))
    case Nil{} +y <> yt:
      do IO<String>:
        s : List<&2, List<&2, U32>> <- sorted(y <> yt)
        return dir ++ "/" ++ S.str(first.or(s))

def cabal.in(+dir: String) -> IO(String):
  do IO<String>:
    +o : S.Out <- S.run(".", [], 60, "find", [dir, "-mindepth", "1", "-maxdepth", "1", "(", "-name", "*.cabal", "-o", "-name", "*.cabal.in", ")", "-not", "-name", ".*", "-printf", "%Y %f\n"], Nil{})
    +ls : List<&2, List<&2, U32>> = S.split.lines(S.Out.text(o))
    cabal.pick(dir, cabal.names(ls, ".cabal"), cabal.names(ls, ".cabal.in"))

type Cw is Data:
  Cw{go: Bool, dir: String, cabal: String}

def cabal.step(+pd: String, w: Cw) -> IO(Cw):
  match w:
    case Cw{g, +d, c}:
      do IO<Cw>:
        +f : String <- cabal.in(d)
        +up : String = S.parent(d)
        return Cw{Bool.and(String.is_empty(f), Bool.and(Bool.not(String.eq(d, pd)), S.prefix(S.b(up ++ "/"), S.b(pd ++ "/")))), up, f}

# the nearest .cabal above the file, up to and including the group's directory
def cabal.go(fuel: Nat, +pd: String, w: Cw) -> IO(String):
  match fuel w:
    case 1n+p Cw{True{}, d, c}:
      IO.bind(Cw, String, cabal.step(pd, Cw{True{}, d, c}), cabal.go(p, pd))
    case _ Cw{g, d, c}:
      IO.pure(String, c)

# `awk 'tolower($1) == "KEY:" { print $2; exit }'`
def field.of(ls: List<&2, List<&2, U32>>, +key: String) -> String:
  match ls:
    case Nil{}:
      ""
    case +l <> more:
      +ws = L.words(l)
      Bool.pick(String, String.eq(String.to_lower(S.str(L.nth(ws, 0n))), key), S.str(L.nth(ws, 1n)), field.of(more, key))

# The stanza fields the harness reads: every stanza's, conditionals
# ignored; a field's value runs over the indented lines after it.
type Fd is Data:
  Fd{f: String, v: List<&2, U32>, out: List<&2, List<&2, U32>>}

def wanted(+k: String) -> Bool:
  Bool.or(Bool.or(Bool.or(String.eq(k, "hs-source-dirs"), String.eq(k, "default-extensions")), Bool.or(String.eq(k, "extensions"), String.eq(k, "default-language"))),
    Bool.or(Bool.or(String.eq(k, "include-dirs"), String.eq(k, "cpp-options")), String.eq(k, "build-depends")))

def sp(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 13), Bool.or(U32.is_eq(c, 11), U32.is_eq(c, 12))))

def sp.len(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, sp(h), sp.len(t, 1n+n), n)

def name.char(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 45), Bool.or(Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), Bool.and(U32.is_le(97, c), U32.is_le(c, 122))))

def name.len(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, name.char(h), name.len(t, 1n+n), n)

# `^[[:space:]]*[A-Za-z-]+:`: the length of the match (0: none)
def field.at(+l: List<&2, U32>) -> Nat:
  +a = sp.len(l, 0n)
  +r = List.drop(&2, U32, l, a)
  +b = name.len(r, 0n)
  Bool.pick(Nat, Bool.and(Nat.is_lt(0n, b), S.head.is(List.drop(&2, U32, r, b), 58)), Nat.add(a, 1n+b), 0n)

def fd.flush(+f: String, +v: List<&2, U32>, +out: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, String.is_empty(f), out, S.append(S.b(f), 9 <> v) <> out)

def comment(+l: List<&2, U32>) -> Bool:
  S.prefix(List.drop(&2, U32, l, sp.len(l, 0n)), S.b("--"))

def key.of(+l: List<&2, U32>, +n: Nat) -> String:
  String.to_lower(S.str(List.filter(~U32, ~(c => Bool.and(Bool.not(sp(c)), U32.is_ne(c, 58))), List.take(&2, U32, l, n))))

def sp.len.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case +h <> t:
      sp(h)
    case Nil{}:
      False{}

def fd.line(+l: List<&2, U32>, st: Fd) -> Fd:
  match st:
    case Fd{+f, +v, +out}:
      +n = field.at(l)
      +k = key.of(l, n)
      +indented = Bool.and(Nat.is_lt(0n, S.len(l)), sp.len.head(l))
      Bool.pick(Fd, comment(l), Fd{f, v, out},
        Bool.pick(Fd, Nat.is_lt(0n, n), Bool.pick(Fd, wanted(k), Fd{k, List.drop(&2, U32, l, n), fd.flush(f, v, out)}, Fd{"", Nil{}, fd.flush(f, v, out)}),
          Bool.pick(Fd, Bool.and(Bool.not(String.is_empty(f)), indented), Fd{f, S.append(v, 32 <> l), out}, Fd{"", Nil{}, fd.flush(f, v, out)})))

def fd.go(ls: List<&2, List<&2, U32>>, st: Fd) -> Fd:
  match ls:
    case Nil{}:
      st
    case +l <> more:
      fd.go(more, fd.line(l, st))

def fd.fin(st: Fd) -> List<&2, List<&2, U32>>:
  match st:
    case Fd{f, v, out}:
      List.reverse(&2, List<&2, U32>, fd.flush(f, v, out))

# the dependency names of a build-depends value: each comma-separated
# item's first word's leading [A-Za-z][A-Za-z0-9-]*
def dep.len(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, Bool.or(name.char(h), Bool.and(U32.is_le(48, h), U32.is_le(h, 57))), dep.len(t, 1n+n), n)

def dep.alpha(+w: List<&2, U32>) -> Bool:
  match w:
    case +h <> t:
      Bool.or(Bool.and(U32.is_le(65, h), U32.is_le(h, 90)), Bool.and(U32.is_le(97, h), U32.is_le(h, 122)))
    case Nil{}:
      False{}

def dep.of(+item: List<&2, U32>) -> List<&2, U32>:
  +w = L.nth(L.words(item), 0n)
  +ok = Bool.and(Nat.is_lt(0n, S.len(w)), dep.alpha(w))
  Bool.pick(List<&2, U32>, ok, List.take(&2, U32, w, dep.len(w, 0n)), Nil{})

def deps.lines(+k: List<&2, U32>, items: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match items:
    case Nil{}:
      Nil{}
    case +i <> more:
      +d = dep.of(i)
      +r = deps.lines(k, more)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(d), 0n), r, S.append(k, 9 <> d) <> r)

def word.lines(+k: List<&2, U32>, ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> more:
      S.append(k, 9 <> w) <> word.lines(k, more)

def commas(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, U32.is_eq(h, 44), 32, h) <> commas(t)

# one field's `key<TAB>value` lines
def field.lines(+kv: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +k = upto(kv, 9)
  +v = after(kv, 9)
  Bool.pick(List<&2, List<&2, U32>>, S.eq(k, S.b("build-depends")), deps.lines(k, S.split.str(v, [44])), word.lines(k, L.words(commas(v))))

def fields.lines(fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match fs:
    case Nil{}:
      Nil{}
    case +f <> more:
      List.append(&2, List<&2, U32>, field.lines(f), fields.lines(more))

def uniq.sorted(+xs: List<&2, List<&2, U32>>) -> IO(List<&2, U32>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, U32>, Nil{})
    case +h <> t:
      do IO<List<&2, U32>>:
        o : S.Out <- S.run(".", [], 60, "sort", ["-u"], S.append(S.join(h <> t, 10), [10]))
        return S.Out.text(o)

# the info file's first part: mode, name, and the stanza fields (a .cabal
# written on Windows ends its lines in CR: deleted)
def info.write(+c: Hc, +info: String, +cabal: String) -> IO(Unit):
  do IO<Unit>:
    +crlf : List<&2, U32> <- S.read(cabal)
    +ls : List<&2, List<&2, U32>> = S.split.lines(List.filter(~U32, ~(c => U32.is_ne(c, 13)), crlf))
    +name : String = Bool.pick(String, String.is_empty(cabal), "", field.of(ls, "name:"))
    +ver : String = Bool.pick(String, String.is_empty(cabal), "", field.of(ls, "version:"))
    +inst : Bool = Bool.and(Bool.not(String.is_empty(name)), Bool.and(Bool.or(S.suffix(S.b(cabal), S.b(".cabal.in")), has(c, name ++ "-" ++ ver)), has(c, name)))
    +mode : String = Bool.pick(String, inst, "installed", "tree")
    fl : List<&2, U32> <- uniq.sorted(Bool.pick(List<&2, List<&2, U32>>, String.is_empty(cabal), Nil{}, fields.lines(fd.fin(fd.go(ls, Fd{"", Nil{}, Nil{}})))))
    S.write(info, S.append(S.b("mode\t" ++ mode ++ "\nname\t" ++ name ++ "\n"), fl))

def info.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  S.split.lines(xs)

def info.get(ls: List<&2, List<&2, U32>>, +k: String) -> String:
  match ls:
    case Nil{}:
      ""
    case +l <> more:
      Bool.pick(String, S.eq(upto(l, 9), S.b(k)), S.str(after(l, 9)), info.get(more, k))

def info.has.root(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      Bool.or(S.prefix(l, S.b("root")), info.has.root(more))

# the module a file declares: `^module[[:space:]]+[A-Za-z0-9_.']+`, first match
def mod.char(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), Bool.and(U32.is_le(97, c), U32.is_le(c, 122))),
    Bool.or(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), Bool.or(Bool.or(U32.is_eq(c, 95), U32.is_eq(c, 46)), U32.is_eq(c, 39))))

def mod.len(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, mod.char(h), mod.len(t, 1n+n), n)

# at a line: `module`, spaces, a name; (the name, the match's length)
def mod.at(+l: List<&2, U32>) -> List<&2, U32>:
  +r = List.drop(&2, U32, l, 6n)
  +a = sp.len(r, 0n)
  +w = List.drop(&2, U32, r, a)
  +n = mod.len(w, 0n)
  Bool.pick(List<&2, U32>, Bool.and(S.prefix(l, S.b("module")), Bool.and(Nat.is_lt(0n, a), Nat.is_lt(0n, n))), List.take(&2, U32, w, n), Nil{})

def mod.first(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +m = mod.at(l)
      Bool.pick(List<&2, U32>, Nat.is_eq(S.len(m), 0n), mod.first(more), m)

def slashes(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, U32.is_eq(h, 46), 47, h) <> slashes(t)

# the root a file's module name implies, if the path ends with it
def root.of(+f: String, +mod: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +s = S.b(f)
  +stem = Bool.pick(List<&2, U32>, S.suffix(s, S.b(".hs")), List.take(&2, U32, s, Nat.sub(S.len(s), 3n)), s)
  +tail = {47 <> slashes(mod) : List<&2, U32>}
  Bool.pick(List<&2, List<&2, U32>>, Bool.and(Nat.is_lt(0n, S.len(mod)), S.suffix(stem, tail)),
    [S.append(S.b("root\t"), List.take(&2, U32, stem, Nat.sub(S.len(stem), S.len(tail))))], Nil{})

def roots(fs: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +f <> more:
      do IO<List<&2, List<&2, U32>>>:
        text : List<&2, U32> <- S.read(S.str(f))
        r : List<&2, List<&2, U32>> <- roots(more)
        return List.append(&2, List<&2, U32>, root.of(S.str(f), mod.first(S.split.lines(text))), r)

def existing(+base: String, fs: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +f <> more:
      do IO<List<&2, List<&2, U32>>>:
        ok : Bool <- S.exists(base ++ "/" ++ S.str(f))
        +r : List<&2, List<&2, U32>> <- existing(base, more)
        return Bool.pick(List<&2, List<&2, U32>>, ok, S.b(base ++ "/" ++ S.str(f)) <> r, r)

def unit.files(ids: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ids:
    case Nil{}:
      Nil{}
    case +i <> more:
      after(upto(i, 35), 47) <> unit.files(more)

def prefixed(+p: String, xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      S.append(S.b(p), x) <> prefixed(p, more)

# a tree package's first setup: its unit files and the roots they imply
def info.roots(+info: String, +base: String, +pd: String, +ids: List<&2, List<&2, U32>>) -> IO(Unit):
  do IO<Unit>:
    rel0 : List<&2, U32> <- uniq.sorted(unit.files(ids))
    +fs : List<&2, List<&2, U32>> <- existing(base, S.split.lines(rel0))
    rs0 : List<&2, List<&2, U32>> <- roots(fs)
    rs : List<&2, U32> <- uniq.sorted(rs0)
    S.add(info, S.append(S.join(prefixed("file\t", fs), 10), Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, fs), 0n), Nil{}, [10])))
    S.add(info, rs)
    S.add(info, S.b("root\t" ++ pd ++ "\n"))

# the flags an info file's lines give (in its order)
type Fl is Data:
  Fl{flags: List<&2, String>, deps: List<&2, String>}

def flag.kind(n: Nat, +c: Hc, +pd: String, +name: String, +v: String, +fs: List<&2, String>, +ds: List<&2, String>) -> IO(Fl):
  match n:
    case 1n:
      IO.pure(Fl, Bool.pick(Fl, Bool.and(Bool.not(String.eq(v, name)), has(c, v)), Fl{fs, List.append(&2, String, ds, ["-package", v])}, Fl{fs, ds}))
    case 2n:
      IO.pure(Fl, Fl{List.append(&2, String, fs, ["-i" ++ v]), ds})
    case 3n:
      do IO<Fl>:
        r : String <- S.realpath(pd ++ "/" ++ v)
        return Fl{List.append(&2, String, fs, ["-i" ++ r]), ds}
    case 4n:
      IO.pure(Fl, Fl{List.append(&2, String, fs, ["-X" ++ v]), ds})
    case 5n:
      do IO<Fl>:
        r : String <- S.realpath(pd ++ "/" ++ v)
        return Fl{List.append(&2, String, fs, ["-I" ++ r]), ds}
    case 6n:
      IO.pure(Fl, Fl{List.append(&2, String, fs, [v]), ds})
    case _:
      IO.pure(Fl, Fl{fs, ds})

def flag.line(+c: Hc, +pd: String, +name: String, +l: List<&2, U32>, st: Fl) -> IO(Fl):
  match st:
    case Fl{+fs, +ds}:
      +k = S.str(upto(l, 9))
      +v = S.str(after(l, 9))
      flag.kind(Bool.pick(Nat, String.eq(k, "build-depends"), 1n, Bool.pick(Nat, String.eq(k, "root"), 2n,
        Bool.pick(Nat, String.eq(k, "hs-source-dirs"), 3n, Bool.pick(Nat, Bool.or(Bool.or(String.eq(k, "default-extensions"), String.eq(k, "extensions")), String.eq(k, "default-language")), 4n,
          Bool.pick(Nat, String.eq(k, "include-dirs"), 5n, Bool.pick(Nat, String.eq(k, "cpp-options"), 6n, 0n)))))), c, pd, name, v, fs, ds)

def flags.go(+c: Hc, +pd: String, +name: String, ls: List<&2, List<&2, U32>>, st: Fl) -> IO(Fl):
  match ls:
    case Nil{}:
      IO.pure(Fl, st)
    case +l <> more:
      IO.bind(Fl, Fl, flag.line(c, pd, name, l, st), flags.go(c, pd, name, more))

def flags.fin(+c: Hc, +hi: String, st: Fl) -> List<&2, String>:
  match st:
    case Fl{fs, +ds}:
      List.append(&2, String, fs, List.append(&2, String,
        Bool.pick(List<&2, String>, Nat.is_eq(List.length(&2, String, ds), 0n), Hc.hide(c), "-hide-all-packages" <> ds), ["-hidir", hi]))

def pkg.mode(inst: Bool, +c: Hc, +info: String, +pd: String, +key: String, +hi: String, +ids: List<&2, List<&2, U32>>, +base: String, +mode: String, +name: String, +rooted: Bool) -> IO(Pkg):
  match inst:
    case True{}:
      IO.pure(Pkg, Pkg{mode, name, key, hi, List.append(&2, String, Hc.hide(c), ["-package", name])})
    case False{}:
      do IO<Pkg>:
        r : Unit <- Bool.pick(IO(Unit), rooted, IO.pure(Unit, Unit{}), info.roots(info, base, pd, ids))
        t1 : List<&2, U32> <- S.read(info)
        st : Fl <- flags.go(c, pd, name, info.lines(t1), Fl{Nil{}, Nil{}})
        return Pkg{mode, name, key, hi, flags.fin(c, hi, st)}

def pkg.flags(+c: Hc, +info: String, +pd: String, +key: String, +hi: String, +ids: List<&2, List<&2, U32>>, +base: String) -> IO(Pkg):
  do IO<Pkg>:
    +t0 : List<&2, U32> <- S.read(info)
    +ls0 : List<&2, List<&2, U32>> = info.lines(t0)
    +mode : String = info.get(ls0, "mode")
    +name : String = info.get(ls0, "name")
    pkg.mode(String.eq(mode, "installed"), c, info, pd, key, hi, ids, base, mode, name, info.has.root(ls0))

def pkg.cabal(+c: Hc, +pd0: String, +cabal: String, +ids: List<&2, List<&2, U32>>, +base: String) -> IO(Pkg):
  +pd = Bool.pick(String, String.is_empty(cabal), pd0, S.parent(cabal))
  +key = sha16(pd)
  +hi = Hc.hc(c) ++ "/hi/" ++ key
  +info = Hc.hc(c) ++ "/info/" ++ key
  do IO<Pkg>:
    there : Bool <- S.exists(info)
    w : Unit <- Bool.pick(IO(Unit), there, IO.pure(Unit, Unit{}), info.write(c, info, cabal))
    pkg.flags(c, info, pd, key, hi, ids, base)

def pkg.src(ok: Bool, +c: Hc, +pd: String, +src: String, +ids: List<&2, List<&2, U32>>) -> IO(Pkg):
  match ok:
    case False{}:
      IO.pure(Pkg, none())
    case True{}:
      do IO<Pkg>:
        +cabal : String <- cabal.go(64n, pd, Cw{True{}, S.parent(src), ""})
        pkg.cabal(c, pd, cabal, ids, pd)

def pkg.unpacked(ok: Bool, +c: Hc, +pd: String, +rel: List<&2, U32>, +ids: List<&2, List<&2, U32>>) -> IO(Pkg):
  match ok:
    case False{}:
      IO.pure(Pkg, none())
    case True{}:
      do IO<Pkg>:
        there : Bool <- S.exists(pd ++ "/" ++ S.str(rel))
        pkg.src(there, c, pd, pd ++ "/" ++ S.str(rel), ids)

def unpack(need: Bool, +c: Hc, +pd: String) -> IO(Bool):
  match need:
    case False{}:
      IO.pure(Bool, True{})
    case True{}:
      do IO<Bool>:
        +o : S.Out <- S.run(".", [], 600, "tar", ["xzf", Hc.cs(c) ++ "/tarballs/" ++ S.str(L.before.last(S.b(S.base(pd)), S.b(".tar.gz"))) ++ ".tar.gz", "-C", Hc.hc(c) ++ "/src"], Nil{})
        return U32.is_eq(S.Out.status(o), 0)

def pkg.dir(+c: Hc, +pd: String, +g: List<&2, U32>, +rel: List<&2, U32>, +ids: List<&2, List<&2, U32>>) -> IO(Pkg):
  do IO<Pkg>:
    there : Bool <- S.exists(pd)
    ok : Bool <- unpack(Bool.and(S.prefix(g, S.b("hackage:")), Bool.not(there)), c, pd)
    pkg.unpacked(ok, c, pd, rel, ids)

# the unit's package (ids: every unit of its package, for the roots)
def pkg(+c: Hc, +u: L.U, +ids: List<&2, List<&2, U32>>) -> IO(Pkg):
  +fid = upto(L.U.id(u), 35)
  +g = upto(fid, 47)
  +rel = after(fid, 47)
  +pd = group.dir(c, g)
  Bool.pick(IO(Pkg), String.is_empty(pd), IO.pure(Pkg, none()), pkg.dir(c, pd, g, rel, ids))

# GHCi -------------------------------------------------------------------------

# the head with its first `module NAME` line naming Unit
def rename.out(+l: List<&2, U32>, done: Bool) -> List<&2, U32>:
  match done:
    case True{}:
      l
    case False{}:
      +m = mod.at(l)
      +r = List.drop(&2, U32, l, 6n)
      +a = sp.len(r, 0n)
      Bool.pick(List<&2, U32>, Nat.is_eq(S.len(m), 0n), l, S.append(S.b("module Unit"), List.drop(&2, U32, r, Nat.add(a, S.len(m)))))

def rename.go(ls: List<&2, List<&2, U32>>, +done: Bool) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      S.append(rename.out(l, done), rename.go(more, Bool.or(done, Nat.is_lt(0n, S.len(mod.at(l))))))

def lines.nl.last(cur: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match cur:
    case Nil{}:
      Nil{}
    case h <> t:
      [List.reverse(&2, U32, h <> t)]

def lines.nl.go(xs: List<&2, U32>, cur: List<&2, U32>, nl: Bool) -> List<&2, List<&2, U32>>:
  match xs nl:
    case Nil{} _:
      lines.nl.last(cur)
    case h <> +t True{}:
      List.reverse(&2, U32, h <> cur) <> lines.nl.go(t, Nil{}, S.head.is(t, 10))
    case h <> +t False{}:
      lines.nl.go(t, h <> cur, S.head.is(t, 10))

# lines with their newlines
def lines.nl(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  lines.nl.go(xs, Nil{}, S.head.is(xs, 10))

def head.unit(+head: List<&2, U32>) -> List<&2, U32>:
  rename.go(lines.nl(head), False{})

def has.module.line(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      Bool.or(Bool.and(S.prefix(l, S.b("module")), sp.len.head(List.drop(&2, U32, l, 6n))), has.module.line(more))

# The segments of a GHCi run: the output between `@@@END` markers, as the
# shell read it line by line (a marker ends a line; the text before it on
# that line, if any, is one more line of the segment).
type Sg is Data:
  Sg{cur: List<&2, U32>, out: List<&2, List<&2, U32>>}

def sg.line(+l: List<&2, U32>, st: Sg) -> Sg:
  match st:
    case Sg{+cur, +out}:
      +m = S.suffix(l, S.b("@@@END"))
      +pre = List.take(&2, U32, l, Nat.sub(S.len(l), 6n))
      Bool.pick(Sg, m, Sg{Nil{}, S.append(cur, Bool.pick(List<&2, U32>, Nat.is_eq(S.len(pre), 0n), Nil{}, S.append(pre, [10]))) <> out},
        Sg{S.append(cur, S.append(l, [10])), out})

def sg.go(ls: List<&2, List<&2, U32>>, st: Sg) -> Sg:
  match ls:
    case Nil{}:
      st
    case +l <> more:
      sg.go(more, sg.line(l, st))

def sg.fin(st: Sg) -> List<&2, List<&2, U32>>:
  match st:
    case Sg{cur, out}:
      List.reverse(&2, List<&2, U32>, out)

# only whole lines count (the shell's `read` drops a last line without a
# newline)
def whole.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ls = S.split.lines(xs)
  Bool.pick(List<&2, List<&2, U32>>, S.suffix(xs, [10]), ls, List.take(&2, List<&2, U32>, ls, Nat.sub(List.length(&2, List<&2, U32>, ls), 1n)))

def segs(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  sg.fin(sg.go(whole.lines(S.no.nul(xs)), Sg{Nil{}, Nil{}}))

def marker() -> String:
  ":!echo @@@END\n"

def load.cmds(+file: String) -> String:
  ":!cp " ++ file ++ " Unit.hs\n:load Unit.hs\n" ++ marker()

def types(ns: List<&2, List<&2, U32>>) -> String:
  match ns:
    case Nil{}:
      ""
    case n <> more:
      ":type " ++ S.str(n) ++ "\n" ++ types(more)

# a unit's mutants in the order they are tried: from the start its id picks
def rot(+ms: List<&2, List<&2, U32>>, +k: Nat) -> List<&2, List<&2, U32>>:
  List.append(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, ms, k), List.take(&2, List<&2, U32>, ms, k))

def mut.start(+u: L.U) -> Nat:
  +nm = List.length(&2, List<&2, U32>, L.U.mutants(u))
  Bool.pick(Nat, Nat.is_eq(nm, 0n), 0n, Nat.mod(U32.to_nat(Ck.cksum(S.append(L.U.id(u), [10]))), nm))

def mutants.tried(+u: L.U) -> List<&2, List<&2, U32>>:
  rot(L.U.mutants(u), mut.start(u))

# A unit prepared for GHCi: its package, its head renamed, and where its
# variant files are (prefix p: p.o.hs, p.h.hs, p.t.hs, p.m<j>.hs).
type Pu is Data:
  Pu{u: L.U, pkg: Pkg, head: List<&2, U32>, p: String}

def Pu.u(+x: Pu) -> L.U:
  match x:
    case Pu{u, k, h, p}:
      u

def Pu.pkg(+x: Pu) -> Pkg:
  match x:
    case Pu{u, k, h, p}:
      k

def variant(+x: Pu, +pre: Bool, body: List<&2, U32>) -> List<&2, U32>:
  match x:
    case Pu{+u, k, +h, p}:
      S.append(h, S.append(Bool.pick(List<&2, U32>, pre, L.U.at(u, 6n), Nil{}), S.append(body, L.U.at(u, 8n))))

def Pu.p(+x: Pu) -> String:
  match x:
    case Pu{u, k, h, p}:
      p

def write.muts(+dir: String, +x: Pu, ms: List<&2, List<&2, U32>>, +j: Nat) -> IO(Unit):
  match ms:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case m <> more:
      do IO<Unit>:
        S.write(dir ++ "/" ++ Pu.p(x) ++ ".m" ++ Nat.show(j) ++ ".hs", variant(x, True{}, m))
        write.muts(dir, x, more, 1n+j)

def write.unit(+dir: String, +x: Pu) -> IO(Unit):
  +u = Pu.u(x)
  +p = Pu.p(x)
  do IO<Unit>:
    S.write(dir ++ "/" ++ p ++ ".o.hs", variant(x, True{}, L.U.at(u, 7n)))
    S.write(dir ++ "/" ++ p ++ ".h.hs", variant(x, True{}, L.U.at(u, 10n)))
    S.write(dir ++ "/" ++ p ++ ".t.hs", variant(x, False{}, L.U.at(u, 7n)))
    write.muts(dir, x, mutants.tried(u), 0n)

def mut.cmds(+p: String, n: Nat, +j: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+k:
      load.cmds(p ++ ".m" ++ Nat.show(j) ++ ".hs") ++ mut.cmds(p, k, 1n+j)

# the commands a unit sends, and how many markers they print
def unit.cmds(+x: Pu, +muts: Bool) -> String:
  +u = Pu.u(x)
  +p = Pu.p(x)
  +ns = L.words(L.U.at(u, 9n))
  load.cmds(p ++ ".o.hs")
    ++ Bool.pick(String, Nat.is_eq(List.length(&2, List<&2, U32>, ns), 0n), "", types(ns) ++ marker())
    ++ Bool.pick(String, Nat.is_eq(S.len(L.U.at(u, 10n)), 0n), "", load.cmds(p ++ ".h.hs"))
    ++ ":set -Wmissing-signatures\n" ++ marker() ++ load.cmds(p ++ ".t.hs") ++ ":set -w\n" ++ marker()
    ++ Bool.pick(String, muts, mut.cmds(p, List.length(&2, List<&2, U32>, L.U.mutants(u)), 0n), "")

def unit.segs(+x: Pu, +muts: Bool) -> Nat:
  +u = Pu.u(x)
  +ns = L.words(L.U.at(u, 9n))
  Nat.add(Nat.add(1n, Bool.pick(Nat, Nat.is_eq(List.length(&2, List<&2, U32>, ns), 0n), 0n, 1n)),
    Nat.add(Nat.add(Bool.pick(Nat, Nat.is_eq(S.len(L.U.at(u, 10n)), 0n), 0n, 1n), 3n),
      Bool.pick(Nat, muts, List.length(&2, List<&2, U32>, L.U.mutants(u)), 0n)))

def setup.cmds() -> String:
  ":set prompt \"\"\n" ++ marker() ++ ":set prompt-cont \"\"\n" ++ marker()

def batch.cmds(xs: List<&2, Pu>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> more:
      unit.cmds(x, True{}) ++ batch.cmds(more)

def batch.segs(xs: List<&2, Pu>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> more:
      Nat.add(unit.segs(x, True{}), batch.segs(more))

def ghci(+c: Hc, +dir: String, +flags: List<&2, String>, +script: String, +secs: U32) -> IO(S.Out):
  S.run(dir, [], secs, Hc.ghc(c), relist(List.append(&2, String, ["--interactive", "-ignore-dot-ghci", "-v1"], List.append(&2, String, FLAGS(), flags))), S.b(script))

# Decisions ----------------------------------------------------------------------

def ok.line(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      Bool.or(S.prefix(l, S.b("Ok, ")), ok.line(more))

def loaded(+seg: List<&2, U32>) -> Bool:
  ok.line(S.split.lines(seg))

# `^\[ *[0-9]+ of [0-9]+\] `: the length (0: not a progress line's start)
def spaces.len(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, U32.is_eq(h, 32), spaces.len(t, 1n+n), n)

def digits.len(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, Bool.and(U32.is_le(48, h), U32.is_le(h, 57)), digits.len(t, 1n+n), n)

def progress.len(+l: List<&2, U32>) -> Nat:
  +a = List.drop(&2, U32, l, 1n)
  +s = spaces.len(a, 0n)
  +b = List.drop(&2, U32, a, s)
  +d1 = digits.len(b, 0n)
  +c = List.drop(&2, U32, b, d1)
  +d = List.drop(&2, U32, c, 4n)
  +d2 = digits.len(d, 0n)
  +e = List.drop(&2, U32, d, d2)
  Bool.pick(Nat, Bool.and(Bool.and(S.head.is(l, 91), Nat.is_lt(0n, d1)), Bool.and(S.prefix(c, S.b(" of ")), Bool.and(Nat.is_lt(0n, d2), S.prefix(e, S.b("] "))))),
    Nat.add(Nat.add(1n, s), Nat.add(Nat.add(d1, 4n), Nat.add(d2, 2n))), 0n)

# a progress line about another module than Unit (the batch check leaves
# those out)
def other.progress(+l: List<&2, U32>) -> Bool:
  +n = progress.len(l)
  +r = List.drop(&2, U32, l, n)
  +w = Bool.pick(List<&2, U32>, S.prefix(r, S.b("Compiling ")), List.drop(&2, U32, r, 10n), Bool.pick(List<&2, U32>, S.prefix(r, S.b("Skipping ")), List.drop(&2, U32, r, 9n), Nil{}))
  +v = List.drop(&2, U32, w, spaces.len(w, 0n))
  Bool.and(Bool.and(Nat.is_lt(0n, n), Bool.or(S.prefix(r, S.b("Compiling ")), S.prefix(r, S.b("Skipping ")))),
    Bool.and(Nat.is_lt(0n, S.len(v)), Bool.not(Bool.or(S.prefix(v, S.b("Unit ")), S.eq(v, S.b("Unit"))))))

# GHCi's own lines: progress (`Compiling`) and the closing Ok/Failed
def ghci.line(+l: List<&2, U32>) -> Bool:
  +n = progress.len(l)
  Bool.or(Bool.and(Nat.is_lt(0n, n), S.prefix(List.drop(&2, U32, l, n), S.b("Compiling "))),
    Bool.and(Bool.or(S.prefix(l, S.b("Ok, ")), S.prefix(l, S.b("Failed, "))), S.suffix(l, S.b(" loaded."))))

def drop.lines(ls: List<&2, List<&2, U32>>, +which: Nat) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      S.append(Bool.pick(List<&2, U32>, Bool.pick(Bool, Nat.is_eq(which, 0n), ghci.line(l), other.progress(l)), Nil{}, S.append(l, [10])), drop.lines(more, which))

def clean(+dir: String, +cap: Nat, +xs: List<&2, U32>) -> List<&2, U32>:
  S.clean(dir, cap, xs)

# a load's errors, as a check (GHCi's own lines left out)
def session.text(+dir: String, +cap: Nat, +seg: List<&2, U32>) -> List<&2, U32>:
  clean(dir, cap, drop.lines(S.split.lines(seg), 0n))

# the Context: the `name :: type` lines of the :type answers
type Cx is Data:
  Cx{keep: Bool, out: List<&2, U32>}

def cx.line(+l: List<&2, U32>, st: Cx) -> Cx:
  match st:
    case Cx{keep, +out}:
      +inter = S.prefix(l, S.b("<interactive>"))
      +top = Bool.and(Nat.is_lt(0n, S.len(l)), Bool.not(Bool.or(S.head.is(l, 32), S.head.is(l, 9))))
      +k = Bool.pick(Bool, inter, False{}, Bool.pick(Bool, top, S.infix(l, S.b(" :: ")), keep))
      Cx{k, Bool.pick(List<&2, U32>, Bool.and(k, Bool.not(inter)), S.append(out, S.append(l, [10])), out)}

def cx.go(ls: List<&2, List<&2, U32>>, st: Cx) -> Cx:
  match ls:
    case Nil{}:
      st
    case +l <> more:
      cx.go(more, cx.line(l, st))

def cx.out(st: Cx) -> List<&2, U32>:
  match st:
    case Cx{k, o}:
      o

def context(+dir: String, +cap: Nat, +seg: List<&2, U32>) -> List<&2, U32>:
  clean(dir, cap, cx.out(cx.go(S.split.lines(seg), Cx{False{}, Nil{}})))

# the type: the missing-signatures warning block for the unit's name
type Tb is Data:
  Tb{keep: Bool, blk: List<&2, U32>, out: List<&2, U32>}

def tb.line(+name: List<&2, U32>, +l: List<&2, U32>, st: Tb) -> Tb:
  match st:
    case Tb{+keep, +blk, +out}:
      +start = S.prefix(l, S.b("Unit.hs:"))
      +out1 = Bool.pick(List<&2, U32>, Bool.and(start, keep), S.append(out, blk), out)
      +blk1 = Bool.pick(List<&2, U32>, start, Nil{}, blk)
      +keep1 = Bool.and(Bool.not(start), keep)
      +skip = ghci.line(l)
      +blk2 = S.append(blk1, S.append(l, [10]))
      Bool.pick(Tb, skip, Tb{keep1, blk1, out1},
        Tb{Bool.or(keep1, Bool.and(S.infix(l, S.append(name, S.b(" ::"))), S.infix(blk2, S.b("missing-signatures")))), blk2, out1})

def tb.go(+name: List<&2, U32>, ls: List<&2, List<&2, U32>>, st: Tb) -> Tb:
  match ls:
    case Nil{}:
      st
    case +l <> more:
      tb.go(name, more, tb.line(name, l, st))

def tb.fin(st: Tb) -> List<&2, U32>:
  match st:
    case Tb{keep, blk, +out}:
      Bool.pick(List<&2, U32>, keep, S.append(out, blk), out)

def type.block(+dir: String, +cap: Nat, +name: List<&2, U32>, +seg: List<&2, U32>) -> List<&2, U32>:
  clean(dir, cap, tb.fin(tb.go(name, S.split.lines(seg), Tb{False{}, Nil{}, Nil{}})))

# What GHCi said about a unit: its segments, in command order.
type Said is Data:
  Said{orig: List<&2, U32>, ctx: List<&2, U32>, hole: List<&2, U32>, typ: List<&2, U32>, muts: List<&2, List<&2, U32>>}

def said.of(+x: Pu, +ss: List<&2, List<&2, U32>>) -> Said:
  +u = Pu.u(x)
  +hn = Bool.pick(Nat, Nat.is_eq(List.length(&2, List<&2, U32>, L.words(L.U.at(u, 9n))), 0n), 0n, 1n)
  +hh = Bool.pick(Nat, Nat.is_eq(S.len(L.U.at(u, 10n)), 0n), 0n, 1n)
  +ti = Nat.add(Nat.add(2n, hn), hh)
  Said{L.nth(ss, 0n), Bool.pick(List<&2, U32>, Nat.is_eq(hn, 0n), Nil{}, L.nth(ss, 1n)), Bool.pick(List<&2, U32>, Nat.is_eq(hh, 0n), Nil{}, L.nth(ss, Nat.add(1n, hn))),
    L.nth(ss, ti), List.drop(&2, List<&2, U32>, ss, Nat.add(ti, 2n))}

# The batch check: ghc on the original, the verdict.
def hs.check(+c: Hc, +dir: String, +x: Pu) -> IO(S.Out):
  +k = Pu.pkg(x)
  do IO<S.Out>:
    S.write(dir ++ "/Unit.hs", variant(x, True{}, L.U.at(Pu.u(x), 7n)))
    r : Unit <- Bool.pick(IO(Unit), String.is_empty(Pkg.hi(k)), IO.pure(Unit, Unit{}), S.rm(Pkg.hi(k) ++ "/Unit.hi"))
    S.rm(dir ++ "/Unit.hi")
    S.run(dir, [], Hc.t(c), Hc.ghc(c), relist(List.append(&2, String, FLAGS(), List.append(&2, String, ["-fwrite-interface"], List.append(&2, String, Pkg.flags(k), ["Unit.hs"])))), Nil{})

def verdict.text(+dir: String, +cap: Nat, +o: S.Out) -> List<&2, U32>:
  L.check(U32.show(S.Out.status(o)), clean(dir, cap, drop.lines(S.split.lines(S.Out.text(o)), 1n)))

def hole.of(+dir: String, +cap: Nat, +u: L.U, +seg: List<&2, U32>) -> L.Hk:
  Bool.pick(L.Hk, Nat.is_eq(S.len(L.U.at(u, 10n)), 0n), L.Hk{Nil{}, Nil{}},
    Bool.pick(L.Hk, loaded(seg), L.Hk{Nil{}, ["hole_not_failing"]}, L.Hk{L.check("-", session.text(dir, cap, seg)), ["hole"]}))

def type.of(+dir: String, +cap: Nat, +u: L.U, +seg: List<&2, U32>) -> L.Hk:
  +b = type.block(dir, cap, L.U.at(u, 2n), seg)
  Bool.pick(L.Hk, loaded(seg), Bool.pick(L.Hk, Nat.is_eq(S.len(b), 0n), L.Hk{Nil{}, ["type_no_warning"]}, L.Hk{L.check("-", b), ["type"]}), L.Hk{Nil{}, ["type_not_loaded"]})

def kept(+u: L.U, +verdict: List<&2, U32>, +cx: List<&2, U32>, h: L.Hk, t: L.Hk, r: L.Mu) -> L.Got:
  match h t r:
    case L.Hk{hc, hk} L.Hk{tc, tk} L.Mu{cs, +ks}:
      L.Kept{L.result(u, verdict <> cx <> hc <> tc <> cs), List.append(&2, String, Bool.pick(List<&2, String>, Nat.is_eq(S.len(cx), 0n), Nil{}, ["context"]), List.append(&2, String, hk, List.append(&2, String, tk, ks)))}

def missing.module(+seg: List<&2, U32>) -> Bool:
  Bool.or(S.infix(seg, S.b("Could not find module")), S.infix(seg, S.b("Could not load module")))

def Said.orig(+sd: Said) -> List<&2, U32>:
  match sd:
    case Said{o, c, h, t, m}:
      o

# Batches ---------------------------------------------------------------------

def batch.flags(xs: List<&2, Pu>) -> List<&2, String>:
  match xs:
    case x <> more:
      Pkg.flags(Pu.pkg(x))
    case Nil{}:
      Nil{}

def write.all(+dir: String, xs: List<&2, Pu>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +x <> more:
      do IO<Unit>:
        write.unit(dir, x)
        write.all(dir, more)

# a GHCi run over a batch: whether it answered every command, and the
# answers (the two prompt settings' dropped)
type Bst is Data:
  Start{}
  Ran{ok: Bool, ss: List<&2, List<&2, U32>>}

def ran.of(+n: Nat, +o: S.Out) -> Bst:
  +ss = List.drop(&2, List<&2, U32>, segs(S.Out.text(o)), 2n)
  Ran{Bool.and(U32.is_eq(S.Out.status(o), 0), Nat.is_le(n, List.length(&2, List<&2, U32>, ss))), ss}

def batch.ran(+c: Hc, +dir: String, +xs: List<&2, Pu>) -> IO(Bst):
  +n = batch.segs(xs)
  do IO<Bst>:
    write.all(dir, xs)
    +o : S.Out <- ghci(c, dir, batch.flags(xs), setup.cmds() ++ batch.cmds(xs), U32.add(60, U32.mul(Hc.t(c), U32.from_nat(n))))
    return ran.of(n, o)

# A single unit, command by command: the original's commands in one run
# (a timeout drops the unit), then each mutant in a run of its own (a
# timeout: not kept), the first two rejected kept.
type Fm is Data:
  Fm{go: Bool, ms: List<&2, List<&2, U32>>, ss: List<&2, List<&2, U32>>, j: Nat, kept: Nat}

def fm.next(r: Bst, ms: List<&2, List<&2, U32>>, ss: List<&2, List<&2, U32>>, +j: Nat, +kept: Nat) -> Fm:
  match r ms:
    case Ran{True{}, +got} +m <> +more:
      +k1 = Bool.pick(Nat, loaded(L.nth(got, 0n)), kept, 1n+kept)
      Fm{Bool.and(Nat.is_lt(k1, 2n), Nat.is_lt(0n, List.length(&2, List<&2, U32>, more))), more, List.append(&2, List<&2, U32>, ss, [L.nth(got, 0n)]), 1n+j, k1}
    case _ +m <> +more:
      Fm{Nat.is_lt(0n, List.length(&2, List<&2, U32>, more)), more, List.append(&2, List<&2, U32>, ss, [S.b("@@@TIMEOUT")]), 1n+j, kept}
    case _ Nil{}:
      Fm{False{}, Nil{}, ss, j, kept}

def fm.step(+c: Hc, +dir: String, +x: Pu, st: Fm) -> IO(Fm):
  match st:
    case Fm{g, ms, ss, +j, +kept}:
      do IO<Fm>:
        +o : S.Out <- ghci(c, dir, Pkg.flags(Pu.pkg(x)), setup.cmds() ++ load.cmds(Pu.p(x) ++ ".m" ++ Nat.show(j) ++ ".hs"), U32.add(60, Hc.t(c)))
        +r : Bst = ran.of(1n, o)
        return fm.next(r, ms, ss, j, kept)

def fm.go(fuel: Nat, +c: Hc, +dir: String, +x: Pu, st: Fm) -> IO(List<&2, List<&2, U32>>):
  match fuel st:
    case 1n+p Fm{True{}, ms, ss, j, k}:
      IO.bind(Fm, List<&2, List<&2, U32>>, fm.step(c, dir, x, Fm{True{}, ms, ss, j, k}), fm.go(p, c, dir, x))
    case _ Fm{g, ms, ss, j, k}:
      IO.pure(List<&2, List<&2, U32>>, ss)

# the mutants' answers as a single unit tried them: a timeout is marked, and
# counts as `mutant_timeout`
def muts.single(+dir: String, +cap: Nat, ms: List<&2, List<&2, U32>>, ss: List<&2, List<&2, U32>>) -> L.Mu:
  match ms ss:
    case +m <> mt +s <> st:
      +r = muts.single(dir, cap, mt, st)
      Bool.pick(L.Mu, S.eq(s, S.b("@@@TIMEOUT")), L.mu.put(Nil{}, ["mutant_timeout"], r),
        Bool.pick(L.Mu, loaded(s), L.mu.put(Nil{}, ["mutant_checks"], r),
          L.mu.put([m, L.check("-", session.text(dir, cap, s))], ["mutant_kept"], r)))
    case _ _:
      L.Mu{Nil{}, Nil{}}

def single.judged(ok: Bool, +c: Hc, +dir: String, +x: Pu, +sd: Said, +o: S.Out, ms: List<&2, List<&2, U32>>) -> L.Got:
  match ok sd:
    case False{} _:
      L.Dropped{["original_batch_exit_" ++ U32.show(S.Out.status(o))]}
    case True{} Said{og, cx, hs, ts, x0}:
      +cap = Hc.cap(c)
      +u = Pu.u(x)
      kept(u, verdict.text(dir, cap, o), context(dir, cap, cx), hole.of(dir, cap, u, hs), type.of(dir, cap, u, ts), muts.single(dir, cap, mutants.tried(u), ms))

def single.batch(+c: Hc, +dir: String, +x: Pu, +sd: Said) -> IO(L.Got):
  do IO<L.Got>:
    ms : List<&2, List<&2, U32>> <- fm.go(64n, c, dir, x, Fm{Nat.is_lt(0n, List.length(&2, List<&2, U32>, L.U.mutants(Pu.u(x)))), mutants.tried(Pu.u(x)), Nil{}, 0n, 0n})
    +o : S.Out <- hs.check(c, dir, x)
    return single.judged(U32.is_eq(S.Out.status(o), 0), c, dir, x, sd, o, ms)

def single.core(ok: Bool, +c: Hc, +dir: String, +x: Pu, +ss: List<&2, List<&2, U32>>) -> IO(L.Got):
  match ok:
    case False{}:
      IO.pure(L.Got, L.Dropped{["original_session_timeout"]})
    case True{}:
      +sd = said.of(x, List.append(&2, List<&2, U32>, ss, [Nil{}, Nil{}]))
      +og = Said.orig(sd)
      Bool.pick(IO(L.Got), loaded(og), single.batch(c, dir, x, sd),
        IO.pure(L.Got, L.Dropped{[Bool.pick(String, missing.module(og), "original_missing_module", "original_fails")]}))

def single.ran(+c: Hc, +dir: String, +x: Pu, r: Bst) -> IO(L.Got):
  match r:
    case Ran{ok, ss}:
      single.core(ok, c, dir, x, ss)
    case Start{}:
      IO.pure(L.Got, L.Dropped{["original_session_timeout"]})

def single(+c: Hc, +dir: String, +x: Pu) -> IO(L.Got):
  +n = unit.segs(x, False{})
  do IO<L.Got>:
    write.unit(dir, x)
    +o : S.Out <- ghci(c, dir, Pkg.flags(Pu.pkg(x)), setup.cmds() ++ unit.cmds(x, False{}), U32.add(60, U32.mul(Hc.t(c), U32.from_nat(n))))
    single.ran(c, dir, x, ran.of(n, o))

def singles(+c: Hc, +dir: String, xs: List<&2, Pu>) -> IO(List<&2, L.Got>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, L.Got>, Nil{})
    case +x <> more:
      do IO<List<&2, L.Got>>:
        g : L.Got <- single(c, dir, x)
        gs : List<&2, L.Got> <- singles(c, dir, more)
        return g <> gs

def halves.join(b: IO(List<&2, L.Got>), a: List<&2, L.Got>) -> IO(List<&2, L.Got>):
  IO.bind(List<&2, L.Got>, List<&2, L.Got>, b, r => IO.pure(List<&2, L.Got>, List.append(&2, L.Got, a, r)))

# Jobs -------------------------------------------------------------------------

# a unit ready for GHCi, or already decided (skipped), with the stats keys
# of its placement
type Prep is Data:
  Skip{g: L.Got}
  Ready{x: Pu, keys: List<&2, String>}

def prep.pkg(+u: L.U, +i: Nat, +k: Pkg) -> Prep:
  +mode = Pkg.mode(k)
  Ready{Pu{u, k, head.unit(L.U.at(u, 5n)), "u" ++ Nat.show(i)}, Bool.pick(List<&2, String>, String.eq(mode, "none"), ["placed_no_source", "mode_none"], ["mode_" ++ mode])}

def prep(+c: Hc, +ids: List<&2, List<&2, U32>>, +i: Nat, +u: L.U) -> IO(Prep):
  Bool.pick(IO(Prep), has.module.line(S.split.lines(L.U.at(u, 5n))),
    IO.bind(Pkg, Prep, pkg(c, u, ids), k => IO.pure(Prep, prep.pkg(u, i, k))),
    IO.pure(Prep, Skip{L.Dropped{["skipped_no_module"]}}))

def prep.all(+c: Hc, +ids: List<&2, List<&2, U32>>, us: List<&2, L.U>, +i: Nat) -> IO(List<&2, Prep>):
  match us:
    case Nil{}:
      IO.pure(List<&2, Prep>, Nil{})
    case +u <> more:
      do IO<List<&2, Prep>>:
        p : Prep <- prep(c, ids, i, u)
        ps : List<&2, Prep> <- prep.all(c, ids, more, 1n+i)
        return p <> ps

def batch.max() -> Nat:
  50n

# the run of ready units with the package key, at most n of them
def same.run(ps: List<&2, Prep>, +key: String, n: Nat) -> List<&2, Pu>:
  match ps n:
    case Ready{+x, ks} <> more 1n+m:
      Bool.pick(List<&2, Pu>, String.eq(Pkg.key(Pu.pkg(x)), key), x <> same.run(more, key, m), Nil{})
    case _ _:
      Nil{}

def keys.run(ps: List<&2, Prep>, n: Nat) -> List<&2, List<&2, String>>:
  match ps n:
    case Ready{x, ks} <> more 1n+m:
      ks <> keys.run(more, m)
    case _ _:
      Nil{}

def with.keys(gs: List<&2, L.Got>, ks: List<&2, List<&2, String>>) -> List<&2, L.Got>:
  match gs ks:
    case +g <> gt +k <> kt:
      L.Got.keys(k, g) <> with.keys(gt, kt)
    case _ _:
      gs

def head.loaded(ss: List<&2, List<&2, U32>>) -> Bool:
  match ss:
    case +s <> t:
      loaded(s)
    case Nil{}:
      False{}

# The mutants in the order tried, their segments: the first two GHCi
# rejects are kept (with the stats of those tried until then).
def muts.pick(+dir: String, +cap: Nat, ms: List<&2, List<&2, U32>>, ss: List<&2, List<&2, U32>>, +kept: Nat, go: Bool, ok: Bool) -> L.Mu:
  match ms ss go ok:
    case +m <> mt +s <> +st True{} True{}:
      L.mu.put(Nil{}, ["mutant_checks"], muts.pick(dir, cap, mt, st, kept, Nat.is_lt(kept, 2n), head.loaded(st)))
    case +m <> mt +s <> +st True{} False{}:
      L.mu.put([m, L.check("-", session.text(dir, cap, s))], ["mutant_kept"], muts.pick(dir, cap, mt, st, 1n+kept, Nat.is_lt(1n+kept, 2n), head.loaded(st)))
    case _ _ _ _:
      L.Mu{Nil{}, Nil{}}

def judged(ok: Bool, +c: Hc, +dir: String, +x: Pu, +sd: Said, +o: S.Out) -> L.Got:
  match ok sd:
    case False{} _:
      L.Dropped{["original_batch_exit_" ++ U32.show(S.Out.status(o))]}
    case True{} Said{og, cx, hs, ts, ms}:
      +cap = Hc.cap(c)
      +u = Pu.u(x)
      kept(u, verdict.text(dir, cap, o), context(dir, cap, cx), hole.of(dir, cap, u, hs), type.of(dir, cap, u, ts), muts.pick(dir, cap, mutants.tried(u), ms, 0n, True{}, head.loaded(ms)))

def decide.batch(+c: Hc, +dir: String, +x: Pu, +sd: Said) -> IO(L.Got):
  do IO<L.Got>:
    +o : S.Out <- hs.check(c, dir, x)
    return judged(U32.is_eq(S.Out.status(o), 0), c, dir, x, sd, o)

# a unit's outcome from what GHCi said, the batch check run when the
# original loaded
def decide(+c: Hc, +dir: String, +x: Pu, +sd: Said) -> IO(L.Got):
  +og = Said.orig(sd)
  Bool.pick(IO(L.Got), loaded(og), decide.batch(c, dir, x, sd),
    IO.pure(L.Got, L.Dropped{[Bool.pick(String, missing.module(og), "original_missing_module", "original_fails")]}))

def decide.all(+c: Hc, +dir: String, xs: List<&2, Pu>, +ss: List<&2, List<&2, U32>>) -> IO(List<&2, L.Got>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, L.Got>, Nil{})
    case +x <> more:
      +n = unit.segs(x, True{})
      do IO<List<&2, L.Got>>:
        g : L.Got <- decide(c, dir, x, said.of(x, List.take(&2, List<&2, U32>, ss, n)))
        gs : List<&2, L.Got> <- decide.all(c, dir, more, List.drop(&2, List<&2, U32>, ss, n))
        return g <> gs

# a batch in one GHCi run; one that times out or dies is halved, down to
# single units
def run.batch(fuel: Nat, +c: Hc, +dir: String, +xs: List<&2, Pu>, st: Bst) -> IO(List<&2, L.Got>):
  match fuel st:
    case 0n _:
      singles(c, dir, xs)
    case 1n+(+f) Start{}:
      IO.bind(Bst, List<&2, L.Got>, batch.ran(c, dir, xs), run.batch(f, c, dir, xs))
    case 1n+(+f) Ran{True{}, ss}:
      decide.all(c, dir, xs, ss)
    case 1n+(+f) Ran{False{}, ss}:
      +n = List.length(&2, Pu, xs)
      +h = Nat.div(n, 2n)
      Bool.pick(IO(List<&2, L.Got>), Nat.is_le(n, 1n), singles(c, dir, xs),
        IO.bind(List<&2, L.Got>, List<&2, L.Got>, run.batch(f, c, dir, List.take(&2, Pu, xs, h), Start{}),
          halves.join(run.batch(f, c, dir, List.drop(&2, Pu, xs, h), Start{}))))

def process(fuel: Nat, +c: Hc, +dir: String, ps: List<&2, Prep>) -> IO(List<&2, L.Got>):
  match fuel ps:
    case 0n _:
      IO.pure(List<&2, L.Got>, Nil{})
    case _ Nil{}:
      IO.pure(List<&2, L.Got>, Nil{})
    case 1n+f Skip{g} <> more:
      do IO<List<&2, L.Got>>:
        gs : List<&2, L.Got> <- process(f, c, dir, more)
        return g <> gs
    case 1n+f Ready{+x, +ks} <> +more:
      +xs = {x <> same.run(more, Pkg.key(Pu.pkg(x)), Nat.sub(batch.max(), 1n)) : List<&2, Pu>}
      +n = List.length(&2, Pu, xs)
      +kss = {ks <> keys.run(more, Nat.sub(n, 1n)) : List<&2, List<&2, String>>}
      do IO<List<&2, L.Got>>:
        a : List<&2, L.Got> <- run.batch(8n, c, dir, xs, Start{})
        b : List<&2, L.Got> <- process(f, c, dir, List.drop(&2, Prep, more, Nat.sub(n, 1n)))
        return List.append(&2, L.Got, with.keys(a, kss), b)

# A chunk of a package's units (ids: every unit of the package, for the
# roots of a tree package's first setup).
def job(+c: Hc, +dir: String, +ids: List<&2, List<&2, U32>>, us: List<&2, L.U>) -> IO(List<&2, L.Got>):
  do IO<List<&2, L.Got>>:
    +ps : List<&2, Prep> <- prep.all(c, ids, us, 0n)
    process(1n+List.length(&2, Prep, ps), c, dir, ps)
