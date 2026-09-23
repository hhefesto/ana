import Base

# Foundation/Fold.agda: the standard left fold over list concatenation.
#
# The fold's step function is used once per element, so it is a template
# argument (Bend2's reusable function); the theorem is a theorem template,
# checked below at two unrelated step functions.

def foldl(~A: Data, ~B: Data, ~f: B -> A -> B, xs: List<&2, A>, z: B) -> B:
  match xs:
    case Nil{}:
      z
    case h <> t:
      foldl(~A, ~B, ~f, t, f(z, h))

def foldl_app(~A: Data, ~B: Data, ~f: B -> A -> B, xs: List<&2, A>, -ys: List<&2, A>, -z: B) ->
    {foldl(~A, ~B, ~f, List.append(&2, A, xs, ys), z) == foldl(~A, ~B, ~f, ys, foldl(~A, ~B, ~f, xs, z)) : B}:
  match xs:
    case Nil{}:
      {==}
    case h <> t:
      foldl_app(~A, ~B, ~f, t, ys, f(z, h))

def plus(a: Nat, b: Nat) -> Nat:
  Nat.add(a, b)

def snoc(acc: List<&2, U32>, x: U32) -> List<&2, U32>:
  x <> acc

law check.foldl_app:
  for xs: List<&2, Nat>
  for -ys: List<&2, Nat>
  for -z: Nat
  for us: List<&2, U32>
  for -vs: List<&2, U32>
  for -w: List<&2, U32>
  {foldl(~Nat, ~Nat, ~plus, List.append(&2, Nat, xs, ys), z) == foldl(~Nat, ~Nat, ~plus, ys, foldl(~Nat, ~Nat, ~plus, xs, z)) : Nat}
  & {foldl(~U32, ~List<&2, U32>, ~snoc, List.append(&2, U32, us, vs), w) == foldl(~U32, ~List<&2, U32>, ~snoc, vs, foldl(~U32, ~List<&2, U32>, ~snoc, us, w)) : List<&2, U32>}

def check.foldl_app(xs, ys, z, us, vs, w):
  (foldl_app(~Nat, ~Nat, ~plus, xs, ys, z), foldl_app(~U32, ~List<&2, U32>, ~snoc, us, vs, w))
