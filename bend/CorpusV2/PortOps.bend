import Base
import ../Sys.bend as S
import ./Lib.bend as L
import ./MutOps.bend as M

# The renames of `bend-corpus-v2 port` (CorpusV2/Port.bend, 2026-10-16): a
# Bend file the locked compiler will not load because one of its names now
# clashes with a name Base declares, renamed so that it loads, each a pure
# function of the texts.  Every rename is a consistent renaming of one name
# under the loader's own resolution rule (a module's own name wins over
# Base's: bend2/bend.ts parse_reso), so no definition or law is dropped,
# changed or weakened.  The laws are bend/tests/portops.bend.
#
#   own      a module declares (`def`, `type`, `law`, or a constructor of its
#            own type) a bare name Base declares in the same table (the
#            definitions', or the constructors'): the loader says `a fresh
#            name (duplicate declaration: X)` or `a fresh constructor name
#            (...)`.  X is renamed in the module (every name token X of its
#            body), and `A.X` in every module that imports it as A.
#   alias    `A.x` in a module, A the alias of an import whose module
#            declares x, while Base declares the dotted name `A.x`: `an
#            unambiguous name (the alias A shadows A.x)`.  The alias is
#            renamed in its import line and in every `A.y` whose y the
#            imported module declares (an `A.y` it does not declare is
#            Base's and stays).
#   binder   a bare name used as a binder (never followed by `{`) that the
#            locked Base declares as a constructor and the older Base
#            (BASE_OLD: upstream v2.0.37's) does not: `a braced constructor
#            pattern (E1 is a constructor: write E1{}, or rename the
#            binder)`.  Every bare token of the name in the module is
#            renamed (a binder or a use of one: the name is no constructor
#            the module could mean, it was none when the code was written).
#
# A new name is the old one with `_` appended until it is fresh: no name
# token of the module and no name Base declares.  An alias the same, also
# no other alias of the module and no Base name under it.
#
# Text: tokens are MutOps' (`mto.lex`, joined they are the text byte for
# byte); a file is its header (the leading `import` lines, blank lines and
# comments, as the loader's book_load reads them) and its body; renames
# touch the body's name tokens only, and an alias rename the header's
# import line.  Every def is prefixed `pto.`.

# Bytes and small sets ---------------------------------------------------------------------------

def pto.key(+xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case h <> t:
      SCon{Chr{h}, pto.key(t)}

def pto.set.go(xss: List<&2, List<&2, U32>>, s: Set()) -> Set():
  match xss:
    case Nil{}:
      s
    case +x <> more:
      pto.set.go(more, Set.add(s, pto.key(x)))

def pto.set(xss: List<&2, List<&2, U32>>) -> Set():
  pto.set.go(xss, Set.new())

def pto.in.fin(r: Set() & Bool) -> Bool:
  (t, b) = r
  b

def pto.in(s: Set(), +x: List<&2, U32>) -> Bool:
  pto.in.fin(Set.has(s, pto.key(x)))

def pto.mem(xs: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> Bool:
  M.mto.mem(xs, x)

def pto.cat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  List.concat(&2, U32, xss)

def pto.has.dot(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(U32.is_eq(h, 46), pto.has.dot(t))

def pto.uniq.go(xs: List<&2, List<&2, U32>>, +seen: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +new = Bool.not(pto.mem(seen, x))
      +rest = pto.uniq.go(t, Bool.pick(List<&2, List<&2, U32>>, new, x <> seen, seen))
      Bool.pick(List<&2, List<&2, U32>>, new, x <> rest, rest)

# each text once, in first-seen order
def pto.uniq(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  pto.uniq.go(xs, Nil{})

# the texts in s, and those not in it
def pto.keep.in(xs: List<&2, List<&2, U32>>, +s: Set()) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = pto.keep.in(t, s)
      Bool.pick(List<&2, List<&2, U32>>, pto.in(s, x), x <> rest, rest)

def pto.drop.in(xs: List<&2, List<&2, U32>>, +s: Set()) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = pto.drop.in(t, s)
      Bool.pick(List<&2, List<&2, U32>>, pto.in(s, x), rest, x <> rest)
# Significant tokens ------------------------------------------------------------------------------
#
# A name, number, string, char or punctuation token, whether it starts a
# line (the text's first token, or one right after a blank that ends with a
# newline: where the loader's top-level `def`, `type`, `law` and `@` are),
# and its class for the declarations' scan: 1 a name, 2 `def` or `law`, 3
# `type`, 4 `@`, 5 `:`, 6 `(` `[` `<`, 7 `)` `]` `}` `>`, 8 `{`, 0 any other.

type PtoTk is Data:
  PtoTk{k: Nat, t: List<&2, U32>, bol: Bool, c: Nat}

def pto.tk.k(+x: PtoTk) -> Nat:
  match x:
    case PtoTk{k, t, b, c}:
      k

def pto.tk.t(+x: PtoTk) -> List<&2, U32>:
  match x:
    case PtoTk{k, t, b, c}:
      t

def pto.tk.bol(+x: PtoTk) -> Bool:
  match x:
    case PtoTk{k, t, b, c}:
      b

def pto.tk.c(+x: PtoTk) -> Nat:
  match x:
    case PtoTk{k, t, b, c}:
      c

def pto.none() -> PtoTk:
  PtoTk{9n, Nil{}, False{}, 0n}

def pto.nl.end(+t: List<&2, U32>) -> Bool:
  U32.is_eq(M.mto.hd(List.reverse(&2, U32, t)), 10)

def pto.cls.name(+t: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.or(S.eq(t, [100, 101, 102]), S.eq(t, [108, 97, 119])), 2n, Bool.pick(Nat, S.eq(t, [116, 121, 112, 101]), 3n, 1n))

def pto.cls.byte(+h: U32) -> Nat:
  Bool.pick(Nat, U32.is_eq(h, 64), 4n, Bool.pick(Nat, U32.is_eq(h, 58), 5n,
    Bool.pick(Nat, Bool.or(U32.is_eq(h, 40), Bool.or(U32.is_eq(h, 91), U32.is_eq(h, 60))), 6n,
      Bool.pick(Nat, Bool.or(Bool.or(U32.is_eq(h, 41), U32.is_eq(h, 93)), Bool.or(U32.is_eq(h, 125), U32.is_eq(h, 62))), 7n,
        Bool.pick(Nat, U32.is_eq(h, 123), 8n, 0n)))))

def pto.cls.punct(+t: List<&2, U32>) -> Nat:
  match t:
    case +h <> Nil{}:
      pto.cls.byte(h)
    case _:
      0n

def pto.cls(+k: Nat, +t: List<&2, U32>) -> Nat:
  match k:
    case 1n:
      pto.cls.name(t)
    case 5n:
      pto.cls.punct(t)
    case _:
      0n

def pto.sig.at(+k: Nat, +t: List<&2, U32>, +bol: Bool, rest: List<&2, PtoTk>) -> List<&2, PtoTk>:
  match k:
    case 0n:
      rest
    case 4n:
      rest
    case _:
      PtoTk{k, t, bol, pto.cls(k, t)} <> rest

def pto.sig.next(+k: Nat, +t: List<&2, U32>, +bol: Bool) -> Bool:
  match k:
    case 0n:
      pto.nl.end(t)
    case 4n:
      bol
    case _:
      False{}

def pto.sig.go(ts: List<&2, M.MtoTk>, +bol: Bool) -> List<&2, PtoTk>:
  match ts:
    case Nil{}:
      Nil{}
    case +x <> more:
      +k = M.mto.tk.k(x)
      +t = M.mto.tk.t(x)
      pto.sig.at(k, t, bol, pto.sig.go(more, pto.sig.next(k, t, bol)))

def pto.sig(+text: List<&2, U32>) -> List<&2, PtoTk>:
  pto.sig.go(M.mto.lex(text), True{})

# a name token (keywords included)
def pto.is.nm(+x: PtoTk) -> Bool:
  Nat.is_eq(pto.tk.k(x), 1n)

# Declarations ------------------------------------------------------------------------------------
#
# A module's declared names, as the loader's parse_book reads them: the
# name after a line-starting `def` or `law` (or `@unsafe def`) and a
# line-starting `type` are the definitions' table; after a `type`'s header
# (its `:` outside brackets), each `NAME{...}` up to the next declaration is
# a constructor.  Both lists in the text's order.

type PtoDecl is Data:
  PtoDecl{tlds: List<&2, List<&2, U32>>, ctrs: List<&2, List<&2, U32>>}

def pto.decl.tlds(+d: PtoDecl) -> List<&2, List<&2, U32>>:
  match d:
    case PtoDecl{t, c}:
      List.reverse(&2, List<&2, U32>, t)

def pto.decl.ctrs(+d: PtoDecl) -> List<&2, List<&2, U32>>:
  match d:
    case PtoDecl{t, c}:
      List.reverse(&2, List<&2, U32>, c)

# (each list newest first while the scan runs)
def pto.decl.tld(+d: PtoDecl, +n: List<&2, U32>) -> PtoDecl:
  match d:
    case PtoDecl{t, c}:
      PtoDecl{n <> t, c}

def pto.decl.ctr(+d: PtoDecl, +n: List<&2, U32>) -> PtoDecl:
  match d:
    case PtoDecl{t, c}:
      PtoDecl{t, n <> c}

# The scan is one pass over the significant tokens, in a state: 0 between
# declarations, 1 after `def` or `law` (the next name is declared), 2 after
# `type` (the same), 3 in a type's header (until its `:` outside brackets),
# 4 at a type's next constructor, 5 in a constructor's fields (until its
# `}`), 6 after `@` (until `def`).  A line-starting `def`, `law`, `type` or
# `@` starts a declaration in any state but 6.

def pto.c.name(+c: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, c), Nat.is_lt(c, 4n))

# state 0's step: what a token starts
def pto.st.zero(+c: Nat, +bol: Bool) -> Nat:
  Bool.pick(Nat, Bool.not(bol), 0n, Bool.pick(Nat, Nat.is_eq(c, 2n), 1n, Bool.pick(Nat, Nat.is_eq(c, 3n), 2n, Bool.pick(Nat, Nat.is_eq(c, 4n), 6n, 0n))))

# the state after a token of class c (yc the next one's class, d the depth after it)
def pto.st.next(+st: Nat, +c: Nat, +bol: Bool, +yc: Nat, +d: Nat) -> Nat:
  match st:
    case 1n:
      0n
    case 2n:
      Bool.pick(Nat, pto.c.name(c), 3n, 0n)
    case 3n:
      Bool.pick(Nat, Bool.and(Nat.is_eq(d, 0n), Nat.is_eq(c, 5n)), 4n, 3n)
    case 4n:
      Bool.pick(Nat, Bool.and(Nat.is_eq(c, 1n), Nat.is_eq(yc, 8n)), 5n, 0n)
    case 5n:
      Bool.pick(Nat, Nat.is_eq(d, 0n), 4n, 5n)
    case 6n:
      Bool.pick(Nat, Nat.is_eq(c, 2n), 1n, Bool.pick(Nat, pto.c.name(c), 6n, 0n))
    case _:
      pto.st.zero(c, bol)

# the bracket depth after a token: counted in a header (3) and in fields (5), else 0
def pto.st.depth(+st: Nat, +c: Nat, +d: Nat) -> Nat:
  +on = Bool.or(Nat.is_eq(st, 3n), Nat.is_eq(st, 5n))
  +open = Bool.or(Nat.is_eq(c, 6n), Nat.is_eq(c, 8n))
  Bool.pick(Nat, Bool.not(on), 0n, Bool.pick(Nat, open, 1n+d, Bool.pick(Nat, Nat.is_eq(c, 7n), Nat.sub(d, 1n), d)))

# what the token declares: 1 a definition's name, 2 a constructor's, 0 nothing
def pto.st.decl(+st: Nat, +c: Nat, +yc: Nat) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_eq(c, 1n), Bool.or(Nat.is_eq(st, 1n), Nat.is_eq(st, 2n))), 1n,
    Bool.pick(Nat, Bool.and(Nat.is_eq(st, 4n), Bool.and(Nat.is_eq(c, 1n), Nat.is_eq(yc, 8n))), 2n, 0n))

def pto.decl.add(+k: Nat, +t: List<&2, U32>, +acc: PtoDecl) -> PtoDecl:
  Bool.pick(PtoDecl, Nat.is_eq(k, 1n), pto.decl.tld(acc, t), Bool.pick(PtoDecl, Nat.is_eq(k, 2n), pto.decl.ctr(acc, t), acc))

def pto.first.c(+ts: List<&2, PtoTk>) -> Nat:
  match ts:
    case x <> t:
      pto.tk.c(x)
    case Nil{}:
      0n

def pto.decls.go(ts: List<&2, PtoTk>, +st: Nat, +d: Nat, +acc: PtoDecl) -> PtoDecl:
  match ts:
    case Nil{}:
      acc
    case PtoTk{k, +t, +bol, +c} <> +more:
      +yc = pto.first.c(more)
      +starts = Bool.and(bol, Bool.and(Nat.is_lt(1n, c), Nat.is_lt(c, 5n)))
      +st1 = Bool.pick(Nat, Bool.and(starts, Bool.not(Nat.is_eq(st, 6n))), 0n, st)
      +d2 = pto.st.depth(st1, c, d)
      pto.decls.go(more, pto.st.next(st1, c, bol, yc, d2), d2, pto.decl.add(pto.st.decl(st1, c, yc), t, acc))

def pto.decls(+text: List<&2, U32>) -> PtoDecl:
  pto.decls.go(pto.sig(text), 0n, 0n, PtoDecl{Nil{}, Nil{}})


# The header ---------------------------------------------------------------------------------------
#
# The loader reads a file's lines in order: a blank line or one starting
# with `#` (after its spaces) is passed over, an `import` line is an
# import, any other line ends the header.  An import is its path and its
# alias (`import Base` has none).

type PtoImp is Data:
  PtoImp{path: List<&2, U32>, alias: List<&2, U32>}

def pto.imp.path(+i: PtoImp) -> List<&2, U32>:
  match i:
    case PtoImp{p, a}:
      p

def pto.imp.alias(+i: PtoImp) -> List<&2, U32>:
  match i:
    case PtoImp{p, a}:
      a

type PtoHd is Data:
  PtoHd{n: Nat, imps: List<&2, PtoImp>}

def pto.hd.n(+h: PtoHd) -> Nat:
  match h:
    case PtoHd{n, i}:
      n

def pto.hd.imps(+h: PtoHd) -> List<&2, PtoImp>:
  match h:
    case PtoHd{n, i}:
      i

def pto.words(+l: List<&2, U32>) -> List<&2, List<&2, U32>>:
  List.filter(~List<&2, U32>, ~(w => Bool.not(List.is_empty(&2, U32, w))), S.split(S.replace(M.mto.text(l), [9], [32]), 32))

# 0 passed over, 1 an import, 2 the header's end
def pto.line.kind(+l: List<&2, U32>) -> Nat:
  +t = M.mto.text(l)
  +ws = pto.words(l)
  Bool.pick(Nat, Bool.or(List.is_empty(&2, U32, t), S.prefix(t, [35])), 0n,
    Bool.pick(Nat, S.eq(M.mto.nth(ws, 0n), S.b("import")), 1n, 2n))

def pto.imp.of(+l: List<&2, U32>) -> PtoImp:
  +ws = pto.words(l)
  PtoImp{M.mto.nth(ws, 1n), Bool.pick(List<&2, U32>, S.eq(M.mto.nth(ws, 2n), S.b("as")), M.mto.nth(ws, 3n), Nil{})}

def pto.hd.go(fuel: Nat, +xs: List<&2, U32>, +n: Nat, +acc: List<&2, PtoImp>, stop: Bool) -> PtoHd:
  match fuel stop:
    case 1n+f False{}:
      +l = L.v2.before(xs, 10)
      +rest = List.drop(&2, U32, xs, S.len(l))
      +w = Nat.add(S.len(l), Bool.pick(Nat, U32.is_eq(M.mto.hd(rest), 10), 1n, 0n))
      +k = Bool.pick(Nat, List.is_empty(&2, U32, xs), 2n, pto.line.kind(l))
      +end = Nat.is_eq(k, 2n)
      pto.hd.go(f, List.drop(&2, U32, rest, 1n), Bool.pick(Nat, end, n, Nat.add(n, w)), Bool.pick(List<&2, PtoImp>, Nat.is_eq(k, 1n), pto.imp.of(l) <> acc, acc), end)
    case _ _:
      PtoHd{n, List.reverse(&2, PtoImp, acc)}

# the header: a line at a time from the text's start, n its bytes (each
# line with its newline)
def pto.header(+text: List<&2, U32>) -> PtoHd:
  pto.hd.go(1000000n, text, 0n, Nil{}, False{})

def pto.aliases(imps: List<&2, PtoImp>) -> List<&2, List<&2, U32>>:
  match imps:
    case Nil{}:
      Nil{}
    case +i <> more:
      +rest = pto.aliases(more)
      Bool.pick(List<&2, List<&2, U32>>, List.is_empty(&2, U32, pto.imp.alias(i)), rest, pto.imp.alias(i) <> rest)

# Paths -------------------------------------------------------------------------------------------
#
# An import's path from the importing file's: both relative to one root
# (the clones' directory), `.` and `..` folded; a path the root's sibling
# links lead with (`LINK TAB TARGET` pairs: SRC/LINK -> TARGET) read
# through its link.  A hub path (`0x...` or `name@version/`) or `Base` is
# no file of the root: empty.

def pto.segs.fold(ss: List<&2, List<&2, U32>>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, acc)
    case +s <> more:
      +dot = Bool.or(List.is_empty(&2, U32, s), S.eq(s, S.b(".")))
      +up = S.eq(s, S.b(".."))
      pto.segs.fold(more, Bool.pick(List<&2, List<&2, U32>>, dot, acc, Bool.pick(List<&2, List<&2, U32>>, up, List.drop(&2, List<&2, U32>, acc, 1n), s <> acc)))

def pto.norm(+p: List<&2, U32>) -> List<&2, U32>:
  S.join(pto.segs.fold(S.split(p, 47), Nil{}), 47)

def pto.dir.of(+p: List<&2, U32>) -> List<&2, U32>:
  +ss = S.split(p, 47)
  S.join(List.take(&2, List<&2, U32>, ss, Nat.sub(List.length(&2, List<&2, U32>, ss), 1n)), 47)

type PtoLink is Data:
  PtoLink{name: List<&2, U32>, target: List<&2, U32>}

def pto.link.hit(+ls: List<&2, PtoLink>, +first: List<&2, U32>) -> Bool:
  match ls:
    case PtoLink{+n, t} <> more:
      S.eq(n, first)
    case Nil{}:
      False{}

def pto.link.go(ls: List<&2, PtoLink>, +p: List<&2, U32>, +first: List<&2, U32>, hit: Bool) -> List<&2, U32>:
  match ls hit:
    case PtoLink{+n, +t} <> more True{}:
      S.append(t, List.drop(&2, U32, p, S.len(n)))
    case l <> +more False{}:
      pto.link.go(more, p, first, pto.link.hit(more, first))
    case Nil{} _:
      p

def pto.unlink(+ls: List<&2, PtoLink>, +p: List<&2, U32>) -> List<&2, U32>:
  +first = M.mto.lhd(S.split(p, 47))
  pto.link.go(ls, p, first, pto.link.hit(ls, first))

def pto.hub(+ip: List<&2, U32>) -> Bool:
  Bool.or(S.prefix(ip, S.b("0x")), M.mto.has(M.mto.lhd(S.split(ip, 47)), 64))

# the file an import names, from the file f (empty: none in the root)
def pto.resolve(+ls: List<&2, PtoLink>, +f: List<&2, U32>, +ip: List<&2, U32>) -> List<&2, U32>:
  +ok = Bool.and(Bool.not(pto.hub(ip)), S.suffix(ip, S.b(".bend")))
  Bool.pick(List<&2, U32>, ok, pto.unlink(ls, pto.norm(pto.cat([pto.dir.of(f), [47], ip]))), Nil{})

# Fresh names -------------------------------------------------------------------------------------

def pto.fresh.go(fuel: Nat, +n: List<&2, U32>, +used: Set(), taken: Bool) -> List<&2, U32>:
  match fuel taken:
    case 1n+f True{}:
      +n2 = S.append(n, [95])
      pto.fresh.go(f, n2, used, pto.in(used, n2))
    case _ _:
      n

# n with `_` appended until it is not used (at least once)
def pto.fresh(+n: List<&2, U32>, +used: Set()) -> List<&2, U32>:
  +n1 = S.append(n, [95])
  pto.fresh.go(64n, n1, used, pto.in(used, n1))

# Renames -----------------------------------------------------------------------------------------

type PtoRn is Data:
  PtoRn{old: List<&2, U32>, new: List<&2, U32>}

def pto.rn.old(+r: PtoRn) -> List<&2, U32>:
  match r:
    case PtoRn{o, n}:
      o

def pto.rn.new(+r: PtoRn) -> List<&2, U32>:
  match r:
    case PtoRn{o, n}:
      n

def pto.look.hit(+rs: List<&2, PtoRn>, +x: List<&2, U32>) -> Bool:
  match rs:
    case PtoRn{+o, n} <> more:
      S.eq(o, x)
    case Nil{}:
      False{}

def pto.look.go(rs: List<&2, PtoRn>, +x: List<&2, U32>, hit: Bool) -> List<&2, U32>:
  match rs hit:
    case PtoRn{o, n} <> more True{}:
      n
    case r <> +more False{}:
      pto.look.go(more, x, pto.look.hit(more, x))
    case Nil{} _:
      x

# what x is renamed to (x when no pair names it)
def pto.look(+rs: List<&2, PtoRn>, +x: List<&2, U32>) -> List<&2, U32>:
  pto.look.go(rs, x, pto.look.hit(rs, x))

def pto.rn.has(rs: List<&2, PtoRn>, +x: List<&2, U32>) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case PtoRn{+o, n} <> more:
      Bool.or(S.eq(o, x), pto.rn.has(more, x))

def pto.rn.inv(rs: List<&2, PtoRn>) -> List<&2, PtoRn>:
  match rs:
    case Nil{}:
      Nil{}
    case PtoRn{o, n} <> more:
      PtoRn{n, o} <> pto.rn.inv(more)

# the name tokens renamed, rendered
def pto.ren.go(ts: List<&2, M.MtoTk>, +rs: List<&2, PtoRn>) -> List<&2, U32>:
  match ts:
    case Nil{}:
      Nil{}
    case +x <> more:
      +t = M.mto.tk.t(x)
      +t2 = Bool.pick(List<&2, U32>, Nat.is_eq(M.mto.tk.k(x), 1n), pto.look(rs, t), t)
      S.append(t2, pto.ren.go(more, rs))

def pto.rename.at(none: Bool, +text: List<&2, U32>, +rs: List<&2, PtoRn>) -> List<&2, U32>:
  match none:
    case True{}:
      text
    case False{}:
      pto.ren.go(M.mto.lex(text), rs)

def pto.rename(+text: List<&2, U32>, +rs: List<&2, PtoRn>) -> List<&2, U32>:
  pto.rename.at(List.is_empty(&2, PtoRn, rs), text, rs)

# an import line with its alias renamed (the last word, after `as`)
def pto.realias.line(+l: List<&2, U32>, +rs: List<&2, PtoRn>) -> List<&2, U32>:
  +a = pto.imp.alias(pto.imp.of(l))
  +ok = Bool.and(Nat.is_eq(pto.line.kind(l), 1n), Bool.and(Bool.not(List.is_empty(&2, U32, a)), pto.rn.has(rs, a)))
  Bool.pick(List<&2, U32>, ok, S.replace.first(l, S.append(S.b(" as "), a), S.append(S.b(" as "), pto.look(rs, a))), l)

def pto.realias(ls: List<&2, List<&2, U32>>, +rs: List<&2, PtoRn>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      S.append(pto.realias.line(l, rs), pto.realias(more, rs))

# the text with the body's name tokens renamed by bs and the header's
# aliases by as
def pto.apply(+text: List<&2, U32>, +bs: List<&2, PtoRn>, +as: List<&2, PtoRn>) -> List<&2, U32>:
  +n = pto.hd.n(pto.header(text))
  +head = List.take(&2, U32, text, n)
  +body = List.drop(&2, U32, text, n)
  +h2 = Bool.pick(List<&2, U32>, List.is_empty(&2, PtoRn, as), head, pto.realias(M.mto.lines(head), as))
  S.append(h2, pto.rename(body, bs))


# A module ----------------------------------------------------------------------------------------
#
# What the planner reads of a file: its path (from the root), text, its
# header's length and imports (each path resolved: empty outside the root),
# its declarations (also as one set, both tables), its body's distinct name
# tokens and those of them a `{` follows.

type PtoMod is Data:
  PtoMod{path: List<&2, U32>, text: List<&2, U32>, hn: Nat, imps: List<&2, PtoImp>, decl: PtoDecl, dset: Set(), ns: List<&2, List<&2, U32>>, braced: List<&2, List<&2, U32>>}

def pto.mod.path(+m: PtoMod) -> List<&2, U32>:
  match m:
    case PtoMod{p, t, h, i, d, s, n, b}:
      p

def pto.mod.text(+m: PtoMod) -> List<&2, U32>:
  match m:
    case PtoMod{p, t, h, i, d, s, n, b}:
      t

def pto.mod.imps(+m: PtoMod) -> List<&2, PtoImp>:
  match m:
    case PtoMod{p, t, h, i, d, s, n, b}:
      i

def pto.mod.decl(+m: PtoMod) -> PtoDecl:
  match m:
    case PtoMod{p, t, h, i, d, s, n, b}:
      d

def pto.mod.dset(+m: PtoMod) -> Set():
  match m:
    case PtoMod{p, t, h, i, d, s, n, b}:
      s

def pto.mod.ns(+m: PtoMod) -> List<&2, List<&2, U32>>:
  match m:
    case PtoMod{p, t, h, i, d, s, n, b}:
      n

def pto.mod.braced(+m: PtoMod) -> List<&2, List<&2, U32>>:
  match m:
    case PtoMod{p, t, h, i, d, s, n, b}:
      b

def pto.dedup.go(xs: List<&2, List<&2, U32>>, +seen: Set()) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +new = Bool.not(pto.in(seen, x))
      +rest = pto.dedup.go(t, Bool.pick(Set(), new, Set.add(seen, pto.key(x)), seen))
      Bool.pick(List<&2, List<&2, U32>>, new, x <> rest, rest)

# each text once, in first-seen order (a set: for long lists)
def pto.dedup(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  pto.dedup.go(xs, Set.new())

def pto.names.go(ts: List<&2, M.MtoTk>) -> List<&2, List<&2, U32>>:
  match ts:
    case Nil{}:
      Nil{}
    case +x <> more:
      +rest = pto.names.go(more)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(M.mto.tk.k(x), 1n), M.mto.tk.t(x) <> rest, rest)

# the name tokens of a text
def pto.names(+text: List<&2, U32>) -> List<&2, List<&2, U32>>:
  pto.names.go(M.mto.lex(text))

# the name tokens a `{` follows (blanks and comments between them passed over)
def pto.braced.go(ts: List<&2, PtoTk>, +prev: PtoTk) -> List<&2, List<&2, U32>>:
  match ts:
    case Nil{}:
      Nil{}
    case +y <> more:
      +rest = pto.braced.go(more, y)
      Bool.pick(List<&2, List<&2, U32>>, Bool.and(pto.is.nm(prev), Nat.is_eq(pto.tk.c(y), 8n)), pto.tk.t(prev) <> rest, rest)

def pto.imps.res(imps: List<&2, PtoImp>, +ls: List<&2, PtoLink>, +f: List<&2, U32>) -> List<&2, PtoImp>:
  match imps:
    case Nil{}:
      Nil{}
    case PtoImp{+p, a} <> more:
      PtoImp{pto.resolve(ls, f, p), a} <> pto.imps.res(more, ls, f)

def pto.mod(+ls: List<&2, PtoLink>, +path: List<&2, U32>, +text: List<&2, U32>) -> PtoMod:
  +h = pto.header(text)
  +d = pto.decls(text)
  +body = List.drop(&2, U32, text, pto.hd.n(h))
  PtoMod{path, text, pto.hd.n(h), pto.imps.res(pto.hd.imps(h), ls, path), d, pto.set(List.append(&2, List<&2, U32>, pto.decl.tlds(d), pto.decl.ctrs(d))),
    pto.dedup(pto.names(body)), pto.dedup(pto.braced.go(pto.sig(body), pto.none()))}

# Base --------------------------------------------------------------------------------------------
#
# The locked Base's two tables (as sets), all its names (one set), and the
# constructors it has that the older Base has not.

type PtoBase is Data:
  PtoBase{tlds: Set(), ctrs: Set(), all: Set(), fresh: Set()}

def pto.base.tlds(+b: PtoBase) -> Set():
  match b:
    case PtoBase{t, c, a, f}:
      t

def pto.base.ctrs(+b: PtoBase) -> Set():
  match b:
    case PtoBase{t, c, a, f}:
      c

def pto.base.all(+b: PtoBase) -> Set():
  match b:
    case PtoBase{t, c, a, f}:
      a

def pto.base.fresh(+b: PtoBase) -> Set():
  match b:
    case PtoBase{t, c, a, f}:
      f

def pto.base.of(+text: List<&2, U32>, +old: List<&2, U32>) -> PtoBase:
  +d = pto.decls(text)
  +od = pto.set(pto.decl.ctrs(pto.decls(old)))
  +news = pto.drop.in(pto.decl.ctrs(d), od)
  PtoBase{pto.set(pto.decl.tlds(d)), pto.set(pto.decl.ctrs(d)), pto.set(List.append(&2, List<&2, U32>, pto.decl.tlds(d), pto.decl.ctrs(d))), pto.set(news)}

# Own and binder renames ----------------------------------------------------------------------------


# the names a new name of the module must avoid: its body's names and Base's
def pto.used(+b: PtoBase, +m: PtoMod) -> Set():
  pto.set.go(pto.mod.ns(m), pto.base.all(b))

def pto.rns(xs: List<&2, List<&2, U32>>, +used: Set()) -> List<&2, PtoRn>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      PtoRn{x, pto.fresh(x, used)} <> pto.rns(more, used)

# own: the module's declared names Base declares in the same table
def pto.own(+b: PtoBase, +m: PtoMod) -> List<&2, PtoRn>:
  +d = pto.mod.decl(m)
  +hits = pto.uniq(List.append(&2, List<&2, U32>, pto.keep.in(pto.decl.tlds(d), pto.base.tlds(b)), pto.keep.in(pto.decl.ctrs(d), pto.base.ctrs(b))))
  pto.rns(hits, pto.used(b, m))

# binder: the body's bare names that are constructors only the locked Base
# has, no `{` after any of them, not declared by the module, no alias of it
def pto.binder.is(+fresh: Set(), +ds: Set(), +braced: Set(), +as: Set(), +x: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(Bool.not(pto.has.dot(x)), pto.in(fresh, x)),
    Bool.and(Bool.not(pto.in(braced, x)), Bool.and(Bool.not(pto.in(ds, x)), Bool.not(pto.in(as, x)))))

def pto.binders.go(xs: List<&2, List<&2, U32>>, +fresh: Set(), +ds: Set(), +braced: Set(), +as: Set()) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = pto.binders.go(t, fresh, ds, braced, as)
      Bool.pick(List<&2, List<&2, U32>>, pto.binder.is(fresh, ds, braced, as, x), x <> rest, rest)

def pto.binders(+b: PtoBase, +m: PtoMod) -> List<&2, PtoRn>:
  +hits = pto.binders.go(pto.mod.ns(m), pto.base.fresh(b), pto.mod.dset(m), pto.set(pto.mod.braced(m)), pto.set(pto.aliases(pto.mod.imps(m))))
  pto.rns(hits, pto.used(b, m))

# The modules' own renames, by path ------------------------------------------------------------------

type PtoInfo is Data:
  PtoInfo{dset: Set(), own: List<&2, PtoRn>}

def pto.info.dset(+i: PtoInfo) -> Set():
  match i:
    case PtoInfo{d, o}:
      d

def pto.info.own(+i: PtoInfo) -> List<&2, PtoRn>:
  match i:
    case PtoInfo{d, o}:
      o

def pto.infos.go(ms: List<&2, PtoMod>, +b: PtoBase, m: Map<&2, PtoInfo>) -> Map<&2, PtoInfo>:
  match ms:
    case Nil{}:
      m
    case +x <> more:
      pto.infos.go(more, b, Map.set(&2, PtoInfo, m, pto.key(pto.mod.path(x)), PtoInfo{pto.mod.dset(x), pto.own(b, x)}))

def pto.infos(ms: List<&2, PtoMod>, +b: PtoBase) -> Map<&2, PtoInfo>:
  pto.infos.go(ms, b, Map.new(&2, PtoInfo))

def pto.snd(r: Map<&2, PtoInfo> & Bool) -> Bool:
  (m, x) = r
  x

def pto.val(r: Map<&2, PtoInfo> & PtoInfo) -> PtoInfo:
  (m, x) = r
  x

def pto.has.info(+im: Map<&2, PtoInfo>, +p: List<&2, U32>) -> Bool:
  Bool.and(Bool.not(List.is_empty(&2, U32, p)), pto.snd(Map.has(&2, PtoInfo, im, pto.key(p))))

def pto.info(+im: Map<&2, PtoInfo>, +p: List<&2, U32>) -> PtoInfo:
  pto.val(Map.get(PtoInfo, PtoInfo{Set.new(), Nil{}}, im, pto.key(p)))

# Qualified names: an importer's view -------------------------------------------------------------------
#
# For an import of a module of the root as A: the body's tokens `A.x` whose
# x the module declares; each becomes A'.x', x' its own rename and A' the
# alias's rename, A' A unless some A.x' is a name Base declares (the alias
# shadows it), then A with `_` appended until no A'.x' is and A' is no
# other alias nor name of the module.

def pto.qual.of(+a: List<&2, U32>, +ds: Set(), +x: List<&2, U32>) -> Bool:
  Bool.and(S.prefix(x, S.append(a, [46])), pto.in(ds, List.drop(&2, U32, x, 1n+S.len(a))))

def pto.qual.new(+a2: List<&2, U32>, +own: List<&2, PtoRn>, +a: List<&2, U32>, +x: List<&2, U32>) -> List<&2, U32>:
  pto.cat([a2, [46], pto.look(own, List.drop(&2, U32, x, 1n+S.len(a)))])

def pto.qual.shadow(qs: List<&2, List<&2, U32>>, +b: PtoBase, +a2: List<&2, U32>, +own: List<&2, PtoRn>, +a: List<&2, U32>) -> Bool:
  match qs:
    case Nil{}:
      False{}
    case +q <> more:
      Bool.or(pto.in(pto.base.all(b), pto.qual.new(a2, own, a, q)), pto.qual.shadow(more, b, a2, own, a))

def pto.alias.go(fuel: Nat, +qs: List<&2, List<&2, U32>>, +b: PtoBase, +used: Set(), +own: List<&2, PtoRn>, +a: List<&2, U32>, +a2: List<&2, U32>, shadow: Bool) -> List<&2, U32>:
  match fuel shadow:
    case 1n+f True{}:
      +a3 = pto.fresh(a2, used)
      pto.alias.go(f, qs, b, used, own, a, a3, pto.qual.shadow(qs, b, a3, own, a))
    case _ _:
      a2

def pto.qual.pairs(qs: List<&2, List<&2, U32>>, +a2: List<&2, U32>, +own: List<&2, PtoRn>, +a: List<&2, U32>) -> List<&2, PtoRn>:
  match qs:
    case Nil{}:
      Nil{}
    case +q <> more:
      +n = pto.qual.new(a2, own, a, q)
      +rest = pto.qual.pairs(more, a2, own, a)
      Bool.pick(List<&2, PtoRn>, S.eq(n, q), rest, PtoRn{q, n} <> rest)

# an import's renames: (the body's pairs, the alias pair if any)
type PtoQ is Data:
  PtoQ{body: List<&2, PtoRn>, alias: List<&2, PtoRn>}

def pto.q.body(+q: PtoQ) -> List<&2, PtoRn>:
  match q:
    case PtoQ{b, a}:
      b

def pto.q.alias(+q: PtoQ) -> List<&2, PtoRn>:
  match q:
    case PtoQ{b, a}:
      a

def pto.quals(xs: List<&2, List<&2, U32>>, +a: List<&2, U32>, +ds: Set()) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = pto.quals(t, a, ds)
      Bool.pick(List<&2, List<&2, U32>>, pto.qual.of(a, ds, x), x <> rest, rest)

def pto.imp.q.with(+b: PtoBase, +m: PtoMod, +used: Set(), +a: List<&2, U32>, +info: PtoInfo) -> PtoQ:
  +qs = pto.quals(pto.mod.ns(m), a, pto.info.dset(info))
  +own = pto.info.own(info)
  +a2 = pto.alias.go(8n, qs, b, used, own, a, a, pto.qual.shadow(qs, b, a, own, a))
  PtoQ{pto.qual.pairs(qs, a2, own, a), Bool.pick(List<&2, PtoRn>, S.eq(a2, a), Nil{}, [PtoRn{a, a2}])}

def pto.imp.q.at(ok: Bool, +b: PtoBase, +im: Map<&2, PtoInfo>, +m: PtoMod, +used: Set(), +i: PtoImp) -> PtoQ:
  match ok:
    case True{}:
      pto.imp.q.with(b, m, used, pto.imp.alias(i), pto.info(im, pto.imp.path(i)))
    case False{}:
      PtoQ{Nil{}, Nil{}}

def pto.imps.q(imps: List<&2, PtoImp>, +b: PtoBase, +im: Map<&2, PtoInfo>, +m: PtoMod, +used: Set()) -> PtoQ:
  match imps:
    case Nil{}:
      PtoQ{Nil{}, Nil{}}
    case +i <> more:
      +ok = Bool.and(Bool.not(List.is_empty(&2, U32, pto.imp.alias(i))), pto.has.info(im, pto.imp.path(i)))
      +q = pto.imp.q.at(ok, b, im, m, used, i)
      +rest = pto.imps.q(more, b, im, m, used)
      PtoQ{List.append(&2, PtoRn, pto.q.body(q), pto.q.body(rest)), List.append(&2, PtoRn, pto.q.alias(q), pto.q.alias(rest))}

# A module's plan -------------------------------------------------------------------------------------
#
# Its new text, the renames of its body (own, binder, qualified) and of its
# aliases, and how many of each kind.

type PtoPlan is Data:
  PtoPlan{path: List<&2, U32>, text: List<&2, U32>, body: List<&2, PtoRn>, alias: List<&2, PtoRn>, own: Nat, binder: Nat, qual: Nat}

def pto.plan.path(+p: PtoPlan) -> List<&2, U32>:
  match p:
    case PtoPlan{a, t, b, l, o, d, q}:
      a

def pto.plan.text(+p: PtoPlan) -> List<&2, U32>:
  match p:
    case PtoPlan{a, t, b, l, o, d, q}:
      t

def pto.plan.body(+p: PtoPlan) -> List<&2, PtoRn>:
  match p:
    case PtoPlan{a, t, b, l, o, d, q}:
      b

def pto.plan.alias(+p: PtoPlan) -> List<&2, PtoRn>:
  match p:
    case PtoPlan{a, t, b, l, o, d, q}:
      l

def pto.plan.own(+p: PtoPlan) -> Nat:
  match p:
    case PtoPlan{a, t, b, l, o, d, q}:
      o

def pto.plan.binder(+p: PtoPlan) -> Nat:
  match p:
    case PtoPlan{a, t, b, l, o, d, q}:
      d

def pto.plan.qual(+p: PtoPlan) -> Nat:
  match p:
    case PtoPlan{a, t, b, l, o, d, q}:
      q

# all its renames, the aliases' too (to read a checker's output back)
def pto.plan.all(+p: PtoPlan) -> List<&2, PtoRn>:
  List.append(&2, PtoRn, pto.plan.body(p), pto.plan.alias(p))

def pto.plan.changed(+p: PtoPlan) -> Bool:
  Bool.not(List.is_empty(&2, PtoRn, pto.plan.all(p)))

def pto.plan(+b: PtoBase, +im: Map<&2, PtoInfo>, +m: PtoMod) -> PtoPlan:
  +own = pto.info.own(pto.info(im, pto.mod.path(m)))
  +bs = pto.binders(b, m)
  +used = pto.set.go(pto.aliases(pto.mod.imps(m)), pto.used(b, m))
  +q = pto.imps.q(pto.mod.imps(m), b, im, m, used)
  +body = List.append(&2, PtoRn, own, List.append(&2, PtoRn, bs, pto.q.body(q)))
  PtoPlan{pto.mod.path(m), pto.apply(pto.mod.text(m), body, pto.q.alias(q)), body, pto.q.alias(q),
    List.length(&2, PtoRn, own), List.length(&2, PtoRn, bs), List.length(&2, PtoRn, pto.q.body(q))}

def pto.plans.go(ms: List<&2, PtoMod>, +b: PtoBase, +im: Map<&2, PtoInfo>) -> List<&2, PtoPlan>:
  match ms:
    case Nil{}:
      Nil{}
    case +m <> more:
      pto.plan(b, im, m) <> pto.plans.go(more, b, im)

# every module's plan, in the modules' order
def pto.plans(+ms: List<&2, PtoMod>, +b: PtoBase) -> List<&2, PtoPlan>:
  pto.plans.go(ms, b, pto.infos(ms, b))

# A checker's output ----------------------------------------------------------------------------------
#
# The failures it names: its `Error:` lines and its `Location: X` lines (X a
# definition), in order, each read back through the renames (rs: new to
# old), so a ported file's failures compare with its original's.

def pto.fail.line(+l: List<&2, U32>) -> Bool:
  Bool.or(S.prefix(l, S.b("Error:")), Bool.and(S.prefix(l, S.b("Location: ")), Nat.is_lt(10n, S.len(l))))

def pto.renames(ls: List<&2, List<&2, U32>>, +rs: List<&2, PtoRn>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      pto.rename(l, rs) <> pto.renames(more, rs)

def pto.fails(+out: List<&2, U32>, +rs: List<&2, PtoRn>) -> List<&2, List<&2, U32>>:
  pto.renames(List.filter(~List<&2, U32>, ~(l => pto.fail.line(l)), S.split.lines(out)), rs)

def pto.texts.eq(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(S.eq(x, y), pto.texts.eq(xt, yt))
    case _ _:
      False{}

# the line a checker's error points at (`N>| text`, N its number): its
# number and text (0 and empty: none)
type PtoAt is Data:
  PtoAt{n: Nat, text: List<&2, U32>}

def pto.at.line(+l: List<&2, U32>) -> Bool:
  +t = M.mto.text(l)
  +num = L.v2.before(t, 62)
  +rest = L.v2.after(t, 62)
  Bool.and(Bool.and(Bool.not(List.is_empty(&2, U32, num)), M.mto.all.digits(num)), Bool.and(Nat.is_lt(S.len(num), S.len(t)), S.prefix(rest, [124])))

def pto.at.of(+l: List<&2, U32>) -> PtoAt:
  +t = M.mto.text(l)
  +rest = List.drop(&2, U32, L.v2.after(t, 62), 1n)
  PtoAt{S.env.nat.got(Nat.read(S.str(L.v2.before(t, 62))), 0n), Bool.pick(List<&2, U32>, S.prefix(rest, [32]), List.drop(&2, U32, rest, 1n), rest)}

def pto.at.hit(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case +l <> more:
      pto.at.line(l)
    case Nil{}:
      False{}

def pto.at.go(ls: List<&2, List<&2, U32>>, hit: Bool) -> PtoAt:
  match ls hit:
    case +l <> more True{}:
      pto.at.of(l)
    case l <> +more False{}:
      pto.at.go(more, pto.at.hit(more))
    case Nil{} _:
      PtoAt{0n, Nil{}}

def pto.at(+out: List<&2, U32>) -> PtoAt:
  +ls = S.split.lines(out)
  pto.at.go(ls, pto.at.hit(ls))

def pto.at.in(a: PtoAt, +text: List<&2, U32>) -> Bool:
  match a:
    case PtoAt{+n, +t}:
      Bool.and(Nat.is_lt(0n, n), S.eq(M.mto.text(M.mto.nth(S.split.lines(text), Nat.sub(n, 1n))), M.mto.text(t)))

# whether the error points into this text: its line N is the line it shows
def pto.at.self(+out: List<&2, U32>, +text: List<&2, U32>) -> Bool:
  pto.at.in(pto.at(out), text)
