import Base
import ../Sys.bend as S
import ../Json.bend as J
import ../Sha256.bend as H
import ./Lib.bend as L

# Corpus v2's raw code (docs/CORPUS-V2.md, C4, C6; the old raw.py, byte for
# byte), and the two splitters the run scripts used Python for.
#
#   raw [OUT [SRC...]]   every raw file run 1 was fed or queued, by language,
#                        each file once, less what v2 holds out and what the
#                        transcript windows already use as filler, less the
#                        filters; shuffled by a hash of the id:
#                        OUT/LANG.jsonl ({"id","text"}) and OUT/summary.txt
#                        (OUT: run/v2/raw; SRC: raw.py's eight files)
#   split-nul SRC PRE N  a NUL (id, text) file's records as N shards
#                        PRE.S.in.nul, record j of k into shard j*N/k
#   slice SRC DST K SIZE slice K of a JSONL file: the lines that start in
#                        [(K-1)*SIZE, K*SIZE); the last slice keeps whole
#                        2,000-line parts only
#
# Meaning (raw).  Read the sources in order, a line at a time; a line that is
# not a {"id","text"} object, or whose path has no language, is passed over.
# A text whose content key (L.v2.key) came before is a copy, whatever it is;
# otherwise it is held out (L.v2.held.id or .key), filler (its key in
# run/v2/transcripts/filler.keys), or filtered: a line over 2,000 code points
# ("long line"), a generated-file marker in the first 1,000 code points
# ("generated"), Lean 3 ("lean 3").  The rest of a language, ordered by
# (sha256("corpus-v2 raw\0" + id) as hex, id, text), is written in that order
# with the repository caps (code points; Haskell 8 M, Lean 15 M, Agda 10 M)
# applied file by file: a file that would take its repository past the cap
# is passed over ("repo cap").  summary.txt: a line per language with a kept
# file, `{lang:8} kept {n:7d} files {MB:8.1f} MB; ` and the reasons' counts
# in sorted order.
#
# The refinement.  A Bend process evaluates on one thread, so the work is
# processes: (1) `split -n l/K/N` cuts each source into byte chunks at line
# ends and JOBS scanners (`raw --scan`) read them, each writing an index line
# a record (content key, position, language, its fate as if it came first)
# and, for a file that would be kept, a spool line (order hash, position,
# code points, repository, output line) under its language; (2) the index,
# sorted (LC_ALL=C sort) by key then position, says which records are
# copies (a key's first position is its first occurrence) and how many of
# each fate every language had; (3) each language's spool, sorted by the
# order hash, is written out by a `raw --write` with the caps.  Equal order
# hashes are one id (sha256), so such a run is ordered by its texts.
#
# The work is in OUT/.rw-work (spools about the size of the output; removed
# at the end); JOBS processes at once (default 5), chunks of RAW_CHUNK bytes
# (default 150 MB; a scanner holds ~0.7 GB, mostly filler.keys).  A slice
# K >= 2 skips to its start with `tail -c` into `raw --slice-at`.  The
# processes are this program again (the head of IO.args) under the
# subcommand rw.cmd() ("raw"): the program must answer to that name.
#
# Run from the repository root.  Every def is prefixed `rw.`: a program's
# definitions share one namespace across its imports.

# Bytes and numbers ------------------------------------------------------------

def rw.big() -> Nat:
  U32.to_nat(4294967295)

def rw.forever() -> U32:
  2000000

# the subcommand this module answers to (what the scanners and writers are
# started as: `SELF raw --scan ...`)
def rw.cmd() -> String:
  "raw"

# the program as invoked (the head of IO.args)
def rw.head(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> t:
      h

# a UTF-8 continuation byte (10xxxxxx) starts no code point
def rw.cont(+c: U32) -> Bool:
  Bool.and(U32.is_le(128, c), U32.is_le(c, 191))

def rw.lead.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.not(rw.cont(h))

# the code points (Python's len of the decoded text)
def rw.cps(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      rw.cps(t, Bool.pick(Nat, rw.cont(h), acc, 1n+acc))

# the bytes of the first k code points (Python's t[:k]); lead: the head
# starts a code point
def rw.cp.take.go(xs: List<&2, U32>, k: Nat, lead: Bool) -> List<&2, U32>:
  match xs k lead:
    case Nil{} _ _:
      Nil{}
    case h <> t 0n True{}:
      Nil{}
    case h <> +t 1n+j True{}:
      h <> rw.cp.take.go(t, j, rw.lead.head(t))
    case h <> +t j False{}:
      h <> rw.cp.take.go(t, j, rw.lead.head(t))

def rw.cp.take(+xs: List<&2, U32>, k: Nat) -> List<&2, U32>:
  rw.cp.take.go(xs, k, rw.lead.head(xs))

def rw.zeros(k: Nat) -> String:
  match k:
    case 0n:
      ""
    case 1n+(+j):
      "0" ++ rw.zeros(j)

def rw.spaces(k: Nat) -> String:
  match k:
    case 0n:
      ""
    case 1n+(+j):
      " " ++ rw.spaces(j)

# n in w digits, zeros in front
def rw.pad(+n: Nat, +w: Nat) -> String:
  +s = Nat.show(n)
  rw.zeros(Nat.sub(w, String.length(s))) ++ s

# a decimal number's value (its digits as bytes)
def rw.nat(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      rw.nat(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48))))

def rw.num(+xs: List<&2, U32>) -> Nat:
  rw.nat(S.chomp(xs), 0n)

# does a <= b, bytewise (Python's order of str: UTF-8 keeps code point
# order); lt, gt: how the heads compare
def rw.hd.lt(+xs: List<&2, U32>, +ys: List<&2, U32>) -> Bool:
  U32.is_lt(L.v2.byte.head(xs), L.v2.byte.head(ys))

def rw.le.go(a: List<&2, U32>, b: List<&2, U32>, lt: Bool, gt: Bool) -> Bool:
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
      rw.le.go(xt, yt, rw.hd.lt(xt, yt), rw.hd.lt(yt, xt))

def rw.le(+a: List<&2, U32>, +b: List<&2, U32>) -> Bool:
  rw.le.go(a, b, rw.hd.lt(a, b), rw.hd.lt(b, a))

# a line stamped in Mexico City time (UTC-6, no daylight saving), on stderr
def rw.pad2(+x: U32) -> String:
  Bool.pick(String, U32.is_lt(x, 10), "0", "") ++ U32.show(x)

def rw.civil(+z0: U32) -> String:
  +z = U32.add(z0, 719468)
  +era = U32.div(z, 146097)
  +doe = U32.sub(z, U32.mul(era, 146097))
  +yoe = U32.div(U32.sub(U32.add(doe, U32.div(doe, 36524)), U32.add(U32.div(doe, 1460), U32.div(doe, 146096))), 365)
  +doy = U32.sub(doe, U32.sub(U32.add(U32.mul(365, yoe), U32.div(yoe, 4)), U32.div(yoe, 100)))
  +mp = U32.div(U32.add(U32.mul(5, doy), 2), 153)
  +d = U32.add(U32.sub(doy, U32.div(U32.add(U32.mul(153, mp), 2), 5)), 1)
  +m = Bool.pick(U32, U32.is_lt(mp, 10), U32.add(mp, 3), U32.sub(mp, 9))
  +y = U32.add(U32.add(yoe, U32.mul(era, 400)), Bool.pick(U32, U32.is_le(m, 2), 1, 0))
  U32.show(y) ++ "-" ++ rw.pad2(m) ++ "-" ++ rw.pad2(d)

def rw.stamp(+ms: Nat) -> String:
  +t = U32.sub(U32.from_nat(Nat.div(ms, 1000n)), 21600)
  +s = U32.mod(t, 86400)
  "[" ++ rw.civil(U32.div(t, 86400)) ++ " " ++ rw.pad2(U32.div(s, 3600)) ++ ":" ++ rw.pad2(U32.div(U32.mod(s, 3600), 60))
    ++ ":" ++ rw.pad2(U32.mod(s, 60)) ++ " UTC-6]"

def rw.log(+line: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- IO.time()
    IO.print_err(rw.stamp(t) ++ " " ++ line)

# Languages and fates --------------------------------------------------------------
#
# A language is a code: 0 agda, 1 bend, 2 haskell, 3 lean, 4 nix (the order
# of their names), 5 none.  A fate is a code too, the reasons in their
# sorted order: 0 copy, 1 filler, 2 generated, 3 held out, 4 lean 3, 5 long
# line, 6 repo cap; 7 a file to keep.

def rw.lang.name(n: Nat) -> String:
  match n:
    case 0n:
      "agda"
    case 1n:
      "bend"
    case 2n:
      "haskell"
    case 3n:
      "lean"
    case _:
      "nix"

def rw.reason(n: Nat) -> String:
  match n:
    case 0n:
      "copy"
    case 1n:
      "filler"
    case 2n:
      "generated"
    case 3n:
      "held out"
    case 4n:
      "lean 3"
    case 5n:
      "long line"
    case _:
      "repo cap"

# the repository caps in code points (0: none)
def rw.cap(+lang: String) -> Nat:
  Bool.pick(Nat, String.eq(lang, "haskell"), 8000000n,
    Bool.pick(Nat, String.eq(lang, "lean"), 15000000n, Bool.pick(Nat, String.eq(lang, "agda"), 10000000n, 0n)))

def rw.lang.ext(+x: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.or(S.eq(x, S.b("hs")), S.eq(x, S.b("lhs"))), 2n,
    Bool.pick(Nat, S.eq(x, S.b("lean")), 3n,
      Bool.pick(Nat, Bool.or(S.eq(x, S.b("agda")), S.eq(x, S.b("lagda"))), 0n,
        Bool.pick(Nat, S.eq(x, S.b("nix")), 4n, Bool.pick(Nat, S.eq(x, S.b("bend")), 1n, 5n)))))

# an id's language: its path, lowered, by its extension (the text after the
# last dot; none without a dot), .lagda.md and .lagda.tex as Agda
def rw.lang(+id: List<&2, U32>) -> Nat:
  +n = L.v2.lower(L.v2.path.of(id))
  +x = Bool.pick(List<&2, U32>, L.v2.has(n, 46), List.reverse(&2, U32, L.v2.before(List.reverse(&2, U32, n), 46)), Nil{})
  Bool.pick(Nat, Bool.or(S.suffix(n, S.b(".lagda.md")), S.suffix(n, S.b(".lagda.tex"))), 0n, rw.lang.ext(x))

# a line longer than 2,000 code points (n: the current line's so far)
def rw.long.go(xs: List<&2, U32>, +n: U32, over: Bool) -> Bool:
  match xs over:
    case _ True{}:
      True{}
    case Nil{} False{}:
      False{}
    case +h <> t False{}:
      +m = Bool.pick(U32, U32.is_eq(h, 10), 0, Bool.pick(U32, rw.cont(h), n, U32.add(n, 1)))
      rw.long.go(t, m, U32.is_lt(2000, m))

def rw.long(+t: List<&2, U32>) -> Bool:
  rw.long.go(t, 0, False{})

# does xs start with p, stopping at the first difference (S.prefix compares
# the whole of p: Bool.and evaluates both sides); eq: the heads agree
def rw.heq(+xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  U32.is_eq(L.v2.byte.head(xs), L.v2.byte.head(p))

def rw.pre.go(p: List<&2, U32>, xs: List<&2, U32>, eq: Bool) -> Bool:
  match p xs eq:
    case Nil{} _ _:
      True{}
    case _ Nil{} _:
      False{}
    case _ _ False{}:
      False{}
    case y <> +pt x <> +xt True{}:
      rw.pre.go(pt, xt, rw.heq(xt, pt))

def rw.pre(+xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  rw.pre.go(p, xs, rw.heq(xs, p))

# does p (not empty) occur in xs; hit: it starts here
def rw.infix.go(xs: List<&2, U32>, +p: List<&2, U32>, hit: Bool) -> Bool:
  match xs hit:
    case _ True{}:
      True{}
    case Nil{} False{}:
      False{}
    case h <> +t False{}:
      rw.infix.go(t, p, rw.pre(t, p))

def rw.infix(+xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  rw.infix.go(xs, p, rw.pre(xs, p))

def rw.gen.marks() -> List<&2, String>:
  ["DO NOT EDIT", "do not edit", "Code generated", "auto-generated", "autogenerated", "Automatically generated",
   "This file was generated", "This file is generated", "generated by"]

def rw.gen.any(+p: List<&2, U32>, gs: List<&2, String>) -> Bool:
  match gs:
    case Nil{}:
      False{}
    case g <> more:
      Bool.or(rw.infix(p, S.b(g)), rw.gen.any(p, more))

# `import data.` opening a line of the first 2,000 code points, or a
# `begin` line and an `end` line
def rw.lean3(+t: List<&2, U32>) -> Bool:
  Bool.or(rw.infix(10 <> rw.cp.take(t, 2000n), S.b("\nimport data.")),
    Bool.and(rw.infix(t, S.b("\nbegin\n")), rw.infix(t, S.b("\nend"))))

def rw.why.lean(lean: Bool, +t: List<&2, U32>) -> Nat:
  match lean:
    case True{}:
      Bool.pick(Nat, rw.lean3(t), 4n, 7n)
    case False{}:
      7n

def rw.why.gen(gen: Bool, +lang: Nat, +t: List<&2, U32>) -> Nat:
  match gen:
    case True{}:
      2n
    case False{}:
      rw.why.lean(Nat.is_eq(lang, 3n), t)

def rw.why.long(long: Bool, +lang: Nat, +t: List<&2, U32>) -> Nat:
  match long:
    case True{}:
      5n
    case False{}:
      rw.why.gen(rw.gen.any(rw.cp.take(t, 1000n), rw.gen.marks()), lang, t)

def rw.st.fill(fill: Bool, +lang: Nat, +t: List<&2, U32>) -> Nat:
  match fill:
    case True{}:
      1n
    case False{}:
      rw.why.long(rw.long(t), lang, t)

def rw.st.held(held: Bool, +fk: Set(), +k: String, +lang: Nat, +t: List<&2, U32>) -> Nat:
  match held:
    case True{}:
      3n
    case False{}:
      rw.st.fill(L.v2.in(fk, k), lang, t)

# a record's fate were it the first with its key
def rw.fate(+e: L.Excl, +fk: Set(), +id: List<&2, U32>, +k: String, +lang: Nat, +t: List<&2, U32>) -> Nat:
  rw.st.held(Bool.or(L.v2.held.id(e, id), L.v2.held.key(e, k)), fk, k, lang, t)

# Scan: a chunk's index and spool lines ------------------------------------------
#
#   PRE.idx    KEY TAB POS TAB LANG TAB FATE        every record with a language
#   PRE.LANG   ORDER TAB POS TAB CPS TAB REPO TAB LINE   every file to keep
#
# POS is the chunk's position prefix and the line's number in the chunk, in
# fixed width, so bytewise order is source order; LINE is the output line.

def rw.idx.line(+k: String, +pos: String, +lang: Nat, +fate: Nat) -> List<&2, U32>:
  S.b(k ++ "\t" ++ pos ++ "\t" ++ Nat.show(lang) ++ "\t" ++ Nat.show(fate) ++ "\n")

def rw.order(+id: List<&2, U32>) -> String:
  H.sha256(S.append(S.b("corpus-v2 raw"), 0 <> id))

# L.v2.py.line's line (json.dumps({"id", "text"}, ensure_ascii=False) and a
# newline), each byte's escape built only when it takes one, and nothing
# copied but the short pieces in front
def rw.q.kind(+c: U32) -> Nat:
  Bool.pick(Nat, U32.is_lt(c, 32), 2n, Bool.pick(Nat, Bool.or(U32.is_eq(c, 34), U32.is_eq(c, 92)), 1n, 0n))

def rw.q.put(kind: Nat, +c: U32, +rest: List<&2, U32>) -> List<&2, U32>:
  match kind:
    case 0n:
      c <> rest
    case 1n:
      92 <> c <> rest
    case _:
      J.esc.byte(c, rest)

# the string's bytes escaped, its closing quote, then end
def rw.q.go(xs: List<&2, U32>, end: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      34 <> end
    case +c <> t:
      rw.q.put(rw.q.kind(c), c, rw.q.go(t, end))

def rw.py.line(id: List<&2, U32>, t: List<&2, U32>) -> List<&2, U32>:
  S.append(S.b("{\"id\": \""), rw.q.go(id, S.append(S.b(", \"text\": \""), rw.q.go(t, [125, 10]))))

def rw.sp.line(+pos: String, +id: List<&2, U32>, +t: List<&2, U32>) -> List<&2, U32>:
  S.append(S.b(rw.order(id) ++ "\t" ++ pos ++ "\t" ++ Nat.show(rw.cps(t, 0n)) ++ "\t"), S.append(L.v2.repo.of(id), 9 <> rw.py.line(id, t)))

type RwSc is Type:
  RwSc{rd: S.Rd, ix: File, n: Nat, go: Bool}

def rw.sc.keep(keep: Bool, rd: S.Rd, ix: File, +n: Nat, +pre: String, +pos: String, +lang: Nat, +id: List<&2, U32>, +t: List<&2, U32>, line: List<&2, U32>) -> IO(RwSc):
  match keep:
    case True{}:
      do IO<RwSc>:
        ix2 : File <- S.emit(ix, line)
        S.add(pre ++ "." ++ rw.lang.name(lang), rw.sp.line(pos, id, t))
        return RwSc{rd, ix2, 1n+n, True{}}
    case False{}:
      do IO<RwSc>:
        ix2 : File <- S.emit(ix, line)
        return RwSc{rd, ix2, 1n+n, True{}}

def rw.sc.fate(rd: S.Rd, ix: File, +n: Nat, +pre: String, +pos: String, +lang: Nat, +id: List<&2, U32>, +t: List<&2, U32>, +k: String, +fate: Nat) -> IO(RwSc):
  rw.sc.keep(Nat.is_eq(fate, 7n), rd, ix, n, pre, pos, lang, id, t, rw.idx.line(k, pos, lang, fate))

def rw.sc.rec(rd: S.Rd, ix: File, +e: L.Excl, +fk: Set(), +n: Nat, +pre: String, +pos: String, +lang: Nat, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(RwSc):
  +k = L.v2.key(t)
  rw.sc.fate(rd, ix, n, pre, pos, lang, id, t, k, rw.fate(e, fk, id, k, lang, t))

def rw.sc.lang(has: Bool, rd: S.Rd, ix: File, +e: L.Excl, +fk: Set(), +n: Nat, +pre: String, +pos: String, +lang: Nat, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(RwSc):
  match has:
    case True{}:
      rw.sc.rec(rd, ix, e, fk, n, pre, pos, lang, id, t)
    case False{}:
      IO.pure(RwSc, RwSc{rd, ix, 1n+n, True{}})

def rw.sc.doc(rd: S.Rd, ix: File, +e: L.Excl, +fk: Set(), +pp: String, +pre: String, +n: Nat, d: Maybe<&2, J.Doc>) -> IO(RwSc):
  match d:
    case None{}:
      IO.pure(RwSc, RwSc{rd, ix, 1n+n, True{}})
    case Some{J.Doc{+i, +t}}:
      +lang = rw.lang(i)
      rw.sc.lang(Nat.is_lt(lang, 5n), rd, ix, e, fk, n, pre, pp ++ rw.pad(n, 8n), lang, i, t)

def rw.sc.line(rd: S.Rd, ix: File, +e: L.Excl, +fk: Set(), +pp: String, +pre: String, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(RwSc):
  match m:
    case None{}:
      IO.pure(RwSc, RwSc{rd, ix, n, False{}})
    case Some{+l}:
      rw.sc.doc(rd, ix, e, fk, pp, pre, n, J.doc(l))

def rw.sc.got(ix: File, +e: L.Excl, +fk: Set(), +pp: String, +pre: String, +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RwSc):
  (rd, m) = x
  rw.sc.line(rd, ix, e, fk, pp, pre, n, m)

def rw.sc.step(+e: L.Excl, +fk: Set(), +pp: String, +pre: String, s: RwSc) -> IO(RwSc):
  match s:
    case RwSc{rd, ix, +n, g}:
      do IO<RwSc>:
        x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        rw.sc.got(ix, e, fk, pp, pre, n, x)

def rw.sc.go(fuel: Nat, +e: L.Excl, +fk: Set(), +pp: String, +pre: String, s: RwSc) -> IO(RwSc):
  match fuel s:
    case 1n+f RwSc{rd, ix, n, True{}}:
      IO.bind(RwSc, RwSc, rw.sc.step(e, fk, pp, pre, RwSc{rd, ix, n, True{}}), rw.sc.go(f, e, fk, pp, pre))
    case _ RwSc{rd, ix, n, g}:
      IO.pure(RwSc, RwSc{rd, ix, n, g})

def rw.sc.fin(+pre: String, s: RwSc) -> IO(Unit):
  match s:
    case RwSc{rd, ix, n, g}:
      do IO<Unit>:
        S.Rd.close(rd)
        File.close(ix)
        rw.log("raw: " ++ pre ++ ": " ++ Nat.show(n) ++ " lines")

# the lines of a file as a set
def rw.set.load(+path: String) -> IO(Set()):
  do IO<Set()>:
    xs : List<&2, U32> <- S.read(path)
    return Set.from_list(L.v2.lines.str(S.split.lines(xs)))

# every language's spool, empty
def rw.touch(+pre: String, k: Nat) -> IO(Unit):
  match k:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+(+j):
      do IO<Unit>:
        S.write(pre ++ "." ++ rw.lang.name(j), Nil{})
        rw.touch(pre, j)

# `raw --scan POS INPUT PRE`: the records of INPUT (a JSONL chunk; /dev/stdin
# for a pipe), their positions POS followed by the line's number
def rw.scan(+pp: String, +inp: String, +pre: String) -> IO(Unit):
  do IO<Unit>:
    e : L.Excl <- L.v2.ex.load("run/v2/holdout")
    fk : Set() <- rw.set.load("run/v2/transcripts/filler.keys")
    rw.touch(pre, 5n)
    rd : S.Rd <- S.Rd.lines(inp)
    ix : File <- IO.try(File, File.open(pre ++ ".idx", "w"))
    s : RwSc <- rw.sc.go(rw.big(), e, fk, pp, pre, RwSc{rd, ix, 0n, True{}})
    rw.sc.fin(pre, s)

# Decide: copies and the fates' counts --------------------------------------------
#
# Over W/idx (the index sorted by key, then position): a record whose key is
# the line before's is a copy; a copy that would have been kept goes into
# W/drop (its position), so its writer passes it over.  W/LANG.counts: the
# count of each fate code 0..7 of the language, a line each.

type RwDc is Type:
  RwDc{rd: S.Rd, dp: File, prev: List<&2, U32>, cnt: List<&2, Nat>, go: Bool}

def rw.nzeros(k: Nat) -> List<&2, Nat>:
  match k:
    case 0n:
      Nil{}
    case 1n+(+j):
      0n <> rw.nzeros(j)

def rw.bump(xs: List<&2, Nat>, i: Nat) -> List<&2, Nat>:
  match xs i:
    case Nil{} _:
      Nil{}
    case x <> t 0n:
      (1n+x) <> t
    case x <> t 1n+j:
      x <> rw.bump(t, j)

def rw.digit(+xs: List<&2, U32>) -> Nat:
  U32.to_nat(U32.sub(L.v2.byte.head(xs), 48))

def rw.dc.rec(first: Bool, keep: Bool, rd: S.Rd, dp: File, key: List<&2, U32>, cnt: List<&2, Nat>, +lang: Nat, +fate: Nat, pos: List<&2, U32>) -> IO(RwDc):
  match first keep:
    case True{} _:
      IO.pure(RwDc, RwDc{rd, dp, key, rw.bump(cnt, Nat.add(Nat.mul(lang, 8n), fate)), True{}})
    case False{} True{}:
      do IO<RwDc>:
        d2 : File <- S.emit(dp, S.append(pos, [10]))
        return RwDc{rd, d2, key, rw.bump(cnt, Nat.mul(lang, 8n)), True{}}
    case False{} False{}:
      IO.pure(RwDc, RwDc{rd, dp, key, rw.bump(cnt, Nat.mul(lang, 8n)), True{}})

def rw.dc.fields(rd: S.Rd, dp: File, prev: List<&2, U32>, cnt: List<&2, Nat>, +f: List<&2, List<&2, U32>>) -> IO(RwDc):
  +key = L.v2.nth(f, 0n)
  +fate = rw.digit(L.v2.nth(f, 3n))
  rw.dc.rec(Bool.not(S.eq(key, prev)), Nat.is_eq(fate, 7n), rd, dp, key, cnt, rw.digit(L.v2.nth(f, 2n)), fate, L.v2.nth(f, 1n))

def rw.dc.line(rd: S.Rd, dp: File, prev: List<&2, U32>, cnt: List<&2, Nat>, m: Maybe<&2, List<&2, U32>>) -> IO(RwDc):
  match m:
    case None{}:
      IO.pure(RwDc, RwDc{rd, dp, prev, cnt, False{}})
    case Some{+l}:
      rw.dc.fields(rd, dp, prev, cnt, S.split(l, 9))

def rw.dc.got(dp: File, prev: List<&2, U32>, cnt: List<&2, Nat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RwDc):
  (rd, m) = x
  rw.dc.line(rd, dp, prev, cnt, m)

def rw.dc.step(s: RwDc) -> IO(RwDc):
  match s:
    case RwDc{rd, dp, prev, cnt, g}:
      do IO<RwDc>:
        x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        rw.dc.got(dp, prev, cnt, x)

def rw.dc.go(fuel: Nat, s: RwDc) -> IO(RwDc):
  match fuel s:
    case 1n+f RwDc{rd, dp, prev, cnt, True{}}:
      IO.bind(RwDc, RwDc, rw.dc.step(RwDc{rd, dp, prev, cnt, True{}}), rw.dc.go(f))
    case _ RwDc{rd, dp, prev, cnt, g}:
      IO.pure(RwDc, RwDc{rd, dp, prev, cnt, g})

def rw.nats.str(xs: List<&2, Nat>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> more:
      Nat.show(x) ++ "\n" ++ rw.nats.str(more)

def rw.dc.write(+w: String, +cnt: List<&2, Nat>, k: Nat) -> IO(Unit):
  match k:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+(+j):
      do IO<Unit>:
        S.write(w ++ "/" ++ rw.lang.name(j) ++ ".counts", S.b(rw.nats.str(List.take(&2, Nat, List.drop(&2, Nat, cnt, Nat.mul(j, 8n)), 8n))))
        rw.dc.write(w, cnt, j)

def rw.dc.fin(+w: String, s: RwDc) -> IO(Unit):
  match s:
    case RwDc{rd, dp, prev, cnt, g}:
      do IO<Unit>:
        S.Rd.close(rd)
        File.close(dp)
        rw.dc.write(w, cnt, 5n)

def rw.decide(+w: String) -> IO(Unit):
  do IO<Unit>:
    rd : S.Rd <- S.Rd.lines(w ++ "/idx")
    dp : File <- IO.try(File, File.open(w ++ "/drop", "w"))
    s : RwDc <- rw.dc.go(rw.big(), RwDc{rd, dp, Nil{}, rw.nzeros(40n), True{}})
    rw.dc.fin(w, s)

# Write: a language's files in order, with the caps --------------------------------
#
# Over W/LANG.sorted (its spool sorted by order hash): the lines of one hash
# are one id's, ordered by their texts; a line whose position is in W/drop is
# a copy; a file that would take its repository past the cap is passed
# over.  OUT/LANG.jsonl, and W/LANG.summary (its summary line; empty when
# the language kept no file before the caps, and then no LANG.jsonl).

# the kept so far: per repository code points, files, code points, files
# capped, files before the caps
type RwAc is Data:
  RwAc{per: Map<&2, Nat>, n: Nat, b: Nat, capped: Nat, cands: Nat}

def rw.wt.put(over: Bool, out: File, per: Map<&2, Nat>, +v: Nat, +n: Nat, +b: Nat, +capped: Nat, +cands: Nat, +repo: String, +cl: Nat, json: List<&2, U32>) -> IO(File & RwAc):
  match over:
    case True{}:
      IO.pure(File & RwAc, (out, RwAc{per, n, b, 1n+capped, 1n+cands}))
    case False{}:
      do IO<File & RwAc>:
        o2 : File <- S.emit(out, S.append(json, [10]))
        return (o2, RwAc{Map.set(&2, Nat, per, repo, Nat.add(v, cl)), 1n+n, Nat.add(b, cl), capped, 1n+cands})

def rw.wt.v(out: File, per: Map<&2, Nat>, +v: Nat, +n: Nat, +b: Nat, +capped: Nat, +cands: Nat, +cap: Nat, +repo: String, +cl: Nat, json: List<&2, U32>) -> IO(File & RwAc):
  rw.wt.put(Bool.and(Nat.is_lt(0n, cap), Nat.is_lt(cap, Nat.add(v, cl))), out, per, v, n, b, capped, cands, repo, cl, json)

def rw.wt.got(out: File, r: Map<&2, Nat> & Nat, +n: Nat, +b: Nat, +capped: Nat, +cands: Nat, +cap: Nat, +repo: String, +cl: Nat, json: List<&2, U32>) -> IO(File & RwAc):
  (per, v) = r
  rw.wt.v(out, per, v, n, b, capped, cands, cap, repo, cl, json)

def rw.wt.one(dropped: Bool, out: File, ac: RwAc, +cap: Nat, +repo: String, +cl: Nat, json: List<&2, U32>) -> IO(File & RwAc):
  match dropped ac:
    case True{} a:
      IO.pure(File & RwAc, (out, a))
    case False{} RwAc{per, n, b, capped, cands}:
      rw.wt.got(out, Map.get(Nat, 0n, per, repo), n, b, capped, cands, cap, repo, cl, json)

# ORDER TAB POS TAB CPS TAB REPO TAB LINE
def rw.wt.line(+drop: Set(), +cap: Nat, +l: List<&2, U32>, st: File & RwAc) -> IO(File & RwAc):
  (out, ac) = st
  +r1 = L.v2.after(l, 9)
  +r2 = L.v2.after(r1, 9)
  +r3 = L.v2.after(r2, 9)
  rw.wt.one(L.v2.in(drop, S.str(L.v2.before(r1, 9))), out, ac, cap, S.str(L.v2.before(r3, 9)), rw.nat(L.v2.before(r2, 9), 0n), L.v2.after(r3, 9))

def rw.wt.lines(+drop: Set(), +cap: Nat, ls: List<&2, List<&2, U32>>, st: File & RwAc) -> IO(File & RwAc):
  match ls:
    case Nil{}:
      IO.pure(File & RwAc, st)
    case +l <> more:
      IO.bind(File & RwAc, File & RwAc, rw.wt.line(drop, cap, l, st), rw.wt.lines(drop, cap, more))

# one id's lines by their texts
type RwGl is Data:
  RwGl{text: List<&2, U32>, line: List<&2, U32>}

def rw.gl.text(m: Maybe<&2, J.Doc>) -> List<&2, U32>:
  match m:
    case Some{J.Doc{i, t}}:
      t
    case None{}:
      Nil{}

def rw.gl.of(ls: List<&2, List<&2, U32>>) -> List<&2, RwGl>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      RwGl{rw.gl.text(J.doc(L.v2.after(L.v2.after(L.v2.after(L.v2.after(l, 9), 9), 9), 9))), l} <> rw.gl.of(more)

def rw.gl.le(a: RwGl, b: RwGl) -> Bool:
  match a b:
    case RwGl{+x, l} RwGl{+y, m}:
      rw.le(x, y)

def rw.gl.lines(gs: List<&2, RwGl>) -> List<&2, List<&2, U32>>:
  match gs:
    case Nil{}:
      Nil{}
    case RwGl{t, l} <> more:
      l <> rw.gl.lines(more)

def rw.grp.order(grp: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match grp:
    case Nil{}:
      Nil{}
    case l <> Nil{}:
      [l]
    case l <> more:
      rw.gl.lines(List.sort(~RwGl, ~rw.gl.le, rw.gl.of(l <> more)))

type RwWt is Type:
  RwWt{rd: S.Rd, out: File, cur: List<&2, U32>, grp: List<&2, List<&2, U32>>, ac: RwAc, go: Bool}

def rw.wt.new(rd: S.Rd, h: List<&2, U32>, l: List<&2, U32>, r: File & RwAc) -> IO(RwWt):
  (out, ac) = r
  IO.pure(RwWt, RwWt{rd, out, h, [l], ac, True{}})

def rw.wt.stop(rd: S.Rd, r: File & RwAc) -> IO(RwWt):
  (out, ac) = r
  IO.pure(RwWt, RwWt{rd, out, Nil{}, Nil{}, ac, False{}})

def rw.wt.next(same: Bool, rd: S.Rd, out: File, cur: List<&2, U32>, grp: List<&2, List<&2, U32>>, ac: RwAc, +drop: Set(), +cap: Nat, l: List<&2, U32>, h: List<&2, U32>) -> IO(RwWt):
  match same:
    case True{}:
      IO.pure(RwWt, RwWt{rd, out, cur, l <> grp, ac, True{}})
    case False{}:
      do IO<RwWt>:
        r : File & RwAc <- rw.wt.lines(drop, cap, rw.grp.order(grp), (out, ac))
        rw.wt.new(rd, h, l, r)

def rw.wt.rec(rd: S.Rd, out: File, +cur: List<&2, U32>, grp: List<&2, List<&2, U32>>, ac: RwAc, +drop: Set(), +cap: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(RwWt):
  match m:
    case None{}:
      do IO<RwWt>:
        r : File & RwAc <- rw.wt.lines(drop, cap, rw.grp.order(grp), (out, ac))
        rw.wt.stop(rd, r)
    case Some{+l}:
      +h = List.take(&2, U32, l, 64n)
      rw.wt.next(S.eq(h, cur), rd, out, cur, grp, ac, drop, cap, l, h)

def rw.wt.read(out: File, +cur: List<&2, U32>, grp: List<&2, List<&2, U32>>, ac: RwAc, +drop: Set(), +cap: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RwWt):
  (rd, m) = x
  rw.wt.rec(rd, out, cur, grp, ac, drop, cap, m)

def rw.wt.step(+drop: Set(), +cap: Nat, s: RwWt) -> IO(RwWt):
  match s:
    case RwWt{rd, out, +cur, grp, ac, g}:
      do IO<RwWt>:
        x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        rw.wt.read(out, cur, grp, ac, drop, cap, x)

def rw.wt.go(fuel: Nat, +drop: Set(), +cap: Nat, s: RwWt) -> IO(RwWt):
  match fuel s:
    case 1n+f RwWt{rd, out, cur, grp, ac, True{}}:
      IO.bind(RwWt, RwWt, rw.wt.step(drop, cap, RwWt{rd, out, cur, grp, ac, True{}}), rw.wt.go(f, drop, cap))
    case _ RwWt{rd, out, cur, grp, ac, g}:
      IO.pure(RwWt, RwWt{rd, out, cur, grp, ac, g})

# Python's `{b / 1e6:8.1f}`, in tenths: b/1e5 rounded to nearest; at an exact
# midpoint b/1e6 is m/20 (m = 2q + 1), and the double nearest it decides:
# when 5 divides m it is m/20 itself and the tie goes to even, otherwise it
# lies above m/20 when m * 2^s mod 20 > 10, s = 52 - floor(log2(m/20)) (the
# double's 53-bit significand is m * 2^s / 20 rounded)
# floor(log2(m/20)) for m >= 20: e with 20 * 2^e <= m < 40 * 2^e (p is
# 20 * 2^e; up: 2p <= m)
def rw.log2.go(fuel: Nat, +m: Nat, +p: Nat, +e: Nat, up: Bool) -> Nat:
  match fuel up:
    case 1n+f True{}:
      rw.log2.go(f, m, Nat.mul(2n, p), 1n+e, Nat.is_le(Nat.mul(4n, p), m))
    case _ _:
      e

def rw.pow2.mod20(k: Nat, +acc: Nat) -> Nat:
  match k:
    case 0n:
      acc
    case 1n+(+j):
      rw.pow2.mod20(j, Nat.mod(Nat.mul(2n, acc), 20n))

# for m < 20: the k with 20 <= m * 2^k < 40 (p is m * 2^k; up: p < 20)
def rw.log2.lo(fuel: Nat, +p: Nat, +k: Nat, up: Bool) -> Nat:
  match fuel up:
    case 1n+f True{}:
      rw.log2.lo(f, Nat.mul(2n, p), 1n+k, Nat.is_lt(Nat.mul(2n, p), 20n))
    case _ _:
      k

# s = 52 - floor(log2(m/20)), so m * 2^s / 20 is in [2^52, 2^53)
def rw.above(+m: Nat) -> Bool:
  +s = Bool.pick(Nat, Nat.is_lt(m, 20n), Nat.add(52n, rw.log2.lo(64n, m, 0n, Nat.is_lt(m, 20n))), Nat.sub(52n, rw.log2.go(64n, m, 20n, 0n, Nat.is_le(40n, m))))
  Nat.is_lt(10n, Nat.mod(Nat.mul(Nat.mod(m, 20n), rw.pow2.mod20(s, 1n)), 20n))

def rw.tie(+q: Nat) -> Nat:
  +m = {1n+Nat.mul(2n, q) : Nat}
  Bool.pick(Nat, Nat.is_eq(Nat.mod(m, 5n), 0n), Nat.add(q, Nat.mod(q, 2n)), Bool.pick(Nat, rw.above(m), 1n+q, q))

def rw.tenths(+b: Nat) -> Nat:
  +q = Nat.div(b, 100000n)
  +r2 = Nat.mul(2n, Nat.mod(b, 100000n))
  Bool.pick(Nat, Nat.is_lt(r2, 100000n), q, Bool.pick(Nat, Nat.is_lt(100000n, r2), 1n+q, rw.tie(q)))

def rw.mb(+b: Nat) -> String:
  +t = rw.tenths(b)
  Nat.show(Nat.div(t, 10n)) ++ "." ++ Nat.show(Nat.mod(t, 10n))

def rw.pad.l(+s: String, +w: Nat) -> String:
  rw.spaces(Nat.sub(w, String.length(s))) ++ s

def rw.pad.r(+s: String, +w: Nat) -> String:
  s ++ rw.spaces(Nat.sub(w, String.length(s)))

# the counted reasons, `name count`, in sorted order (code k on)
def rw.reasons(cs: List<&2, Nat>, +k: Nat, +capped: Nat) -> List<&2, String>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> more:
      +v = Bool.pick(Nat, Nat.is_eq(k, 6n), capped, c)
      +rest = rw.reasons(more, 1n+k, capped)
      Bool.pick(List<&2, String>, Bool.and(Nat.is_lt(k, 7n), Nat.is_lt(0n, v)), (rw.reason(k) ++ " " ++ Nat.show(v)) <> rest, rest)

def rw.join(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> Nil{}:
      x
    case x <> more:
      x ++ ", " ++ rw.join(more)

def rw.nums(ls: List<&2, List<&2, U32>>) -> List<&2, Nat>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      rw.nat(l, 0n) <> rw.nums(more)

def rw.summary(+lang: String, +n: Nat, +b: Nat, +capped: Nat, +counts: List<&2, U32>) -> String:
  rw.pad.r(lang, 8n) ++ " kept " ++ rw.pad.l(Nat.show(n), 7n) ++ " files " ++ rw.pad.l(rw.mb(b), 8n) ++ " MB; "
    ++ rw.join(rw.reasons(rw.nums(S.split.lines(counts)), 0n, capped))

def rw.wt.sum(none: Bool, +lang: String, +w: String, +out: String, line: String) -> IO(Unit):
  match none:
    case True{}:
      do IO<Unit>:
        S.rm(out ++ "/" ++ lang ++ ".jsonl")
        S.write(w ++ "/" ++ lang ++ ".summary", Nil{})
    case False{}:
      S.write(w ++ "/" ++ lang ++ ".summary", S.b(line))

def rw.wt.fin(+lang: String, +w: String, +out: String, +counts: List<&2, U32>, s: RwWt) -> IO(Unit):
  match s:
    case RwWt{rd, o, cur, grp, RwAc{per, +n, +b, +capped, +cands}, g}:
      do IO<Unit>:
        S.Rd.close(rd)
        File.close(o)
        rw.wt.sum(Nat.is_eq(cands, 0n), lang, w, out, rw.summary(lang, n, b, capped, counts))
        rw.log("raw: " ++ lang ++ ": " ++ Nat.show(n) ++ " kept of " ++ Nat.show(cands))

# `raw --write LANG W OUT`
def rw.write(+lang: String, +w: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    dl : List<&2, U32> <- S.read(w ++ "/drop")
    +cl : List<&2, U32> <- S.read(w ++ "/" ++ lang ++ ".counts")
    rd : S.Rd <- S.Rd.lines(w ++ "/" ++ lang ++ ".sorted")
    o : File <- IO.try(File, File.open(out ++ "/" ++ lang ++ ".jsonl", "w"))
    s : RwWt <- rw.wt.go(rw.big(), Set.from_list(L.v2.lines.str(S.split.lines(dl))), rw.cap(lang), RwWt{rd, o, Nil{}, Nil{}, RwAc{Map.new(&2, Nat), 0n, 0n, 0n, 0n}, True{}})
    rw.wt.fin(lang, w, out, cl, s)

# split-nul ------------------------------------------------------------------------
#
# `split-nul SRC PRE N`: the k = (NUL bytes)/2 whole (id, text) records of the
# NUL file SRC into N shards PRE.0.in.nul .. PRE.(N-1).in.nul, record j into
# shard j*N/k, every shard created (render.sh's Python).

# the NUL bytes of a file, a chunk at a time
type RwCn is Type:
  RwCn{f: File, n: Nat, go: Bool}

def rw.zs(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      rw.zs(t, Bool.pick(Nat, U32.is_eq(h, 0), 1n+acc, acc))

def rw.cn.got(+n: Nat, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(RwCn):
  (f, x) = r
  do IO<RwCn>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return RwCn{f, rw.zs(xs, n), Bool.not(Nat.is_eq(S.len(xs), 0n))}

def rw.cn.step(s: RwCn) -> IO(RwCn):
  match s:
    case RwCn{f, +n, g}:
      do IO<RwCn>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, S.chunk())
        rw.cn.got(n, r)

def rw.cn.go(fuel: Nat, s: RwCn) -> IO(Nat):
  match fuel s:
    case 1n+p RwCn{f, n, True{}}:
      IO.bind(RwCn, Nat, rw.cn.step(RwCn{f, n, True{}}), rw.cn.go(p))
    case _ RwCn{f, n, g}:
      do IO<Nat>:
        File.close(f)
        return n

def rw.fields(+path: String) -> IO(Nat):
  do IO<Nat>:
    f : File <- IO.try(File, File.open(path, "r"))
    rw.cn.go(rw.big(), RwCn{f, 0n, True{}})

def rw.sn.shard(+pre: String, +s: Nat) -> String:
  pre ++ "." ++ Nat.show(s) ++ ".in.nul"

def rw.sn.create(+pre: String, k: Nat) -> IO(Unit):
  match k:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+(+j):
      do IO<Unit>:
        S.write(rw.sn.shard(pre, j), Nil{})
        rw.sn.create(pre, j)

def rw.sn.text(+pre: String, +s: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(S.Rd):
  (rd, m) = x
  match m:
    case None{}:
      do IO<S.Rd>:
        S.Rd.close(rd)
        IO.die(S.Rd, 1, "split-nul: the file ended inside a record")
    case Some{t}:
      do IO<S.Rd>:
        S.add(rw.sn.shard(pre, s), L.v2.concat([id, [0], t, [0]]))
        return rd

def rw.sn.id(+pre: String, +s: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(S.Rd):
  (rd, m) = x
  match m:
    case None{}:
      do IO<S.Rd>:
        S.Rd.close(rd)
        IO.die(S.Rd, 1, "split-nul: the file ended inside a record")
    case Some{+i}:
      do IO<S.Rd>:
        y : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        rw.sn.text(pre, s, i, y)

def rw.sn.one(+pre: String, +s: Nat, rd: S.Rd) -> IO(S.Rd):
  do IO<S.Rd>:
    x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
    rw.sn.id(pre, s, x)

# r records left of k, into n shards
def rw.sn.go(r: Nat, +k: Nat, +n: Nat, +pre: String, rd: S.Rd) -> IO(S.Rd):
  match r:
    case 0n:
      IO.pure(S.Rd, rd)
    case 1n+(+f):
      IO.bind(S.Rd, S.Rd, rw.sn.one(pre, Nat.div(Nat.mul(Nat.sub(k, 1n+f), n), k), rd), rw.sn.go(f, k, n, pre))

def rw.sn.run(+src: String, +pre: String, +n: Nat) -> IO(Unit):
  do IO<Unit>:
    +fs : Nat <- rw.fields(src)
    rw.sn.create(pre, n)
    rd : S.Rd <- S.Rd.open(src)
    r2 : S.Rd <- rw.sn.go(Nat.div(fs, 2n), Nat.div(fs, 2n), n, pre, rd)
    S.Rd.close(r2)

def rw.split.nul.n(+src: String, +pre: String, m: Maybe<&2, Nat>) -> IO(Unit):
  match m:
    case Some{+n}:
      rw.sn.run(src, pre, n)
    case None{}:
      IO.die(Unit, 2, "split-nul: N is not a number")

# `split-nul SRC PRE N`
def rw.split.nul(xs: List<String>) -> IO(Unit):
  match xs:
    case src <> pre <> n <> Nil{}:
      rw.split.nul.n(src, pre, Nat.read(n))
    case _:
      IO.die(Unit, 2, "usage: split-nul SRC PRE N")

# slice --------------------------------------------------------------------------------
#
# `slice SRC DST K SIZE` (rawshards.sh's and raw-stage.sh's Python): the
# lines of SRC (each with its newline) that start in [lo, hi) = [(K-1)*SIZE,
# K*SIZE), read until a line ends at or past hi; when the file ends before
# hi (the last slice) only whole 2,000-line parts are kept.  Prints
# `slice K N documents (the last)` (or `... documents ` before it).

# a line with its newline (none on a last line without one)
type RwCut is Data:
  RwCut{line: List<&2, U32>, rest: List<&2, U32>, hit: Bool}

def rw.cut.put(h: U32, c: RwCut) -> RwCut:
  match c:
    case RwCut{l, r, b}:
      RwCut{h <> l, r, b}

def rw.cut.go(xs: List<&2, U32>, at: Bool) -> RwCut:
  match xs at:
    case h <> t True{}:
      RwCut{[h], t, True{}}
    case h <> +t False{}:
      rw.cut.put(h, rw.cut.go(t, S.head.is(t, 10)))
    case Nil{} _:
      RwCut{Nil{}, Nil{}, False{}}

type RwLr is Type:
  RwLr{f: File, buf: List<&2, U32>, eof: Bool}

type RwLq is Type:
  RwLq{f: File, buf: List<&2, U32>, eof: Bool, more: Bool, got: Maybe<&2, List<&2, U32>>}

def rw.lr.filled(buf: List<&2, U32>, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(RwLq):
  (f, x) = r
  do IO<RwLq>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return RwLq{f, List.append(&2, U32, buf, xs), Nat.is_eq(List.length(&2, U32, xs), 0n), True{}, None{}}

def rw.lr.cut(f: File, eof: Bool, c: RwCut) -> IO(RwLq):
  match eof c:
    case _ RwCut{l, r, True{}}:
      IO.pure(RwLq, RwLq{f, r, eof, False{}, Some{l}})
    case True{} RwCut{Nil{}, r, False{}}:
      IO.pure(RwLq, RwLq{f, Nil{}, True{}, False{}, None{}})
    case True{} RwCut{l, r, False{}}:
      IO.pure(RwLq, RwLq{f, Nil{}, True{}, False{}, Some{l}})
    case False{} RwCut{l, r, False{}}:
      do IO<RwLq>:
        x : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, S.chunk())
        rw.lr.filled(l, x)

def rw.lr.try(q: RwLq) -> IO(RwLq):
  match q:
    case RwLq{f, +buf, eof, m, g}:
      rw.lr.cut(f, eof, rw.cut.go(buf, S.head.is(buf, 10)))

def rw.lr.go(fuel: Nat, q: RwLq) -> IO(RwLr & Maybe<&2, List<&2, U32>>):
  match fuel q:
    case 1n+p RwLq{f, buf, eof, True{}, g}:
      IO.bind(RwLq, RwLr & Maybe<&2, List<&2, U32>>, rw.lr.try(RwLq{f, buf, eof, True{}, g}), rw.lr.go(p))
    case _ RwLq{f, buf, eof, False{}, g}:
      IO.pure(RwLr & Maybe<&2, List<&2, U32>>, (RwLr{f, buf, eof}, g))
    case 0n RwLq{f, buf, eof, True{}, g}:
      do IO<RwLr & Maybe<&2, List<&2, U32>>>:
        File.close(f)
        IO.die(RwLr & Maybe<&2, List<&2, U32>>, 1, "slice: a line past 4 GiB")

def rw.lr.next(r: RwLr) -> IO(RwLr & Maybe<&2, List<&2, U32>>):
  match r:
    case RwLr{f, buf, eof}:
      rw.lr.go(4096n, RwLq{f, buf, eof, True{}, None{}})

# the slice so far: bytes read, lines kept, bytes kept, bytes kept at the
# last whole 2,000 lines
type RwSl is Type:
  RwSl{lr: RwLr, out: File, pos: Nat, n: Nat, wrote: Nat, cut: Nat, go: Bool}

# a line read: kept when it starts in [lo, hi) (inc); len its bytes, p2 the
# position after it
def rw.sl.keep(inc: Bool, lr: RwLr, out: File, +n: Nat, +wrote: Nat, +cut: Nat, +hi: Nat, +len: Nat, +p2: Nat, l: List<&2, U32>) -> IO(RwSl):
  match inc:
    case True{}:
      do IO<RwSl>:
        o2 : File <- S.emit(out, l)
        return RwSl{lr, o2, p2, 1n+n, Nat.add(wrote, len), Bool.pick(Nat, Nat.is_eq(Nat.mod(1n+n, 2000n), 0n), Nat.add(wrote, len), cut), Nat.is_lt(p2, hi)}
    case False{}:
      IO.pure(RwSl, RwSl{lr, out, p2, n, wrote, cut, Nat.is_lt(p2, hi)})

def rw.sl.got(out: File, +pos: Nat, +n: Nat, +wrote: Nat, +cut: Nat, +lo: Nat, +hi: Nat, x: RwLr & Maybe<&2, List<&2, U32>>) -> IO(RwSl):
  (lr, m) = x
  match m:
    case None{}:
      IO.pure(RwSl, RwSl{lr, out, pos, n, wrote, cut, False{}})
    case Some{+l}:
      +len = S.len(l)
      rw.sl.keep(Bool.and(Nat.is_le(lo, pos), Nat.is_lt(pos, hi)), lr, out, n, wrote, cut, hi, len, Nat.add(pos, len), l)

def rw.sl.step(+lo: Nat, +hi: Nat, s: RwSl) -> IO(RwSl):
  match s:
    case RwSl{lr, out, +pos, +n, +wrote, +cut, g}:
      do IO<RwSl>:
        x : RwLr & Maybe<&2, List<&2, U32>> <- rw.lr.next(lr)
        rw.sl.got(out, pos, n, wrote, cut, lo, hi, x)

def rw.sl.go(fuel: Nat, +lo: Nat, +hi: Nat, s: RwSl) -> IO(RwSl):
  match fuel s:
    case 1n+f RwSl{lr, out, pos, n, wrote, cut, True{}}:
      IO.bind(RwSl, RwSl, rw.sl.step(lo, hi, RwSl{lr, out, pos, n, wrote, cut, True{}}), rw.sl.go(f, lo, hi))
    case _ RwSl{lr, out, pos, n, wrote, cut, g}:
      IO.pure(RwSl, RwSl{lr, out, pos, n, wrote, cut, g})

def rw.sl.trim(trim: Bool, +dst: String, +cut: Nat) -> IO(Unit):
  match trim:
    case True{}:
      do IO<Unit>:
        o : List<&2, U32> <- S.must("truncate " ++ dst, "truncate", ["-s", Nat.show(cut), dst])
        return Unit{}
    case False{}:
      IO.pure(Unit, Unit{})

def rw.sl.fin(+dst: String, +k: Nat, +hi: Nat, s: RwSl) -> IO(Unit):
  match s:
    case RwSl{RwLr{f, buf, eof}, out, +pos, +n, wrote, +cut, g}:
      +last = Nat.is_lt(pos, hi)
      +trim = Bool.and(last, Nat.is_lt(0n, Nat.mod(n, 2000n)))
      do IO<Unit>:
        File.close(f)
        File.close(out)
        rw.sl.trim(trim, dst, cut)
        IO.print("slice " ++ Nat.show(k) ++ " " ++ Nat.show(Bool.pick(Nat, trim, Nat.sub(n, Nat.mod(n, 2000n)), n)) ++ " documents " ++ Bool.pick(String, last, "(the last)", ""))

# the slice of the stream inp, whose first byte is the file's byte off
def rw.sl.run(+inp: String, +dst: String, +k: Nat, +size: Nat, +off: Nat) -> IO(Unit):
  +lo = Nat.mul(Nat.sub(k, 1n), size)
  +hi = Nat.mul(k, size)
  do IO<Unit>:
    f : File <- IO.try(File, File.open(inp, "r"))
    o : File <- IO.try(File, File.open(dst, "w"))
    s : RwSl <- rw.sl.go(rw.big(), lo, hi, RwSl{RwLr{f, Nil{}, False{}}, o, off, 0n, 0n, 0n, Nat.is_lt(off, hi)})
    rw.sl.fin(dst, k, hi, s)

# Slice K >= 2 starts at lo - 1 (`tail -c` seeks there; a line starting
# there or past it is read as Python read it, and the line that byte ends or
# lies in starts before lo, so it is passed over either way); its output is
# this process's
def rw.sl.out(+o: S.Out) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(S.Out.status(o), 0), IO.print(S.str(S.chomp(S.Out.text(o)))),
    IO.die(Unit, 1, "slice: " ++ S.str(S.chomp(S.Out.text(o)))))

def rw.sl.skip(+self: String, +src: String, +dst: String, +k: Nat, +size: Nat) -> IO(Unit):
  +lo = Nat.mul(Nat.sub(k, 1n), size)
  do IO<Unit>:
    +o : S.Out <- S.run(".", [], rw.forever(), "sh", ["-c", "[ -r \"$2\" ] || { echo \"cannot read $2\"; exit 1; }; tail -c +\"$1\" \"$2\" 2>/dev/null | \"$3\" \"$4\" --slice-at \"$5\" /dev/stdin \"$6\" \"$7\" \"$8\"",
      "sh", Nat.show(lo), src, self, rw.cmd(), Nat.show(Nat.sub(lo, 1n)), dst, Nat.show(k), Nat.show(size)], Nil{})
    rw.sl.out(o)

def rw.sl.at(first: Bool, +self: String, +src: String, +dst: String, +k: Nat, +size: Nat) -> IO(Unit):
  match first:
    case True{}:
      rw.sl.run(src, dst, k, size, 0n)
    case False{}:
      rw.sl.skip(self, src, dst, k, size)

def rw.slice.n(+self: String, +src: String, +dst: String, k: Maybe<&2, Nat>, size: Maybe<&2, Nat>) -> IO(Unit):
  match k size:
    case Some{+a} Some{+b}:
      rw.sl.at(Nat.is_le(a, 1n), self, src, dst, a, b)
    case _ _:
      IO.die(Unit, 2, "slice: K and SIZE are numbers")

def rw.slice.args(xs: List<String>, +self: String) -> IO(Unit):
  match xs:
    case src <> dst <> k <> size <> Nil{}:
      rw.slice.n(self, src, dst, Nat.read(k), Nat.read(size))
    case _:
      IO.die(Unit, 2, "usage: slice SRC DST K SIZE")

# `slice SRC DST K SIZE`
def rw.slice(xs: List<String>) -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    rw.slice.args(xs, rw.head(argv))

def rw.slice.at.n(+inp: String, +dst: String, off: Maybe<&2, Nat>, k: Maybe<&2, Nat>, size: Maybe<&2, Nat>) -> IO(Unit):
  match off k size:
    case Some{+o} Some{+a} Some{+b}:
      rw.sl.run(inp, dst, a, b, o)
    case _ _ _:
      IO.die(Unit, 2, "slice: OFF, K and SIZE are numbers")

# The driver ---------------------------------------------------------------------------

def rw.sources() -> List<String>:
  ["run/code-train-v3.jsonl",
   "run/raw-new/haskell.jsonl", "run/raw-new/haskell-2.jsonl", "run/raw-new/agda-f.jsonl", "run/raw-new/agda-2f.jsonl",
   "run/raw-new/lean.jsonl", "run/raw-new/lean-2.jsonl", "run/raw-new/bend.jsonl"]

# a job for the pool: a source's chunk K of N scanned, or a language sorted
# and written
type RwJ is Type:
  RwScan{pp: String, src: String, k: Nat, n: Nat, pre: String}
  RwLang{lang: String}

def rw.scan.sh() -> String:
  "set -o pipefail; split -n \"l/$1/$2\" \"$3\" | \"$4\" \"$5\" --scan \"$6\" /dev/stdin \"$7\""

def rw.lang.sh() -> String:
  "set -e; sort -S 1G -T \"$1\" -o \"$1/$2.sorted\" \"$1\"/*.\"$2\"; rm -f \"$1\"/*.\"$2\"; \"$3\" \"$4\" --write \"$2\" \"$1\" \"$5\"; rm -f \"$1/$2.sorted\""

def rw.job.run(+self: String, +w: String, +out: String, j: RwJ) -> IO(Bool):
  match j:
    case RwScan{pp, src, k, n, +pre}:
      do IO<Bool>:
        +st : U32 <- S.run.log(".", ["LC_ALL=C"], rw.forever(), "sh", ["-c", rw.scan.sh(), "sh", Nat.show(k), Nat.show(n), src, self, rw.cmd(), pp, pre], pre ++ ".log")
        return U32.is_eq(st, 0)
    case RwLang{+lang}:
      do IO<Bool>:
        +st : U32 <- S.run.log(".", ["LC_ALL=C"], rw.forever(), "sh", ["-c", rw.lang.sh(), "sh", w, lang, self, rw.cmd(), out], w ++ "/" ++ lang ++ ".log")
        return U32.is_eq(st, 0)

type RwPw is Type:
  RwPw{go: Bool, bad: Nat}

def rw.pw.got(+self: String, +w: String, +out: String, m: Maybe<&1, RwJ>, +bad: Nat) -> IO(RwPw):
  match m:
    case None{}:
      IO.pure(RwPw, RwPw{False{}, bad})
    case Some{j}:
      do IO<RwPw>:
        +ok : Bool <- rw.job.run(self, w, out, j)
        return RwPw{True{}, Nat.add(bad, Bool.pick(Nat, ok, 0n, 1n))}

def rw.pw.step(+self: String, +w: String, +out: String, +q: Chan(RwJ), p: RwPw) -> IO(RwPw):
  match p:
    case RwPw{g, +bad}:
      do IO<RwPw>:
        m : Maybe<&1, RwJ> <- Chan.recv(RwJ, q)
        rw.pw.got(self, w, out, m, bad)

def rw.pw.go(fuel: Nat, +self: String, +w: String, +out: String, +q: Chan(RwJ), p: RwPw) -> IO(Nat):
  match fuel p:
    case 1n+f RwPw{True{}, bad}:
      IO.bind(RwPw, Nat, rw.pw.step(self, w, out, q, RwPw{True{}, bad}), rw.pw.go(f, self, w, out, q))
    case _ RwPw{g, bad}:
      IO.pure(Nat, bad)

def rw.pw.fork(n: Nat, +self: String, +w: String, +out: String, +q: Chan(RwJ)) -> IO(List<Chan(Nat)>):
  match n:
    case 0n:
      IO.pure(List<Chan(Nat)>, Nil{})
    case 1n+m:
      do IO<List<Chan(Nat)>>:
        ch : Chan(Nat) <- IO.fork(Nat, rw.pw.go(rw.big(), self, w, out, q, RwPw{True{}, 0n}))
        rest : List<Chan(Nat)> <- rw.pw.fork(m, self, w, out, q)
        return ch <> rest

def rw.pw.join(chs: List<Chan(Nat)>, +bad: Nat) -> IO(Nat):
  match chs:
    case Nil{}:
      IO.pure(Nat, bad)
    case +ch <> more:
      do IO<Nat>:
        +b : Nat <- IO.join(Nat, ch)
        rw.pw.join(more, Nat.add(bad, b))

def rw.pw.send(js: List<RwJ>, +q: Chan(RwJ)) -> IO(Unit):
  match js:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case j <> more:
      do IO<Unit>:
        ok : Result<&1, &1, RwJ, Unit> <- Chan.send(RwJ, q, j)
        rw.pw.send(more, q)

# the jobs run by `jobs` workers; the answer is how many failed
def rw.pool(+self: String, +w: String, +out: String, js: List<RwJ>, +jobs: Nat) -> IO(Nat):
  do IO<Nat>:
    +q : Chan(RwJ) <- Chan.new(RwJ, U32.from_nat(jobs))
    chs : List<Chan(Nat)> <- rw.pw.fork(jobs, self, w, out, q)
    rw.pw.send(js, q)
    Chan.close(RwJ, q)
    rw.pw.join(chs, 0n)

def rw.chunks(r: Nat, +n: Nat, +w: String, +src: String, +si: Nat) -> List<RwJ>:
  match r:
    case 0n:
      Nil{}
    case 1n+(+j):
      +k = Nat.sub(n, j)
      RwScan{rw.pad(si, 2n) ++ rw.pad(k, 3n), src, k, n, w ++ "/" ++ rw.pad(si, 2n) ++ "." ++ rw.pad(k, 3n)} <> rw.chunks(j, n, w, src, si)

def rw.nchunks(+size: Nat, +ch: Nat) -> Nat:
  Nat.max(1n, Nat.div(Nat.add(size, Nat.sub(ch, 1n)), ch))

# the scan jobs: each source cut into chunks of about ch bytes
def rw.plan(+w: String, +ch: Nat, srcs: List<String>, +si: Nat) -> IO(List<RwJ>):
  match srcs:
    case Nil{}:
      IO.pure(List<RwJ>, Nil{})
    case +s <> more:
      do IO<List<RwJ>>:
        o : List<&2, U32> <- S.must("stat " ++ s, "stat", ["-L", "-c", "%s", s])
        +n : Nat <- IO.pure(Nat, rw.nchunks(rw.num(o), ch))
        rw.log("raw: " ++ s ++ ": " ++ Nat.show(n) ++ " chunks")
        rest : List<RwJ> <- rw.plan(w, ch, more, 1n+si)
        return List.append(&1, RwJ, rw.chunks(n, n, w, s, si), rest)

def rw.ok(+bad: Nat, +what: String) -> IO(Unit):
  Bool.pick(IO(Unit), Nat.is_eq(bad, 0n), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "raw: " ++ Nat.show(bad) ++ " " ++ what ++ " failed (their .log files are in the work directory)"))

def rw.langs.all() -> List<RwJ>:
  [RwLang{"haskell"}, RwLang{"lean"}, RwLang{"agda"}, RwLang{"bend"}, RwLang{"nix"}]

# the summary lines of the languages that kept a file, in their names' order
def rw.sum.lines(+w: String, k: Nat, +i: Nat) -> IO(List<&2, List<&2, U32>>):
  match k:
    case 0n:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case 1n+(+j):
      do IO<List<&2, List<&2, U32>>>:
        +x : List<&2, U32> <- S.read(w ++ "/" ++ rw.lang.name(i) ++ ".summary")
        +rest : List<&2, List<&2, U32>> <- rw.sum.lines(w, j, 1n+i)
        return Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(x), 0n), rest, x <> rest)

def rw.sorted.idx(+w: String) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], rw.forever(), "sh", ["-c", "set -e; sort -S 2G -T \"$1\" -o \"$1/idx\" \"$1\"/*.idx; rm -f \"$1\"/*.idx", "sh", w], Nil{})
    rw.ok(U32.to_nat(S.Out.status(o)), "index sorts")

def rw.say(+text: List<&2, U32>) -> IO(Unit):
  match text:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case t <> more:
      IO.print(S.str(S.chomp(t <> more)))

# `raw [OUT [SRC...]]`
def rw.main(+out: String, srcs: List<String>, +self: String) -> IO(Unit):
  do IO<Unit>:
    +w : String <- IO.pure(String, out ++ "/.rw-work")
    S.mkdir(out)
    S.rm(w)
    S.mkdir(w)
    +jobs : Nat <- S.env.nat("JOBS", 5n)
    +ch : Nat <- S.env.nat("RAW_CHUNK", 150000000n)
    js : List<RwJ> <- rw.plan(w, ch, srcs, 0n)
    rw.log("raw: scanning, " ++ Nat.show(jobs) ++ " chunks at once")
    b1 : Nat <- rw.pool(self, w, out, js, jobs)
    rw.ok(b1, "scans")
    rw.log("raw: scanned; sorting the index")
    rw.sorted.idx(w)
    rw.decide(w)
    rw.log("raw: copies decided; writing the languages")
    b2 : Nat <- rw.pool(self, w, out, rw.langs.all(), jobs)
    rw.ok(b2, "languages")
    ls : List<&2, List<&2, U32>> <- rw.sum.lines(w, 5n, 0n)
    +text : List<&2, U32> <- IO.pure(List<&2, U32>, S.append(S.join(ls, 10), [10]))
    S.write(out ++ "/summary.txt", text)
    rw.say(text)
    S.rm(w)

def rw.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: raw [OUT [SRC...]] | raw --scan POS INPUT PRE | raw --write LANG WORK OUT | raw --slice-at OFF INPUT DST K SIZE")

def rw.srcs.or(xs: List<String>) -> List<String>:
  match xs:
    case Nil{}:
      rw.sources()
    case h <> t:
      h <> t

# the internal modes: 0 --scan, 1 --write, 2 --slice-at (slice's skip), 3
# none (OUT), 4 another flag
def rw.mode(+c: String) -> Nat:
  Bool.pick(Nat, String.eq(c, "--scan"), 0n, Bool.pick(Nat, String.eq(c, "--write"), 1n, Bool.pick(Nat, String.eq(c, "--slice-at"), 2n,
    Bool.pick(Nat, S.prefix(S.b(c), [45]), 4n, 3n))))

def rw.raw.sub(mode: Nat, +c: String, more: List<String>, +self: String) -> IO(Unit):
  match mode more:
    case 0n pp <> inp <> pre <> Nil{}:
      rw.scan(pp, inp, pre)
    case 1n l <> w <> o <> Nil{}:
      rw.write(l, w, o)
    case 2n off <> inp <> dst <> k <> size <> Nil{}:
      rw.slice.at.n(inp, dst, Nat.read(off), Nat.read(k), Nat.read(size))
    case 3n srcs:
      rw.main(c, rw.srcs.or(srcs), self)
    case _ _:
      rw.usage()

def rw.raw.args(xs: List<String>, +self: String) -> IO(Unit):
  match xs:
    case Nil{}:
      rw.main("run/v2/raw", rw.sources(), self)
    case +c <> more:
      rw.raw.sub(rw.mode(c), c, more, self)

def rw.raw.self(argv: List<String>) -> String:
  rw.head(argv)

# the `raw` subcommand (xs: its arguments); the program as invoked (the
# head of IO.args) is what the scanners and writers are started as
def rw.raw(xs: List<String>) -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    rw.raw.args(xs, rw.raw.self(argv))
