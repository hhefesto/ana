import Base
import ./Sys.bend as S
import ./Json.bend as J
import ./Sha256.bend as H

# bend-extract: the {id, text} JSON-lines code corpus from Hackage tarballs
# and cloned repositories (what deploy/extract-code.sh did).
#
#   bend-extract OUT.jsonl [SOURCES_DIR]
#
# Run it from the repository root.  SOURCES_DIR (default run/code-sources)
# holds tarballs/*.tar.gz (Hackage packages), repos/NAME/ (cloned
# repositories, under the license gate), own/NAME/ (the user's) and
# curated/NAME/ (chosen by name; the user's decision of 2026-09-25).
#
# Ids are `group/path`, the group carrying its source as a namespace
# (hackage:foo, repo:foo, own:foo, curated:foo): the pools share bare names
# (the Hackage package cubical and the Agda repository cubical are different
# projects).  plan-corpus's PACK_GROUP packs within a group.
#
# A file is taken when its name ends in a source extension (any case), it
# holds 1 to 1,000,000 bytes, and without its NUL bytes it is UTF-8 by
# glibc's rules (what `iconv -f UTF-8 -t UTF-8 -c` passes with status 0);
# its text is then what `jq -Rs` makes of those bytes (a sequence past
# U+10FFFF becomes U+FFFD).  Files of equal content (SHA-256 of those
# bytes) are kept once, the first seen, across the train and held-out
# streams, so a file vendored into a held-out package cannot reappear there.
#
# Licenses.  A Hackage package's first `License:` / `license:` line (of the
# first .cabal found at most two levels down) must name a permissive license
# (Cabal and SPDX spellings; anything else, or none, drops the package).  A
# repository's primary license file (LICENSE, LICENCE, COPYING, then their
# .md / .txt forms) must hold a grant (MIT, BSD, Apache, ISC, MPL, CC0,
# public domain, CC-BY-4.0) and no copyleft or restricted Creative Commons
# text; copyleft wins.  own/ and curated/ are taken without the gate.
#
# Holdout (HOLDOUT_OUT set): whole sources, by name.  A group named in
# HOLDOUT_GROUPS (default repo:cubical repo:batteries repo:nixpkgs/nixos
# repo:idris2/tests) is held out whole; a named subtree (a name with a
# slash) holds out the files under it; otherwise a source is held out when
# the first six hex digits of the SHA-256 of its bare name (the group
# without its namespace), mod 100, are below HOLDOUT_PERCENT (2).  own/ and
# curated/ are never held out.  Without HOLDOUT_OUT everything is train.
#
# Order.  Sources in byte order of their paths (tarballs, then repos/,
# own/, curated/), files within a source in byte order of their paths, so
# the output and which of two equal files is kept no longer depend on the
# file system's directory order or the locale (the script this replaces
# followed `find`).
#
# Both files are written to OUT.tmp (HOLDOUT_OUT.tmp) and renamed when the
# pass is complete; an empty corpus is refused.

# Counters ---------------------------------------------------------------

type Ct is Data:
  Ct{key: String, n: Nat}

def ct.bump(cs: List<&2, Ct>, +k: String) -> List<&2, Ct>:
  match cs:
    case Nil{}:
      [Ct{k, 1n}]
    case Ct{+x, +n} <> +more:
      Bool.pick(List<&2, Ct>, String.eq(x, k), Ct{x, 1n+n} <> more, Ct{x, n} <> ct.bump(more, k))

def ct.get(cs: List<&2, Ct>, +k: String) -> Nat:
  match cs:
    case Nil{}:
      0n
    case Ct{+x, +n} <> more:
      Bool.pick(Nat, String.eq(x, k), n, ct.get(more, k))

# The run's state: the two outputs, the contents seen, the counters.
type Xst is Type:
  Xst{out: File, hout: File, seen: Set(), cs: List<&2, Ct>}

def es.bump(s: Xst, +k: String) -> Xst:
  match s:
    case Xst{o, h, seen, cs}:
      Xst{o, h, seen, ct.bump(cs, k)}

# The holdout settings: on (HOLDOUT_OUT set), the percent, the named groups.
type Cf is Data:
  Cf{on: Bool, pct: Nat, groups: List<&2, List<&2, U32>>}

# Text -------------------------------------------------------------------

def lower(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(U32, Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), U32.add(c, 32), c) <> lower(t)

def nat.of(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n)

def nth(xs: List<&2, List<&2, U32>>, n: Nat) -> List<&2, U32>:
  match xs n:
    case x <> more 0n:
      x
    case x <> more 1n+k:
      nth(more, k)
    case Nil{} _:
      Nil{}

def any.infix(+xs: List<&2, U32>, ps: List<String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> more:
      Bool.or(S.infix(xs, S.b(p)), any.infix(xs, more))

def any.suffix(+xs: List<&2, U32>, ps: List<String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> more:
      Bool.or(S.suffix(xs, S.b(p)), any.suffix(xs, more))

def any.eq(+xs: List<&2, U32>, ps: List<String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> more:
      Bool.or(S.eq(xs, S.b(p)), any.eq(xs, more))

# the bytes before the first c (all of them when there is none)
def upto(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), Nil{}, h <> upto(t, c))

# the bytes after the first c (all of them when there is none: ${x#*c})
def after.go(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), t, after.go(t, c))

def after(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.infix(xs, [c]), after.go(xs, c), xs)

# the bytes before the last c (all of them when there is none: ${x%c*})
def before.last(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  +r = List.reverse(&2, U32, xs)
  Bool.pick(List<&2, U32>, S.infix(r, [c]), List.reverse(&2, U32, after.go(r, c)), xs)

# the file's source extensions (grep -Ei on the whole path)
def ext.ok(+path: List<&2, U32>) -> Bool:
  any.suffix(lower(path), [".hs", ".lhs", ".nix", ".agda", ".lagda", ".lagda.md", ".lagda.tex", ".lagda.rst", ".lean", ".idr", ".ipkg", ".bend"])

# UTF-8, glibc's way ---------------------------------------------------------

# The length of the sequence a byte starts, 0 when it cannot start one.
# glibc takes the old five- and six-byte forms (up to U+7FFFFFFF) and
# refuses overlong forms and surrogates.
def lead.len(+b: U32) -> Nat:
  Bool.pick(Nat, U32.is_lt(b, 128), 1n, Bool.pick(Nat, U32.is_lt(b, 194), 0n, Bool.pick(Nat, U32.is_lt(b, 224), 2n,
    Bool.pick(Nat, U32.is_lt(b, 240), 3n, Bool.pick(Nat, U32.is_lt(b, 248), 4n, Bool.pick(Nat, U32.is_lt(b, 252), 5n,
      Bool.pick(Nat, U32.is_lt(b, 254), 6n, 0n)))))))

def lead.bits(+b: U32, n: Nat) -> U32:
  match n:
    case 2n:
      U32.and(b, 31)
    case 3n:
      U32.and(b, 15)
    case 4n:
      U32.and(b, 7)
    case 5n:
      U32.and(b, 3)
    case 6n:
      U32.and(b, 1)
    case _:
      b

def cp.min(n: Nat) -> U32:
  match n:
    case 3n:
      2048
    case 4n:
      65536
    case 5n:
      2097152
    case 6n:
      67108864
    case _:
      128

def cp.ok(+cp: U32, +n: Nat) -> Bool:
  Bool.and(U32.is_le(cp.min(n), cp), Bool.not(Bool.and(U32.is_le(55296, cp), U32.is_le(cp, 57343))))

# need: continuation bytes still to come; cp: the scalar so far; n: the
# sequence's length; ok: nothing refused so far
def utf.go(xs: List<&2, U32>, need: Nat, +cp: U32, +n: Nat, +ok: Bool) -> Bool:
  match xs need:
    case Nil{} 0n:
      ok
    case Nil{} 1n+k:
      False{}
    case +b <> t 0n:
      +l = lead.len(b)
      utf.go(t, Nat.sub(l, 1n), lead.bits(b, l), l, Bool.and(ok, Bool.not(Nat.is_eq(l, 0n))))
    case +b <> t 1n+(+k):
      +c2 = U32.or(U32.shln(cp, 6n), U32.and(b, 63))
      +cont = Bool.and(U32.is_le(128, b), U32.is_lt(b, 192))
      utf.go(t, k, c2, n, Bool.and(ok, Bool.and(cont, Bool.or(Bool.not(Nat.is_eq(k, 0n)), cp.ok(c2, n)))))

def utf.valid(xs: List<&2, U32>) -> Bool:
  utf.go(xs, 0n, 0, 0n, True{})

# What jq -Rs makes of them: a four-byte sequence past U+10FFFF is one
# U+FFFD; a sequence led by F5..FD is one U+FFFD per byte.

def fffd() -> List<&2, U32>:
  [239, 191, 189]

def fffds(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      List.append(&2, U32, fffd(), fffds(k))

def byte.at(+xs: List<&2, U32>, +i: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, xs, i), 0)

# 0: keep one byte; 1: one U+FFFD for four bytes; n > 1: n of them for n
def jq.code(hi: Bool, +b: U32, +t: List<&2, U32>) -> Nat:
  match hi:
    case False{}:
      0n
    case True{}:
      +cp = U32.or(U32.or(U32.shln(U32.and(b, 7), 18n), U32.shln(U32.and(byte.at(t, 0n), 63), 12n)),
        U32.or(U32.shln(U32.and(byte.at(t, 1n), 63), 6n), U32.and(byte.at(t, 2n), 63)))
      Bool.pick(Nat, U32.is_lt(b, 245), Bool.pick(Nat, U32.is_lt(cp, 1114112), 0n, 1n),
        Bool.pick(Nat, U32.is_lt(b, 248), 4n, Bool.pick(Nat, U32.is_lt(b, 252), 5n, 6n)))

def jq.at(+xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +b <> +t:
      jq.code(U32.is_le(240, b), b, t)

def jq.fix(fuel: Nat, xs: List<&2, U32>, code: Nat) -> List<&2, U32>:
  match fuel xs code:
    case 0n _ _:
      Nil{}
    case _ Nil{} _:
      Nil{}
    case 1n+f b <> +t 0n:
      b <> jq.fix(f, t, jq.at(t))
    case 1n+f b <> +t 1n:
      +r = List.drop(&2, U32, t, 3n)
      List.append(&2, U32, fffd(), jq.fix(f, r, jq.at(r)))
    case 1n+f b <> +t +n:
      +r = List.drop(&2, U32, t, Nat.sub(n, 1n))
      List.append(&2, U32, fffds(n), jq.fix(f, r, jq.at(r)))

def has.hi(xs: List<&2, U32>, +acc: Bool) -> Bool:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      has.hi(t, Bool.or(acc, U32.is_le(244, h)))

def jq.maybe(hi: Bool, +xs: List<&2, U32>) -> List<&2, U32>:
  match hi:
    case False{}:
      xs
    case True{}:
      jq.fix(1n+S.len(xs), xs, jq.at(xs))

def jq.text(+xs: List<&2, U32>) -> List<&2, U32>:
  jq.maybe(has.hi(xs, False{}), xs)

# The content key: the SHA-256 digest as eight 32-bit characters ------------

def key.of(h: H.H8) -> String:
  match h:
    case H.H8{a, b, c, d, e, f, g, x}:
      SCon{Chr{a}, SCon{Chr{b}, SCon{Chr{c}, SCon{Chr{d}, SCon{Chr{e}, SCon{Chr{f}, SCon{Chr{g}, SCon{Chr{x}, SNil{}}}}}}}}}

def digest(+xs: List<&2, U32>) -> String:
  +padded = H.pad(xs)
  key.of(H.blocks(Nat.add(Nat.div(List.length(&2, U32, padded), 64n), 1n), H.H0(), H.split64(64n, padded)))

# Holdout ------------------------------------------------------------------

def hexv(+c: U32) -> Nat:
  U32.to_nat(Bool.pick(U32, U32.is_le(c, 57), U32.sub(c, 48), U32.sub(c, 87)))

def hex.val(xs: List<&2, U32>, +v: Nat) -> Nat:
  match xs:
    case Nil{}:
      v
    case +c <> t:
      hex.val(t, Nat.add(Nat.mul(v, 16n), hexv(c)))

# the first six hex digits of the name's SHA-256, mod 100, below pct
def hold.bucket(+bare: List<&2, U32>, +pct: Nat) -> Bool:
  Nat.is_lt(Nat.mod(hex.val(List.take(&2, U32, S.b(H.sha256(bare)), 6n), 0n), 100n), pct)

# a named group (no slash) equal to group
def hold.named(gs: List<&2, List<&2, U32>>, +group: List<&2, U32>) -> Bool:
  match gs:
    case Nil{}:
      False{}
    case +w <> more:
      Bool.or(Bool.and(Bool.not(S.infix(w, [47])), S.eq(w, group)), hold.named(more, group))

# a named subtree (with a slash) equal to target
def hold.sub(gs: List<&2, List<&2, U32>>, +target: List<&2, U32>) -> Bool:
  match gs:
    case Nil{}:
      False{}
    case +w <> more:
      Bool.or(Bool.and(S.infix(w, [47]), S.eq(w, target)), hold.sub(more, target))

# is the whole source held out (spare: own/ and curated/)
def hold.source(c: Cf, +spare: Bool, +group: List<&2, U32>) -> Bool:
  match c:
    case Cf{+on, +pct, gs}:
      Bool.and(Bool.and(on, Bool.not(spare)), Bool.or(hold.named(gs, group), hold.bucket(after(group, 58), pct)))

# is the file held out by a named subtree
def hold.path(c: Cf, +group: List<&2, U32>, +rel: List<&2, U32>) -> Bool:
  match c:
    case Cf{+on, pct, gs}:
      Bool.and(on, hold.sub(gs, S.append(group, 47 <> upto(rel, 47))))

# Licenses -------------------------------------------------------------------

def space(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.and(U32.is_le(10, c), U32.is_le(c, 13)))

def drop.space(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> +t:
      Bool.pick(List<&2, U32>, space(c), drop.space(t), c <> t)

# `awk 'sub(/^[Ll]icense:[[:space:]]*/, "") { print; exit }' | tr -d '\r'`
def lic.value(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      Bool.pick(List<&2, U32>, Bool.or(S.prefix(l, S.b("License:")), S.prefix(l, S.b("license:"))),
        List.filter(~U32, ~(c => U32.is_ne(c, 13)), drop.space(List.drop(&2, U32, l, 8n))), lic.value(more))

# the value lowercased (A-Z only) and without spaces, against the names
def permissive(+v: List<&2, U32>) -> Bool:
  any.eq(List.filter(~U32, ~(c => U32.is_ne(c, 32)), lower(v)), ["bsd3", "bsd-3-clause", "bsd2", "bsd-2-clause",
    "bsd-2-clause-patent", "mit", "isc", "apache-2.0", "apache2.0", "apache", "mpl-2.0", "mpl2.0", "publicdomain",
    "cc0-1.0", "unlicense", "bsd3clause", "0bsd", "zlib", "bsd"])

# `SPDX-License-Identifier:.*(GPL|AGPL|LGPL)` within a line
def spdx.at(+l: List<&2, U32>, m: Maybe<&2, Nat>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{+k}:
      S.infix(List.drop(&2, U32, l, Nat.add(k, 24n)), S.b("gpl"))

def spdx(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      Bool.or(spdx.at(l, S.find(l, S.b("spdx-license-identifier:"), 0n)), spdx(more))

# a license file's text (lowercased): copyleft or a restricted Creative
# Commons variant
def copyleft(+t: List<&2, U32>) -> Bool:
  Bool.or(any.infix(t, ["gnu general public license", "gnu lesser general public license", "gnu affero general public license",
    "gnu gpl", "gnu lgpl", "gnu agpl", "sharealike", "noncommercial", "noderivatives"]), spdx(S.split.lines(t)))

def grant(+t: List<&2, U32>) -> Bool:
  any.infix(t, ["permission is hereby granted, free of charge", "redistribution and use in source", "apache license",
    "isc license", "mozilla public license", "cc0", "public domain", "mit license", "attribution 4.0 international"])

# `$(cat FILE)` drops NUL bytes; grep -i matches ASCII case-blind
def lic.text.ok(+t: List<&2, U32>) -> Bool:
  +x = lower(S.no.nul(t))
  Bool.and(Bool.not(copyleft(x)), grant(x))

# Listings: `find ... | LC_ALL=C sort`, one record per line ------------------

def listing(+cmd: String, +arg: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    o : S.Out <- S.run.quiet(".", ["LC_ALL=C"], 86400, "sh", ["-c", cmd ++ " | sort", "sh", arg], Nil{})
    return S.split.lines(S.Out.text(o))

# a file: its path, find's type letter, depth and size
type Fr is Data:
  Fr{path: List<&2, U32>, kind: List<&2, U32>, depth: Nat, size: Nat}

# `%p\t%y\t%d\t%s` (a tab in the path stays in the path)
def rec4(+l: List<&2, U32>) -> Fr:
  +fs = S.split(l, 9)
  +n = List.length(&2, List<&2, U32>, fs)
  Fr{S.join(List.take(&2, List<&2, U32>, fs, Nat.sub(n, 3n)), 9), nth(fs, Nat.sub(n, 3n)), nat.of(nth(fs, Nat.sub(n, 2n))), nat.of(nth(fs, Nat.sub(n, 1n)))}

# `%p\t%s`
def rec2(+l: List<&2, U32>) -> Fr:
  +fs = S.split(l, 9)
  +n = List.length(&2, List<&2, U32>, fs)
  Fr{S.join(List.take(&2, List<&2, U32>, fs, Nat.sub(n, 1n)), 9), S.b("f"), 0n, nat.of(nth(fs, Nat.sub(n, 1n)))}

def recs4(ls: List<&2, List<&2, U32>>) -> List<&2, Fr>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      rec4(l) <> recs4(more)

# the source files among them (regular, a source extension)
def sources(rs: List<&2, Fr>) -> List<&2, Fr>:
  match rs:
    case Nil{}:
      Nil{}
    case Fr{+p, +k, +d, +z} <> more:
      +rest = sources(more)
      Bool.pick(List<&2, Fr>, Bool.and(S.eq(k, S.b("f")), ext.ok(p)), Fr{p, k, d, z} <> rest, rest)

def Fr.path(+r: Fr) -> List<&2, U32>:
  match r:
    case Fr{p, k, d, z}:
      p

def sources2(ls: List<&2, List<&2, U32>>) -> List<&2, Fr>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +rest = sources2(more)
      +r = rec2(l)
      Bool.pick(List<&2, Fr>, ext.ok(Fr.path(r)), r <> rest, rest)

# `find PKG -maxdepth 2 -name '*.cabal' -print -quit`, the first in path order
def cabal.of(rs: List<&2, Fr>) -> Maybe<&2, Fr>:
  match rs:
    case Nil{}:
      None{}
    case Fr{+p, +k, +d, +z} <> more:
      Bool.pick(Maybe<&2, Fr>, Bool.and(Nat.is_le(d, 2n), S.suffix(p, S.b(".cabal"))), Some{Fr{p, k, d, z}}, cabal.of(more))

# One file ---------------------------------------------------------------------

def doc.line(+group: List<&2, U32>, +rel: List<&2, U32>, +clean: List<&2, U32>) -> List<&2, U32>:
  S.append(J.line(S.append(group, 47 <> rel), jq.text(clean)), [10])

def emit.put(dup: Bool, held: Bool, +group: List<&2, U32>, +rel: List<&2, U32>, +clean: List<&2, U32>, +key: String, o: File, h: File, seen: Set(), cs: List<&2, Ct>) -> IO(Xst):
  match dup held:
    case True{} _:
      IO.pure(Xst, Xst{o, h, seen, cs})
    case False{} False{}:
      do IO<Xst>:
        o2 : File <- S.emit(o, doc.line(group, rel, clean))
        return Xst{o2, h, Set.add(seen, key), ct.bump(cs, "kept")}
    case False{} True{}:
      do IO<Xst>:
        h2 : File <- S.emit(h, doc.line(group, rel, clean))
        return Xst{o, h2, Set.add(seen, key), ct.bump(cs, "heldkept")}

def emit.seen(held: Bool, +group: List<&2, U32>, +rel: List<&2, U32>, +clean: List<&2, U32>, +key: String, o: File, h: File, cs: List<&2, Ct>, r: Set() & Bool) -> IO(Xst):
  (seen, dup) = r
  emit.put(dup, held, group, rel, clean, key, o, h, seen, cs)

def emit.route(+held: Bool, +group: List<&2, U32>, +rel: List<&2, U32>, +clean: List<&2, U32>, +key: String, s: Xst) -> IO(Xst):
  match s:
    case Xst{o, h, seen, cs}:
      emit.seen(held, group, rel, clean, key, o, h, ct.bump(ct.bump(cs, Bool.pick(String, held, "held", "emitted")), "total"), Set.has(seen, key))

def emit.valid(ok: Bool, +c: Cf, +group: List<&2, U32>, +rel: List<&2, U32>, +hold: Bool, +clean: List<&2, U32>, s: Xst) -> IO(Xst):
  match ok:
    case False{}:
      IO.pure(Xst, es.bump(s, "undecodable"))
    case True{}:
      emit.route(Bool.or(hold, hold.path(c, group, rel)), group, rel, clean, digest(clean), s)

def emit.read(+c: Cf, +group: List<&2, U32>, +rel: List<&2, U32>, +hold: Bool, +clean: List<&2, U32>, s: Xst) -> IO(Xst):
  emit.valid(Bool.and(Nat.is_lt(0n, S.len(clean)), utf.valid(clean)), c, group, rel, hold, clean, s)

def emit.sized(ok: Bool, +c: Cf, +group: List<&2, U32>, +rel: List<&2, U32>, +path: List<&2, U32>, +hold: Bool, s: Xst) -> IO(Xst):
  match ok:
    case False{}:
      IO.pure(Xst, es.bump(s, "size"))
    case True{}:
      do IO<Xst>:
        xs : List<&2, U32> <- S.read(S.str(path))
        emit.read(c, group, rel, hold, S.no.nul(xs), s)

def emit.one(+c: Cf, +group: List<&2, U32>, +rel: List<&2, U32>, +path: List<&2, U32>, +size: Nat, +hold: Bool, s: Xst) -> IO(Xst):
  emit.sized(Bool.and(Nat.is_lt(0n, size), Nat.is_le(size, 1000000n)), c, group, rel, path, hold, s)

# a source's files, in order; pre is the directory prefix their ids drop
def emit.all(rs: List<&2, Fr>, +c: Cf, +group: List<&2, U32>, +pre: List<&2, U32>, +hold: Bool, s: Xst) -> IO(Xst):
  match rs:
    case Nil{}:
      IO.pure(Xst, s)
    case Fr{+p, k, d, +z} <> more:
      IO.bind(Xst, Xst, emit.one(c, group, S.strip(p, pre), p, z, hold, s), emit.all(more, c, group, pre, hold))

# Hackage tarballs ---------------------------------------------------------------

def tar.perm(ok: Bool, +c: Cf, +pre: List<&2, U32>, +package: List<&2, U32>, files: List<&2, Fr>, s: Xst) -> IO(Xst):
  match ok:
    case False{}:
      IO.pure(Xst, es.bump(s, "license"))
    case True{}:
      +group = S.append(S.b("hackage:"), package)
      emit.all(files, c, group, pre, hold.source(c, False{}, group), s)

def cabal.text(dir: Bool, +p: List<&2, U32>) -> IO(List<&2, U32>):
  match dir:
    case True{}:
      IO.pure(List<&2, U32>, Nil{})
    case False{}:
      S.read(S.str(p))

def tar.lic(+c: Cf, +pre: List<&2, U32>, +package: List<&2, U32>, cab: Maybe<&2, Fr>, files: List<&2, Fr>, s: Xst) -> IO(Xst):
  match cab:
    case None{}:
      IO.pure(Xst, es.bump(s, "license"))
    case Some{Fr{+p, +k, d, z}}:
      do IO<Xst>:
        t : List<&2, U32> <- cabal.text(S.eq(k, S.b("d")), p)
        tar.perm(permissive(lic.value(S.split.lines(t))), c, pre, package, files, s)

def tar.listed(+c: Cf, +pre: List<&2, U32>, +package: List<&2, U32>, +rs: List<&2, Fr>, s: Xst) -> IO(Xst):
  tar.lic(c, pre, package, cabal.of(rs), sources(rs), s)

def tar.got(ok: Bool, +c: Cf, +pkg: String, +pv: List<&2, U32>, +package: List<&2, U32>, s: Xst) -> IO(Xst):
  match ok:
    case False{}:
      IO.pure(Xst, es.bump(s, "unreadable"))
    case True{}:
      do IO<Xst>:
        ls : List<&2, List<&2, U32>> <- listing("find \"$1\" -mindepth 1 -printf '%p\\t%y\\t%d\\t%s\\n'", pkg)
        tar.listed(c, S.append(S.b(pkg ++ "/"), S.append(pv, [47])), package, recs4(ls), es.bump(s, "processed"))

# one tarball: a fresh directory, the package unpacked into it
def tar.one(+c: Cf, +src: String, +work: String, +name: List<&2, U32>, s: Xst) -> IO(Xst):
  +pv = before.last(before.last(name, 46), 46)
  +pkg = work ++ "/pkg"
  do IO<Xst>:
    o : S.Out <- S.run(".", [], 3600, "sh", ["-c", "chmod -R u+rwX \"$1\" 2>/dev/null; rm -rf \"$1\"; mkdir -p \"$1\" && tar xzf \"$2\" -C \"$1\" 2>/dev/null", "sh", pkg, src ++ "/tarballs/" ++ S.str(name)], Nil{})
    tar.got(U32.is_eq(S.Out.status(o), 0), c, pkg, pv, before.last(pv, 45), es.bump(s, "considered"))

def tar.all(ns: List<&2, List<&2, U32>>, +c: Cf, +src: String, +work: String, s: Xst) -> IO(Xst):
  match ns:
    case Nil{}:
      IO.pure(Xst, s)
    case +n <> more:
      IO.bind(Xst, Xst, tar.one(c, src, work, n, s), tar.all(more, c, src, work))

def any.line(ls: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      Bool.or(S.eq(l, x), any.line(more, x))

# Repositories ---------------------------------------------------------------------

# the first license file present (a regular file, symlinks followed)
def lic.file(names: List<String>, +have: List<&2, List<&2, U32>>) -> Maybe<&2, String>:
  match names:
    case Nil{}:
      None{}
    case +n <> more:
      Bool.pick(Maybe<&2, String>, any.line(have, S.b("f\t" ++ n)), Some{n}, lic.file(more, have))

def lic.read(+tree: String, m: Maybe<&2, String>) -> IO(List<&2, U32>):
  match m:
    case None{}:
      IO.pure(List<&2, U32>, Nil{})
    case Some{n}:
      S.read(tree ++ n)

def tree.files(ok: Bool, +c: Cf, +tree: String, +group: List<&2, U32>, +spare: Bool, s: Xst) -> IO(Xst):
  match ok:
    case False{}:
      IO.pure(Xst, es.bump(s, "license"))
    case True{}:
      do IO<Xst>:
        ls : List<&2, List<&2, U32>> <- listing("find \"$1\" -type f -not -path '*/.git/*' -printf '%p\\t%s\\n'", tree)
        emit.all(sources2(ls), c, group, S.b(tree), hold.source(c, spare, group), s)

# repos/: the license gate first
def tree.gated(+c: Cf, +tree: String, +group: List<&2, U32>, s: Xst) -> IO(Xst):
  do IO<Xst>:
    have : List<&2, List<&2, U32>> <- listing("find \"$1\" -mindepth 1 -maxdepth 1 -printf '%Y\\t%f\\n'", tree)
    t : List<&2, U32> <- lic.read(tree, lic.file(["LICENSE", "LICENCE", "COPYING", "LICENSE.md", "LICENCE.md", "LICENSE.txt", "LICENCE.txt", "COPYING.md"], have))
    tree.files(lic.text.ok(t), c, tree, group, False{}, s)

def tree.class(repos: Bool, +c: Cf, +tree: String, +cls: String, +name: List<&2, U32>, s: Xst) -> IO(Xst):
  match repos:
    case True{}:
      tree.gated(c, tree, S.append(S.b("repo:"), name), s)
    case False{}:
      tree.files(True{}, c, tree, S.append(S.b(cls ++ ":"), name), True{}, s)

def tree.all(ns: List<&2, List<&2, U32>>, +c: Cf, +src: String, +cls: String, s: Xst) -> IO(Xst):
  match ns:
    case Nil{}:
      IO.pure(Xst, s)
    case +n <> more:
      IO.bind(Xst, Xst, tree.class(String.eq(cls, "repos"), c, src ++ "/" ++ cls ++ "/" ++ S.str(n), cls, before.last(n, 47), es.bump(s, "considered")), tree.all(more, c, src, cls))

# the directories of src/cls, each as `NAME/`, so that they sort as the
# paths of their files do (telomare-history/ before telomare/)
def trees(+c: Cf, +src: String, +cls: String, s: Xst) -> IO(Xst):
  do IO<Xst>:
    ns : List<&2, List<&2, U32>> <- listing("find -H \"$1\" -mindepth 1 -maxdepth 1 -xtype d -not -name '.*' -printf '%f/\\n'", src ++ "/" ++ cls)
    tree.all(ns, c, src, cls, s)

# The run ----------------------------------------------------------------------------

def say(+msg: String) -> IO(Unit):
  IO.print_err("bend-extract: " ++ msg)

def pct1(+d: Nat, +t: Nat) -> String:
  +p = Bool.pick(Nat, Nat.is_eq(t, 0n), 0n, Nat.div(Nat.add(Nat.mul(2000n, d), t), Nat.mul(2n, t)))
  Nat.show(Nat.div(p, 10n)) ++ "." ++ Nat.show(Nat.mod(p, 10n))

def mv.hold(on: Bool, +hp: String) -> IO(Unit):
  match on:
    case True{}:
      S.mv(hp ++ ".tmp", hp)
    case False{}:
      IO.pure(Unit, Unit{})

def done(ok: Bool, +out: String, +hp: String, +on: Bool, +kept: Nat) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "bend-extract: produced nothing")
    case True{}:
      do IO<Unit>:
        S.mv(out ++ ".tmp", out)
        mv.hold(on, hp)
        +n : Nat <- S.size(out)
        say("wrote " ++ out ++ " (" ++ Nat.show(kept) ++ " documents, " ++ Nat.show(n) ++ " bytes)")

def finish(+out: String, +hp: String, +on: Bool, +work: String, s: Xst) -> IO(Unit):
  match s:
    case Xst{o, h, seen, +cs}:
      +total = ct.get(cs, "total")
      +kept = ct.get(cs, "kept")
      +hk = ct.get(cs, "heldkept")
      +dups = Nat.sub(total, Nat.add(kept, hk))
      do IO<Unit>:
        File.close(o)
        File.close(h)
        say(Nat.show(ct.get(cs, "considered")) ++ " sources considered, " ++ Nat.show(ct.get(cs, "license")) ++ " dropped on license, "
          ++ Nat.show(ct.get(cs, "size")) ++ " files skipped by size, " ++ Nat.show(ct.get(cs, "undecodable")) ++ " undecodable, "
          ++ Nat.show(ct.get(cs, "emitted")) ++ " train / " ++ Nat.show(ct.get(cs, "held")) ++ " held-out files; "
          ++ Nat.show(ct.get(cs, "processed")) ++ " tarballs opened, " ++ Nat.show(ct.get(cs, "unreadable")) ++ " unreadable")
        say(Nat.show(total) ++ " files, " ++ Nat.show(Nat.add(kept, hk)) ++ " unique (" ++ Nat.show(kept) ++ " train, " ++ Nat.show(hk)
          ++ " held out), " ++ Nat.show(dups) ++ " duplicates dropped (" ++ pct1(dups, total) ++ "%)")
        ch : S.Out <- S.run(".", [], 3600, "chmod", ["-R", "u+rwX", work], Nil{})
        S.rm(work)
        done(Nat.is_lt(0n, kept), out, hp, on, kept)

def blanks(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(U32, space(c), 32, c) <> blanks(t)

def nonempty(ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> more:
      +rest = nonempty(more)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_lt(0n, S.len(w)), w <> rest, rest)

# the words of xs (IFS: blanks, tabs, newlines)
def words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  nonempty(S.split(blanks(xs), 32))

def run(+out: String, +src: String) -> IO(Unit):
  do IO<Unit>:
    +hp : String <- S.env("HOLDOUT_OUT", "")
    +pct : Nat <- S.env.nat("HOLDOUT_PERCENT", 2n)
    +gs : String <- S.env("HOLDOUT_GROUPS", "repo:cubical repo:batteries repo:nixpkgs/nixos repo:idris2/tests")
    +on : Bool = Bool.not(String.is_empty(hp))
    +c : Cf = Cf{on, pct, words(S.b(gs))}
    +work : String <- S.mktemp()
    o : File <- IO.try(File, File.open(out ++ ".tmp", "w"))
    h : File <- IO.try(File, File.open(Bool.pick(String, on, hp ++ ".tmp", "/dev/null"), "w"))
    say("Hackage tarballs")
    ns : List<&2, List<&2, U32>> <- listing("find -H \"$1\" -mindepth 1 -maxdepth 1 -name '*.tar.gz' -not -name '.*' -printf '%f\\n'", src ++ "/tarballs")
    s1 : Xst <- tar.all(ns, c, src, work, Xst{o, h, Set.new(), Nil{}})
    say("cloned repositories")
    s2 : Xst <- trees(c, src, "repos", s1)
    s3 : Xst <- trees(c, src, "own", s2)
    s4 : Xst <- trees(c, src, "curated", s3)
    finish(out, hp, on, work, s4)

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case +o <> Nil{}:
      run(o, "run/code-sources")
    case +o <> +s <> Nil{}:
      run(o, s)
    case _:
      IO.die(Unit, 2, "usage: bend-extract OUT.jsonl [SOURCES_DIR]")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args(xs)
