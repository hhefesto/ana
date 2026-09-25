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

# generate: master's `formal-transformer-* generate CKPT PROMPT N`, with the
# same environment (TEMPERATURE, TOP_K, TOP_P, SAMPLE_SEED, TOKENIZER_FILE)
# plus CKPT, PROMPT and TOKENS, since a Bend program reads no argv.
#
# The prompt is BOS then its encoding, fed one token at a time through the
# incremental decoder (the cache-run law executed); every sampled token is
# fed back until EOS or the budget.  Output streams as it is decoded.
# Environment ------------------------------------------------------------
def env.or(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      d

def env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env.or(r, d)

def f32.or(m: Maybe<&2, F32>, d: F32) -> F32:
  Maybe.default(&2, F32, m, d)

def nat.or(m: Maybe<&2, U32>, d: Nat) -> Nat:
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

def candidates() -> List<&2, String>:
  ["weights/enwiki-fineweb-32k.bpe", "run/enwiki-fineweb-32k.bpe",
   "weights/code32k.bpe", "run/code32k.bpe", "run/enwiki-c4-32k.bpe"]

def open.try(r: Result<&1, &1, U32 & String, File>) -> IO(List<&2, U32>):
  match r:
    case Fail{e}:
      IO.pure(List<&2, U32>, Nil{})
    case Done{f}:
      do IO<List<&2, U32>>:
        fr : B.Chunk() <- File.read_bytes(f, 268435456)
        B.Bytes.all.fin(fr)

# a file's bytes, or nothing if it cannot be opened
def read.maybe(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    open.try(r)

def tok.check.if(ok: Bool, +path: String, +b: Tk.Bpe) -> Maybe<&2, Tk.Bpe>:
  match ok:
    case True{}:
      Some{b}
    case False{}:
      None{}

def tok.check(+want: String, +path: String, m: Maybe<&2, Tk.Bpe>) -> Maybe<&2, Tk.Bpe>:
  match m:
    case Some{+b}:
      tok.check.if(String.eq(Tk.Bpe.identity(b), want), path, b)
    case None{}:
      None{}

def first.some(a: Maybe<&2, Tk.Bpe>, b: Maybe<&2, Tk.Bpe>) -> Maybe<&2, Tk.Bpe>:
  match a:
    case Some{x}:
      Some{x}
    case None{}:
      b

# candidates are read in order until one matches (the flag carries the
# answer, so the recursion stops reading once it has one)
def tok.search(cs: List<&2, String>, +want: String, found: Maybe<&2, Tk.Bpe>) -> IO(Maybe<&2, Tk.Bpe>):
  match cs found:
    case _ Some{b}:
      IO.pure(Maybe<&2, Tk.Bpe>, Some{b})
    case +p <> t None{}:
      do IO<Maybe<&2, Tk.Bpe>>:
        xs : List<&2, U32> <- read.maybe(p)
        tok.search(t, want, tok.check(want, p, Tk.Bpe.parse(xs)))
    case Nil{} None{}:
      IO.pure(Maybe<&2, Tk.Bpe>, None{})

def tok.found(m: Maybe<&2, Tk.Bpe>, +want: String) -> IO(Tk.Bpe):
  match m:
    case Some{b}:
      IO.pure(Tk.Bpe, b)
    case None{}:
      IO.die(Tk.Bpe, 1, "checkpoint uses BPE and no candidate tokenizer matches its identity\n  checkpoint: " ++ want ++ "\n  set TOKENIZER_FILE to the matching .bpe artifact")

def tok.pinned(m: Maybe<&2, Tk.Bpe>, +want: String) -> IO(Tk.Bpe):
  match m:
    case Some{b}:
      IO.pure(Tk.Bpe, b)
    case None{}:
      IO.die(Tk.Bpe, 1, "TOKENIZER_FILE identity does not match the checkpoint\n  checkpoint: " ++ want)

def tok.of.if(empty: Bool, +pinned: String, +want: String) -> IO(Tk.Bpe):
  match empty:
    case True{}:
      do IO<Tk.Bpe>:
        m : Maybe<&2, Tk.Bpe> <- tok.search(candidates(), want, None{})
        tok.found(m, want)
    case False{}:
      do IO<Tk.Bpe>:
        xs : List<&2, U32> <- B.Bytes.read_all(pinned)
        tok.pinned(tok.check(want, pinned, Tk.Bpe.parse(xs)), want)

# The decode loop --------------------------------------------------------

def tok.of(+pinned: String, +want: String) -> IO(Tk.Bpe):
  tok.of.if(String.is_empty(pinned), pinned, want)

type Settings is Data:
  Settings{temp: F32, topk: Nat, topp: F32}

def Out.logits(o: Md.Out) -> T.V:
  match o:
    case Md.Out{l, s}:
      l

def Out.sts(o: Md.Out) -> List<&2, Md.LState>:
  match o:
    case Md.Out{l, s}:
      s

def Pick.token(p: S.Pick) -> U32:
  match p:
    case S.Pick{t, r}:
      t

def Pick.rng(p: S.Pick) -> S.Rng:
  match p:
    case S.Pick{t, r}:
      r

# feed the prompt; answer the output after its last token
def prefill(xs: List<&2, U32>, +dm: Md.Dims, +w: Md.Weights, +o: Md.Out, +pos: Nat) -> Md.Out:
  match xs:
    case Nil{}:
      o
    case t <> rest:
      prefill(rest, dm, w, Md.decode(dm, w, Out.sts(o), pos, t), 1n+pos)

def pick(+dm: Md.Dims, +st: Settings, +vocab: Nat, +logits: T.V, r: S.Rng) -> S.Pick:
  match st:
    case Settings{+t, +k, +p}:
      S.pick(Md.Dims.dv(dm), t, k, p, vocab, logits, r)

def bytes.str(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case h <> t:
      SCon{Chr{h}, bytes.str(t)}

def Dec.text(d: Tk.Dec) -> String:
  match d:
    case Tk.Dec{s, p}:
      s

def Dec.pending(d: Tk.Dec) -> List<&2, U32>:
  match d:
    case Tk.Dec{s, p}:
      p

def emit.bytes(skip: Bool, +b: Tk.Bpe, +t: U32) -> List<&2, U32>:
  match skip:
    case True{}:
      Nil{}
    case False{}:
      Tk.Bpe.decode(b, t)

# the text a token's bytes complete, beside the bytes still pending
def emit(+b: Tk.Bpe, +pending: List<&2, U32>, +t: U32) -> Tk.Dec:
  +xs = List.append(&2, U32, pending, emit.bytes(U32.is_eq(t, Tk.bos()), b, t))
  Tk.utf8.decode(Nat.add(List.length(&2, U32, xs), 1n), xs, Tk.utf8.mode(xs))

# The model's own probability of the chosen token (temperature 1, no
# truncation), the quantity master's SAMPLE_STATS reports as prob=.
def prob.of(+dv: Nat, +logits: T.V, +t: U32) -> F32:
  +m = T.V.max(logits)
  F32.div(F32.exp(F32.sub(T.V.at(dv, logits, t), m)), T.V.sum_exp(m, logits))

def stats.line(on: Bool, +pos: Nat, +t: U32, +p: F32) -> IO(Unit):
  match on:
    case True{}:
      IO.print_err("sample pos=" ++ Nat.show(pos) ++ " token=" ++ U32.show(t) ++ " prob=" ++ F32.show(p))
    case False{}:
      IO.pure(Unit, Unit{})

def gen(n: Nat, stop: Bool, +pk: S.Pick, +dm: Md.Dims, +w: Md.Weights, +b: Tk.Bpe, +st: Settings,
        +vocab: Nat, +sts: List<&2, Md.LState>, +pos: Nat, +pending: List<&2, U32>, +count: Nat,
        +stats: Bool, +lg: T.V) -> IO(Nat):
  match n stop:
    case 1n+p False{}:
      +t = Pick.token(pk)
      +d = emit(b, pending, t)
      +o = Md.decode(dm, w, sts, pos, t)
      +pk2 = pick(dm, st, vocab, Out.logits(o), Pick.rng(pk))
      do IO<Nat>:
        stats.line(stats, pos, t, prob.of(Md.Dims.dv(dm), lg, t))
        IO.write(Dec.text(d))
        gen(p, U32.is_eq(Pick.token(pk2), Tk.eos()), pk2, dm, w, b, st, vocab, Out.sts(o), 1n+pos, Dec.pending(d), 1n+count, stats, Out.logits(o))
    case _ _:
      IO.pure(Nat, count)

# Main -------------------------------------------------------------------

def strip.if(v1: Bool, s: String) -> String:
  match v1:
    case True{}:
      String.trim_end(s)
    case False{}:
      s

# printf "%.3f" of 100 * done / total, in exact integer arithmetic
def pad3(+n: Nat) -> String:
  String.drop(Nat.show(Nat.add(U32.to_nat(1000), n)), 1n)

def pct.milli(+m: Nat) -> String:
  Nat.show(Nat.div(m, U32.to_nat(1000))) ++ "." ++ pad3(Nat.mod(m, U32.to_nat(1000)))

def pct(+done: Nat, +total: Nat) -> String:
  pct.milli(Nat.div(Nat.add(Nat.mul(U32.to_nat(200000), done), total), Nat.mul(2n, total)))

type Run is Data:
  Run{w: Md.Weights, step: Nat}

def Load.run(+c: C.Config) -> B.Load(Run):
  do B.Load<Run>:
    w : Md.Weights <- Md.Load.weights(c)
    step : Nat <- B.Load.nat()
    return Run{w, step}

def Run.w(r: Run) -> Md.Weights:
  match r:
    case Run{w, s}:
      w

def Run.step(r: Run) -> Nat:
  match r:
    case Run{w, s}:
      s

def rng.of.m(m: Maybe<&2, N.U64>) -> S.Rng:
  match m:
    case Some{seed}:
      S.Rng.seeded(seed)
    case None{}:
      S.Rng.seeded(N.U64{0, 0})

def rng.of(s: String) -> S.Rng:
  rng.of.m(N.U64.read(s))

def ms(+t0: Nat, +t1: Nat) -> String:
  Nat.show(Nat.sub(t1, t0))

def go(+c: C.Config, +total: Nat, +b: Tk.Bpe, +w: Md.Weights, +step: Nat, +prompt: String, +budget: Nat,
       +st: Settings, +seed: String, +t0: Nat, +stats: Bool) -> IO(Unit):
  +dm = Md.Dims.of(c)
  +vocab = C.Config.vocab(c)
  +text = strip.if(Bool.not(Tk.Bpe.v2(b)), prompt)
  +bytes = Tk.utf8.bytes(text)
  +ids = List.append(&2, U32, [Tk.bos()], Tk.Bpe.encode(b, bytes))
  +start = {Md.Out{T.VZ{}, Md.states.zero(C.Config.layers(c), dm, 0n)} : Md.Out}
  +o = prefill(ids, dm, w, start, 0n)
  +pk = pick(dm, st, vocab, Out.logits(o), rng.of(seed))
  do IO<Unit>:
    +t1 : Nat <- IO.now()
    IO.print_err("generate: loaded in " ++ ms(t0, t1) ++ " ms; prompt_tokens=" ++ Nat.show(List.length(&2, U32, ids)))
    IO.print("=== Wikipedia corpus training: " ++ pct(step, Nat.max(total, 1n)) ++ "% complete ("
      ++ Nat.show(step) ++ "/" ++ Nat.show(total) ++ " updates) ===")
    IO.write(bytes.str(Nil{}) ++ text)
    +t2 : Nat <- IO.now()
    n : Nat <- gen(budget, U32.is_eq(Pick.token(pk), Tk.eos()), pk, dm, w, b, st, vocab, Out.sts(o), List.length(&2, U32, ids), Nil{}, 0n, stats, Out.logits(o))
    +t3 : Nat <- IO.now()
    IO.print("")
    IO.print_err("generate: prefill " ++ ms(t1, t2) ++ " ms; " ++ Nat.show(n) ++ " tokens in " ++ ms(t2, t3) ++ " ms")

def problem(p: String) -> IO(Unit):
  match p:
    case SNil{}:
      IO.pure(Unit, Unit{})
    case SCon{c, t}:
      IO.die(Unit, 1, "generate: " ++ SCon{c, t})

def after.run(+m: K.Manifest, +b: Tk.Bpe, rw: B.Cur & Run, +prompt: String, +budget: Nat,
              +st: Settings, +seed: String, +t0: Nat, +stats: Bool) -> IO(Unit):
  (cur, +run) = rw
  do IO<Unit>:
    B.Bytes.close(cur)
    go(K.Manifest.cfg(m), K.Manifest.total_steps(m), b, Run.w(run), Run.step(run), prompt, budget, st, seed, t0, stats)

def after(r: B.Cur & K.Manifest, +prompt: String, +budget: Nat, +st: Settings, +seed: String, +pinned: String, +t0: Nat, +stats: Bool) -> IO(Unit):
  (cur, +m) = r
  do IO<Unit>:
    problem(K.Manifest.problem(m))
    b : Tk.Bpe <- tok.of(pinned, K.Manifest.tokenizer_id(m))
    rw : B.Cur & Run <- Load.run(K.Manifest.cfg(m))(cur)
    after.run(m, b, rw, prompt, budget, st, seed, t0, stats)

def byte.identity() -> String:
  "lossless-byte-v1:bos=0:eos=1:bytes=2..257"

# the byte tokenizer is a BPE with no merges (V1 whitespace off)
def tok.btc(bytes: Bool, +pinned: String, +want: String) -> IO(Tk.Bpe):
  match bytes:
    case True{}:
      IO.pure(Tk.Bpe, Tk.Bpe{258, True{}, Nil{}, Tk.LZ{}, Tk.LZ{}})
    case False{}:
      tok.of(pinned, want)

# a BTC1 checkpoint (the Bend trainer's): parsed whole, trained to 100%
def after.btc(+l: TC.Loaded, +prompt: String, +budget: Nat, +st: Settings, +seed: String, +pinned: String, +t0: Nat, +stats: Bool) -> IO(Unit):
  match l:
    case TC.Loaded{+c, +tok, +step, +w}:
      do IO<Unit>:
        b : Tk.Bpe <- tok.btc(String.eq(tok, byte.identity()), pinned, tok)
        go(c, step, b, w, step, prompt, budget, st, seed, t0, stats)

def open.fmt(btc: Bool, +path: String, +prompt: String, +budget: Nat, +st: Settings, +seed: String, +pinned: String, +t0: Nat, +stats: Bool) -> IO(Unit):
  match btc:
    case True{}:
      do IO<Unit>:
        +xs : List<&2, U32> <- B.Bytes.read_all(path)
        after.btc(TC.parse(xs), prompt, budget, st, seed, pinned, t0, stats)
    case False{}:
      do IO<Unit>:
        c : B.Cur <- B.Bytes.open(path)
        r : B.Cur & K.Manifest <- K.Load.header()(c)
        after(r, prompt, budget, st, seed, pinned, t0, stats)

def main() -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +path : String <- env("CKPT", "run/last-checkpoint")
    +prompt : String <- env("PROMPT", "The")
    +tokens : String <- env("TOKENS", "128")
    +temp : String <- env("TEMPERATURE", "0.8")
    +topk : String <- env("TOP_K", "")
    +topp : String <- env("TOP_P", "0.95")
    +seed : String <- env("SAMPLE_SEED", "0")
    +pinned : String <- env("TOKENIZER_FILE", "")
    sflag : String <- env("SAMPLE_STATS", "")
    +st : Settings = Settings{f32.or(F32.read(temp), 0.8), nat.or(U32.read(topk), U32.to_nat(4294967295)), f32.or(F32.read(topp), 0.95)}
    IO.print_err("generate: temperature=" ++ temp ++ " top_k=" ++ topk ++ " top_p=" ++ topp ++ " seed=" ++ seed)
    open.fmt(String.ends_with(path, ".btc"), path, prompt, nat.or(U32.read(tokens), 128n), st, seed, pinned, t0, String.eq(sflag, "1"))
