import Base

# IMap: a map from U32 keys, a binary trie on the key's bits from the lowest
# (a leaf holds a whole key; a node splits on the next bit). The memory
# keeps its nodes' texts in one, keyed by slot (Tree.bend tr.slot), and its
# running jobs in another.
#
# Every def is prefixed `im.` (a program's defs share one namespace).
#
# ana's copy of mugen's bend/IMap.bend (github:hhefesto/mugen c3275ba), for
# Mugen/Diff.bend.

type im.M<-V: Data> is Data:
  im.E{}
  im.L{k: U32, v: V}
  im.N{z: im.M<V>, o: im.M<V>}

def im.new(-V: Data) -> im.M<V>:
  im.E{}

def im.low(+k: U32) -> Bool:
  U32.is_ne(U32.and(k, 1), 0)

# rest: the key's bits not walked yet; b: the lowest of them
def im.get.go(-V: Data, m: im.M<V>, +b: Bool, +rest: U32, +key: U32) -> Maybe<&2, V>:
  match m b:
    case im.E{} _:
      None{}
    case im.L{+k, v} _:
      Bool.pick(Maybe<&2, V>, U32.is_eq(k, key), Some{v}, None{})
    case im.N{z, o} True{}:
      im.get.go(V, o, im.low(U32.shr(rest)), U32.shr(rest), key)
    case im.N{z, o} False{}:
      im.get.go(V, z, im.low(U32.shr(rest)), U32.shr(rest), key)

def im.get(-V: Data, m: im.M<V>, +key: U32) -> Maybe<&2, V>:
  im.get.go(V, m, im.low(key), key, key)

def im.has(-V: Data, m: im.M<V>, +key: U32) -> Bool:
  Maybe.is_some(&2, V, im.get(V, m, key))

# Two leaves where one was: nodes down the bits they share, then a fork.
# ka, kb: the two keys' bits from here; ba, bb: the lowest of them.
def im.split(-V: Data, fuel: Nat, +ba: Bool, +bb: Bool, +ka: U32, +k: U32, w: V, +kb: U32, +key: U32, v: V) -> im.M<V>:
  match fuel ba bb:
    case 0n _ _:
      im.L{key, v}
    case 1n+f True{} True{}:
      im.N{im.E{}, im.split(V, f, im.low(U32.shr(ka)), im.low(U32.shr(kb)), U32.shr(ka), k, w, U32.shr(kb), key, v)}
    case 1n+f False{} False{}:
      im.N{im.split(V, f, im.low(U32.shr(ka)), im.low(U32.shr(kb)), U32.shr(ka), k, w, U32.shr(kb), key, v), im.E{}}
    case 1n+f True{} False{}:
      im.N{im.L{key, v}, im.L{k, w}}
    case 1n+f False{} True{}:
      im.N{im.L{k, w}, im.L{key, v}}

def im.leaf(-V: Data, same: Bool, +d: Nat, +k: U32, w: V, +rest: U32, +key: U32, v: V) -> im.M<V>:
  match same:
    case True{}:
      im.L{key, v}
    case False{}:
      +ka = U32.shrn(k, d)
      im.split(V, 33n, im.low(ka), im.low(rest), ka, k, w, rest, key, v)

# d: the bits walked (rest is key >> d)
def im.set.go(-V: Data, m: im.M<V>, +b: Bool, +d: Nat, +rest: U32, +key: U32, v: V) -> im.M<V>:
  match m b:
    case im.E{} _:
      im.L{key, v}
    case im.L{+k, w} _:
      im.leaf(V, U32.is_eq(k, key), d, k, w, rest, key, v)
    case im.N{z, o} True{}:
      im.N{z, im.set.go(V, o, im.low(U32.shr(rest)), 1n+d, U32.shr(rest), key, v)}
    case im.N{z, o} False{}:
      im.N{im.set.go(V, z, im.low(U32.shr(rest)), 1n+d, U32.shr(rest), key, v), o}

# the map with key bound to v
def im.set(-V: Data, m: im.M<V>, +key: U32, v: V) -> im.M<V>:
  im.set.go(V, m, im.low(key), 0n, key, key, v)

def im.del.go(-V: Data, m: im.M<V>, +b: Bool, +rest: U32, +key: U32) -> im.M<V>:
  match m b:
    case im.E{} _:
      im.E{}
    case im.L{+k, +w} _:
      Bool.pick(im.M<V>, U32.is_eq(k, key), im.E{}, im.L{k, w})
    case im.N{z, o} True{}:
      im.N{z, im.del.go(V, o, im.low(U32.shr(rest)), U32.shr(rest), key)}
    case im.N{z, o} False{}:
      im.N{im.del.go(V, z, im.low(U32.shr(rest)), U32.shr(rest), key), o}

# the map without key
def im.del(-V: Data, m: im.M<V>, +key: U32) -> im.M<V>:
  im.del.go(V, m, im.low(key), key, key)

def im.size(-V: Data, m: im.M<V>) -> Nat:
  match m:
    case im.E{}:
      0n
    case im.L{k, v}:
      1n
    case im.N{z, o}:
      Nat.add(im.size(V, z), im.size(V, o))
