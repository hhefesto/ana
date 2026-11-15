import Base
import ../Units.bend as U
import ../Transcript.bend as T
import ./ExlawText.bend as X
import ./ValidText.bend as V

# authlaw's texts (collector A: built 2026-11-14 in /tmp/bx/lawres, moved into
# ana 11-15; the user, 11-14: build "the authors'-law collector": the laws a repository's
# authors wrote, a LAWS.bend proven by the PROOF.bend beside it, or a law
# later in a unit's own file proven there, each tied to the corpus units it
# names; "the law is the spec, the model writes the code, and the repo's proof
# checks it").  Pure: a file's top-level pieces, its local imports, the units
# a law names, holes, a piece taken out, the checker's answer read, and a
# check file's laws through its checks.  Every def is prefixed `al.`; laws at
# the end.

# Bytes -----------------------------------------------------------------------------------------

def al.namech(+c: U32) -> Bool:
  Bool.or(X.ex.alpha(c), Bool.or(X.ex.digit(c), U32.is_eq(c, 46)))

def al.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  T.split(xs, 10)

def al.unlines(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  T.mg.join(ls, [10])

# the length of xs's leading name bytes
def al.wlen(xs: List<&2, U32>, +go: Bool, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      +ok = Bool.and(go, al.namech(h))
      al.wlen(t, ok, Bool.pick(Nat, ok, 1n+n, n))

def al.word(+xs: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, xs, al.wlen(xs, True{}, 0n))

def al.words.go(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +r = al.words.go(t)
      Bool.pick(List<&2, List<&2, U32>>, T.empty(x), r, x <> r)

# a line's pieces between blanks
def al.words(+l: List<&2, U32>) -> List<&2, List<&2, U32>>:
  al.words.go(T.split(l, 32))

# a path's directory and last name
def al.dirname(+rel: List<&2, U32>) -> List<&2, U32>:
  +ss = T.split(rel, 47)
  T.mg.join(List.take(&2, List<&2, U32>, ss, Nat.sub(X.ex.count(ss), 1n)), [47])

def al.basename(+rel: List<&2, U32>) -> List<&2, U32>:
  +ss = T.split(rel, 47)
  T.field(ss, Nat.sub(X.ex.count(ss), 1n))

def al.seg.put(+skip: Bool, +up: Bool, +s: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, skip, acc, Bool.pick(List<&2, List<&2, U32>>, up, List.drop(&2, List<&2, U32>, acc, 1n), s <> acc))

def al.segs(ss: List<&2, List<&2, U32>>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, acc)
    case +s <> t:
      al.segs(t, al.seg.put(Bool.or(T.empty(s), U.eq(s, [46])), U.eq(s, [46, 46]), s, acc))

# dir/p with its `.` and `..` resolved
def al.norm(+dir: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  T.mg.join(al.segs(T.split(T.cat([dir, [47], p]), 47), Nil{}), [47])

# p somewhere in xs, not right after a name byte
def al.has.pre(xs: List<&2, U32>, +p: List<&2, U32>, +prev: Bool) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> +t:
      Bool.or(Bool.and(Bool.not(prev), U.prefix(h <> t, p)), al.has.pre(t, p, al.namech(h)))

def al.any.pre(ps: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +p <> t:
      Bool.or(al.has.pre(x, p, False{}), al.any.pre(t, x))

# Pieces ----------------------------------------------------------------------------------------
#
# A file's top-level pieces: each from a line at column 0 that starts with a
# letter, `_` or `@` (a law, a def, a type, an import) to the next one; its
# kind (1 a law, 2 a def, 3 an import, 0 any other), its name (an import's:
# its alias), its text (trailing blanks out), and its doc: the comment lines
# right above it.

type AlS is Data:
  AlS{kind: Nat, name: List<&2, U32>}

def AlS.kind(+s: AlS) -> Nat:
  match s:
    case AlS{k, n}:
      k

def AlS.name(+s: AlS) -> List<&2, U32>:
  match s:
    case AlS{k, n}:
      n

def al.opens(+l: List<&2, U32>) -> Bool:
  match l:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(X.ex.alpha(h), U32.is_eq(h, 64))

# `import PATH as ALIAS`: [PATH, ALIAS] (none: not one)
def al.imp.words(+l: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ws = al.words(l)
  +ok = Bool.and(Nat.is_eq(X.ex.count(ws), 4n), Bool.and(U.eq(T.field(ws, 0n), U.b("import")), U.eq(T.field(ws, 2n), U.b("as"))))
  Bool.pick(List<&2, List<&2, U32>>, ok, [T.field(ws, 1n), T.field(ws, 3n)], Nil{})

def al.imp.if(go: Bool, +l: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match go:
    case True{}:
      al.imp.words(l)
    case False{}:
      Nil{}

# a line's piece: `law NAME:`, `def NAME(..` (or `@unsafe def`, `def NAME?(`), an import
def al.start(+l: List<&2, U32>) -> AlS:
  +isl = U.prefix(l, U.b("law "))
  +d0 = U.prefix(l, U.b("def "))
  +d1 = U.prefix(l, U.b("@unsafe def "))
  +iw = al.imp.if(U.prefix(l, U.b("import ")), l)
  +im = Nat.is_eq(X.ex.count(iw), 2n)
  +rest = List.drop(&2, U32, l, Bool.pick(Nat, Bool.or(isl, d0), 4n, 12n))
  +k = Bool.pick(Nat, isl, 1n, Bool.pick(Nat, Bool.or(d0, d1), 2n, Bool.pick(Nat, im, 3n, 0n)))
  +nm = Bool.pick(List<&2, U32>, im, T.field(iw, 1n), Bool.pick(List<&2, U32>, Nat.is_lt(0n, k), al.word(rest), Nil{}))
  AlS{k, nm}

type AlB is Data:
  AlB{kind: Nat, name: List<&2, U32>, text: List<&2, U32>, doc: List<&2, U32>}

def AlB.kind(+b: AlB) -> Nat:
  match b:
    case AlB{k, n, x, d}:
      k

def AlB.name(+b: AlB) -> List<&2, U32>:
  match b:
    case AlB{k, n, x, d}:
      n

def AlB.text(+b: AlB) -> List<&2, U32>:
  match b:
    case AlB{k, n, x, d}:
      x

def AlB.doc(+b: AlB) -> List<&2, U32>:
  match b:
    case AlB{k, n, x, d}:
      d

# the walk: the piece being read (kind, name, doc, its lines newest first), the pieces read
type AlW is Data:
  AlW{kind: Nat, name: List<&2, U32>, doc: List<&2, List<&2, U32>>, cur: List<&2, List<&2, U32>>, acc: List<&2, AlB>}

def al.is.cmt(+l: List<&2, U32>) -> Bool:
  T.head.is(l, 35)

# xs's first line a comment (cm) or a blank
def al.hd(+xs: List<&2, List<&2, U32>>, +cm: Bool) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.pick(Bool, cm, al.is.cmt(l), U.blank(l))

# how many of xs's first lines are comments (cm) or blanks
def al.lead(xs: List<&2, List<&2, U32>>, +cm: Bool, +n: Nat, hit: Bool) -> Nat:
  match xs hit:
    case +l <> +t True{}:
      al.lead(t, cm, 1n+n, al.hd(t, cm))
    case _ _:
      n

def al.close(+k: Nat, +nm: List<&2, U32>, +doc: List<&2, List<&2, U32>>, +cur: List<&2, List<&2, U32>>, acc: List<&2, AlB>) -> List<&2, AlB>:
  +nb = al.lead(cur, False{}, 0n, al.hd(cur, False{}))
  +body = List.reverse(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, cur, nb))
  {AlB{k, nm, al.unlines(body), al.unlines(doc)} : AlB} <> acc

def al.step(op: Bool, +l: List<&2, U32>, st: AlW) -> AlW:
  match op st:
    case True{} AlW{+k, +nm, +doc, +cur, acc}:
      +nc = al.lead(cur, True{}, 0n, al.hd(cur, True{}))
      +s = al.start(l)
      AlW{AlS.kind(s), AlS.name(s), List.reverse(&2, List<&2, U32>, List.take(&2, List<&2, U32>, cur, nc)), [l], al.close(k, nm, doc, List.drop(&2, List<&2, U32>, cur, nc), acc)}
    case False{} AlW{+k, +nm, +doc, +cur, acc}:
      AlW{k, nm, doc, l <> cur, acc}

def al.fin(st: AlW) -> List<&2, AlB>:
  match st:
    case AlW{+k, +nm, +doc, +cur, acc}:
      List.reverse(&2, AlB, al.close(k, nm, doc, cur, acc))

def al.go(ls: List<&2, List<&2, U32>>, st: AlW) -> List<&2, AlB>:
  match ls:
    case Nil{}:
      al.fin(st)
    case +l <> t:
      al.go(t, al.step(al.opens(l), l, st))

def al.blocks(+text: List<&2, U32>) -> List<&2, AlB>:
  al.go(al.lines(text), AlW{0n, Nil{}, Nil{}, Nil{}, Nil{}})

# the names of the pieces of kind k
def al.names(bs: List<&2, AlB>, +k: Nat) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      +r = al.names(t, k)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(AlB.kind(b), k), AlB.name(b) <> r, r)

# the piece of kind k named nm (none: one with no name)
def al.piece(bs: List<&2, AlB>, +k: Nat, +nm: List<&2, U32>) -> AlB:
  match bs:
    case Nil{}:
      AlB{0n, Nil{}, Nil{}, Nil{}}
    case +b <> t:
      +hit = Bool.and(Nat.is_eq(AlB.kind(b), k), U.eq(AlB.name(b), nm))
      +r = al.piece(t, k, nm)
      Bool.pick(AlB, hit, b, r)

# a law's text as the spec: its doc, then the law
def al.spec(+b: AlB) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, T.empty(AlB.doc(b)), AlB.text(b), T.cat([AlB.doc(b), [10], AlB.text(b)]))

# Imports and the units a law names -------------------------------------------------------------

type AlI is Data:
  AlI{alias: List<&2, U32>, path: List<&2, U32>}

# the local imports (`./`, `../`) of the pieces, their paths from dir
def al.imps(bs: List<&2, AlB>, +dir: List<&2, U32>) -> List<&2, AlI>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      +r = al.imps(t, dir)
      +p = T.field(al.imp.words(T.field(al.lines(AlB.text(b)), 0n)), 0n)
      +loc = Bool.or(U.prefix(p, U.b("./")), U.prefix(p, U.b("../")))
      Bool.pick(List<&2, AlI>, Bool.and(Nat.is_eq(AlB.kind(b), 3n), loc), {AlI{AlB.name(b), al.norm(dir, p)} : AlI} <> r, r)

# an alias's path (none: not a local import)
def al.imp.of(ims: List<&2, AlI>, +a: List<&2, U32>) -> List<&2, U32>:
  match ims:
    case Nil{}:
      Nil{}
    case AlI{+x, +p} <> t:
      +r = al.imp.of(t, a)
      Bool.pick(List<&2, U32>, U.eq(x, a), p, r)

# the alias a path is imported as (none: it is not)
def al.alias.of(ims: List<&2, AlI>, +p: List<&2, U32>) -> List<&2, U32>:
  match ims:
    case Nil{}:
      Nil{}
    case AlI{+x, +q} <> t:
      +r = al.alias.of(t, p)
      Bool.pick(List<&2, U32>, U.eq(q, p), x, r)

# the names called in x (a name right before `(` or `!(`), outside string and char literals
def al.tk.go(xs: List<&2, U32>, +q: U32, +esc: Bool, +cur: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, acc)
    case +h <> t:
      +inq = Bool.not(U32.is_eq(q, 0))
      +shut = Bool.and(U32.is_eq(h, q), Bool.not(esc))
      +opens = Bool.or(U32.is_eq(h, 34), U32.is_eq(h, 39))
      +q2 = Bool.pick(U32, inq, Bool.pick(U32, shut, 0, q), Bool.pick(U32, opens, h, 0))
      +esc2 = Bool.and(inq, Bool.and(U32.is_eq(h, 92), Bool.not(esc)))
      +grow = Bool.and(Bool.not(inq), Bool.and(al.namech(h), Bool.or(Bool.not(T.empty(cur)), X.ex.alpha(h))))
      +bang = Bool.and(Bool.not(inq), U32.is_eq(h, 33))
      +emit = Bool.and(Bool.not(inq), Bool.and(U32.is_eq(h, 40), Bool.not(T.empty(cur))))
      +cur2 = Bool.pick(List<&2, U32>, grow, h <> cur, Bool.pick(List<&2, U32>, bang, cur, Nil{}))
      +acc2 = Bool.pick(List<&2, List<&2, U32>>, emit, List.reverse(&2, U32, cur) <> acc, acc)
      al.tk.go(t, q2, esc2, cur2, acc2)

def al.calls(+x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  al.tk.go(x, 0, False{}, Nil{}, Nil{})

# a called name's unit: `A.f` through the local import A (A's path#f), else a
# def f of the file self (self#f); none: neither
def al.ref(+t: List<&2, U32>, +ims: List<&2, AlI>, +self: List<&2, U32>, +defs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  +dot = U.find(t, [46], 0n)
  +p = al.imp.of(ims, List.take(&2, U32, t, dot))
  +viaim = Bool.and(Nat.is_lt(dot, U.len(t)), Bool.not(T.empty(p)))
  +local = T.f3.in(defs, t)
  Bool.pick(List<&2, List<&2, U32>>, viaim, [T.cat([p, [35], List.drop(&2, U32, t, 1n+dot)])],
    Bool.pick(List<&2, List<&2, U32>>, local, [T.cat([self, [35], t])], Nil{}))

def al.refs.go(ts: List<&2, List<&2, U32>>, +ims: List<&2, AlI>, +self: List<&2, U32>, +defs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> more:
      List.append(&2, List<&2, U32>, al.ref(t, ims, self, defs), al.refs.go(more, ims, self, defs))

# the units a law (its text x) of the file self names, each once
def al.refs(+x: List<&2, U32>, +ims: List<&2, AlI>, +self: List<&2, U32>, +defs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  T.f3.dedupe(al.refs.go(al.calls(x), ims, self, defs), Nil{})

# the import lines whose alias x uses (`A.` not right after a name byte)
def al.used.if(imp: Bool, +b: AlB, +x: List<&2, U32>) -> Bool:
  match imp:
    case True{}:
      al.has.pre(x, U.append(AlB.name(b), [46]), False{})
    case False{}:
      False{}

def al.used.imps(bs: List<&2, AlB>, +x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      +r = al.used.imps(t, x)
      Bool.pick(List<&2, List<&2, U32>>, al.used.if(Nat.is_eq(AlB.kind(b), 3n), b, x), AlB.text(b) <> r, r)

# the import pieces
def al.imp.blocks(bs: List<&2, AlB>) -> List<&2, AlB>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      +r = al.imp.blocks(t)
      Bool.pick(List<&2, AlB>, Nat.is_eq(AlB.kind(b), 3n), b <> r, r)

# the laws of a unit's file after it (its tail) that name it and have a def
# of the same name there (a law proven in its own file)
def al.own.go(bs: List<&2, AlB>, +name: List<&2, U32>, +defs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      +r = al.own.go(t, name, defs)
      +hit = Bool.and(Nat.is_eq(AlB.kind(b), 1n), Bool.and(T.f3.in(defs, AlB.name(b)), T.f3.uses(AlB.text(b), name)))
      Bool.pick(List<&2, List<&2, U32>>, hit, AlB.name(b) <> r, r)

def al.own(+tail: List<&2, U32>, +name: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +bs = al.blocks(tail)
  al.own.go(bs, name, al.names(bs, 2n))

# Holes -----------------------------------------------------------------------------------------

# a `?name` (a hole: ?TODO, ?goal) outside string and char literals and `#` comments
def al.holes.go(xs: List<&2, U32>, +q: U32, +esc: Bool, +cm: Bool, +prev: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      +inq = Bool.not(U32.is_eq(q, 0))
      +shut = Bool.and(U32.is_eq(h, q), Bool.not(esc))
      +opens = Bool.and(Bool.not(cm), Bool.or(U32.is_eq(h, 34), U32.is_eq(h, 39)))
      +q2 = Bool.pick(U32, inq, Bool.pick(U32, shut, 0, q), Bool.pick(U32, opens, h, 0))
      +esc2 = Bool.and(inq, Bool.and(U32.is_eq(h, 92), Bool.not(esc)))
      +cm2 = Bool.pick(Bool, cm, Bool.not(U32.is_eq(h, 10)), Bool.and(Bool.not(inq), U32.is_eq(h, 35)))
      +hole = Bool.and(Bool.and(Bool.not(inq), Bool.not(cm)), Bool.and(U32.is_eq(prev, 63), X.ex.alpha(h)))
      Bool.or(hole, al.holes.go(t, q2, esc2, cm2, h))

def al.holes(+x: List<&2, U32>) -> Bool:
  al.holes.go(x, 0, False{}, False{}, 0)

# Pieces taken out ------------------------------------------------------------------------------

# whether a line starts a piece to take out (op: it starts a piece), else the skip goes on (a comment ends it)
def al.skip.if(op: Bool, +cm: Bool, +l: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +ds: List<&2, List<&2, U32>>, +skip: Bool) -> Bool:
  match op:
    case True{}:
      +s = al.start(l)
      +k = AlS.kind(s)
      Bool.or(Bool.and(Nat.is_eq(k, 1n), T.f3.in(ls, AlS.name(s))), Bool.and(Nat.is_eq(k, 2n), T.f3.in(ds, AlS.name(s))))
    case False{}:
      Bool.and(Bool.not(cm), skip)

def al.drops.go(xs: List<&2, List<&2, U32>>, +ls: List<&2, List<&2, U32>>, +ds: List<&2, List<&2, U32>>, +skip: Bool) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +l <> t:
      +sk = al.skip.if(al.opens(l), al.is.cmt(l), l, ls, ds, skip)
      +r = al.drops.go(t, ls, ds, sk)
      Bool.pick(List<&2, List<&2, U32>>, sk, r, l <> r)

def al.drops.if(go: Bool, +x: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +ds: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match go:
    case True{}:
      al.unlines(al.drops.go(al.lines(x), ls, ds, False{}))
    case False{}:
      x

# x without its laws named in ls and its defs named in ds (each its lines up
# to the next piece or comment), in one pass
def al.drops(+x: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +ds: List<&2, List<&2, U32>>) -> List<&2, U32>:
  al.drops.if(Bool.or(Nat.is_lt(0n, X.ex.count(ls)), Nat.is_lt(0n, X.ex.count(ds))), x, ls, ds)

# x without its piece of kind k (1 a law, 2 a def) named nm
def al.drop(+x: List<&2, U32>, +k: Nat, +nm: List<&2, U32>) -> List<&2, U32>:
  al.drops(x, Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(k, 1n), [nm], Nil{}), Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(k, 2n), [nm], Nil{}))

def al.has.if(op: Bool, +l: List<&2, U32>, +k: Nat, +nm: List<&2, U32>) -> Bool:
  match op:
    case True{}:
      +s = al.start(l)
      Bool.and(Nat.is_eq(AlS.kind(s), k), U.eq(AlS.name(s), nm))
    case False{}:
      False{}

def al.has.go(ls: List<&2, List<&2, U32>>, +k: Nat, +nm: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(al.has.if(al.opens(l), l, k, nm), al.has.go(t, k, nm))

# x has a piece of kind k named nm
def al.has(+x: List<&2, U32>, +k: Nat, +nm: List<&2, U32>) -> Bool:
  Bool.and(Bool.not(T.empty(nm)), al.has.go(al.lines(x), k, nm))

# The files of a check: the law file first, then the files with proofs (a
# PROOF.bend and the files it imports that import the law file), each its
# path (from the repository's root) and its text as it is now

type AlF is Data:
  AlF{path: List<&2, U32>, text: List<&2, U32>}

def AlF.path(+f: AlF) -> List<&2, U32>:
  match f:
    case AlF{p, x}:
      p

def AlF.text(+f: AlF) -> List<&2, U32>:
  match f:
    case AlF{p, x}:
      x

def al.fs.drops(fs: List<&2, AlF>, +ls: List<&2, List<&2, U32>>, +ds: List<&2, List<&2, U32>>) -> List<&2, AlF>:
  match fs:
    case Nil{}:
      Nil{}
    case AlF{+p, +x} <> t:
      {AlF{p, al.drops(x, ls, ds)} : AlF} <> al.fs.drops(t, ls, ds)

def al.fs.has(fs: List<&2, AlF>, +k: Nat, +nm: List<&2, U32>) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case AlF{+p, +x} <> t:
      Bool.or(al.has(x, k, nm), al.fs.has(t, k, nm))

def al.fs.blocks(fs: List<&2, AlF>) -> List<&2, AlB>:
  match fs:
    case Nil{}:
      Nil{}
    case AlF{+p, +x} <> t:
      List.append(&2, AlB, al.blocks(x), al.fs.blocks(t))

def al.fs.first(+fs: List<&2, AlF>) -> List<&2, U32>:
  match fs:
    case Nil{}:
      Nil{}
    case AlF{+p, +x} <> t:
      x

# The checker's answer --------------------------------------------------------------------------
#
# bend 2.0.39 `--check-only` reports the first failing def only (its
# `Location:`); when none fails, open claims and holes as `Error: N TODOs
# found.` (no names), and only when there are none the defs that rely on
# `@unsafe` or foreign code, by name (a law of an imported file as
# `FILE.name`).  A timeout is exit 124.

type AlR is Data:
  AlClean{}
  AlTodo{why: List<&2, U32>}
  AlUnsafe{names: List<&2, List<&2, U32>>}
  AlLoc{name: List<&2, U32>, why: List<&2, U32>}
  AlTime{}
  AlOther{why: List<&2, U32>}

def al.todo.line(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = al.todo.line(t)
      Bool.pick(List<&2, U32>, Bool.and(U.prefix(l, U.b("Error: ")), U.infix(l, U.b("TODO"))), l, r)

def al.unsafe.names(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = al.unsafe.names(t)
      +at = U.find(l, U.b(": "), 0n)
      +ns = X.ex.trims(T.split(List.drop(&2, U32, l, Nat.add(at, 2n)), 44))
      Bool.pick(List<&2, List<&2, U32>>, U.prefix(l, U.b("defs that depend on ")), List.append(&2, List<&2, U32>, ns, r), r)

# the error's `- expected`/`- observed`/`- message` lines (before its Context)
def al.why.go(ls: List<&2, List<&2, U32>>, +stop: Bool) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +st = Bool.or(stop, Bool.or(U.prefix(l, U.b("Context:")), U.prefix(l, U.b("Location:"))))
      +r = al.why.go(t, st)
      Bool.pick(List<&2, List<&2, U32>>, Bool.and(Bool.not(st), U.prefix(l, U.b("- "))), List.take(&2, U32, l, 200n) <> r, r)

def al.why(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +w = T.mg.join(List.take(&2, List<&2, U32>, al.why.go(ls, False{}), 3n), U.b("; "))
  Bool.pick(List<&2, U32>, T.empty(w), List.take(&2, U32, T.mg.join(List.take(&2, List<&2, U32>, ls, 4n), U.b(" | ")), 400n), w)

def al.result(+st: U32, +out: List<&2, U32>) -> AlR:
  +ls = al.lines(out)
  +clean = Bool.and(U32.is_eq(st, 0), U.infix(out, U.b("ALL PROOFS CHECK")))
  +todo = al.todo.line(ls)
  +uns = al.unsafe.names(ls)
  +loc = X.ex.trim(U.strip(T.mg.find(ls, U.b("Location:")), U.b("Location:")))
  +why = al.why(ls)
  Bool.pick(AlR, U32.is_eq(st, 124), AlTime{}, Bool.pick(AlR, U32.is_eq(st, 137), AlOther{U.b("the checker was killed (signal 9: out of memory?)")},
    Bool.pick(AlR, clean, AlClean{},
      Bool.pick(AlR, Bool.not(T.empty(todo)), AlTodo{todo},
        Bool.pick(AlR, Nat.is_lt(0n, X.ex.count(uns)), AlUnsafe{uns},
          Bool.pick(AlR, Bool.not(T.empty(loc)), AlLoc{loc, why}, AlOther{why}))))))

# a check's answer in one line, for the record
def al.said(+st: U32, +out: List<&2, U32>) -> List<&2, U32>:
  +ls = al.lines(out)
  T.cat([U.b("exit "), U.b(U32.show(st)), U.b(": "), List.take(&2, U32, T.mg.join(List.take(&2, List<&2, U32>, ls, 2n), U.b(" | ")), 160n)])

# A check's laws through its checks -----------------------------------------------------------
#
# A check (a PROOF.bend run, or a unit's own file) and its files (the law
# file first): each law of the law file is open (no def of its proof: for a
# LAWS.bend, `ALIAS.NAME` in a file with proofs that imports it as ALIAS; in
# its own file, `NAME`), holed (its proof has a ?hole), or checked.  Open and
# holed laws are taken out of every file before the first check (so their
# TODOs do not hide the @unsafe report), and so is any def with a hole.  Then
# each check's first failing def is taken out: a law's proof (or its
# statement) fails that law, any other def of the files is a helper (the laws
# that use it fail at a later check, by name); a def of no file stops the
# checks.  When a check passes, the laws still standing pass, but those the
# @unsafe report names.

type AlL is Data:
  AlL{name: List<&2, U32>, pdef: List<&2, U32>}

type AlSt is Data:
  AlSt{name: List<&2, U32>, st: List<&2, U32>, why: List<&2, U32>}

def AlSt.name(+s: AlSt) -> List<&2, U32>:
  match s:
    case AlSt{n, x, w}:
      n

def AlSt.st(+s: AlSt) -> List<&2, U32>:
  match s:
    case AlSt{n, x, w}:
      x

def AlSt.why(+s: AlSt) -> List<&2, U32>:
  match s:
    case AlSt{n, x, w}:
      w

# the files as they are now, the laws standing, the outcomes, notes, checks
# run, their ms, the last check's answer
type AlCk is Data:
  AlCk{fs: List<&2, AlF>, live: List<&2, AlL>, done: List<&2, AlSt>, notes: List<&2, List<&2, U32>>, runs: Nat, ms: Nat, last: List<&2, U32>}

def AlCk.fs(+c: AlCk) -> List<&2, AlF>:
  match c:
    case AlCk{f, l, d, n, r, m, s}:
      f

def AlCk.live(+c: AlCk) -> List<&2, AlL>:
  match c:
    case AlCk{f, l, d, n, r, m, s}:
      l

def AlCk.done(+c: AlCk) -> List<&2, AlSt>:
  match c:
    case AlCk{f, l, d, n, r, m, s}:
      d

def AlCk.notes(+c: AlCk) -> List<&2, List<&2, U32>>:
  match c:
    case AlCk{f, l, d, n, r, m, s}:
      n

def AlCk.runs(+c: AlCk) -> Nat:
  match c:
    case AlCk{f, l, d, n, r, m, s}:
      r

def AlCk.ms(+c: AlCk) -> Nat:
  match c:
    case AlCk{f, l, d, n, r, m, s}:
      m

def AlCk.last(+c: AlCk) -> List<&2, U32>:
  match c:
    case AlCk{f, l, d, n, r, m, s}:
      s

# one check run: its ms and its answer's line
def al.ran(+ms: Nat, +said: List<&2, U32>, ck: AlCk) -> AlCk:
  match ck:
    case AlCk{f, l, d, n, r, m, s}:
      AlCk{f, l, d, n, 1n+r, Nat.add(m, ms), said}

# a law's proof among the defs: the first ALIAS.NAME, of the aliases the
# law file has in the files with proofs, that is a def (a1); else NAME (none:
# an empty name)
def al.pd.go(xs: List<&2, List<&2, U32>>, +l: List<&2, U32>, +defs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +a <> t:
      +pd = T.cat([a, [46], l])
      +r = al.pd.go(t, l, defs)
      Bool.pick(List<&2, U32>, T.f3.in(defs, pd), pd, r)

def al.pd.of(+a1: Bool, +aliases: List<&2, List<&2, U32>>, +l: List<&2, U32>, +defs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, a1, al.pd.go(aliases, l, defs), Bool.pick(List<&2, U32>, T.f3.in(defs, l), l, Nil{}))

# the prep's tally: laws standing, outcomes, laws and defs to take out
type AlP is Data:
  AlP{live: List<&2, AlL>, done: List<&2, AlSt>, dl: List<&2, List<&2, U32>>, dd: List<&2, List<&2, U32>>}

def al.prep.one(ok: Bool, +has: Bool, +l: List<&2, U32>, +pd: List<&2, U32>, +st: List<&2, U32>, +why: List<&2, U32>, p: AlP) -> AlP:
  match ok p:
    case True{} AlP{lv, d, dl, dd}:
      AlP{{AlL{l, pd} : AlL} <> lv, d, dl, dd}
    case False{} AlP{lv, d, +dl, +dd}:
      AlP{lv, {AlSt{l, st, why} : AlSt} <> d, l <> dl, Bool.pick(List<&2, List<&2, U32>>, has, pd <> dd, dd)}

def al.prep.go(ls: List<&2, List<&2, U32>>, +a1: Bool, +aliases: List<&2, List<&2, U32>>, +defs: List<&2, List<&2, U32>>, +bs: List<&2, AlB>, p: AlP) -> AlP:
  match ls:
    case Nil{}:
      p
    case +l <> t:
      +pd = al.pd.of(a1, aliases, l, defs)
      +has = Bool.not(T.empty(pd))
      +hole = Bool.and(has, al.holes(AlB.text(al.piece(bs, 2n, pd))))
      +st = Bool.pick(List<&2, U32>, has, U.b("hole"), U.b("open"))
      +why = Bool.pick(List<&2, U32>, has, U.b("its proof has a ?hole"), U.b("no def proves it"))
      al.prep.go(t, a1, aliases, defs, bs, al.prep.one(Bool.and(has, Bool.not(hole)), has, l, pd, st, why, p))

# the defs with a hole
def al.hole.defs(bs: List<&2, AlB>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      +r = al.hole.defs(t)
      Bool.pick(List<&2, List<&2, U32>>, Bool.and(Nat.is_eq(AlB.kind(b), 2n), al.holes(AlB.text(b))), AlB.name(b) <> r, r)

def al.noted(xs: List<&2, List<&2, U32>>, +pre: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      T.cat([pre, x]) <> al.noted(t, pre)

def al.prep.fin(p: AlP, +fs: List<&2, AlF>, +hd: List<&2, List<&2, U32>>) -> AlCk:
  match p:
    case AlP{+lv, +d, +dl, +dd}:
      AlCk{al.fs.drops(fs, dl, List.append(&2, List<&2, U32>, dd, hd)), lv, d, al.noted(hd, U.b("dropped (a ?hole): ")), 0n, 0n, Nil{}}

# a check's laws before its first check (a1: a LAWS.bend, the aliases it has
# in the files with proofs; else the law file proves its own laws)
def al.prep(+a1: Bool, +aliases: List<&2, List<&2, U32>>, +fs: List<&2, AlF>) -> AlCk:
  +bs = al.fs.blocks(fs)
  +ls = al.names(al.blocks(al.fs.first(fs)), 1n)
  al.prep.fin(al.prep.go(ls, a1, aliases, al.names(bs, 2n), bs, AlP{Nil{}, Nil{}, Nil{}, Nil{}}), fs, al.hole.defs(bs))

# the standing law named nm or proven by nm (none: an empty name)
def al.live.of(ls: List<&2, AlL>, +nm: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case AlL{+l, +pd} <> t:
      +r = al.live.of(t, nm)
      Bool.pick(List<&2, U32>, Bool.or(U.eq(l, nm), U.eq(pd, nm)), l, r)

def al.live.pd(ls: List<&2, AlL>, +l: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case AlL{+x, +pd} <> t:
      +r = al.live.pd(t, l)
      Bool.pick(List<&2, U32>, U.eq(x, l), pd, r)

def al.live.less(ls: List<&2, AlL>, +l: List<&2, U32>) -> List<&2, AlL>:
  match ls:
    case Nil{}:
      Nil{}
    case AlL{+x, +pd} <> t:
      +r = al.live.less(t, l)
      Bool.pick(List<&2, AlL>, U.eq(x, l), r, {AlL{x, pd} : AlL} <> r)

type AlRm is Data:
  AlRm{ck: AlCk, stop: Bool, why: List<&2, U32>}

def AlRm.ck(+r: AlRm) -> AlCk:
  match r:
    case AlRm{c, s, w}:
      c

def AlRm.stop(+r: AlRm) -> Bool:
  match r:
    case AlRm{c, s, w}:
      s

def AlRm.why(+r: AlRm) -> List<&2, U32>:
  match r:
    case AlRm{c, s, w}:
      w

def al.rm.fs(isl: Bool, +fs: List<&2, AlF>, +l: List<&2, U32>, +pd: List<&2, U32>, +nm: List<&2, U32>) -> List<&2, AlF>:
  match isl:
    case True{}:
      al.fs.drops(fs, [l], [pd])
    case False{}:
      al.fs.drops(fs, Nil{}, [nm])

# a check failed at nm: its law (its statement or proof) fails and is taken
# out; else nm, a helper def of the files, is taken out; else the checks stop
def al.rm(+nm: List<&2, U32>, +why: List<&2, U32>, ck: AlCk) -> AlRm:
  match ck:
    case AlCk{+fs, +live, +done, +ns, +r, +ms, +last}:
      +l = al.live.of(live, nm)
      +isl = Bool.not(T.empty(l))
      +pd = al.live.pd(live, l)
      +helper = al.fs.has(fs, 2n, nm)
      +fs2 = al.rm.fs(isl, fs, l, pd, nm)
      +done2 = Bool.pick(List<&2, AlSt>, isl, {AlSt{l, U.b("fail"), why} : AlSt} <> done, done)
      +ns2 = Bool.pick(List<&2, List<&2, U32>>, Bool.and(Bool.not(isl), helper), T.cat([U.b("dropped "), nm, U.b(": "), why]) <> ns, ns)
      +stop = Bool.and(Bool.not(isl), Bool.not(helper))
      AlRm{AlCk{fs2, al.live.less(live, l), done2, ns2, r, ms, last}, stop, T.cat([U.b("outside "), nm, U.b(": "), why])}

def al.mark(ls: List<&2, AlL>, +st: List<&2, U32>, +why: List<&2, U32>, +done: List<&2, AlSt>) -> List<&2, AlSt>:
  match ls:
    case Nil{}:
      done
    case AlL{+l, +pd} <> t:
      al.mark(t, st, why, {AlSt{l, st, why} : AlSt} <> done)

def al.ends.in(ns: List<&2, List<&2, U32>>, +s: List<&2, U32>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case +n <> t:
      Bool.or(U.suffix(n, s), al.ends.in(t, s))

# a passing check's laws: pass, but unsafe when the report names the law
# (NAME, LB.NAME) or its proof (PDEF, or PDEF with a file's prefix)
def al.mark.uns(ls: List<&2, AlL>, +names: List<&2, List<&2, U32>>, +lb: List<&2, U32>, +done: List<&2, AlSt>) -> List<&2, AlSt>:
  match ls:
    case Nil{}:
      done
    case AlL{+l, +pd} <> t:
      +bad = Bool.or(Bool.or(T.f3.in(names, l), T.f3.in(names, pd)), Bool.or(T.f3.in(names, T.cat([lb, [46], l])), al.ends.in(names, T.cat([[46], pd]))))
      +s = {AlSt{l, Bool.pick(List<&2, U32>, bad, U.b("unsafe"), U.b("pass")), Bool.pick(List<&2, U32>, bad, U.b("relies on @unsafe or foreign code"), Nil{})} : AlSt}
      al.mark.uns(t, names, lb, s <> done)

# the laws still standing when the checks end with r (lb: the law file's base name)
def al.finish(r: AlR, +lb: List<&2, U32>, ck: AlCk) -> AlCk:
  match r ck:
    case AlClean{} AlCk{f, +lv, +d, n, rn, m, s}:
      AlCk{f, Nil{}, al.mark(lv, U.b("pass"), Nil{}, d), n, rn, m, s}
    case AlUnsafe{+ns} AlCk{f, +lv, +d, n, rn, m, s}:
      AlCk{f, Nil{}, al.mark.uns(lv, ns, lb, d), n, rn, m, s}
    case AlTodo{+w} AlCk{f, +lv, +d, n, rn, m, s}:
      AlCk{f, Nil{}, al.mark(lv, U.b("todo"), T.cat([w, U.b(" (the proof checks; open claims elsewhere hide the @unsafe report)")]), d), n, rn, m, s}
    case AlTime{} AlCk{f, +lv, +d, n, rn, m, s}:
      AlCk{f, Nil{}, al.mark(lv, U.b("timeout"), U.b("the check ran past its time"), d), n, rn, m, s}
    case AlLoc{+nm, +w} AlCk{f, +lv, +d, n, rn, m, s}:
      AlCk{f, Nil{}, al.mark(lv, U.b("undecided"), T.cat([U.b("checks used up at "), nm, U.b(": "), w]), d), n, rn, m, s}
    case AlOther{+w} AlCk{f, +lv, +d, n, rn, m, s}:
      AlCk{f, Nil{}, al.mark(lv, U.b("error"), w, d), n, rn, m, s}

# a law's outcome
def al.st.of(ss: List<&2, AlSt>, +l: List<&2, U32>) -> AlSt:
  match ss:
    case Nil{}:
      AlSt{l, U.b("missing"), U.b("no law of this name in the law file")}
    case +s <> t:
      +r = al.st.of(t, l)
      Bool.pick(AlSt, U.eq(AlSt.name(s), l), s, r)

def al.yn(+b: Bool) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, b, U.b("yes"), U.b("no"))

def al.lnames(ls: List<&2, AlL>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case AlL{+l, +p} <> t:
      l <> al.lnames(t)

def al.snames(ss: List<&2, AlSt>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      Nil{}
    case AlSt{+l, +s, +w} <> t:
      T.cat([l, [32], s]) <> al.snames(t)

# a prep seen: the laws standing, the outcomes, the notes, what the files still have
def al.prep.view(+c: AlCk) -> List<&2, List<&2, U32>>:
  +fs = AlCk.fs(c)
  List.concat(&2, List<&2, U32>, [al.lnames(AlCk.live(c)), al.snames(AlCk.done(c)), AlCk.notes(c),
    [T.cat([U.b("has b: "), al.yn(al.fs.has(fs, 1n, U.b("b")))]), T.cat([U.b("has L.c: "), al.yn(al.fs.has(fs, 2n, U.b("L.c")))]), T.cat([U.b("has L.a: "), al.yn(al.fs.has(fs, 2n, U.b("L.a")))])]])

# Rank ------------------------------------------------------------------------------------------

# a law's text (its doc comment, then the law) states it for every input: a `for` binder
def al.for.every(+t: List<&2, U32>) -> Bool:
  U.infix(t, U.b("\n  for "))

# a law's rank in training (the user, 11-15: the laws that check fixed inputs go in "ranked below
# laws that hold for every input"): 0 for every input, 1 fixed inputs
def al.rank(+t: List<&2, U32>) -> Nat:
  Bool.pick(Nat, al.for.every(t), 0n, 1n)

# The ask ---------------------------------------------------------------------------------------
#
# The user, 11-15: "Yes" to the authors'-law ask in Transcript.bend.  Every passing record's law as
# the fill, repair and direct asks state it (Transcript.bend f3.alaw.block): its statement only
# (T.f3.stmts: the `law` line and the lines under it, its doc comment and its proof left out) less
# any comment line in it, so no author's note or tool's comment is trained on as the spec; at most
# al.ask.max() laws a unit, in al.ranked's order (every input first), none longer than al.ask.long()
# bytes, each once.  A law whose unit is in a held-out file, or that names one (ValidText.bend, R7's
# change 8), is left out, so a held-out unit's laws are never trained on.  The ask's map is keyed
# PATH#NAME: Transcript's mg.path of the unit's id and the unit's name.

def al.ask.max() -> Nat:
  4n

def al.ask.long() -> Nat:
  800n

# a comment line: `#` after its indent
def al.ask.cmt(+l: List<&2, U32>) -> Bool:
  U.prefix(U.trim.left(l), U.b("#"))

def al.ask.keep(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = al.ask.keep(t)
      Bool.pick(List<&2, List<&2, U32>>, al.ask.cmt(l), r, l <> r)

# a record's law (field 7: its doc comment, then the law) as the ask states it
def al.ask.stmt(+t: List<&2, U32>) -> List<&2, U32>:
  al.unlines(al.ask.keep(al.lines(T.f3.stmts(t))))

# a record's law as the ask's map holds it: the law file's import lines the law uses (field 8; a
# name as `C.f` reads by them; Transcript.bend states each once), a blank line, the statement (none
# when there is no statement)
def al.ask.stmt.of(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +im = X.ex.trim(T.field(fs, 8n))
  +s = al.ask.stmt(T.field(fs, 7n))
  Bool.pick(List<&2, U32>, Bool.or(T.empty(s), T.empty(im)), s, T.cat([im, U.b("\n\n"), s]))

# a unit's key: PATH#NAME
def al.ask.key(+id: List<&2, U32>) -> List<&2, U32>:
  T.cat([T.mg.path(id), [35], T.mg.upto(T.mg.after(id, 35), 64)])

def al.ask.names.held(+k: U32, ws: List<&2, List<&2, U32>>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> t:
      Bool.or(Bool.and(Bool.not(T.empty(w)), V.vd.held(k, w)), al.ask.names.held(k, t))

# the record's unit is in a held-out file, or its law names one (field 11: FILE#NAME, a space between)
def al.ask.held(+k: U32, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> Bool:
  Bool.or(V.vd.held(k, id), al.ask.names.held(k, T.split(T.field(fs, 11n), 32)))

# the laws in a unit's value (0x1F between)
def al.ask.n(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +c <> t:
      al.ask.n(t, Bool.pick(Nat, U32.is_eq(c, 31), Nat.add(n, 1n), n))

# The map: each unit's laws, 0x1F between; the units, newest first; the laws kept, the records held out
type AlAk is Type:
  AlAk{m: Map<&2, List<&2, U32>>, ks: List<&2, List<&2, U32>>, laws: Nat, held: Nat}

def al.ask.new() -> AlAk:
  AlAk{Map.new(&2, List<&2, U32>), Nil{}, 0n, 0n}

def al.ask.got(+key: List<&2, U32>, +s: List<&2, U32>, +ks: List<&2, List<&2, U32>>, +nl: Nat, +nh: Nat, r: Map<&2, List<&2, U32>> & List<&2, U32>) -> AlAk:
  match r:
    case (m2, +cur):
      +fresh = T.empty(cur)
      +n = Bool.pick(Nat, fresh, 0n, al.ask.n(cur, 1n))
      +keep = Bool.and(Bool.not(T.empty(s)), Bool.and(Bool.not(U.infix(cur, s)), Bool.and(Nat.is_lt(n, al.ask.max()), Bool.not(Nat.is_lt(al.ask.long(), U.len(s))))))
      +v = Bool.pick(List<&2, U32>, fresh, s, T.cat([cur, [31], s]))
      AlAk{Map.set(&2, List<&2, U32>, m2, T.mg.str(key), Bool.pick(List<&2, U32>, keep, v, cur)),
        Bool.pick(List<&2, List<&2, U32>>, Bool.and(keep, fresh), key <> ks, ks), Bool.pick(Nat, keep, Nat.add(nl, 1n), nl), nh}

# a law for the unit KEY, kept when it is new to it, under the cap and not too long
def al.ask.put(a: AlAk, +key: List<&2, U32>, +s: List<&2, U32>) -> AlAk:
  match a:
    case AlAk{m, ks, nl, nh}:
      al.ask.got(key, s, ks, nl, nh, Map.get(List<&2, U32>, Nil{}, m, T.mg.str(key)))

def al.ask.held.one(a: AlAk) -> AlAk:
  match a:
    case AlAk{m, ks, nl, nh}:
      AlAk{m, ks, nl, Nat.add(nh, 1n)}

def al.ask.rec.on(held: Bool, +key: List<&2, U32>, +s: List<&2, U32>, a: AlAk) -> AlAk:
  match held:
    case True{}:
      al.ask.held.one(a)
    case False{}:
      al.ask.put(a, key, s)

# a passing record (its id, its fields) into the map
def al.ask.rec(+k: U32, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, a: AlAk) -> AlAk:
  al.ask.rec.on(al.ask.held(k, id, fs), al.ask.key(id), al.ask.stmt.of(fs), a)

def al.ask.out.go(ks: List<&2, List<&2, U32>>, +m: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  match ks:
    case Nil{}:
      Nil{}
    case +key <> t:
      T.cat([key, [0], T.mg.got(Map.get(List<&2, U32>, Nil{}, m, T.mg.str(key))), [0], al.ask.out.go(t, m)])

# the ask's file: a pair a unit, oldest first (KEY, its laws)
def al.ask.out(a: AlAk) -> List<&2, U32>:
  match a:
    case AlAk{m, ks, nl, nh}:
      al.ask.out.go(List.reverse(&2, List<&2, U32>, ks), m)

# the file and its counts: units, laws, records held out
def al.ask.done(a: AlAk) -> List<&2, U32> & Nat & Nat & Nat:
  match a:
    case AlAk{m, +ks, nl, nh}:
      (al.ask.out.go(List.reverse(&2, List<&2, U32>, ks), m), List.length(&2, List<&2, U32>, ks), nl, nh)

# The prove units -------------------------------------------------------------------------------
#
# R7's change 6 (docs/r7/PLAN.md; the user, 11-14: "work on these"): more proofs, and induction
# with the rewrite step.  A passing law's proof, from its check file, as a unit of Units.bend's
# shape (a proposition) that bend-check checks and bend-transcript renders as any other: the def
# that proves it, `ALIAS.NAME` for a LAWS.bend law in its PROOF.bend (Units.bend never cuts those:
# their law is in another file), `NAME` in the law's own file.  Its fields, as Units.bend's: bend,
# proposition, the def's name, the law's doc, the law's statement (al.ask.stmt), the file before
# the def (the head), nothing (the pre: the law is above the def, or in the law file), the def (the
# body), the file after it (the tail), the names the body uses, the hole (the def's header, then
# `?goal`), then at most four mutants: a proof's own two first (one `%` rewrite step dropped with
# the lines under it: an induction one line short, as r6's add_zero; the first rewrite's lemma
# misspelt: a wrong name, as r5g's), then Units.bend's.  A record gives one only when its check ran
# once (nothing was taken out of its files) within the ms allowed, its def is in the file and new
# to it, the def is at most Units.bend's 40 lines and 3,000 bytes, the file at most 2,000 lines,
# and a trivial proof (neither a rewrite step nor a `match`) is under the cap a check file.

# a line's indentation (its leading blanks)
def al.pv.ind(+l: List<&2, U32>) -> Nat:
  Nat.sub(U.len(l), U.len(U.trim.left(l)))

def al.pv.dname.if(go: Bool, +l: List<&2, U32>) -> List<&2, U32>:
  match go:
    case True{}:
      +r = List.drop(&2, U32, l, 4n)
      +i = U.find(r, [40], 0n)
      Bool.pick(List<&2, U32>, Nat.is_lt(i, U.len(r)), List.take(&2, U32, r, i), Nil{})
    case False{}:
      Nil{}

# the name of the def a line starts (none: it starts none)
def al.pv.dname(+l: List<&2, U32>) -> List<&2, U32>:
  al.pv.dname.if(U.prefix(l, U.b("def ")), l)

# whether a def's name is the law's proof: NAME, or (a law file's law) ALIAS.NAME
def al.pv.is(+dn: List<&2, U32>, +lw: List<&2, U32>, +same: Bool) -> Bool:
  Bool.and(Bool.not(T.empty(dn)), Bool.or(U.eq(dn, lw), Bool.and(Bool.not(same), U.suffix(dn, T.cat([[46], lw])))))

# the index of the first of the lines (from i) that starts the law's proof (none: the lines' count)
def al.pv.at(ls: List<&2, List<&2, U32>>, +lw: List<&2, U32>, +same: Bool, +i: Nat) -> Nat:
  match ls:
    case Nil{}:
      i
    case +l <> t:
      Bool.pick(Nat, al.pv.is(al.pv.dname(l), lw, same), i, al.pv.at(t, lw, same, 1n+i))

# a line still the def's: blank or indented (none: past the file's end)
def al.pv.under(+l: List<&2, U32>) -> Bool:
  Bool.and(Bool.not(T.empty(l)), Bool.or(U.blank(l), Bool.not(U.col0(l))))

# a def's length in lines from its first: the lines under it that are blank or indented, less the
# blank ones at its end (go: the first of ls is the def's; k: the lines so far; last: through its
# last line not blank)
def al.pv.len.go(ls: List<&2, List<&2, U32>>, go: Bool, +k: Nat, +last: Nat) -> Nat:
  match ls go:
    case +l <> +t True{}:
      al.pv.len.go(t, al.pv.under(U.nth(t, 0n)), 1n+k, Bool.pick(Nat, U.blank(l), last, 1n+k))
    case _ _:
      last

# the length of the def at line d
def al.pv.len(+ls: List<&2, List<&2, U32>>, +d: Nat) -> Nat:
  +r = List.drop(&2, List<&2, U32>, ls, 1n+d)
  al.pv.len.go(r, al.pv.under(U.nth(r, 0n)), 1n, 1n)

# the def's header: its first line through its first `):` (a law's proof has no return type)
def al.pv.header(+l: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, l, Nat.add(U.find(l, U.b("):"), 0n), 2n))

# the hole: the header, then `?goal` under it
def al.pv.hole(+l: List<&2, U32>) -> List<&2, U32>:
  T.cat([U.trim.right(al.pv.header(l)), U.b("\n  ?goal\n")])

# a rewrite step's line: `%` its first byte not blank
def al.pv.rw(+l: List<&2, U32>) -> Bool:
  U.prefix(U.trim.left(l), [37])

# the indices of the rewrite lines, from i
def al.pv.rws(ls: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, Nat>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = al.pv.rws(t, 1n+i)
      Bool.pick(List<&2, Nat>, al.pv.rw(l), i <> r, r)

# the lines less line k and the lines right under it indented deeper (ik: line k's indentation;
# on: the line before was taken out)
def al.pv.cut(ls: List<&2, List<&2, U32>>, +k: Nat, +ik: Nat, +i: Nat, +on: Bool) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +out = Bool.or(Nat.is_eq(k, i), Bool.and(on, Bool.and(Bool.not(U.blank(l)), Nat.is_lt(ik, al.pv.ind(l)))))
      +r = al.pv.cut(t, k, ik, 1n+i, out)
      Bool.pick(List<&2, List<&2, U32>>, out, r, l <> r)

# the body less its line k, a rewrite step's, and the lines under it
def al.pv.drop.at(+ls: List<&2, List<&2, U32>>, +k: Nat) -> List<&2, U32>:
  U.concat(al.pv.cut(ls, k, al.pv.ind(U.nth(ls, k)), 0n, False{}))

# one rewrite step dropped, the one the id picks (none: the body has none).  The pick hashes the
# id (U.pick.at), which the checker cannot normalize (a U32 as a Nat): the law is al.pv.drop.at's
def al.pv.mut.drop(+uid: List<&2, U32>, +body: List<&2, U32>) -> List<&2, U32>:
  +ls = U.lines(body)
  +rs = al.pv.rws(ls, 0n)
  +n = List.length(&2, Nat, rs)
  +k = Maybe.default(&2, Nat, List.get(&2, Nat, rs, U.pick.at(uid, 7n, n)), 0n)
  Bool.pick(List<&2, U32>, Nat.is_eq(n, 0n), Nil{}, al.pv.drop.at(ls, k))

# a rewrite line with its lemma's name misspelt, its last byte dropped (none: a name under 3 bytes)
def al.pv.mis(+l: List<&2, U32>) -> List<&2, U32>:
  +j = Nat.add(1n, al.pv.ind(l))
  +after = List.drop(&2, U32, l, j)
  +n = U.len(al.word(after))
  Bool.pick(List<&2, U32>, Nat.is_lt(n, 3n), Nil{}, T.cat([List.take(&2, U32, l, j), List.take(&2, U32, after, Nat.sub(n, 1n)), List.drop(&2, U32, after, n)]))

# the first rewrite step's lemma misspelt (none: the body has none)
def al.pv.mut.name(+body: List<&2, U32>) -> List<&2, U32>:
  +ls = U.lines(body)
  +rs = al.pv.rws(ls, 0n)
  +k = Maybe.default(&2, Nat, List.get(&2, Nat, rs, 0n), 0n)
  +m = al.pv.mis(U.nth(ls, k))
  Bool.pick(List<&2, U32>, Bool.or(Nat.is_eq(List.length(&2, Nat, rs), 0n), T.empty(m)), Nil{}, U.concat(List.set(&2, List<&2, U32>, ls, k, m)))

# the mutants: the proof's own two, then Units.bend's, not empty, not the body, each once, at most four
def al.pv.muts(+uid: List<&2, U32>, +body: List<&2, U32>, +nm: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.take(&2, List<&2, U32>, U.dedup(body, List.append(&2, List<&2, U32>, [al.pv.mut.drop(uid, body), al.pv.mut.name(body)], U.mutants(3n, uid, body, nm)), Nil{}), 4n)

# a comment line less its marker (`#` and a blank after it)
def al.pv.unc(+l: List<&2, U32>) -> List<&2, U32>:
  +x = List.drop(&2, U32, l, 1n)
  Bool.pick(List<&2, U32>, U.prefix(x, [32]), List.drop(&2, U32, x, 1n), x)

# the comment lines the lines lead with (go: the first is one), markers out
def al.pv.doc.go(ls: List<&2, List<&2, U32>>, go: Bool) -> List<&2, List<&2, U32>>:
  match ls go:
    case +l <> +t True{}:
      al.pv.unc(l) <> al.pv.doc.go(t, U.prefix(U.nth(t, 0n), [35]))
    case _ _:
      Nil{}

# a law's doc: the comment lines its text leads with, markers out
def al.pv.doc(+t: List<&2, U32>) -> List<&2, U32>:
  +ls = U.lines(t)
  U.trim.right(U.concat(al.pv.doc.go(ls, U.prefix(U.nth(ls, 0n), [35]))))

# an id's class (`curated`, `own`, `repo`: before its first `:`)
def al.pv.cls(+id: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, id, U.find(id, [58], 0n))

# a record's check file, from its root
def al.pv.path(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  T.cat([T.field(fs, 4n), [47], T.field(fs, 9n)])

# a passing record whose check ran once (nothing taken out of its files) in ms, at most maxms
def al.pv.want(+fs: List<&2, List<&2, U32>>, +maxms: Nat, +ms: Nat) -> Bool:
  Bool.and(U.eq(T.field(fs, 1n), U.b("pass")), Bool.and(U.infix(T.field(fs, 10n), U.b(", 1 checks,")), Nat.is_le(ms, maxms)))

# The tail moved up.  bend-check writes a variant as the head, the pre and the variant, and leaves
# the tail out (a def calls only the defs above it); but a PROOF.bend proves every law of the
# LAWS.bend it imports, so a proof with others under it fails there ("3 TODOs found": hanw__cpp-bend
# example/PROOF.bend#Laws.umax_is_an_input, 11-15).  So the tail's blocks that do not reach the def
# go up into the head, in order: a block (a def, law or type line at column 0 with the `#` lines
# right above it) stays under the def when it names the def or a name an earlier kept block
# declares (a def calls only the defs above it, so one pass in order is the closure).  A name
# matches as text, so a block kept by a longer name sharing its start only costs a unit.

# a line at column 0 opening a def, law or type
def al.pv.decl(+l: List<&2, U32>) -> Bool:
  Bool.or(U.prefix(l, U.b("def ")), Bool.or(U.prefix(l, U.b("law ")), U.prefix(l, U.b("type "))))

# whether line l, after line p, opens a block: a declaration not under a `#` line, or a `#` line under a
# blank one
def al.pv.bstart(+p: List<&2, U32>, +l: List<&2, U32>) -> Bool:
  Bool.or(Bool.and(al.pv.decl(l), Bool.not(U.prefix(p, [35]))), Bool.and(U.prefix(l, [35]), U.blank(p)))

# the lines in blocks (p: the line before; cur: the block so far, reversed)
def al.pv.blocks(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>, +cur: List<&2, List<&2, U32>>) -> List<&2, List<&2, List<&2, U32>>>:
  match ls:
    case Nil{}:
      [List.reverse(&2, List<&2, U32>, cur)]
    case +l <> t:
      +s = Bool.and(al.pv.bstart(p, l), Nat.is_lt(0n, List.length(&2, List<&2, U32>, cur)))
      +r = al.pv.blocks(t, l, Bool.pick(List<&2, List<&2, U32>>, s, [l], l <> cur))
      Bool.pick(List<&2, List<&2, List<&2, U32>>>, s, List.reverse(&2, List<&2, U32>, cur) <> r, r)

# the length of the name at the start of r
def al.pv.nlen(+r: List<&2, U32>) -> Nat:
  match r:
    case Nil{}:
      0n
    case +c <> t:
      Bool.pick(Nat, al.namech(c), 1n+al.pv.nlen(t), 0n)

# the name a declaration line declares (none: not one)
def al.pv.dnm(+l: List<&2, U32>) -> List<&2, U32>:
  +r = List.drop(&2, U32, l, Bool.pick(Nat, U.prefix(l, U.b("type ")), 5n, 4n))
  Bool.pick(List<&2, U32>, al.pv.decl(l), List.take(&2, U32, r, al.pv.nlen(r)), Nil{})

# the names a block declares
def al.pv.bnames(b: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match b:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = al.pv.bnames(t)
      +n = al.pv.dnm(l)
      Bool.pick(List<&2, List<&2, U32>>, T.empty(n), r, n <> r)

# whether a line of the block holds n
def al.pv.bhas(b: List<&2, List<&2, U32>>, +n: List<&2, U32>) -> Bool:
  match b:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(U.infix(l, n), al.pv.bhas(t, n))

# whether the block holds one of the names
def al.pv.uses(+b: List<&2, List<&2, U32>>, ns: List<&2, List<&2, U32>>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case +n <> t:
      Bool.or(al.pv.bhas(b, n), al.pv.uses(b, t))

# the blocks apart: those that go up (their lines), those kept under the def (their lines); ns: the
# names kept so far
def al.pv.part.put(+k: Bool, +b: List<&2, List<&2, U32>>, r: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  match r:
    case (+up, +kept):
      Bool.pick(List<&2, List<&2, U32>> & List<&2, List<&2, U32>>, k, (up, List.append(&2, List<&2, U32>, b, kept)), (List.append(&2, List<&2, U32>, b, up), kept))

def al.pv.part(bs: List<&2, List<&2, List<&2, U32>>>, +ns: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      (Nil{}, Nil{})
    case +b <> t:
      +k = al.pv.uses(b, ns)
      al.pv.part.put(k, b, al.pv.part(t, Bool.pick(List<&2, List<&2, U32>>, k, List.append(&2, List<&2, U32>, al.pv.bnames(b), ns), ns)))

# the head with the tail's free blocks under it (a blank line after them), and the tail left
def al.pv.lift.of(+head: List<&2, List<&2, U32>>, r: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>) -> List<&2, U32> & List<&2, U32>:
  match r:
    case (+up, +kept):
      +gap = Bool.pick(List<&2, List<&2, U32>>, Nat.is_lt(0n, List.length(&2, List<&2, U32>, up)), [[10]], Nil{})
      (U.concat(List.append(&2, List<&2, U32>, head, List.append(&2, List<&2, U32>, up, gap))), U.concat(kept))

def al.pv.lift(+head: List<&2, List<&2, U32>>, +tail: List<&2, List<&2, U32>>, +nm: List<&2, U32>) -> List<&2, U32> & List<&2, U32>:
  al.pv.lift.of(head, al.pv.part(al.pv.blocks(tail, Nil{}, Nil{}), [nm]))

def al.pv.unit.with(+uid: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +nm: List<&2, U32>, +body: List<&2, U32>, +names: List<&2, List<&2, U32>>, +hole: List<&2, U32>, ht: List<&2, U32> & List<&2, U32>) -> List<&2, U32>:
  match ht:
    case (+hd, +tl):
      +fields : List<&2, List<&2, U32>> = [U.b("bend"), U.b("proposition"), nm, al.pv.doc(T.field(fs, 7n)), al.ask.stmt(T.field(fs, 7n)), hd, Nil{}, body,
        tl, U.sep.join(names, 32), hole]
      T.cat([uid, [0], U.sep.join(List.append(&2, List<&2, U32>, fields, al.pv.muts(uid, body, names)), 30), [0]])

# the unit (a NUL pair: its id, its record) of the record's law, its proof the k lines of ls from d,
# the def named nm
def al.pv.unit(+cls: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +nm: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +d: Nat, +k: Nat) -> List<&2, U32>:
  +uid = T.cat([cls, [58], T.field(fs, 9n), [35], nm, [64], U.b(Nat.show(1n+d))])
  +body = U.slice(ls, d, Nat.add(d, k))
  +names = U.names(3n, nm, body)
  al.pv.unit.with(uid, fs, nm, body, names, al.pv.hole(U.nth(ls, d)), al.pv.lift(List.take(&2, List<&2, U32>, ls, d), List.drop(&2, List<&2, U32>, ls, Nat.add(d, k)), nm))

def al.pv.unit.if(go: Bool, +cls: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +nm: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +d: Nat, +k: Nat) -> List<&2, U32>:
  match go:
    case True{}:
      al.pv.unit(cls, fs, nm, ls, d, k)
    case False{}:
      Nil{}

# The walk: the check file read (its path, its lines), the defs taken from it, its trivial ones
# taken; the units out, those with a rewrite step or a match, the records passed over
type AlPv is Data:
  AlPv{path: List<&2, U32>, ls: List<&2, List<&2, U32>>, seen: List<&2, List<&2, U32>>, triv: Nat, n: Nat, deep: Nat, skip: Nat}

def AlPv.path(+s: AlPv) -> List<&2, U32>:
  match s:
    case AlPv{p, ls, seen, tr, n, dp, sk}:
      p

def al.pv.new() -> AlPv:
  AlPv{Nil{}, Nil{}, Nil{}, 0n, 0n, 0n, 0n}

# the check file at p read (its text x): its lines, nothing taken from it yet
def al.pv.fresh(+p: List<&2, U32>, +x: List<&2, U32>, st: AlPv) -> AlPv:
  match st:
    case AlPv{op, ols, os, ot, n, dp, sk}:
      AlPv{p, U.lines(x), Nil{}, 0n, n, dp, sk}

# a record's unit, and the walk after it
type AlPvR is Data:
  AlPvR{out: List<&2, U32>, st: AlPv}

def AlPvR.out(+r: AlPvR) -> List<&2, U32>:
  match r:
    case AlPvR{o, s}:
      o

def AlPvR.st(+r: AlPvR) -> AlPv:
  match r:
    case AlPvR{o, s}:
      s

# a wanted record from the file read: its unit when its proof is there, new to the file, small
# enough, and not a trivial one over tcap
def al.pv.take(+id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +tcap: Nat, st: AlPv) -> AlPvR:
  match st:
    case AlPv{+p, +ls, +seen, +tr, +n, +dp, +sk}:
      +same = U.eq(T.field(fs, 3n), U.b("same-file"))
      +nl = List.length(&2, List<&2, U32>, ls)
      +d = al.pv.at(ls, T.field(fs, 6n), same, 0n)
      +dn = al.pv.dname(U.nth(ls, d))
      +k = al.pv.len(ls, d)
      +body = U.slice(ls, d, Nat.add(d, k))
      +deep = Bool.or(U.has(body, 37), U.infix(body, U.b("match ")))
      +ok = Bool.and(Bool.and(Nat.is_lt(d, nl), Nat.is_le(nl, 2000n)), Bool.and(Bool.not(U.member(seen, dn)), Bool.and(Nat.is_le(k, 40n), Nat.is_le(U.len(body), 3000n))))
      +go = Bool.and(ok, Bool.or(deep, Nat.is_lt(tr, tcap)))
      AlPvR{al.pv.unit.if(go, al.pv.cls(id), fs, dn, ls, d, k),
        AlPv{p, ls, Bool.pick(List<&2, List<&2, U32>>, go, dn <> seen, seen), Bool.pick(Nat, Bool.and(go, Bool.not(deep)), 1n+tr, tr),
          Bool.pick(Nat, go, 1n+n, n), Bool.pick(Nat, Bool.and(go, deep), 1n+dp, dp), Bool.pick(Nat, go, sk, 1n+sk)}}

def al.pv.skip1(st: AlPv) -> AlPv:
  match st:
    case AlPv{p, ls, seen, tr, n, dp, sk}:
      AlPv{p, ls, seen, tr, n, dp, 1n+sk}

# a record (want: al.pv.want's) into the walk
def al.pv.rec(want: Bool, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +tcap: Nat, st: AlPv) -> AlPvR:
  match want:
    case True{}:
      al.pv.take(id, fs, tcap, st)
    case False{}:
      AlPvR{Nil{}, al.pv.skip1(st)}

# the walk's account
def al.pv.said(st: AlPv) -> String:
  match st:
    case AlPv{p, ls, seen, tr, n, dp, sk}:
      "authlaw prove: " ++ Nat.show(n) ++ " units (" ++ Nat.show(dp) ++ " with a rewrite step or a match), " ++ Nat.show(sk) ++ " records passed over"

# Laws ------------------------------------------------------------------------------------------

law al.ask.stmt.only:
  {al.ask.stmt(U.b("# the identity\nlaw a_id:\n  for x: U32\n  # a note\n  {a(x) == x : U32}\n\ndef a_id(x):\n  {==}\n"))
   == U.b("law a_id:\n  for x: U32\n  {a(x) == x : U32}") : List<&2, U32>}

def al.ask.stmt.only():
  {==}

law al.ask.key.unit:
  {al.ask.key(U.b("curated:ab__cd/src/f.bend#g.h@31")) == U.b("ab__cd/src/f.bend#g.h") : List<&2, U32>}

def al.ask.key.unit():
  {==}

# the import lines the law uses come first; a record without a statement gives none
law al.ask.stmt.imports:
  {(al.ask.stmt.of([Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, U.b("law l:\n  {C.f(0n) == 0n : Nat}"), U.b("import ./c.bend as C")]),
    al.ask.stmt.of([Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, U.b("# no law here"), U.b("import ./c.bend as C")]))
   == (U.b("import ./c.bend as C\n\nlaw l:\n  {C.f(0n) == 0n : Nat}"), Nil{}) : List<&2, U32> & List<&2, U32>}

def al.ask.stmt.imports():
  {==}

# a unit's laws: each once, at most al.ask.max(), the unit once, in the order put
law al.ask.cap:
  {al.ask.out(al.ask.put(al.ask.put(al.ask.put(al.ask.put(al.ask.put(al.ask.put(al.ask.put(al.ask.new(), U.b("p#f"), U.b("law a")), U.b("p#f"), U.b("law a")),
     U.b("p#g"), U.b("law z")), U.b("p#f"), U.b("law b")), U.b("p#f"), U.b("law c")), U.b("p#f"), U.b("law d")), U.b("p#f"), U.b("law e")))
   == U.b("p#f\0law a\u{1F}law b\u{1F}law c\u{1F}law d\0p#g\0law z\0") : List<&2, U32>}

def al.ask.cap():
  {==}

law al.rank.every:
  {(al.rank(U.b("# f is the identity\nlaw f_id:\n  for x: U32\n  {f(x) == x : U32}")), al.rank(U.b("law f_two:\n  {f(2) == 2 : U32}"))) == (0n, 1n) : Nat & Nat}

def al.rank.every():
  {==}

law al.norm.up:
  {(al.norm(U.b("r/a/b"), U.b("../c/d.bend")), al.norm(U.b("r"), U.b("./x.bend"))) == (U.b("r/a/c/d.bend"), U.b("r/x.bend")) : List<&2, U32> & List<&2, U32>}

def al.norm.up():
  {==}

law al.blocks.read:
  {al.names(al.blocks(U.b("import Base\nimport ./c.bend as C\n\n# twice\nlaw dbl:\n  for n: Nat\n  {C.d(n) == n : Nat}\n\ndef dbl(n):\n  ?TODO\n")), 1n)
   == [U.b("dbl")] : List<&2, List<&2, U32>>}

def al.blocks.read():
  {==}

law al.blocks.doc:
  {al.spec(al.piece(al.blocks(U.b("def f(x: U32) -> U32:\n  x\n\n# f is the identity\nlaw f_id:\n  for x: U32\n  {f(x) == x : U32}\n\ndef f_id(x):\n  {==}\n")), 1n, U.b("f_id")))
   == U.b("# f is the identity\nlaw f_id:\n  for x: U32\n  {f(x) == x : U32}") : List<&2, U32>}

def al.blocks.doc():
  {==}

law al.drop.def:
  {al.drop(U.b("law a:\n  {1n == 1n : Nat}\n\ndef a():\n  {==}\n\n# b\ndef b():\n  {==}\n"), 2n, U.b("a")) == U.b("law a:\n  {1n == 1n : Nat}\n\n# b\ndef b():\n  {==}\n") : List<&2, U32>}

def al.drop.def():
  {==}

law al.refs.names:
  {al.refs(U.b("law rt:\n  for v: U32\n  {B.le32_at(B.le32(v), 0n) == Some{v} : Maybe<&2, U32>}"), [AlI{U.b("B"), U.b("r/bytes.bend")}], U.b("r/LAWS.bend"), [U.b("lo")])
   == [U.b("r/bytes.bend#le32_at"), U.b("r/bytes.bend#le32")] : List<&2, List<&2, U32>>}

def al.refs.names():
  {==}

law al.holes.some:
  {(al.holes(U.b("def h():\n  ?TODO\n")), al.holes(U.b("def f?(x):\n  \"what?x\" # ?no\n"))) == (True{}, False{}) : Bool & Bool}

def al.holes.some():
  {==}

law al.result.reads:
  {(al.result(1, U.b("SOME PROOFS FAIL\nError:\n- expected : 4n\n- observed : 5n\nLocation: Laws.dbl_two\n10 | def Laws.dbl_two():")),
    al.result(1, U.b("SOME PROOFS FAIL\nError: 2 defs rely on unsafe or foreign code:\ndefs that depend on @unsafe: LAWS.dbl_one, cheat")))
   == (AlLoc{U.b("Laws.dbl_two"), U.b("- expected : 4n; - observed : 5n")}, AlUnsafe{[U.b("LAWS.dbl_one"), U.b("cheat")]}) : AlR & AlR}

def al.result.reads():
  {==}

law al.own.laws:
  {al.own(U.b("\nlaw g_zero:\n  {g(0n) == 0n : Nat}\n\ndef g_zero():\n  {==}\n\nlaw h_open:\n  {g(1n) == 1n : Nat}\n"), U.b("g")) == [U.b("g_zero")] : List<&2, List<&2, U32>>}

def al.own.laws():
  {==}

law al.prep.files:
  {al.prep.view(al.prep(True{}, [U.b("L")], [AlF{U.b("r/LAWS.bend"), U.b("import ./c.bend as C\n\nlaw a:\n  {C.f(0n) == 0n : Nat}\n\nlaw b:\n  {C.f(1n) == 1n : Nat}\n\nlaw c:\n  {C.f(2n) == 2n : Nat}\n")},
                                AlF{U.b("r/p/x.bend"), U.b("import ../LAWS.bend as L\n\ndef L.a():\n  {==}\n\ndef L.c():\n  ?TODO\n")}]))
   == [U.b("a"), U.b("c hole"), U.b("b open"), U.b("dropped (a ?hole): L.c"), U.b("has b: no"), U.b("has L.c: no"), U.b("has L.a: yes")] : List<&2, List<&2, U32>>}

def al.prep.files():
  {==}

# a LAWS.bend law's proof in its PROOF.bend: the first def ALIAS.NAME, through its last indented
# line (the blank line and the comment after it are not its); a law of the file itself: NAME only
def al.pv.ex() -> List<&2, U32>:
  U.b("import ./LAWS.bend as L\n\ndef L.a(n): {==}\n\ndef L.comm(a, b):\n  match a:\n    case Z{}:\n      %L.zero(b) : {_ == add(b, Z{}) : Nat}\n      {==}\n    case S{a}:\n      %L.succ(b, a) : {S{add(a, b)} == _ : Nat}\n      {==}\n\n# next\ndef L.b(): {==}\n")

law al.pv.at.len:
  {(al.pv.at(U.lines(al.pv.ex()), U.b("comm"), False{}, 0n), al.pv.len(U.lines(al.pv.ex()), 4n), al.pv.at(U.lines(al.pv.ex()), U.b("comm"), True{}, 0n))
   == (4n, 8n, 15n) : Nat & Nat & Nat}

def al.pv.at.len():
  {==}

law al.pv.names:
  {(al.pv.dname(U.b("def L.a(n): {==}\n")), al.pv.dname(U.b("  def x(n):\n")), al.pv.hole(U.b("def L.a(n): {==}\n")))
   == (U.b("L.a"), Nil{}, U.b("def L.a(n):\n  ?goal\n")) : List<&2, U32> & List<&2, U32> & List<&2, U32>}

def al.pv.names():
  {==}

# the proof's own mutants: its rewrite step dropped (with the line under it), its lemma misspelt;
# a body with no rewrite step gives none
law al.pv.muts.own:
  {(al.pv.drop.at(U.lines(U.b("def c(a):\n  match a:\n    case Z{}:\n      {==}\n    case S{p}:\n      %add_zero(p) : {x\n        == y : N}\n      {==}\n")), 5n),
    al.pv.mut.name(U.b("def c(a):\n  match a:\n    case S{p}:\n      %add_zero(p) : {x == y : N}\n      {==}\n")),
    al.pv.mut.drop(U.b("id"), U.b("def c(a): {==}\n")))
   == (U.b("def c(a):\n  match a:\n    case Z{}:\n      {==}\n    case S{p}:\n      {==}\n"),
       U.b("def c(a):\n  match a:\n    case S{p}:\n      %add_zer(p) : {x == y : N}\n      {==}\n"), Nil{}) : List<&2, U32> & List<&2, U32> & List<&2, U32>}

def al.pv.muts.own():
  {==}

law al.pv.doc.marks:
  {(al.pv.doc(U.b("# twice\n#  kept\nlaw d:\n  {x == x : N}")), al.pv.cls(U.b("curated:a/b.bend#f@3"))) == (U.b("twice\n kept"), U.b("curated")) : List<&2, U32> & List<&2, U32>}

def al.pv.doc.marks():
  {==}

# a PROOF.bend's tail: the blocks that do not name the def go up above it, the one that names it (and
# what names that one) stays under it
law al.pv.lift.moves:
  {al.pv.lift([U.b("H\n")], [U.b("def a():\n"), U.b("  x\n"), U.b("\n"), U.b("# uses it\n"), U.b("def q():\n"), U.b("  nm()\n"), U.b("\n"), U.b("def r():\n"), U.b("  q()\n"), U.b("\n"), U.b("def c():\n"), U.b("  y\n")], U.b("nm")) == (U.b("H\ndef a():\n  x\n\ndef c():\n  y\n\n"), U.b("# uses it\ndef q():\n  nm()\n\ndef r():\n  q()\n\n")) : List<&2, U32> & List<&2, U32>}

def al.pv.lift.moves():
  {==}
