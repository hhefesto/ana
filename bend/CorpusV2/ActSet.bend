import Base
import ../Sys.bend as S
import ./Lib.bend as L
import ./Steps.bend as St
import ./Keyed.bend as K

# actset: the prompts ana's own episodes are drawn from (2026-10-15, the plan
# "all logic in Bend", Phase 4: tools/corpus-v2/actset.sh).
#
#   bend-corpus-v2 actset [OUT_DIR]          (OUT_DIR: run/v2/act)
#
# Train units only, each with its direct and its repair prompt as E5 asks
# them (evalset's cut), the languages ordered together so a run stopped
# early still covers them all:
#   - a unit is UNIT/SHAPE less its last `/SHAPE`, and less a `+N` at its end
#     when it holds a `#` (the `+N` after the last `#`); a language's units are
#     its train transcripts' (TRANSCRIPTS/LANG/transcripts.train.nul,
#     TRANSCRIPTS run/v2/transcripts) runs of one unit, and every k-th of them
#     is kept, k = max(1, units / wanted) (UNITS_LEAN 2400, UNITS_HASKELL
#     1800, UNITS_NIX 1200, UNITS_AGDA 600, UNITS_BEND 600), all its
#     presentations together: OUT/src/LANG/transcripts.holdout.nul, the name
#     evalset reads;
#   - evalset (this program, EVALSET_SRC=OUT/src) once direct only, once repair
#     only: OUT/prompts.direct.nul, OUT/prompts.repair.nul, joined as
#     OUT/prompts.sorted.nul;
#   - no held-out unit: OUT/units.txt (the prompts' units) and OUT/heldout.txt
#     (the units of run/v2/evalset/prompts*.nul and the ids of
#     run/v2/results/*.holdout.nul), each sorted bytewise and unique, must
#     not meet, or actset stops;
#   - the prompts in keyed order (keyed-order, salt "corpus-v2 actset"; the
#     script shuffled with `shuf --random-source=<(yes "corpus-v2 actset")`,
#     its prompts with any \001 removed so a pair could be one line; a pair
#     moves whole here): OUT/prompts.shuf.nul;
#   - only units with a train record (agent-eval checks against it; 20 Bend
#     units, own:py2bend/..., have transcripts but no record): OUT/recorded.txt
#     (the ids of run/v2/results/*.train.nul, sorted bytewise, unique), and
#     OUT/prompts.nul the prompts whose unit is one of them.
# Sorts are bytewise (the script's sort used the locale); the logs go to
# stderr, stamped UTC-6.  Run from the repository root.  Every def is
# prefixed `ast.`.

# Units (pure) ------------------------------------------------------------------------------

# the id less its last `/...` (`sub(/\/[^\/]*$/, "")`)
def ast.unslash(+id: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, L.v2.has(id, 47), L.v2.parent(id, 47), id)

def ast.digits.drop(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case c <> +t True{}:
      ast.digits.drop(t, K.kor.hd.isd(t))
    case r _:
      r

# a reversed text less a leading `N+` (the text's trailing `+N`, N digits)
def ast.plus.cut(+r: List<&2, U32>) -> List<&2, U32>:
  +d = ast.digits.drop(r, K.kor.hd.isd(r))
  Bool.pick(List<&2, U32>, Bool.and(K.kor.hd.isd(r), S.head.is(d, 43)), List.drop(&2, U32, d, 1n), r)

# a transcript id's unit: UNIT/SHAPE less its shape, and a `+N` after its last `#`
def ast.unit(+id: List<&2, U32>) -> List<&2, U32>:
  +u = ast.unslash(id)
  Bool.pick(List<&2, U32>, L.v2.has(u, 35), List.reverse(&2, U32, ast.plus.cut(List.reverse(&2, U32, u))), u)

# Settings ----------------------------------------------------------------------------------

def ast.langs() -> List<&2, String>:
  ["haskell", "agda", "lean", "nix", "bend"]

def ast.want.of(+l: String) -> String & Nat:
  Bool.pick(String & Nat, String.eq(l, "lean"), ("UNITS_LEAN", 2400n), Bool.pick(String & Nat, String.eq(l, "haskell"), ("UNITS_HASKELL", 1800n),
    Bool.pick(String & Nat, String.eq(l, "nix"), ("UNITS_NIX", 1200n), Bool.pick(String & Nat, String.eq(l, "agda"), ("UNITS_AGDA", 600n), ("UNITS_BEND", 600n)))))

def ast.want.env(r: String & Nat) -> IO(Nat):
  (v, +d) = r
  S.env.nat(v, d)

def ast.want(+l: String) -> IO(Nat):
  ast.want.env(ast.want.of(l))

def ast.log(+msg: String) -> IO(Unit):
  K.kor.log("actset", msg)

# Pass 1: a language's units --------------------------------------------------------------

type AstCn is Type:
  AstCn{r: St.StRd, last: List<&2, U32>, n: Nat, more: Bool}

def ast.cn.rec(m: Maybe<&2, St.StPair>, r: St.StRd, +last: List<&2, U32>, +n: Nat) -> IO(AstCn):
  match m:
    case None{}:
      IO.pure(AstCn, AstCn{r, last, n, False{}})
    case Some{St.StPair{+id, t}}:
      +u = ast.unit(id)
      IO.pure(AstCn, AstCn{r, u, Bool.pick(Nat, S.eq(u, last), n, 1n+n), True{}})

def ast.cn.got(+last: List<&2, U32>, +n: Nat, x: St.StRd & Maybe<&2, St.StPair>) -> IO(AstCn):
  (r, m) = x
  ast.cn.rec(m, r, last, n)

def ast.cn.step(s: AstCn) -> IO(AstCn):
  match s:
    case AstCn{r, last, n, m}:
      IO.bind(St.StRd & Maybe<&2, St.StPair>, AstCn, St.st.rd.pair(r), ast.cn.got(last, n))

def ast.cn.go(fuel: Nat, s: AstCn) -> IO(Nat):
  match fuel s:
    case 1n+f AstCn{r, last, n, True{}}:
      IO.bind(AstCn, Nat, ast.cn.step(AstCn{r, last, n, True{}}), ast.cn.go(f))
    case _ AstCn{r, last, n, m}:
      do IO<Nat>:
        St.st.rd.close(r)
        return n

# the units of a NUL file: its runs of one unit
def ast.units(+path: String) -> IO(Nat):
  do IO<Nat>:
    r : St.StRd <- St.st.rd.open(path, 0)
    ast.cn.go(K.kor.fuel(), AstCn{r, Nil{}, 0n, True{}})

# Pass 2: every k-th unit ---------------------------------------------------------------------

# the reader, the output, the unit before and its index, the kept unit
# before, the kept units
type AstSl is Type:
  AstSl{r: St.StRd, o: File, last: List<&2, U32>, i: Nat, kl: List<&2, U32>, c: Nat, more: Bool}

def ast.sl.keep(keep: Bool, r: St.StRd, o: File, +u: List<&2, U32>, +i: Nat, +kl: List<&2, U32>, +c: Nat, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(AstSl):
  match keep:
    case True{}:
      do IO<AstSl>:
        o2 : File <- S.emit(o, List.concat(&2, U32, [id, [0], t, [0]]))
        return AstSl{r, o2, u, i, u, Bool.pick(Nat, S.eq(u, kl), c, 1n+c), True{}}
    case False{}:
      IO.pure(AstSl, AstSl{r, o, u, i, kl, c, True{}})

def ast.sl.rec(m: Maybe<&2, St.StPair>, r: St.StRd, o: File, +k: Nat, +last: List<&2, U32>, +i: Nat, +kl: List<&2, U32>, +c: Nat) -> IO(AstSl):
  match m:
    case None{}:
      IO.pure(AstSl, AstSl{r, o, last, i, kl, c, False{}})
    case Some{St.StPair{+id, +t}}:
      +u = ast.unit(id)
      +j = Bool.pick(Nat, S.eq(u, last), i, 1n+i)
      ast.sl.keep(Nat.is_eq(Nat.mod(Nat.sub(j, 1n), k), 0n), r, o, u, j, kl, c, id, t)

def ast.sl.got(o: File, +k: Nat, +last: List<&2, U32>, +i: Nat, +kl: List<&2, U32>, +c: Nat, x: St.StRd & Maybe<&2, St.StPair>) -> IO(AstSl):
  (r, m) = x
  ast.sl.rec(m, r, o, k, last, i, kl, c)

def ast.sl.step(+k: Nat, s: AstSl) -> IO(AstSl):
  match s:
    case AstSl{r, o, last, i, kl, c, m}:
      IO.bind(St.StRd & Maybe<&2, St.StPair>, AstSl, St.st.rd.pair(r), ast.sl.got(o, k, last, i, kl, c))

def ast.sl.go(fuel: Nat, +k: Nat, s: AstSl) -> IO(Nat):
  match fuel s:
    case 1n+f AstSl{r, o, last, i, kl, c, True{}}:
      IO.bind(AstSl, Nat, ast.sl.step(k, AstSl{r, o, last, i, kl, c, True{}}), ast.sl.go(f, k))
    case _ AstSl{r, o, last, i, kl, c, m}:
      do IO<Nat>:
        St.st.rd.close(r)
        File.close(o)
        return c

# every k-th unit of src into dst; the answer is dst's units
def ast.select(+src: String, +dst: String, +k: Nat) -> IO(Nat):
  do IO<Nat>:
    r : St.StRd <- St.st.rd.open(src, 0)
    o : File <- IO.try(File, File.open(dst, "w"))
    ast.sl.go(K.kor.fuel(), k, AstSl{r, o, Nil{}, 0n, Nil{}, 0n, True{}})

def ast.lang(+tx: String, +out: String, +l: String) -> IO(Unit):
  +f = tx ++ "/" ++ l ++ "/transcripts.train.nul"
  do IO<Unit>:
    +n : Nat <- ast.units(f)
    +w : Nat <- ast.want(l)
    +k : Nat = Nat.max(1n, Nat.div(n, Nat.max(w, 1n)))
    S.mkdir(out ++ "/src/" ++ l)
    +c : Nat <- ast.select(f, out ++ "/src/" ++ l ++ "/transcripts.holdout.nul", k)
    ast.log(l ++ ": " ++ Nat.show(n) ++ " train units, every " ++ Nat.show(k) ++ "th: " ++ Nat.show(c) ++ " units")

def ast.langs.go(ls: List<&2, String>, +tx: String, +out: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      do IO<Unit>:
        ast.lang(tx, out, l)
        ast.langs.go(t, tx, out)

# Ids and units as sorted lines ----------------------------------------------------------------
#
# A NUL file's ids (the odd fields), each as is or as its unit, appended as
# lines to a spool; `LC_ALL=C sort -u` makes the list.

type AstId is Type:
  AstId{r: St.StRd, o: File, more: Bool}

def ast.id.line(+unit: Bool, +id: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, Bool.pick(List<&2, U32>, unit, ast.unslash(id), id), [10])

def ast.id.rec(m: Maybe<&2, St.StPair>, r: St.StRd, o: File, +unit: Bool) -> IO(AstId):
  match m:
    case None{}:
      IO.pure(AstId, AstId{r, o, False{}})
    case Some{St.StPair{+id, t}}:
      do IO<AstId>:
        o2 : File <- S.emit(o, ast.id.line(unit, id))
        return AstId{r, o2, True{}}

def ast.id.got(o: File, +unit: Bool, x: St.StRd & Maybe<&2, St.StPair>) -> IO(AstId):
  (r, m) = x
  ast.id.rec(m, r, o, unit)

def ast.id.step(+unit: Bool, s: AstId) -> IO(AstId):
  match s:
    case AstId{r, o, m}:
      IO.bind(St.StRd & Maybe<&2, St.StPair>, AstId, St.st.rd.pair(r), ast.id.got(o, unit))

def ast.id.go(fuel: Nat, +unit: Bool, s: AstId) -> IO(File):
  match fuel s:
    case 1n+f AstId{r, o, True{}}:
      IO.bind(AstId, File, ast.id.step(unit, AstId{r, o, True{}}), ast.id.go(f, unit))
    case _ AstId{r, o, m}:
      do IO<File>:
        St.st.rd.close(r)
        return o

def ast.ids.one(+src: String, +unit: Bool, o: File) -> IO(File):
  do IO<File>:
    r : St.StRd <- St.st.rd.open(src, 0)
    ast.id.go(K.kor.fuel(), unit, AstId{r, o, True{}})

def ast.ids.all(srcs: List<&2, String>, +unit: Bool, o: File) -> IO(File):
  match srcs:
    case Nil{}:
      IO.pure(File, o)
    case +s <> t:
      IO.bind(File, File, ast.ids.one(s, unit, o), ast.ids.all(t, unit))

# the ids (unit: their units) of the files appended to the spool
def ast.ids(srcs: List<&2, String>, +unit: Bool, +spool: String) -> IO(Unit):
  do IO<Unit>:
    o : File <- IO.try(File, File.open(spool, "a"))
    o2 : File <- ast.ids.all(srcs, unit, o)
    File.close(o2)

def ast.sorted.ok(+o: S.Out) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(S.Out.status(o), 0), IO.pure(Unit, Unit{}),
    IO.die(Unit, 1, "actset: sort failed: " ++ S.str(S.lines.take(S.Out.text(o), 5n))))

# `LC_ALL=C sort -u -o DST SPOOL`, the spool removed
def ast.sort.u(+spool: String, +dst: String) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 2000000, "sort", ["-u", "-S", "1G", "-T", K.kor.dir(dst), "-o", dst, spool], Nil{})
    ast.sorted.ok(o)
    S.rm(spool)

# the files NAME* of DIR ending in SUF (a glob's files)
def ast.glob.keep(ns: List<&2, List<&2, U32>>, +dir: String, +pre: String, +suf: String) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +r = ast.glob.keep(t, dir, pre, suf)
      Bool.pick(List<&2, String>, Bool.and(S.prefix(n, S.b(pre)), S.suffix(n, S.b(suf))), (dir ++ "/" ++ S.str(n)) <> r, r)

def ast.glob(+dir: String, +pre: String, +suf: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +o : S.Out <- S.run(".", [], 600, "find", [dir, "-mindepth", "1", "-maxdepth", "1", "-printf", "%P\\0"], Nil{})
    return ast.glob.keep(S.split(S.Out.text(o), 0), dir, pre, suf)

# Sets ------------------------------------------------------------------------------------------
#
# The act set's units are few (about 12,000): a Set of them meets the long
# lists a line at a time (comm -12 of the sorted files, as the script did).

def ast.keys(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = ast.keys(t)
      Bool.pick(List<&2, String>, Nat.is_eq(S.len(l), 0n), r, S.str(l) <> r)

def ast.set(+path: String) -> IO(Set()):
  do IO<Set()>:
    +xs : List<&2, U32> <- S.read(path)
    return Set.from_list(ast.keys(S.split.lines(xs)))

# the lines of a file that are in s, each added to hit (and counted)
type AstMt is Type:
  AstMt{r: S.Rd, +hit: Set(), n: Nat, more: Bool}

def ast.mt.line(m: Maybe<&2, List<&2, U32>>, r: S.Rd, +s: Set(), +hit: Set(), +n: Nat) -> IO(AstMt):
  match m:
    case None{}:
      IO.pure(AstMt, AstMt{r, hit, n, False{}})
    case Some{+l}:
      +k = S.str(l)
      +in = Bool.and(Nat.is_lt(0n, S.len(l)), L.v2.in(s, k))
      IO.pure(AstMt, AstMt{r, Bool.pick(Set(), in, Set.add(hit, k), hit), Bool.pick(Nat, in, 1n+n, n), True{}})

def ast.mt.got(+s: Set(), +hit: Set(), +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(AstMt):
  (r, m) = x
  ast.mt.line(m, r, s, hit, n)

def ast.mt.step(+s: Set(), st: AstMt) -> IO(AstMt):
  match st:
    case AstMt{r, hit, n, m}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, AstMt, S.Rd.next(r), ast.mt.got(s, hit, n))

def ast.mt.go(fuel: Nat, +s: Set(), st: AstMt) -> IO(Set() & Nat):
  match fuel st:
    case 1n+f AstMt{r, hit, n, True{}}:
      IO.bind(AstMt, Set() & Nat, ast.mt.step(s, AstMt{r, hit, n, True{}}), ast.mt.go(f, s))
    case _ AstMt{r, hit, n, m}:
      do IO<Set() & Nat>:
        S.Rd.close(r)
        return (hit, n)

# the lines of PATH in s: as a set, and how many
def ast.meet(+s: Set(), +path: String) -> IO(Set() & Nat):
  do IO<Set() & Nat>:
    r : S.Rd <- S.Rd.lines(path)
    ast.mt.go(K.kor.fuel(), s, AstMt{r, Set.new(), 0n, True{}})

# The prompts kept: a pair whose unit is in s ---------------------------------------------------

type AstKp is Type:
  AstKp{r: St.StRd, o: File, kept: Nat, units: Set(), u: Nat, more: Bool}

def ast.kp.keep(keep: Bool, r: St.StRd, o: File, +kept: Nat, +us: Set(), +u: Nat, +k: String, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(AstKp):
  match keep:
    case True{}:
      do IO<AstKp>:
        o2 : File <- S.emit(o, List.concat(&2, U32, [id, [0], t, [0]]))
        +seen : Bool = L.v2.in(us, k)
        return AstKp{r, o2, 1n+kept, Bool.pick(Set(), seen, us, Set.add(us, k)), Bool.pick(Nat, seen, u, 1n+u), True{}}
    case False{}:
      IO.pure(AstKp, AstKp{r, o, kept, us, u, True{}})

def ast.kp.rec(m: Maybe<&2, St.StPair>, r: St.StRd, o: File, +s: Set(), +kept: Nat, +us: Set(), +u: Nat) -> IO(AstKp):
  match m:
    case None{}:
      IO.pure(AstKp, AstKp{r, o, kept, us, u, False{}})
    case Some{St.StPair{+id, +t}}:
      +k = S.str(ast.unslash(id))
      ast.kp.keep(L.v2.in(s, k), r, o, kept, us, u, k, id, t)

def ast.kp.got(o: File, +s: Set(), +kept: Nat, +us: Set(), +u: Nat, x: St.StRd & Maybe<&2, St.StPair>) -> IO(AstKp):
  (r, m) = x
  ast.kp.rec(m, r, o, s, kept, us, u)

def ast.kp.step(+s: Set(), st: AstKp) -> IO(AstKp):
  match st:
    case AstKp{r, o, kept, us, u, m}:
      IO.bind(St.StRd & Maybe<&2, St.StPair>, AstKp, St.st.rd.pair(r), ast.kp.got(o, s, kept, us, u))

def ast.kp.go(fuel: Nat, +s: Set(), st: AstKp) -> IO(Nat & Nat):
  match fuel st:
    case 1n+f AstKp{r, o, kept, us, u, True{}}:
      IO.bind(AstKp, Nat & Nat, ast.kp.step(s, AstKp{r, o, kept, us, u, True{}}), ast.kp.go(f, s))
    case _ AstKp{r, o, kept, us, u, m}:
      do IO<Nat & Nat>:
        St.st.rd.close(r)
        File.close(o)
        return (kept, u)

# src's pairs whose unit is in s into dst: (prompts kept, their units)
def ast.keep(+s: Set(), +src: String, +dst: String) -> IO(Nat & Nat):
  do IO<Nat & Nat>:
    r : St.StRd <- St.st.rd.open(src, 0)
    o : File <- IO.try(File, File.open(dst, "w"))
    ast.kp.go(K.kor.fuel(), s, AstKp{r, o, 0n, Set.new(), 0n, True{}})

# Main ------------------------------------------------------------------------------------------

def ast.evalset(+self: String, +out: String, +f: String, +nd: String, +nr: String) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run(".", ["EVALSET_SRC=" ++ out ++ "/src"], 2000000, self, ["evalset", "--out", f, nd, nr], Nil{})
    K.kor.show(S.Out.text(o))
    Bool.pick(IO(Unit), U32.is_eq(S.Out.status(o), 0), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "actset: evalset --out " ++ f ++ " failed"))

def ast.refuse(+bad: Nat) -> IO(Unit):
  Bool.pick(IO(Unit), Nat.is_eq(bad, 0n), IO.pure(Unit, Unit{}), K.kor.die("actset", Nat.show(bad) ++ " units of the act set are held out: refusing"))

def ast.fst(p: Set() & Nat) -> Set():
  (s, n) = p
  s

def ast.snd(p: Set() & Nat) -> Nat:
  (s, n) = p
  n

def ast.said(r: Nat & Nat, +all: Nat, +out: String) -> IO(Unit):
  (+kept, +u) = r
  do IO<Unit>:
    ast.log(Nat.show(Nat.sub(all, kept)) ++ " prompts dropped: their unit has no train record")
    ast.log(Nat.show(kept) ++ " prompts of " ++ Nat.show(u) ++ " units in " ++ out ++ "/prompts.nul, none held out")

def ast.run(+out: String) -> IO(Unit):
  do IO<Unit>:
    +tx : String <- S.env("TRANSCRIPTS", "run/v2/transcripts")
    +self : String <- K.kor.self()
    S.mkdir(out ++ "/src")
    ast.langs.go(ast.langs(), tx, out)
    # evalset gives a unit one prompt (direct first, repair from the units not asked yet):
    # once direct only, once repair only, so a unit gives both
    ast.evalset(self, out, out ++ "/prompts.direct.nul", "100000", "0")
    ast.evalset(self, out, out ++ "/prompts.repair.nul", "0", "100000")
    K.kor.cat([out ++ "/prompts.direct.nul", out ++ "/prompts.repair.nul"], out ++ "/prompts.sorted.nul")
    # no held-out unit among them
    S.write(out ++ "/units.spool", Nil{})
    ast.ids([out ++ "/prompts.sorted.nul"], True{}, out ++ "/units.spool")
    ast.sort.u(out ++ "/units.spool", out ++ "/units.txt")
    S.write(out ++ "/heldout.spool", Nil{})
    +ev : List<&2, String> <- ast.glob("run/v2/evalset", "prompts", ".nul")
    ast.ids(ev, True{}, out ++ "/heldout.spool")
    +ho : List<&2, String> <- ast.glob("run/v2/results", "", ".holdout.nul")
    ast.ids(ho, False{}, out ++ "/heldout.spool")
    ast.sort.u(out ++ "/heldout.spool", out ++ "/heldout.txt")
    +units : Set() <- ast.set(out ++ "/units.txt")
    bad : Set() & Nat <- ast.meet(units, out ++ "/heldout.txt")
    ast.refuse(ast.snd(bad))
    # the languages ordered together: each prompt pair in keyed order
    r : Nat & Nat <- K.kor.order(False{}, "corpus-v2 actset", K.kor.fuel(), out ++ "/prompts.sorted.nul", out ++ "/prompts.shuf.nul")
    # only units with a train record (agent-eval checks against it)
    S.write(out ++ "/recorded.spool", Nil{})
    +tr : List<&2, String> <- ast.glob("run/v2/results", "", ".train.nul")
    ast.ids(tr, False{}, out ++ "/recorded.spool")
    ast.sort.u(out ++ "/recorded.spool", out ++ "/recorded.txt")
    rec : Set() & Nat <- ast.meet(units, out ++ "/recorded.txt")
    +all : Nat <- K.kor.pairs(out ++ "/prompts.shuf.nul")
    k : Nat & Nat <- ast.keep(ast.fst(rec), out ++ "/prompts.shuf.nul", out ++ "/prompts.nul")
    ast.said(k, all, out)

def ast.main(xs: List<String>) -> IO(Unit):
  match xs:
    case Nil{}:
      ast.run("run/v2/act")
    case +out <> Nil{}:
      ast.run(out)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 actset [OUT_DIR]")

