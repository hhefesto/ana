import Base

# Moving values between the host and the store (Array.set / Array.get: on
# a GPU build these touch managed memory, so the regions they touch sit
# apart from the device's working data; see Layout.bend).

def put(xs: List<&2, F32>, s: Array<F32>, +i: U32) -> Array<F32>:
  match xs:
    case Nil{}:
      s
    case x <> t:
      put(t, Array.set(F32, s, i, x), U32.inc(i))

def put.u32(xs: List<&2, U32>, s: Array<F32>, +i: U32) -> Array<F32>:
  match xs:
    case Nil{}:
      s
    case x <> t:
      put.u32(t, Array.set(F32, s, i, U32.to_f32(x)), U32.inc(i))

def get1(s: Array<F32>, +i: U32) -> Array<F32> & F32:
  Array.get(F32, s, i)

def get.cons(acc: List<&2, F32>, r: Array<F32> & F32) -> Array<F32> & List<&2, F32>:
  (s, x) = r
  (s, x <> acc)

def get.step(+i: U32, r: Array<F32> & List<&2, F32>) -> Array<F32> & List<&2, F32>:
  (s, acc) = r
  get.cons(acc, Array.get(F32, s, i))

# n values from index i, newest last
def get.go(n: Nat, +i: U32, r: Array<F32> & List<&2, F32>) -> Array<F32> & List<&2, F32>:
  match n:
    case 0n:
      r
    case 1n+p:
      get.go(p, U32.inc(i), get.step(i, r))

def get.fin(r: Array<F32> & List<&2, F32>) -> Array<F32> & List<&2, F32>:
  (s, acc) = r
  (s, List.reverse(&2, F32, acc))

def get(+n: Nat, s: Array<F32>, +i: U32) -> Array<F32> & List<&2, F32>:
  get.fin(get.go(n, i, (s, Nil{})))

def ones(n: Nat) -> List<&2, F32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      1.0 <> ones(p)

def pad(+n: Nat, xs: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, List.append(&2, U32, xs, List.replicate(U32, n, 0)), n)

def padf(+n: Nat, xs: List<&2, F32>) -> List<&2, F32>:
  List.take(&2, F32, List.append(&2, F32, xs, List.replicate(F32, n, 0.0)), n)

# a window of k tokens makes k - 1 predictions: its inputs, targets and
# weights 1, then padding (token 0, weight 0) to t positions
def put.windows(ws: List<&2, List<&2, U32>>, s: Array<F32>, +tin: U32, +ttg: U32, +tw: U32, +t: U32) -> Array<F32>:
  match ws:
    case Nil{}:
      s
    case +w <> rest:
      +k = Nat.sub(List.length(&2, U32, w), 1n)
      +tn = U32.to_nat(t)
      put.windows(rest,
        put(padf(tn, ones(k)), put.u32(pad(tn, List.drop(&2, U32, w, 1n)), put.u32(pad(tn, List.take(&2, U32, w, k)), s, tin), ttg), tw),
        U32.add(tin, t), U32.add(ttg, t), U32.add(tw, t), t)
