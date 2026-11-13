import Base
import ../Sys.bend as S
import ../Check/Lib.bend as Cl

# theory-pick: the arXiv papers R5g pass 2's theory filler takes (2026-11-12).
# The user, 11-12: "I want ana to also be knowledgeable on the theory behind
# the code. Use category theory, type theory and in general math prose that
# helps in proofs with dependent types"; "All of them, credited, as
# Proof-Pile-2 did: nLab, and the arXiv papers under arXiv's default
# license"; "also add all the theory/prose you can find in denotational
# semantics and similar"; "Also use anything you can find in formal
# verification".
#
#   bend-corpus-v2 theory-pick META OUT
#
# META: NUL pairs (arXiv id, record), the record's lines its categories,
# license, title, authors and abstract (run/v9/theory/meta-fetch.sh, from
# arXiv's metadata).  A paper is kept when its categories name math.CT
# (class ct); or name math.LO, cs.LO or cs.PL and its title or abstract,
# lowercased, holds a phrase of one of the topic groups below; or name
# cs.SE or cs.FL (broad categories) and holds a phrase of the groups types,
# proof or verif.  Its class is the first group that matches, in the order
# types, proof, cats, sem, verif.  The classes say how close a paper is to
# proofs with dependent types, so a filler too small for all of them can
# take them in that order.
#
# OUT: a line a kept paper, in META's order, the credits list:
#   id TAB class TAB phrase TAB license TAB title TAB authors
# OUT.pat: `"arxiv_id": "ID"` a line a kept paper, Proof-Pile-2's own
# spelling of its meta field, for grep -F over its arXiv part.
# OUT.stats: papers in, kept a class, dropped.

# Topic phrases, lowercase.  A phrase is matched anywhere in the title and
# abstract, so "categor" would also take model theory's "categorical
# theories"; the phrases below avoid such stems.

# a topic group: its class and phrases
type Grp is Data:
  Grp{c: String, ps: List<&2, String>}

# a kept paper's class and the phrase that kept it
type Hit is Data:
  Hit{c: String, p: String}

def thy.types() -> List<&2, String>:
  ["type theor", "type-theor", "dependent type", "dependently typed", "dependently-typed", "martin-l",
   "calculus of constructions", "identity type", "inductive type", "inductive famil", "higher inductive",
   "coinductive", "homotopy type", "univalen", "cubical", "type system", "typed lambda", "lambda calcul",
   "lambda-calcul", "curry-howard", "curry howard", "propositions as types", "proofs as programs",
   "realizab", "parametricity", "logical relation", "polymorphi", "system f", "linear type", "modal type",
   "refinement type", "session type", "gradual typ", "type inference", "type checking", "typechecking",
   "type-checking", "bidirectional typ", "quantitative type", "guarded recursi", "observational equality",
   "setoid", "proof-relevant", "proof relevant"]

def thy.proof() -> List<&2, String>:
  ["proof assistant", "interactive theorem", "theorem prover", "agda", "coq", "rocq", "isabelle", "lean 4",
   "lean theorem", "lean prover", "mathlib", "hol4", "hol light", "nuprl", "idris", "twelf", "formaliz",
   "formalis", "mechaniz", "mechanis", "machine-checked", "machine checked", "verified compil",
   "certified", "proof engineering", "tactic"]

def thy.cats() -> List<&2, String>:
  ["category theory", "categorical semantic", "categorical model", "categorical logic", "categorical approach",
   "categorical framework", "category of", "categories", "functor", "monad", "adjunct", "adjoint", "topos",
   "topoi", "sheaf", "sheaves", "fibration", "fibred", "fibered", "string diagram", "monoidal", "operad",
   "kan extension", "yoneda", "coalgebra", "algebraic effect", "effect handler", "algebraic theor",
   "lawvere", "cartesian closed", "enriched", "profunctor", "lens", "optic", "polynomial functor",
   "(co)limit", "colimit", "initial algebra", "final coalgebra", "string diagram", "2-categor",
   "higher categor", "infinity-categor", "-groupoid"]

def thy.sem() -> List<&2, String>:
  ["denotational", "domain theor", "domain-theor", "scott domain", "dcpo", "fixed point", "fixed-point",
   "fixpoint", "operational semantic", "full abstraction", "fully abstract", "game semantic", "semantics of",
   "program semantic", "axiomatic semantic", "semantic model", "hoare logic", "separation logic",
   "program logic", "abstract interpretation", "program verification", "program equivalence",
   "contextual equivalence", "bisimulation", "bisimilar", "process calcul", "pi-calculus", "rewriting",
   "normalization", "normalisation", "cut elimination", "cut-elimination", "sequent calcul",
   "natural deduction", "proof theor", "proof-theor", "linear logic", "intuitionistic", "constructive",
   "continuation", "effects", "probabilistic programming", "differentiable programming",
   "automatic differentiation", "functional reactive", "functional programming", "combinator",
   "recursion scheme", "datatype", "data type", "abstract machine", "compiler correctness", "semantics"]

def thy.verif() -> List<&2, String>:
  ["formal verification", "formally verif", "formal method", "verification", "verified", "verifying",
   "model check", "model-check", "temporal logic", " ltl", " ctl ", " smt", "sat solv", "theorem proving",
   "deductive", "refinement calcul", "invariant", "correctness", "symbolic execution", "static analysis",
   "hoare", "contract", "formal specification", "tla+", "alloy", "dafny", "why3", "f*", "liquid haskell",
   "k framework", "proof-carrying", "sel4", "compcert", "bounded model", "reachability", "safety propert",
   "liveness", "automata", "proof obligation", "soundness"]

def thy.groups() -> List<&2, Grp>:
  [Grp{"types", thy.types()}, Grp{"proof", thy.proof()}, Grp{"cats", thy.cats()}, Grp{"sem", thy.sem()}, Grp{"verif", thy.verif()}]

# the broad categories' groups: phrases that name the field itself
def thy.groups.fv() -> List<&2, Grp>:
  [Grp{"types", thy.types()}, Grp{"proof", thy.proof()}, Grp{"verif", thy.verif()}]

def thy.lower(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(U32, Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), U32.add(c, 32), c) <> thy.lower(t)

# the first phrase of ps in xs (found: whether p, the last one tried, was);
# a match stops the search
def thy.hit.go(ps: List<&2, String>, found: Bool, +p: String, +xs: List<&2, U32>) -> Maybe<&2, String>:
  match ps found:
    case _ True{}:
      Some{p}
    case Nil{} False{}:
      None{}
    case +q <> t False{}:
      thy.hit.go(t, S.infix(xs, S.b(q)), q, xs)

def thy.hit(+xs: List<&2, U32>, ps: List<&2, String>) -> Maybe<&2, String>:
  thy.hit.go(ps, False{}, "", xs)

# the first group with a phrase in xs, as its class and the phrase (m: the
# last group tried, c, had one)
def thy.group.go(gs: List<&2, Grp>, m: Maybe<&2, String>, +c: String, +xs: List<&2, U32>) -> Maybe<&2, Hit>:
  match gs m:
    case _ Some{p}:
      Some{Hit{c, p}}
    case Nil{} None{}:
      None{}
    case Grp{d, ps} <> t None{}:
      thy.group.go(t, thy.hit(xs, ps), d, xs)

def thy.group(+xs: List<&2, U32>, gs: List<&2, Grp>) -> Maybe<&2, Hit>:
  thy.group.go(gs, None{}, "", xs)

# does the space-separated category list cs name c
def thy.cat(cs: List<&2, List<&2, U32>>, +c: List<&2, U32>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case x <> t:
      Bool.or(S.eq(x, c), thy.cat(t, c))

def thy.nth(xs: List<&2, List<&2, U32>>, n: Nat) -> List<&2, U32>:
  match xs n:
    case x <> more 0n:
      x
    case x <> more 1n+k:
      thy.nth(more, k)
    case Nil{} _:
      Nil{}

def thy.tt(+cs: List<&2, List<&2, U32>>) -> Bool:
  Bool.or(thy.cat(cs, S.b("math.LO")), Bool.or(thy.cat(cs, S.b("cs.LO")), thy.cat(cs, S.b("cs.PL"))))

def thy.fv(+cs: List<&2, List<&2, U32>>) -> Bool:
  Bool.or(thy.cat(cs, S.b("cs.SE")), thy.cat(cs, S.b("cs.FL")))

# title and abstract, lowercased
def thy.words(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  thy.lower(S.join([thy.nth(ls, 2n), thy.nth(ls, 4n)], 32))

def thy.topic.fv(fv: Bool, +ls: List<&2, List<&2, U32>>) -> Maybe<&2, Hit>:
  match fv:
    case False{}:
      None{}
    case True{}:
      thy.group(thy.words(ls), thy.groups.fv())

# a paper's class and phrase, or None when it is not kept
def thy.topic(tt: Bool, +cs: List<&2, List<&2, U32>>, +ls: List<&2, List<&2, U32>>) -> Maybe<&2, Hit>:
  match tt:
    case False{}:
      thy.topic.fv(thy.fv(cs), ls)
    case True{}:
      thy.group(thy.words(ls), thy.groups())

def thy.class(ct: Bool, +cs: List<&2, List<&2, U32>>, +ls: List<&2, List<&2, U32>>) -> Maybe<&2, Hit>:
  match ct:
    case True{}:
      Some{Hit{"ct", "math.CT"}}
    case False{}:
      thy.topic(thy.tt(cs), cs, ls)

def thy.pick(+ls: List<&2, List<&2, U32>>) -> Maybe<&2, Hit>:
  +cs = S.split(thy.nth(ls, 0n), 32)
  thy.class(thy.cat(cs, S.b("math.CT")), cs, ls)

# a field with no tabs or newlines, for the TSV
def thy.flat(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(U32, Bool.or(U32.is_eq(c, 9), U32.is_eq(c, 10)), 32, c) <> thy.flat(t)

type ThySt is Type:
  ThySt{r: S.Rd, o: File, p: File, st: List<&2, Cl.Stat>, more: Bool}

def thy.line(+id: List<&2, U32>, +c: String, +ph: String, +ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  S.append(S.join([id, S.b(c), S.b(ph), thy.flat(thy.nth(ls, 1n)), thy.flat(thy.nth(ls, 2n)), thy.flat(thy.nth(ls, 3n))], 9), [10])

def thy.keep(+c: String, +ph: String, r: S.Rd, o: File, p: File, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +ls: List<&2, List<&2, U32>>) -> IO(ThySt):
  do IO<ThySt>:
    o2 : File <- S.emit(o, thy.line(id, c, ph, ls))
    p2 : File <- S.emit(p, S.append(S.b("\"arxiv_id\": \""), S.append(id, S.b("\"\n"))))
    return ThySt{r, o2, p2, Cl.stat.bump(c, 1n, st), True{}}

def thy.put(m: Maybe<&2, Hit>, r: S.Rd, o: File, p: File, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +ls: List<&2, List<&2, U32>>) -> IO(ThySt):
  match m:
    case None{}:
      IO.pure(ThySt, ThySt{r, o, p, Cl.stat.bump("dropped", 1n, st), True{}})
    case Some{Hit{c, ph}}:
      thy.keep(c, ph, r, o, p, st, id, ls)

def thy.text(o: File, p: File, st: List<&2, Cl.Stat>, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(ThySt):
  (r, m) = x
  match m:
    case None{}:
      IO.die(ThySt, 1, "theory-pick: an id with no record")
    case Some{t}:
      +ls = S.split(t, 10)
      thy.put(thy.pick(ls), r, o, p, Cl.stat.bump("in", 1n, st), id, ls)

def thy.id(r: S.Rd, o: File, p: File, st: List<&2, Cl.Stat>, m: Maybe<&2, List<&2, U32>>) -> IO(ThySt):
  match m:
    case None{}:
      IO.pure(ThySt, ThySt{r, o, p, st, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, ThySt, S.Rd.next(r), thy.text(o, p, st, id))

def thy.got(o: File, p: File, st: List<&2, Cl.Stat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(ThySt):
  (r, m) = x
  thy.id(r, o, p, st, m)

def thy.step(s: ThySt) -> IO(ThySt):
  match s:
    case ThySt{r, o, p, st, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, ThySt, S.Rd.next(r), thy.got(o, p, st))

def thy.go(fuel: Nat, s: ThySt) -> IO(ThySt):
  match fuel s:
    case 1n+f ThySt{r, o, p, st, True{}}:
      IO.bind(ThySt, ThySt, thy.step(ThySt{r, o, p, st, True{}}), thy.go(f))
    case _ ThySt{r, o, p, st, g}:
      IO.pure(ThySt, ThySt{r, o, p, st, g})

def thy.fin(+out: String, s: ThySt) -> IO(Unit):
  match s:
    case ThySt{r, o, p, +st, g}:
      do IO<Unit>:
        S.Rd.close(r)
        File.close(o)
        File.close(p)
        S.write(out ++ ".stats", S.b(Cl.stat.show(st)))
        IO.print(S.str(S.chomp(S.b(Cl.stat.show(st)))))

def thy.run(+meta: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    r : S.Rd <- S.Rd.open(meta)
    o : File <- IO.try(File, File.open(out, "w"))
    p : File <- IO.try(File, File.open(out ++ ".pat", "w"))
    s : ThySt <- thy.go(U32.to_nat(4294967295), ThySt{r, o, p, Nil{}, True{}})
    thy.fin(out, s)

def thy.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +m <> +o <> Nil{}:
      thy.run(m, o)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 theory-pick META OUT")
