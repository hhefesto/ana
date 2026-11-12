import Base
import ../Tokenizer.bend as Tk
import ../Model.bend as Md
import ../Sample.bend as Sm
import ../Tensor.bend as T
import ../Config.bend as C
import ../Decode.bend as D
import ./Spec.bend as A
import ./Episode.bend as E

# The tool loop (docs/AGENT.md): Agent/Spec.bend's `ag.unfold` refined.
# ana decodes until it ends a call line (a tool's heading, `## ghc` ...,
# opening its line after an empty one); the loop runs the tool command with
# the episode so far on standard input and the tool's name as its last
# argument; the tool's standard output is the echo, appended verbatim and
# fed to the decoder as text it did not sample; ana goes on.  ana never
# writes an echo: the decoder stops at the call's newline, and what follows
# it is the tool's.
#
# The tool answers with its exit status: 0 the check passed (the episode is
# solved and ends), 1 it failed (the echo holds the checker's words), any
# other status is the tool's own failure (the episode ends, unsolved).  An
# episode also ends when ana writes EOS, spends a stretch's token budget, or
# has made its quota of calls.
#
# The call line's newline is fed as the newline token even when ana's token
# was a newline with indentation (a tool's heading is followed by an empty
# line in every transcript), so the context reads exactly `## TOOL\n` then
# the echo.  A newline is a word of its own (code32k's pretokenizer), so the
# echo's tokens, encoded alone, are the tokens the whole text would have.

def al.str(+xs: List<&2, U32>) -> String:
  D.dc.Dec.text(Tk.utf8.decode(Nat.add(List.length(&2, U32, xs), 1n), xs, Tk.utf8.mode(xs)))

def al.starts.nl(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 10)
    case Nil{}:
      False{}

def al.tail(+xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case h <> t:
      t
    case Nil{}:
      Nil{}

def al.is.empty(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      False{}

# Where the text is: the current line so far (newest byte first), and
# whether the line before it is empty (true at the text's start)
type AlLine is Data:
  AlLine{line: List<&2, U32>, pe: Bool}

# the line state after a piece of text (a token never holds a newline but
# at its start, so pieces are scanned byte by byte only for the prompt)
def al.line.byte(+l: AlLine, +c: U32) -> AlLine:
  match l:
    case AlLine{+line, pe}:
      Bool.pick(AlLine, U32.is_eq(c, 10), AlLine{Nil{}, al.is.empty(line)}, AlLine{c <> line, pe})

def al.line.of(xs: List<&2, U32>, +l: AlLine) -> AlLine:
  match xs:
    case Nil{}:
      l
    case +c <> t:
      al.line.of(t, al.line.byte(l, c))

# the tool a newline would call here: the current line's heading class 5
# (a format-2 tool), or 7 (the mugen shape's `## echo`: ana ends her call
# with it, and mugen answers; the tool's name is then `echo`), after an
# empty line (empty: no call)
def al.call.at(+hs: List<&2, A.Hd>, +l: AlLine) -> List<&2, U32>:
  match l:
    case AlLine{+line, +pe}:
      +full = List.reverse(&2, U32, 10 <> line)
      +k = A.ag.class(hs, full)
      Bool.pick(List<&2, U32>, Bool.and(pe, Bool.or(Nat.is_eq(k, 5n), Nat.is_eq(k, 7n))),
        List.drop(&2, U32, List.reverse(&2, U32, line), 3n), Nil{})

def al.first(+xs: List<&2, U32>) -> U32:
  match xs:
    case h <> t:
      h
    case Nil{}:
      10

# the line state after a token (a token holds a newline only at its start)
def al.next.line(+l: AlLine, +tb: List<&2, U32>) -> AlLine:
  match l:
    case AlLine{+line, pe}:
      Bool.pick(AlLine, al.starts.nl(tb), AlLine{List.reverse(&2, U32, al.tail(tb)), al.is.empty(line)}, AlLine{List.append(&2, U32, List.reverse(&2, U32, tb), line), pe})

# The retry's product (RETRY_AVOID=1; Spec/Operations.bend's avoid and the
# retry's product along T).  After a failed check the retry's term is
# decoded from the model times avoid(T), T the failed term: every answer but
# T keeps its weight, T's goes to 0.  A term starts after the line that opens
# a code fence (the eval's prompts end with `## Term`'s fence open, so the
# first stretch's term starts at once; a retry writes `## Term` and its fence
# itself) and runs to the stretch's end, its call line included: the stretch
# ends there, so once T is followed to its end, ending there is certain.
#
# δ of the product along T is the model's continuation times avoid of the
# rest of T, and off T the model's own (Lang.avoid's ν/δ laws): while the
# retry follows T, a token x that leaves T weighs the model's M(x), and T's
# own token M(T_i) - q_i, q_i the model's probability of writing T from i to
# its end; one pass of T through the model in the retry's context gives
# every q_i.  Greedy decoding of the product follows T up to the first i
# where another token outweighs M(T_i)·(1 - q_{i+1}), takes that token, and
# decodes normally after it (avoid(T) off T is 𝒰).  At T's last token T's
# weight is 0, so an exact copy never comes out.

# whether a line's first n bytes are backticks
def al.ticks(n: Nat, +xs: List<&2, U32>) -> Bool:
  match n xs:
    case 0n _:
      True{}
    case 1n+p c <> t:
      Bool.and(U32.is_eq(c, 96), al.ticks(p, t))
    case _ _:
      False{}

# the fence state after a newline ends line l: a line opening with three
# backticks opens or closes a fence
def al.fence.turn(+f: Bool, +l: AlLine) -> Bool:
  match l:
    case AlLine{+line, pe}:
      Bool.pick(Bool, al.ticks(3n, List.reverse(&2, U32, line)), Bool.not(f), f)

# the fence state after text (bytes), from line l and state f
def al.fence.of(xs: List<&2, U32>, +l: AlLine, +f: Bool) -> Bool:
  match xs:
    case Nil{}:
      f
    case +c <> t:
      al.fence.of(t, al.line.byte(l, c), Bool.pick(Bool, U32.is_eq(c, 10), al.fence.turn(f, l), f))

# The bookkeeping the product needs, carried with the decoder: every token
# fed so far, newest first (the product replays them after its pass along
# T); whether the text is inside a fence; whether this stretch's term has
# started; the term's tokens so far, newest first; the failed term to avoid
# (empty: none); the tokens forced next (the product's choice, written as
# ana's).
type AlK is Data:
  AlK{fed: List<&2, U32>, fence: Bool, on: Bool, tt: List<&2, U32>, av: List<&2, U32>, force: List<&2, U32>}

def al.k.on(+k: AlK) -> Bool:
  match k:
    case AlK{fed, fence, on, tt, av, force}:
      on

def al.k.fed(+k: AlK) -> List<&2, U32>:
  match k:
    case AlK{fed, fence, on, tt, av, force}:
      fed

def al.k.forcing(+k: AlK, +xs: List<&2, U32>) -> AlK:
  match k:
    case AlK{fed, fence, on, tt, av, force}:
      AlK{fed, fence, on, tt, av, xs}

# the term a call line ends, in order: the term's tokens, then the call's
# (none when no term started)
def al.k.term(+k: AlK, +t: U32) -> List<&2, U32>:
  match k:
    case AlK{fed, fence, +on, +tt, av, force}:
      Bool.pick(List<&2, U32>, on, List.reverse(&2, U32, t <> tt), Nil{})

# the bookkeeping after ana's token t (its bytes tb) on line l: t fed, the
# fence turned when t ends a fence's line, the term started when that opens
# one, t one of the term's tokens when the term had started
def al.k.step(+k: AlK, +l: AlLine, +tb: List<&2, U32>, +t: U32) -> AlK:
  match k:
    case AlK{+fed, +fence, +on, +tt, +av, +force}:
      +f2 = Bool.pick(Bool, al.starts.nl(tb), al.fence.turn(fence, l), fence)
      AlK{t <> fed, f2, Bool.or(on, Bool.and(f2, Bool.not(fence))), Bool.pick(List<&2, U32>, on, t <> tt, tt), av, force}

# The model and its settings, fixed for an episode: dims, the tokenizer,
# the sampling settings, the vocabulary, the byte headings, the newline
# token (the weights live in the engine, Decode.bend's En); rep, the
# repetition cut's window (AGENT_REPEAT, 0: none) and report, whether her
# `## mugen` report is held for the tool's word on it (AGENT_REPORT=1)
type AlM is Data:
  AlM{dm: Md.Dims, b: Tk.Bpe, st: D.Settings, vocab: Nat, hs: List<&2, A.Hd>, nlt: U32, rep: Nat, report: Bool}

def AlM.dm(+m: AlM) -> Md.Dims:
  match m:
    case AlM{dm, b, st, v, hs, n, r, rp}:
      dm

def AlM.b(+m: AlM) -> Tk.Bpe:
  match m:
    case AlM{dm, b, st, v, hs, n, r, rp}:
      b

def AlM.st(+m: AlM) -> D.Settings:
  match m:
    case AlM{dm, b, st, v, hs, n, r, rp}:
      st

def AlM.rep(+m: AlM) -> Nat:
  match m:
    case AlM{dm, b, st, v, hs, n, r, rp}:
      r

def AlM.report(+m: AlM) -> Bool:
  match m:
    case AlM{dm, b, st, v, hs, n, r, rp}:
      rp

# the model with the settings a retry decodes with: after a failed check
# the loop goes on with the retry settings (RETRY_TEMPERATURE, Generate.bend;
# by default the episode's own, so a greedy episode stays greedy)
def AlM.retry(+m: AlM, +rs: D.Settings) -> AlM:
  match m:
    case AlM{dm, b, st, v, hs, n, r, rp}:
      AlM{dm, b, rs, v, hs, n, r, rp}

def AlM.vocab(+m: AlM) -> Nat:
  match m:
    case AlM{dm, b, st, v, hs, n, r, rp}:
      v

def AlM.hs(+m: AlM) -> List<&2, A.Hd>:
  match m:
    case AlM{dm, b, st, v, hs, n, r, rp}:
      hs

def al.of(+md: D.Model, +st: D.Settings, +rep: Nat, +report: Bool) -> AlM:
  match md:
    case D.Model{+c, t, s, +b}:
      AlM{Md.Dims.of(c), b, st, C.Config.vocab(c), A.ag.hds.bytes(), al.first(Tk.Bpe.encode(b, [10])), rep, report}

# whether picking token t on this line ends a call line
def al.is.call(+m: AlM, +l: AlLine, +t: U32) -> Bool:
  Bool.and(al.starts.nl(Tk.Bpe.decode(AlM.b(m), t)), Bool.not(al.is.empty(al.call.at(AlM.hs(m), l))))

# Where decoding is: the engine after the tokens fed so far, the pick drawn
# from its logits, whether the pick is EOS, whether it ends a call line, and
# the product's bookkeeping (a Type: the engine is one, its dense store
# threaded)
type AlG is Type:
  AlG{e: D.En, pk: Sm.Pick, stop: Bool, call: Bool, k: AlK}

def al.g.of(+m: AlM, +l: AlLine, px: D.Px, +k: AlK) -> AlG:
  match px:
    case D.Px{e, +pk, p}:
      +t = D.dc.Pick.token(pk)
      AlG{e, pk, U32.is_eq(t, Tk.eos()), al.is.call(m, l, t), k}

# a pick not drawn: token f, as if ana had drawn it
def al.g.forced(+m: AlM, +l: AlLine, e: D.En, +f: U32, rng: Sm.Rng, +k: AlK) -> AlG:
  AlG{e, Sm.Pick{f, rng}, U32.is_eq(f, Tk.eos()), al.is.call(m, l, f), k}

# One step along T: the model's probability of T's token there, and the
# likeliest other token with its probability
type AlP is Data:
  AlP{p: F32, a: U32, b: F32}

def al.stat(+dv: Nat, +lg: T.V, +x: U32) -> AlP:
  +mx = T.V.max(lg)
  +z = T.V.sum_exp(mx, lg)
  +a = Sm.argmax(dv, T.V.set(dv, lg, x, F32.neg(3.0e38)))
  AlP{F32.div(F32.exp(F32.sub(T.V.at(dv, lg, x), mx)), z), a, F32.div(F32.exp(F32.sub(T.V.at(dv, lg, a), mx)), z)}

# The pass along T, from its end back: q, the model's probability of
# writing T from here to its end (1 past the end: the stretch ends there),
# and the first step where another token outweighs T's under the product:
# its index d, the token a, and a's probability b.  T's own token weighs
# p·(1 - q') (q' the rest's, after it), another its own probability; at T's
# last step T's weighs 0, so the product leaves T there if nowhere before.
type AlC is Data:
  AlC{q: F32, d: Nat, a: U32, b: F32}

def al.cut.last(+x: AlP) -> AlC:
  match x:
    case AlP{+p, +a, +b}:
      AlC{p, 0n, a, b}

def al.cut.step(+x: AlP, +c: AlC) -> AlC:
  match x c:
    case AlP{+p, +a, +b} AlC{+q, +d, +a2, +b2}:
      Bool.pick(AlC, F32.is_gt(b, F32.mul(p, F32.sub(1.0, q))), AlC{F32.mul(p, q), 0n, a, b}, AlC{F32.mul(p, q), 1n+d, a2, b2})

def al.pass.step(+s: AlP, q: D.En & AlC) -> D.En & AlC:
  (e, +c) = q
  (e, al.cut.step(s, c))

# T (x, then rest) read through the model from the logits r answers (x's
# step next); T's last token is not fed (ending after it is certain)
def al.pass.last(+dv: Nat, +x: U32, r: D.En & T.V) -> D.En & AlC:
  (e, +lg) = r
  (e, al.cut.last(al.stat(dv, lg, x)))

def al.pass(+dv: Nat, rest: List<&2, U32>, +x: U32, r: D.En & T.V, +pos: Nat) -> IO(D.En & AlC):
  match rest:
    case Nil{}:
      IO.pure(D.En & AlC, al.pass.last(dv, x, r))
    case +y <> more:
      (e, +lg) = r
      do IO<D.En & AlC>:
        r2 : D.En & T.V <- D.dc.en.step(e, pos, x)
        q : D.En & AlC <- al.pass(dv, more, y, r2, 1n+pos)
        return al.pass.step(al.stat(dv, lg, x), q)

def al.forced.first(+m: AlM, +l: AlLine, e: D.En, +force: List<&2, U32>, rng: Sm.Rng, +k: AlK) -> AlG:
  match force:
    case +f <> rest:
      al.g.forced(m, l, e, f, rng, al.k.forcing(k, rest))
    case Nil{}:
      AlG{e, Sm.Pick{Tk.eos(), rng}, True{}, False{}, k}

# the pass's verdict: the engine emptied and every token fed so far
# replayed (the dense store has no rewind), then T up to d and a forced
def al.product.fin(+m: AlM, +k: AlK, +l: AlLine, +av: List<&2, U32>, q: D.En & AlC, rng: Sm.Rng) -> IO(AlG):
  (e, +c) = q
  match c:
    case AlC{+q0, +d, +a, +b}:
      do IO<AlG>:
        IO.print_err("agent: product: the failed term " ++ Nat.show(List.length(&2, U32, av)) ++ " tokens, copied with probability " ++ F32.show(q0) ++ "; kept " ++ Nat.show(d) ++ ", then token " ++ U32.show(a) ++ " (probability " ++ F32.show(b) ++ ")")
        e2 : D.En <- D.dc.en.reset(e)
        e3 : D.En <- D.dc.en.feeds(List.reverse(&2, U32, al.k.fed(k)), e2, 0n)
        return al.forced.first(m, l, e3, List.append(&2, U32, List.take(&2, U32, av, d), [a]), rng, k)

# the term starts after t and a failed term is to be avoided: t fed with
# its logits, the pass along the failed term, then the product's choice
def al.product(+m: AlM, +k: AlK, +l: AlLine, e: D.En, +pos: Nat, +t: U32, rng: Sm.Rng) -> IO(AlG):
  match k:
    case AlK{+fed, +fence, +on, +tt, +av, force}:
      match av:
        case +x <> rest:
          do IO<AlG>:
            r : D.En & T.V <- D.dc.en.step(e, pos, t)
            q : D.En & AlC <- al.pass(Md.Dims.dv(AlM.dm(m)), rest, x, r, 1n+pos)
            al.product.fin(m, AlK{fed, fence, on, tt, Nil{}, Nil{}}, l, av, q, rng)
        case Nil{}:
          IO.bind(D.Px, AlG, D.dc.en.step.pick(e, pos, t, AlM.dm(m), AlM.st(m), AlM.vocab(m), False{}, rng),
            (px: D.Px) => IO.pure(AlG, al.g.of(m, l, px, AlK{fed, fence, on, tt, Nil{}, Nil{}})))

def al.next.free(+m: AlM, go: Bool, +k: AlK, +l: AlLine, e: D.En, +pos: Nat, +t: U32, rng: Sm.Rng) -> IO(AlG):
  match go:
    case True{}:
      al.product(m, k, l, e, pos, t, rng)
    case False{}:
      IO.bind(D.Px, AlG, D.dc.en.step.pick(e, pos, t, AlM.dm(m), AlM.st(m), AlM.vocab(m), False{}, rng),
        (px: D.Px) => IO.pure(AlG, al.g.of(m, l, px, k)))

# the pick after ana's token t (k already past t, l the line after it): the
# next forced token; the product's choice when t starts the term (`start`)
# and a failed term is to be avoided; else the model's pick
def al.next(+m: AlM, +start: Bool, +k: AlK, +l: AlLine, e: D.En, +pos: Nat, +t: U32, rng: Sm.Rng) -> IO(AlG):
  match k:
    case AlK{+fed, +fence, +on, +tt, +av, +force}:
      match force:
        case +f <> rest:
          IO.bind(D.En, AlG, D.dc.en.feed(e, pos, t),
            (x: D.En) => IO.pure(AlG, al.g.forced(m, l, x, f, rng, AlK{fed, fence, on, tt, av, rest})))
        case Nil{}:
          al.next.free(m, Bool.and(start, Bool.not(al.is.empty(av))), k, l, e, pos, t, rng)

# Where the loop is
#   AlStop    ana ended a stretch (EOS, the budget, or the repetition cut):
#             what it wrote, tokens, and how many of its bytes were
#             written out before a held `## mugen` report (0: none held)
#   AlCalled  ana ended a call line: the tool, what it wrote, tokens, the
#             decoder after the line (engine, position, RNG, pending bytes),
#             every token fed (newest first) and the stretch's term
#   AlPass    the tool passed the check: its echo
#   AlFail    the tool failed the check: its echo, the decoder as it was,
#             the tokens fed and the failed term
#   AlBroke   the tool could not answer
type AlS is Type:
  AlStop{why: String, out: List<&2, U32>, n: Nat, cut: Nat}
  AlCalled{tool: List<&2, U32>, out: List<&2, U32>, n: Nat, e: D.En, pos: Nat, rng: Sm.Rng, pending: List<&2, U32>, fed: List<&2, U32>, tm: List<&2, U32>}
  AlPass{echo: List<&2, U32>}
  AlFail{echo: List<&2, U32>, e: D.En, pos: Nat, rng: Sm.Rng, pending: List<&2, U32>, fed: List<&2, U32>, tm: List<&2, U32>}
  AlBroke{msg: String}

# the call line's newline fed (no logits: the echo comes next)
def al.called(+m: AlM, +pk: Sm.Pick, e: D.En, +pos: Nat, +pending: List<&2, U32>, +out: List<&2, U32>, +count: Nat, +tool: List<&2, U32>, +k: AlK) -> IO(AlS):
  match m:
    case AlM{dm, +b, st, vocab, hs, +nlt, rep, report}:
      +d = D.dc.emit(b, pending, nlt)
      do IO<AlS>:
        IO.write(D.dc.Dec.text(d))
        e2 : D.En <- D.dc.en.feed(e, pos, nlt)
        return AlCalled{tool, List.reverse(&2, U32, 10 <> out), 1n+count, e2, 1n+pos, D.dc.Pick.rng(pk), D.dc.Dec.pending(d),
          nlt <> al.k.fed(k), al.k.term(k, D.dc.Pick.token(pk))}

def al.halt(stop: Bool, +out: List<&2, U32>, +count: Nat, +cut: Nat) -> IO(AlS):
  match stop:
    case True{}:
      IO.pure(AlS, AlStop{"eos", List.reverse(&2, U32, out), count, cut})
    case False{}:
      IO.pure(AlS, AlStop{"budget", List.reverse(&2, U32, out), count, cut})

# The repetition cut (AGENT_REPEAT=W, 11-11).  Greedy decoding loops: at
# step 99,500 one stretch wrote `Nil{}, Nil{}, ...` to the budget, another
# one line 38 times.  A stretch ends (`repeat`) once its last W tokens are
# a run of period 1 to 16: xs[i] = xs[i + k] for every i below W - k, so
# at least W / 16 copies of one short run (W = 128: 8 or more).
def al.rep.at(n: Nat, xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match n xs ys:
    case 0n _ _:
      True{}
    case 1n+p x <> xt y <> yt:
      Bool.and(U32.is_eq(x, y), al.rep.at(p, xt, yt))
    case _ _ _:
      False{}

def al.rep.any(k: Nat, +xs: List<&2, U32>, +w: Nat) -> Bool:
  match k:
    case 0n:
      False{}
    case 1n+(+p):
      Bool.or(al.rep.at(Nat.sub(w, 1n+p), xs, List.drop(&2, U32, xs, 1n+p)), al.rep.any(p, xs, w))

# whether the stretch's last tokens (fed, newest first; count of them hers)
# repeat: the cut on, and the stretch at least its window long
def al.loops(+m: AlM, +k: AlK, +count: Nat) -> Bool:
  +w = AlM.rep(m)
  Bool.and(Bool.and(Nat.is_lt(0n, w), Nat.is_le(w, count)), al.rep.any(16n, List.take(&2, U32, al.k.fed(k), w), w))

# The held report (AGENT_REPORT=1, 11-11).  Every session she trained on
# ends in a passing check and a `## mugen` report that says so, so she
# writes "... passes." whether or not it does (81 of the 118 unsolved
# episodes at step 99,500).  With the report held, what she writes after a
# `## mugen` heading line is not written out as it comes; when the stretch
# ends the tool is asked about it (its name `mugen`, the episode on its
# standard input): exit 0, it stands and is written; exit 1, the tool's
# standard output is written in its place (the report the session earned).
# A call made after the heading writes the held text first.
def al.report.at(+m: AlM, +l: AlLine, +tb: List<&2, U32>) -> Bool:
  match l:
    case AlLine{+line, +pe}:
      Bool.and(Bool.and(AlM.report(m), al.starts.nl(tb)), Bool.and(pe, A.ag.eq(List.reverse(&2, U32, line), Tk.utf8.bytes("## mugen"))))

def al.out(hold: Bool, +s: String) -> IO(Unit):
  match hold:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.write(s)

# the held text, written (out newest first, its first cut bytes already out)
def al.flush(hold: Bool, +out: List<&2, U32>, +cut: Nat) -> IO(Unit):
  match hold:
    case True{}:
      IO.write(al.str(List.drop(&2, U32, List.reverse(&2, U32, out), cut)))
    case False{}:
      IO.pure(Unit, Unit{})

# decode until EOS, the budget, a call (the pick ends a call line), or the
# repetition cut (rp: the tokens so far repeat); `out` is what ana wrote,
# newest byte first; hold, whether a report is held (from byte cut of out on)
def al.gen(n: Nat, rp: Bool, g: AlG, +m: AlM, +pos: Nat, +pending: List<&2, U32>, +l: AlLine, +out: List<&2, U32>, +count: Nat, +hold: Bool, +cut: Nat) -> IO(AlS):
  match n rp g:
    case _ True{} _:
      do IO<AlS>:
        IO.print_err("agent: the repetition cut: the last " ++ Nat.show(AlM.rep(m)) ++ " tokens repeat a short run")
        return AlStop{"repeat", List.reverse(&2, U32, out), count, cut}
    case 1n+p False{} AlG{e, +pk, False{}, True{}, +k}:
      do IO<AlS>:
        al.flush(hold, out, cut)
        al.called(m, pk, e, pos, pending, out, count, al.call.at(AlM.hs(m), l), k)
    case 1n+p False{} AlG{e, +pk, False{}, False{}, +k}:
      +b = AlM.b(m)
      +t = D.dc.Pick.token(pk)
      +tb = Tk.Bpe.decode(b, t)
      +d = D.dc.emit(b, pending, t)
      +l2 = al.next.line(l, tb)
      +k2 = al.k.step(k, l, tb, t)
      +out2 = List.append(&2, U32, List.reverse(&2, U32, tb), out)
      +starts = Bool.and(Bool.not(hold), al.report.at(m, l, tb))
      +cut2 = Bool.pick(Nat, starts, List.length(&2, U32, out2), cut)
      do IO<AlS>:
        al.out(hold, D.dc.Dec.text(d))
        g2 : AlG <- al.next(m, Bool.and(Bool.not(al.k.on(k)), al.k.on(k2)), k2, l2, e, pos, t, D.dc.Pick.rng(pk))
        al.gen(p, al.loops(m, k2, 1n+count), g2, m, 1n+pos, D.dc.Dec.pending(d), l2, out2, 1n+count, Bool.or(hold, starts), cut2)
    case _ False{} AlG{e, pk, stop, call, k}:
      al.halt(stop, out, count, cut)

# The episode as written: its segments (Agent/Episode.bend), newest first,
# each with who wrote it (0 the prompt, 1 ana, 2 a tool: its name and exit
# status, 0 passed, 1 failed); the calls made, the tokens ana drew, how it
# ended (solved, eos, budget, calls, tool-error), and the tool last called
type AlEp is Data:
  AlEp{segs: List<&2, E.EpSeg>, calls: Nat, tokens: Nat, end: String, tool: List<&2, U32>}

def al.ep.add(+e: AlEp, +who: Nat, +x: List<&2, U32>, +n: Nat) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, tl}:
      AlEp{E.EpSeg{who, Nil{}, 0, x} <> ss, c, Nat.add(k, n), f, tl}

# the tool's turn: its echo, written by the tool last called, with its status
def al.ep.echo(+e: AlEp, +code: U32, +x: List<&2, U32>) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, +tl}:
      AlEp{E.EpSeg{2n, tl, code, x} <> ss, c, k, f, tl}

def al.ep.call(+e: AlEp, +tool: List<&2, U32>) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, tl}:
      AlEp{ss, 1n+c, k, f, tool}

def al.ep.fin(+e: AlEp, +why: String) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, tl}:
      AlEp{ss, c, k, why, tl}

# the episode's text, in order (Episode.bend `ep.law.newest`: the newest-first
# fold is `ep.text` of the segments in order, the text the log renders)
def al.ep.text(+e: AlEp) -> List<&2, U32>:
  match e:
    case AlEp{ss, c, k, f, tl}:
      E.ep.text.newest(ss, Nil{})


def al.status(pass: Bool, fail: Bool, +st: U32, +so: String, +se: String, e: D.En, +pos: Nat, +rng: Sm.Rng, +pending: List<&2, U32>, +fed: List<&2, U32>, +tm: List<&2, U32>) -> AlS:
  match pass fail:
    case True{} _:
      AlPass{Tk.utf8.bytes(so)}
    case False{} True{}:
      AlFail{Tk.utf8.bytes(so), e, pos, rng, pending, fed, tm}
    case False{} False{}:
      AlBroke{"the tool failed (exit " ++ U32.show(st) ++ "): " ++ se}

def al.tool.of(r: Result<&1, &1, U32 & String, U32 & (String & String)>, e: D.En, +pos: Nat, +rng: Sm.Rng, +pending: List<&2, U32>, +fed: List<&2, U32>, +tm: List<&2, U32>) -> AlS:
  match r:
    case Done{(+st, (so, se))}:
      al.status(U32.is_eq(st, 0), U32.is_eq(st, 1), st, so, se, e, pos, rng, pending, fed, tm)
    case Fail{(code, msg)}:
      AlBroke{"the tool did not run: " ++ msg}

# the decoder fed the echo, then a new stretch; av the failed term its term
# is to avoid (empty: none)
def al.resume(+m: AlM, +budget: Nat, +echo: List<&2, U32>, e: D.En, +pos: Nat, +rng: Sm.Rng, +pending: List<&2, U32>, +fed: List<&2, U32>, +av: List<&2, U32>) -> IO(AlS):
  +ids = Tk.Bpe.encode(AlM.b(m), echo)
  +l = al.line.of(echo, AlLine{Nil{}, False{}})
  +f = al.fence.of(echo, AlLine{Nil{}, False{}}, False{})
  +k = {AlK{List.append(&2, U32, List.reverse(&2, U32, ids), fed), f, f, Nil{}, av, Nil{}} : AlK}
  do IO<AlS>:
    px : D.Px <- D.dc.en.prefill.pick(ids, e, pos, AlM.dm(m), AlM.st(m), AlM.vocab(m), False{}, rng)
    al.gen(budget, False{}, al.g.of(m, l, px, k), m, Nat.add(pos, List.length(&2, U32, ids)), pending, l, Nil{}, 0n, False{}, 0n)

# her report's segment and the tool's in its place
def al.ep.say(+e: AlEp, +x: List<&2, U32>) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, tl}:
      AlEp{E.EpSeg{2n, Tk.utf8.bytes("mugen"), 1, x} <> ss, c, k, f, tl}

# the tool's word on a held report: exit 0 it stands, exit 1 its output
# replaces it, anything else leaves it (and says so on the error stream)
def al.verdict.got(stands: Bool, other: Bool, +st: U32, +so: String, +se: String, +why: String, +out: List<&2, U32>, +n: Nat, +cut: Nat, +ep: AlEp) -> IO(AlEp):
  match stands other:
    case True{} _:
      do IO<AlEp>:
        IO.write(al.str(List.drop(&2, U32, out, cut)))
        return al.ep.fin(al.ep.add(ep, 1n, out, n), why)
    case False{} False{}:
      do IO<AlEp>:
        IO.write(so)
        IO.print_err("agent: her report, replaced by the tool's: " ++ al.str(List.drop(&2, U32, out, cut)))
        return al.ep.fin(al.ep.say(al.ep.add(ep, 1n, List.take(&2, U32, out, cut), n), Tk.utf8.bytes(so)), why)
    case False{} True{}:
      do IO<AlEp>:
        IO.write(al.str(List.drop(&2, U32, out, cut)))
        IO.print_err("agent: the report's check failed (exit " ++ U32.show(st) ++ "): " ++ se)
        return al.ep.fin(al.ep.add(ep, 1n, out, n), why)

def al.verdict(r: Result<&1, &1, U32 & String, U32 & (String & String)>, +why: String, +out: List<&2, U32>, +n: Nat, +cut: Nat, +ep: AlEp) -> IO(AlEp):
  match r:
    case Done{(+st, (so, se))}:
      al.verdict.got(U32.is_eq(st, 0), Bool.not(U32.is_eq(st, 1)), st, so, se, why, out, n, cut, ep)
    case Fail{(code, msg)}:
      do IO<AlEp>:
        IO.write(al.str(List.drop(&2, U32, out, cut)))
        IO.print_err("agent: the report's check did not run: " ++ msg)
        return al.ep.fin(al.ep.add(ep, 1n, out, n), why)

# a stretch's end: a held report goes to the tool first
def al.stop(none: Bool, +cmd: String, +why: String, +out: List<&2, U32>, +n: Nat, +cut: Nat, +ep: AlEp) -> IO(AlEp):
  match none:
    case True{}:
      IO.pure(AlEp, al.ep.fin(al.ep.add(ep, 1n, out, n), why))
    case False{}:
      do IO<AlEp>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run("sh", ["-c", cmd ++ " \"$1\"", "sh", "mugen"], al.str(al.ep.text(al.ep.add(ep, 1n, out, n))), 16777216, 3600000)
        al.verdict(r, why, out, n, cut, ep)

# The loop: `fuel` is two steps a call (the call, then resuming after a
# failed check), so at most fuel / 2 calls; `rs` the settings every stretch
# after a failed check decodes with; `avoid` whether its term is decoded
# from the product with avoid(the failed term) (RETRY_AVOID); `cmd` the tool
# command (run by sh, the tool's name its argument $1, the episode so far
# its standard input)
def al.round(+fuel: Nat, +m: AlM, +rs: D.Settings, +avoid: Bool, +cmd: String, +budget: Nat, s: AlS, +ep: AlEp) -> IO(AlEp):
  match fuel s:
    case _ AlStop{+why, +out, +n, +cut}:
      al.stop(Nat.is_eq(cut, 0n), cmd, why, out, n, cut, ep)
    case 0n AlCalled{tool, +out, +n, e, pos, rng, pending, fed, tm}:
      IO.pure(AlEp, al.ep.fin(al.ep.add(ep, 1n, out, n), "calls"))
    case 1n+p AlCalled{+tool, +out, +n, e, +pos, +rng, +pending, +fed, +tm}:
      +ep2 = al.ep.call(al.ep.add(ep, 1n, out, n), tool)
      do IO<AlEp>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run("sh", ["-c", cmd ++ " \"$1\"", "sh", al.str(tool)], al.str(al.ep.text(ep2)), 16777216, 3600000)
        al.round(p, m, rs, avoid, cmd, budget, al.tool.of(r, e, pos, rng, pending, fed, tm), ep2)
    case _ AlPass{+echo}:
      do IO<AlEp>:
        IO.write(al.str(echo))
        return al.ep.fin(al.ep.echo(ep, 0, echo), "solved")
    case _ AlBroke{msg}:
      do IO<AlEp>:
        IO.print_err("agent: " ++ msg)
        return al.ep.fin(ep, "tool-error")
    case 1n+p AlFail{+echo, e, +pos, +rng, +pending, +fed, +tm}:
      +m2 = AlM.retry(m, rs)
      do IO<AlEp>:
        IO.write(al.str(echo))
        s2 : AlS <- al.resume(m2, budget, echo, e, pos, rng, pending, fed, Bool.pick(List<&2, U32>, avoid, tm, Nil{}))
        al.round(p, m2, rs, avoid, cmd, budget, s2, al.ep.echo(ep, 1, echo))
    case 0n AlFail{+echo, e, pos, rng, pending, fed, tm}:
      do IO<AlEp>:
        IO.write(al.str(echo))
        return al.ep.fin(al.ep.echo(ep, 1, echo), "calls")

# The ask as her sessions open it.  AGENT_SHAPE=mugen (the ana-mugen wrapper,
# mugen's /ana) makes a bare task mugen's `## user` turn, T.mg.user's bytes
# (tests/agentmugen.bend); any other caller's prompt is whole already.  Until
# 11-04 nothing read AGENT_SHAPE: /ana fed her the bare task, and a checkpoint
# that plays the loop on the eval's prompts wrote comments instead.
def al.ask(+shape: String, +prompt: String) -> String:
  Bool.pick(String, String.eq(shape, "mugen"), "## user\n\n" ++ prompt ++ "\n\n", prompt)

# The first call made for her (AGENT_FIRST, 11-11): the text of a call (its
# heading, its body, `## echo` and that line's newline), fed as if she had
# written it, so the tool answers it before she draws a token.  Every
# session she trained on opens the same way for its shape (an added
# definition: a read of the file's last 24 lines; a hole or a fix: the
# check), and at step 99,500 she guessed the read's lines (`kex.bend 332
# 24` on a 45-line file) or the path (`lib/Sort.hs` for `src/Sort.hs`).
def al.start(none: Bool, +m: AlM, +l: AlLine, px: D.Px, +first: List<&2, U32>, +k: AlK) -> AlG:
  match none:
    case True{}:
      al.g.of(m, l, px, k)
    case False{}:
      match px:
        case D.Px{e, +pk, p}:
          al.forced.first(m, l, e, Tk.Bpe.encode(AlM.b(m), first), D.dc.Pick.rng(pk), k)

# An episode from a prompt on an engine with empty states: BOS and the
# prompt fed, then the loop (the first call made for her when `first` is
# not empty).  The prompt is written to standard output first, then
# everything ana and the tools write, as it comes: the transcript.
def al.episode(+md: D.Model, e: D.En, +st: D.Settings, +rs: D.Settings, +avoid: Bool, +seed: String, +cmd: String, +calls: Nat, +budget: Nat, +first: List<&2, U32>, +rep: Nat, +report: Bool, +prompt: List<&2, U32>) -> IO(AlEp):
  +m = al.of(md, st, rep, report)
  +ids = List.append(&2, U32, [Tk.bos()], Tk.Bpe.encode(D.dc.Model.b(md), prompt))
  +l = al.line.of(prompt, AlLine{Nil{}, True{}})
  +f = al.fence.of(prompt, AlLine{Nil{}, True{}}, False{})
  do IO<AlEp>:
    IO.write(al.str(prompt))
    px : D.Px <- D.dc.en.prefill.pick(ids, e, 0n, AlM.dm(m), AlM.st(m), AlM.vocab(m), False{}, D.dc.rng.of(seed))
    s : AlS <- al.gen(budget, False{}, al.start(al.is.empty(first), m, l, px, first, AlK{List.reverse(&2, U32, ids), f, f, Nil{}, Nil{}, Nil{}}), m, List.length(&2, U32, ids), Nil{}, l, Nil{}, 0n, False{}, 0n)
    al.round(Nat.mul(2n, calls), m, rs, avoid, cmd, budget, s, AlEp{[E.EpSeg{0n, Nil{}, 0, prompt}], 0n, 0n, "", Nil{}})
