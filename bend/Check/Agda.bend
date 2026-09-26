import Base
import ../Sys.bend as S
import ../Json.bend as J
import ./Lib.bend as L

# Agda checks Agda units.  Run `bend-check agda-libs precompile` first: it
# writes the library file (run/check-cache/agda/libraries) passed to Agda,
# pins every library's standard library, and leaves every library's
# interfaces built.
#
# A unit is checked inside its own library, where its file lives: the
# unit's file id (repo:NAME/path, own:NAME/path, curated:NAME/path) names a
# file under run/code-sources; the nearest .agda-lib above it is its
# library, and the include directory holding it is where the variant is
# written, as FTUnit<worker>.agda (the head's top-level module renamed to
# match), so the library's flags and dependencies apply and its other
# modules load from their interfaces.  A file in no library is written at
# its module's root with standard-library-2.3 in scope; a unit whose file is
# not on disk is written in the work directory the same way.  Every output
# names the file Unit.agda.
#
# Every variant is the head, the declaration's signature, the variant.  The
# tail is left out: Agda checks top-down.  Literate files arrive as the
# plain Agda bend-units made of them.
#
#   check    agda FILE (status 42 on an error)
#   hole     the last one-line equation's right side replaced by `?`: in
#            interaction mode, Cmd_load then Cmd_goal_type_context, whose
#            display (the goal, a rule, the local context) is the check
#   Context  Cmd_infer_toplevel for each name the body uses, in the same
#            session: `name : type` for each name Agda can type
#   type     none
#
# A mutant is kept when its load in the session did not end "Checked": its
# check is the first message Agda gave (status `-`).

type Cf is Data:
  Cf{bin: String, libs: String, cs: String, t: U32, cap: Nat}

def Cf.bin(+c: Cf) -> String:
  match c:
    case Cf{b, l, s, t, n}:
      b

def Cf.libs(+c: Cf) -> String:
  match c:
    case Cf{b, l, s, t, n}:
      l

def Cf.cs(+c: Cf) -> String:
  match c:
    case Cf{b, l, s, t, n}:
      s

def Cf.t(+c: Cf) -> U32:
  match c:
    case Cf{b, l, s, t, n}:
      t

def Cf.cap(+c: Cf) -> Nat:
  match c:
    case Cf{b, l, s, t, n}:
      n

# Where a unit's variants go: the directory, the flags for a file in no
# library, and the stats key.
type Loc is Data:
  Loc{dir: String, extra: List<&2, String>, key: String}

def Loc.dir(+l: Loc) -> String:
  match l:
    case Loc{d, e, k}:
      d

def Loc.extra(+l: Loc) -> List<&2, String>:
  match l:
    case Loc{d, e, k}:
      e

def std23() -> List<&2, String>:
  ["-l", "standard-library-2.3"]

# the bytes before the first c (all of xs when c is absent)
def upto.go(xs: List<&2, U32>, +c: U32, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> +t False{}:
      h <> upto.go(t, c, S.head.is(t, c))
    case _ _:
      Nil{}

def upto(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  upto.go(xs, c, S.head.is(xs, c))

# the bytes after the first c (all of xs when c is absent, as ${x#*/} does)
def after.go(+xs: List<&2, U32>, ys: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match ys:
    case Nil{}:
      xs
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), t, after.go(xs, t, c))

def after(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  after.go(xs, xs, c)

def base.of(+cs: String, +g: List<&2, U32>) -> String:
  Bool.pick(String, S.prefix(g, S.b("repo:")), cs ++ "/repos/" ++ S.str(S.strip(g, S.b("repo:"))),
    Bool.pick(String, S.prefix(g, S.b("own:")), cs ++ "/own/" ++ S.str(S.strip(g, S.b("own:"))),
      Bool.pick(String, S.prefix(g, S.b("curated:")), cs ++ "/curated/" ++ S.str(S.strip(g, S.b("curated:"))), "")))

# `dirname`
def dirname(+p: String) -> String:
  S.parent(p)

# The .agda-lib files of a directory, `%Y %p` lines from find: the library
# when there is exactly one and it is a file.
def lib.pick(ls: List<&2, List<&2, U32>>) -> Maybe<&2, String>:
  match ls:
    case +l <> Nil{}:
      Bool.pick(Maybe<&2, String>, S.prefix(l, S.b("f ")), Some{S.str(List.drop(&2, U32, l, 2n))}, None{})
    case _:
      None{}

def lib.in(+dir: String) -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    +o : S.Out <- S.run(".", [], 60, "find", [dir, "-mindepth", "1", "-maxdepth", "1", "-name", "*.agda-lib", "-not", "-name", ".*", "-printf", "%Y %p\n"], Nil{})
    return lib.pick(S.split.lines(S.Out.text(o)))

type Lk is Data:
  Lk{go: Bool, dir: String, lib: Maybe<&2, String>}

def lib.next(+base: String, +d: String, m: Maybe<&2, String>) -> Lk:
  match m:
    case Some{f}:
      Lk{False{}, d, Some{f}}
    case None{}:
      +up = dirname(d)
      Lk{Bool.and(S.prefix(S.b(up), S.b(base)), Bool.not(String.eq(up, d))), up, None{}}

def lib.step(+base: String, k: Lk) -> IO(Lk):
  match k:
    case Lk{g, +d, l}:
      do IO<Lk>:
        m : Maybe<&2, String> <- lib.in(d)
        return lib.next(base, d, m)

# the nearest library above a file: walk up while the directory is still
# under the repository
def lib.go(fuel: Nat, +base: String, k: Lk) -> IO(Maybe<&2, String>):
  match fuel k:
    case 1n+p Lk{True{}, d, l}:
      IO.bind(Lk, Maybe<&2, String>, lib.step(base, Lk{True{}, d, l}), lib.go(p, base))
    case _ Lk{g, d, l}:
      IO.pure(Maybe<&2, String>, l)

# the include directories of a library file: the words of its `include:`
# field (the field's first line and the lines up to the next field)
type Inc is Data:
  Inc{on: Bool, words: List<&2, List<&2, U32>>}

def field.start.go(xs: List<&2, U32>, +n: Nat) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.pick(Bool, Bool.or(U32.is_eq(h, 45), Bool.and(U32.is_le(97, h), U32.is_le(h, 122))), field.start.go(t, 1n+n),
        Bool.and(U32.is_eq(h, 58), Nat.is_lt(0n, n)))

def field.start(+l: List<&2, U32>) -> Bool:
  field.start.go(l, 0n)

def inc.line(+l: List<&2, U32>, acc: Inc) -> Inc:
  match acc:
    case Inc{on, +ws}:
      +isinc = S.prefix(l, S.b("include:"))
      +rest = Bool.pick(List<&2, U32>, isinc, List.drop(&2, U32, l, 8n), l)
      +on1 = Bool.or(isinc, on)
      +on2 = Bool.and(on1, Bool.not(Bool.and(field.start(rest), Bool.not(S.prefix(rest, S.b("include:"))))))
      Inc{on2, Bool.pick(List<&2, List<&2, U32>>, on2, List.append(&2, List<&2, U32>, ws, L.words(rest)), ws)}

def incs.go(ls: List<&2, List<&2, U32>>, acc: Inc) -> Inc:
  match ls:
    case Nil{}:
      acc
    case +l <> more:
      incs.go(more, inc.line(l, acc))

def Inc.words(i: Inc) -> List<&2, List<&2, U32>>:
  match i:
    case Inc{on, ws}:
      ws

def incs(+text: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Inc.words(incs.go(S.split.lines(text), Inc{False{}, Nil{}}))

def inc.find(+src: String, +libdir: String, xs: List<&2, List<&2, U32>>) -> IO(Maybe<&2, String>):
  match xs:
    case Nil{}:
      IO.pure(Maybe<&2, String>, None{})
    case +i <> more:
      do IO<Maybe<&2, String>>:
        +p : String <- S.realpath(libdir ++ "/" ++ S.str(i))
        r : Maybe<&2, String> <- inc.find(src, libdir, more)
        return Bool.pick(Maybe<&2, String>, S.prefix(S.b(src), S.b(p ++ "/")), Some{p}, r)

# the top-level module's name in a head (`^module\s+\S+`, first match)
def ws(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 13), Bool.or(U32.is_eq(c, 11), U32.is_eq(c, 12))))

def word.stop(+xs: List<&2, U32>) -> Bool:
  match xs:
    case +h <> t:
      Bool.or(ws(h), U32.is_eq(h, 10))
    case Nil{}:
      True{}

def word.go(xs: List<&2, U32>, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> +t False{}:
      h <> word.go(t, word.stop(t))
    case _ _:
      Nil{}

def ws.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case +h <> t:
      ws(h)
    case Nil{}:
      False{}

def ws.drop(xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t True{}:
      ws.drop(t, ws.head(t))
    case Nil{} _:
      Nil{}
    case h <> t False{}:
      h <> t

# at a line start: `module`, whitespace, a name; the name (empty: no match)
def module.at(+xs: List<&2, U32>) -> List<&2, U32>:
  +r = List.drop(&2, U32, xs, 6n)
  +w = ws.drop(r, ws.head(r))
  Bool.pick(List<&2, U32>, Bool.and(S.prefix(xs, S.b("module")), ws.head(r)), word.go(w, word.stop(w)), Nil{})

def module.go(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +m = module.at(l)
      Bool.pick(List<&2, U32>, Nat.is_eq(S.len(m), 0n), module.go(more), m)

def module.name(+head: List<&2, U32>) -> List<&2, U32>:
  module.go(S.split.lines(head))

# the head with its first `module NAME` line naming `name` instead
def rename.out(+l: List<&2, U32>, +name: List<&2, U32>, done: Bool) -> List<&2, U32>:
  match done:
    case True{}:
      l
    case False{}:
      +m = module.at(l)
      +r = List.drop(&2, U32, l, 6n)
      +w = ws.drop(r, ws.head(r))
      Bool.pick(List<&2, U32>, Nat.is_eq(S.len(m), 0n), l, S.append(S.b("module "), S.append(name, List.drop(&2, U32, w, S.len(m)))))

def rename.go(ls: List<&2, List<&2, U32>>, +name: List<&2, U32>, +done: Bool) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      S.append(rename.out(l, name, done), rename.go(more, name, Bool.or(done, Nat.is_lt(0n, S.len(module.at(l))))))

def lines.nl.last(cur: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match cur:
    case Nil{}:
      Nil{}
    case h <> t:
      [List.reverse(&2, U32, h <> t)]

# lines with their newlines (joining them gives the text back)
def lines.nl.go(xs: List<&2, U32>, cur: List<&2, U32>, nl: Bool) -> List<&2, List<&2, U32>>:
  match xs nl:
    case Nil{} _:
      lines.nl.last(cur)
    case h <> +t True{}:
      List.reverse(&2, U32, h <> cur) <> lines.nl.go(t, Nil{}, S.head.is(t, 10))
    case h <> +t False{}:
      lines.nl.go(t, h <> cur, S.head.is(t, 10))

def lines.nl(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  lines.nl.go(xs, Nil{}, S.head.is(xs, 10))

def root.of(+src: String, +mpath: String) -> Maybe<&2, String>:
  +s = S.b(src)
  +cut = L.before.at(s, S.find(s, S.b(".agda"), 0n))
  +stem = Bool.pick(List<&2, U32>, S.suffix(cut, S.b(".lagda")), List.take(&2, U32, cut, Nat.sub(S.len(cut), 6n)), cut)
  +tail = S.b("/" ++ mpath)
  Bool.pick(Maybe<&2, String>, S.suffix(stem, tail), Some{S.str(List.take(&2, U32, stem, Nat.sub(S.len(stem), S.len(tail))))}, None{})

def placed.root(m: Maybe<&2, String>, +d: String) -> Loc:
  match m:
    case Some{r}:
      Loc{r, std23(), "placed_root"}
    case None{}:
      Loc{d, std23(), "placed_workdir"}

def module.root(+src: String, +d: String, +head: List<&2, U32>) -> Loc:
  +mod = module.name(head)
  Bool.pick(Loc, Nat.is_eq(S.len(mod), 0n), Loc{d, std23(), "placed_workdir"},
    placed.root(root.of(src, S.str(S.replace(mod, [46], [47]))), d))

def in.lib(m: Maybe<&2, String>, +src: String, +d: String, +head: List<&2, U32>) -> Loc:
  match m:
    case Some{inc}:
      Loc{inc, Nil{}, "placed_library"}
    case None{}:
      module.root(src, d, head)

def with.lib(m: Maybe<&2, String>, +src: String, +d: String, +head: List<&2, U32>) -> IO(Loc):
  match m:
    case None{}:
      IO.pure(Loc, module.root(src, d, head))
    case Some{+lib}:
      do IO<Loc>:
        text : List<&2, U32> <- S.read(lib)
        i : Maybe<&2, String> <- inc.find(src, dirname(lib), incs(text))
        return in.lib(i, src, d, head)

def located(ok: Bool, +base: String, +src: String, +d: String, +head: List<&2, U32>) -> IO(Loc):
  match ok:
    case False{}:
      IO.pure(Loc, Loc{d, std23(), "placed_workdir"})
    case True{}:
      do IO<Loc>:
        m : Maybe<&2, String> <- lib.go(64n, base, Lk{True{}, dirname(src), None{}})
        with.lib(m, src, d, head)

def locate(+c: Cf, +d: String, +u: L.U) -> IO(Loc):
  +fid = upto(L.U.id(u), 35)
  +g = upto(fid, 47)
  +rel = after(fid, 47)
  +base = base.of(Cf.cs(c), g)
  +src = base ++ "/" ++ S.str(rel)
  do IO<Loc>:
    there : Bool <- S.exists(src)
    located(Bool.and(Bool.not(String.is_empty(base)), there), base, src, d, L.U.at(u, 5n))

def digit.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case +h <> t:
      Bool.and(U32.is_le(48, h), U32.is_le(h, 57))
    case Nil{}:
      False{}

# Output ---------------------------------------------------------------------

# `sed "s/NAMEm[0-9]*/Unit/g"`
def digits.drop(xs: List<&2, U32>, d: Bool) -> List<&2, U32>:
  match xs d:
    case h <> +t True{}:
      digits.drop(t, digit.head(t))
    case Nil{} _:
      Nil{}
    case h <> t False{}:
      h <> t

def unm.go(fuel: Nat, xs: List<&2, U32>, +p: List<&2, U32>, +n: Nat, hit: Bool) -> List<&2, U32>:
  match fuel xs hit:
    case 0n _ _:
      xs
    case _ Nil{} _:
      Nil{}
    case 1n+f h <> +t True{}:
      +r = List.drop(&2, U32, h <> t, n)
      +rest = digits.drop(r, digit.head(r))
      S.append(S.b("Unit"), unm.go(f, rest, p, n, S.prefix(rest, p)))
    case 1n+f h <> +t False{}:
      h <> unm.go(f, t, p, n, S.prefix(t, p))

def unm(+xs: List<&2, U32>, +name: String) -> List<&2, U32>:
  +p = S.b(name ++ "m")
  unm.go(1n+S.len(xs), xs, p, S.len(p), S.prefix(xs, p))

# `sed "s|DIR/||g; s|D/||g; s|NAME|Unit|g" | head -n CAP`, then $(...):
# also the run's temporary directory (Sys.clean)
def clean(+dir: String, +d: String, +name: String, +cap: Nat, +xs: List<&2, U32>) -> List<&2, U32>:
  +a = S.replace(S.replace(xs, S.b(dir ++ "/"), Nil{}), S.b(d ++ "/"), Nil{})
  +b = S.replace(S.replace(a, S.b(S.parent(d) ++ "/"), Nil{}), S.b(name), S.b("Unit"))
  S.chomp(S.no.nul(S.lines.take(b, cap)))

# the segments of a session's output: the text between its prompts
def segs(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  S.split.str(xs, S.b("Agda2> "))

def letters.len(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, Bool.and(U32.is_le(97, h), U32.is_le(h, 122)), letters.len(t, 1n+n), n)

# the part of `"..." word)` before its last ` word)`
def info.group(+xs: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, xs)
  +w = List.drop(&2, U32, r, 1n)
  +letters = letters.len(w, 0n)
  +rest = List.drop(&2, U32, w, letters)
  Bool.pick(List<&2, U32>, S.head.is(rest, 32), List.reverse(&2, U32, List.drop(&2, U32, rest, 1n)), Nil{})

# `(agda2-info-action "TITLE" "<string>" word)`: the string, decoded
def info.body(+l: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  +p = S.b("(agda2-info-action \"")
  +r = List.drop(&2, U32, l, S.len(p))
  +t = after(r, 34)
  +ok = Bool.and(S.prefix(l, p), S.head.is(t, 32))
  +g0 = List.drop(&2, U32, t, 1n)
  +g = info.group(g0)
  Bool.pick(Maybe<&2, List<&2, U32>>, Bool.and(ok, Bool.and(S.suffix(g0, [41]), Bool.and(S.prefix(g, [34]), S.suffix(g, [34])))), J.string(g), None{})

def progress(+l: List<&2, U32>) -> Bool:
  Bool.or(S.prefix(l, S.b("(agda2-info-action \"*Type-checking*\"")), S.prefix(l, S.b("(agda2-info-action \"*All Done*\"")))

def msg.of(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case Some{x}:
      S.append(x, [10])
    case None{}:
      Nil{}

# the first info action that is not progress, decoded (`jq -r` adds a
# newline, which the shell's $(...) took back)
def msg.go(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      Bool.pick(List<&2, U32>, Bool.and(S.prefix(l, S.b("(agda2-info-action \"")), Bool.not(progress(l))), msg.of(info.body(l)), msg.go(more))

def msg(+seg: List<&2, U32>) -> List<&2, U32>:
  msg.go(S.split.lines(seg))

def only.at(keep: Bool, +l: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match keep:
    case True{}:
      l <> rest
    case False{}:
      rest

def only(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      only.at(S.infix(l, p), l, only(more, p))

def msg.titled(+seg: List<&2, U32>, +title: String) -> List<&2, U32>:
  msg.go(only(S.split.lines(seg), S.b("(agda2-info-action \"" ++ title ++ "\" ")))

# Units ----------------------------------------------------------------------

type Un is Data:
  Un{c: Cf, k: Nat, d: String, dir: String, extra: List<&2, String>, name: String, head: List<&2, U32>, u: L.U}

def Un.clean(+x: Un, +xs: List<&2, U32>) -> List<&2, U32>:
  match x:
    case Un{c, k, d, dir, e, n, h, u}:
      clean(dir, d, n, Cf.cap(c), xs)

def relist(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> relist(more)

def write(+x: Un, +file: String, +head: List<&2, U32>, body: List<&2, U32>) -> IO(Unit):
  match x:
    case Un{c, k, d, dir, e, n, h, u}:
      S.write(dir ++ "/" ++ file ++ ".agda", S.append(head, S.append(L.U.at(u, 6n), body)))

def batch(+x: Un, body: List<&2, U32>) -> IO(S.Out):
  match x:
    case Un{+c, k, d, +dir, +e, +n, +h, u}:
      do IO<S.Out>:
        write(x, n, h, body)
        S.run(dir, [], Cf.t(c), Cf.bin(c), List.append(&1, String, relist(("--library-file=" ++ Cf.libs(c)) <> e), [n ++ ".agda"]), Nil{})

def cmd(+file: String, +c: String) -> List<&2, U32>:
  S.b("IOTCM \"" ++ file ++ "\" None Indirect (" ++ c ++ ")\n")

def infers(+file: String, ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case n <> more:
      S.append(cmd(file, "Cmd_infer_toplevel Simplified \"" ++ S.str(n) ++ "\""), infers(file, more))

def mut.name(+n: String, +j: Nat) -> String:
  n ++ "m" ++ Nat.show(j)

def Un.name(+x: Un) -> String:
  match x:
    case Un{c, k, d, dir, e, n, h, u}:
      n

def Un.headof(+x: Un) -> List<&2, U32>:
  match x:
    case Un{c, k, d, dir, e, n, h, u}:
      L.U.at(u, 5n)

def Un.dirof(+x: Un) -> String:
  match x:
    case Un{c, k, d, dir, e, n, h, u}:
      dir

def mut.rm(+x: Un, n: Nat, +j: Nat) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+m:
      do IO<Unit>:
        S.rm(Un.dirof(x) ++ "/" ++ mut.name(Un.name(x), j) ++ ".agda")
        mut.rm(x, m, 1n+j)

def session(+x: Un, +input: List<&2, U32>) -> IO(S.Out):
  match x:
    case Un{+c, k, d, +dir, +e, n, h, u}:
      S.run(dir, [], U32.mul(Cf.t(c), 3), Cf.bin(c), List.append(&1, String, relist(("--library-file=" ++ Cf.libs(c)) <> e), ["--interaction"]), input)

def seg(+ss: List<&2, List<&2, U32>>, +k: Nat) -> List<&2, U32>:
  L.nth(ss, k)

def goal.of(+x: Un, +ss: List<&2, List<&2, U32>>, +at: Nat) -> L.Hk:
  +g = Un.clean(x, unm(msg.titled(seg(ss, at), "*Goal type etc.*"), Un.name(x)))
  Bool.pick(L.Hk, Nat.is_eq(at, 0n), L.Hk{Nil{}, Nil{}},
    Bool.pick(L.Hk, Nat.is_eq(S.len(g), 0n), L.Hk{Nil{}, ["hole_no_goal"]}, L.Hk{L.check("-", g), ["hole"]}))

def ctx.go(+ss: List<&2, List<&2, U32>>, ns: List<&2, List<&2, U32>>, +at: Nat) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> more:
      +l = S.chomp(msg.titled(seg(ss, at), "*Inferred Type*"))
      S.append(Bool.pick(List<&2, U32>, Nat.is_eq(S.len(l), 0n), Nil{}, S.append(n, S.append(S.b(" : "), S.append(l, [10])))), ctx.go(ss, more, 1n+at))

def mut.one(+x: Un, +m: List<&2, U32>, +s: List<&2, U32>, r: L.Mu) -> L.Mu:
  match r:
    case L.Mu{+cs, +ks}:
      +l = Un.clean(x, unm(msg(s), Un.name(x)))
      Bool.pick(L.Mu, Nat.is_eq(S.len(s), 0n), L.Mu{cs, "mutant_no_response" <> ks},
        Bool.pick(L.Mu, S.infix(s, S.b("(agda2-status-action \"Checked\")")), L.Mu{cs, "mutant_checks" <> ks},
          Bool.pick(L.Mu, Nat.is_eq(S.len(l), 0n), L.Mu{cs, "mutant_no_message" <> ks}, L.Mu{m <> L.check("-", l) <> cs, "mutant_kept" <> ks})))

def muts(+x: Un, +ss: List<&2, List<&2, U32>>, ms: List<&2, List<&2, U32>>, +at: Nat) -> L.Mu:
  match ms:
    case Nil{}:
      L.Mu{Nil{}, Nil{}}
    case +m <> more:
      mut.one(x, m, S.chomp(seg(ss, at)), muts(x, ss, more, 1n+at))

def kept(+u: L.U, +verdict: List<&2, U32>, +cx: List<&2, U32>, h: L.Hk, r: L.Mu) -> L.Got:
  match h r:
    case L.Hk{hc, hk} L.Mu{cs, +ks}:
      L.Kept{L.result(u, verdict <> cx <> hc <> Nil{} <> cs), List.append(&2, String, hk, Bool.pick(List<&2, String>, Nat.is_eq(S.len(cx), 0n), ks, "context" <> ks))}

def rename(+head: List<&2, U32>, +name: List<&2, U32>) -> List<&2, U32>:
  rename.go(lines.nl(head), name, False{})

# each mutant as a file of its own; their load commands
def mut.files(+x: Un, ms: List<&2, List<&2, U32>>, +j: Nat) -> IO(List<&2, U32>):
  match ms:
    case Nil{}:
      IO.pure(List<&2, U32>, Nil{})
    case m <> more:
      +f = mut.name(Un.name(x), j)
      do IO<List<&2, U32>>:
        write(x, f, rename(Un.headof(x), S.b(f)), m)
        r : List<&2, U32> <- mut.files(x, more, 1n+j)
        return S.append(cmd(f ++ ".agda", "Cmd_load \"" ++ f ++ ".agda\" []"), r)

def checked(+x: Un, +verdict: List<&2, U32>) -> IO(L.Got):
  match x:
    case Un{+c, k, d, +dir, e, +n, +h, +u}:
      +hole = L.U.at(u, 10n)
      +hn = Bool.pick(Nat, Nat.is_eq(S.len(hole), 0n), 0n, 1n)
      +ns = L.words(L.U.at(u, 9n))
      +file = n ++ ".agda"
      +gat = Bool.pick(Nat, Nat.is_eq(hn, 0n), 0n, 2n)
      +nat0 = Nat.add(2n, hn)
      +mat = Nat.add(nat0, List.length(&2, List<&2, U32>, ns))
      +hcmds = S.append(cmd(file, "Cmd_load \"" ++ file ++ "\" []"),
        S.append(Bool.pick(List<&2, U32>, Nat.is_eq(hn, 0n), Nil{}, cmd(file, "Cmd_goal_type_context Simplified 0 noRange \"\"")), infers(file, ns)))
      do IO<L.Got>:
        hw : Unit <- Bool.pick(IO(Unit), Nat.is_eq(hn, 0n), IO.pure(Unit, Unit{}), write(x, n, h, hole))
        mcs : List<&2, U32> <- mut.files(x, L.U.mutants(u), 11n)
        +o : S.Out <- session(x, S.append(hcmds, S.append(mcs, [10])))
        S.rm(dir ++ "/" ++ file)
        mut.rm(x, List.length(&2, List<&2, U32>, L.U.mutants(u)), 11n)
        +ss : List<&2, List<&2, U32>> = segs(S.Out.text(o))
        return kept(u, verdict, Un.clean(x, ctx.go(ss, ns, nat0)), goal.of(x, ss, gat), muts(x, ss, L.U.mutants(u), mat))

def orig(ok: Bool, +x: Un, +o: S.Out) -> IO(L.Got):
  match ok:
    case False{}:
      do IO<L.Got>:
        S.rm(Un.dirof(x) ++ "/" ++ Un.name(x) ++ ".agda")
        return L.Dropped{["original_exit_" ++ U32.show(S.Out.status(o))]}
    case True{}:
      checked(x, L.check(U32.show(S.Out.status(o)), Un.clean(x, S.Out.text(o))))

def placed(+c: Cf, +k: Nat, +d: String, +u: L.U, +l: Loc) -> IO(L.Got):
  match l:
    case Loc{+dir, +e, key}:
      +n = "FTUnit" ++ Nat.show(k)
      +x = {Un{c, k, d, dir, e, n, rename(L.U.at(u, 5n), S.b(n)), u} : Un}
      do IO<L.Got>:
        +o : S.Out <- batch(x, L.U.at(u, 7n))
        g : L.Got <- orig(U32.is_eq(S.Out.status(o), 0), x, o)
        return L.Got.key(key, g)

def unit(+c: Cf, +k: Nat, +d: String, +u: L.U) -> IO(L.Got):
  do IO<L.Got>:
    +l : Loc <- locate(c, d, u)
    placed(c, k, d, u, l)

def job(+c: Cf, +k: Nat, +d: String, us: List<&2, L.U>) -> IO(List<&2, L.Got>):
  match us:
    case Nil{}:
      IO.pure(List<&2, L.Got>, Nil{})
    case +u <> more:
      do IO<List<&2, L.Got>>:
        g : L.Got <- unit(c, k, d, u)
        gs : List<&2, L.Got> <- job(c, k, d, more)
        return g <> gs
