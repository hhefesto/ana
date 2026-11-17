import Base
import ./Algebra.bend as Al
import ./Autoregressive.bend as Ar
import ./Operations.bend as Op
import ./Nat.bend as NL
import ./Trie.bend as Tr
import ../Agent/Spec.bend as Ag

# A session as a concatenation of languages: the first of Elliott's open
# items (the user, 2026-11-17: "Implement the three Elliott items").
#
# A session is the prompt's text, then ana's turns and the tools' answers.
# Two facts make that precise, over any semiring of weights:
#
#   decoding after a prompt is the derivative by the prompt.  The language
#   "the word t, then Q" (Elliott's ` t ⋆ Q, `prompted` here) read after t
#   is Q itself: δ_t(t ⋆ Q) = Q (`prompt_derivative`).  For the model, the
#   continuation after t is Spec/Autoregressive.bend's residual_continuation
#   (the state t leaves, scaled by t's weight): mixture_residual and
#   product_on_path (Operations.bend) are its two decoder laws, both stated
#   after a prefix;
#
#   the training mask follows from what an episode means.  An episode's
#   turns are concatenated (`flat`), and the model reads all of them; its
#   weight under ana and the tools (`episode`: ana's turns weighed by the
#   model from the state the prefix left, the others by the environment,
#   a function of the prefix: the tool's [answer = tool(prefix)], the
#   task's text) splits into the model's weight of ana's own turns times a
#   factor `env.part` that does not mention the model at all
#   (`episode_factors`).  Training on a whole transcript fits the model's
#   weight of every turn (`full` = the path weight of the concatenation,
#   `full_is_path`), which splits into what the mask keeps times what it
#   drops (`full_splits`); `masked` is Mask.bend's objective, its weights
#   Agent/Spec.bend's ag.weight (`weight_kept`).  Every echo is in the
#   dropped factor: fitting it is fitting a model of the tool, what run 1
#   learned (docs/AGENT.md).  The mask also drops attempts (handed over as
#   wrong) and tries (ana's terms the tool rejected), and keeps the task's
#   text as plain language modelling: choices, which `kept` states and
#   these laws do not derive.
#
# Theorem templates over the semiring (with commutativity, which splitting
# a product needs), the machine and the environment, checked generically
# and at the Nat and Bool instances at the end.

# The prompt -----------------------------------------------------------------

# the word t, then Q: over the cuts u ++ v of the word, word(t)(u)·Q(v)
def conv.word(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~Q: List<&2, A> -> W, +t: List<&2, A>, ps: List<&2, Op.Cut<A>>) -> W:
  match ps:
    case Nil{}:
      Al.SR.zero(W, R)
    case Op.Cut{u, v} <> rest:
      Al.SR.add(W, R)(Al.SR.mul(W, R)(Op.Lang.word.go(~A, ~W, ~R, ~eq, t, u, True{}), Q(v)), conv.word(~A, ~W, ~R, ~eq, ~Q, t, rest))

def prompted(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~Q: List<&2, A> -> W, +t: List<&2, A>, +w: List<&2, A>) -> W:
  conv.word(~A, ~W, ~R, ~eq, ~Q, t, Op.Lang.splits(A, w))

# with the prompt read, no left part that starts with a token is it
def conv.word.nil(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~Q: List<&2, A> -> W, +x: A, ps: List<&2, Op.Cut<A>>) ->
    {conv.word(~A, ~W, ~R, ~eq, ~Q, Nil{}, Op.Lang.splits.cons(A, x, ps)) == Al.SR.zero(W, R) : W}:
  match ps:
    case Nil{}:
      {==}
    case Op.Cut{+u, +v} <> rest:
      %Equal.sym(W, conv.word(~A, ~W, ~R, ~eq, ~Q, Nil{}, Op.Lang.splits.cons(A, x, rest)), Al.SR.zero(W, R), conv.word.nil(~A, ~W, ~R, ~eq, ~Q, x, rest))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.zero(W, R), Q(v)), _) == Al.SR.zero(W, R) : W}
      %Equal.sym(W, Al.SR.mul(W, R)(Al.SR.zero(W, R), Q(v)), Al.SR.zero(W, R), Al.SR.zero_l(W, R, Q(v)))
        : {Al.SR.add(W, R)(_, Al.SR.zero(W, R)) == Al.SR.zero(W, R) : W}
      Al.SR.add_zero_l(W, R, Al.SR.zero(W, R))

# reading the prompt's next token off every left part
def conv.word.cons(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~refl: @+x: A -> {eq(x, x) == True{} : Bool}, ~Q: List<&2, A> -> W,
    +x: A, +t: List<&2, A>, ps: List<&2, Op.Cut<A>>) ->
    {conv.word(~A, ~W, ~R, ~eq, ~Q, x <> t, Op.Lang.splits.cons(A, x, ps)) == conv.word(~A, ~W, ~R, ~eq, ~Q, t, ps) : W}:
  match ps:
    case Nil{}:
      {==}
    case Op.Cut{+u, +v} <> rest:
      %Equal.sym(Bool, eq(x, x), True{}, refl(x))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Op.Lang.word.go(~A, ~W, ~R, ~eq, t, u, _), Q(v)), conv.word(~A, ~W, ~R, ~eq, ~Q, x <> t, Op.Lang.splits.cons(A, x, rest)))
           == Al.SR.add(W, R)(Al.SR.mul(W, R)(Op.Lang.word.go(~A, ~W, ~R, ~eq, t, u, True{}), Q(v)), conv.word(~A, ~W, ~R, ~eq, ~Q, t, rest)) : W}
      %Equal.sym(W, conv.word(~A, ~W, ~R, ~eq, ~Q, x <> t, Op.Lang.splits.cons(A, x, rest)), conv.word(~A, ~W, ~R, ~eq, ~Q, t, rest), conv.word.cons(~A, ~W, ~R, ~eq, ~refl, ~Q, x, t, rest))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Op.Lang.word.go(~A, ~W, ~R, ~eq, t, u, True{}), Q(v)), _)
           == Al.SR.add(W, R)(Al.SR.mul(W, R)(Op.Lang.word.go(~A, ~W, ~R, ~eq, t, u, True{}), Q(v)), conv.word(~A, ~W, ~R, ~eq, ~Q, t, rest)) : W}
      {==}

def prompt_derivative.nil(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~Q: List<&2, A> -> W, +v: List<&2, A>) ->
    {prompted(~A, ~W, ~R, ~eq, ~Q, Nil{}, v) == Q(v) : W}:
  match v:
    case Nil{}:
      %Al.SR.mul_one_l(W, R, Q(Nil{})) : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.one(W, R), Q(Nil{})), Al.SR.zero(W, R)) == _ : W}
      Al.SR.add_zero_r(~W, ~R, Al.SR.mul(W, R)(Al.SR.one(W, R), Q(Nil{})))
    case +x <> +vv:
      +q0 = Q(x <> vv)
      %Equal.sym(W, conv.word(~A, ~W, ~R, ~eq, ~Q, Nil{}, Op.Lang.splits.cons(A, x, Op.Lang.splits(A, vv))), Al.SR.zero(W, R),
          conv.word.nil(~A, ~W, ~R, ~eq, ~Q, x, Op.Lang.splits(A, vv)))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.one(W, R), q0), _) == q0 : W}
      %Equal.sym(W, Al.SR.mul(W, R)(Al.SR.one(W, R), q0), q0, Al.SR.mul_one_l(W, R, q0))
        : {Al.SR.add(W, R)(_, Al.SR.zero(W, R)) == q0 : W}
      Al.SR.add_zero_r(~W, ~R, q0)

# δ_t(t ⋆ Q) = Q: the session "prompt t, then Q", read after its prompt, is Q
def prompt_derivative(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~refl: @+x: A -> {eq(x, x) == True{} : Bool}, ~Q: List<&2, A> -> W,
    t: List<&2, A>, +v: List<&2, A>) ->
    {prompted(~A, ~W, ~R, ~eq, ~Q, t, List.append(&2, A, t, v)) == Q(v) : W}:
  match t:
    case Nil{}:
      prompt_derivative.nil(~A, ~W, ~R, ~eq, ~Q, v)
    case +x <> +tt:
      +rest = Op.Lang.splits.cons(A, x, Op.Lang.splits(A, List.append(&2, A, tt, v)))
      +q0 = Q(x <> List.append(&2, A, tt, v))
      %Equal.sym(W, conv.word(~A, ~W, ~R, ~eq, ~Q, x <> tt, rest), conv.word(~A, ~W, ~R, ~eq, ~Q, tt, Op.Lang.splits(A, List.append(&2, A, tt, v))),
          conv.word.cons(~A, ~W, ~R, ~eq, ~refl, ~Q, x, tt, Op.Lang.splits(A, List.append(&2, A, tt, v))))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.zero(W, R), q0), _) == Q(v) : W}
      %Equal.sym(W, Al.SR.mul(W, R)(Al.SR.zero(W, R), q0), Al.SR.zero(W, R), Al.SR.zero_l(W, R, q0))
        : {Al.SR.add(W, R)(_, prompted(~A, ~W, ~R, ~eq, ~Q, tt, List.append(&2, A, tt, v))) == Q(v) : W}
      %Equal.sym(W, prompted(~A, ~W, ~R, ~eq, ~Q, tt, List.append(&2, A, tt, v)), Q(v), prompt_derivative(~A, ~W, ~R, ~eq, ~refl, ~Q, tt, v))
        : {Al.SR.add(W, R)(Al.SR.zero(W, R), _) == Q(v) : W}
      Al.SR.add_zero_l(W, R, Q(v))

# The episode ----------------------------------------------------------------

type Seg<-A: Data> is Data:
  Seg{role: Ag.Role, toks: List<&2, A>}

# who writes a turn: ana (act, call, try), or the environment (the tool's
# echo; the task's user, given and attempt text)
def by.ana(+r: Ag.Role) -> Bool:
  match r:
    case Ag.RoAct{}:
      True{}
    case Ag.RoCall{}:
      True{}
    case Ag.RoTry{}:
      True{}
    case _:
      False{}

# what the mask keeps: the roles Agent/Spec.bend's ag.weight gives 1
def kept(+r: Ag.Role) -> Bool:
  match r:
    case Ag.RoAttempt{}:
      False{}
    case Ag.RoEcho{}:
      False{}
    case Ag.RoTry{}:
      False{}
    case _:
      True{}

law weight_kept:
  for +r: Ag.Role
  {Ag.ag.weight(r) == Bool.pick(F32, kept(r), 1.0, 0.0) : F32}

def weight_kept(r):
  match r:
    case Ag.RoUser{}:
      {==}
    case Ag.RoGiven{}:
      {==}
    case Ag.RoAttempt{}:
      {==}
    case Ag.RoAct{}:
      {==}
    case Ag.RoCall{}:
      {==}
    case Ag.RoEcho{}:
      {==}
    case Ag.RoTry{}:
      {==}

# an echo is the environment's, and the mask drops it
law echo_roles:
  {by.ana(Ag.RoEcho{}) == False{} : Bool} & {kept(Ag.RoEcho{}) == False{} : Bool}

def echo_roles():
  ({==}, {==})

# the episode's text: its turns concatenated
def flat(-A: Data, segs: List<&2, Seg<A>>) -> List<&2, A>:
  match segs:
    case Nil{}:
      Nil{}
    case Seg{r, x} <> t:
      List.append(&2, A, x, flat(A, t))

# The episode's weight under ana and the environment: a turn of ana's is
# the model's path weight from the state the prefix left; any other turn
# is env(prefix, turn), the tool's or the task's (for a tool, 1 when the
# turn is tool(prefix), else 0).  The model reads every turn.
def episode(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, ~env: List<&2, A> -> Seg<A> -> W,
    segs: List<&2, Seg<A>>, +q: S, +pre: List<&2, A>) -> W:
  match segs:
    case Nil{}:
      Al.SR.one(W, R)
    case Seg{+r, +x} <> t:
      Al.SR.mul(W, R)(Bool.pick(W, by.ana(r), Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q), env(pre, Seg{r, x})),
        episode(~S, ~A, ~W, ~R, ~M, ~env, t, Ar.run(~S, ~A, ~W, ~M, x, q), List.append(&2, A, pre, x)))

# the model's weight of ana's own turns
def ana.part(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, segs: List<&2, Seg<A>>, +q: S) -> W:
  match segs:
    case Nil{}:
      Al.SR.one(W, R)
    case Seg{+r, +x} <> t:
      Al.SR.mul(W, R)(Bool.pick(W, by.ana(r), Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q), Al.SR.one(W, R)),
        ana.part(~S, ~A, ~W, ~R, ~M, t, Ar.run(~S, ~A, ~W, ~M, x, q)))

# the environment's weight of the other turns: no model in it
def env.part(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~env: List<&2, A> -> Seg<A> -> W, segs: List<&2, Seg<A>>, +pre: List<&2, A>) -> W:
  match segs:
    case Nil{}:
      Al.SR.one(W, R)
    case Seg{+r, +x} <> t:
      Al.SR.mul(W, R)(Bool.pick(W, by.ana(r), Al.SR.one(W, R), env(pre, Seg{r, x})),
        env.part(~A, ~W, ~R, ~env, t, List.append(&2, A, pre, x)))

# p·(a·e) = (b ? p : 1)·a · (b ? 1 : p)·e, by cases on b (commutativity
# moves the environment's factor past the model's)
def split(~W: Data, ~R: Al.Semiring<W>, ~mc: @+x:W -> @+y:W -> {Al.SR.mul(W, R)(x, y) == Al.SR.mul(W, R)(y, x) : W},
    b: Bool, +p: W, +en: W, +a: W, +e: W) ->
    {Al.SR.mul(W, R)(Bool.pick(W, b, p, en), Al.SR.mul(W, R)(a, e))
     == Al.SR.mul(W, R)(Al.SR.mul(W, R)(Bool.pick(W, b, p, Al.SR.one(W, R)), a), Al.SR.mul(W, R)(Bool.pick(W, b, Al.SR.one(W, R), en), e)) : W}:
  match b:
    case True{}:
      %Equal.sym(W, Al.SR.mul(W, R)(Al.SR.one(W, R), e), e, Al.SR.mul_one_l(W, R, e))
        : {Al.SR.mul(W, R)(p, Al.SR.mul(W, R)(a, e)) == Al.SR.mul(W, R)(Al.SR.mul(W, R)(p, a), _) : W}
      Equal.sym(W, Al.SR.mul(W, R)(Al.SR.mul(W, R)(p, a), e), Al.SR.mul(W, R)(p, Al.SR.mul(W, R)(a, e)), Al.SR.mul_assoc(W, R, p, a, e))
    case False{}:
      %Equal.sym(W, Al.SR.mul(W, R)(Al.SR.one(W, R), a), a, Al.SR.mul_one_l(W, R, a))
        : {Al.SR.mul(W, R)(en, Al.SR.mul(W, R)(a, e)) == Al.SR.mul(W, R)(_, Al.SR.mul(W, R)(en, e)) : W}
      %Al.SR.mul_assoc(W, R, a, en, e)
        : {Al.SR.mul(W, R)(en, Al.SR.mul(W, R)(a, e)) == _ : W}
      %mc(en, a)
        : {Al.SR.mul(W, R)(en, Al.SR.mul(W, R)(a, e)) == Al.SR.mul(W, R)(_, e) : W}
      Equal.sym(W, Al.SR.mul(W, R)(Al.SR.mul(W, R)(en, a), e), Al.SR.mul(W, R)(en, Al.SR.mul(W, R)(a, e)), Al.SR.mul_assoc(W, R, en, a, e))

# An episode's weight is the model's weight of ana's turns times a factor
# without the model: the likelihood's gradient in the model is a sum over
# ana's own turns, and an echo is never one of them.
def episode_factors(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~mc: @+x:W -> @+y:W -> {Al.SR.mul(W, R)(x, y) == Al.SR.mul(W, R)(y, x) : W},
    ~M: Ar.StateAlgebra<S, A, W>, ~env: List<&2, A> -> Seg<A> -> W, segs: List<&2, Seg<A>>, +q: S, +pre: List<&2, A>) ->
    {episode(~S, ~A, ~W, ~R, ~M, ~env, segs, q, pre) == Al.SR.mul(W, R)(ana.part(~S, ~A, ~W, ~R, ~M, segs, q), env.part(~A, ~W, ~R, ~env, segs, pre)) : W}:
  match segs:
    case Nil{}:
      Equal.sym(W, Al.SR.mul(W, R)(Al.SR.one(W, R), Al.SR.one(W, R)), Al.SR.one(W, R), Al.SR.mul_one_l(W, R, Al.SR.one(W, R)))
    case Seg{+r, +x} <> +t:
      +q2 = Ar.run(~S, ~A, ~W, ~M, x, q)
      +pre2 = List.append(&2, A, pre, x)
      +p = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q)
      +en = env(pre, Seg{r, x})
      +a = ana.part(~S, ~A, ~W, ~R, ~M, t, q2)
      +e = env.part(~A, ~W, ~R, ~env, t, pre2)
      %Equal.sym(W, episode(~S, ~A, ~W, ~R, ~M, ~env, t, q2, pre2), Al.SR.mul(W, R)(a, e), episode_factors(~S, ~A, ~W, ~R, ~mc, ~M, ~env, t, q2, pre2))
        : {Al.SR.mul(W, R)(Bool.pick(W, by.ana(r), p, en), _)
           == Al.SR.mul(W, R)(Al.SR.mul(W, R)(Bool.pick(W, by.ana(r), p, Al.SR.one(W, R)), a), Al.SR.mul(W, R)(Bool.pick(W, by.ana(r), Al.SR.one(W, R), en), e)) : W}
      split(~W, ~R, ~mc, by.ana(r), p, en, a, e)

# Training on a whole transcript: the model's weight of every turn, which
# is its path weight of the episode's text (the concatenation: each turn
# read from the state the turns before it left)
def full(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, segs: List<&2, Seg<A>>, +q: S) -> W:
  match segs:
    case Nil{}:
      Al.SR.one(W, R)
    case Seg{r, +x} <> t:
      Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q), full(~S, ~A, ~W, ~R, ~M, t, Ar.run(~S, ~A, ~W, ~M, x, q)))

def full_is_path(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, segs: List<&2, Seg<A>>, +q: S) ->
    {full(~S, ~A, ~W, ~R, ~M, segs, q) == Ar.pathWeight(~S, ~A, ~W, ~R, ~M, flat(A, segs), q) : W}:
  match segs:
    case Nil{}:
      {==}
    case Seg{r, +x} <> +t:
      +q2 = Ar.run(~S, ~A, ~W, ~M, x, q)
      %Equal.sym(W, full(~S, ~A, ~W, ~R, ~M, t, q2), Ar.pathWeight(~S, ~A, ~W, ~R, ~M, flat(A, t), q2), full_is_path(~S, ~A, ~W, ~R, ~M, t, q2))
        : {Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q), _) == Ar.pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, x, flat(A, t)), q) : W}
      Equal.sym(W, Ar.pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, x, flat(A, t)), q),
        Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q), Ar.pathWeight(~S, ~A, ~W, ~R, ~M, flat(A, t), q2)),
        Ar.factorization(~S, ~A, ~W, ~R, ~M, x, q, flat(A, t)))

# what the mask keeps (Mask.bend's objective: a token weighs its role's
# ag.weight) and what it drops
def masked(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, segs: List<&2, Seg<A>>, +q: S) -> W:
  match segs:
    case Nil{}:
      Al.SR.one(W, R)
    case Seg{+r, +x} <> t:
      Al.SR.mul(W, R)(Bool.pick(W, kept(r), Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q), Al.SR.one(W, R)),
        masked(~S, ~A, ~W, ~R, ~M, t, Ar.run(~S, ~A, ~W, ~M, x, q)))

def dropped(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, segs: List<&2, Seg<A>>, +q: S) -> W:
  match segs:
    case Nil{}:
      Al.SR.one(W, R)
    case Seg{+r, +x} <> t:
      Al.SR.mul(W, R)(Bool.pick(W, kept(r), Al.SR.one(W, R), Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q)),
        dropped(~S, ~A, ~W, ~R, ~M, t, Ar.run(~S, ~A, ~W, ~M, x, q)))

def pick.same(-A: Data, b: Bool, +x: A) -> {Bool.pick(A, b, x, x) == x : A}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}

# the whole transcript's objective is the mask's times the dropped turns'
# (every echo among them: the model of the tool run 1 fitted)
def full_splits(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~mc: @+x:W -> @+y:W -> {Al.SR.mul(W, R)(x, y) == Al.SR.mul(W, R)(y, x) : W},
    ~M: Ar.StateAlgebra<S, A, W>, segs: List<&2, Seg<A>>, +q: S) ->
    {full(~S, ~A, ~W, ~R, ~M, segs, q) == Al.SR.mul(W, R)(masked(~S, ~A, ~W, ~R, ~M, segs, q), dropped(~S, ~A, ~W, ~R, ~M, segs, q)) : W}:
  match segs:
    case Nil{}:
      Equal.sym(W, Al.SR.mul(W, R)(Al.SR.one(W, R), Al.SR.one(W, R)), Al.SR.one(W, R), Al.SR.mul_one_l(W, R, Al.SR.one(W, R)))
    case Seg{+r, +x} <> +t:
      +q2 = Ar.run(~S, ~A, ~W, ~M, x, q)
      +p = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, x, q)
      +a = masked(~S, ~A, ~W, ~R, ~M, t, q2)
      +e = dropped(~S, ~A, ~W, ~R, ~M, t, q2)
      +rhs = Al.SR.mul(W, R)(Al.SR.mul(W, R)(Bool.pick(W, kept(r), p, Al.SR.one(W, R)), a), Al.SR.mul(W, R)(Bool.pick(W, kept(r), Al.SR.one(W, R), p), e))
      %Equal.sym(W, full(~S, ~A, ~W, ~R, ~M, t, q2), Al.SR.mul(W, R)(a, e), full_splits(~S, ~A, ~W, ~R, ~mc, ~M, t, q2))
        : {Al.SR.mul(W, R)(p, _) == rhs : W}
      %pick.same(W, kept(r), p) : {Al.SR.mul(W, R)(_, Al.SR.mul(W, R)(a, e)) == rhs : W}
      split(~W, ~R, ~mc, kept(r), p, p, a, e)

# Instances ------------------------------------------------------------------
#
# Nat weights over Nat tokens (Autoregressive.bend's count machine; the
# prompt's continuation Trie.bend's len.nat), and Bool weights over Nat
# tokens (Operations.bend's `seen` machine; has.zero): the environments
# weigh a turn by its prefix's length, or 1.

def nat.env(pre: List<&2, Nat>) -> Seg<Nat> -> Nat:
  s => 1n+List.length(&2, Nat, pre)

def bool.env(pre: List<&2, Nat>) -> Seg<Nat> -> Bool:
  s => True{}

def bool.and_comm(+x: Bool, +y: Bool) -> {Bool.and(x, y) == Bool.and(y, x) : Bool}:
  match x y:
    case True{} True{}:
      {==}
    case True{} False{}:
      {==}
    case False{} True{}:
      {==}
    case False{} False{}:
      {==}

law check.prompt:
  for +t: List<&2, Nat>
  for +v: List<&2, Nat>
  {prompted(~Nat, ~Nat, ~Al.Nat.semiring(), ~Op.tok.eq, ~Tr.len.nat, t, List.append(&2, Nat, t, v)) == Tr.len.nat(v) : Nat}
  & {prompted(~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.tok.eq, ~Op.has.zero, t, List.append(&2, Nat, t, v)) == Op.has.zero(v) : Bool}

def check.prompt(t, v):
  (prompt_derivative(~Nat, ~Nat, ~Al.Nat.semiring(), ~Op.tok.eq, ~Op.tok.eq_refl, ~Tr.len.nat, t, v),
   prompt_derivative(~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.tok.eq, ~Op.tok.eq_refl, ~Op.has.zero, t, v))

law check.episode:
  for +segs: List<&2, Seg<Nat>>
  for +q: Nat
  for +b: Bool
  for +pre: List<&2, Nat>
  {episode(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), ~nat.env, segs, q, pre)
   == Nat.mul(ana.part(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), segs, q), env.part(~Nat, ~Nat, ~Al.Nat.semiring(), ~nat.env, segs, pre)) : Nat}
  & {episode(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.seen(), ~bool.env, segs, b, pre)
   == Bool.and(ana.part(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.seen(), segs, b), env.part(~Nat, ~Bool, ~Al.Bool.semiring(), ~bool.env, segs, pre)) : Bool}

def check.episode(segs, q, b, pre):
  (episode_factors(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~NL.Nat.mul_comm, ~Ar.count(), ~nat.env, segs, q, pre),
   episode_factors(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~bool.and_comm, ~Op.seen(), ~bool.env, segs, b, pre))

law check.full:
  for +segs: List<&2, Seg<Nat>>
  for +q: Nat
  for +b: Bool
  {full(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), segs, q) == Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), flat(Nat, segs), q) : Nat}
  & {full(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), segs, q)
     == Nat.mul(masked(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), segs, q), dropped(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), segs, q)) : Nat}
  & {full(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.seen(), segs, b) == Ar.pathWeight(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.seen(), flat(Nat, segs), b) : Bool}
  & {full(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.seen(), segs, b)
     == Bool.and(masked(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.seen(), segs, b), dropped(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.seen(), segs, b)) : Bool}

def check.full(segs, q, b):
  (full_is_path(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), segs, q),
   (full_splits(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~NL.Nat.mul_comm, ~Ar.count(), segs, q),
    (full_is_path(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~Op.seen(), segs, b),
     full_splits(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~bool.and_comm, ~Op.seen(), segs, b))))
