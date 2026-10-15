import Base
import ../Sys.bend as S
import ./Lib.bend as L
import ./Steps.bend as St
import ./Keyed.bend as K

# steady-mix: a raw mix whose language shares hold from its first line to its
# last (2026-10-15, the plan "all logic in Bend", Phase 4:
# tools/corpus-v2/steady-mix.sh).
#
#   bend-corpus-v2 steady-mix OUT.jsonl SRC.jsonl:BYTES ...
#
# Run 2's mix (rawshards.sh mix) ran raw Agda dry at 72.8% of its output and
# Lean at 94.1%; here every source runs dry in the same round:
#
#   T_s = min(lines, BYTES * lines / bytes)   the documents source s gives
#                                             (BYTES `all`: every line; the
#                                             product in big integers, st.bn)
#   R   = min_s T_s                           the rounds
#   PER_s = floor(T_s / R), take PER_s * R    each round's share, and the
#                                             documents taken
#
# A source is sampled as it is taken: its first PER_s * R lines in keyed
# order (keyed-order lines, salt "steady-mix BASENAME"; the script took `shuf
# -n` with that string as its random source, a change the user accepted), so
# no repository runs in one block and a rerun takes the same sample; then the
# deploy tool's `mix` interleaves PER_s lines of each per round, R rounds.
# The check at the end cuts OUT into 20 pieces by bytes (a line and its
# newline in the piece its first byte falls in: int(bytes before it * 20 /
# OUT's size)) and prints each piece's byte share by language, from the id's
# extension (.hs .lhs haskell, .lean, .agda .lagda (+ .md .tex .rst) agda,
# .nix, .bend, else other), the languages in bytewise order, to stdout and to
# OUT less .jsonl plus .steady.txt.  (The script's awk measured a line in
# characters against a size in bytes, and printed the languages in its hash
# order.)  A piece no line starts in shows 0.0%.
#
# lines and bytes are `wc -l -c`'s.  The samples sit in OUT's directory's
# steady-tmp, removed at the end.  Run from the repository root.  Every def
# is prefixed `smx.`.

# A source (pure) -------------------------------------------------------------------------------

type SmSrc is Data:
  SmSrc{f: String, want: String, lines: Nat, bytes: Nat, t: Nat}

def smx.src.f(+s: SmSrc) -> String:
  match s:
    case SmSrc{f, w, l, b, t}:
      f

def smx.src.t(+s: SmSrc) -> Nat:
  match s:
    case SmSrc{f, w, l, b, t}:
      t

# what SRC:BYTES gives: every line, or BYTES * lines / bytes of them, at most lines
def smx.take(+want: String, +lines: Nat, +bytes: Nat) -> Nat:
  +w = K.kor.nat(S.b(want))
  +q = St.st.bn.nat(St.st.bn.fst(St.st.bn.divmod(St.st.bn.mul(St.st.bn.of(w), St.st.bn.of(lines)), St.st.bn.of(Nat.max(bytes, 1n)))))
  Bool.pick(Nat, String.eq(want, "all"), lines, Nat.min(lines, q))

def smx.min(ss: List<&2, SmSrc>, +m: Nat) -> Nat:
  match ss:
    case Nil{}:
      m
    case +s <> t:
      smx.min(t, Nat.min(m, smx.src.t(s)))

def smx.base(+f: String) -> String:
  +b = S.base(f)
  Bool.pick(String, S.suffix(S.b(b), S.b(".jsonl")), S.str(List.take(&2, U32, S.b(b), Nat.sub(S.len(S.b(b)), 6n))), b)

# The check (pure) ------------------------------------------------------------------------------

# 0 other, 1 haskell, 2 lean, 3 agda, 4 nix, 5 bend
def smx.lang.names() -> List<&2, String>:
  ["other", "haskell", "lean", "agda", "nix", "bend"]

def smx.ends(+id: List<&2, U32>, +e: String) -> Bool:
  S.suffix(id, S.b(e))

def smx.agda(+id: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(smx.ends(id, ".agda"), smx.ends(id, ".lagda")),
    Bool.or(Bool.or(Bool.or(smx.ends(id, ".agda.md"), smx.ends(id, ".lagda.md")), Bool.or(smx.ends(id, ".agda.tex"), smx.ends(id, ".lagda.tex"))),
      Bool.or(smx.ends(id, ".agda.rst"), smx.ends(id, ".lagda.rst"))))

def smx.lang(+id: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.or(smx.ends(id, ".hs"), smx.ends(id, ".lhs")), 1n, Bool.pick(Nat, smx.ends(id, ".lean"), 2n,
    Bool.pick(Nat, smx.agda(id), 3n, Bool.pick(Nat, smx.ends(id, ".nix"), 4n, Bool.pick(Nat, smx.ends(id, ".bend"), 5n, 0n)))))

def smx.sp.drop(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case c <> +t True{}:
      smx.sp.drop(t, S.head.is(t, 32))
    case r _:
      r

# awk's id: `sub(/^\{"id": *"/, "", id); sub(/".*/, "", id)`
def smx.id.at(+line: List<&2, U32>) -> List<&2, U32>:
  +r = List.drop(&2, U32, line, 6n)
  +q = smx.sp.drop(r, S.head.is(r, 32))
  Bool.pick(List<&2, U32>, Bool.and(S.prefix(line, S.b("{\"id\":")), S.head.is(q, 34)), List.drop(&2, U32, q, 1n), line)

def smx.id(+line: List<&2, U32>) -> List<&2, U32>:
  L.v2.before(smx.id.at(line), 34)

# a table of 20 pieces x 6 languages, the bytes in each
def smx.zeros(n: Nat) -> List<&2, Nat>:
  List.replicate(Nat, n, 0n)

def smx.bump(xs: List<&2, Nat>, i: Nat, +b: Nat) -> List<&2, Nat>:
  match xs i:
    case Nil{} _:
      Nil{}
    case +x <> t 0n:
      Nat.add(x, b) <> t
    case +x <> t 1n+j:
      x <> smx.bump(t, j, b)

def smx.at(xs: List<&2, Nat>, +i: Nat) -> Nat:
  Maybe.default(&2, Nat, List.get(&2, Nat, xs, i), 0n)

# Settings, logs -----------------------------------------------------------------------------------

def smx.log(+msg: String) -> IO(Unit):
  K.kor.log("steady-mix", msg)

# `wc -l -c F`: lines and bytes
def smx.wc.of(+o: S.Out) -> Nat & Nat:
  +ws = K.kor.words(S.Out.text(o))
  (K.kor.nat(K.kor.field(ws, 0n)), K.kor.nat(K.kor.field(ws, 1n)))

def smx.wc(+f: String) -> IO(Nat & Nat):
  do IO<Nat & Nat>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 86400, "wc", ["-l", "-c", f], Nil{})
    Bool.pick(IO(Nat & Nat), U32.is_eq(S.Out.status(o), 0), IO.pure(Nat & Nat, smx.wc.of(o)), IO.die(Nat & Nat, 1, "steady-mix: wc " ++ f ++ " failed"))

def smx.src.of(+f: String, +want: String, r: Nat & Nat) -> IO(SmSrc):
  (+lines, +bytes) = r
  +t = smx.take(want, lines, bytes)
  do IO<SmSrc>:
    Bool.pick(IO(Unit), Nat.is_eq(t, 0n), K.kor.die("steady-mix", f ++ " gives no document at " ++ want ++ " bytes"), IO.pure(Unit, Unit{}))
    smx.log(f ++ ": " ++ Nat.show(lines) ++ " lines, " ++ Nat.show(bytes) ++ " bytes; takes " ++ Nat.show(t))
    return SmSrc{f, want, lines, bytes, t}

def smx.src(+a: String) -> IO(SmSrc):
  +xs = S.b(a)
  +f = S.str(L.v2.parent(xs, 58))
  +want = S.str(St.st.after.last(xs, 58))
  do IO<SmSrc>:
    Bool.pick(IO(Unit), L.v2.has(xs, 58), IO.pure(Unit, Unit{}), IO.die(Unit, 2, "steady-mix: " ++ a ++ " is not SRC.jsonl:BYTES"))
    r : Nat & Nat <- smx.wc(f)
    smx.src.of(f, want, r)

def smx.srcs(as: List<&2, String>) -> IO(List<&2, SmSrc>):
  match as:
    case Nil{}:
      IO.pure(List<&2, SmSrc>, Nil{})
    case +a <> t:
      do IO<List<&2, SmSrc>>:
        +s : SmSrc <- smx.src(a)
        +rest : List<&2, SmSrc> <- smx.srcs(t)
        return s <> rest

# each source sampled into tmp: the mix's SRC:PER arguments
def smx.samples(ss: List<&2, SmSrc>, +rounds: Nat, +tmp: String, +i: Nat) -> IO(List<&2, String>):
  match ss:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +s <> t:
      +f = smx.src.f(s)
      +per = Nat.div(smx.src.t(s), Nat.max(rounds, 1n))
      +n = Nat.mul(per, rounds)
      +dst = tmp ++ "/" ++ smx.base(f) ++ "." ++ Nat.show(i) ++ ".jsonl"
      do IO<List<&2, String>>:
        r : Nat & Nat <- K.kor.order(True{}, "steady-mix " ++ S.base(f), n, f, dst)
        smx.log(f ++ ": " ++ Nat.show(n) ++ " lines sampled (" ++ Nat.show(per) ++ " a round)")
        +rest : List<&2, String> <- smx.samples(t, rounds, tmp, 1n+i)
        return (dst ++ ":" ++ Nat.show(per)) <> rest

# The check: a line at a time ----------------------------------------------------------------------

# the reader, the bytes so far, the table (piece * 6 + language) and each piece's bytes, the languages seen
type SmCk is Type:
  SmCk{r: S.Rd, acc: Nat, tab: List<&2, Nat>, p: List<&2, Nat>, seen: List<&2, Nat>, more: Bool}

def smx.ck.line(m: Maybe<&2, List<&2, U32>>, r: S.Rd, +total: Nat, +acc: Nat, +tab: List<&2, Nat>, +p: List<&2, Nat>, +seen: List<&2, Nat>) -> IO(SmCk):
  match m:
    case None{}:
      IO.pure(SmCk, SmCk{r, acc, tab, p, seen, False{}})
    case Some{+l}:
      +b = Nat.add(1n, S.len(l))
      +piece = Nat.min(19n, Nat.div(Nat.mul(acc, 20n), Nat.max(total, 1n)))
      +lang = smx.lang(smx.id(l))
      IO.pure(SmCk, SmCk{r, Nat.add(acc, b), smx.bump(tab, Nat.add(Nat.mul(piece, 6n), lang), b), smx.bump(p, piece, b), smx.bump(seen, lang, 1n), True{}})

def smx.ck.got(+total: Nat, +acc: Nat, +tab: List<&2, Nat>, +p: List<&2, Nat>, +seen: List<&2, Nat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(SmCk):
  (r, m) = x
  smx.ck.line(m, r, total, acc, tab, p, seen)

def smx.ck.step(+total: Nat, s: SmCk) -> IO(SmCk):
  match s:
    case SmCk{r, acc, tab, p, seen, m}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, SmCk, S.Rd.next(r), smx.ck.got(total, acc, tab, p, seen))

def smx.ck.go(fuel: Nat, +total: Nat, s: SmCk) -> IO(SmCk):
  match fuel s:
    case 1n+f SmCk{r, acc, tab, p, seen, True{}}:
      IO.bind(SmCk, SmCk, smx.ck.step(total, SmCk{r, acc, tab, p, seen, True{}}), smx.ck.go(f, total))
    case _ s2:
      IO.pure(SmCk, s2)

def smx.pad(+s: String, +w: Nat) -> String:
  String.concat(List.replicate(String, Nat.sub(w, String.length(s)), " ")) ++ s

# the languages seen, in bytewise order of their names
def smx.order() -> List<&2, Nat>:
  [3n, 5n, 1n, 2n, 4n, 0n]

def smx.cols(ls: List<&2, Nat>, +seen: List<&2, Nat>) -> List<&2, Nat>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = smx.cols(t, seen)
      Bool.pick(List<&2, Nat>, Nat.is_eq(smx.at(seen, l), 0n), r, l <> r)

def smx.name(+l: Nat) -> String:
  Maybe.default(&2, String, List.get(&2, String, smx.lang.names(), l), "other")

def smx.head(cs: List<&2, Nat>) -> String:
  match cs:
    case Nil{}:
      ""
    case +c <> t:
      " " ++ smx.pad(smx.name(c), 8n) ++ smx.head(t)

# " %7.1f%%" of 100 * s / p, the double's quotient rounded as printf rounds
def smx.cell(+s: Nat, +p: Nat) -> String:
  +x = Bool.pick(St.StF, Nat.is_eq(p, 0n), St.st.f.zero(), St.st.f.ratio(Nat.mul(100n, s), Nat.max(p, 1n)))
  " " ++ smx.pad(St.st.f.fixed(x, 1n), 7n) ++ "%"

def smx.row(cs: List<&2, Nat>, +tab: List<&2, Nat>, +i: Nat, +p: Nat) -> String:
  match cs:
    case Nil{}:
      ""
    case +c <> t:
      smx.cell(smx.at(tab, Nat.add(Nat.mul(i, 6n), c)), p) ++ smx.row(t, tab, i, p)

def smx.rows(k: Nat, +cs: List<&2, Nat>, +tab: List<&2, Nat>, +p: List<&2, Nat>, +i: Nat) -> String:
  match k:
    case 0n:
      ""
    case 1n+j:
      smx.pad(Nat.show(1n+i), 5n) ++ smx.row(cs, tab, i, smx.at(p, i)) ++ "\n" ++ smx.rows(j, cs, tab, p, 1n+i)

def smx.table(+tab: List<&2, Nat>, +p: List<&2, Nat>, +seen: List<&2, Nat>) -> String:
  +cs = smx.cols(smx.order(), seen)
  "piece" ++ smx.head(cs) ++ "\n" ++ smx.rows(20n, cs, tab, p, 0n)

def smx.ck.fin(s: SmCk) -> IO(String):
  match s:
    case SmCk{r, acc, +tab, +p, +seen, m}:
      do IO<String>:
        S.Rd.close(r)
        return smx.table(tab, p, seen)

def smx.size(+o: S.Out) -> Nat:
  K.kor.nat(S.chomp(S.Out.text(o)))

# the twentieths' table of a mix
def smx.check(+out: String) -> IO(String):
  do IO<String>:
    +o : S.Out <- S.run(".", [], 600, "stat", ["-L", "-c", "%s", out], Nil{})
    r : S.Rd <- S.Rd.lines(out)
    s : SmCk <- smx.ck.go(K.kor.fuel(), smx.size(o), SmCk{r, 0n, smx.zeros(120n), smx.zeros(20n), smx.zeros(6n), True{}})
    smx.ck.fin(s)

# Main -------------------------------------------------------------------------------------------

def smx.stem(+out: String) -> String:
  Bool.pick(String, S.suffix(S.b(out), S.b(".jsonl")), S.str(List.take(&2, U32, S.b(out), Nat.sub(S.len(S.b(out)), 6n))), out)

def smx.run(+out: String, +as: List<&2, String>) -> IO(Unit):
  +tmp = K.kor.dir(out) ++ "/steady-tmp"
  do IO<Unit>:
    S.mkdir(tmp)
    +ss : List<&2, SmSrc> <- smx.srcs(as)
    +rounds : Nat = smx.min(ss, K.kor.fuel())
    +args : List<&2, String> <- smx.samples(ss, rounds, tmp, 0n)
    smx.log(Nat.show(rounds) ++ " rounds")
    K.kor.tool([], "mix", out <> args)
    +t : String <- smx.check(out)
    IO.write(t)
    S.write(smx.stem(out) ++ ".steady.txt", S.b(t))
    S.rm(tmp)
    smx.log("done: " ++ out)

def smx.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +out <> a <> more:
      smx.run(out, K.kor.l2(a <> more))
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 steady-mix OUT.jsonl SRC.jsonl:BYTES ...")
