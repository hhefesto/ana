import Base
import ../Sys.bend as S
import ../Json.bend as J
import ../Sha256.bend as H
import ./Lib.bend as L

# Corpus v2's holdout tools (docs/CORPUS-V2.md, C3), byte for byte the old
# tools/corpus-v2/{stream_index,vault,holdout,exclude}.py:
#
#   stream-index [DIR]    DIR/holdout/stream-index.json: every repository each
#                         training stream of run 1 holds (folded names, sorted)
#   vault [DIR]           the vault: up to 150 repositories per language no
#                         training stream holds (>= 3 files, chosen by
#                         sha256(name)): DIR/vault/{agda,lean,haskell}.jsonl and
#                         DIR/holdout/vault.tsv
#   holdout [DIR]         the split and the exclusion lists:
#                         DIR/holdout/{units.tsv,exclude.paths,exclude.sha256,summary.txt}
#   exclude IN OUT [DIR]  IN (JSONL, or NUL id/text pairs) less every record
#                         DIR/holdout holds out
#
# DIR is run/v2. Run from the repository root (the sources are run/'s).
#
# A Bend process evaluates on one thread, so the tools fan out: the binary
# runs itself (`ho-part`, argv[0] or $HO_SELF) on HO_JOBS (5) pieces at a
# time, a JSONL file cut into byte ranges (a line belongs to the range its
# first byte is in), a NUL file whole, and reduces their part files, sorted
# by coreutils `sort` in byte order (Python's order for UTF-8 text). The gzipped pools are inflated (`gzip -dc`) into a
# temporary directory (mktemp -d, under $TMPDIR) first; it is removed at
# the end. `ho-part` is internal: the binary's dispatcher must route it to
# ho.part.
#
# Where the port refuses what Python would take: an input of 4 GiB or more
# (the reads are 32-bit), and an id holding a TAB or a newline (the part
# files are TAB separated lines). Python's `.1%` and `.1f` round the float;
# here the exact quotient is rounded half to even, which differs only on an
# exact tie.
#
# Every def here starts with `ho.`: a Bend program's defs share one
# namespace across its imports.

# Small things -------------------------------------------------------------------

def ho.big() -> Nat:
  U32.to_nat(4294967295)

def ho.range() -> Nat:
  134217728n

# a read: 8 MiB (1 MiB reads made a long scan slower and slower)
def ho.chunk() -> U32:
  8388608

def ho.zeros(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      48 <> ho.zeros(k)

def ho.spaces(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      32 <> ho.spaces(k)

def ho.dec(+n: Nat) -> List<&2, U32>:
  S.b(Nat.show(n))

# n in decimal, zero-padded to w digits
def ho.dec.w(+n: Nat, +w: Nat) -> List<&2, U32>:
  +d = ho.dec(n)
  List.append(&2, U32, ho.zeros(Nat.sub(w, S.len(d))), d)

# Python's `{:<w}` and `{:>w}` (ASCII text)
def ho.left(+xs: List<&2, U32>, +w: Nat) -> List<&2, U32>:
  List.append(&2, U32, xs, ho.spaces(Nat.sub(w, S.len(xs))))

def ho.right(+xs: List<&2, U32>, +w: Nat) -> List<&2, U32>:
  List.append(&2, U32, ho.spaces(Nat.sub(w, S.len(xs))), xs)

def ho.num.go(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      ho.num.go(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48))))

def ho.num(xs: List<&2, U32>) -> Nat:
  ho.num.go(xs, 0n)

def ho.is.nil(+xs: List<&2, U32>) -> Bool:
  Nat.is_eq(S.len(xs), 0n)

def ho.join(xss: List<&2, List<&2, U32>>, +sep: List<&2, U32>) -> List<&2, U32>:
  match xss:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      x
    case x <> more:
      L.v2.concat([x, sep, ho.join(more, sep)])

def ho.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> ho.l1(more)

def ho.str.le(a: String, b: String) -> Bool:
  String.is_le(a, b)

def ho.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  S.split.lines(xs)

def ho.in(+s: Set(), +k: List<&2, U32>) -> Bool:
  L.v2.in(s, S.str(k))

def ho.cont(+h: U32) -> Bool:
  U32.is_eq(U32.and(h, 192), 128)

# the code points of UTF-8 text (Python's len)
def ho.cps.go(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      ho.cps.go(t, Bool.pick(Nat, ho.cont(h), n, 1n+n))

def ho.cps(xs: List<&2, U32>) -> Nat:
  ho.cps.go(xs, 0n)

# n / d rounded half to even (n / d in tenths: 10 n / d), as Python formats
# the quotient
# (exact ties aside, which the float may break either way)
def ho.tenths.of(+q: Nat, +r: Nat, +d: Nat) -> Nat:
  +twice = Nat.mul(2n, r)
  Bool.pick(Nat, Nat.is_lt(d, twice), 1n+q, Bool.pick(Nat, Bool.and(Nat.is_eq(twice, d), Nat.is_eq(Nat.mod(q, 2n), 1n)), 1n+q, q))

def ho.tenths(+n: Nat, +d: Nat) -> Nat:
  ho.tenths.of(Nat.div(n, d), Nat.mod(n, d), d)

def ho.fix1(+t: Nat) -> List<&2, U32>:
  L.v2.concat([ho.dec(Nat.div(t, 10n)), [46], ho.dec(Nat.mod(t, 10n))])

# JSON as Python's json.dump writes it (ensure_ascii): `"` `\` \b \f \n \r \t
# escaped, every other code point outside ' '..'~' as \uxxxx (a surrogate
# pair past U+FFFF)
def ho.hex4(+v: U32) -> List<&2, U32>:
  [J.hexc(U32.and(U32.shrn(v, 12n), 15)), J.hexc(U32.and(U32.shrn(v, 8n), 15)), J.hexc(U32.and(U32.shrn(v, 4n), 15)), J.hexc(U32.and(v, 15))]

def ho.ua(+c: U32, rest: List<&2, U32>) -> List<&2, U32>:
  92 <> 117 <> List.append(&2, U32, ho.hex4(c), rest)

def ho.asc.cp(+c: U32, +rest: List<&2, U32>) -> List<&2, U32>:
  +d = U32.sub(c, 65536)
  Bool.pick(List<&2, U32>, U32.is_lt(c, 128), J.esc.byte(c, rest),
    Bool.pick(List<&2, U32>, U32.is_lt(c, 65536), ho.ua(c, rest),
      ho.ua(U32.add(55296, U32.shrn(d, 10n)), ho.ua(U32.add(56320, U32.and(d, 1023)), rest))))

def ho.asc.go(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      [34]
    case SCon{Chr{+c}, t}:
      ho.asc.cp(c, ho.asc.go(t))

def ho.asc(+xs: List<&2, U32>) -> List<&2, U32>:
  34 <> ho.asc.go(S.str(xs))

# Commands ------------------------------------------------------------------------

def ho.ok.if(ok: Bool, +o: S.Out, +what: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, what ++ " failed (exit " ++ U32.show(S.Out.status(o)) ++ "): " ++ S.str(S.lines.take(S.Out.text(o), 20n)))

# a command that must succeed (env: K=V words)
def ho.sh(+what: String, env: List<String>, prog: String, args: List<String>) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run(".", env, 86400, prog, args, Nil{})
    ho.ok.if(U32.is_eq(S.Out.status(o), 0), o, what)

# files matching sh globs (as Python's glob: no hidden names), sorted
def ho.glob(+pats: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    o : List<&2, U32> <- S.must("glob " ++ pats, "sh", ["-c", "for f in " ++ pats ++ "; do if [ -e \"$f\" ] || [ -L \"$f\" ]; then printf '%s\\n' \"$f\"; fi; done"])
    return List.sort(~String, ~ho.str.le, L.v2.lines.str(ho.lines(o)))

# `sort` in byte order (Python's order of UTF-8 text) of the files ins into
# out (u: one of each line); nothing in, an empty out
def ho.sort(+tmp: String, +u: Bool, +out: String, ins: List<&2, String>) -> IO(Unit):
  match ins:
    case Nil{}:
      S.write(out, Nil{})
    case i <> more:
      ho.sh("sort " ++ out, ["LC_ALL=C"], "sort", List.append(&1, String, Bool.pick(List<String>, u, ["-u"], Nil{}),
        List.append(&1, String, ["-S", "1G", "--parallel=4", "-T", tmp, "-o", out], ho.l1(i <> more))))

def ho.gunzip(+out: String, ins: List<&2, String>) -> IO(Unit):
  ho.sh("gzip -dc into " ++ out, [], "sh", List.append(&1, String, ["-c", "o=$1; shift; exec gzip -dc -- \"$@\" > \"$o\"", "sh", out], ho.l1(ins)))

def ho.self.of(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      "bend-corpus-v2"
    case x <> more:
      x

# the binary to run the pieces with
def ho.self() -> IO(String):
  do IO<String>:
    argv : List<String> <- IO.args()
    +s : String <- S.env("HO_SELF", "")
    return Bool.pick(String, String.is_empty(s), ho.self.of(argv), s)

def ho.dir.of(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      "run/v2"
    case x <> more:
      x

# Scanning ------------------------------------------------------------------------
#
# A record: its head (a JSON line's bytes up to its id's closing quote; a
# NUL record's id), its offset and length in bytes (a line with its newline,
# a pair with both NULs) and its text's code points (Python's len). The
# scanners keep no text: a held-out file is read again by its offset.

type HoRec is Data:
  HoRec{head: List<&2, U32>, off: Nat, len: Nat, cp: Nat}

# The JSONL scanner between bytes: mode 0 reads the head (kept, reversed),
# 1 the rest, 2 skips to the next line (a range's start); nq the unescaped
# quotes so far, esc after a backslash, skip the hex digits of a \u escape
# still to pass, cp the text's characters so far (the text is the string
# after the 7th quote), start the line's offset, pos the next byte's; out
# the records ended (newest first).
type HoJs is Data:
  HoJs{mode: Nat, nq: Nat, esc: Bool, skip: Nat, acc: List<&2, U32>, cp: Nat, start: Nat, pos: Nat, out: List<&2, HoRec>}

type HoJr is Data:
  HoJr{nq: Nat, esc: Bool, skip: Nat, cp: Nat}

# 0 a newline that ends a record, 1 a head byte, 2 a rest byte, 3 the
# newline a skip ends at, 4 a skipped byte
def ho.j.code(+h: U32, +mode: Nat) -> Nat:
  Bool.pick(Nat, U32.is_eq(h, 10), Bool.pick(Nat, Nat.is_eq(mode, 2n), 3n, 0n),
    Bool.pick(Nat, Nat.is_eq(mode, 0n), 1n, Bool.pick(Nat, Nat.is_eq(mode, 1n), 2n, 4n)))

def ho.j.head(+h: U32, +nq: Nat, esc: Bool) -> Nat & Bool:
  match esc:
    case True{}:
      (nq, False{})
    case False{}:
      (Bool.pick(Nat, U32.is_eq(h, 34), 1n+nq, nq), U32.is_eq(h, 92))

def ho.j.head.fin(+h: U32, acc: List<&2, U32>, cp: Nat, start: Nat, pos: Nat, out: List<&2, HoRec>, r: Nat & Bool) -> HoJs:
  (+nq, esc) = r
  HoJs{Bool.pick(Nat, Nat.is_eq(nq, 4n), 1n, 0n), nq, esc, 0n, h <> acc, cp, start, 1n+pos, out}

# a rest byte: a \u escape's 4 hex digits count nothing, an escape one
# character (at its backslash), a byte one unless it continues a UTF-8
# sequence (only inside the text)
def ho.j.rest(+h: U32, +nq: Nat, esc: Bool, skip: Nat, +cp: Nat) -> HoJr:
  match esc skip:
    case _ 1n+k:
      HoJr{nq, False{}, k, cp}
    case True{} 0n:
      HoJr{nq, False{}, Bool.pick(Nat, U32.is_eq(h, 117), 4n, 0n), cp}
    case False{} 0n:
      +intext = Nat.is_eq(nq, 7n)
      +bs = U32.is_eq(h, 92)
      +qt = U32.is_eq(h, 34)
      HoJr{Bool.pick(Nat, qt, 1n+nq, nq), bs, 0n,
        Bool.pick(Nat, Bool.and(intext, Bool.and(Bool.not(qt), Bool.not(ho.cont(h)))), 1n+cp, cp)}

def ho.j.rest.fin(acc: List<&2, U32>, start: Nat, pos: Nat, out: List<&2, HoRec>, r: HoJr) -> HoJs:
  match r:
    case HoJr{nq, esc, skip, cp}:
      HoJs{1n, nq, esc, skip, acc, cp, start, 1n+pos, out}

def ho.j.act(code: Nat, +h: U32, +nq: Nat, e: Bool, k: Nat, acc: List<&2, U32>, +cp: Nat, +start: Nat, +pos: Nat, out: List<&2, HoRec>) -> HoJs:
  match code:
    case 0n:
      HoJs{0n, 0n, False{}, 0n, Nil{}, 0n, 1n+pos, 1n+pos, HoRec{List.reverse(&2, U32, acc), start, Nat.sub(1n+pos, start), cp} <> out}
    case 1n:
      ho.j.head.fin(h, acc, cp, start, pos, out, ho.j.head(h, nq, e))
    case 2n:
      ho.j.rest.fin(acc, start, pos, out, ho.j.rest(h, nq, e, k, cp))
    case 3n:
      HoJs{0n, 0n, False{}, 0n, Nil{}, 0n, 1n+pos, 1n+pos, out}
    case _:
      HoJs{2n, nq, e, k, acc, cp, start, 1n+pos, out}

def ho.j.step(+h: U32, s: HoJs) -> HoJs:
  match s:
    case HoJs{+m, nq, e, k, acc, cp, start, pos, out}:
      ho.j.act(ho.j.code(h, m), h, nq, e, k, acc, cp, start, pos, out)

def ho.j.scan(xs: List<&2, U32>, s: HoJs) -> HoJs:
  match xs:
    case Nil{}:
      s
    case +h <> t:
      ho.j.scan(t, ho.j.step(h, s))

# The NUL scanner: txt after the id's NUL; the id kept (reversed).
type HoNs is Data:
  HoNs{txt: Bool, acc: List<&2, U32>, cp: Nat, start: Nat, pos: Nat, out: List<&2, HoRec>}

# 0 the id's NUL, 1 the text's (a record ends), 2 an id byte, 3 a text byte
def ho.n.code(+h: U32, +txt: Bool) -> Nat:
  Bool.pick(Nat, U32.is_eq(h, 0), Bool.pick(Nat, txt, 1n, 0n), Bool.pick(Nat, txt, 3n, 2n))

def ho.n.act(code: Nat, +h: U32, acc: List<&2, U32>, +cp: Nat, +start: Nat, +pos: Nat, out: List<&2, HoRec>) -> HoNs:
  match code:
    case 0n:
      HoNs{True{}, acc, cp, start, 1n+pos, out}
    case 1n:
      HoNs{False{}, Nil{}, 0n, 1n+pos, 1n+pos, HoRec{List.reverse(&2, U32, acc), start, Nat.sub(1n+pos, start), cp} <> out}
    case 2n:
      HoNs{False{}, h <> acc, cp, start, 1n+pos, out}
    case _:
      HoNs{True{}, acc, Bool.pick(Nat, ho.cont(h), cp, 1n+cp), start, 1n+pos, out}

def ho.n.step(+h: U32, s: HoNs) -> HoNs:
  match s:
    case HoNs{+t, acc, cp, start, pos, out}:
      ho.n.act(ho.n.code(h, t), h, acc, cp, start, pos, out)

def ho.n.scan(xs: List<&2, U32>, s: HoNs) -> HoNs:
  match xs:
    case Nil{}:
      s
    case +h <> t:
      ho.n.scan(t, ho.n.step(h, s))

type HoSc is Data:
  ScJ{s: HoJs}
  ScN{s: HoNs}

def ho.sc.scan(xs: List<&2, U32>, sc: HoSc) -> HoSc:
  match sc:
    case ScJ{s}:
      ScJ{ho.j.scan(xs, s)}
    case ScN{s}:
      ScN{ho.n.scan(xs, s)}

# the records ended so far, in file order, and the scanner without them
def ho.sc.take(sc: HoSc) -> HoSc & List<&2, HoRec>:
  match sc:
    case ScJ{HoJs{m, nq, e, k, acc, cp, start, pos, out}}:
      (ScJ{HoJs{m, nq, e, k, acc, cp, start, pos, Nil{}}}, List.reverse(&2, HoRec, out))
    case ScN{HoNs{t, acc, cp, start, pos, out}}:
      (ScN{HoNs{t, acc, cp, start, pos, Nil{}}}, List.reverse(&2, HoRec, out))

# where the record being read starts (0 while skipping to a line)
def ho.sc.start(+sc: HoSc) -> Nat:
  match sc:
    case ScJ{HoJs{+m, nq, e, k, acc, cp, +start, pos, out}}:
      Bool.pick(Nat, Nat.is_eq(m, 2n), 0n, start)
    case ScN{HoNs{t, acc, cp, start, pos, out}}:
      start

# at the end of the file: a last line without its newline (Python reads it;
# a NUL file's unended pair is not one)
def ho.sc.last(sc: HoSc) -> List<&2, HoRec>:
  match sc:
    case ScJ{HoJs{+m, nq, e, k, acc, cp, +start, +pos, out}}:
      Bool.pick(List<&2, HoRec>, Bool.and(Bool.not(Nat.is_eq(m, 2n)), Nat.is_lt(start, pos)), [HoRec{List.reverse(&2, U32, acc), start, Nat.sub(pos, start), cp}], Nil{})
    case ScN{s}:
      Nil{}

def ho.sc.j(+start: Nat) -> HoSc:
  match start:
    case 0n:
      ScJ{HoJs{0n, 0n, False{}, 0n, Nil{}, 0n, 0n, 0n, Nil{}}}
    case 1n+k:
      ScJ{HoJs{2n, 0n, False{}, 0n, Nil{}, 0n, 0n, k, Nil{}}}

# a scanner for a range from start: a JSONL range reads from the byte
# before it, skipping to the first line that starts in it
def ho.sc.new(j: Bool, +start: Nat) -> HoSc:
  match j:
    case True{}:
      ho.sc.j(start)
    case False{}:
      ScN{HoNs{False{}, Nil{}, 0n, start, start, Nil{}}}

def ho.sc.from(j: Bool, +start: Nat) -> Nat:
  match j:
    case True{}:
      Nat.sub(start, 1n)
    case False{}:
      start

# Ids ------------------------------------------------------------------------------

def ho.or(m: Maybe<&2, Nat>, +plus: Nat, +d: Nat) -> Nat:
  match m:
    case Some{n}:
      Nat.add(n, plus)
    case None{}:
      d

# stream_index.py's id: the bytes from the quote after `"id":` to the next
# quote, escapes as they stand
def ho.raw.id(+h: List<&2, U32>) -> List<&2, U32>:
  +s = ho.or(S.find(h, S.b("\"id\":"), 0n), 5n, 4n)
  +i = ho.or(S.find(List.drop(&2, U32, h, s), [34], s), 1n, 0n)
  +j = ho.or(S.find(List.drop(&2, U32, h, i), [34], i), 0n, S.len(h))
  List.take(&2, U32, List.drop(&2, U32, h, i), Nat.sub(j, i))

# the id as json.loads reads it (None: the line is not an {"id", ...} object)
def ho.id.pr(p: J.Pr) -> Maybe<&2, List<&2, U32>>:
  match p:
    case J.Pok{+k, v, r}:
      Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(k, S.b("id")), Some{v}, None{})
    case J.Pbad{}:
      None{}

# mode 0 reads a JSON line's id raw (stream_index.py), the others parsed
def ho.rec.id.j(raw: Bool, +head: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match raw:
    case True{}:
      Some{ho.raw.id(head)}
    case False{}:
      ho.id.pr(J.first.at(head))

def ho.rec.id(j: Bool, +raw: Bool, +head: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match j:
    case True{}:
      ho.rec.id.j(raw, head)
    case False{}:
      Some{head}

# an id the part files cannot carry (they are TAB separated lines)
def ho.bad(+id: List<&2, U32>) -> Bool:
  Bool.or(L.v2.has(id, 9), L.v2.has(id, 10))

# The pieces ----------------------------------------------------------------------
#
# A piece's part file has a line a record:
#   mode 0 (stream-index)  repository
#   mode 1 (holdout)       repository TAB path TAB tag TAB offset TAB bytes TAB characters
#   mode 2 (vault)         repository TAB tag TAB offset TAB bytes
# the tag (4 digits) the file's place among the tool's inputs, the offset
# 10 digits: in byte order a repository's (and path's) records sort in the
# order Python read them.

def ho.line(mode: Nat, +tag: List<&2, U32>, +id: List<&2, U32>, +off: Nat, +len: Nat, +cp: Nat) -> List<&2, U32>:
  match mode:
    case 0n:
      S.append(L.v2.repo.of(id), [10])
    case 1n:
      L.v2.concat([L.v2.repo.of(id), [9], L.v2.path.of(id), [9], tag, [9], ho.dec.w(off, 10n), [9], ho.dec(len), [9], ho.dec(cp), [10]])
    case _:
      L.v2.concat([L.v2.repo.of(id), [9], tag, [9], ho.dec.w(off, 10n), [9], ho.dec(len), [10]])

# Some line (Nil: no record, as Python's loads would refuse it), None: an
# id the files cannot carry
def ho.fmt.id(+mode: Nat, +tag: List<&2, U32>, m: Maybe<&2, List<&2, U32>>, +off: Nat, +len: Nat, +cp: Nat) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      Some{Nil{}}
    case Some{+id}:
      Bool.pick(Maybe<&2, List<&2, U32>>, ho.bad(id), None{}, Some{ho.line(mode, tag, id, off, len, cp)})

def ho.fmt.join(a: Maybe<&2, List<&2, U32>>, b: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match a b:
    case Some{x} Some{y}:
      Some{List.append(&2, U32, x, y)}
    case _ _:
      None{}

# the lines of the records that start before end
def ho.fmt.all(rs: List<&2, HoRec>, +mode: Nat, +j: Bool, +tag: List<&2, U32>, +end: Nat) -> Maybe<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      Some{Nil{}}
    case HoRec{+head, +off, +len, +cp} <> more:
      ho.fmt.join(Bool.pick(Maybe<&2, List<&2, U32>>, Nat.is_lt(off, end), ho.fmt.id(mode, tag, ho.rec.id(j, Nat.is_eq(mode, 0n), head), off, len, cp), Some{Nil{}}),
        ho.fmt.all(more, mode, j, tag, end))

def ho.w.emit(o: File, m: Maybe<&2, List<&2, U32>>) -> IO(File):
  match m:
    case None{}:
      do IO<File>:
        File.close(o)
        IO.die(File, 1, "holdout: an id holds a TAB or a newline")
    case Some{xs}:
      S.emit(o, xs)

# a piece being read: the input, the part file, the next offset, whether to
# read on, the scanner
type HoW is Type:
  HoW{f: File, o: File, off: Nat, more: Bool, sc: HoSc}

def ho.w.chunk(+mode: Nat, +j: Bool, +tag: List<&2, U32>, +end: Nat, f: File, o: File, +off: Nat, +more: Bool, r: HoSc & List<&2, HoRec>) -> IO(HoW):
  (+sc, rs) = r
  do IO<HoW>:
    o2 : File <- ho.w.emit(o, ho.fmt.all(rs, mode, j, tag, end))
    return HoW{f, o2, off, Bool.and(more, Nat.is_lt(ho.sc.start(sc), end)), sc}

def ho.w.got(+mode: Nat, +j: Bool, +tag: List<&2, U32>, +end: Nat, o: File, +off: Nat, sc: HoSc, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(HoW):
  (f, x) = r
  do IO<HoW>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    ho.w.chunk(mode, j, tag, end, f, o, Nat.add(off, S.len(xs)), Bool.not(ho.is.nil(xs)), ho.sc.take(ho.sc.scan(xs, sc)))

def ho.w.step(+mode: Nat, +j: Bool, +tag: List<&2, U32>, +end: Nat, w: HoW) -> IO(HoW):
  match w:
    case HoW{f, o, +off, m, sc}:
      do IO<HoW>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(off), ho.chunk())
        ho.w.got(mode, j, tag, end, o, off, sc, r)

def ho.w.go(fuel: Nat, +mode: Nat, +j: Bool, +tag: List<&2, U32>, +end: Nat, w: HoW) -> IO(HoW):
  match fuel w:
    case 1n+k HoW{f, o, off, True{}, sc}:
      IO.bind(HoW, HoW, ho.w.step(mode, j, tag, end, HoW{f, o, off, True{}, sc}), ho.w.go(k, mode, j, tag, end))
    case _ w:
      IO.pure(HoW, w)

def ho.w.fin(+mode: Nat, +j: Bool, +tag: List<&2, U32>, +end: Nat, w: HoW) -> IO(Unit):
  match w:
    case HoW{f, o, off, m, sc}:
      do IO<Unit>:
        o2 : File <- ho.w.emit(o, ho.fmt.all(ho.sc.last(sc), mode, j, tag, end))
        File.close(f)
        File.close(o2)

# ho-part scan MODE j|n FILE START END TAG OUT: the records of FILE that
# start in [START, END) as MODE's lines into OUT
def ho.scan.run(+mode: Nat, +j: Bool, +file: String, +start: Nat, +end: Nat, +tag: List<&2, U32>, +out: String) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(file, "r"))
    o : File <- IO.try(File, File.open(out, "w"))
    w : HoW <- ho.w.go(ho.big(), mode, j, tag, end, HoW{f, o, ho.sc.from(j, start), True{}, ho.sc.new(j, start)})
    ho.w.fin(mode, j, tag, end, w)

# Keys: the content key of each listed record ------------------------------------

# a NUL record's text: between its first NUL and its last byte
def ho.nul.text(+xs: List<&2, U32>) -> List<&2, U32>:
  +t = L.v2.after(xs, 0)
  List.take(&2, U32, t, Nat.sub(S.len(t), 1n))

def ho.key.j(m: Maybe<&2, J.Doc>) -> List<&2, U32>:
  match m:
    case None{}:
      Nil{}
    case Some{J.Doc{i, t}}:
      S.append(S.b(L.v2.key(t)), [10])

def ho.key.of(j: Bool, +xs: List<&2, U32>) -> List<&2, U32>:
  match j:
    case True{}:
      ho.key.j(J.doc(xs))
    case False{}:
      S.append(S.b(L.v2.key(ho.nul.text(xs))), [10])

type HoK is Type:
  HoK{f: File, o: File}

def ho.k.got(+j: Bool, o: File, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(HoK):
  (f, x) = r
  do IO<HoK>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    o2 : File <- S.emit(o, ho.key.of(j, xs))
    return HoK{f, o2}

def ho.k.read(+j: Bool, +fs: List<&2, List<&2, U32>>, k: HoK) -> IO(HoK):
  match k:
    case HoK{f, o}:
      do IO<HoK>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(ho.num(L.v2.nth(fs, 0n))), U32.from_nat(ho.num(L.v2.nth(fs, 1n))))
        ho.k.got(j, o, r)

def ho.k.one(+j: Bool, +line: List<&2, U32>, k: HoK) -> IO(HoK):
  ho.k.read(j, S.split(line, 9), k)

def ho.k.go(ls: List<&2, List<&2, U32>>, +j: Bool, k: HoK) -> IO(HoK):
  match ls:
    case Nil{}:
      IO.pure(HoK, k)
    case l <> more:
      IO.bind(HoK, HoK, ho.k.one(j, l, k), ho.k.go(more, j))

def ho.k.fin(k: HoK) -> IO(Unit):
  match k:
    case HoK{f, o}:
      do IO<Unit>:
        File.close(f)
        File.close(o)

# ho-part keys j|n FILE LIST OUT: the content key of each record LIST names
# (offset TAB bytes lines), a line each, into OUT
def ho.keys.run(+j: Bool, +file: String, +list: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    xs : List<&2, U32> <- S.read(list)
    f : File <- IO.try(File, File.open(file, "r"))
    o : File <- IO.try(File, File.open(out, "w"))
    k : HoK <- ho.k.go(ho.lines(xs), j, HoK{f, o})
    ho.k.fin(k)

def ho.part.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: ho-part scan MODE j|n FILE START END TAG OUT | ho-part keys j|n FILE LIST OUT | ho-part excl FILE START END OUT DIR")

def ho.part.keys(xs: List<String>) -> IO(Unit):
  match xs:
    case +k <> file <> list <> out <> Nil{}:
      ho.keys.run(String.eq(k, "j"), file, list, out)
    case _:
      ho.part.usage()

def ho.part.scan(xs: List<String>) -> IO(Unit):
  match xs:
    case +m <> +k <> file <> +s <> +e <> +t <> out <> Nil{}:
      ho.scan.run(ho.num(S.b(m)), String.eq(k, "j"), file, ho.num(S.b(s)), ho.num(S.b(e)), S.b(t), out)
    case _:
      ho.part.usage()



# The pool: W threads, each running one piece at a time ---------------------------

def ho.pool.got(+self: String, m: Maybe<&1, List<String>>) -> IO(Bool):
  match m:
    case None{}:
      IO.pure(Bool, False{})
    case Some{args}:
      do IO<Bool>:
        ho.sh("a piece (" ++ self ++ " ho-part)", [], self, args)
        return True{}

def ho.pool.wk(fuel: Nat, +self: String, +q: Chan(List<String>), go: Bool) -> IO(Unit):
  match fuel go:
    case 1n+k True{}:
      do IO<Unit>:
        m : Maybe<&1, List<String>> <- Chan.recv(List<String>, q)
        g : Bool <- ho.pool.got(self, m)
        ho.pool.wk(k, self, q, g)
    case _ _:
      IO.pure(Unit, Unit{})

def ho.pool.fork(n: Nat, +self: String, +q: Chan(List<String>)) -> IO(List<Chan(Unit)>):
  match n:
    case 0n:
      IO.pure(List<Chan(Unit)>, Nil{})
    case 1n+m:
      do IO<List<Chan(Unit)>>:
        ch : Chan(Unit) <- IO.fork(Unit, ho.pool.wk(ho.big(), self, q, True{}))
        rest : List<Chan(Unit)> <- ho.pool.fork(m, self, q)
        return ch <> rest

def ho.pool.send(+q: Chan(List<String>), jobs: List<List<String>>) -> IO(Unit):
  match jobs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case jb <> more:
      do IO<Unit>:
        ok : Result<&1, &1, List<String>, Unit> <- Chan.send(List<String>, q, jb)
        ho.pool.send(q, more)

def ho.pool.join(chs: List<Chan(Unit)>) -> IO(Unit):
  match chs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +ch <> more:
      do IO<Unit>:
        u : Unit <- IO.join(Unit, ch)
        ho.pool.join(more)

type HoJob is Data:
  HoJob{size: Nat, args: List<&2, String>}

def ho.job.le(a: HoJob, b: HoJob) -> Bool:
  match a b:
    case HoJob{+x, s} HoJob{+y, t}:
      Nat.is_le(y, x)

def ho.job.args(js: List<&2, HoJob>) -> List<List<String>>:
  match js:
    case Nil{}:
      Nil{}
    case HoJob{z, a} <> more:
      ho.l1(a) <> ho.job.args(more)

# the jobs, the biggest first, on w threads
def ho.pool(+self: String, +w: Nat, jobs: List<&2, HoJob>) -> IO(Unit):
  do IO<Unit>:
    +q : Chan(List<String>) <- Chan.new(List<String>, U32.from_nat(w))
    chs : List<Chan(Unit)> <- ho.pool.fork(w, self, q)
    ho.pool.send(q, ho.job.args(List.sort(~HoJob, ~ho.job.le, jobs)))
    Chan.close(List<String>, q)
    ho.pool.join(chs)

# Inputs ---------------------------------------------------------------------------

# an input file: its tag, path, whether JSON lines, size
type HoIn is Data:
  HoIn{tag: Nat, path: String, j: Bool, size: Nat}

def ho.ins.put(e: Bool, x: HoIn, +rest: List<&2, HoIn>) -> List<&2, HoIn>:
  match e:
    case True{}:
      x <> rest
    case False{}:
      rest

# the paths that exist (os.path.exists), tagged from t
def ho.ins(ps: List<&2, String>, +j: Bool, +t: Nat) -> IO(List<&2, HoIn>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, HoIn>, Nil{})
    case +p <> more:
      do IO<List<&2, HoIn>>:
        e : Bool <- S.exists(p)
        z : Nat <- S.size(p)
        rest : List<&2, HoIn> <- ho.ins(more, j, 1n+t)
        return ho.ins.put(e, HoIn{t, p, j, z}, rest)

def ho.ins.check(ins: List<&2, HoIn>) -> IO(Unit):
  match ins:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case HoIn{t, +p, j, +z} <> more:
      Bool.pick(IO(Unit), Nat.is_lt(z, 4294967295n), ho.ins.check(more), IO.die(Unit, 1, "holdout: " ++ p ++ " is 4 GiB or more (the reads are 32-bit)"))

def ho.ranges(fuel: Nat, +s: Nat, +z: Nat, go: Bool) -> List<&2, Nat>:
  match fuel go:
    case 1n+k True{}:
      +n = Nat.add(s, ho.range())
      s <> ho.ranges(k, n, z, Nat.is_lt(n, z))
    case _ _:
      Nil{}

# where an input's pieces start: a JSONL file every ho.range() bytes, a NUL
# file once (none when empty)
def ho.starts(+j: Bool, +z: Nat) -> List<&2, Nat>:
  match j:
    case True{}:
      ho.ranges(1n+Nat.div(z, ho.range()), 0n, z, Nat.is_lt(0n, z))
    case False{}:
      Bool.pick(List<&2, Nat>, Nat.is_eq(z, 0n), Nil{}, [0n])

def ho.part.name(+tmp: String, +t: Nat, +k: Nat) -> String:
  tmp ++ "/p." ++ Nat.show(t) ++ "." ++ Nat.show(k)

def ho.in.jobs.go(+tmp: String, +mode: String, +j: Bool, +p: String, +z: Nat, +t: Nat, ss: List<&2, Nat>, +k: Nat) -> List<&2, HoJob>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> more:
      +e = Bool.pick(Nat, j, Nat.add(s, ho.range()), z)
      HoJob{Nat.sub(Nat.min(e, z), s), ["ho-part", "scan", mode, Bool.pick(String, j, "j", "n"), p, Nat.show(s), Nat.show(e), S.str(ho.dec.w(t, 4n)), ho.part.name(tmp, t, k)]}
        <> ho.in.jobs.go(tmp, mode, j, p, z, t, more, 1n+k)

def ho.in.parts.go(+tmp: String, +t: Nat, ss: List<&2, Nat>, +k: Nat) -> List<&2, String>:
  match ss:
    case Nil{}:
      Nil{}
    case s <> more:
      ho.part.name(tmp, t, k) <> ho.in.parts.go(tmp, t, more, 1n+k)

# every input's pieces as jobs (`ho-part scan MODE ...`)
def ho.jobs(+tmp: String, +mode: String, ins: List<&2, HoIn>) -> List<&2, HoJob>:
  match ins:
    case Nil{}:
      Nil{}
    case HoIn{+t, +p, +j, +z} <> more:
      List.append(&2, HoJob, ho.in.jobs.go(tmp, mode, j, p, z, t, ho.starts(j, z), 0n), ho.jobs(tmp, mode, more))

# their part files
def ho.parts(+tmp: String, ins: List<&2, HoIn>) -> List<&2, String>:
  match ins:
    case Nil{}:
      Nil{}
    case HoIn{+t, p, +j, +z} <> more:
      List.append(&2, String, ho.in.parts.go(tmp, t, ho.starts(j, z), 0n), ho.parts(tmp, more))

# run the pieces of ins (MODE's lines) on the pool
def ho.scan.all(+tmp: String, +mode: String, ins: List<&2, HoIn>) -> IO(Unit):
  do IO<Unit>:
    +self : String <- ho.self()
    +w : Nat <- S.env.nat("HO_JOBS", 5n)
    ho.pool(self, w, ho.jobs(tmp, mode, ins))

# stream-index -----------------------------------------------------------------------

type HoSpec is Data:
  HoSpec{name: String, j: Bool, paths: List<&2, String>}

type HoSi is Data:
  HoSi{name: String, ins: List<&2, HoIn>}

def ho.si.raws(fs: List<&2, String>) -> List<&2, HoSpec>:
  match fs:
    case Nil{}:
      Nil{}
    case +f <> more:
      HoSpec{"raw-new:" ++ f, True{}, ["run/raw-new/" ++ f ++ ".jsonl"]} <> ho.si.raws(more)

def ho.si.waves(ws: List<&2, String>) -> IO(List<&2, HoSpec>):
  match ws:
    case Nil{}:
      IO.pure(List<&2, HoSpec>, Nil{})
    case +w <> more:
      do IO<List<&2, HoSpec>>:
        ps : List<&2, String> <- ho.glob("run/" ++ w ++ "/*/transcripts.*.nul run/" ++ w ++ "/*/files-*.nul")
        rest : List<&2, HoSpec> <- ho.si.waves(more)
        return HoSpec{w, False{}, ps} <> rest

# the training streams of run 1, in stream_index.py's order
def ho.si.specs() -> IO(List<&2, HoSpec>):
  do IO<List<&2, HoSpec>>:
    ws : List<&2, HoSpec> <- ho.si.waves(["transcripts-final", "transcripts-next", "transcripts-w1", "transcripts-w2", "transcripts-w3", "transcripts-w4"])
    return List.append(&2, HoSpec, HoSpec{"code-train-v3", True{}, ["run/code-train-v3.jsonl"]} <> ho.si.raws(["haskell", "haskell-2", "lean", "agda-f", "bend", "lean-2", "agda-2f"]), ws)

# a stream's inputs tagged 100 s + i
def ho.si.streams(specs: List<&2, HoSpec>, +s: Nat) -> IO(List<&2, HoSi>):
  match specs:
    case Nil{}:
      IO.pure(List<&2, HoSi>, Nil{})
    case HoSpec{name, +j, paths} <> more:
      do IO<List<&2, HoSi>>:
        ins : List<&2, HoIn> <- ho.ins(paths, j, Nat.mul(s, 100n))
        rest : List<&2, HoSi> <- ho.si.streams(more, 1n+s)
        return HoSi{name, ins} <> rest

def ho.si.ins(ss: List<&2, HoSi>) -> List<&2, HoIn>:
  match ss:
    case Nil{}:
      Nil{}
    case HoSi{n, ins} <> more:
      List.append(&2, HoIn, ins, ho.si.ins(more))

def ho.si.quote(rs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      Nil{}
    case r <> more:
      ho.asc(r) <> ho.si.quote(more)

def ho.si.member(+name: String, rs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  L.v2.concat([ho.asc(S.b(name)), S.b(": ["), ho.join(ho.si.quote(rs), S.b(", ")), [93]])

def ho.si.say(+name: String, +n: Nat) -> IO(Unit):
  IO.print(S.str(L.v2.concat([ho.left(S.b(name), 24n), [32], ho.right(ho.dec(n), 7n), S.b(" repositories")])))

# each stream's repositories (sorted, one of each): its JSON member, and
# stream_index.py's line
def ho.si.reduce(+tmp: String, ss: List<&2, HoSi>, +k: Nat) -> IO(List<&2, List<&2, U32>>):
  match ss:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case HoSi{+name, ins} <> more:
      do IO<List<&2, List<&2, U32>>>:
        ho.sort(tmp, True{}, tmp ++ "/s." ++ Nat.show(k), ho.parts(tmp, ins))
        xs : List<&2, U32> <- S.read(tmp ++ "/s." ++ Nat.show(k))
        +rs : List<&2, List<&2, U32>> = ho.lines(xs)
        ho.si.say(name, List.length(&2, List<&2, U32>, rs))
        rest : List<&2, List<&2, U32>> <- ho.si.reduce(tmp, more, 1n+k)
        return ho.si.member(name, rs) <> rest

def ho.stream.index.at(+dir: String) -> IO(Unit):
  do IO<Unit>:
    +tmp : String <- S.mktemp()
    specs : List<&2, HoSpec> <- ho.si.specs()
    +ss : List<&2, HoSi> <- ho.si.streams(specs, 0n)
    ho.ins.check(ho.si.ins(ss))
    ho.scan.all(tmp, "0", ho.si.ins(ss))
    ms : List<&2, List<&2, U32>> <- ho.si.reduce(tmp, ss, 0n)
    S.mkdir(dir ++ "/holdout")
    S.write(dir ++ "/holdout/stream-index.json", L.v2.concat([[123], ho.join(ms, S.b(", ")), [125]]))
    S.rm(tmp)

# stream-index [DIR]
def ho.stream.index(xs: List<String>) -> IO(Unit):
  ho.stream.index.at(ho.dir.of(xs))

# Reducing a sorted part file ----------------------------------------------------
#
# The file is read 8 MiB at a time and cut into lines; a reducer folds each
# line (its TAB separated fields) into its state, and may give bytes for
# two output files.

# pass A of holdout: the repositories with more than 300 distinct paths
type HoAs is Data:
  HoAs{r: List<&2, U32>, p: List<&2, U32>, n: Nat, big: Set()}

def ho.a.add(yes: Bool, +r: List<&2, U32>, big: Set()) -> Set():
  match yes:
    case True{}:
      Set.add(big, S.str(r))
    case False{}:
      big

# 0 a new repository, 1 a new path, 2 the same
def ho.a.code(+r: List<&2, U32>, +p: List<&2, U32>, +r2: List<&2, U32>, +p2: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.eq(r, r2), Bool.pick(Nat, S.eq(p, p2), 2n, 1n), 0n)

def ho.a.act(code: Nat, r: List<&2, U32>, p: List<&2, U32>, +n: Nat, big: Set(), r2: List<&2, U32>, p2: List<&2, U32>) -> HoAs:
  match code:
    case 0n:
      HoAs{r2, p2, 1n, ho.a.add(Nat.is_lt(300n, n), r, big)}
    case 1n:
      HoAs{r, p2, 1n+n, big}
    case _:
      HoAs{r, p, n, big}

def ho.a.line(s: HoAs, +fs: List<&2, List<&2, U32>>) -> HoAs:
  match s:
    case HoAs{+r, +p, n, big}:
      ho.a.act(ho.a.code(r, p, L.v2.nth(fs, 0n), L.v2.nth(fs, 1n)), r, p, n, big, L.v2.nth(fs, 0n), L.v2.nth(fs, 1n))

def ho.a.end(s: HoAs) -> Set():
  match s:
    case HoAs{r, p, +n, big}:
      ho.a.add(Nat.is_lt(300n, n), r, big)

# pass B of holdout: lines `repository TAB path TAB tag TAB offset TAB
# bytes TAB characters`, each (repository, path) a group, its first line
# the first version Python read. The state: the group (rp), its
# repository's vault language (vl, Nil: none) and bigness (bg), its unit
# (u) and whether the split holds it out (uh), its reason (rs, Nil: kept);
# the held-out units, the languages' counts, the paths listed.

type HoU is Data:
  HoU{reason: List<&2, U32>, n: Nat, b: Nat}

type HoL is Data:
  HoL{tf: Nat, tb: Nat, of: Nat, ob: Nat}

def ho.l.inc(+cp: Nat, +held: Bool, v: HoL) -> HoL:
  match v:
    case HoL{+tf, +tb, +of, +ob}:
      HoL{1n+tf, Nat.add(tb, cp), Bool.pick(Nat, held, 1n+of, of), Bool.pick(Nat, held, Nat.add(ob, cp), ob)}

# the six languages' counts (in sorted order)
type HoLs is Data:
  HoLs{agda: HoL, bend: HoL, haskell: HoL, lean: HoL, nix: HoL, other: HoL}

def ho.ls.new() -> HoLs:
  HoLs{HoL{0n, 0n, 0n, 0n}, HoL{0n, 0n, 0n, 0n}, HoL{0n, 0n, 0n, 0n}, HoL{0n, 0n, 0n, 0n}, HoL{0n, 0n, 0n, 0n}, HoL{0n, 0n, 0n, 0n}}

def ho.ls.add(code: Nat, +cp: Nat, +held: Bool, ls: HoLs) -> HoLs:
  match code ls:
    case 0n HoLs{a, b, h, l, n, o}:
      HoLs{ho.l.inc(cp, held, a), b, h, l, n, o}
    case 1n HoLs{a, b, h, l, n, o}:
      HoLs{a, ho.l.inc(cp, held, b), h, l, n, o}
    case 2n HoLs{a, b, h, l, n, o}:
      HoLs{a, b, ho.l.inc(cp, held, h), l, n, o}
    case 3n HoLs{a, b, h, l, n, o}:
      HoLs{a, b, h, ho.l.inc(cp, held, l), n, o}
    case 4n HoLs{a, b, h, l, n, o}:
      HoLs{a, b, h, l, ho.l.inc(cp, held, n), o}
    case _ HoLs{a, b, h, l, n, o}:
      HoLs{a, b, h, l, n, ho.l.inc(cp, held, o)}

type HoB is Data:
  HoB{rp: List<&2, U32>, r: List<&2, U32>, vl: List<&2, U32>, bg: Bool, u: List<&2, U32>, uh: Bool, rs: List<&2, U32>, units: Map<&2, HoU>, langs: HoLs, np: Nat}

type HoBo is Data:
  HoBo{s: HoB, paths: List<&2, U32>, held: List<&2, U32>}

def ho.u.put(m: Map<&2, HoU>, +k: String, +reason: List<&2, U32>, +cp: Nat, v: HoU) -> Map<&2, HoU>:
  match v:
    case HoU{x, +n, +b}:
      Map.set(&2, HoU, m, k, HoU{reason, 1n+n, Nat.add(b, cp)})

def ho.u.set(+k: String, +reason: List<&2, U32>, +cp: Nat, r: Map<&2, HoU> & HoU) -> Map<&2, HoU>:
  (m, v) = r
  ho.u.put(m, k, reason, cp, v)

def ho.u.add(held: Bool, units: Map<&2, HoU>, +k: List<&2, U32>, +reason: List<&2, U32>, +cp: Nat) -> Map<&2, HoU>:
  match held:
    case True{}:
      ho.u.set(S.str(k), reason, cp, Map.get(HoU, HoU{Nil{}, 0n, 0n}, units, S.str(k)))
    case False{}:
      units

def ho.snd.l(r: Map<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, U32>:
  (m, v) = r
  v

def ho.vlang(+vm: Map<&2, List<&2, U32>>, +r: List<&2, U32>) -> List<&2, U32>:
  ho.snd.l(Map.get(List<&2, U32>, Nil{}, vm, S.str(r)))

# the file's language (holdout.py's lang_of, "other" for None) as a code:
# 0 agda, 1 bend, 2 haskell, 3 lean, 4 nix, 5 other
def ho.lang.ext(+e: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.or(S.eq(e, S.b("hs")), S.eq(e, S.b("lhs"))), 2n,
    Bool.pick(Nat, S.eq(e, S.b("lean")), 3n,
      Bool.pick(Nat, Bool.or(S.eq(e, S.b("agda")), S.eq(e, S.b("lagda"))), 0n,
        Bool.pick(Nat, S.eq(e, S.b("nix")), 4n,
          Bool.pick(Nat, S.eq(e, S.b("bend")), 1n, 5n)))))

def ho.lang(+p: List<&2, U32>) -> Nat:
  +lo = L.v2.lower(p)
  +ext = Bool.pick(List<&2, U32>, L.v2.has(lo, 46), List.reverse(&2, U32, L.v2.before(List.reverse(&2, U32, lo), 46)), Nil{})
  Bool.pick(Nat, S.suffix(lo, S.b(".lagda.md")), 0n, ho.lang.ext(ext))

# the holdout unit: a dataset's record, a big repository's directory, or
# the repository
def ho.unit(+r: List<&2, U32>, +p: List<&2, U32>, +big: Bool) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.prefix(r, S.b("hf:")), L.v2.concat([r, [47], p]),
    Bool.pick(List<&2, U32>, big, L.v2.concat([r, [47], L.v2.parent(p, 47)]), r))

def ho.hexv(n: Nat, xs: List<&2, U32>, +acc: Nat) -> Nat:
  match n xs:
    case 1n+k +h <> t:
      ho.hexv(k, t, Nat.add(Nat.mul(acc, 16n), U32.to_nat(J.hexd(h))))
    case _ _:
      acc

# int(sha256("corpus-v2 holdout\0" + u)[:8], 16) % 1000 < 20
def ho.held(+u: List<&2, U32>) -> Bool:
  Nat.is_lt(Nat.mod(ho.hexv(8n, S.b(H.sha256(L.v2.concat([S.b("corpus-v2 holdout"), [0], u]))), 0n), 1000n), 20n)

def ho.b.vl(same: Bool, +vl: List<&2, U32>, +vm: Map<&2, List<&2, U32>>, +r: List<&2, U32>) -> List<&2, U32>:
  match same:
    case True{}:
      vl
    case False{}:
      ho.vlang(vm, r)

def ho.b.bg(same: Bool, +bg: Bool, +bigs: Set(), +r: List<&2, U32>) -> Bool:
  match same:
    case True{}:
      bg
    case False{}:
      ho.in(bigs, r)

def ho.b.uh(same: Bool, +uh: Bool, +u: List<&2, U32>) -> Bool:
  match same:
    case True{}:
      uh
    case False{}:
      ho.held(u)

def ho.reason(+vl: List<&2, U32>, +uh: Bool) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, ho.is.nil(vl), Bool.pick(List<&2, U32>, uh, S.b("split"), Nil{}), S.append(S.b("vault-"), vl))

def ho.b.rp(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  L.v2.concat([L.v2.nth(fs, 0n), [9], L.v2.nth(fs, 1n)])

def ho.b.heldline(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  L.v2.concat([L.v2.nth(fs, 2n), [9], L.v2.nth(fs, 3n), [9], L.v2.nth(fs, 4n), [10]])

# a group's first line: what decides the group
def ho.b.group(+vm: Map<&2, List<&2, U32>>, +bigs: Set(), +r: List<&2, U32>, +vl: List<&2, U32>, +bg: Bool, +u: List<&2, U32>, +uh: Bool, units: Map<&2, HoU>, langs: HoLs, +np: Nat, +fs: List<&2, List<&2, U32>>) -> HoBo:
  +r2 = L.v2.nth(fs, 0n)
  +p2 = L.v2.nth(fs, 1n)
  +samer = S.eq(r, r2)
  +vl2 = ho.b.vl(samer, vl, vm, r2)
  +bg2 = ho.b.bg(samer, bg, bigs, r2)
  +u2 = ho.unit(r2, p2, bg2)
  +uh2 = ho.b.uh(S.eq(u, u2), uh, u2)
  +rs2 = ho.reason(vl2, uh2)
  +cp = ho.num(L.v2.nth(fs, 5n))
  +held = Bool.not(ho.is.nil(rs2))
  HoBo{HoB{ho.b.rp(fs), r2, vl2, bg2, u2, uh2, rs2, ho.u.add(held, units, Bool.pick(List<&2, U32>, ho.is.nil(vl2), u2, r2), rs2, cp),
      ho.ls.add(ho.lang(p2), cp, held, langs), Bool.pick(Nat, held, 1n+np, np)},
    Bool.pick(List<&2, U32>, held, L.v2.concat([r2, [9], p2, [10]]), Nil{}), Bool.pick(List<&2, U32>, held, ho.b.heldline(fs), Nil{})}

def ho.b.next(same: Bool, +vm: Map<&2, List<&2, U32>>, +bigs: Set(), rp: List<&2, U32>, r: List<&2, U32>, vl: List<&2, U32>, bg: Bool, u: List<&2, U32>, uh: Bool, +rs: List<&2, U32>, units: Map<&2, HoU>, langs: HoLs, np: Nat, +fs: List<&2, List<&2, U32>>) -> HoBo:
  match same:
    case True{}:
      HoBo{HoB{rp, r, vl, bg, u, uh, rs, units, langs, np}, Nil{}, Bool.pick(List<&2, U32>, ho.is.nil(rs), Nil{}, ho.b.heldline(fs))}
    case False{}:
      ho.b.group(vm, bigs, r, vl, bg, u, uh, units, langs, np, fs)

def ho.b.line(+vm: Map<&2, List<&2, U32>>, +bigs: Set(), s: HoB, +fs: List<&2, List<&2, U32>>) -> HoBo:
  match s:
    case HoB{+rp, r, vl, bg, u, uh, rs, units, langs, np}:
      ho.b.next(S.eq(rp, ho.b.rp(fs)), vm, bigs, rp, r, vl, bg, u, uh, rs, units, langs, np, fs)

# vault: lines `repository TAB tag TAB offset TAB bytes`, grouped by
# repository; a group no counted stream holds is untrained, one of >= 3
# records a candidate

type HoLoc is Data:
  HoLoc{off: Nat, len: Nat}

type HoCand is Data:
  HoCand{hash: String, repo: List<&2, U32>, n: Nat, locs: List<&2, HoLoc>}

type HoV is Data:
  HoV{repo: List<&2, U32>, keep: Bool, n: Nat, locs: List<&2, HoLoc>, untrained: Nat, cands: List<&2, HoCand>}

def ho.snd.u(r: Map<&2, U32> & U32) -> U32:
  (m, v) = r
  v

def ho.mask.of(+masks: Map<&2, U32>, +r: List<&2, U32>) -> U32:
  ho.snd.u(Map.get(U32, 0, masks, S.str(r)))

def ho.v.cand(big: Bool, +repo: List<&2, U32>, +n: Nat, locs: List<&2, HoLoc>, cands: List<&2, HoCand>) -> List<&2, HoCand>:
  match big:
    case True{}:
      HoCand{H.sha256(repo), repo, n, List.reverse(&2, HoLoc, locs)} <> cands
    case False{}:
      cands

# the group read ends; the next (repository r2, kept or not) starts
def ho.v.close(keep: Bool, +repo: List<&2, U32>, +n: Nat, locs: List<&2, HoLoc>, +u: Nat, cands: List<&2, HoCand>, r2: List<&2, U32>, k2: Bool) -> HoV:
  match keep:
    case True{}:
      HoV{r2, k2, 0n, Nil{}, 1n+u, ho.v.cand(Nat.is_le(3n, n), repo, n, locs, cands)}
    case False{}:
      HoV{r2, k2, 0n, Nil{}, u, cands}

def ho.v.add(+fs: List<&2, List<&2, U32>>, s: HoV) -> HoV:
  match s:
    case HoV{repo, True{}, +n, locs, u, cands}:
      HoV{repo, True{}, 1n+n, HoLoc{ho.num(L.v2.nth(fs, 2n)), ho.num(L.v2.nth(fs, 3n))} <> locs, u, cands}
    case HoV{repo, False{}, n, locs, u, cands}:
      HoV{repo, False{}, n, locs, u, cands}

def ho.v.untrained(+lmask: U32, +masks: Map<&2, U32>, +r: List<&2, U32>) -> Bool:
  U32.is_eq(U32.and(ho.mask.of(masks, r), lmask), 0)

def ho.v.next(same: Bool, +lmask: U32, +masks: Map<&2, U32>, repo: List<&2, U32>, keep: Bool, n: Nat, locs: List<&2, HoLoc>, u: Nat, cands: List<&2, HoCand>, +fs: List<&2, List<&2, U32>>) -> HoV:
  match same:
    case True{}:
      ho.v.add(fs, HoV{repo, keep, n, locs, u, cands})
    case False{}:
      ho.v.add(fs, ho.v.close(keep, repo, n, locs, u, cands, L.v2.nth(fs, 0n), ho.v.untrained(lmask, masks, L.v2.nth(fs, 0n))))

def ho.v.line(+lmask: U32, +masks: Map<&2, U32>, s: HoV, +fs: List<&2, List<&2, U32>>) -> HoV:
  match s:
    case HoV{+repo, keep, n, locs, u, cands}:
      ho.v.next(S.eq(repo, L.v2.nth(fs, 0n)), lmask, masks, repo, keep, n, locs, u, cands, fs)

def ho.v.end(s: HoV) -> HoV:
  match s:
    case HoV{repo, keep, n, locs, u, cands}:
      ho.v.close(keep, repo, n, locs, u, cands, Nil{}, False{})

# A reducer, its constants with it; RedB's two outputs (reversed bytes)
type HoRed is Data:
  RedA{s: HoAs}
  RedB{vm: Map<&2, List<&2, U32>>, bigs: Set(), s: HoB, paths: List<&2, U32>, held: List<&2, U32>}
  RedV{lmask: U32, masks: Map<&2, U32>, s: HoV}

def ho.red.b(vm: Map<&2, List<&2, U32>>, bigs: Set(), p: List<&2, U32>, h: List<&2, U32>, o: HoBo) -> HoRed:
  match o:
    case HoBo{s, pl, hl}:
      RedB{vm, bigs, s, List.reverse.go(&2, U32, pl, p), List.reverse.go(&2, U32, hl, h)}

def ho.red.line(+l: List<&2, U32>, r: HoRed) -> HoRed:
  match r:
    case RedA{s}:
      RedA{ho.a.line(s, S.split(l, 9))}
    case RedB{+vm, +bigs, s, p, h}:
      ho.red.b(vm, bigs, p, h, ho.b.line(vm, bigs, s, S.split(l, 9)))
    case RedV{+lmask, +masks, s}:
      RedV{lmask, masks, ho.v.line(lmask, masks, s, S.split(l, 9))}

def ho.red.lines(ls: List<&2, List<&2, U32>>, r: HoRed) -> HoRed:
  match ls:
    case Nil{}:
      r
    case l <> more:
      ho.red.lines(more, ho.red.line(l, r))

type HoTk is Data:
  HoTk{r: HoRed, p: List<&2, U32>, h: List<&2, U32>}

def ho.red.take(r: HoRed) -> HoTk:
  match r:
    case RedB{vm, bigs, s, p, h}:
      HoTk{RedB{vm, bigs, s, Nil{}, Nil{}}, List.reverse(&2, U32, p), List.reverse(&2, U32, h)}
    case r:
      HoTk{r, Nil{}, Nil{}}

# a chunk cut into lines: the line being read (reversed), the lines ended
# (newest first)
type HoLn is Data:
  HoLn{cur: List<&2, U32>, out: List<&2, List<&2, U32>>}

def ho.ln.act(nl: Bool, +h: U32, cur: List<&2, U32>, out: List<&2, List<&2, U32>>) -> HoLn:
  match nl:
    case True{}:
      HoLn{Nil{}, List.reverse(&2, U32, cur) <> out}
    case False{}:
      HoLn{h <> cur, out}

def ho.ln.step(+h: U32, s: HoLn) -> HoLn:
  match s:
    case HoLn{cur, out}:
      ho.ln.act(U32.is_eq(h, 10), h, cur, out)

def ho.ln.scan(xs: List<&2, U32>, s: HoLn) -> HoLn:
  match xs:
    case Nil{}:
      s
    case +h <> t:
      ho.ln.scan(t, ho.ln.step(h, s))

def ho.emit(f: File, xs: List<&2, U32>) -> IO(File):
  match xs:
    case Nil{}:
      IO.pure(File, f)
    case h <> t:
      S.emit(f, h <> t)

type HoRl is Type:
  HoRl{f: File, pf: File, hf: File, off: Nat, more: Bool, cur: List<&2, U32>, r: HoRed}

def ho.rl.emit(f: File, pf: File, hf: File, +off: Nat, +more: Bool, cur: List<&2, U32>, t: HoTk) -> IO(HoRl):
  match t:
    case HoTk{r, p, h}:
      do IO<HoRl>:
        pf2 : File <- ho.emit(pf, p)
        hf2 : File <- ho.emit(hf, h)
        return HoRl{f, pf2, hf2, off, more, cur, r}

def ho.rl.lines(f: File, pf: File, hf: File, +off: Nat, +more: Bool, l: HoLn, r: HoRed) -> IO(HoRl):
  match l:
    case HoLn{cur, out}:
      ho.rl.emit(f, pf, hf, off, more, cur, ho.red.take(ho.red.lines(List.reverse(&2, List<&2, U32>, out), r)))

def ho.rl.got(pf: File, hf: File, +off: Nat, cur: List<&2, U32>, r: HoRed, q: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(HoRl):
  (f, x) = q
  do IO<HoRl>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    ho.rl.lines(f, pf, hf, Nat.add(off, S.len(xs)), Bool.not(ho.is.nil(xs)), ho.ln.scan(xs, HoLn{cur, Nil{}}), r)

def ho.rl.step(w: HoRl) -> IO(HoRl):
  match w:
    case HoRl{f, pf, hf, +off, m, cur, r}:
      do IO<HoRl>:
        q : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(off), ho.chunk())
        ho.rl.got(pf, hf, off, cur, r, q)

def ho.rl.go(fuel: Nat, w: HoRl) -> IO(HoRl):
  match fuel w:
    case 1n+k HoRl{f, pf, hf, off, True{}, cur, r}:
      IO.bind(HoRl, HoRl, ho.rl.step(HoRl{f, pf, hf, off, True{}, cur, r}), ho.rl.go(k))
    case _ w:
      IO.pure(HoRl, w)

# a last line without its newline
def ho.rl.last(+cur: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, ho.is.nil(cur), Nil{}, [List.reverse(&2, U32, cur)])

def ho.rl.close(w: HoRl) -> IO(HoRed):
  match w:
    case HoRl{f, pf, hf, off, m, cur, r}:
      do IO<HoRed>:
        File.close(f)
        File.close(pf)
        File.close(hf)
        return r

def ho.rl.fin(w: HoRl) -> IO(HoRed):
  match w:
    case HoRl{f, pf, hf, off, m, cur, r}:
      do IO<HoRed>:
        u : HoRl <- ho.rl.emit(f, pf, hf, off, False{}, Nil{}, ho.red.take(ho.red.lines(ho.rl.last(cur), r)))
        ho.rl.close(u)

# fold r over the lines of path; RedB's outputs into po and ho
def ho.reduce(+path: String, +po: String, +hn: String, r: HoRed) -> IO(HoRed):
  do IO<HoRed>:
    f : File <- IO.try(File, File.open(path, "r"))
    pf : File <- IO.try(File, File.open(po, "w"))
    hf : File <- IO.try(File, File.open(hn, "w"))
    w : HoRl <- ho.rl.go(ho.big(), HoRl{f, pf, hf, 0n, True{}, Nil{}, r})
    ho.rl.fin(w)

# vault ------------------------------------------------------------------------------
#
# stream-index.json read back: each repository's streams as a mask, 1 a
# stream other than raw-new:agda-2f, 2 raw-new:agda-2f (the Agda vault comes
# from agda-2f, so only the other streams count against it).

type HoXj is Data:
  HoXj{ins: Bool, esc: Bool, depth: Nat, raw: List<&2, U32>, key: List<&2, U32>, m: Map<&2, U32>}

# in a string: 0 a byte, 1 a backslash, 2 the closing quote; outside: 3 a
# quote, 4 `[`, 5 `]`, 6 anything else
def ho.xj.code(+h: U32, +ins: Bool, +esc: Bool) -> Nat:
  Bool.pick(Nat, ins,
    Bool.pick(Nat, esc, 0n, Bool.pick(Nat, U32.is_eq(h, 92), 1n, Bool.pick(Nat, U32.is_eq(h, 34), 2n, 0n))),
    Bool.pick(Nat, U32.is_eq(h, 34), 3n, Bool.pick(Nat, U32.is_eq(h, 91), 4n, Bool.pick(Nat, U32.is_eq(h, 93), 5n, 6n))))

def ho.mask.set(+k: String, +bit: U32, r: Map<&2, U32> & U32) -> Map<&2, U32>:
  (m, v) = r
  Map.set(&2, U32, m, k, U32.or(v, bit))

def ho.mask.add(m: Map<&2, U32>, +k: String, +bit: U32) -> Map<&2, U32>:
  ho.mask.set(k, bit, Map.get(U32, 0, m, k))

def ho.xj.str(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case Some{x}:
      x
    case None{}:
      Nil{}

# a string ended: a stream's name (depth 0) or one of its repositories
def ho.xj.end(+depth: Nat, +s: List<&2, U32>, +key: List<&2, U32>, m: Map<&2, U32>) -> HoXj:
  match depth:
    case 0n:
      HoXj{False{}, False{}, 0n, Nil{}, s, m}
    case 1n+d:
      HoXj{False{}, False{}, 1n+d, Nil{}, key, ho.mask.add(m, S.str(s), Bool.pick(U32, S.eq(key, S.b("raw-new:agda-2f")), 2, 1))}

def ho.xj.act(code: Nat, +h: U32, +depth: Nat, raw: List<&2, U32>, key: List<&2, U32>, m: Map<&2, U32>) -> HoXj:
  match code:
    case 0n:
      HoXj{True{}, False{}, depth, h <> raw, key, m}
    case 1n:
      HoXj{True{}, True{}, depth, h <> raw, key, m}
    case 2n:
      ho.xj.end(depth, ho.xj.str(J.string(L.v2.concat([[34], List.reverse(&2, U32, raw), [34]]))), key, m)
    case 3n:
      HoXj{True{}, False{}, depth, Nil{}, key, m}
    case 4n:
      HoXj{False{}, False{}, 1n, raw, key, m}
    case 5n:
      HoXj{False{}, False{}, 0n, raw, key, m}
    case _:
      HoXj{False{}, False{}, depth, raw, key, m}

def ho.xj.step(+h: U32, s: HoXj) -> HoXj:
  match s:
    case HoXj{+ins, +esc, depth, raw, key, m}:
      ho.xj.act(ho.xj.code(h, ins, esc), h, depth, raw, key, m)

def ho.xj.scan(xs: List<&2, U32>, s: HoXj) -> HoXj:
  match xs:
    case Nil{}:
      s
    case +h <> t:
      ho.xj.scan(t, ho.xj.step(h, s))

def ho.xj.m(s: HoXj) -> Map<&2, U32>:
  match s:
    case HoXj{i, e, d, r, k, m}:
      m

def ho.xj.masks(xs: List<&2, U32>) -> Map<&2, U32>:
  ho.xj.m(ho.xj.scan(xs, HoXj{False{}, False{}, 0n, Nil{}, Nil{}, Map.new(&2, U32)}))

def ho.cand.le(a: HoCand, b: HoCand) -> Bool:
  match a b:
    case HoCand{x, r, n, l} HoCand{y, s, m, k}:
      String.is_le(x, y)

# The chosen repositories' lines, copied from the input as they stand.
type HoO is Type:
  HoO{f: File, o: File, files: Nat, cps: Nat}

def ho.o.got(o: File, +files: Nat, +cps: Nat, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(HoO):
  (f, x) = r
  do IO<HoO>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    o2 : File <- S.emit(o, xs)
    return HoO{f, o2, 1n+files, Nat.add(cps, ho.cps(xs))}

def ho.o.one(l: HoLoc, w: HoO) -> IO(HoO):
  match l w:
    case HoLoc{off, len} HoO{f, o, files, cps}:
      do IO<HoO>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(off), U32.from_nat(len))
        ho.o.got(o, files, cps, r)

def ho.o.locs(ls: List<&2, HoLoc>, w: HoO) -> IO(HoO):
  match ls:
    case Nil{}:
      IO.pure(HoO, w)
    case l <> more:
      IO.bind(HoO, HoO, ho.o.one(l, w), ho.o.locs(more))

def ho.o.cands(cs: List<&2, HoCand>, w: HoO) -> IO(HoO):
  match cs:
    case Nil{}:
      IO.pure(HoO, w)
    case HoCand{h, r, n, ls} <> more:
      IO.bind(HoO, HoO, ho.o.locs(ls, w), ho.o.cands(more))

def ho.o.fin(w: HoO) -> IO(Nat & Nat):
  match w:
    case HoO{f, o, files, cps}:
      do IO<Nat & Nat>:
        File.close(f)
        File.close(o)
        return (files, cps)

def ho.v.rows(+lang: String, cs: List<&2, HoCand>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case HoCand{h, r, n, ls} <> more:
      L.v2.concat([S.b(lang), [9], r, [9], ho.dec(n), [10], ho.v.rows(lang, more)])

def ho.v.say(+lang: String, +untrained: Nat, +ncand: Nat, +nchosen: Nat, fc: Nat & Nat) -> IO(Unit):
  (+files, +cps) = fc
  IO.print(lang ++ ": " ++ Nat.show(untrained) ++ " untrained repositories, " ++ Nat.show(ncand) ++ " with >= 3 files, "
    ++ Nat.show(nchosen) ++ " chosen, " ++ Nat.show(files) ++ " files, " ++ S.str(ho.fix1(ho.tenths(cps, 100000n))) ++ " MB")

def ho.in.path(ins: List<&2, HoIn>) -> String:
  match ins:
    case Nil{}:
      "/dev/null"
    case HoIn{t, p, j, z} <> more:
      p

def ho.red.v(r: HoRed) -> HoV:
  match r:
    case RedV{m, k, s}:
      ho.v.end(s)
    case _:
      HoV{Nil{}, False{}, 0n, Nil{}, 0n, Nil{}}

# one language: its vault file and its vault.tsv rows
def ho.v.pick(+lang: String, +src: String, +out: String, s: HoV) -> IO(List<&2, U32>):
  match s:
    case HoV{r, k, n, l, +u, cands}:
      do IO<List<&2, U32>>:
        +cs : List<&2, HoCand> = List.sort(~HoCand, ~ho.cand.le, cands)
        +chosen : List<&2, HoCand> = List.take(&2, HoCand, cs, 150n)
        f : File <- IO.try(File, File.open(src, "r"))
        o : File <- IO.try(File, File.open(out, "w"))
        w : HoO <- ho.o.cands(chosen, HoO{f, o, 0n, 0n})
        fc : Nat & Nat <- ho.o.fin(w)
        ho.v.say(lang, u, List.length(&2, HoCand, cs), List.length(&2, HoCand, chosen), fc)
        return ho.v.rows(lang, chosen)

def ho.v.lang(+tmp: String, +dir: String, +lang: String, +lmask: U32, +masks: Map<&2, U32>, +ins: List<&2, HoIn>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    ho.sort(tmp, False{}, tmp ++ "/v." ++ lang, ho.parts(tmp, ins))
    r : HoRed <- ho.reduce(tmp ++ "/v." ++ lang, "/dev/null", "/dev/null", RedV{lmask, masks, HoV{[0, 0], False{}, 0n, Nil{}, 0n, Nil{}}})
    ho.v.pick(lang, ho.in.path(ins), dir ++ "/vault/" ++ lang ++ ".jsonl", ho.red.v(r))

def ho.gunzip.if(+out: String, ins: List<&2, String>) -> IO(List<&2, String>):
  match ins:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case i <> more:
      do IO<List<&2, String>>:
        ho.gunzip(out, i <> more)
        return [out]

# the pools, inflated into tmp: Lean's (its .jsonl.gz files in sorted
# order, as one file) and the Haskell agent's HF pool
def ho.pools(+tmp: String) -> IO(List<&2, String> & List<&2, String>):
  do IO<List<&2, String> & List<&2, String>>:
    lgz : List<&2, String> <- ho.glob("run/raw-new/.rawla/stage/lean/*.jsonl.gz")
    hgz : List<&2, String> <- ho.glob("run/raw-new/work/pool/hf-ghcode.jsonl.gz")
    le : List<&2, String> <- ho.gunzip.if(tmp ++ "/lean.jsonl", lgz)
    hs : List<&2, String> <- ho.gunzip.if(tmp ++ "/hf.jsonl", hgz)
    return (le, hs)

def ho.ins3(a: List<&2, HoIn>, b: List<&2, HoIn>, c: List<&2, HoIn>) -> List<&2, HoIn>:
  List.append(&2, HoIn, a, List.append(&2, HoIn, b, c))

def ho.vault.go(+tmp: String, +dir: String, +masks: Map<&2, U32>, pools: List<&2, String> & List<&2, String>) -> IO(Unit):
  (le, hs) = pools
  do IO<Unit>:
    +ia : List<&2, HoIn> <- ho.ins(["run/raw-new/agda-2f.jsonl"], True{}, 0n)
    +il : List<&2, HoIn> <- ho.ins(le, True{}, 1n)
    +ih : List<&2, HoIn> <- ho.ins(hs, True{}, 2n)
    ho.ins.check(ho.ins3(ia, il, ih))
    ho.scan.all(tmp, "2", ho.ins3(ia, il, ih))
    S.mkdir(dir ++ "/vault")
    S.mkdir(dir ++ "/holdout")
    ra : List<&2, U32> <- ho.v.lang(tmp, dir, "agda", 1, masks, ia)
    rl : List<&2, U32> <- ho.v.lang(tmp, dir, "lean", 3, masks, il)
    rh : List<&2, U32> <- ho.v.lang(tmp, dir, "haskell", 3, masks, ih)
    S.write(dir ++ "/holdout/vault.tsv", L.v2.concat([S.b("lang\trepository\tfiles\n"), ra, rl, rh]))

def ho.vault.at(+dir: String) -> IO(Unit):
  do IO<Unit>:
    +tmp : String <- S.mktemp()
    idx : List<&2, U32> <- S.read(dir ++ "/holdout/stream-index.json")
    pools : List<&2, String> & List<&2, String> <- ho.pools(tmp)
    ho.vault.go(tmp, dir, ho.xj.masks(idx), pools)
    S.rm(tmp)

# vault [DIR]
def ho.vault(xs: List<String>) -> IO(Unit):
  ho.vault.at(ho.dir.of(xs))

# holdout ----------------------------------------------------------------------------
#
# Pass 1 (pieces, mode 1): every record of every source as `repository TAB
# path TAB tag TAB offset TAB bytes TAB characters`, sorted. Pass A: the
# repositories with more than BIG (300) distinct paths. Pass B: each
# (repository, path) decided by its first version (holdout.py's counted),
# exclude.paths, the units and the languages' counts, and the held-out
# records' places (tag TAB offset TAB bytes). Pass 2 (pieces, keys): the
# content key of every held-out record, every version.

def ho.vm.rows(ls: List<&2, List<&2, U32>>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      m
    case +l <> more:
      +fs = S.split(l, 9)
      ho.vm.rows(more, Map.set(&2, List<&2, U32>, m, S.str(L.v2.nth(fs, 1n)), L.v2.nth(fs, 0n)))

# vault.tsv: each vault repository's language
def ho.vm.load(+dir: String) -> IO(Map<&2, List<&2, U32>>):
  do IO<Map<&2, List<&2, U32>>>:
    xs : List<&2, U32> <- S.read(dir ++ "/holdout/vault.tsv")
    return ho.vm.rows(List.drop(&2, List<&2, U32>, ho.lines(xs), 1n), Map.new(&2, List<&2, U32>))

def ho.red.a(r: HoRed) -> Set():
  match r:
    case RedA{s}:
      ho.a.end(s)
    case _:
      Set.new()

def ho.b.new() -> HoB:
  HoB{[0, 0], [0, 0], Nil{}, False{}, [0, 0], False{}, Nil{}, Map.new(&2, HoU), ho.ls.new(), 0n}

def ho.red.bs(r: HoRed) -> HoB:
  match r:
    case RedB{vm, bigs, s, p, h}:
      s
    case _:
      ho.b.new()

# The held-out records cut into pieces of about ho.piece() bytes, one input
# each: their list (offset TAB bytes lines, reversed bytes) and size.

def ho.piece() -> Nat:
  16777216n

type HoPc is Data:
  HoPc{tag: List<&2, U32>, lines: List<&2, U32>, bytes: Nat}

type HoPs is Data:
  HoPs{tag: List<&2, U32>, lines: List<&2, U32>, bytes: Nat, done: List<&2, HoPc>}

def ho.pc.push(+tag: List<&2, U32>, +lines: List<&2, U32>, +bytes: Nat, +done: List<&2, HoPc>) -> List<&2, HoPc>:
  Bool.pick(List<&2, HoPc>, ho.is.nil(lines), done, HoPc{tag, lines, bytes} <> done)

def ho.pc.add(same: Bool, +tag2: List<&2, U32>, +line: List<&2, U32>, +len: Nat, s: HoPs) -> HoPs:
  match same s:
    case True{} HoPs{tag, lines, +bytes, done}:
      HoPs{tag, List.reverse.go(&2, U32, line, lines), Nat.add(bytes, len), done}
    case False{} HoPs{tag, lines, bytes, done}:
      HoPs{tag2, List.reverse(&2, U32, line), len, ho.pc.push(tag, lines, bytes, done)}

def ho.pc.line(+fs: List<&2, List<&2, U32>>, s: HoPs) -> HoPs:
  match s:
    case HoPs{+tag, lines, +bytes, done}:
      ho.pc.add(Bool.and(S.eq(tag, L.v2.nth(fs, 0n)), Nat.is_lt(bytes, ho.piece())), L.v2.nth(fs, 0n),
        L.v2.concat([L.v2.nth(fs, 1n), [9], L.v2.nth(fs, 2n), [10]]), ho.num(L.v2.nth(fs, 2n)), HoPs{tag, lines, bytes, done})

def ho.pc.go(ls: List<&2, List<&2, U32>>, s: HoPs) -> HoPs:
  match ls:
    case Nil{}:
      s
    case +l <> more:
      ho.pc.go(more, ho.pc.line(S.split(l, 9), s))

def ho.pc.end(s: HoPs) -> List<&2, HoPc>:
  match s:
    case HoPs{tag, lines, bytes, done}:
      ho.pc.push(tag, lines, bytes, done)

def ho.pieces(ls: List<&2, List<&2, U32>>) -> List<&2, HoPc>:
  ho.pc.end(ho.pc.go(ls, HoPs{[0, 0], Nil{}, 0n, Nil{}}))

def ho.in.hit(+ins: List<&2, HoIn>, +t: Nat) -> Bool:
  match ins:
    case Nil{}:
      False{}
    case HoIn{+u, p, j, z} <> more:
      Nat.is_eq(u, t)

def ho.in.at.go(ins: List<&2, HoIn>, +t: Nat, hit: Bool) -> HoIn:
  match ins hit:
    case x <> more True{}:
      x
    case x <> +more False{}:
      ho.in.at.go(more, t, ho.in.hit(more, t))
    case Nil{} _:
      HoIn{t, "/dev/null", True{}, 0n}

# the input tagged t
def ho.in.at(+ins: List<&2, HoIn>, +t: Nat) -> HoIn:
  ho.in.at.go(ins, t, ho.in.hit(ins, t))

def ho.pc.job(+tmp: String, +k: Nat, +bytes: Nat, x: HoIn) -> HoJob:
  match x:
    case HoIn{t, p, j, z}:
      HoJob{bytes, ["ho-part", "keys", Bool.pick(String, j, "j", "n"), p, tmp ++ "/k." ++ Nat.show(k), tmp ++ "/x." ++ Nat.show(k)]}

# each piece's list written, its job
def ho.pc.jobs(+tmp: String, +ins: List<&2, HoIn>, pcs: List<&2, HoPc>, +k: Nat) -> IO(List<&2, HoJob>):
  match pcs:
    case Nil{}:
      IO.pure(List<&2, HoJob>, Nil{})
    case HoPc{tag, lines, +bytes} <> more:
      do IO<List<&2, HoJob>>:
        S.write(tmp ++ "/k." ++ Nat.show(k), List.reverse(&2, U32, lines))
        rest : List<&2, HoJob> <- ho.pc.jobs(tmp, ins, more, 1n+k)
        return ho.pc.job(tmp, k, bytes, ho.in.at(ins, ho.num(tag))) <> rest

def ho.xs.names(+tmp: String, n: Nat, +i: Nat) -> List<&2, String>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      (tmp ++ "/x." ++ Nat.show(i)) <> ho.xs.names(tmp, m, 1n+i)

# units.tsv and summary.txt
def ho.units.rows(us: List<&2, Sigma<&2, &2, String, _ => HoU>>) -> List<&2, U32>:
  match us:
    case Nil{}:
      Nil{}
    case (k, HoU{r, n, b}) <> more:
      L.v2.concat([S.b(k), [9], r, [9], ho.dec(n), [9], ho.dec(b), [10], ho.units.rows(more)])

def ho.units.count(us: List<&2, Sigma<&2, &2, String, _ => HoU>>, +split: Nat, +vault: Nat) -> Nat & Nat:
  match us:
    case Nil{}:
      (split, vault)
    case (k, HoU{+r, n, b}) <> more:
      ho.units.count(more, Bool.pick(Nat, S.eq(r, S.b("split")), 1n+split, split), Bool.pick(Nat, S.prefix(r, S.b("vault")), 1n+vault, vault))

def ho.sum.lang(+lang: String, +tf: Nat, +tb: Nat, +of: Nat, +ob: Nat) -> List<&2, U32>:
  L.v2.concat([ho.left(S.b(lang), 9n), [32], ho.right(ho.dec(of), 8n), S.b(" / "), ho.right(ho.dec(tf), 8n), S.b(" ("),
    ho.right(S.append(ho.fix1(ho.tenths(Nat.mul(1000n, of), Nat.max(1n, tf))), [37]), 5n), S.b(")   "),
    ho.right(ho.fix1(ho.tenths(ob, 100000n)), 8n), S.b(" / "), ho.right(ho.fix1(ho.tenths(tb, 100000n)), 8n), S.b(" MB\n")])

def ho.sum.one(+lang: String, v: HoL) -> List<&2, U32>:
  match v:
    case HoL{+tf, tb, of, ob}:
      Bool.pick(List<&2, U32>, Nat.is_eq(tf, 0n), Nil{}, ho.sum.lang(lang, tf, tb, of, ob))

# the languages seen (Python's sorted(tot))
def ho.sum.langs(ls: HoLs) -> List<&2, U32>:
  match ls:
    case HoLs{a, b, h, l, n, o}:
      L.v2.concat([ho.sum.one("agda", a), ho.sum.one("bend", b), ho.sum.one("haskell", h), ho.sum.one("lean", l), ho.sum.one("nix", n), ho.sum.one("other", o)])

def ho.sum.head(+np: Nat, +nk: Nat, sv: Nat & Nat) -> List<&2, U32>:
  (s, v) = sv
  S.b("held-out units: " ++ Nat.show(s) ++ " split, " ++ Nat.show(v) ++ " vault; " ++ Nat.show(np) ++ " paths, " ++ Nat.show(nk) ++ " content keys\n")

def ho.holdout.write(+dir: String, +nk: Nat, s: HoB) -> IO(Unit):
  match s:
    case HoB{rp, r, vl, bg, u, uh, rs, units, langs, +np}:
      +us = Map.to_list(&2, HoU, units)
      +sum = L.v2.concat([ho.sum.head(np, nk, ho.units.count(us, 0n, 0n)), S.b("language   files held out / all     bytes held out / all\n"), ho.sum.langs(langs)])
      do IO<Unit>:
        S.write(dir ++ "/holdout/units.tsv", S.append(S.b("unit\treason\tfiles\tbytes\n"), ho.units.rows(us)))
        S.write(dir ++ "/holdout/summary.txt", sum)
        IO.print(S.str(sum))

def ho.holdout.keys(+tmp: String, +dir: String, +ins: List<&2, HoIn>, rb: HoRed) -> IO(Unit):
  do IO<Unit>:
    ho.sort(tmp, False{}, tmp ++ "/held.sorted", [tmp ++ "/held"])
    hl : List<&2, U32> <- S.read(tmp ++ "/held.sorted")
    +pcs : List<&2, HoPc> = ho.pieces(ho.lines(hl))
    jobs : List<&2, HoJob> <- ho.pc.jobs(tmp, ins, pcs, 0n)
    +self : String <- ho.self()
    +w : Nat <- S.env.nat("HO_JOBS", 5n)
    ho.pool(self, w, jobs)
    ho.sort(tmp, True{}, dir ++ "/holdout/exclude.sha256", ho.xs.names(tmp, List.length(&2, HoPc, pcs), 0n))
    ks : List<&2, U32> <- S.read(dir ++ "/holdout/exclude.sha256")
    ho.holdout.write(dir, List.length(&2, List<&2, U32>, ho.lines(ks)), ho.red.bs(rb))

def ho.holdout.go(+tmp: String, +dir: String, pools: List<&2, String> & List<&2, String>) -> IO(Unit):
  (le, hs) = pools
  do IO<Unit>:
    raws : List<&2, String> <- ho.glob("run/raw-new/*.jsonl")
    vs : List<&2, String> <- ho.glob(dir ++ "/vault/*.jsonl")
    fill : List<&2, String> <- ho.glob("run/transcripts-*/*/files-*.nul")
    +srcs : List<&2, String> = List.append(&2, String, "run/code-train-v3.jsonl" <> raws, List.append(&2, String, hs, List.append(&2, String, le, vs)))
    ij : List<&2, HoIn> <- ho.ins(srcs, True{}, 0n)
    inn : List<&2, HoIn> <- ho.ins(fill, False{}, List.length(&2, String, srcs))
    +ins : List<&2, HoIn> = List.append(&2, HoIn, ij, inn)
    ho.ins.check(ins)
    ho.scan.all(tmp, "1", ins)
    ho.sort(tmp, False{}, tmp ++ "/h.sorted", ho.parts(tmp, ins))
    ra : HoRed <- ho.reduce(tmp ++ "/h.sorted", "/dev/null", "/dev/null", RedA{HoAs{[0, 0], [0, 0], 0n, Set.new()}})
    vm : Map<&2, List<&2, U32>> <- ho.vm.load(dir)
    S.mkdir(dir ++ "/holdout")
    rb : HoRed <- ho.reduce(tmp ++ "/h.sorted", dir ++ "/holdout/exclude.paths", tmp ++ "/held", RedB{vm, ho.red.a(ra), ho.b.new(), Nil{}, Nil{}})
    ho.holdout.keys(tmp, dir, ins, rb)

def ho.holdout.at(+dir: String) -> IO(Unit):
  do IO<Unit>:
    +tmp : String <- S.mktemp()
    pools : List<&2, String> & List<&2, String> <- ho.pools(tmp)
    ho.holdout.go(tmp, dir, pools)
    S.rm(tmp)

# holdout [DIR]
def ho.holdout(xs: List<String>) -> IO(Unit):
  ho.holdout.at(ho.dir.of(xs))

# exclude ----------------------------------------------------------------------------
#
# exclude.py IN OUT: a record goes when its repository, its file's directory
# or its file is a held-out unit ("unit"), its repository/path is listed
# ("path"), or (a file's text: every JSON line, a NUL id without `#`) its
# content key is listed ("content"); what is kept is copied as it stands.
# A JSONL input is cut into HO_JOBS x 4 ranges run as pieces (`ho-part
# excl`) and their outputs joined in order; a NUL input is read here.

# the counts by reason, and where each reason first struck (offset + 1; 0
# not yet): Python's dict lists the reasons in that order
type HoWhy is Data:
  HoWhy{u: Nat, p: Nat, c: Nat, fu: Nat, fp: Nat, fc: Nat}

def ho.first(+n: Nat, +f: Nat, +off: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(n, 0n), 1n+off, f)

def ho.why.add(code: Nat, +off: Nat, w: HoWhy) -> HoWhy:
  match code w:
    case 1n HoWhy{+u, p, c, +fu, fp, fc}:
      HoWhy{1n+u, p, c, ho.first(u, fu, off), fp, fc}
    case 2n HoWhy{u, +p, c, fu, +fp, fc}:
      HoWhy{u, 1n+p, c, fu, ho.first(p, fp, off), fc}
    case _ HoWhy{u, p, +c, fu, fp, +fc}:
      HoWhy{u, p, 1n+c, fu, fp, ho.first(c, fc, off)}

# the earlier of two first offsets (0: none)
def ho.fmin(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(a, 0n), b, Bool.pick(Nat, Nat.is_eq(b, 0n), a, Nat.min(a, b)))

def ho.why.merge(a: HoWhy, b: HoWhy) -> HoWhy:
  match a b:
    case HoWhy{u, p, c, +fu, +fp, +fc} HoWhy{v, q, d, +gu, +gp, +gc}:
      HoWhy{Nat.add(u, v), Nat.add(p, q), Nat.add(c, d), ho.fmin(fu, gu), ho.fmin(fp, gp), ho.fmin(fc, gc)}

type HoKv is Data:
  HoKv{f: Nat, k: Nat}

def ho.kv.le(a: HoKv, b: HoKv) -> Bool:
  match a b:
    case HoKv{+x, i} HoKv{+y, j}:
      Nat.is_le(x, y)

def ho.kv.put(+f: Nat, +k: Nat, +rest: List<&2, HoKv>) -> List<&2, HoKv>:
  Bool.pick(List<&2, HoKv>, Nat.is_eq(f, 0n), rest, HoKv{f, k} <> rest)

def ho.why.item(k: Nat, +u: Nat, +p: Nat, +c: Nat) -> List<&2, U32>:
  match k:
    case 1n:
      S.b("'unit': " ++ Nat.show(u))
    case 2n:
      S.b("'path': " ++ Nat.show(p))
    case _:
      S.b("'content': " ++ Nat.show(c))

def ho.why.items(ks: List<&2, HoKv>, +u: Nat, +p: Nat, +c: Nat) -> List<&2, List<&2, U32>>:
  match ks:
    case Nil{}:
      Nil{}
    case HoKv{f, k} <> more:
      ho.why.item(k, u, p, c) <> ho.why.items(more, u, p, c)

# Python's `dropped N {...}` (the dict's repr, the first reason first)
def ho.why.show(w: HoWhy) -> String:
  match w:
    case HoWhy{+u, +p, +c, fu, fp, fc}:
      "dropped " ++ Nat.show(Nat.add(u, Nat.add(p, c))) ++ " {"
        ++ S.str(ho.join(ho.why.items(List.sort(~HoKv, ~ho.kv.le, ho.kv.put(fu, 1n, ho.kv.put(fp, 2n, ho.kv.put(fc, 3n, Nil{})))), u, p, c), S.b(", "))) ++ "}"

def ho.why.line(+n: Nat, w: HoWhy) -> List<&2, U32>:
  match w:
    case HoWhy{u, p, c, fu, fp, fc}:
      S.b(Nat.show(n) ++ " " ++ Nat.show(u) ++ " " ++ Nat.show(p) ++ " " ++ Nat.show(c) ++ " " ++ Nat.show(fu) ++ " " ++ Nat.show(fp) ++ " " ++ Nat.show(fc) ++ "\n")

def ho.why.read(+fs: List<&2, List<&2, U32>>) -> HoWhy:
  HoWhy{ho.num(L.v2.nth(fs, 1n)), ho.num(L.v2.nth(fs, 2n)), ho.num(L.v2.nth(fs, 3n)), ho.num(L.v2.nth(fs, 4n)), ho.num(L.v2.nth(fs, 5n)), ho.num(L.v2.nth(fs, 6n))}

def ho.x.content(go: Bool, +e: L.Excl, +text: List<&2, U32>) -> Nat:
  match go:
    case True{}:
      Bool.pick(Nat, L.v2.held.key(e, L.v2.key(text)), 3n, 0n)
    case False{}:
      0n

# 0 kept, 1 unit, 2 path, 3 content
def ho.x.code(+e: L.Excl, +id: List<&2, U32>, +text: List<&2, U32>, +file: Bool) -> Nat:
  +r = L.v2.repo.of(id)
  +p = L.v2.path.of(id)
  +slash = S.append(r, [47])
  +unit = Bool.or(Bool.or(ho.in(L.v2.ex.units(e), r), ho.in(L.v2.ex.units(e), S.append(slash, L.v2.parent(p, 47)))), ho.in(L.v2.ex.units(e), S.append(slash, p)))
  +path = ho.in(L.v2.ex.paths(e), L.v2.concat([r, [9], p]))
  Bool.pick(Nat, unit, 1n, Bool.pick(Nat, path, 2n, ho.x.content(Bool.and(file, Bool.and(Bool.not(unit), Bool.not(path))), e, text)))

def ho.x.doc(+e: L.Excl, m: Maybe<&2, J.Doc>) -> Nat:
  match m:
    case None{}:
      4n
    case Some{J.Doc{+i, +t}}:
      ho.x.code(e, i, t, True{})

def ho.x.rcode(j: Bool, +e: L.Excl, +head: List<&2, U32>, +xs: List<&2, U32>) -> Nat:
  match j:
    case True{}:
      ho.x.doc(e, J.doc(xs))
    case False{}:
      ho.x.code(e, head, ho.nul.text(xs), Bool.not(L.v2.has(head, 35)))

type HoX is Type:
  HoX{f: File, o: File, n: Nat, why: HoWhy}

def ho.x.decide(code: Nat, +off: Nat, f: File, o: File, +n: Nat, why: HoWhy, xs: List<&2, U32>) -> IO(HoX):
  match code:
    case 0n:
      do IO<HoX>:
        o2 : File <- S.emit(o, xs)
        return HoX{f, o2, 1n+n, why}
    case 4n:
      do IO<HoX>:
        File.close(f)
        File.close(o)
        IO.die(HoX, 1, "exclude: a line is not a JSON {\"id\", \"text\"} object")
    case k:
      IO.pure(HoX, HoX{f, o, n, ho.why.add(k, off, why)})

def ho.x.got(+j: Bool, +e: L.Excl, +head: List<&2, U32>, +off: Nat, o: File, +n: Nat, why: HoWhy, q: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(HoX):
  (f, res) = q
  do IO<HoX>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, res)
    ho.x.decide(ho.x.rcode(j, e, head, xs), off, f, o, n, why, xs)

# a record that starts before end is decided, one past it is the next range's
def ho.x.one.if(here: Bool, +j: Bool, +e: L.Excl, head: List<&2, U32>, +off: Nat, len: Nat, x: HoX) -> IO(HoX):
  match here x:
    case True{} HoX{f, o, n, why}:
      do IO<HoX>:
        q : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(off), U32.from_nat(len))
        ho.x.got(j, e, head, off, o, n, why, q)
    case False{} x:
      IO.pure(HoX, x)

def ho.x.one(+j: Bool, +e: L.Excl, +end: Nat, r: HoRec, x: HoX) -> IO(HoX):
  match r:
    case HoRec{head, +off, len, cp}:
      ho.x.one.if(Nat.is_lt(off, end), j, e, head, off, len, x)

def ho.x.recs(rs: List<&2, HoRec>, +j: Bool, +e: L.Excl, +end: Nat, x: HoX) -> IO(HoX):
  match rs:
    case Nil{}:
      IO.pure(HoX, x)
    case r <> more:
      IO.bind(HoX, HoX, ho.x.one(j, e, end, r, x), ho.x.recs(more, j, e, end))

type HoXs is Type:
  HoXs{f: File, o: File, n: Nat, why: HoWhy, off: Nat, more: Bool, sc: HoSc}

def ho.x.pack(+off: Nat, +more: Bool, sc: HoSc, x: HoX) -> HoXs:
  match x:
    case HoX{f, o, n, why}:
      HoXs{f, o, n, why, off, more, sc}

def ho.x.chunk(+j: Bool, +e: L.Excl, +end: Nat, +off: Nat, +more: Bool, x: HoX, r: HoSc & List<&2, HoRec>) -> IO(HoXs):
  (+sc, rs) = r
  do IO<HoXs>:
    x2 : HoX <- ho.x.recs(rs, j, e, end, x)
    return ho.x.pack(off, Bool.and(more, Nat.is_lt(ho.sc.start(sc), end)), sc, x2)

def ho.x.got.chunk(+j: Bool, +e: L.Excl, +end: Nat, o: File, +n: Nat, why: HoWhy, +off: Nat, sc: HoSc, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(HoXs):
  (f, x) = r
  do IO<HoXs>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    ho.x.chunk(j, e, end, Nat.add(off, S.len(xs)), Bool.not(ho.is.nil(xs)), HoX{f, o, n, why}, ho.sc.take(ho.sc.scan(xs, sc)))

def ho.x.step(+j: Bool, +e: L.Excl, +end: Nat, s: HoXs) -> IO(HoXs):
  match s:
    case HoXs{f, o, n, why, +off, m, sc}:
      do IO<HoXs>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(off), ho.chunk())
        ho.x.got.chunk(j, e, end, o, n, why, off, sc, r)

def ho.x.go(fuel: Nat, +j: Bool, +e: L.Excl, +end: Nat, s: HoXs) -> IO(HoXs):
  match fuel s:
    case 1n+k HoXs{f, o, n, why, off, True{}, sc}:
      IO.bind(HoXs, HoXs, ho.x.step(j, e, end, HoXs{f, o, n, why, off, True{}, sc}), ho.x.go(k, j, e, end))
    case _ s:
      IO.pure(HoXs, s)

def ho.x.close(x: HoX) -> IO(Nat & HoWhy):
  match x:
    case HoX{f, o, n, why}:
      do IO<Nat & HoWhy>:
        File.close(f)
        File.close(o)
        return (n, why)

def ho.x.fin(+j: Bool, +e: L.Excl, +end: Nat, s: HoXs) -> IO(Nat & HoWhy):
  match s:
    case HoXs{f, o, n, why, off, m, sc}:
      do IO<Nat & HoWhy>:
        x : HoX <- ho.x.recs(ho.sc.last(sc), j, e, end, HoX{f, o, n, why})
        ho.x.close(x)

def ho.why.new() -> HoWhy:
  HoWhy{0n, 0n, 0n, 0n, 0n, 0n}

# the records of src that start in [start, end) less the held out, into dst
def ho.x.range(+e: L.Excl, +j: Bool, +src: String, +dst: String, +start: Nat, +end: Nat) -> IO(Nat & HoWhy):
  do IO<Nat & HoWhy>:
    f : File <- IO.try(File, File.open(src, "r"))
    o : File <- IO.try(File, File.open(dst, "w"))
    s : HoXs <- ho.x.go(ho.big(), j, e, end, HoXs{f, o, 0n, ho.why.new(), ho.sc.from(j, start), True{}, ho.sc.new(j, start)})
    ho.x.fin(j, e, end, s)

def ho.x.say(+src: String, r: Nat & HoWhy) -> IO(Unit):
  (n, why) = r
  IO.print(src ++ ": kept " ++ Nat.show(n) ++ ", " ++ ho.why.show(why))

def ho.x.part.fin(+out: String, r: Nat & HoWhy) -> IO(Unit):
  (+n, why) = r
  S.write(out ++ ".why", ho.why.line(n, why))

# ho-part excl FILE START END OUT DIR: a JSONL range, its counts in OUT.why
def ho.x.part(+file: String, +start: Nat, +end: Nat, +out: String, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +e : L.Excl <- L.v2.ex.load(dir ++ "/holdout")
    r : Nat & HoWhy <- ho.x.range(e, True{}, file, out, start, end)
    ho.x.part.fin(out, r)

# the pieces' counts summed
def ho.x.sum(ps: List<&2, String>, +n: Nat, why: HoWhy) -> IO(Nat & HoWhy):
  match ps:
    case Nil{}:
      IO.pure(Nat & HoWhy, (n, why))
    case p <> more:
      do IO<Nat & HoWhy>:
        xs : List<&2, U32> <- S.read(p ++ ".why")
        +fs : List<&2, List<&2, U32>> = S.split(S.chomp(xs), 32)
        ho.x.sum(more, Nat.add(n, ho.num(L.v2.nth(fs, 0n))), ho.why.merge(why, ho.why.read(fs)))

def ho.x.piece(+z: Nat, +w: Nat) -> Nat:
  Nat.max(1048576n, 1n+Nat.div(z, Nat.mul(4n, Nat.max(1n, w))))

def ho.x.ranges(fuel: Nat, +s: Nat, +z: Nat, +r: Nat, go: Bool) -> List<&2, Nat>:
  match fuel go:
    case 1n+k True{}:
      +n = Nat.add(s, r)
      s <> ho.x.ranges(k, n, z, r, Nat.is_lt(n, z))
    case _ _:
      Nil{}

def ho.x.jobs(+tmp: String, +src: String, +dir: String, +r: Nat, ss: List<&2, Nat>, +k: Nat) -> List<&2, HoJob>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> more:
      HoJob{r, ["ho-part", "excl", src, Nat.show(s), Nat.show(Nat.add(s, r)), tmp ++ "/e." ++ Nat.show(k), dir]} <> ho.x.jobs(tmp, src, dir, r, more, 1n+k)

def ho.x.outs(+tmp: String, n: Nat, +k: Nat) -> List<&2, String>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      (tmp ++ "/e." ++ Nat.show(k)) <> ho.x.outs(tmp, m, 1n+k)

def ho.cat(+out: String, ins: List<&2, String>) -> IO(Unit):
  match ins:
    case Nil{}:
      S.write(out, Nil{})
    case i <> more:
      ho.sh("cat into " ++ out, [], "sh", List.append(&1, String, ["-c", "o=$1; shift; exec cat -- \"$@\" > \"$o\"", "sh", out], ho.l1(i <> more)))

def ho.x.jsonl(+src: String, +dst: String, +dir: String, +z: Nat) -> IO(Unit):
  do IO<Unit>:
    +tmp : String <- S.mktemp()
    +self : String <- ho.self()
    +w : Nat <- S.env.nat("HO_JOBS", 5n)
    +r : Nat = ho.x.piece(z, w)
    +ss : List<&2, Nat> = ho.x.ranges(1n+Nat.div(z, r), 0n, z, r, Nat.is_lt(0n, z))
    ho.pool(self, w, ho.x.jobs(tmp, src, dir, r, ss, 0n))
    +outs : List<&2, String> = ho.x.outs(tmp, List.length(&2, Nat, ss), 0n)
    ho.cat(dst, outs)
    res : Nat & HoWhy <- ho.x.sum(outs, 0n, ho.why.new())
    ho.x.say(src, res)
    S.rm(tmp)

def ho.x.nul(+src: String, +dst: String, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +e : L.Excl <- L.v2.ex.load(dir ++ "/holdout")
    r : Nat & HoWhy <- ho.x.range(e, False{}, src, dst, 0n, ho.big())
    ho.x.say(src, r)

def ho.exclude.go(j: Bool, +src: String, +dst: String, +dir: String, +z: Nat) -> IO(Unit):
  match j:
    case True{}:
      ho.x.jsonl(src, dst, dir, z)
    case False{}:
      ho.x.nul(src, dst, dir)

def ho.exclude.run(+src: String, +dst: String, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +z : Nat <- S.size(src)
    ho.ins.check([HoIn{0n, src, True{}, z}])
    ho.exclude.go(S.suffix(S.b(src), S.b(".jsonl")), src, dst, dir, z)

def ho.exclude.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: exclude IN OUT [DIR]")

# exclude IN OUT [DIR]
def ho.exclude(xs: List<String>) -> IO(Unit):
  match xs:
    case src <> dst <> Nil{}:
      ho.exclude.run(src, dst, "run/v2")
    case src <> dst <> dir <> Nil{}:
      ho.exclude.run(src, dst, dir)
    case _:
      ho.exclude.usage()

# The internal subcommand -----------------------------------------------------------

def ho.part.excl(xs: List<String>) -> IO(Unit):
  match xs:
    case file <> +s <> +e <> out <> dir <> Nil{}:
      ho.x.part(file, ho.num(S.b(s)), ho.num(S.b(e)), out, dir)
    case _:
      ho.part.usage()

def ho.part.code(+c: String) -> Nat:
  Bool.pick(Nat, String.eq(c, "scan"), 0n, Bool.pick(Nat, String.eq(c, "keys"), 1n, Bool.pick(Nat, String.eq(c, "excl"), 2n, 3n)))

def ho.part.run(k: Nat, xs: List<String>) -> IO(Unit):
  match k:
    case 0n:
      ho.part.scan(xs)
    case 1n:
      ho.part.keys(xs)
    case 2n:
      ho.part.excl(xs)
    case _:
      ho.part.usage()

# `ho-part scan ...`, `ho-part keys ...` or `ho-part excl ...`: a piece of
# stream-index, vault, holdout or exclude (the pool runs the binary so)
def ho.part(xs: List<String>) -> IO(Unit):
  match xs:
    case +c <> more:
      ho.part.run(ho.part.code(c), more)
    case Nil{}:
      ho.part.usage()
