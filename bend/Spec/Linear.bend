import Base
import ./Algebra.bend as Al
import ./Autoregressive.bend as Ar

# Attention/Linear.agda: a denotational semantics for gated linear attention.
#
# The state is one dk x dv matrix, S_t = diag(gate t) S_{t-1} + key t (val t)^T,
# and the output is a query readout of it.  Diagonal transitions keep every
# transition product diagonal, so the whole development is scalar semiring
# algebra, entry by entry.
#
#   recurrent_parallel   the recurrent run and the parallel closed form are
#                        one function (the licence for chunked execution)
#   runGLA_append        a run over a concatenation runs the chunks in order
#   gateProd_append      gate products compose across a chunk boundary
#   chunk_closed         a chunk acts on the reached state through its own
#                        gate product and contribution only
#   contrib_sum          the contribution is the literal sum over tokens of
#                        (gates after the token) * key val^T
#
# Matrices are functions of (row, column).  The carrier, the semiring and
# the gate/key/value maps are template arguments; the initial state S is an
# ordinary argument used once, so every theorem holds for EVERY initial
# state.  The entry-level recurrence runE carries the algebra; runGLA is
# related to it by unfolding alone (runGLA_entry), which needs no law.

def Matrix(-C: Data) -> Type:
  Nat -> Nat -> C

def stepAt(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
           +t: A, S: Matrix(C), +i: Nat, +j: Nat) -> C:
  Al.SR.add(C, R)(Al.SR.mul(C, R)(gate(t, i), S(i, j)), Al.SR.mul(C, R)(key(t, i), val(t, j)))

def stepGLA(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
            +t: A, S: Matrix(C)) -> Matrix(C):
  i => j => stepAt(~C, ~R, ~A, ~gate, ~key, ~val, t, S, i, j)

# the recurrent form: one step per token
def runGLA(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
           +ts: List<&2, A>, S: Matrix(C)) -> Matrix(C):
  match ts:
    case Nil{}:
      S
    case +t <> +rest:
      runGLA(~C, ~R, ~A, ~gate, ~key, ~val, rest, stepGLA(~C, ~R, ~A, ~gate, ~key, ~val, t, S))

# one entry of the recurrence
def entry(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
          +t: A, +i: Nat, +j: Nat, +s: C) -> C:
  Al.SR.add(C, R)(Al.SR.mul(C, R)(gate(t, i), s), Al.SR.mul(C, R)(key(t, i), val(t, j)))

def runE(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
         +ts: List<&2, A>, +i: Nat, +j: Nat, +s: C) -> C:
  match ts:
    case Nil{}:
      s
    case +t <> +rest:
      runE(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j, entry(~C, ~R, ~A, ~gate, ~key, ~val, t, i, j, s))

# the diagonal of the transition product; later tokens multiply on the
# left (multiplication is not assumed commutative)
def gateProd(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, +ts: List<&2, A>, +i: Nat) -> C:
  match ts:
    case Nil{}:
      Al.SR.one(C, R)
    case +t <> +rest:
      Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, rest, i), gate(t, i))

def kv(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C, +t: A, +i: Nat, +j: Nat) -> C:
  Al.SR.mul(C, R)(key(t, i), val(t, j))

# every token's key val^T, decayed by the gates after it
def contrib(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
            +ts: List<&2, A>, +i: Nat, +j: Nat) -> C:
  match ts:
    case Nil{}:
      Al.SR.zero(C, R)
    case +t <> +rest:
      Al.SR.add(C, R)(Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, rest, i), kv(~C, ~R, ~A, ~key, ~val, t, i, j)),
                      contrib(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j))

def closedE(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
            +ts: List<&2, A>, +i: Nat, +j: Nat, +s: C) -> C:
  Al.SR.add(C, R)(Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, ts, i), s), contrib(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j))

def closedAt(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
             +ts: List<&2, A>, S: Matrix(C), +i: Nat, +j: Nat) -> C:
  closedE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, S(i, j))

# the parallel form
def closedGLA(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
              +ts: List<&2, A>, S: Matrix(C)) -> Matrix(C):
  i => j => closedAt(~C, ~R, ~A, ~gate, ~key, ~val, ts, S, i, j)

# runGLA reads, entry by entry, as runE: unfolding only, no law
def runGLA_entry(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                 +ts: List<&2, A>, -S: Matrix(C), +i: Nat, +j: Nat) ->
    {runGLA(~C, ~R, ~A, ~gate, ~key, ~val, ts, S)(i, j) == runE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, S(i, j)) : C}:
  match ts:
    case Nil{}:
      {==}
    case +t <> +rest:
      runGLA_entry(~C, ~R, ~A, ~gate, ~key, ~val, rest, stepGLA(~C, ~R, ~A, ~gate, ~key, ~val, t, S), i, j)

# The recurrent and parallel forms agree at every entry.
def recurrent_parallel_entry(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                             +ts: List<&2, A>, +i: Nat, +j: Nat, +s: C) ->
    {runE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s) == closedE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s) : C}:
  match ts:
    case Nil{}:
      %Al.SR.mul_one_l(C, R, s) : {_ == Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.one(C, R), s), Al.SR.zero(C, R)) : C}
      Equal.sym(C, Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.one(C, R), s), Al.SR.zero(C, R)), Al.SR.mul(C, R)(Al.SR.one(C, R), s), Al.SR.add_zero_r(~C, ~R, Al.SR.mul(C, R)(Al.SR.one(C, R), s)))
    case +t <> +rest:
      +g = gateProd(~C, ~R, ~A, ~gate, rest, i)
      +gt = gate(t, i)
      +k = kv(~C, ~R, ~A, ~key, ~val, t, i, j)
      +c = contrib(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j)
      +st = Al.SR.mul(C, R)(gt, s)
      %Equal.sym(C, runE(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j, Al.SR.add(C, R)(st, k)), closedE(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j, Al.SR.add(C, R)(st, k)),
                 recurrent_parallel_entry(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j, Al.SR.add(C, R)(st, k)))
        : {_ == Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.mul(C, R)(g, gt), s), Al.SR.add(C, R)(Al.SR.mul(C, R)(g, k), c)) : C}
      %Equal.sym(C, Al.SR.mul(C, R)(g, Al.SR.add(C, R)(st, k)), Al.SR.add(C, R)(Al.SR.mul(C, R)(g, st), Al.SR.mul(C, R)(g, k)), Al.SR.distrib_l(C, R, g, st, k))
        : {Al.SR.add(C, R)(_, c) == Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.mul(C, R)(g, gt), s), Al.SR.add(C, R)(Al.SR.mul(C, R)(g, k), c)) : C}
      %Equal.sym(C, Al.SR.add(C, R)(Al.SR.add(C, R)(Al.SR.mul(C, R)(g, st), Al.SR.mul(C, R)(g, k)), c), Al.SR.add(C, R)(Al.SR.mul(C, R)(g, st), Al.SR.add(C, R)(Al.SR.mul(C, R)(g, k), c)),
                 Al.SR.add_assoc(C, R, Al.SR.mul(C, R)(g, st), Al.SR.mul(C, R)(g, k), c))
        : {_ == Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.mul(C, R)(g, gt), s), Al.SR.add(C, R)(Al.SR.mul(C, R)(g, k), c)) : C}
      %Al.SR.mul_assoc(C, R, g, gt, s)
        : {Al.SR.add(C, R)(_, Al.SR.add(C, R)(Al.SR.mul(C, R)(g, k), c)) == Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.mul(C, R)(g, gt), s), Al.SR.add(C, R)(Al.SR.mul(C, R)(g, k), c)) : C}
      {==}

# recurrent == parallel, for every initial state and every entry
def recurrent_parallel(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                       +ts: List<&2, A>, S: Matrix(C), +i: Nat, +j: Nat) ->
    {runGLA(~C, ~R, ~A, ~gate, ~key, ~val, ts, S)(i, j) == closedE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, S(i, j)) : C}:
  Equal.trans(C, runGLA(~C, ~R, ~A, ~gate, ~key, ~val, ts, S)(i, j), runE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, S(i, j)),
    closedE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, S(i, j)),
    runGLA_entry(~C, ~R, ~A, ~gate, ~key, ~val, ts, S, i, j),
    recurrent_parallel_entry(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, S(i, j)))

# running a concatenation is running the chunks in order (refl per step)
def runGLA_append(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                  +ts: List<&2, A>, -us: List<&2, A>, -S: Matrix(C), -i: Nat, -j: Nat) ->
    {runGLA(~C, ~R, ~A, ~gate, ~key, ~val, List.append(&2, A, ts, us), S)(i, j) == runGLA(~C, ~R, ~A, ~gate, ~key, ~val, us, runGLA(~C, ~R, ~A, ~gate, ~key, ~val, ts, S))(i, j) : C}:
  match ts:
    case Nil{}:
      {==}
    case +t <> +rest:
      runGLA_append(~C, ~R, ~A, ~gate, ~key, ~val, rest, us, stepGLA(~C, ~R, ~A, ~gate, ~key, ~val, t, S), i, j)

def gateProd_append(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, +ts: List<&2, A>, +us: List<&2, A>, +i: Nat) ->
    {gateProd(~C, ~R, ~A, ~gate, List.append(&2, A, ts, us), i) == Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, us, i), gateProd(~C, ~R, ~A, ~gate, ts, i)) : C}:
  match ts:
    case Nil{}:
      Equal.sym(C, Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, us, i), Al.SR.one(C, R)), gateProd(~C, ~R, ~A, ~gate, us, i), Al.SR.mul_one_r(C, R, gateProd(~C, ~R, ~A, ~gate, us, i)))
    case +t <> +rest:
      %Equal.sym(C, gateProd(~C, ~R, ~A, ~gate, List.append(&2, A, rest, us), i), Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, us, i), gateProd(~C, ~R, ~A, ~gate, rest, i)), gateProd_append(~C, ~R, ~A, ~gate, rest, us, i))
        : {Al.SR.mul(C, R)(_, gate(t, i)) == Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, us, i), Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, rest, i), gate(t, i))) : C}
      Al.SR.mul_assoc(C, R, gateProd(~C, ~R, ~A, ~gate, us, i), gateProd(~C, ~R, ~A, ~gate, rest, i), gate(t, i))

# The chunkwise recurrence: the second chunk acts on the state the first
# reached, through its own gate product and contribution only.
def chunk_closed(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                 +ts: List<&2, A>, +us: List<&2, A>, S: Matrix(C), +i: Nat, +j: Nat) ->
    {runGLA(~C, ~R, ~A, ~gate, ~key, ~val, List.append(&2, A, ts, us), S)(i, j)
      == closedE(~C, ~R, ~A, ~gate, ~key, ~val, us, i, j, runGLA(~C, ~R, ~A, ~gate, ~key, ~val, ts, S)(i, j)) : C}:
  Equal.trans(C, runGLA(~C, ~R, ~A, ~gate, ~key, ~val, List.append(&2, A, ts, us), S)(i, j),
    runGLA(~C, ~R, ~A, ~gate, ~key, ~val, us, runGLA(~C, ~R, ~A, ~gate, ~key, ~val, ts, S))(i, j),
    closedE(~C, ~R, ~A, ~gate, ~key, ~val, us, i, j, runGLA(~C, ~R, ~A, ~gate, ~key, ~val, ts, S)(i, j)),
    runGLA_append(~C, ~R, ~A, ~gate, ~key, ~val, ts, us, S, i, j),
    recurrent_parallel(~C, ~R, ~A, ~gate, ~key, ~val, us, runGLA(~C, ~R, ~A, ~gate, ~key, ~val, ts, S), i, j))

# Each token paired with its strict suffix, making the sum literal.
type Suffix<-A: Data> is Data:
  Suffix{t: A, rest: List<&2, A>}

def suffixes(-A: Data, +ts: List<&2, A>) -> List<&2, Suffix<A>>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> +rest:
      Suffix{t, rest} <> suffixes(A, rest)

def term(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
         +i: Nat, +j: Nat, p: Suffix<A>) -> C:
  match p:
    case Suffix{+t, rest}:
      Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, rest, i), kv(~C, ~R, ~A, ~key, ~val, t, i, j))

def sumTerms(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
             +ps: List<&2, Suffix<A>>, +i: Nat, +j: Nat) -> C:
  match ps:
    case Nil{}:
      Al.SR.zero(C, R)
    case p <> rest:
      Al.SR.add(C, R)(term(~C, ~R, ~A, ~gate, ~key, ~val, i, j, p), sumTerms(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j))

def contrib_sum(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                +ts: List<&2, A>, +i: Nat, +j: Nat) ->
    {contrib(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j) == sumTerms(~C, ~R, ~A, ~gate, ~key, ~val, suffixes(A, ts), i, j) : C}:
  match ts:
    case Nil{}:
      {==}
    case +t <> +rest:
      %contrib_sum(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j)
        : {Al.SR.add(C, R)(Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, rest, i), kv(~C, ~R, ~A, ~key, ~val, t, i, j)), contrib(~C, ~R, ~A, ~gate, ~key, ~val, rest, i, j))
            == Al.SR.add(C, R)(Al.SR.mul(C, R)(gateProd(~C, ~R, ~A, ~gate, rest, i), kv(~C, ~R, ~A, ~key, ~val, t, i, j)), _) : C}
      {==}

# The pure GLA machine at one entry, as a state algebra of
# Autoregressive.bend: weight one per step, the entry as the state.
def machine.step(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                 ~i: Nat, ~j: Nat, +s: C, +t: A) -> Ar.WS<C, C>:
  Ar.WS{Al.SR.one(C, R), entry(~C, ~R, ~A, ~gate, ~key, ~val, t, i, j, s)}

def machine(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
            ~i: Nat, ~j: Nat) -> Ar.StateAlgebra<C, A, C>:
  Ar.StateAlgebra{s => s, s => t => machine.step(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j, s, t)}

# Instances ----------------------------------------------------------------
#
# Over Nat: gates, keys and values that depend on the token and the index.
# Over Bool: a token opens a gate at its own index.

def ng(+t: Nat, +i: Nat) -> Nat:
  Nat.add(t, i)

def nk(+t: Nat, +i: Nat) -> Nat:
  Nat.mul(t, i)

def nv(+t: Nat, +j: Nat) -> Nat:
  1n+j

def bg(+t: Nat, +i: Nat) -> Bool:
  Nat.is_eq(t, i)

def bk(+t: Nat, +i: Nat) -> Bool:
  Nat.is_lt(t, i)

def bv(+t: Nat, +j: Nat) -> Bool:
  Nat.is_le(j, t)

law check.linear:
  for +ts: List<&2, Nat>
  for +us: List<&2, Nat>
  for S: Nat -> Nat -> Nat
  for B: Nat -> Nat -> Bool
  for +i: Nat
  for +j: Nat
  {runGLA(~Nat, ~Al.Nat.semiring(), ~Nat, ~ng, ~nk, ~nv, ts, S)(i, j) == closedE(~Nat, ~Al.Nat.semiring(), ~Nat, ~ng, ~nk, ~nv, ts, i, j, S(i, j)) : Nat}
  & {runGLA(~Bool, ~Al.Bool.semiring(), ~Nat, ~bg, ~bk, ~bv, List.append(&2, Nat, ts, us), B)(i, j)
      == closedE(~Bool, ~Al.Bool.semiring(), ~Nat, ~bg, ~bk, ~bv, us, i, j, runGLA(~Bool, ~Al.Bool.semiring(), ~Nat, ~bg, ~bk, ~bv, ts, B)(i, j)) : Bool}
  & {gateProd(~Nat, ~Al.Nat.semiring(), ~Nat, ~ng, List.append(&2, Nat, ts, us), i) == Nat.mul(gateProd(~Nat, ~Al.Nat.semiring(), ~Nat, ~ng, us, i), gateProd(~Nat, ~Al.Nat.semiring(), ~Nat, ~ng, ts, i)) : Nat}
  & {contrib(~Bool, ~Al.Bool.semiring(), ~Nat, ~bg, ~bk, ~bv, ts, i, j) == sumTerms(~Bool, ~Al.Bool.semiring(), ~Nat, ~bg, ~bk, ~bv, suffixes(Nat, ts), i, j) : Bool}

def check.linear(ts, us, S, B, i, j):
  (recurrent_parallel(~Nat, ~Al.Nat.semiring(), ~Nat, ~ng, ~nk, ~nv, ts, S, i, j),
   chunk_closed(~Bool, ~Al.Bool.semiring(), ~Nat, ~bg, ~bk, ~bv, ts, us, B, i, j),
   gateProd_append(~Nat, ~Al.Nat.semiring(), ~Nat, ~ng, ts, us, i),
   contrib_sum(~Bool, ~Al.Bool.semiring(), ~Nat, ~bg, ~bk, ~bv, ts, i, j))
