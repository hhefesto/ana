import Base
import ../Sys.bend as S
import ./Ast.bend as T

# Order: a module's items so that every def comes after what it uses
# (Bend checks a def only against those above it; types may name each other
# in any order, but a type's field may call a def, so types are ordered the
# same way).  A depth-first walk from each item in turn writes an item
# after the items its terms name; an item already written is not written
# again.  A cycle (mutual recursion, which Bend refuses) is broken where the
# walk meets it, and the gate then reports the def that came too early.
# Every def is prefixed `tor.`.

def tor.name(it: T.BItem) -> List<&2, U32>:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      n
    case T.BiType{n, ps, d, cs, doc}:
      n
    case T.BiComment{doc}:
      Nil{}

# the names an item's terms mention
def tor.refs(it: T.BItem) -> List<&2, List<&2, U32>>:
  T.tba.item.fold(~T.tba.refs, it, Nil{})

# A frame of the walk: an item to visit, or one whose uses are written.
type TorFr is Data:
  TorFr{n: List<&2, U32>, done: Bool}

type TorSt is Data:
  TorSt{stack: List<&2, TorFr>, seen: Map<&2, Bool>, out: List<&2, T.BItem>}

def tor.has.got(r: Map<&2, Bool> & Bool) -> Bool:
  (m, b) = r
  b

def tor.has(+seen: Map<&2, Bool>, +n: List<&2, U32>) -> Bool:
  tor.has.got(Map.has(&2, Bool, seen, S.str(n)))

def tor.item.got(r: Map<&2, T.BItem> & T.BItem) -> T.BItem:
  (m, it) = r
  it

def tor.item(+items: Map<&2, T.BItem>, +n: List<&2, U32>) -> T.BItem:
  tor.item.got(Map.get(T.BItem, T.BiComment{Nil{}}, items, S.str(n)))

def tor.known.got(r: Map<&2, T.BItem> & Bool) -> Bool:
  (m, b) = r
  b

def tor.known(+items: Map<&2, T.BItem>, +n: List<&2, U32>) -> Bool:
  tor.known.got(Map.has(&2, T.BItem, items, S.str(n)))

def tor.frame.put(k: Bool, n: List<&2, U32>, rest: List<&2, TorFr>) -> List<&2, TorFr>:
  match k:
    case True{}:
      TorFr{n, False{}} <> rest
    case False{}:
      rest

# frames for the names that are items of this module
def tor.frames(ns: List<&2, List<&2, U32>>, +items: Map<&2, T.BItem>, rest: List<&2, TorFr>) -> List<&2, TorFr>:
  match ns:
    case Nil{}:
      rest
    case +n <> t:
      tor.frame.put(tor.known(items, n), n, tor.frames(t, items, rest))

def tor.visit(seen: Bool, +n: List<&2, U32>, rest: List<&2, TorFr>, sn: Map<&2, Bool>, out: List<&2, T.BItem>, +items: Map<&2, T.BItem>) -> TorSt:
  match seen:
    case True{}:
      TorSt{rest, sn, out}
    case False{}:
      TorSt{tor.frames(tor.refs(tor.item(items, n)), items, TorFr{n, True{}} <> rest), Map.set(&2, Bool, sn, S.str(n), True{}), out}

def tor.walk(fuel: Nat, s: TorSt, +items: Map<&2, T.BItem>) -> TorSt:
  match fuel s:
    case 1n+p TorSt{TorFr{+n, True{}} <> rest, sn, out}:
      tor.walk(p, TorSt{rest, sn, tor.item(items, n) <> out}, items)
    case 1n+p TorSt{TorFr{+n, False{}} <> rest, +sn, out}:
      tor.walk(p, tor.visit(tor.has(sn, n), n, rest, sn, out, items), items)
    case _ s:
      s

def tor.map(its: List<&2, T.BItem>, m: Map<&2, T.BItem>) -> Map<&2, T.BItem>:
  match its:
    case Nil{}:
      m
    case +it <> t:
      tor.map(t, Map.set(&2, T.BItem, m, S.str(tor.name(it)), it))

def tor.names(its: List<&2, T.BItem>) -> List<&2, List<&2, U32>>:
  match its:
    case Nil{}:
      Nil{}
    case it <> t:
      tor.name(it) <> tor.names(t)

def tor.comments(its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  match its:
    case Nil{}:
      Nil{}
    case T.BiComment{doc} <> t:
      T.BiComment{doc} <> tor.comments(t)
    case it <> t:
      tor.comments(t)

def tor.out(s: TorSt) -> List<&2, T.BItem>:
  match s:
    case TorSt{st, sn, out}:
      List.reverse(&2, T.BItem, out)

# the items in an order Bend accepts (the comments, which name nothing, first)
def tor.order(+its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  List.append(&2, T.BItem, tor.comments(its), tor.out(tor.walk(100000000n, TorSt{tor.frames(tor.names(its), tor.map(its, Map.new(&2, T.BItem)), Nil{}), Map.new(&2, Bool), Nil{}}, tor.map(its, Map.new(&2, T.BItem)))))
