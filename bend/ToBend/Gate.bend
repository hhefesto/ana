import Base
import ../Sys.bend as S
import ./Ast.bend as T
import ./Print.bend as P

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
  TgFail{name: List<&2, U32>, line: Nat, why: List<&2, U32>}

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
  T.tba.item.fold(~T.tba.refs, it, Nil{})

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

def tgt.dep.put(hit: Bool, +it: T.BItem, +why: List<&2, U32>, r: TgtDep) -> TgtDep:
  match hit r:
    case False{} TgtDep{TgtSt{its, ds}, c}:
      TgtDep{TgtSt{it <> its, ds}, c}
    case True{} TgtDep{TgtSt{its, ds}, c}:
      TgtDep{TgtSt{its, TgtDrop{tgt.name(it), tgt.agda(it), why, True{}} <> ds}, True{}}

def tgt.dep.round(its: List<&2, T.BItem>, +dead: List<&2, List<&2, U32>>, +why: List<&2, U32>, ds: List<&2, TgtDrop>) -> TgtDep:
  match its:
    case Nil{}:
      TgtDep{TgtSt{Nil{}, ds}, False{}}
    case +it <> t:
      tgt.dep.put(tgt.any.mem(tgt.refs(it), dead), it, why, tgt.dep.round(t, dead, why, ds))

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

def tgt.digits(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case +h <> t:
      Bool.pick(Nat, Bool.and(U32.is_ge(h, 48), U32.is_le(h, 57)), tgt.digits(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48)))), acc)
    case Nil{}:
      acc

# the line a source excerpt marks with `NNN>|`, 0 when none
def tgt.marked(ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      Bool.pick(Nat, S.infix(l, S.b(">|")), tgt.digits(tgt.trim(l), 0n), tgt.marked(t))

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

def tgt.verdict.of(pass: Bool, +ls: List<&2, List<&2, U32>>) -> TgtV:
  match pass:
    case True{}:
      TgPass{}
    case False{}:
      TgFail{tgt.location(ls), tgt.marked(ls), tgt.why(ls)}

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
    case TgFail{+n, +l, +w} TgtSt{+its, ds}:
      TgtRun{tgt.after.fail(tgt.blame(n, its, tgt.start(head, ims), l), w, TgtSt{its, ds}), False{}, checks}

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

# A module through the gate: its file at path holds only the items that
# check (with the header and imports given); the answer has the kept
# items, the drops and the number of checks run.
def tgt.gate(+bend: String, +secs: U32, +path: String, +head: List<&2, List<&2, U32>>, +ims: List<&2, T.BImport>, +its: List<&2, T.BItem>) -> IO(TgtRun):
  do IO<TgtRun>:
    +st : TgtSt = tgt.deps(S.b("uses an item with a gap"), tgt.gapless(its))
    r : TgtRun <- tgt.loop(1n+List.length(&2, T.BItem, its), bend, secs, path, head, ims, TgtRun{st, tgt.empty(st), 0n})
    tgt.final(path, head, ims, r)
