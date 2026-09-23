import Base
import ./Nat.bend as NL
import ./Order.bend as O
import ./Decoding.bend as D

# Attention/Sink.agda: attention sinks as algebra.  softmax-with-sink is
# ordinary softmax over the vocabulary extended by one element that carries
# no value, restricted back: a sink head's token weights are a
# SUBdistribution whose deficiency is exactly the sink's share.
#
#   sink_total          extended mass = sink mass + token mass
#   sink_deficiency     what restriction to the tokens loses is exactly s
#   sink_conservative   s = 0 recovers ordinary softmax
#   token_mass_bounded  token mass never exceeds the extended total
#
# The implementation contract, met by Model.bend's sm.attend: the softmax
# denominator includes the sink's exp and the value sum drops it
# (Spec/Refinement.bend checks that on the executable code).

def withSink(+s: Nat, w: List<&2, Nat>) -> List<&2, Nat>:
  s <> w

law sink_total:
  for +s: Nat
  for +w: List<&2, Nat>
  {D.mass(withSink(s, w)) == Nat.add(s, D.mass(w)) : Nat}

def sink_total(s, w):
  {==}

law sub.self:
  for +n: Nat
  {Nat.sub(n, n) == 0n : Nat}

def sub.self(n):
  match n:
    case 0n:
      {==}
    case 1n+p:
      sub.self(p)

law sub.zero_r:
  for +m: Nat
  {Nat.sub(m, 0n) == m : Nat}

def sub.zero_r(m):
  match m:
    case 0n:
      {==}
    case 1n+p:
      {==}

# (m + n) - n = m
law add_sub:
  for +m: Nat
  for +n: Nat
  {Nat.sub(Nat.add(m, n), n) == m : Nat}

def add_sub(m, n):
  match n:
    case 0n:
      %Equal.sym(Nat, Nat.add(m, 0n), m, NL.Nat.add_zero_r(m)) : {Nat.sub(_, 0n) == m : Nat}
      sub.zero_r(m)
    case 1n+p:
      %Equal.sym(Nat, Nat.add(m, 1n+p), 1n+Nat.add(m, p), NL.Nat.add_succ_r(m, p)) : {Nat.sub(_, 1n+p) == m : Nat}
      add_sub(m, p)

law sink_deficiency:
  for +s: Nat
  for +w: List<&2, Nat>
  {Nat.sub(D.mass(withSink(s, w)), D.mass(w)) == s : Nat}

def sink_deficiency(s, w):
  add_sub(s, D.mass(w))

law sink_conservative:
  for +w: List<&2, Nat>
  {D.mass(withSink(0n, w)) == D.mass(w) : Nat}

def sink_conservative(w):
  {==}

law token_mass_bounded:
  for +s: Nat
  for +w: List<&2, Nat>
  O.Le(D.mass(w), D.mass(withSink(s, w)))

def token_mass_bounded(s, w):
  NL.Le.add_l(D.mass(w), s)
