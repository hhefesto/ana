import Base
import ../Sys.bend as S
import ./Lib.bend as L

# Bend checks Bend units.  A unit's file id is `CLASS:<path under BEND_SRC>`
# (own:, repo:, curated:; BEND_SRC is that class's tree) followed by
# `#NAME@LINE`.  Bend imports are paths relative to the file,
# so each worker copies the .bend files of the unit's repository (the
# path's first component) once, and writes every variant as Unit.bend
# beside the original: the head, the declaration's first part (a law, or
# a def's header), the variant.  The tail is left out: a def may only call
# the defs above it.
#
#   check    bend Unit.bend --check-only (it reports the first error only)
#   hole     the body replaced by `?goal`: the error shows the goal and
#            the context
#   Context  for each name the body uses, the header of its definition:
#            the file's own `def NAME(...) -> T` or `law NAME:` line, else
#            the first line of `bend base NAME` when it is a def, law or
#            type (cached per worker)
#   type     none

type Cf is Data:
  Cf{bend: String, src: String, t: U32, cap: Nat}

def Cf.bend(+c: Cf) -> String:
  match c:
    case Cf{b, s, t, n}:
      b

def Cf.src(+c: Cf) -> String:
  match c:
    case Cf{b, s, t, n}:
      s

def Cf.t(+c: Cf) -> U32:
  match c:
    case Cf{b, s, t, n}:
      t

def Cf.cap(+c: Cf) -> Nat:
  match c:
    case Cf{b, s, t, n}:
      n

# the id after its class (the first `:`)
def after.class(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 58), t, after.class(t))

# the file's path under BEND_SRC: the id without its class and its `#NAME@..`
def rel.of(+id: List<&2, U32>, +name: List<&2, U32>) -> List<&2, U32>:
  L.before.last(after.class(id), List.append(&2, U32, 35 <> name, [64]))

def first.go(xs: List<&2, U32>, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> +t False{}:
      h <> first.go(t, S.head.is(t, 47))
    case _ _:
      Nil{}

# the path's first component (its repository)
def repo.of(+rel: List<&2, U32>) -> List<&2, U32>:
  first.go(rel, S.head.is(rel, 47))

def check.of(+dir: String, +cap: Nat, +o: S.Out) -> List<&2, U32>:
  L.check(U32.show(S.Out.status(o)), S.clean(dir, cap, S.Out.text(o)))

def run(+c: Cf, +udir: String, +u: L.U, body: List<&2, U32>) -> IO(S.Out):
  do IO<S.Out>:
    S.write(udir ++ "/Unit.bend", S.append(L.U.at(u, 5n), S.append(L.U.at(u, 6n), body)))
    S.run(udir, [], Cf.t(c), Cf.bend(c), ["Unit.bend", "--check-only"], Nil{})

# Context -------------------------------------------------------------------

def colon.drop.r(r: List<&2, U32>) -> List<&2, U32>:
  match r:
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 58), t, h <> t)
    case Nil{}:
      Nil{}

def colon.drop(+l: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, l)
  List.reverse(&2, U32, colon.drop.r(r))

# `^(def|law) NAME[(:]`
def sig.line(+name: List<&2, U32>, +l: List<&2, U32>) -> Bool:
  +d = S.append(S.b("def "), name)
  +w = S.append(S.b("law "), name)
  Bool.or(Bool.or(S.prefix(l, S.append(d, [40])), S.prefix(l, S.append(d, [58]))),
    Bool.or(S.prefix(l, S.append(w, [40])), S.prefix(l, S.append(w, [58]))))

def sig.find(ls: List<&2, List<&2, U32>>, +name: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      None{}
    case +l <> more:
      Bool.pick(Maybe<&2, List<&2, U32>>, sig.line(name, l), Some{l}, sig.find(more, name))

# the first line of `bend base NAME` when it opens a def, law or type
def base.pick(+xs: List<&2, U32>) -> List<&2, U32>:
  +l = S.lines.first(xs)
  Bool.pick(List<&2, U32>, Bool.or(Bool.or(S.prefix(l, S.b("def ")), S.prefix(l, S.b("law "))), S.prefix(l, S.b("type "))), l, Nil{})

def base.cached(hit: Bool, +c: Cf, +path: String, +name: List<&2, U32>) -> IO(List<&2, U32>):
  match hit:
    case True{}:
      S.read(path)
    case False{}:
      do IO<List<&2, U32>>:
        +o : S.Out <- S.run.quiet(".", [], 60, Cf.bend(c), ["base", S.str(name)], Nil{})
        +v : List<&2, U32> = base.pick(S.Out.text(o))
        S.write(path, v)
        return v

def base(+c: Cf, +dir: String, +name: List<&2, U32>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    h : Bool <- S.exists(dir ++ "/base/" ++ S.str(name))
    base.cached(h, c, dir ++ "/base/" ++ S.str(name), name)

def sig.of(m: Maybe<&2, List<&2, U32>>, +c: Cf, +dir: String, +name: List<&2, U32>) -> IO(List<&2, U32>):
  match m:
    case Some{l}:
      IO.pure(List<&2, U32>, S.append(colon.drop(l), [10]))
    case None{}:
      do IO<List<&2, U32>>:
        +v : List<&2, U32> <- base(c, dir, name)
        return Bool.pick(List<&2, U32>, Nat.is_eq(S.len(v), 0n), Nil{}, S.append(colon.drop(v), [10]))

def ctx(+c: Cf, +dir: String, +ls: List<&2, List<&2, U32>>, ns: List<&2, List<&2, U32>>) -> IO(List<&2, U32>):
  match ns:
    case Nil{}:
      IO.pure(List<&2, U32>, Nil{})
    case +n <> more:
      do IO<List<&2, U32>>:
        x : List<&2, U32> <- sig.of(sig.find(ls, n), c, dir, n)
        r : List<&2, U32> <- ctx(c, dir, ls, more)
        return S.append(x, r)

# Units ------------------------------------------------------------------------

def muts(+c: Cf, +dir: String, +udir: String, +u: L.U, ms: List<&2, List<&2, U32>>) -> IO(L.Mu):
  match ms:
    case Nil{}:
      IO.pure(L.Mu, L.Mu{Nil{}, Nil{}})
    case +m <> more:
      do IO<L.Mu>:
        +o : S.Out <- run(c, udir, u, m)
        r : L.Mu <- muts(c, dir, udir, u, more)
        return L.mu.rule(S.Out.status(o), m, check.of(dir, Cf.cap(c), o), r)

type Hole is Data:
  Hole{check: List<&2, U32>, key: String}

def hole.of(+c: Cf, +dir: String, +o: S.Out) -> Hole:
  +e = S.Out.status(o)
  Bool.pick(Hole, U32.is_eq(e, 1), Hole{check.of(dir, Cf.cap(c), o), "hole"}, Hole{Nil{}, "hole_exit_" ++ U32.show(e)})

def hole(none: Bool, +c: Cf, +dir: String, +udir: String, +u: L.U) -> IO(Maybe<&2, Hole>):
  match none:
    case True{}:
      IO.pure(Maybe<&2, Hole>, None{})
    case False{}:
      do IO<Maybe<&2, Hole>>:
        +o : S.Out <- run(c, udir, u, L.U.at(u, 10n))
        return Some{hole.of(c, dir, o)}

def ctx.key(+cx: List<&2, U32>, +ks: List<&2, String>) -> List<&2, String>:
  Bool.pick(List<&2, String>, Nat.is_eq(S.len(cx), 0n), ks, "context" <> ks)

def kept(+u: L.U, +verdict: List<&2, U32>, +cx: List<&2, U32>, h: Maybe<&2, Hole>, r: L.Mu) -> L.Got:
  match h r:
    case None{} L.Mu{cs, ks}:
      L.Kept{L.result(u, verdict <> cx <> Nil{} <> Nil{} <> cs), ctx.key(cx, ks)}
    case Some{Hole{hc, hk}} L.Mu{cs, ks}:
      L.Kept{L.result(u, verdict <> cx <> hc <> Nil{} <> cs), hk <> ctx.key(cx, ks)}

def orig(ok: Bool, +c: Cf, +dir: String, +udir: String, +u: L.U, +o: S.Out) -> IO(L.Got):
  match ok:
    case False{}:
      IO.pure(L.Got, L.Dropped{["original_exit_" ++ U32.show(S.Out.status(o))]})
    case True{}:
      do IO<L.Got>:
        cx0 : List<&2, U32> <- ctx(c, dir, S.split.lines(L.U.at(u, 5n)), L.words(L.U.at(u, 9n)))
        +cx : List<&2, U32> = S.chomp(S.lines.take(cx0, Cf.cap(c)))
        h : Maybe<&2, Hole> <- hole(Nat.is_eq(S.len(L.U.at(u, 10n)), 0n), c, dir, udir, u)
        r : L.Mu <- muts(c, dir, udir, u, L.U.mutants(u))
        S.rm(udir ++ "/Unit.bend")
        return kept(u, check.of(dir, Cf.cap(c), o), cx, h, r)

def placed(+c: Cf, +dir: String, +u: L.U, +rel: List<&2, U32>) -> IO(L.Got):
  +udir = dir ++ "/src/" ++ S.str(L.before.last(rel, [47]))
  do IO<L.Got>:
    +o : S.Out <- run(c, udir, u, L.U.at(u, 7n))
    orig(U32.is_eq(S.Out.status(o), 0), c, dir, udir, u, o)

# the unit's repository's .bend files, copied under the worker's src/ once
def copy(have: Bool, +c: Cf, +dir: String, +repo: String) -> IO(Unit):
  match have:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        S.mkdir(dir ++ "/src")
        o : S.Out <- S.run(Cf.src(c), [], 3600, "find", [repo, "-name", "*.bend", "-not", "-path", "*/node_modules/*",
          "-exec", "cp", "--parents", "{}", dir ++ "/src/", ";"], Nil{})
        return Unit{}

def found(ok: Bool, +c: Cf, +dir: String, +u: L.U, +rel: List<&2, U32>) -> IO(L.Got):
  match ok:
    case False{}:
      IO.pure(L.Got, L.Dropped{["skipped_no_source"]})
    case True{}:
      +repo = S.str(repo.of(rel))
      do IO<L.Got>:
        h : Bool <- S.exists(dir ++ "/src/" ++ repo)
        copy(h, c, dir, repo)
        S.mkdir(dir ++ "/base")
        placed(c, dir, u, rel)

def unit(+c: Cf, +dir: String, +u: L.U) -> IO(L.Got):
  +rel = rel.of(L.U.id(u), L.U.at(u, 2n))
  do IO<L.Got>:
    ok : Bool <- S.exists(Cf.src(c) ++ "/" ++ S.str(rel))
    found(ok, c, dir, u, rel)

def job(+c: Cf, +dir: String, us: List<&2, L.U>) -> IO(List<&2, L.Got>):
  match us:
    case Nil{}:
      IO.pure(List<&2, L.Got>, Nil{})
    case +u <> more:
      do IO<List<&2, L.Got>>:
        g : L.Got <- unit(c, dir, u)
        gs : List<&2, L.Got> <- job(c, dir, more)
        return g <> gs
