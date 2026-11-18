import Base

# Lanes (2026-11-18): why a GPU may run a Seq one thread a lane.
#
# Dense/Op.bend's Seq means its slices run one after another, each slice
# over every lane at once (slice-major: GLA's state across chunks, chunk 1
# for every window, head and value, then chunk 2, ...). bulk.c's kernel k4
# gives each lane a thread that runs that lane's slices in order, lane by
# lane (lane-major). When a lane's step reads only its own state and its
# own inputs (bulk.c's ft_seq_ok checks the views for that), the two orders
# leave every lane in the same state: this file's law, `slices_lanes`.
#
# A lane is its state (an A) and the column of inputs it has left (a list
# of B); a step takes the column's head, or keeps the lane as it is once
# the column is done. The step function is used once per call, so it is a
# template argument, and the law a theorem template, checked below at two
# unrelated step functions (as Spec/Fold.bend does).

type Lane<-A: Data, -B: Data> is Data:
  Lane{s: A, c: List<&2, B>}

def stepc(~A: Data, ~B: Data, ~f: A -> B -> A, s: A, c: List<&2, B>) -> Lane<A, B>:
  match c:
    case Nil{}:
      Lane{s, Nil{}}
    case b <> t:
      Lane{f(s, b), t}

def step(~A: Data, ~B: Data, ~f: A -> B -> A, l: Lane<A, B>) -> Lane<A, B>:
  match l:
    case Lane{s, c}:
      stepc(~A, ~B, ~f, s, c)

# one slice: every lane takes one step
def slice(~A: Data, ~B: Data, ~f: A -> B -> A, ls: List<&2, Lane<A, B>>) -> List<&2, Lane<A, B>>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      step(~A, ~B, ~f, l) <> slice(~A, ~B, ~f, t)

# slice-major, a Seq's meaning: n slices, one after another
def by_slices(~A: Data, ~B: Data, ~f: A -> B -> A, n: Nat, ls: List<&2, Lane<A, B>>) -> List<&2, Lane<A, B>>:
  match n:
    case 0n:
      ls
    case 1n+p:
      by_slices(~A, ~B, ~f, p, slice(~A, ~B, ~f, ls))

# one lane, n steps
def run(~A: Data, ~B: Data, ~f: A -> B -> A, n: Nat, l: Lane<A, B>) -> Lane<A, B>:
  match n:
    case 0n:
      l
    case 1n+p:
      run(~A, ~B, ~f, p, step(~A, ~B, ~f, l))

# lane-major, bulk.c's k4: each lane its n steps, lane after lane
def by_lanes(~A: Data, ~B: Data, ~f: A -> B -> A, +n: Nat, ls: List<&2, Lane<A, B>>) -> List<&2, Lane<A, B>>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      run(~A, ~B, ~f, n, l) <> by_lanes(~A, ~B, ~f, n, t)

# no steps leave every lane as it was
def lanes_zero(~A: Data, ~B: Data, ~f: A -> B -> A, ls: List<&2, Lane<A, B>>) ->
    {by_lanes(~A, ~B, ~f, 0n, ls) == ls : List<&2, Lane<A, B>>}:
  match ls:
    case Nil{}:
      {==}
    case l <> t:
      Equal.cong(List<&2, Lane<A, B>>, List<&2, Lane<A, B>>, r => l <> r,
        by_lanes(~A, ~B, ~f, 0n, t), t, lanes_zero(~A, ~B, ~f, t))

# a slice first, then p steps a lane, is p + 1 steps a lane
def lanes_slice(~A: Data, ~B: Data, ~f: A -> B -> A, +p: Nat, ls: List<&2, Lane<A, B>>) ->
    {by_lanes(~A, ~B, ~f, p, slice(~A, ~B, ~f, ls)) == by_lanes(~A, ~B, ~f, 1n+p, ls) : List<&2, Lane<A, B>>}:
  match ls:
    case Nil{}:
      {==}
    case l <> t:
      Equal.cong(List<&2, Lane<A, B>>, List<&2, Lane<A, B>>, r => run(~A, ~B, ~f, p, step(~A, ~B, ~f, l)) <> r,
        by_lanes(~A, ~B, ~f, p, slice(~A, ~B, ~f, t)), by_lanes(~A, ~B, ~f, 1n+p, t), lanes_slice(~A, ~B, ~f, p, t))

# The law: n slices over every lane leave each lane where its own n steps do
def slices_lanes(~A: Data, ~B: Data, ~f: A -> B -> A, +n: Nat, +ls: List<&2, Lane<A, B>>) ->
    {by_slices(~A, ~B, ~f, n, ls) == by_lanes(~A, ~B, ~f, n, ls) : List<&2, Lane<A, B>>}:
  match n:
    case 0n:
      Equal.sym(List<&2, Lane<A, B>>, by_lanes(~A, ~B, ~f, 0n, ls), ls, lanes_zero(~A, ~B, ~f, ls))
    case 1n+p:
      Equal.trans(List<&2, Lane<A, B>>, by_slices(~A, ~B, ~f, p, slice(~A, ~B, ~f, ls)),
        by_lanes(~A, ~B, ~f, p, slice(~A, ~B, ~f, ls)), by_lanes(~A, ~B, ~f, 1n+p, ls),
        slices_lanes(~A, ~B, ~f, p, slice(~A, ~B, ~f, ls)), lanes_slice(~A, ~B, ~f, p, ls))

# two unrelated steps: a running sum, and a lane that keeps what it read
def plus(a: Nat, b: Nat) -> Nat:
  Nat.add(a, b)

def keep(acc: List<&2, U32>, x: U32) -> List<&2, U32>:
  x <> acc

law check.slices_lanes:
  for n: Nat
  for ls: List<&2, Lane<Nat, Nat>>
  for m: Nat
  for ks: List<&2, Lane<List<&2, U32>, U32>>
  {by_slices(~Nat, ~Nat, ~plus, n, ls) == by_lanes(~Nat, ~Nat, ~plus, n, ls) : List<&2, Lane<Nat, Nat>>}
  & {by_slices(~List<&2, U32>, ~U32, ~keep, m, ks) == by_lanes(~List<&2, U32>, ~U32, ~keep, m, ks) : List<&2, Lane<List<&2, U32>, U32>>}

def check.slices_lanes(n, ls, m, ks):
  (slices_lanes(~Nat, ~Nat, ~plus, n, ls), slices_lanes(~List<&2, U32>, ~U32, ~keep, m, ks))
