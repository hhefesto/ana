import Base
import ../Sys.bend as S
import ./Ast.bend as T
import ./Print.bend as P
import ./Copy.bend as Q

# Gate: only Bend that checks is kept (the user, 2026-10-18: "only fully
# proven").  A module's file is written and checked with the locked
# compiler (`bend FILE --check-only`, which reports the first error only);
# the def the error names is dropped together with every item of the
# module that uses it, the file is written again, and so on until it prints
# ALL PROOFS CHECK.  An item holding a gap (?TODO) is dropped before any
# check, with the gap's reason.  Every drop is recorded with its reason
# and whether it was the failing item itself or one that depends on it:
# the ledger the translator is improved from.  The modules a file imports
# have passed their own gate before it, so an error is the file's own.
# Every def is prefixed `tgt.`.

# A dropped item: its Bend name, the Agda name its comment gives, the
# reason, and whether it only depended on a dropped one.
type TgtDrop is Data:
  TgtDrop{name: List<&2, U32>, agda: List<&2, U32>, why: List<&2, U32>, dep: Bool}

# What a check said: it passed, or it failed at the item called name (or,
# when the error names none, at a line of the file), for a reason.
type TgtV is Data:
  TgPass{}
  TgFail{name: List<&2, U32>, line: Nat, why: List<&2, U32>, span: List<&2, U32>}

def tgt.name(it: T.BItem) -> List<&2, U32>:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      n
    case T.BiType{n, ps, d, cs, doc}:
      n
    case T.BiComment{doc}:
      Nil{}

def tgt.doc.first(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case h <> t:
      h
    case Nil{}:
      Nil{}

# the Agda name an item's comment starts with (`Agda: Q`)
def tgt.agda(it: T.BItem) -> List<&2, U32>:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      S.strip(tgt.doc.first(doc), S.b("Agda: "))
    case T.BiType{n, ps, d, cs, doc}:
      S.strip(tgt.doc.first(doc), S.b("Agda: "))
    case T.BiComment{doc}:
      S.strip(tgt.doc.first(doc), S.b("Agda: "))

def tgt.gaps(it: T.BItem) -> List<&2, List<&2, U32>>:
  T.tba.item.fold(~T.tba.todos, it, Nil{})

def tgt.refs(it: T.BItem) -> List<&2, List<&2, U32>>:
  T.tba.item.refs(it)

def tgt.mem(+x: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(S.eq(h, x), tgt.mem(x, t))

def tgt.any.mem(xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(tgt.mem(h, ys), tgt.any.mem(t, ys))

# The kept items and the drops so far.
type TgtSt is Data:
  TgtSt{items: List<&2, T.BItem>, drops: List<&2, TgtDrop>}

def tgt.first.gap(gs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match gs:
    case h <> t:
      List.append(&2, U32, S.b("gap: "), h)
    case Nil{}:
      Nil{}

def tgt.gap.put(+it: T.BItem, gs: List<&2, List<&2, U32>>, st: TgtSt) -> TgtSt:
  match gs st:
    case Nil{} TgtSt{its, ds}:
      TgtSt{it <> its, ds}
    case g <> gt TgtSt{its, ds}:
      TgtSt{its, TgtDrop{tgt.name(it), tgt.agda(it), tgt.first.gap(g <> gt), False{}} <> ds}

# items with a gap dropped (with its reason), the others kept in order
def tgt.gapless(its: List<&2, T.BItem>) -> TgtSt:
  match its:
    case Nil{}:
      TgtSt{Nil{}, Nil{}}
    case +it <> t:
      tgt.gap.put(it, tgt.gaps(it), tgt.gapless(t))

def tgt.drop.names(ds: List<&2, TgtDrop>) -> List<&2, List<&2, U32>>:
  match ds:
    case Nil{}:
      Nil{}
    case TgtDrop{n, a, w, d} <> t:
      n <> tgt.drop.names(t)

# One round of dependents: every kept item that uses a dropped name is
# dropped too.  changed says whether any was.
type TgtDep is Data:
  TgtDep{st: TgtSt, changed: Bool}

# the first of names that is among dead (empty when none is)
def tgt.first.mem(ns: List<&2, List<&2, U32>>, +dead: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      Bool.pick(List<&2, U32>, tgt.mem(n, dead), n, tgt.first.mem(t, dead))

def tgt.dep.put(none: Bool, +used: List<&2, U32>, +it: T.BItem, r: TgtDep) -> TgtDep:
  match none r:
    case True{} TgtDep{TgtSt{its, ds}, c}:
      TgtDep{TgtSt{it <> its, ds}, c}
    case False{} TgtDep{TgtSt{its, ds}, c}:
      TgtDep{TgtSt{its, TgtDrop{tgt.name(it), tgt.agda(it), List.append(&2, U32, S.b("uses "), used), True{}} <> ds}, True{}}

def tgt.dep.one(+used: List<&2, U32>, +it: T.BItem, r: TgtDep) -> TgtDep:
  tgt.dep.put(S.eq(used, Nil{}), used, it, r)

# one round: each kept item that uses a dropped name is dropped too, its
# reason naming the name (why is the fallback no longer used)
def tgt.dep.round(its: List<&2, T.BItem>, +dead: List<&2, List<&2, U32>>, +why: List<&2, U32>, ds: List<&2, TgtDrop>) -> TgtDep:
  match its:
    case Nil{}:
      TgtDep{TgtSt{Nil{}, ds}, False{}}
    case +it <> t:
      tgt.dep.one(tgt.first.mem(tgt.refs(it), dead), it, tgt.dep.round(t, dead, why, ds))

def tgt.deps.go(fuel: Nat, +why: List<&2, U32>, r: TgtDep) -> TgtSt:
  match fuel r:
    case 1n+p TgtDep{TgtSt{its, +ds}, True{}}:
      tgt.deps.go(p, why, tgt.dep.round(its, tgt.drop.names(ds), why, ds))
    case _ TgtDep{st, c}:
      st

# the dependents of the drops, to a fixed point
def tgt.deps(+why: List<&2, U32>, st: TgtSt) -> TgtSt:
  match st:
    case TgtSt{+its, ds}:
      tgt.deps.go(1n+List.length(&2, T.BItem, its), why, TgtDep{TgtSt{its, ds}, True{}})

# Reading a check -------------------------------------------------------------

def tgt.line.after(+l: List<&2, U32>, +p: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  Bool.pick(Maybe<&2, List<&2, U32>>, S.prefix(l, p), Some{S.strip(l, p)}, None{})

def tgt.trim(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 32), tgt.trim(t), h <> t)
    case Nil{}:
      Nil{}

# the name after `Location:` on its line, if any
def tgt.location(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Bool.pick(List<&2, U32>, S.prefix(l, S.b("Location:")), tgt.trim(S.strip(l, S.b("Location:"))), tgt.location(t))

# whether xs starts with a digit
def tgt.digit.hd(xs: List<&2, U32>) -> Bool:
  match xs:
    case +h <> t:
      Bool.and(U32.is_ge(h, 48), U32.is_le(h, 57))
    case Nil{}:
      False{}

# the leading digits' value (d: xs starts with a digit, decided by the
# caller: a strict Bool.pick would read on past the digits)
def tgt.digits(xs: List<&2, U32>, +acc: Nat, d: Bool) -> Nat:
  match xs d:
    case h <> +t True{}:
      tgt.digits(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48))), tgt.digit.hd(t))
    case _ _:
      acc

def tgt.digits.of(+xs: List<&2, U32>) -> Nat:
  tgt.digits(xs, 0n, tgt.digit.hd(xs))

# the line a source excerpt marks with `NNN>|`, 0 when none
def tgt.marked(ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      Bool.pick(Nat, S.infix(l, S.b(">|")), tgt.digits.of(tgt.trim(l)), tgt.marked(t))

# the reason: the first two lines of the error's fields (`- message :`,
# `- expected :`, `- observed :`), trimmed
# whether the first line is a field line (`- `)
def tgt.field.hd(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case l <> t:
      S.prefix(l, S.b("- "))
    case Nil{}:
      False{}

# the first n field lines (hit: the first line is one, decided by the
# caller so each line is looked at once)
def tgt.why.go(ls: List<&2, List<&2, U32>>, n: Nat, hit: Bool) -> List<&2, U32>:
  match ls n hit:
    case ls 0n _:
      Nil{}
    case Nil{} 1n+p _:
      Nil{}
    case l <> +t 1n+p True{}:
      List.append(&2, U32, tgt.trim(S.strip(l, S.b("- "))), 32 <> tgt.why.go(t, p, tgt.field.hd(t)))
    case l <> +t 1n+p False{}:
      tgt.why.go(t, 1n+p, tgt.field.hd(t))

# when the error has no fields: the line after `Error:`
def tgt.first.err(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case +l <> +t:
      Bool.pick(List<&2, U32>, S.prefix(l, S.b("Error")), tgt.trim(S.strip(l, S.b("Error:"))), tgt.first.err(t))
    case Nil{}:
      S.b("an error bend did not explain")

def tgt.why.of(+w: List<&2, U32>, +ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.eq(w, Nil{}), tgt.first.err(ls), w)

def tgt.why(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  tgt.why.of(tgt.why.go(ls, 2n, tgt.field.hd(ls)), ls)

# the text the carets mark (`^^^` on the line under the `>|` one), empty
# when there is none: the two lines' columns agree after their first `|`
def tgt.bar(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 124), t, tgt.bar(t))

# how many c the text starts with (on: no other character came before)
def tgt.lead(xs: List<&2, U32>, +c: U32, on: Bool) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +h <> t:
      +k = Bool.and(on, U32.is_eq(h, c))
      Nat.add(Bool.pick(Nat, k, 1n, 0n), tgt.lead(t, c, k))

def tgt.cols.drop(n: Nat, xs: List<&2, U32>) -> List<&2, U32>:
  match n xs:
    case 1n+p h <> t:
      tgt.cols.drop(p, t)
    case _ xs:
      xs

def tgt.cols.take(n: Nat, xs: List<&2, U32>) -> List<&2, U32>:
  match n xs:
    case 1n+p h <> t:
      h <> tgt.cols.take(p, t)
    case _ xs:
      Nil{}

# the span up to its first space (Bend marks a binder with the space after it)
def tgt.word(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 32), Nil{}, h <> tgt.word(t))

def tgt.span.at(+ml: List<&2, U32>, +cl: List<&2, U32>) -> List<&2, U32>:
  +k = tgt.lead(tgt.bar(cl), 32, True{})
  tgt.word(tgt.cols.take(tgt.lead(tgt.cols.drop(k, tgt.bar(cl)), 94, True{}), tgt.cols.drop(k, tgt.bar(ml))))

def tgt.line.hd(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case l <> t:
      l
    case Nil{}:
      Nil{}

def tgt.span(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case +l <> +t:
      Bool.pick(List<&2, U32>, S.infix(l, S.b(">|")), tgt.span.at(l, tgt.line.hd(t)), tgt.span(t))
    case Nil{}:
      Nil{}

def tgt.verdict.of(pass: Bool, +ls: List<&2, List<&2, U32>>) -> TgtV:
  match pass:
    case True{}:
      TgPass{}
    case False{}:
      TgFail{tgt.location(ls), tgt.marked(ls), tgt.why(ls), tgt.span(ls)}

def tgt.verdict(+out: List<&2, U32>) -> TgtV:
  tgt.verdict.of(S.infix(out, S.b("ALL PROOFS CHECK")), S.split.lines(out))

# Locating a failure by line ------------------------------------------------

def tgt.nls(xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +h <> t:
      Nat.add(Bool.pick(Nat, U32.is_eq(h, 10), 1n, 0n), tgt.nls(t))

# the item whose printed lines hold line l: items are printed after the
# header (start lines) and each after a blank line
def tgt.at.line(its: List<&2, T.BItem>, +start: Nat, +l: Nat) -> List<&2, U32>:
  match its:
    case Nil{}:
      Nil{}
    case +it <> t:
      +first = Nat.add(start, 1n)
      +n = tgt.nls(P.tpr.item(it, Nil{}))
      Bool.pick(List<&2, U32>, Bool.and(Nat.is_gt(l, first), Nat.is_le(l, Nat.add(first, n))), tgt.name(it), tgt.at.line(t, Nat.add(first, n), l))

def tgt.names(its: List<&2, T.BItem>) -> List<&2, List<&2, U32>>:
  match its:
    case Nil{}:
      Nil{}
    case it <> t:
      tgt.name(it) <> tgt.names(t)

# the name to drop: the one the error names when it is a kept item, else
# the item at the marked line
def tgt.blame.of(named: Bool, +n: List<&2, U32>, +its: List<&2, T.BItem>, +start: Nat, +l: Nat) -> List<&2, U32>:
  match named:
    case True{}:
      n
    case False{}:
      tgt.at.line(its, start, l)

def tgt.blame(+n: List<&2, U32>, +its: List<&2, T.BItem>, +start: Nat, +l: Nat) -> List<&2, U32>:
  tgt.blame.of(tgt.mem(n, tgt.names(its)), n, its, start, l)

# The loop -------------------------------------------------------------------

def tgt.drop.one.put(hit: Bool, +it: T.BItem, +why: List<&2, U32>, st: TgtSt) -> TgtSt:
  match hit st:
    case False{} TgtSt{its, ds}:
      TgtSt{it <> its, ds}
    case True{} TgtSt{its, ds}:
      TgtSt{its, TgtDrop{tgt.name(it), tgt.agda(it), why, False{}} <> ds}

def tgt.drop.one(+name: List<&2, U32>, +why: List<&2, U32>, its: List<&2, T.BItem>, ds: List<&2, TgtDrop>) -> TgtSt:
  match its:
    case Nil{}:
      TgtSt{Nil{}, ds}
    case +it <> t:
      tgt.drop.one.put(S.eq(tgt.name(it), name), it, why, tgt.drop.one(name, why, t, ds))

def tgt.all.dropped(+why: List<&2, U32>, its: List<&2, T.BItem>, ds: List<&2, TgtDrop>) -> TgtSt:
  match its:
    case Nil{}:
      TgtSt{Nil{}, ds}
    case +it <> t:
      tgt.all.dropped(why, t, TgtDrop{tgt.name(it), tgt.agda(it), why, False{}} <> ds)

def tgt.after.fail.of(none: Bool, +blame: List<&2, U32>, +why: List<&2, U32>, its: List<&2, T.BItem>, ds: List<&2, TgtDrop>) -> TgtSt:
  match none:
    case True{}:
      tgt.all.dropped(List.append(&2, U32, S.b("unlocated: "), why), its, ds)
    case False{}:
      tgt.deps(List.append(&2, U32, S.b("uses "), blame), tgt.drop.one(blame, why, its, ds))

# one failure: its item and the items using it dropped; an error that
# names no kept item and marks no line of one drops the whole module
def tgt.after.fail(+blame: List<&2, U32>, +why: List<&2, U32>, st: TgtSt) -> TgtSt:
  match st:
    case TgtSt{its, ds}:
      tgt.after.fail.of(S.eq(blame, Nil{}), blame, why, its, ds)

# The file a module's kept items make (written for each check).
def tgt.file(+head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>, its: List<&2, T.BItem>) -> List<&2, U32>:
  P.tpr.file(T.BFile{head, ims, its})

# the header's lines: its comment lines, `import Base` and the imports
def tgt.start(+head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>) -> Nat:
  Nat.add(List.length(&2, List<&2, U32>, head), 1n+List.length(&2, T.BImport, ims))

# Repairs: a failure whose message names a binder of the blamed def (x
# consumed more than once, -x expected where x is used live) raises that
# binder (ToBend/Copy.bend) and checks again; only when nothing can be
# raised is the def dropped.
def tgt.cut.at(xs: List<&2, U32>, +stop: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case Nil{} _:
      Nil{}
    case h <> t True{}:
      Nil{}
    case h <> +t False{}:
      h <> tgt.cut.at(t, stop, S.prefix(t, stop))

def tgt.cut(+xs: List<&2, U32>, +stop: List<&2, U32>) -> List<&2, U32>:
  tgt.cut.at(xs, stop, S.prefix(xs, stop))

# the binder an "expected : V observed : ..." message names (its - aside)
def tgt.var.of(+w: List<&2, U32>) -> List<&2, U32>:
  S.strip(tgt.cut(S.strip(w, S.b("expected : ")), S.b(" observed")), S.b("-"))

# 1: a use twice, 2: an erased binder used live, 3: a Type where Data is
# expected (the marked span a type parameter), 0: none of these
def tgt.repair.kind(+w: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.infix(w, S.b("(consumed more than once)")), 1n, Bool.pick(Nat, Bool.and(S.prefix(w, S.b("expected : -")), S.infix(w, S.b("observed : "))), 2n, Bool.pick(Nat, Bool.and(S.prefix(w, S.b("expected : Data")), Bool.or(S.infix(w, S.b("observed : Type")), S.infix(w, S.b("observed : Kind(")))), 3n, Bool.pick(Nat, Bool.and(S.prefix(w, S.b("expected : ")), S.infix(w, S.b("&2"))), 4n, 0n))))

def tgt.find(its: List<&2, T.BItem>, +n: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match its:
    case Nil{}:
      None{}
    case +it <> t:
      Bool.pick(Maybe<&2, T.BItem>, S.eq(tgt.name(it), n), Some{it}, tgt.find(t, n))

def tgt.replace(its: List<&2, T.BItem>, +n: List<&2, U32>, +new: T.BItem) -> List<&2, T.BItem>:
  match its:
    case Nil{}:
      Nil{}
    case +it <> t:
      Bool.pick(T.BItem, S.eq(tgt.name(it), n), new, it) <> tgt.replace(t, n, new)

def tgt.raise.of(m: Maybe<&2, T.BItem>, +v: List<&2, U32>, +copy: Bool) -> Maybe<&2, T.BItem>:
  match m:
    case Some{it}:
      Q.tcp.raise(it, v, copy)
    case None{}:
      None{}

def tgt.data.of(m: Maybe<&2, T.BItem>, +v: List<&2, U32>, +why: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match m:
    case Some{+it}:
      Q.tcp.data.or.q(Q.tcp.data.raise(it, v), it, why)
    case None{}:
      None{}

# a caller passing its own quantity where &2 is expected: specialised too
def tgt.q.of(m: Maybe<&2, T.BItem>, +why: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match m:
    case Some{+it}:
      Q.tcp.q.spec(it, why)
    case None{}:
      None{}

def tgt.repaired(r: Maybe<&2, T.BItem>, +blame: List<&2, U32>, +why: List<&2, U32>, +its: List<&2, T.BItem>, ds: List<&2, TgtDrop>) -> TgtSt:
  match r:
    case Some{new}:
      TgtSt{tgt.replace(its, blame, new), ds}
    case None{}:
      tgt.after.fail(blame, why, TgtSt{its, ds})

# a failure: repaired when its message names a binder the blamed def can
# raise (or its carets mark a type parameter to declare Data), else the def
# and its dependents dropped
def tgt.on.fail(+k: Nat, +blame: List<&2, U32>, +why: List<&2, U32>, +sp: List<&2, U32>, +its: List<&2, T.BItem>, ds: List<&2, TgtDrop>) -> TgtSt:
  match k:
    case 0n:
      tgt.after.fail(blame, why, TgtSt{its, ds})
    case 3n:
      tgt.repaired(tgt.data.of(tgt.find(its, blame), S.strip(S.strip(sp, S.b("~")), S.b("-")), why), blame, why, its, ds)
    case 4n:
      tgt.repaired(tgt.q.of(tgt.find(its, blame), why), blame, why, its, ds)
    case 1n+p:
      tgt.repaired(tgt.raise.of(tgt.find(its, blame), tgt.var.of(why), Nat.is_eq(k, 1n)), blame, why, its, ds)

type TgtRun is Data:
  TgtRun{st: TgtSt, done: Bool, checks: Nat}

def tgt.empty(st: TgtSt) -> Bool:
  match st:
    case TgtSt{Nil{}, ds}:
      True{}
    case _:
      False{}

def tgt.round.of(v: TgtV, +head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>, +checks: Nat, st: TgtSt) -> TgtRun:
  match v st:
    case TgPass{} st:
      TgtRun{st, True{}, checks}
    case TgFail{+n, +l, +w, sp} TgtSt{+its, ds}:
      TgtRun{tgt.on.fail(tgt.repair.kind(w), tgt.blame(n, its, tgt.start(head, ims), l), w, sp, its, ds), False{}, checks}

# one check: the file written, bend run on it, its verdict applied
def tgt.round(+bend: String, +secs: U32, +path: String, +head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>, +checks: Nat, st: TgtSt) -> IO(TgtRun):
  match st:
    case TgtSt{+its, ds}:
      do IO<TgtRun>:
        S.write(path, tgt.file(head, ims, its))
        +o : S.Out <- S.run(S.parent(path), Nil{}, secs, bend, [S.base(path), "--check-only"], Nil{})
        return tgt.round.of(tgt.verdict(S.Out.text(o)), head, ims, 1n+checks, TgtSt{its, ds})

def tgt.loop(fuel: Nat, +bend: String, +secs: U32, +path: String, +head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>, r: TgtRun) -> IO(TgtRun):
  match fuel r:
    case 1n+p TgtRun{st, False{}, +checks}:
      IO.bind(TgtRun, TgtRun, tgt.round(bend, secs, path, head, ims, checks, st), tgt.loop(p, bend, secs, path, head, ims))
    case _ r:
      IO.pure(TgtRun, r)

def tgt.final(+path: String, +head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>, r: TgtRun) -> IO(TgtRun):
  match r:
    case TgtRun{TgtSt{+its, ds}, d, c}:
      do IO<TgtRun>:
        S.write(path, tgt.file(head, ims, its))
        return TgtRun{TgtSt{its, ds}, d, c}

def tgt.has.got(r: Map<&2, Bool> & Bool) -> Bool:
  (m, b) = r
  b

def tgt.al.got(r: Map<&2, List<&2, U32>> & Bool) -> Bool:
  (m, b) = r
  b

# Names from other modules: an item that uses one its module dropped (an
# alias-qualified name not among the kept ones) is dropped before any
# check, naming it.
def tgt.head.part(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case h <> t:
      h
    case Nil{}:
      Nil{}

# the name after its alias (Alias.rest)
def tgt.after.alias(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case h <> t:
      S.join(t, 46)
    case Nil{}:
      Nil{}

def tgt.ral.got(r: Map<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, U32>:
  (m, x) = r
  x

# the first name of refs that is another module's (its first part an
# alias) and not kept there; empty when there is none
def tgt.missing(rs: List<&2, List<&2, U32>>, +kept: Map<&2, Bool>, +ral: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      Bool.pick(List<&2, U32>, Bool.and(tgt.al.got(Map.has(&2, List<&2, U32>, ral, S.str(tgt.head.part(S.split(r, 46))))), Bool.not(tgt.has.got(Map.has(&2, Bool, kept, S.str(r))))), r, tgt.missing(t, kept, ral))

# the reason of a drop for a name another module dropped: the name as that
# module writes it, and the module (the report follows it there)
def tgt.ext.why(+miss: List<&2, U32>, +ral: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  List.append(&2, U32, S.b("uses "), List.append(&2, U32, tgt.after.alias(S.split(miss, 46)), List.append(&2, U32, S.b(" in "), List.append(&2, U32, tgt.ral.got(Map.get(List<&2, U32>, Nil{}, ral, S.str(tgt.head.part(S.split(miss, 46))))), S.b(", which dropped it")))))

def tgt.ext.put(none: Bool, +miss: List<&2, U32>, +ral: Map<&2, List<&2, U32>>, +it: T.BItem, st: TgtSt) -> TgtSt:
  match none st:
    case True{} TgtSt{its, ds}:
      TgtSt{it <> its, ds}
    case False{} TgtSt{its, ds}:
      TgtSt{its, TgtDrop{tgt.name(it), tgt.agda(it), tgt.ext.why(miss, ral), True{}} <> ds}

def tgt.ext.one(+miss: List<&2, U32>, +ral: Map<&2, List<&2, U32>>, +it: T.BItem, st: TgtSt) -> TgtSt:
  tgt.ext.put(S.eq(miss, Nil{}), miss, ral, it, st)

def tgt.ext(its: List<&2, T.BItem>, +kept: Map<&2, Bool>, +ral: Map<&2, List<&2, U32>>) -> TgtSt:
  match its:
    case Nil{}:
      TgtSt{Nil{}, Nil{}}
    case +it <> t:
      tgt.ext.one(tgt.missing(tgt.refs(it), kept, ral), ral, it, tgt.ext(t, kept, ral))

def tgt.merge(a: TgtSt, ds: List<&2, TgtDrop>) -> TgtSt:
  match a:
    case TgtSt{its, d0}:
      TgtSt{its, List.append(&2, TgtDrop, d0, ds)}

def tgt.gate.go(+bend: String, +secs: U32, +path: String, +head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>, +its: List<&2, T.BItem>, +st: TgtSt) -> IO(TgtRun):
  do IO<TgtRun>:
    r : TgtRun <- tgt.loop(Nat.add(8n, Nat.mul(4n, List.length(&2, T.BItem, its))), bend, secs, path, head, ims, TgtRun{st, tgt.empty(st), 0n})
    tgt.final(path, head, ims, r)


# A module through the gate: its file at path holds only the items that
# check (with the header and imports given); the answer has the kept
# items, the drops and the number of checks run.  pre: the items left
# after tgt.ext, and its drops.
def tgt.gate(+bend: String, +secs: U32, +path: String, +head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>, pre: TgtSt) -> IO(TgtRun):
  match pre:
    case TgtSt{+its, d0}:
      tgt.gate.go(bend, secs, path, head, ims, its, tgt.deps(S.b("uses a dropped item"), tgt.merge(tgt.gapless(its), d0)))