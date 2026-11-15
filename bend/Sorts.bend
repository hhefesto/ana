# bend-sorts DIR N: R7's change 5, the sorts with fuel (2026-11-15; docs/r7/PLAN.md; the user, 11-15: "Yes" to
# building "a sorts-with-fuel kind" before R7).  R5g and R6 could not write a merge sort or a quicksort in Bend
# (msort-bend 0/9, qsort-bend 4/9, and those 4 only by calling Base's List.sort): the corpus held few sorts written
# out, none with fuel, and no file where a sort and its helpers are written from nothing.  This writes N small
# files, each a sort written out in a nearly empty file (Base, at most one type): its helpers, then the sort, then
# the laws that check it on fixed inputs.  Bend's checker takes a self-call only when an argument read left to
# right shrinks, so a merge sort's halves and a quicksort's parts (not structurally smaller) recurse on a fuel
# argument first, and the list's length is always enough fuel.  The file v varies by its digits: the element type
# (Nat, U32, a Card by rank, a Task by priority), the order (smallest or largest first), the sort (merge sort
# splitting by turns or by halves, quicksort around the first element, insertion sort, which needs no fuel),
# whether the order is a helper, and the names and words.  bend-units cuts each file into units; the transcript's
# direct ask of the sort reads the file cut before the helpers it calls, so the session writes them and the sort
# (form 2's helper and scratch kinds).  The laws' expected lists come from a reference sort here, and each file
# is checked as the corpus's units are.  Writes DIR/src/sorts/fuel/*.bend and DIR/files-hi.nul (NUL-framed pairs,
# own:PATH and the text, as bend-transcripts' sources stage writes them).

import Base
import ./Sys.bend as S
import ./Units.bend as U

def so.cat(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  U.concat(xs)

def so.n(+n: Nat) -> List<&2, U32>:
  U.b(Nat.show(n))

# the i-th of xs, round
def so.pick(+xs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  U.nth(xs, Nat.mod(i, List.length(&2, List<&2, U32>, xs)))

# v's digits
def so.ty(+v: Nat) -> Nat:
  Nat.mod(v, 4n)

def so.desc(+v: Nat) -> Bool:
  Nat.is_eq(Nat.mod(Nat.div(v, 4n), 2n), 1n)

def so.alg(+v: Nat) -> Nat:
  Nat.mod(Nat.div(v, 8n), 4n)

def so.hc(+v: Nat) -> Bool:
  Bool.or(Nat.is_lt(1n, so.ty(v)), Nat.is_eq(Nat.mod(Nat.div(v, 32n), 2n), 1n))

def so.w(+v: Nat) -> Nat:
  Nat.div(v, 64n)

# The element types ---------------------------------------------------------------------------

def so.T(+v: Nat) -> List<&2, U32>:
  so.pick([U.b("Nat"), U.b("U32"), U.b("Card"), U.b("Task")], so.ty(v))

def so.noun(+v: Nat) -> List<&2, U32>:
  so.pick([U.b("natural numbers"), U.b("numbers"), U.b("cards"), U.b("tasks")], so.ty(v))

def so.ord(+v: Nat) -> List<&2, U32>:
  +i = Nat.add(Nat.mul(so.ty(v), 2n), Bool.pick(Nat, so.desc(v), 1n, 0n))
  so.pick([U.b("smallest first"), U.b("largest first"), U.b("smallest first"), U.b("largest first"),
    U.b("lowest rank first"), U.b("highest rank first"), U.b("lowest priority first"), U.b("highest priority first")], i)

def so.tdecl(+v: Nat) -> List<&2, U32>:
  so.pick([Nil{}, Nil{}, U.b("# A playing card: its rank, then its suit.\ntype Card is Data:\n  Card{rank: Nat, suit: U32}\n\n"),
    U.b("# A task: its priority, then its id.\ntype Task is Data:\n  Task{prio: U32, id: Nat}\n\n")], so.ty(v))

# an element of key k as a literal (a Card's suit and a Task's id follow from the key)
def so.lit(+v: Nat, +k: Nat) -> List<&2, U32>:
  so.pick([so.cat([so.n(k), U.b("n")]), so.n(k), so.cat([U.b("Card{"), so.n(k), U.b("n, "), so.n(Nat.mod(Nat.add(Nat.mul(k, 3n), 1n), 4n)), U.b("}")]),
    so.cat([U.b("Task{"), so.n(k), U.b(", "), so.n(Nat.add(k, 100n)), U.b("n}")])], so.ty(v))

# The order ------------------------------------------------------------------------------------

def so.cmpname(+v: Nat) -> List<&2, U32>:
  so.pick([U.b("in_order"), U.b("goes_first"), U.b("precedes"), U.b("le")], Nat.add(so.w(v), v))

# whether a goes before b, as an expression: the helper's call, or the comparison itself
def so.le(+v: Nat, +a: List<&2, U32>, +b: List<&2, U32>) -> List<&2, U32>:
  +x = Bool.pick(List<&2, U32>, so.desc(v), b, a)
  +y = Bool.pick(List<&2, U32>, so.desc(v), a, b)
  +prim = so.cat([so.pick([U.b("Nat"), U.b("U32")], so.ty(v)), U.b(".is_le("), x, U.b(", "), y, U.b(")")])
  Bool.pick(List<&2, U32>, so.hc(v), so.cat([so.cmpname(v), U.b("("), a, U.b(", "), b, U.b(")")]), prim)

def so.cmp.body(+v: Nat) -> List<&2, U32>:
  +x = Bool.pick(List<&2, U32>, so.desc(v), U.b("b"), U.b("a"))
  +y = Bool.pick(List<&2, U32>, so.desc(v), U.b("a"), U.b("b"))
  so.pick([so.cat([U.b("  Nat.is_le("), x, U.b(", "), y, U.b(")\n")]), so.cat([U.b("  U32.is_le("), x, U.b(", "), y, U.b(")\n")]),
    so.cat([U.b("  match a b:\n    case Card{ra, sa} Card{rb, sb}:\n      Nat.is_le(r"), x, U.b(", r"), y, U.b(")\n")]),
    so.cat([U.b("  match a b:\n    case Task{pa, ia} Task{pb, ib}:\n      U32.is_le(p"), x, U.b(", p"), y, U.b(")\n")])], so.ty(v))

def so.cmp(+v: Nat) -> List<&2, U32>:
  +d = so.cat([U.b("# whether a goes before b: "), so.ord(v), U.b("\ndef "), so.cmpname(v), U.b("(+a: "), so.T(v), U.b(", +b: "), so.T(v), U.b(") -> Bool:\n"), so.cmp.body(v), U.b("\n")])
  Bool.pick(List<&2, U32>, so.hc(v), d, Nil{})

# The sorts ------------------------------------------------------------------------------------

def so.L(+v: Nat) -> List<&2, U32>:
  so.cat([U.b("List<&2, "), so.T(v), U.b(">")])

def so.name(+v: Nat) -> List<&2, U32>:
  +i = Nat.add(so.w(v), Nat.div(v, 3n))
  so.pick([so.pick([U.b("msort"), U.b("merge_sort"), U.b("mergesort"), U.b("sort_merge")], i), so.pick([U.b("msort"), U.b("merge_sort"), U.b("halving_sort"), U.b("sort")], i),
    so.pick([U.b("qsort"), U.b("quicksort"), U.b("quick_sort"), U.b("sort")], i), so.pick([U.b("isort"), U.b("insertion_sort"), U.b("insort"), U.b("sort")], i)], so.alg(v))

def so.core(+v: Nat) -> List<&2, U32>:
  so.cat([so.name(v), Bool.pick(List<&2, U32>, Nat.is_eq(Nat.mod(so.w(v), 2n), 0n), U.b(".go"), U.b("_fuel"))])

def so.merge.n(+v: Nat) -> List<&2, U32>:
  so.pick([U.b("merge"), U.b("merge_sorted"), U.b("merge2")], Nat.add(so.w(v), v))

def so.alt.n(+v: Nat) -> List<&2, U32>:
  so.pick([U.b("alt"), U.b("every_other"), U.b("deal")], Nat.add(so.w(v), Nat.div(v, 5n)))

def so.lr(+v: Nat, +k: Nat) -> List<&2, U32>:
  +i = Nat.add(Nat.mul(Nat.mod(Nat.add(so.w(v), v), 3n), 2n), k)
  so.pick([U.b("left"), U.b("right"), U.b("front"), U.b("back"), U.b("head_part"), U.b("rest_part")], i)

def so.ins.n(+v: Nat) -> List<&2, U32>:
  so.pick([U.b("insert"), U.b("insert_sorted"), U.b("place")], Nat.add(so.w(v), v))

def so.merge(+v: Nat) -> List<&2, U32>:
  +m = so.merge.n(v)
  so.cat([U.b("# the two lists, each "), so.ord(v), U.b(", as one list "), so.ord(v), U.b("\ndef "), m, U.b("(xs: "), so.L(v), U.b(", ys: "), so.L(v), U.b(") -> "), so.L(v), U.b(":\n"),
    U.b("  match xs ys:\n    case Nil{} _:\n      ys\n    case +x <> +xt Nil{}:\n      x <> xt\n    case +x <> +xt +y <> +yt:\n"),
    U.b("      Bool.pick("), so.L(v), U.b(", "), so.le(v, U.b("x"), U.b("y")), U.b(", x <> "), m, U.b("(xt, y <> yt), y <> "), m, U.b("(x <> xt, yt))\n\n")])

def so.alt(+v: Nat) -> List<&2, U32>:
  +a = so.alt.n(v)
  so.cat([U.b("# every other element of xs: from the first when keep, else from the second\ndef "), a, U.b("(xs: "), so.L(v), U.b(", keep: Bool) -> "), so.L(v), U.b(":\n"),
    U.b("  match xs:\n    case Nil{}:\n      Nil{}\n    case +x <> +t:\n      Bool.pick("), so.L(v), U.b(", keep, x <> "), a, U.b("(t, False{}), "), a, U.b("(t, True{}))\n\n")])

def so.msort.turns(+v: Nat) -> List<&2, U32>:
  +c = so.core(v)
  +a = so.alt.n(v)
  so.cat([U.b("# merge sort, "), so.ord(v), U.b(": the elements dealt in turns into two lists, each sorted, then merged; each level\n# spends one fuel\ndef "),
    c, U.b("(fuel: Nat, +xs: "), so.L(v), U.b(") -> "), so.L(v), U.b(":\n  match fuel:\n    case 0n:\n      xs\n    case 1n++f:\n      Bool.pick("), so.L(v),
    U.b(", Nat.is_le(List.length(&2, "), so.T(v), U.b(", xs), 1n), xs, "), so.merge.n(v), U.b("("), c, U.b("(f, "), a, U.b("(xs, True{})), "), c, U.b("(f, "), a, U.b("(xs, False{}))))\n\n")])

def so.msort.halves(+v: Nat) -> List<&2, U32>:
  +c = so.core(v)
  so.cat([U.b("# merge sort, "), so.ord(v), U.b(": the two halves sorted, then merged; each level spends one fuel\ndef "),
    c, U.b("(fuel: Nat, +xs: "), so.L(v), U.b(") -> "), so.L(v), U.b(":\n  match fuel:\n    case 0n:\n      xs\n    case 1n++f:\n      +h = Nat.div(List.length(&2, "), so.T(v), U.b(", xs), 2n)\n      Bool.pick("), so.L(v),
    U.b(", Nat.is_le(List.length(&2, "), so.T(v), U.b(", xs), 1n), xs, "), so.merge.n(v), U.b("("), c, U.b("(f, List.take(&2, "), so.T(v), U.b(", xs, h)), "), c, U.b("(f, List.drop(&2, "), so.T(v), U.b(", xs, h))))\n\n")])

def so.part(+v: Nat, +k: Nat) -> List<&2, U32>:
  +n = so.lr(v, k)
  +keep = so.cat([U.b("x <> "), n, U.b("(t, p)")])
  +skip = so.cat([n, U.b("(t, p)")])
  so.cat([Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), U.b("# the elements of xs that go before p, in order\ndef "), U.b("# the elements of xs that do not go before p, in order\ndef ")),
    n, U.b("(xs: "), so.L(v), U.b(", +p: "), so.T(v), U.b(") -> "), so.L(v), U.b(":\n  match xs:\n    case Nil{}:\n      Nil{}\n    case +x <> +t:\n      Bool.pick("), so.L(v), U.b(", "),
    so.le(v, U.b("x"), U.b("p")), U.b(", "), Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), keep, skip), U.b(", "), Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), skip, keep), U.b(")\n\n")])

def so.qsort(+v: Nat) -> List<&2, U32>:
  +c = so.core(v)
  so.cat([so.part(v, 0n), so.part(v, 1n), U.b("# quicksort around the first element, "), so.ord(v), U.b("; each level spends one fuel\ndef "),
    c, U.b("(fuel: Nat, xs: "), so.L(v), U.b(") -> "), so.L(v), U.b(":\n  match fuel xs:\n    case _ Nil{}:\n      Nil{}\n    case 0n +p <> +t:\n      p <> t\n    case 1n++f +p <> +t:\n      List.append(&2, "),
    so.T(v), U.b(", "), c, U.b("(f, "), so.lr(v, 0n), U.b("(t, p)), p <> "), c, U.b("(f, "), so.lr(v, 1n), U.b("(t, p)))\n\n")])

def so.wrap(+v: Nat) -> List<&2, U32>:
  so.cat([U.b("# the list, "), so.ord(v), U.b("\ndef "), so.name(v), U.b("(+xs: "), so.L(v), U.b(") -> "), so.L(v), U.b(":\n  "), so.core(v), U.b("(List.length(&2, "), so.T(v), U.b(", xs), xs)\n\n")])

def so.isort(+v: Nat) -> List<&2, U32>:
  +i = so.ins.n(v)
  +s = so.name(v)
  so.cat([U.b("# xs ("), so.ord(v), U.b(" already) with x in its place\ndef "), i, U.b("(xs: "), so.L(v), U.b(", +x: "), so.T(v), U.b(") -> "), so.L(v), U.b(":\n  match xs:\n    case Nil{}:\n      [x]\n    case +y <> +t:\n      Bool.pick("),
    so.L(v), U.b(", "), so.le(v, U.b("x"), U.b("y")), U.b(", x <> y <> t, y <> "), i, U.b("(t, x))\n\n"),
    U.b("# insertion sort, "), so.ord(v), U.b(": each element put in its place in the rest, sorted\ndef "), s, U.b("(xs: "), so.L(v), U.b(") -> "), so.L(v), U.b(":\n  match xs:\n    case Nil{}:\n      Nil{}\n    case +x <> +t:\n      "),
    i, U.b("("), s, U.b("(t), x)\n\n")])

def so.sort(+v: Nat) -> List<&2, U32>:
  so.pick([so.cat([so.merge(v), so.alt(v), so.msort.turns(v), so.wrap(v)]), so.cat([so.merge(v), so.msort.halves(v), so.wrap(v)]), so.cat([so.qsort(v), so.wrap(v)]), so.isort(v)], so.alg(v))

# The laws: fixed inputs, their expected lists from a reference sort ---------------------------

# the keys of an example: n of them; a Card's and a Task's distinct (their order is then the only one)
def so.key(+v: Nat, +j: Nat, +i: Nat) -> Nat:
  +s = Nat.add(Nat.mul(v, 5n), Nat.mul(j, 11n))
  Bool.pick(Nat, Nat.is_lt(1n, so.ty(v)), Nat.add(Nat.mod(Nat.add(Nat.mul(i, 7n), s), 13n), 1n), Nat.mod(Nat.add(Nat.add(Nat.mul(s, 31n), Nat.mul(i, 17n)), Nat.mul(Nat.mul(i, i), 7n)), 23n))

def so.keys(n: Nat, +v: Nat, +j: Nat, +i: Nat) -> List<&2, Nat>:
  match n:
    case 0n:
      Nil{}
    case 1n++m:
      so.key(v, j, i) <> so.keys(m, v, j, 1n+i)

def so.ins(xs: List<&2, Nat>, +k: Nat) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      [k]
    case +y <> +t:
      Bool.pick(List<&2, Nat>, Nat.is_le(k, y), k <> y <> t, y <> so.ins(t, k))

def so.ref(xs: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> +t:
      so.ins(so.ref(t), x)

def so.lits(ks: List<&2, Nat>, +v: Nat) -> List<&2, List<&2, U32>>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> t:
      so.lit(v, k) <> so.lits(t, v)

# the pieces with ", " between
def so.join(xs: List<&2, List<&2, U32>>, +first: Bool) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      so.cat([Bool.pick(List<&2, U32>, first, Nil{}, U.b(", ")), x, so.join(t, False{})])

def so.list(+ks: List<&2, Nat>, +v: Nat) -> List<&2, U32>:
  so.cat([U.b("["), so.join(so.lits(ks, v), True{}), U.b("]")])

def so.law(+v: Nat, +j: Nat, +n: Nat) -> List<&2, U32>:
  +ks = so.keys(n, v, j, 0n)
  +sorted = Bool.pick(List<&2, Nat>, so.desc(v), List.reverse(&2, Nat, so.ref(ks)), so.ref(ks))
  +nm = so.cat([so.name(v), U.b(".ex"), so.n(j)])
  so.cat([U.b("law "), nm, U.b(":\n  {"), so.name(v), U.b("("), so.list(ks, v), U.b(") == "), so.list(sorted, v), U.b(" : "), so.L(v), U.b("}\n\ndef "), nm, U.b("():\n  {==}\n\n")])

def so.laws(+v: Nat) -> List<&2, U32>:
  +empty = so.cat([U.b("law "), so.name(v), U.b(".empty:\n  {"), so.name(v), U.b("(Nil{}) == Nil{} : "), so.L(v), U.b("}\n\ndef "), so.name(v), U.b(".empty():\n  {==}\n\n")])
  so.cat([so.law(v, 1n, Nat.add(3n, Nat.mod(v, 4n))), so.law(v, 2n, Nat.add(6n, Nat.mod(Nat.div(v, 3n), 3n))), Bool.pick(List<&2, U32>, Nat.is_eq(Nat.mod(v, 3n), 0n), empty, Nil{})])

# The file ---------------------------------------------------------------------------------------

def so.head(+v: Nat) -> List<&2, U32>:
  +how = so.pick([U.b("a merge sort, the elements dealt in turns"), U.b("a merge sort by halves"), U.b("a quicksort"), U.b("an insertion sort")], so.alg(v))
  +fuel = Bool.pick(List<&2, U32>, Nat.is_eq(so.alg(v), 3n), U.b(".  Its recursion is on the list itself, so it needs no fuel.\n\n"),
    U.b(".  Its parts are not structurally smaller than the list, so it recurses on fuel first: each level\n# spends one, and the list's length is always enough.\n\n"))
  Bool.pick(List<&2, U32>, Nat.is_eq(Nat.mod(Nat.add(so.w(v), v), 3n), 2n), Nil{}, so.cat([U.b("# The "), so.noun(v), U.b(", "), so.ord(v), U.b(", by "), how, fuel]))

def so.text(+v: Nat) -> List<&2, U32>:
  so.cat([U.b("import Base\n\n"), so.head(v), so.tdecl(v), so.cmp(v), so.sort(v), so.laws(v)])

def so.pad(+n: Nat) -> List<&2, U32>:
  so.cat([Bool.pick(List<&2, U32>, Nat.is_lt(n, 100n), U.b("0"), Nil{}), Bool.pick(List<&2, U32>, Nat.is_lt(n, 10n), U.b("0"), Nil{}), so.n(n)])

def so.path(+v: Nat) -> List<&2, U32>:
  so.cat([U.b("sorts/fuel/"), so.pad(v), U.b("-"), so.name(v), U.b("-"), so.pick([U.b("nat"), U.b("u32"), U.b("card"), U.b("task")], so.ty(v)), U.b(".bend")])

# IO ---------------------------------------------------------------------------------------------

def so.one(+dir: String, +v: Nat) -> IO(Unit):
  +p = so.path(v)
  +x = so.text(v)
  do IO<Unit>:
    S.write(dir ++ "/src/" ++ S.str(p), x)
    S.add(dir ++ "/files-hi.nul", so.cat([U.b("own:"), p, [0], x, [0]]))

def so.go(n: Nat, +dir: String, +v: Nat) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n++m:
      do IO<Unit>:
        so.one(dir, v)
        so.go(m, dir, 1n+v)

def so.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +dir <> +n <> Nil{}:
      do IO<Unit>:
        S.write(dir ++ "/files-hi.nul", Nil{})
        so.go(Maybe.default(&2, Nat, Nat.read(n), 0n), dir, 0n)
        IO.print("bend-sorts: " ++ n ++ " files in " ++ dir ++ "/src/sorts/fuel, " ++ dir ++ "/files-hi.nul")
    case _:
      IO.die(Unit, 2, "usage: bend-sorts DIR N")

# Laws -------------------------------------------------------------------------------------------

law so.ref.sorts:
  {so.ref([3n, 1n, 2n, 1n]) == [1n, 1n, 2n, 3n] : List<&2, Nat>}

def so.ref.sorts():
  {==}

law so.lit.card:
  {so.lit(2n, 5n) == U.b("Card{5n, 0}") : List<&2, U32>}

def so.lit.card():
  {==}

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    so.main(xs)
