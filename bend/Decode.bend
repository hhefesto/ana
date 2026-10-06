import Base
import ./Num.bend as N
import ./Bytes.bend as B
import ./Config.bend as C
import ./Checkpoint.bend as K
import ./Train/Ckpt.bend as TC
import ./Model.bend as Md
import ./Sample.bend as S
import ./Tensor.bend as T
import ./Tokenizer.bend as Tk
import ./Dense/Ckpt.bend as Dk
import ./Dense/Decode.bend as Dd

# Decode: ana's decoder as a library (bend/Generate.bend, the `ana` command,
# and bend/Agent.bend, the tool loop, both use it; every def is `dc.`, so
# importing it beside Sys, Units or Check names nothing twice).
#
# A checkpoint (FTC2, or the Bend trainer's BTC1) loads as a Model: its
# config, its plan's total steps, the step it was saved at, its weights and
# the tokenizer it names, found by identity (TOKENIZER_FILE, or the first
# candidate artifact that matches).  Decoding is the incremental decoder
# (Model.bend `decode`, the cache-run law executed): a prompt is fed one
# token at a time (`dc.prefill`), and each next token is drawn from the
# logits by `dc.pick` (Sample.bend; temperature 0 is argmax).  The state
# after any prefix (layer states, position, the RNG) is a plain value, so a
# loop can keep it, extend it with text it did not sample (a tool's answer),
# and go on.

# Environment ------------------------------------------------------------
def dc.env.or(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      d

def dc.env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return dc.env.or(r, d)

def dc.f32.or(m: Maybe<&2, F32>, d: F32) -> F32:
  Maybe.default(&2, F32, m, d)

def dc.nat.or(m: Maybe<&2, U32>, d: Nat) -> Nat:
  match m:
    case Some{x}:
      U32.to_nat(x)
    case None{}:
      d

# Tokenizer discovery ----------------------------------------------------
#
# The checkpoint names its tokenizer by identity (a digest over the merge
# list), so the artifact is found, never assumed: TOKENIZER_FILE if set,
# else the first candidate whose identity matches.  Bend has no directory
# listing, so the candidates are the artifacts this repository ships.

def dc.candidates() -> List<&2, String>:
  ["weights/enwiki-fineweb-32k.bpe", "run/enwiki-fineweb-32k.bpe",
   "weights/code32k.bpe", "run/code32k.bpe", "run/enwiki-c4-32k.bpe"]

def dc.open.try(r: Result<&1, &1, U32 & String, File>) -> IO(List<&2, U32>):
  match r:
    case Fail{e}:
      IO.pure(List<&2, U32>, Nil{})
    case Done{f}:
      do IO<List<&2, U32>>:
        fr : B.Chunk() <- File.read_bytes(f, 268435456)
        B.Bytes.all.fin(fr)

# a file's bytes, or nothing if it cannot be opened
def dc.read.maybe(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    dc.open.try(r)

def dc.tok.check.if(ok: Bool, +path: String, +b: Tk.Bpe) -> Maybe<&2, Tk.Bpe>:
  match ok:
    case True{}:
      Some{b}
    case False{}:
      None{}

def dc.tok.check(+want: String, +path: String, m: Maybe<&2, Tk.Bpe>) -> Maybe<&2, Tk.Bpe>:
  match m:
    case Some{+b}:
      dc.tok.check.if(String.eq(Tk.Bpe.identity(b), want), path, b)
    case None{}:
      None{}

def dc.first.some(a: Maybe<&2, Tk.Bpe>, b: Maybe<&2, Tk.Bpe>) -> Maybe<&2, Tk.Bpe>:
  match a:
    case Some{x}:
      Some{x}
    case None{}:
      b

# candidates are read in order until one matches (the flag carries the
# answer, so the recursion stops reading once it has one)
def dc.tok.search(cs: List<&2, String>, +want: String, found: Maybe<&2, Tk.Bpe>) -> IO(Maybe<&2, Tk.Bpe>):
  match cs found:
    case _ Some{b}:
      IO.pure(Maybe<&2, Tk.Bpe>, Some{b})
    case +p <> t None{}:
      do IO<Maybe<&2, Tk.Bpe>>:
        xs : List<&2, U32> <- dc.read.maybe(p)
        dc.tok.search(t, want, dc.tok.check(want, p, Tk.Bpe.parse(xs)))
    case Nil{} None{}:
      IO.pure(Maybe<&2, Tk.Bpe>, None{})

def dc.tok.found(m: Maybe<&2, Tk.Bpe>, +want: String) -> IO(Tk.Bpe):
  match m:
    case Some{b}:
      IO.pure(Tk.Bpe, b)
    case None{}:
      IO.die(Tk.Bpe, 1, "checkpoint uses BPE and no candidate tokenizer matches its identity\n  checkpoint: " ++ want ++ "\n  set TOKENIZER_FILE to the matching .bpe artifact")

def dc.tok.pinned(m: Maybe<&2, Tk.Bpe>, +want: String) -> IO(Tk.Bpe):
  match m:
    case Some{b}:
      IO.pure(Tk.Bpe, b)
    case None{}:
      IO.die(Tk.Bpe, 1, "TOKENIZER_FILE identity does not match the checkpoint\n  checkpoint: " ++ want)

def dc.tok.of.if(empty: Bool, +pinned: String, +want: String) -> IO(Tk.Bpe):
  match empty:
    case True{}:
      do IO<Tk.Bpe>:
        m : Maybe<&2, Tk.Bpe> <- dc.tok.search(dc.candidates(), want, None{})
        dc.tok.found(m, want)
    case False{}:
      do IO<Tk.Bpe>:
        xs : List<&2, U32> <- B.Bytes.read_all(pinned)
        dc.tok.pinned(dc.tok.check(want, pinned, Tk.Bpe.parse(xs)), want)

# The decode loop --------------------------------------------------------

def dc.tok.of(+pinned: String, +want: String) -> IO(Tk.Bpe):
  dc.tok.of.if(String.is_empty(pinned), pinned, want)

type Settings is Data:
  Settings{temp: F32, topk: Nat, topp: F32}

def dc.Out.logits(o: Md.Out) -> T.V:
  match o:
    case Md.Out{l, s}:
      l

def dc.Out.sts(o: Md.Out) -> List<&2, Md.LState>:
  match o:
    case Md.Out{l, s}:
      s

def dc.Pick.token(p: S.Pick) -> U32:
  match p:
    case S.Pick{t, r}:
      t

def dc.Pick.rng(p: S.Pick) -> S.Rng:
  match p:
    case S.Pick{t, r}:
      r

# feed the prompt; answer the output after its last token
def dc.prefill(xs: List<&2, U32>, +dm: Md.Dims, +w: Md.Weights, +o: Md.Out, +pos: Nat) -> Md.Out:
  match xs:
    case Nil{}:
      o
    case t <> rest:
      dc.prefill(rest, dm, w, Md.decode(dm, w, dc.Out.sts(o), pos, t), 1n+pos)

def dc.pick(+dm: Md.Dims, +st: Settings, +vocab: Nat, +logits: T.V, r: S.Rng) -> S.Pick:
  match st:
    case Settings{+t, +k, +p}:
      S.pick(Md.Dims.dv(dm), t, k, p, vocab, logits, r)

def dc.bytes.str(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case h <> t:
      SCon{Chr{h}, dc.bytes.str(t)}

def dc.Dec.text(d: Tk.Dec) -> String:
  match d:
    case Tk.Dec{s, p}:
      s

def dc.Dec.pending(d: Tk.Dec) -> List<&2, U32>:
  match d:
    case Tk.Dec{s, p}:
      p

def dc.emit.bytes(skip: Bool, +b: Tk.Bpe, +t: U32) -> List<&2, U32>:
  match skip:
    case True{}:
      Nil{}
    case False{}:
      Tk.Bpe.decode(b, t)

# the text a token's bytes complete, beside the bytes still pending
def dc.emit(+b: Tk.Bpe, +pending: List<&2, U32>, +t: U32) -> Tk.Dec:
  +xs = List.append(&2, U32, pending, dc.emit.bytes(U32.is_eq(t, Tk.bos()), b, t))
  Tk.utf8.decode(Nat.add(List.length(&2, U32, xs), 1n), xs, Tk.utf8.mode(xs))

# The model's own probability of the chosen token (temperature 1, no
# truncation), the quantity master's SAMPLE_STATS reports as prob=.
def dc.prob.of(+dv: Nat, +logits: T.V, +t: U32) -> F32:
  +m = T.V.max(logits)
  F32.div(F32.exp(F32.sub(T.V.at(dv, logits, t), m)), T.V.sum_exp(m, logits))

def dc.stats.line(on: Bool, +pos: Nat, +t: U32, +p: F32) -> IO(Unit):
  match on:
    case True{}:
      IO.print_err("sample pos=" ++ Nat.show(pos) ++ " token=" ++ U32.show(t) ++ " prob=" ++ F32.show(p))
    case False{}:
      IO.pure(Unit, Unit{})


def dc.strip.if(v1: Bool, s: String) -> String:
  match v1:
    case True{}:
      String.trim_end(s)
    case False{}:
      s


type Wts is Data:
  Wts{w: Md.Weights, step: Nat}

def dc.Load.run(+c: C.Config) -> B.Load(Wts):
  do B.Load<Wts>:
    w : Md.Weights <- Md.Load.weights(c)
    step : Nat <- B.Load.nat()
    return Wts{w, step}

def dc.Wts.w(r: Wts) -> Md.Weights:
  match r:
    case Wts{w, s}:
      w

def dc.Wts.step(r: Wts) -> Nat:
  match r:
    case Wts{w, s}:
      s

def dc.rng.of.m(m: Maybe<&2, N.U64>) -> S.Rng:
  match m:
    case Some{seed}:
      S.Rng.seeded(seed)
    case None{}:
      S.Rng.seeded(N.U64{0, 0})

def dc.rng.of(s: String) -> S.Rng:
  dc.rng.of.m(N.U64.read(s))

def dc.ms(+t0: Nat, +t1: Nat) -> String:
  Nat.show(Nat.sub(t1, t0))


def dc.problem(p: String) -> IO(Unit):
  match p:
    case SNil{}:
      IO.pure(Unit, Unit{})
    case SCon{c, t}:
      IO.die(Unit, 1, "generate: " ++ SCon{c, t})

def dc.byte.identity() -> String:
  "lossless-byte-v1:bos=0:eos=1:bytes=2..257"

# the byte tokenizer is a BPE with no merges (V1 whitespace off)
def dc.tok.btc(bytes: Bool, +pinned: String, +want: String) -> IO(Tk.Bpe):
  match bytes:
    case True{}:
      IO.pure(Tk.Bpe, Tk.Bpe{258, True{}, Nil{}, Tk.LZ{}, Tk.LZ{}})
    case False{}:
      dc.tok.of(pinned, want)

# a BTC1 checkpoint (the Bend trainer's): parsed whole, trained to 100%

# Loading -------------------------------------------------------------------

type Model is Data:
  Model{c: C.Config, total: Nat, step: Nat, b: Tk.Bpe}

def dc.Model.c(+m: Model) -> C.Config:
  match m:
    case Model{c, t, s, b}:
      c

def dc.Model.total(+m: Model) -> Nat:
  match m:
    case Model{c, t, s, b}:
      t

def dc.Model.step(+m: Model) -> Nat:
  match m:
    case Model{c, t, s, b}:
      s

def dc.Model.b(+m: Model) -> Tk.Bpe:
  match m:
    case Model{c, t, s, b}:
      b

# The engine: the decoder's state after the tokens fed so far, and how it
# computes. ETree is the meaning (Model.bend's decode over tree tensors,
# its layer states a value); EDense is its refinement on the dense store
# (Dense/Decode.bend, held to it by tests/decode-dense.bend), the store
# threaded linearly. Both answer the same logits up to F32 rounding.
type En is Type:
  ETree{dm: Md.Dims, w: Md.Weights, sts: List<&2, Md.LState>}
  EDense{k: Dd.Dd, dv: Nat, s: Array<F32>}

def dc.en.tree(+dm: Md.Dims, +w: Md.Weights, o: Md.Out) -> En & T.V:
  match o:
    case Md.Out{l, s}:
      (ETree{dm, w, s}, l)

def dc.en.dense(+k: Dd.Dd, +dv: Nat, r: Array<F32> & List<&2, F32>) -> En & T.V:
  (s, xs) = r
  (EDense{k, dv, s}, T.V.of_list(dv, xs))

# a token in, the logits after it
def dc.en.step(e: En, +pos: Nat, +t: U32) -> En & T.V:
  match e:
    case ETree{+dm, +w, sts}:
      dc.en.tree(dm, w, Md.decode(dm, w, sts, pos, t))
    case EDense{+k, +dv, s}:
      dc.en.dense(k, dv, Dd.dd.logits(k, Dd.dd.feed(k, pos, t, s)))

# a token in, no logits wanted (the dense head is not run)
def dc.en.feed(e: En, +pos: Nat, +t: U32) -> En:
  match e:
    case ETree{+dm, +w, sts}:
      ETree{dm, w, dc.Out.sts(Md.decode(dm, w, sts, pos, t))}
    case EDense{+k, dv, s}:
      EDense{k, dv, Dd.dd.feed(k, pos, t, s)}

# a fold of feeds: every token without logits
def dc.en.feeds(xs: List<&2, U32>, e: En, +pos: Nat) -> En:
  match xs:
    case Nil{}:
      e
    case t <> rest:
      dc.en.feeds(rest, dc.en.feed(e, pos, t), 1n+pos)

# the last token (if any) stepped: its logits
def dc.en.last(ys: List<&2, U32>, e: En, +pos: Nat) -> En & T.V:
  match ys:
    case t <> rest:
      dc.en.step(e, pos, t)
    case Nil{}:
      (e, T.VZ{})

# tokens in from pos, the logits after the last (none: T.VZ). The tree
# engine prefills with dc.prefill, the meaning's (Spec/Refinement.bend's
# prefill_chunks law is about it); the dense engine runs the head only for
# the last token.
def dc.en.prefill(+xs: List<&2, U32>, e: En, +pos: Nat) -> En & T.V:
  match e:
    case ETree{+dm, +w, sts}:
      dc.en.tree(dm, w, dc.prefill(xs, dm, w, {Md.Out{T.VZ{}, sts} : Md.Out}, pos))
    case EDense{+k, +dv, s}:
      +n = Nat.sub(List.length(&2, U32, xs), 1n)
      dc.en.last(List.drop(&2, U32, xs, n), dc.en.feeds(List.take(&2, U32, xs, n), EDense{k, dv, s}, pos), Nat.add(pos, n))

# every layer's state back to empty (a fresh episode on loaded weights)
def dc.en.reset(e: En) -> En:
  match e:
    case ETree{+dm, w, +sts}:
      ETree{dm, w, Md.states.zero(List.length(&2, Md.LState, sts), dm, 0n)}
    case EDense{+k, dv, s}:
      EDense{k, dv, Dd.dd.reset(k, s)}

def dc.en.name(e: En) -> En & String:
  match e:
    case ETree{dm, w, sts}:
      (ETree{dm, w, sts}, "tree")
    case EDense{k, dv, s}:
      (EDense{k, dv, s}, "dense")

# a fresh tree engine: the weights, every layer's state empty
def dc.en.of.tree(+c: C.Config, +w: Md.Weights) -> En:
  +dm = Md.Dims.of(c)
  ETree{dm, w, Md.states.zero(C.Config.layers(c), dm, 0n)}

def dc.loaded.wts(+m: K.Manifest, +b: Tk.Bpe, rw: B.Cur & Wts) -> IO(Model & En):
  (cur, +run) = rw
  do IO<Model & En>:
    B.Bytes.close(cur)
    return (Model{K.Manifest.cfg(m), K.Manifest.total_steps(m), dc.Wts.step(run), b}, dc.en.of.tree(K.Manifest.cfg(m), dc.Wts.w(run)))

# an FTC2 checkpoint on the tree engine: its manifest, its tokenizer, then
# its weights
def dc.loaded(r: B.Cur & K.Manifest, +pinned: String) -> IO(Model & En):
  (cur, +m) = r
  do IO<Model & En>:
    dc.problem(K.Manifest.problem(m))
    b : Tk.Bpe <- dc.tok.of(pinned, K.Manifest.tokenizer_id(m))
    rw : B.Cur & Wts <- dc.Load.run(K.Manifest.cfg(m))(cur)
    dc.loaded.wts(m, b, rw)

# a BTC1 checkpoint (the Bend trainer's): parsed whole, trained to 100%
def dc.loaded.btc(+l: TC.Loaded, +pinned: String) -> IO(Model & En):
  match l:
    case TC.Loaded{+c, +tok, +step, +w}:
      do IO<Model & En>:
        b : Tk.Bpe <- dc.tok.btc(String.eq(tok, dc.byte.identity()), pinned, tok)
        return (Model{c, step, step, b}, dc.en.of.tree(c, w))

def dc.loaded.dense.fin(+man: K.Manifest, +b: Tk.Bpe, +k: Dd.Dd, r: Array<F32> & Nat) -> IO(Model & En):
  (s, +step) = r
  IO.pure(Model & En, (Model{K.Manifest.cfg(man), K.Manifest.total_steps(man), step, b},
    EDense{k, Md.Dims.dv(Md.Dims.of(K.Manifest.cfg(man))), s}))

# an FTC2 checkpoint on the dense engine: its parameter vector read
# straight into the store (one bulk read)
def dc.loaded.dense(+path: String, +pinned: String, mh: K.Manifest & Nat) -> IO(Model & En):
  (+man, +h) = mh
  +k = Dd.dd.of(K.Manifest.cfg(man))
  do IO<Model & En>:
    dc.problem(K.Manifest.problem(man))
    b : Tk.Bpe <- dc.tok.of(pinned, K.Manifest.tokenizer_id(man))
    r : Array<F32> & Nat <- Dd.dd.load(path, man, h, k)
    dc.loaded.dense.fin(man, b, k, r)

def dc.load.fmt(btc: Bool, tree: Bool, +path: String, +pinned: String) -> IO(Model & En):
  match btc tree:
    case True{} _:
      do IO<Model & En>:
        +xs : List<&2, U32> <- B.Bytes.read_all(path)
        dc.loaded.btc(TC.parse(xs), pinned)
    case False{} True{}:
      do IO<Model & En>:
        c : B.Cur <- B.Bytes.open(path)
        r : B.Cur & K.Manifest <- K.Load.header()(c)
        dc.loaded(r, pinned)
    case False{} False{}:
      do IO<Model & En>:
        mh : K.Manifest & Nat <- Dk.header(path)
        dc.loaded.dense(path, pinned, mh)

# a checkpoint and its engine: a .btc file is BTC1 (the tree engine), any
# other FTC2 on the dense engine unless ANA_DECODER=tree; pinned is
# TOKENIZER_FILE ("" to search)
def dc.load(+path: String, +pinned: String) -> IO(Model & En):
  do IO<Model & En>:
    eng : String <- dc.env("ANA_DECODER", "dense")
    dc.load.fmt(String.ends_with(path, ".btc"), String.eq(eng, "tree"), path, pinned)

# the decoding settings: TEMPERATURE (0.8), TOP_K (none), TOP_P (0.95)
def dc.settings(+temp: String, +topk: String, +topp: String) -> Settings:
  Settings{dc.f32.or(F32.read(temp), 0.8), dc.nat.or(U32.read(topk), U32.to_nat(4294967295)), dc.f32.or(F32.read(topp), 0.95)}

# printf "%.3f" of 100 * done / total, in exact integer arithmetic
def dc.pad3(+n: Nat) -> String:
  String.drop(Nat.show(Nat.add(U32.to_nat(1000), n)), 1n)

def dc.pct.milli(+m: Nat) -> String:
  Nat.show(Nat.div(m, U32.to_nat(1000))) ++ "." ++ dc.pad3(Nat.mod(m, U32.to_nat(1000)))

def dc.pct(+done: Nat, +total: Nat) -> String:
  dc.pct.milli(Nat.div(Nat.add(Nat.mul(U32.to_nat(200000), done), total), Nat.mul(2n, total)))
