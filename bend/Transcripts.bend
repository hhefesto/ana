import Base
import ./Sys.bend as S
import ./Json.bend as J
import ./Clock.bend as Ck
import ./Check/Lib.bend as L

# bend-transcripts: the transcript corpus, one language at a time, from the
# code corpus to rendered transcripts (docs/TRANSCRIPT-FORMAT.md).
#
#   bend-transcripts STAGE LANG
#
#   STAGE  sources   the language's files from $CORPUS, as NUL-framed
#                    (id, text) pairs, split into two streams by how many
#                    units a file may give (MAX_HI for the sources the corpus
#                    wants more of, MAX otherwise)
#          units     bend-units over chunks of CHUNK files, UNIT_JOBS at once
#          check     bend-check LANG with CHECK_JOBS workers
#          clean     bend-clean: exact and near duplicates and units
#                    contaminated by EVAL dropped, the rest split into
#                    train and holdout (HOLDOUT_PCT of units by id hash)
#          render    bend-transcript with the code32k tokenizer, train and
#                    holdout apart
#          all       the five in order
#   LANG   haskell | agda | lean | nix | bend
#
# Run it from the repository root.  Everything lands in $OUT/LANG/ (default
# run/transcripts): files-{hi,lo}.nul, units.nul, results.nul (+ .stats;
# a restart puts a stopped run's results.prev.nul in front),
# results.{train,holdout}.nul (+ train's .stats), transcripts.{train,holdout}.nul,
# and log, whose lines are stamped in Mexico City time
# (UTC-6).  A stage whose output exists is skipped, so a killed run resumes
# at the stage it died in.
#
# Environment: CORPUS (default run/code-train-v3.jsonl, else v2), OUT,
# MAX (4), MAX_HI (8), CHUNK (300), UNIT_JOBS (8), CHECK_JOBS (lean 5,
# agda 8, else the core count), WINDOW (2048), TOKENIZER
# (weights/code32k.bpe), HACKAGE_PCT (30), EVAL (run/code-eval-v2.jsonl),
# HOLDOUT_PCT (2), and the tools BEND_UNITS, BEND_CHECK, BEND_CLEAN,
# BEND_TRANSCRIPT (default: bend-units, bend-check, bend-clean,
# bend-transcript on PATH); for LANG bend, BEND (bend) and BEND_SRC
# (run/code-sources/own) reach bend-check.
#
# CORPUS is JSON lines, `{"id": ..., "text": ...}` in that order, as
# bend-extract writes them.  A document whose id or text holds a NUL
# cannot be NUL-framed: it is left out and counted (the jq this replaces
# wrote its id alone and shifted every pair after it; the corpus has none).

# Languages ------------------------------------------------------------------

# haskell 1, agda 2, lean 3, nix 4, bend 5 (0: none)
def lang.code(+l: String) -> Nat:
  Bool.pick(Nat, String.eq(l, "haskell"), 1n, Bool.pick(Nat, String.eq(l, "agda"), 2n, Bool.pick(Nat, String.eq(l, "lean"), 3n,
    Bool.pick(Nat, String.eq(l, "nix"), 4n, Bool.pick(Nat, String.eq(l, "bend"), 5n, 0n)))))

# sources 1, units 2, check 3, render 4, all 5, clean 6 (0: none)
def stage.code(+s: String) -> Nat:
  Bool.pick(Nat, String.eq(s, "sources"), 1n, Bool.pick(Nat, String.eq(s, "units"), 2n, Bool.pick(Nat, String.eq(s, "check"), 3n,
    Bool.pick(Nat, String.eq(s, "render"), 4n, Bool.pick(Nat, String.eq(s, "all"), 5n, Bool.pick(Nat, String.eq(s, "clean"), 6n, 0n))))))

def ends(+id: List<&2, U32>, s: String) -> Bool:
  S.suffix(id, S.b(s))

def starts(+id: List<&2, U32>, s: String) -> Bool:
  S.prefix(id, S.b(s))

# mathlib's own libraries only: the oleans the harness has are mathlib's
# (its batteries is a different version from repo:batteries, held out
# anyway), and lean4's sources are the compiler's own prelude
def lean.from(+id: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(starts(id, "repo:mathlib4/Mathlib/"), starts(id, "repo:mathlib4/Archive/")),
    Bool.or(starts(id, "repo:mathlib4/Counterexamples/"), Bool.or(starts(id, "own:"), starts(id, "curated:"))))

# the files of each language, by id
def files(lang: Nat, +id: List<&2, U32>) -> Bool:
  match lang:
    case 1n:
      ends(id, ".hs")
    case 2n:
      Bool.or(Bool.or(ends(id, ".agda"), ends(id, ".lagda")), Bool.or(ends(id, ".lagda.md"), ends(id, ".lagda.tex")))
    case 3n:
      Bool.and(lean.from(id), ends(id, ".lean"))
    case 4n:
      ends(id, ".nix")
    case 5n:
      ends(id, ".bend")
    case _:
      False{}

# the regular expressions the ids were once matched by, for the log
def files.said(lang: Nat) -> String:
  match lang:
    case 1n:
      "\\.hs$"
    case 2n:
      "\\.(agda|lagda|lagda\\.md|lagda\\.tex)$"
    case 3n:
      "^(repo:mathlib4/(Mathlib|Archive|Counterexamples)/|own:|curated:).*\\.lean$"
    case 4n:
      "\\.nix$"
    case 5n:
      "\\.bend$"
    case _:
      ""

# files left out: Agda's own test suite beyond test/Succeed (most of it
# fails on purpose), its benchmarks, notes and primitives; HoTT-Agda's old/
# tree (Agda 2.4 era); Agda files inside Hackage packages (no library to
# check them in)
def excluded(lang: Nat, +id: List<&2, U32>) -> Bool:
  match lang:
    case 2n:
      Bool.or(Bool.or(Bool.and(starts(id, "repo:agda/test/"), Bool.not(starts(id, "repo:agda/test/Succeed/"))),
          Bool.or(starts(id, "repo:agda/benchmark/"), starts(id, "repo:agda/notes/"))),
        Bool.or(Bool.or(starts(id, "repo:agda/src/"), starts(id, "repo:agda/doc/")),
          Bool.or(starts(id, "repo:HoTT-Agda/old/"), starts(id, "hackage:"))))
    case _:
      Nat.is_eq(S.len(id), 0n)

# the sources the corpus wants more of: category theory, the user's own
# code, the curated repositories (Conal Elliott's), PLFA
def hi(+id: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(Bool.or(S.infix(id, S.b("Categor")), S.infix(id, S.b("categor"))),
      Bool.or(starts(id, "own:"), Bool.and(starts(id, "curated:"), Bool.not(starts(id, "curated:ghc-9"))))),
    Bool.or(Bool.or(Bool.or(starts(id, "repo:plfa/"), starts(id, "repo:agda-unimath/")), Bool.or(starts(id, "repo:HoTT-Agda/"), starts(id, "repo:formal-ledger-specifications/"))),
      Bool.or(starts(id, "repo:plutus/plutus-metatheory/"), starts(id, "repo:ouroboros-consensus/docs/agda-spec/"))))

# the bytes before the first c (all of them when there is none)
def before(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), Nil{}, h <> before(t, c))

# (7; h * 31 + c mod 1000003) over the code points
def hash.go(s: String, +h: U32) -> U32:
  match s:
    case SNil{}:
      h
    case SCon{Chr{c}, t}:
      hash.go(t, U32.mod(U32.add(U32.mul(h, 31), c), 1000003))

# Hackage packages taken (Haskell): a fixed HACKAGE_PCT percent of them,
# whole, by a hash of the package name (`hackage:NAME`, the id before its
# first slash); every other source is taken whole
def hackage.ok(+pct: U32, +id: List<&2, U32>) -> Bool:
  Bool.or(Bool.not(starts(id, "hackage:")), U32.is_lt(U32.mod(hash.go(S.str(before(id, 47)), 7), 100), pct))

# 0: left out, 1: hi, 2: lo
def select(+lang: Nat, +pct: U32, +id: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.and(Bool.and(files(lang, id), Bool.not(excluded(lang, id))), hackage.ok(pct, id)),
    Bool.pick(Nat, hi(id), 1n, 2n), 0n)

# Log -------------------------------------------------------------------------

# a stamped line on stderr and at the end of the language's log
def say(+dir: String, +msg: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- IO.time()
    +line : String = Ck.stamp(t) ++ " " ++ msg
    S.add(dir ++ "/log", S.b(line ++ "\n"))
    IO.print_err(line)

# Stage sources: one pass over the corpus -----------------------------------

type Cl is Data:
  Skip{}
  Take{hi: Bool, id: List<&2, U32>, text: List<&2, U32>}
  Nul{}
  Bad{}

def has.nul(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(U32.is_eq(h, 0), has.nul(t))

def cl.text(+up: Bool, +id: List<&2, U32>, p: J.Pr) -> Cl:
  match p:
    case J.Pok{+k, +t, +r}:
      Bool.pick(Cl, Bool.and(S.eq(k, S.b("text")), S.head.is(J.ws.drop(r, J.ws.head(r)), 125)),
        Bool.pick(Cl, Bool.or(has.nul(id), has.nul(t)), Nul{}, Take{up, id, t}), Bad{})
    case J.Pbad{}:
      Bad{}

def cl.comma(+rest: List<&2, U32>) -> J.Pr:
  +r = J.ws.drop(rest, J.ws.head(rest))
  Bool.pick(J.Pr, S.head.is(r, 44), J.pair(List.drop(&2, U32, r, 1n)), J.Pbad{})

def cl.sel(sel: Nat, +id: List<&2, U32>, +rest: List<&2, U32>) -> Cl:
  match sel:
    case 0n:
      Skip{}
    case 1n+s:
      cl.text(Nat.is_eq(s, 0n), id, cl.comma(rest))

def cl.first(+lang: Nat, +pct: U32, p: J.Pr) -> Cl:
  match p:
    case J.Pok{+k, +v, +r}:
      Bool.pick(Cl, S.eq(k, S.b("id")), cl.sel(select(lang, pct, v), v, r), Bad{})
    case J.Pbad{}:
      Bad{}

def pair.bytes(id: List<&2, U32>, t: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, id, 0 <> List.append(&2, U32, t, [0]))

type Sc is Type:
  Sc{rd: S.Rd, hi: File, lo: File, nhi: Nat, nlo: Nat, nul: Nat, line: Nat, go: Bool}

type Sr is Data:
  Sr{nhi: Nat, nlo: Nat, nul: Nat}

def sc.put(+corpus: String, rd: S.Rd, hi: File, lo: File, +a: Nat, +b: Nat, +n: Nat, +l: Nat, c: Cl) -> IO(Sc):
  match c:
    case Skip{}:
      IO.pure(Sc, Sc{rd, hi, lo, a, b, n, 1n+l, True{}})
    case Nul{}:
      IO.pure(Sc, Sc{rd, hi, lo, a, b, 1n+n, 1n+l, True{}})
    case Take{True{}, id, t}:
      do IO<Sc>:
        h2 : File <- S.emit(hi, pair.bytes(id, t))
        return Sc{rd, h2, lo, 1n+a, b, n, 1n+l, True{}}
    case Take{False{}, id, t}:
      do IO<Sc>:
        l2 : File <- S.emit(lo, pair.bytes(id, t))
        return Sc{rd, hi, l2, a, 1n+b, n, 1n+l, True{}}
    case Bad{}:
      do IO<Sc>:
        S.Rd.close(rd)
        File.close(hi)
        File.close(lo)
        IO.die(Sc, 1, "bend-transcripts: line " ++ Nat.show(1n+l) ++ " of " ++ corpus ++ " is not an {\"id\", \"text\"} object")

def sc.got(+lang: Nat, +pct: U32, +corpus: String, rd: S.Rd, hi: File, lo: File, +a: Nat, +b: Nat, +n: Nat, +l: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Sc):
  match m:
    case None{}:
      IO.pure(Sc, Sc{rd, hi, lo, a, b, n, l, False{}})
    case Some{+x}:
      sc.put(corpus, rd, hi, lo, a, b, n, l, cl.first(lang, pct, J.first.at(x)))

def sc.pair(+lang: Nat, +pct: U32, +corpus: String, hi: File, lo: File, +a: Nat, +b: Nat, +n: Nat, +l: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Sc):
  (rd, m) = r
  sc.got(lang, pct, corpus, rd, hi, lo, a, b, n, l, m)

def sc.step(+lang: Nat, +pct: U32, +corpus: String, s: Sc) -> IO(Sc):
  match s:
    case Sc{rd, hi, lo, +a, +b, +n, +l, g}:
      do IO<Sc>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        sc.pair(lang, pct, corpus, hi, lo, a, b, n, l, r)

def sc.go(fuel: Nat, +lang: Nat, +pct: U32, +corpus: String, s: Sc) -> IO(Sr):
  match fuel s:
    case 1n+p Sc{rd, hi, lo, a, b, n, l, True{}}:
      IO.bind(Sc, Sr, sc.step(lang, pct, corpus, Sc{rd, hi, lo, a, b, n, l, True{}}), sc.go(p, lang, pct, corpus))
    case _ Sc{rd, hi, lo, a, b, n, l, g}:
      do IO<Sr>:
        S.Rd.close(rd)
        File.close(hi)
        File.close(lo)
        return Sr{a, b, n}

def big() -> Nat:
  1000000000n

def sources.nul(+dir: String, n: Nat) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+k:
      say(dir, "sources: " ++ Nat.show(n) ++ " files left out: a NUL in the id or the text")

def sources.said(+dir: String, +max: Nat, +maxhi: Nat, r: Sr) -> IO(Unit):
  match r:
    case Sr{+a, +b, +n}:
      do IO<Unit>:
        say(dir, "sources: " ++ Nat.show(a) ++ " files at " ++ Nat.show(maxhi) ++ " units, " ++ Nat.show(b) ++ " at " ++ Nat.show(max))
        sources.nul(dir, n)

def sources.run(+lang: Nat, +dir: String, +corpus: String, +max: Nat, +maxhi: Nat, +pct: U32) -> IO(Unit):
  do IO<Unit>:
    say(dir, "sources: " ++ corpus ++ ", ids matching " ++ files.said(lang))
    rd : S.Rd <- S.Rd.lines(corpus)
    hi : File <- IO.try(File, File.open(dir ++ "/files-hi.nul.tmp", "w"))
    lo : File <- IO.try(File, File.open(dir ++ "/files-lo.nul.tmp", "w"))
    r : Sr <- sc.go(big(), lang, pct, corpus, Sc{rd, hi, lo, 0n, 0n, 0n, 0n, True{}})
    S.mv(dir ++ "/files-hi.nul.tmp", dir ++ "/files-hi.nul")
    S.mv(dir ++ "/files-lo.nul.tmp", dir ++ "/files-lo.nul")
    sources.said(dir, max, maxhi, r)

def sources.if(done: Bool, +lang: Nat, +dir: String, +corpus: String, +max: Nat, +maxhi: Nat, +pct: U32) -> IO(Unit):
  match done:
    case True{}:
      say(dir, "sources: done already")
    case False{}:
      sources.run(lang, dir, corpus, max, maxhi, pct)

def sources(+lang: Nat, +dir: String, +corpus: String, +max: Nat, +maxhi: Nat, +pct: U32) -> IO(Unit):
  do IO<Unit>:
    +a : Nat <- S.size(dir ++ "/files-lo.nul")
    +b : Nat <- S.size(dir ++ "/files-hi.nul")
    sources.if(Nat.is_lt(0n, Nat.add(a, b)), lang, dir, corpus, max, maxhi, pct)

# Stage units: chunks of CHUNK files, bend-units over each -------------------

def pad4(+k: Nat) -> String:
  +s = Nat.show(k)
  Bool.pick(String, Nat.is_lt(k, 10n), "000" ++ s, Bool.pick(String, Nat.is_lt(k, 100n), "00" ++ s, Bool.pick(String, Nat.is_lt(k, 1000n), "0" ++ s, s)))

# fields, each followed by its NUL
def nul.all(fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match fs:
    case Nil{}:
      Nil{}
    case f <> more:
      List.append(&2, U32, f, 0 <> nul.all(more))

# A split in progress: the chunk being filled (its fields, newest first, and
# how many), its number, and the chunk files written so far (newest first).
type Sp is Type:
  Sp{rd: S.Rd, k: Nat, i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>, go: Bool}

def sp.flush(+pre: String, +k: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>) -> IO(List<&2, String>):
  +path = pre ++ "." ++ pad4(k)
  do IO<List<&2, String>>:
    S.write(path, nul.all(List.reverse(&2, List<&2, U32>, acc)))
    return path <> paths

def sp.put(full: Bool, +pre: String, rd: S.Rd, +k: Nat, +i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>) -> IO(Sp):
  match full:
    case True{}:
      do IO<Sp>:
        ps : List<&2, String> <- sp.flush(pre, k, acc, paths)
        return Sp{rd, 1n+k, 0n, Nil{}, ps, True{}}
    case False{}:
      IO.pure(Sp, Sp{rd, k, i, acc, paths, True{}})

def sp.end(+pre: String, rd: S.Rd, +k: Nat, i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>) -> IO(Sp):
  match i:
    case 0n:
      IO.pure(Sp, Sp{rd, k, 0n, Nil{}, paths, False{}})
    case 1n+j:
      do IO<Sp>:
        ps : List<&2, String> <- sp.flush(pre, k, acc, paths)
        return Sp{rd, 1n+k, 0n, Nil{}, ps, False{}}

def sp.got(+n: Nat, +pre: String, rd: S.Rd, +k: Nat, +i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>, m: Maybe<&2, List<&2, U32>>) -> IO(Sp):
  match m:
    case None{}:
      sp.end(pre, rd, k, i, acc, paths)
    case Some{f}:
      sp.put(Nat.is_eq(1n+i, Nat.mul(2n, n)), pre, rd, k, 1n+i, f <> acc, paths)

def sp.pair(+n: Nat, +pre: String, +k: Nat, +i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Sp):
  (rd, m) = r
  sp.got(n, pre, rd, k, i, acc, paths, m)

def sp.step(+n: Nat, +pre: String, s: Sp) -> IO(Sp):
  match s:
    case Sp{rd, +k, +i, acc, paths, g}:
      do IO<Sp>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        sp.pair(n, pre, k, i, acc, paths, r)

def sp.go(fuel: Nat, +n: Nat, +pre: String, s: Sp) -> IO(List<&2, String>):
  match fuel s:
    case 1n+p Sp{rd, k, i, acc, paths, True{}}:
      IO.bind(Sp, List<&2, String>, sp.step(n, pre, Sp{rd, k, i, acc, paths, True{}}), sp.go(p, n, pre))
    case _ Sp{rd, k, i, acc, paths, g}:
      do IO<List<&2, String>>:
        S.Rd.close(rd)
        return List.reverse(&2, String, paths)

# the NUL-framed pairs of path in files of n pairs: pre.0000, pre.0001, ...
def split.pairs(+path: String, +n: Nat, +pre: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    rd : S.Rd <- S.Rd.open(path)
    sp.go(big(), n, pre, Sp{rd, 0n, 0n, Nil{}, Nil{}, True{}})

# a chunk to run bend-units on, with its MAX
type Uj is Type:
  Uj{path: String, max: Nat}

# a chunk run: its path, exit status and output
type Ur is Data:
  Ur{path: String, status: U32, out: List<&2, U32>}

type Uw is Type:
  Uw{go: Bool, rs: List<&2, Ur>}

def uw.ran(+p: String, o: S.Out, rs: List<&2, Ur>) -> IO(Uw):
  match o:
    case S.Out{+st, +t}:
      do IO<Uw>:
        S.write(p ++ ".log", t)
        return Uw{True{}, Ur{p, st, t} <> rs}

def uw.got(+bu: String, +lang: String, m: Maybe<&1, Uj>, rs: List<&2, Ur>) -> IO(Uw):
  match m:
    case None{}:
      IO.pure(Uw, Uw{False{}, rs})
    case Some{Uj{+p, +mx}}:
      do IO<Uw>:
        o : S.Out <- S.run(".", [], 86400, bu, [lang, p, p ++ ".units", Nat.show(mx)], Nil{})
        uw.ran(p, o, rs)

def uw.step(+bu: String, +lang: String, +q: Chan(Uj), w: Uw) -> IO(Uw):
  match w:
    case Uw{g, rs}:
      do IO<Uw>:
        m : Maybe<&1, Uj> <- Chan.recv(Uj, q)
        uw.got(bu, lang, m, rs)

def uw.go(fuel: Nat, +bu: String, +lang: String, +q: Chan(Uj), w: Uw) -> IO(List<&2, Ur>):
  match fuel w:
    case 1n+p Uw{True{}, rs}:
      IO.bind(Uw, List<&2, Ur>, uw.step(bu, lang, q, Uw{True{}, rs}), uw.go(p, bu, lang, q))
    case _ Uw{g, rs}:
      IO.pure(List<&2, Ur>, rs)

def uw.fork(n: Nat, +bu: String, +lang: String, +q: Chan(Uj)) -> IO(List<Chan(List<&2, Ur>)>):
  match n:
    case 0n:
      IO.pure(List<Chan(List<&2, Ur>)>, Nil{})
    case 1n+m:
      do IO<List<Chan(List<&2, Ur>)>>:
        ch : Chan(List<&2, Ur>) <- IO.fork(List<&2, Ur>, uw.go(big(), bu, lang, q, Uw{True{}, Nil{}}))
        rest : List<Chan(List<&2, Ur>)> <- uw.fork(m, bu, lang, q)
        return ch <> rest

def uw.join(chs: List<Chan(List<&2, Ur>)>, rs: List<&2, Ur>) -> IO(List<&2, Ur>):
  match chs:
    case Nil{}:
      IO.pure(List<&2, Ur>, rs)
    case +ch <> more:
      do IO<List<&2, Ur>>:
        got : List<&2, Ur> <- IO.join(List<&2, Ur>, ch)
        uw.join(more, List.append(&2, Ur, got, rs))

def uj.send(+q: Chan(Uj), ps: List<&2, String>, +m: Nat) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> more:
      do IO<Unit>:
        ok : Bool <- Chan.send(Uj, q, Uj{p, m})
        uj.send(q, more, m)

# a failed chunk stops the stage, with its output
def ur.check(rs: List<&2, Ur>) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Ur{+p, +st, +t} <> more:
      Bool.pick(IO(Unit), U32.is_eq(st, 0), ur.check(more),
        IO.die(Unit, 255, "units: FAILED " ++ p ++ "\n" ++ S.str(t)))

def nth(xs: List<&2, List<&2, U32>>, n: Nat) -> List<&2, U32>:
  match xs n:
    case x <> more 0n:
      x
    case x <> more 1n+k:
      nth(more, k)
    case Nil{} _:
      Nil{}

def nat.of(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n)

# `units: F files in, U units out`, summed over the chunks' output
type Fu is Data:
  Fu{f: Nat, u: Nat}

def fu.line(+l: List<&2, U32>, fu: Fu) -> Fu:
  match fu:
    case Fu{+f, +u}:
      +ws = S.split(l, 32)
      Bool.pick(Fu, S.prefix(l, S.b("units: ")), Fu{Nat.add(f, nat.of(nth(ws, 1n))), Nat.add(u, nat.of(nth(ws, 4n)))}, Fu{f, u})

def fu.lines(ls: List<&2, List<&2, U32>>, fu: Fu) -> Fu:
  match ls:
    case Nil{}:
      fu
    case +l <> more:
      fu.lines(more, fu.line(l, fu))

def fu.all(rs: List<&2, Ur>, fu: Fu) -> Fu:
  match rs:
    case Nil{}:
      fu
    case Ur{p, st, +t} <> more:
      fu.all(more, fu.lines(S.split.lines(t), fu))

def fu.said(fu: Fu) -> String:
  match fu:
    case Fu{f, u}:
      Nat.show(f) ++ " files in, " ++ Nat.show(u) ++ " units out"

# the chunks' units, in order, into one file
def cat.units(+out: String, ps: List<&2, String>) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> more:
      do IO<Unit>:
        xs : List<&2, U32> <- S.read(p ++ ".units")
        S.add(out, xs)
        cat.units(out, more)

def units.run(+lang: String, +dir: String, +max: Nat, +maxhi: Nat, +chunk: Nat, +jobs: Nat) -> IO(Unit):
  +w = dir ++ "/units.work"
  do IO<Unit>:
    +bu : String <- S.env("BEND_UNITS", "bend-units")
    S.rm(w)
    S.mkdir(w)
    +hs : List<&2, String> <- split.pairs(dir ++ "/files-hi.nul", chunk, w ++ "/hi")
    +ls : List<&2, String> <- split.pairs(dir ++ "/files-lo.nul", chunk, w ++ "/lo")
    say(dir, "units: " ++ Nat.show(Nat.add(List.length(&2, String, hs), List.length(&2, String, ls))) ++ " chunks of " ++ Nat.show(chunk) ++ " files, " ++ Nat.show(jobs) ++ " at once")
    +q : Chan(Uj) <- Chan.new(Uj, U32.from_nat(jobs))
    chs : List<Chan(List<&2, Ur>)> <- uw.fork(jobs, bu, lang, q)
    uj.send(q, hs, maxhi)
    uj.send(q, ls, max)
    Chan.close(Uj, q)
    +rs : List<&2, Ur> <- uw.join(chs, Nil{})
    ur.check(rs)
    S.write(dir ++ "/units.nul.tmp", Nil{})
    cat.units(dir ++ "/units.nul.tmp", List.append(&2, String, hs, ls))
    S.mv(dir ++ "/units.nul.tmp", dir ++ "/units.nul")
    say(dir, "units: " ++ fu.said(fu.all(rs, Fu{0n, 0n})))
    S.rm(w)

def units.if(done: Bool, +lang: String, +dir: String, +max: Nat, +maxhi: Nat, +chunk: Nat, +jobs: Nat) -> IO(Unit):
  match done:
    case True{}:
      say(dir, "units: done already")
    case False{}:
      units.run(lang, dir, max, maxhi, chunk, jobs)

def units(+lang: String, +dir: String, +max: Nat, +maxhi: Nat, +chunk: Nat, +jobs: Nat) -> IO(Unit):
  do IO<Unit>:
    +n : Nat <- S.size(dir ++ "/units.nul")
    units.if(Nat.is_lt(0n, n), lang, dir, max, maxhi, chunk, jobs)

# Stage check: bend-check ------------------------------------------------------

def nproc() -> IO(Nat):
  do IO<Nat>:
    xs : List<&2, U32> <- S.must("nproc", "nproc", [])
    return nat.of(S.chomp(xs))

def jobs.default(lang: Nat) -> IO(Nat):
  match lang:
    case 3n:
      IO.pure(Nat, 5n)
    case 2n:
      IO.pure(Nat, 8n)
    case _:
      nproc()

def jobs.or(n: Nat, +lang: Nat) -> IO(Nat):
  match n:
    case 0n:
      jobs.default(lang)
    case 1n+k:
      IO.pure(Nat, n)

# for LANG bend: the bend binary and the tree its units' imports resolve in
def check.env(lang: Nat) -> IO(List<String>):
  match lang:
    case 5n:
      do IO<List<String>>:
        +bend : String <- S.env("BEND", "bend")
        +src : String <- S.env("BEND_SRC", "run/code-sources/own")
        return ["BEND=" ++ bend, "BEND_SRC=" ++ src]
    case _:
      IO.pure(List<String>, [])

def ok.or(+st: U32, +what: String, +log: String) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(st, 0), IO.pure(Unit, Unit{}),
    IO.die(Unit, 1, "bend-transcripts: " ++ what ++ " failed (exit " ++ U32.show(st) ++ "), see " ++ log))

def nl.sp(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, U32.is_eq(h, 10), 32, h) <> nl.sp(t)

def shard.done(ok: Bool, +st: U32, +r: String) -> IO(U32):
  match ok:
    case True{}:
      do IO<U32>:
        S.mv(r ++ ".tmp.stats", r ++ ".stats")
        S.mv(r ++ ".tmp", r)
        return st
    case False{}:
      IO.pure(U32, st)

# One shard of CHECK_PROCS: bend-check with SHARD=k of SHARDS=n into
# results.K.nul (the Haskell dispatcher takes the packages whose key hashes
# to k; one process evaluates on one core, so the shards spread the parsing
# over processes).  A shard already done is kept.
def shard.go(have: Bool, +code: Nat, +k: Nat, +n: Nat, +bc: String, +lang: String, +dir: String, +jobs: Nat) -> IO(U32):
  match have:
    case True{}:
      IO.pure(U32, 0)
    case False{}:
      +r = dir ++ "/results." ++ Nat.show(k) ++ ".nul"
      do IO<U32>:
        env : List<String> <- check.env(code)
        +st : U32 <- S.run.log(".", ("SHARD=" ++ Nat.show(k)) <> ("SHARDS=" ++ Nat.show(n)) <> env, 2000000, bc, [lang, dir ++ "/units.nul", r ++ ".tmp", Nat.show(jobs)], dir ++ "/check." ++ Nat.show(k) ++ ".out")
        shard.done(U32.is_eq(st, 0), st, r)

def shard.run(+code: Nat, +k: Nat, +n: Nat, +bc: String, +lang: String, +dir: String, +jobs: Nat) -> IO(U32):
  do IO<U32>:
    +have : Nat <- S.size(dir ++ "/results." ++ Nat.show(k) ++ ".nul.stats")
    shard.go(Nat.is_lt(0n, have), code, k, n, bc, lang, dir, jobs)

def shards.fork(m: Nat, +code: Nat, +k: Nat, +n: Nat, +bc: String, +lang: String, +dir: String, +jobs: Nat) -> IO(List<Chan(U32)>):
  match m:
    case 0n:
      IO.pure(List<Chan(U32)>, Nil{})
    case 1n+p:
      do IO<List<Chan(U32)>>:
        ch : Chan(U32) <- IO.fork(U32, shard.run(code, k, n, bc, lang, dir, jobs))
        rest : List<Chan(U32)> <- shards.fork(p, code, 1n+k, n, bc, lang, dir, jobs)
        return ch <> rest

def shards.join(chs: List<Chan(U32)>, +bad: Nat) -> IO(Nat):
  match chs:
    case Nil{}:
      IO.pure(Nat, bad)
    case ch <> more:
      do IO<Nat>:
        +st : U32 <- IO.join(U32, ch)
        shards.join(more, Bool.pick(Nat, U32.is_eq(st, 0), bad, 1n+bad))

def shards.files(m: Nat, +k: Nat, +dir: String, +ext: String) -> List<String>:
  match m:
    case 0n:
      Nil{}
    case 1n+p:
      (dir ++ "/results." ++ Nat.show(k) ++ ".nul" ++ ext) <> shards.files(p, 1n+k, dir, ext)

# `key count` lines, summed over the shards
def stat.line(+l: List<&2, U32>, st: List<&2, L.Stat>) -> List<&2, L.Stat>:
  +k = before(l, 32)
  L.stat.bump(S.str(k), nat.of(List.drop(&2, U32, l, 1n+S.len(k))), st)

def stat.lines(ls: List<&2, List<&2, U32>>, +st: List<&2, L.Stat>) -> List<&2, L.Stat>:
  match ls:
    case Nil{}:
      st
    case +l <> more:
      stat.lines(more, Bool.pick(List<&2, L.Stat>, Nat.is_eq(S.len(l), 0n), st, stat.line(l, st)))

def stat.sum(fs: List<String>, st: List<&2, L.Stat>) -> IO(List<&2, L.Stat>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, L.Stat>, st)
    case +f <> more:
      do IO<List<&2, L.Stat>>:
        +xs : List<&2, U32> <- S.read(f)
        stat.sum(more, stat.lines(S.split.lines(xs), st))

# results files one after another into results.nul, their stats summed
def cat.into(fs: List<String>, sfs: List<String>, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +st : U32 <- S.run.log(".", [], 2000000, "cat", fs, dir ++ "/results.nul.cat")
    ok.or(st, "cat of the results", dir ++ "/results.nul.cat")
    +sts : List<&2, L.Stat> <- stat.sum(sfs, Nil{})
    S.write(dir ++ "/results.nul.stats", S.b(L.stat.show(sts)))
    S.mv(dir ++ "/results.nul.cat", dir ++ "/results.nul")

# A restart after a stop: results.prev.nul (+ .stats) holds the stopped
# run's kept results, and DONE (bend-check) the ids it decided; they go
# back in front of the new results.
def prev.then(none: Bool, +dir: String, +ext: String, rest: List<String>) -> List<String>:
  match none:
    case True{}:
      rest
    case False{}:
      (dir ++ "/results.prev.nul" ++ ext) <> rest

def prev.none(+dir: String) -> IO(Bool):
  do IO<Bool>:
    +n : Nat <- S.size(dir ++ "/results.prev.nul.stats")
    return Nat.is_eq(n, 0n)

# the shards' results one after another (shard order), and their stats
def shards.cat(+n: Nat, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +none : Bool <- prev.none(dir)
    cat.into(prev.then(none, dir, "", shards.files(n, 0n, dir, "")), prev.then(none, dir, ".stats", shards.files(n, 0n, dir, ".stats")), dir)

def shards.all(bad: Nat, +n: Nat, +dir: String) -> IO(Unit):
  match bad:
    case 0n:
      shards.cat(n, dir)
    case 1n+b:
      IO.die(Unit, 1, "bend-transcripts: " ++ Nat.show(bad) ++ " of " ++ Nat.show(n) ++ " bend-check shards failed, see " ++ dir ++ "/check.K.out")

def one.fin(none: Bool, +dir: String) -> IO(Unit):
  match none:
    case True{}:
      do IO<Unit>:
        S.mv(dir ++ "/results.nul.tmp.stats", dir ++ "/results.nul.stats")
        S.mv(dir ++ "/results.nul.tmp", dir ++ "/results.nul")
    case False{}:
      cat.into([dir ++ "/results.prev.nul", dir ++ "/results.nul.tmp"], [dir ++ "/results.prev.nul.stats", dir ++ "/results.nul.tmp.stats"], dir)

def check.one(+code: Nat, +lang: String, +dir: String, +bc: String, +jobs: Nat) -> IO(Unit):
  do IO<Unit>:
    env : List<String> <- check.env(code)
    say(dir, "check: bend-check " ++ lang ++ " with " ++ Nat.show(jobs) ++ " workers")
    +st : U32 <- S.run.log(".", env, 2000000, bc, [lang, dir ++ "/units.nul", dir ++ "/results.nul.tmp", Nat.show(jobs)], dir ++ "/check.out")
    ok.or(st, "bend-check", dir ++ "/check.out")
    +none : Bool <- prev.none(dir)
    one.fin(none, dir)

def check.many(+code: Nat, +n: Nat, +lang: String, +dir: String, +bc: String, +jobs: Nat) -> IO(Unit):
  do IO<Unit>:
    say(dir, "check: " ++ Nat.show(n) ++ " bend-check " ++ lang ++ " processes with " ++ Nat.show(jobs) ++ " workers each")
    chs : List<Chan(U32)> <- shards.fork(n, code, 0n, n, bc, lang, dir, jobs)
    +bad : Nat <- shards.join(chs, 0n)
    shards.all(bad, n, dir)

def check.procs(procs: Nat, +code: Nat, +lang: String, +dir: String, +bc: String, +jobs: Nat) -> IO(Unit):
  match procs:
    case 0n:
      check.one(code, lang, dir, bc, jobs)
    case 1n:
      check.one(code, lang, dir, bc, jobs)
    case _:
      check.many(code, procs, lang, dir, bc, jobs)

# CHECK_PROCS (default 1) processes of CHECK_JOBS workers each
def check.run(+code: Nat, +lang: String, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +cj : Nat <- S.env.nat("CHECK_JOBS", 0n)
    +jobs : Nat <- jobs.or(cj, code)
    +procs : Nat <- S.env.nat("CHECK_PROCS", 1n)
    +bc : String <- S.env("BEND_CHECK", "bend-check")
    check.procs(procs, code, lang, dir, bc, jobs)
    stats : List<&2, U32> <- S.read(dir ++ "/results.nul.stats")
    say(dir, "check: " ++ S.str(nl.sp(stats)))

def check.if(done: Bool, +code: Nat, +lang: String, +dir: String) -> IO(Unit):
  match done:
    case True{}:
      say(dir, "check: done already")
    case False{}:
      check.run(code, lang, dir)

def check(+code: Nat, +lang: String, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +n : Nat <- S.size(dir ++ "/results.nul")
    check.if(Nat.is_lt(0n, n), code, lang, dir)

# Stage clean: bend-clean ------------------------------------------------------

def clean.run(+dir: String) -> IO(Unit):
  do IO<Unit>:
    +bc : String <- S.env("BEND_CLEAN", "bend-clean")
    +ev : String <- S.env("EVAL", "run/code-eval-v2.jsonl")
    say(dir, "clean: against " ++ ev)
    +st : U32 <- S.run.log(".", [], 2000000, bc, [dir ++ "/results.nul", dir ++ "/results.train.nul", dir ++ "/results.holdout.nul", ev], dir ++ "/clean.out")
    ok.or(st, "bend-clean", dir ++ "/clean.out")
    stats : List<&2, U32> <- S.read(dir ++ "/results.train.nul.stats")
    say(dir, "clean: " ++ S.str(nl.sp(stats)))

def clean.if(done: Bool, +dir: String) -> IO(Unit):
  match done:
    case True{}:
      say(dir, "clean: done already")
    case False{}:
      clean.run(dir)

def clean(+dir: String) -> IO(Unit):
  do IO<Unit>:
    +n : Nat <- S.size(dir ++ "/results.train.nul.stats")
    clean.if(Nat.is_lt(0n, n), dir)

# Stage render: bend-transcript -------------------------------------------------

def last.line(ls: List<&2, List<&2, U32>>, +d: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      d
    case l <> more:
      last.line(more, l)

# one of the two: results.PART.nul to transcripts.PART.nul
def render.part(+dir: String, +window: Nat, +tok: String, +bt: String, +part: String) -> IO(Unit):
  +out = dir ++ "/transcripts." ++ part ++ ".nul"
  +log = dir ++ "/render." ++ part ++ ".out"
  do IO<Unit>:
    +st : U32 <- S.run.log(".", [], 2000000, bt, [tok, dir ++ "/results." ++ part ++ ".nul", out ++ ".tmp", Nat.show(window)], log)
    ok.or(st, "bend-transcript", log)
    S.mv(out ++ ".tmp", out)
    xs : List<&2, U32> <- S.read(log)
    say(dir, "render: " ++ part ++ ": " ++ S.str(last.line(S.split.lines(xs), Nil{})))

def render.run(+dir: String, +window: Nat, +tok: String) -> IO(Unit):
  do IO<Unit>:
    +bt : String <- S.env("BEND_TRANSCRIPT", "bend-transcript")
    say(dir, "render: window " ++ Nat.show(window))
    render.part(dir, window, tok, bt, "holdout")
    render.part(dir, window, tok, bt, "train")

def render.if(done: Bool, +dir: String, +window: Nat, +tok: String) -> IO(Unit):
  match done:
    case True{}:
      say(dir, "render: done already")
    case False{}:
      render.run(dir, window, tok)

def render(+dir: String, +window: Nat, +tok: String) -> IO(Unit):
  do IO<Unit>:
    +n : Nat <- S.size(dir ++ "/transcripts.train.nul")
    render.if(Nat.is_lt(0n, n), dir, window, tok)

# The driver --------------------------------------------------------------------

type Tc is Data:
  Tc{code: Nat, lang: String, dir: String, corpus: String, max: Nat, maxhi: Nat, chunk: Nat, jobs: Nat, window: Nat, tok: String, pct: U32}

def stage.run(stage: Nat, +code: Nat, +lang: String, +dir: String, +corpus: String, +max: Nat, +maxhi: Nat, +chunk: Nat, +jobs: Nat, +window: Nat, +tok: String, +pct: U32) -> IO(Unit):
  match stage:
    case 1n:
      sources(code, dir, corpus, max, maxhi, pct)
    case 2n:
      units(lang, dir, max, maxhi, chunk, jobs)
    case 3n:
      check(code, lang, dir)
    case 4n:
      render(dir, window, tok)
    case 6n:
      clean(dir)
    case _:
      do IO<Unit>:
        sources(code, dir, corpus, max, maxhi, pct)
        units(lang, dir, max, maxhi, chunk, jobs)
        check(code, lang, dir)
        clean(dir)
        render(dir, window, tok)

def stage.go(stage: Nat, c: Tc) -> IO(Unit):
  match c:
    case Tc{+code, +lang, +dir, +corpus, +max, +maxhi, +chunk, +jobs, +window, +tok, +pct}:
      stage.run(stage, code, lang, dir, corpus, max, maxhi, chunk, jobs, window, tok, pct)

def corpus.of(there: Bool) -> String:
  Bool.pick(String, there, "run/code-train-v3.jsonl", "run/code-train-v2.jsonl")

def start(stage: Nat, code: Nat, +lang: String) -> IO(Unit):
  match stage code:
    case _ 0n:
      IO.die(Unit, 2, "bend-transcripts: LANG is haskell, agda, lean, nix or bend")
    case 0n _:
      IO.die(Unit, 2, "bend-transcripts: STAGE is sources, units, check, clean, render or all")
    case _ _:
      do IO<Unit>:
        +v3 : Bool <- S.exists("run/code-train-v3.jsonl")
        +corpus : String <- S.env("CORPUS", corpus.of(v3))
        +out : String <- S.env("OUT", "run/transcripts")
        +max : Nat <- S.env.nat("MAX", 4n)
        +maxhi : Nat <- S.env.nat("MAX_HI", 8n)
        +chunk : Nat <- S.env.nat("CHUNK", 300n)
        +jobs : Nat <- S.env.nat("UNIT_JOBS", 8n)
        +window : Nat <- S.env.nat("WINDOW", 2048n)
        +tok : String <- S.env("TOKENIZER", "weights/code32k.bpe")
        +pct : Nat <- S.env.nat("HACKAGE_PCT", 30n)
        +dir : String = out ++ "/" ++ lang
        S.mkdir(dir)
        stage.go(stage, Tc{code, lang, dir, corpus, max, maxhi, chunk, jobs, window, tok, U32.from_nat(pct)})

def usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-transcripts STAGE LANG")

def args.go(xs: List<String>) -> IO(Unit):
  match xs:
    case +st <> +l <> Nil{}:
      start(stage.code(st), lang.code(l), l)
    case _:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args.go(xs)
