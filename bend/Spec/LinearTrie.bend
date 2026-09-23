import Base
import ./Algebra.bend as Al
import ./Autoregressive.bend as Ar
import ./Trie.bend as Tr
import ./AutoregressiveTrie.bend as At
import ./Linear.bend as Li

# Attention/LinearTrie.agda: the GLA state algebra at the observation trie,
# the first concrete discharge of the KV-cache law.  The cache state is one
# fixed-size entry per (row, column) -- its type never mentions the prefix
# length -- and reading a word off the cache is running the recurrence.
#
#   machine_run    the generic state-algebra run of the GLA machine is the
#                  GLA recurrence (refl per step)
#   cache_denotes  the cache trie denotes the recurrence's final state...
#   cache_closed   ...which is the parallel closed form (recurrent_parallel)

def machine_run(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                ~i: Nat, ~j: Nat, +ts: List<&2, A>, +s: C) ->
    {Ar.run(~C, ~A, ~C, ~Li.machine(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j), ts, s) == Li.runE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s) : C}:
  match ts:
    case Nil{}:
      {==}
    case +t <> rest:
      machine_run(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j, rest, Li.entry(~C, ~R, ~A, ~gate, ~key, ~val, t, i, j, s))

def cache_denotes(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                  ~i: Nat, ~j: Nat, +ts: List<&2, A>, +s: C) ->
    {Tr.toLanguage(Tr.len(A, ts), A, C, ts, At.observationTrie(~C, ~A, ~C, ~Li.machine(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j), Tr.len(A, ts), s))
      == Li.runE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s) : C}:
  Equal.trans(C,
    Tr.toLanguage(Tr.len(A, ts), A, C, ts, At.observationTrie(~C, ~A, ~C, ~Li.machine(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j), Tr.len(A, ts), s)),
    Ar.run(~C, ~A, ~C, ~Li.machine(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j), ts, s),
    Li.runE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s),
    At.observation_denotes(~C, ~A, ~C, ~Li.machine(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j), ts, s),
    machine_run(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j, ts, s))

# the cache, read at a word, is the parallel closed form of that word
def cache_closed(~C: Data, ~R: Al.Semiring<C>, ~A: Data, ~gate: @+t:A -> @+i:Nat -> C, ~key: @+t:A -> @+i:Nat -> C, ~val: @+t:A -> @+i:Nat -> C,
                 ~i: Nat, ~j: Nat, +ts: List<&2, A>, +s: C) ->
    {Tr.toLanguage(Tr.len(A, ts), A, C, ts, At.observationTrie(~C, ~A, ~C, ~Li.machine(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j), Tr.len(A, ts), s))
      == Li.closedE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s) : C}:
  Equal.trans(C,
    Tr.toLanguage(Tr.len(A, ts), A, C, ts, At.observationTrie(~C, ~A, ~C, ~Li.machine(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j), Tr.len(A, ts), s)),
    Li.runE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s),
    Li.closedE(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s),
    cache_denotes(~C, ~R, ~A, ~gate, ~key, ~val, ~i, ~j, ts, s),
    Li.recurrent_parallel_entry(~C, ~R, ~A, ~gate, ~key, ~val, ts, i, j, s))

law check.cache:
  for +ts: List<&2, Nat>
  for +s: Nat
  for +b: Bool
  {Tr.toLanguage(Tr.len(Nat, ts), Nat, Nat, ts, At.observationTrie(~Nat, ~Nat, ~Nat, ~Li.machine(~Nat, ~Al.Nat.semiring(), ~Nat, ~Li.ng, ~Li.nk, ~Li.nv, ~2n, ~1n), Tr.len(Nat, ts), s))
      == Li.closedE(~Nat, ~Al.Nat.semiring(), ~Nat, ~Li.ng, ~Li.nk, ~Li.nv, ts, 2n, 1n, s) : Nat}
  & {Tr.toLanguage(Tr.len(Nat, ts), Nat, Bool, ts, At.observationTrie(~Bool, ~Nat, ~Bool, ~Li.machine(~Bool, ~Al.Bool.semiring(), ~Nat, ~Li.bg, ~Li.bk, ~Li.bv, ~0n, ~3n), Tr.len(Nat, ts), b))
      == Li.closedE(~Bool, ~Al.Bool.semiring(), ~Nat, ~Li.bg, ~Li.bk, ~Li.bv, ts, 0n, 3n, b) : Bool}

def check.cache(ts, s, b):
  (cache_closed(~Nat, ~Al.Nat.semiring(), ~Nat, ~Li.ng, ~Li.nk, ~Li.nv, ~2n, ~1n, ts, s),
   cache_closed(~Bool, ~Al.Bool.semiring(), ~Nat, ~Li.bg, ~Li.bk, ~Li.bv, ~0n, ~3n, ts, b))
