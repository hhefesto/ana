import Base
import ./Sys.bend as S
import ./Check/Agda.bend as Ag
import ./Check/Haskell.bend as Hs

# The look-ups ana's mugen-shape sessions call on the other languages
# (docs/MUGEN-SHAPE.md, "The other languages"), as real commands on a file,
# run from the directory a session's paths start at:
#
#   ana-type PATH NAME...   the type of each name, in the file's scope; a name
#                           the checker cannot type is left out
#       .hs     GHCi's `:type`        `name :: type`
#       .agda   Cmd_infer_toplevel    `name : type`
#       .lean   `#check`, after the file (so its own errors do not show)
#   ana-goal PATH           an Agda file's first hole: Cmd_goal_type_context's
#                           display; no hole: the load's first message
#
# bend-check's checkers answered these when the corpus was rendered, so the
# answers read as the sessions' echoes do, though a session's were asked from
# its unit's head and these from the whole file.  Exit 0: an answer; 1: none.

type Lk is Data:
  Lk{text: List<&2, U32>, ok: Bool}

def lk.of(+t: List<&2, U32>) -> Lk:
  Lk{t, Bool.not(Nat.is_eq(S.len(t), 0n))}

def lk.has(+path: List<&2, U32>, +ext: String) -> Bool:
  S.suffix(path, S.b(ext))

# GHCi -------------------------------------------------------------------------

# `:type <$>` does not parse, `:type (<$>)` does
def lk.hs.word(+c: U32) -> Bool:
  Bool.or(U32.is_lt(126, c), Bool.or(Bool.and(U32.is_lt(96, c), U32.is_lt(c, 123)), Bool.or(Bool.and(U32.is_lt(64, c), U32.is_lt(c, 91)),
    Bool.or(Bool.and(U32.is_lt(47, c), U32.is_lt(c, 58)), Bool.or(U32.is_eq(c, 95), U32.is_eq(c, 40))))))

def lk.hs.name.at(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      lk.hs.word(h)

def lk.hs.name(+n: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, lk.hs.name.at(n), n, S.append([40], S.append(n, [41])))

def lk.hs.names(ns: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      lk.hs.name(n) <> lk.hs.names(t)

def lk.hs(+path: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> IO(Lk):
  do IO<Lk>:
    +o : S.Out <- S.run(".", [], 120, "ghci", ["-v0", "-ignore-dot-ghci", "-w", S.str(path)], S.b(Hs.types(lk.hs.names(ns))))
    return lk.of(Hs.context(".", 200n, S.Out.text(o)))

# Agda -------------------------------------------------------------------------

def lk.agda.run(+file: String, +cmds: List<&2, U32>) -> IO(S.Out):
  S.run(".", [], 300, "agda", ["--interaction"], S.append(Ag.cmd(file, "Cmd_load \"" ++ file ++ "\" []"), S.append(cmds, [10])))

def lk.agda(+path: List<&2, U32>, +ns: List<&2, List<&2, U32>>) -> IO(Lk):
  +file = S.str(path)
  do IO<Lk>:
    +o : S.Out <- lk.agda.run(file, Ag.infers(file, ns))
    return lk.of(Ag.ctx.go(Ag.segs(S.Out.text(o)), ns, 2n))

def lk.goal.of(+ss: List<&2, List<&2, U32>>) -> Lk:
  +g = S.chomp(Ag.msg.titled(Ag.seg(ss, 2n), "*Goal type etc.*"))
  Bool.pick(Lk, Nat.is_eq(S.len(g), 0n), Lk{S.chomp(Ag.msg(Ag.seg(ss, 1n))), False{}}, Lk{g, True{}})

def lk.goal(+path: List<&2, U32>) -> IO(Lk):
  +file = S.str(path)
  do IO<Lk>:
    +o : S.Out <- lk.agda.run(file, Ag.cmd(file, "Cmd_goal_type_context Simplified 0 noRange \"\""))
    return lk.goal.of(Ag.segs(S.Out.text(o)))

# Lean -------------------------------------------------------------------------

def lk.lean.mark() -> List<&2, U32>:
  S.b("ANA-LOOK")

def lk.lean.keep(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = lk.lean.keep(t)
      Bool.pick(List<&2, List<&2, U32>>, S.prefix(l, S.b("<stdin>:")), r, l <> r)

def lk.lean.after(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> +t:
      Bool.pick(List<&2, List<&2, U32>>, S.eq(l, lk.lean.mark()), lk.lean.keep(t), lk.lean.after(t))

def lk.lean.checks(ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      S.append(S.b("#check "), S.append(n, 10 <> lk.lean.checks(t)))

def lk.lean.got(m: Maybe<&2, List<&2, U32>>, +path: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> IO(Lk):
  match m:
    case Some{+f}:
      do IO<Lk>:
        +o : S.Out <- S.run(".", [], 300, "lake", ["env", "lean", "--stdin"], S.append(f, S.append(S.b("\n#print \"ANA-LOOK\"\n"), lk.lean.checks(ns))))
        return lk.of(S.chomp(S.join(lk.lean.after(S.split.lines(S.Out.text(o))), 10)))
    case None{}:
      IO.pure(Lk, Lk{S.b("ana-type: cannot read " ++ S.str(path)), False{}})

def lk.lean(+path: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> IO(Lk):
  do IO<Lk>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(S.str(path))
    lk.lean.got(m, path, ns)

# The commands -----------------------------------------------------------------

def lk.type.lean(l: Bool, +path: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> IO(Lk):
  match l:
    case True{}:
      lk.lean(path, ns)
    case False{}:
      IO.pure(Lk, Lk{S.b("ana-type: not a .hs, .agda or .lean file: " ++ S.str(path)), False{}})

def lk.type.agda(a: Bool, +path: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> IO(Lk):
  match a:
    case True{}:
      lk.agda(path, ns)
    case False{}:
      lk.type.lean(lk.has(path, ".lean"), path, ns)

def lk.type.hs(h: Bool, +path: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> IO(Lk):
  match h:
    case True{}:
      lk.hs(path, ns)
    case False{}:
      lk.type.agda(lk.has(path, ".agda"), path, ns)

def lk.type(+path: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> IO(Lk):
  lk.type.hs(lk.has(path, ".hs"), path, ns)

def lk.bytes(xs: List<String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.b(x) <> lk.bytes(t)

def lk.end(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "")

def lk.say.got(r: Lk) -> IO(Unit):
  match r:
    case Lk{+t, ok}:
      do IO<Unit>:
        IO.print(S.str(t))
        lk.end(ok)

def lk.say(l: IO(Lk)) -> IO(Unit):
  do IO<Unit>:
    r : Lk <- l
    lk.say.got(r)

def lk.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: ana-look type PATH NAME... | ana-look goal PATH")

def lk.go(+cmd: List<&2, U32>, rest: List<String>) -> IO(Unit):
  match rest:
    case Nil{}:
      lk.usage()
    case p <> ns:
      +path = S.b(p)
      Bool.pick(IO(Unit), S.eq(cmd, S.b("type")), lk.say(lk.type(path, lk.bytes(ns))),
        Bool.pick(IO(Unit), S.eq(cmd, S.b("goal")), lk.say(lk.goal(path)), lk.usage()))

def lk.args(xs: List<String>) -> IO(Unit):
  match xs:
    case Nil{}:
      lk.usage()
    case c <> rest:
      lk.go(S.b(c), rest)

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    lk.args(List.tail(&1, String, argv))
