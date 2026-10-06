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
import ./Decode.bend as D
import ./Agent/Loop.bend as L

# generate (the `ana` app): master's `formal-transformer-* generate CKPT
# PROMPT N`, with the same environment (TEMPERATURE, TOP_K, TOP_P,
# SAMPLE_SEED, TOKENIZER_FILE) plus CKPT, PROMPT and TOKENS, and since
# 2026-10-05 the Haskell-era app's command line, which a shell wrapper in the
# flake used to parse (the user: logic in Bend, at most a small shim): see
# "Command line" below.
#
# The prompt is BOS then its encoding, fed one token at a time through the
# incremental decoder (the cache-run law executed; the dense engine reads
# it ANA_PREFILL_CHUNK tokens at a time, to the same state); every sampled token is
# fed back until EOS or the budget.  Output streams as it is decoded.

# Where decoding is: the engine after the tokens fed so far, the pick it
# answered (D.Px: on the dense store for greedy, else from the logits), the
# pick's probability for SAMPLE_STATS (0 without), and whether the pick is
# EOS. A Type, since the engine is (the dense store is threaded).
type Gs is Type:
  Gs{e: D.En, pk: S.Pick, p: F32, stop: Bool}

def gs.of(px: D.Px) -> Gs:
  match px:
    case D.Px{e, +pk, +p}:
      Gs{e, pk, p, U32.is_eq(D.dc.Pick.token(pk), Tk.eos())}

def gen(n: Nat, g: Gs, +dm: Md.Dims, +b: Tk.Bpe, +st: D.Settings, +vocab: Nat, +pos: Nat, +pending: List<&2, U32>,
        +count: Nat, +stats: Bool) -> IO(Nat):
  match n g:
    case 1n+p Gs{e, +pk, +pr, False{}}:
      +t = D.dc.Pick.token(pk)
      +d = D.dc.emit(b, pending, t)
      do IO<Nat>:
        D.dc.stats.line(stats, pos, t, pr)
        IO.write(D.dc.Dec.text(d))
        gen(p, gs.of(D.dc.en.step.pick(e, pos, t, dm, st, vocab, stats, D.dc.Pick.rng(pk))), dm, b, st, vocab, 1n+pos, D.dc.Dec.pending(d), 1n+count, stats)
    case _ _:
      IO.pure(Nat, count)

# Main -------------------------------------------------------------------

def pct(+done: Nat, +total: Nat) -> String:
  D.dc.pct(done, total)

def go.fin(+t1: Nat, +ids: List<&2, U32>, n: Nat) -> IO(Unit):
  do IO<Unit>:
    +t3 : Nat <- IO.now()
    IO.print("")
    IO.print_err("generate: " ++ Nat.show(List.length(&2, U32, ids)) ++ " prompt tokens and " ++ Nat.show(n) ++ " tokens in " ++ D.dc.ms(t1, t3) ++ " ms")

def go(+c: C.Config, +total: Nat, +b: Tk.Bpe, e: D.En, +step: Nat, +prompt: String, +budget: Nat,
       +st: D.Settings, +seed: String, +t0: Nat, +stats: Bool) -> IO(Unit):
  +dm = Md.Dims.of(c)
  +vocab = C.Config.vocab(c)
  +text = D.dc.strip.if(Bool.not(Tk.Bpe.v2(b)), prompt)
  +bytes = Tk.utf8.bytes(text)
  +ids = List.append(&2, U32, [Tk.bos()], Tk.Bpe.encode(b, bytes))
  do IO<Unit>:
    +t1 : Nat <- IO.now()
    IO.print_err("generate: loaded in " ++ D.dc.ms(t0, t1) ++ " ms; prompt_tokens=" ++ Nat.show(List.length(&2, U32, ids)))
    IO.print("=== ana: step " ++ Nat.show(step) ++ " of " ++ Nat.show(total) ++ " (" ++ pct(step, Nat.max(total, 1n)) ++ "% of its plan) ===")
    IO.write(D.dc.bytes.str(Nil{}) ++ text)
    n : Nat <- gen(budget, gs.of(D.dc.en.prefill.pick(ids, e, 0n, dm, st, vocab, stats, D.dc.rng.of(seed))), dm, b, st, vocab, List.length(&2, U32, ids), Nil{}, 0n, stats)
    go.fin(t1, ids, n)

def open.model(+prompt: String, +budget: Nat, +st: D.Settings, +seed: String, +t0: Nat, +stats: Bool, me: D.Model & D.En) -> IO(Unit):
  (m, e) = me
  match m:
    case D.Model{+c, +total, +step, +b}:
      go(c, total, b, e, step, prompt, budget, st, seed, t0, stats)

# the decoding settings from the environment, then the checkpoint
def generate(+path: String, +prompt: String, +tokens: String, +pinned: String, +t0: Nat) -> IO(Unit):
  do IO<Unit>:
    +temp : String <- D.dc.env("TEMPERATURE", "0.8")
    +topk : String <- D.dc.env("TOP_K", "")
    +topp : String <- D.dc.env("TOP_P", "0.95")
    +seed : String <- D.dc.env("SAMPLE_SEED", "0")
    sflag : String <- D.dc.env("SAMPLE_STATS", "")
    +st : D.Settings = D.dc.settings(temp, topk, topp)
    IO.print_err("generate: temperature=" ++ temp ++ " top_k=" ++ topk ++ " top_p=" ++ topp ++ " seed=" ++ seed)
    me : D.Model & D.En <- D.dc.load(path, pinned)
    open.model(prompt, D.dc.nat.or(U32.read(tokens), 128n), st, seed, t0, String.eq(sflag, "1"), me)

# --agent: the tool loop (Agent/Loop.bend).  ana stops at each call line
# (`## ghc` ...), the tool command answers (AGENT_TOOL, default
# `bend-agent-tool snippet`; its standard output is the echo), and ana goes
# on, at most AGENT_CALLS calls (4); TOKENS is each stretch's budget.
def agent.fin(+t1: Nat, ep: L.AlEp) -> IO(Unit):
  match ep:
    case L.AlEp{ss, +c, +k, +f}:
      do IO<Unit>:
        +t2 : Nat <- IO.now()
        IO.print("")
        IO.print_err("agent: " ++ f ++ "; " ++ Nat.show(c) ++ " calls, " ++ Nat.show(k) ++ " tokens in " ++ D.dc.ms(t1, t2) ++ " ms")

def agent.go(+tool: String, +calls: Nat, +budget: Nat, +st: D.Settings, +seed: String, +prompt: String, +t0: Nat, me: D.Model & D.En) -> IO(Unit):
  (+m, e) = me
  do IO<Unit>:
    +t1 : Nat <- IO.now()
    IO.print_err("agent: loaded in " ++ D.dc.ms(t0, t1) ++ " ms")
    IO.print("=== ana: step " ++ Nat.show(D.dc.Model.step(m)) ++ " of " ++ Nat.show(D.dc.Model.total(m)) ++ " (" ++ pct(D.dc.Model.step(m), Nat.max(D.dc.Model.total(m), 1n)) ++ "% of its plan) ===")
    ep : L.AlEp <- L.al.episode(m, e, st, seed, tool, calls, budget, Tk.utf8.bytes(prompt))
    agent.fin(t1, ep)

def agent(+path: String, +prompt: String, +tokens: String, +pinned: String, +t0: Nat) -> IO(Unit):
  do IO<Unit>:
    +temp : String <- D.dc.env("TEMPERATURE", "0.8")
    +topk : String <- D.dc.env("TOP_K", "")
    +topp : String <- D.dc.env("TOP_P", "0.95")
    +seed : String <- D.dc.env("SAMPLE_SEED", "0")
    +tool : String <- D.dc.env("AGENT_TOOL", "bend-agent-tool snippet")
    +calls : String <- D.dc.env("AGENT_CALLS", "4")
    +st : D.Settings = D.dc.settings(temp, topk, topp)
    IO.print_err("agent: temperature=" ++ temp ++ " top_k=" ++ topk ++ " top_p=" ++ topp ++ " seed=" ++ seed ++ "; tool `" ++ tool ++ "`, at most " ++ calls ++ " calls")
    me : D.Model & D.En <- D.dc.load(path, pinned)
    agent.go(tool, D.dc.nat.or(U32.read(calls), 4n), D.dc.nat.or(U32.read(tokens), 128n), st, seed, prompt, t0, me)

# Command line -----------------------------------------------------------
#
#   ana [--checkpoint PATH] [--tokenizer PATH] [--tokens N]
#       [--prompt TEXT | --prompt-file PATH] [--list] [--agent] [-h] [PROMPT...]
#
# Meaning.  Each setting is the first of: its flag, its WIKI_ variable
# (WIKI_CHECKPOINT, WIKI_TOKENIZER, WIKI_TOKENS, WIKI_PROMPT), the
# evaluation harness's variable (CKPT, TOKENIZER_FILE, TOKENS, PROMPT), and
# a default: the newest local checkpoint (below), the tokenizer the
# checkpoint names, 128 tokens, and one line read from standard input.
# Trailing words are the prompt, joined by spaces.  The runtime takes
# `--threads N` (default: every core) and the first `--` itself; a later
# `--` ends the flags.  A checkpoint named by a flag, a WIKI_ variable or
# discovery is announced (`ana: PATH` on stderr); CKPT is used as given, so
# the harness's output is what it was.
#
# Discovery.  The candidates are the files up to four levels under run/
# named *.checkpoint, as the glob run/*.checkpoint run/*/*.checkpoint
# run/*/*/*.checkpoint run/*/*/*/*.checkpoint sees them (symbolic links
# followed, no component starting with a dot): four reaches a run chain's
# pulls (run/v2/run2/out/), listed by one `find` (Bend has no directory
# listing).  Each one's first four bytes say FTC2, BTC1 or unreadable; they
# rank by write time (seconds), newest first, then by the step in the name
# (the digits after the last "step" or "step-"), then by path; the newest
# readable one is used.  The old flags --pull, --host, --user, --port, --key
# and --remote-checkpoint are gone (the run scripts pull the boxes'
# checkpoints themselves).
#
# Every def is prefixed `cli.` (a program's definitions share one namespace
# across its imports), and each is defined before its first use.

def cli.usage() -> String:
  String.join({[
    "ana [OPTIONS] [PROMPT]",
    "",
    "Generate text from a trained checkpoint with the Bend2 decoder.  With no",
    "options it uses the newest local weights and never contacts the network.",
    "With no prompt it reads one line from standard input.",
    "",
    "  --checkpoint PATH        generate from this checkpoint (skips discovery)",
    "  --tokenizer PATH         tokenizer artifact (default: the one under weights/",
    "                           or run/ whose identity the checkpoint names)",
    "  --tokens N               generation budget (default 128)",
    "  --prompt TEXT            prompt; also accepted as trailing arguments",
    "  --prompt-file PATH       read the prompt from PATH byte for byte, trailing",
    "                           newlines kept (- reads standard input)",
    "  --list                   list local checkpoints, newest first, then exit",
    "  --agent                  stop at each tool call ana writes (## ghc, ## lean,",
    "                           ## agda, ## bend, ## nix), run the real tool and",
    "                           go on from its answer (AGENT_TOOL, AGENT_CALLS)",
    "  --threads N              decoder threads (default: all cores)",
    "  -h, --help               this message",
    "",
    "Newest means the latest write time among the checkpoints up to three",
    "levels under run/ (run/X/out/NAME-stepN.checkpoint, as the box pulls lay",
    "them out) whose first bytes are FTC2 or BTC1 (rsync and cp -p keep the",
    "write time; a checkpoint copied without it ranks by the copy's time).",
    "Ties break toward the higher step in the file name.",
    "",
    "Environment (flags win): WIKI_CHECKPOINT, WIKI_TOKENIZER, WIKI_TOKENS,",
    "WIKI_PROMPT, then CKPT, TOKENIZER_FILE, TOKENS, PROMPT.  TEMPERATURE,",
    "TOP_P, TOP_K and SAMPLE_SEED shape decoding (defaults: temperature 0.8,",
    "nucleus top-p 0.95, top-k off, seed 0); SAMPLE_STATS=1 prints each step's",
    "probability.  AGENT_TOOL is the tool command (default: bend-agent-tool",
    "snippet; the tool's name is its last argument, the episode its input)",
    "and AGENT_CALLS the most calls an --agent episode makes (default 4)."
  ] : List<&2, String>}, "\n")

def cli.strs(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> cli.strs(more)

# a word's part: 0 a prompt word, 1 --checkpoint, 2 --tokenizer, 3 --tokens,
# 4 --prompt, 5 --prompt-file, 6 --list, 7 -h/--help, 8 --, 9 another option,
# 10 --agent
def cli.flag(+x: String) -> Nat:
  Bool.pick(Nat, String.eq(x, "--checkpoint"), 1n, Bool.pick(Nat, String.eq(x, "--tokenizer"), 2n,
  Bool.pick(Nat, String.eq(x, "--tokens"), 3n, Bool.pick(Nat, String.eq(x, "--prompt"), 4n,
  Bool.pick(Nat, String.eq(x, "--prompt-file"), 5n, Bool.pick(Nat, String.eq(x, "--list"), 6n,
  Bool.pick(Nat, Bool.or(String.eq(x, "-h"), String.eq(x, "--help")), 7n,
  Bool.pick(Nat, String.eq(x, "--"), 8n, Bool.pick(Nat, String.eq(x, "--agent"), 10n, Bool.pick(Nat, String.starts_with(x, "-"), 9n, 0n))))))))))

def cli.flag.of(+xs: List<&2, String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> more:
      cli.flag(x)

# the parsed line: a setting is "" when not given; bad, when not "", stops
# the run (with the usage when usage is set)
type Cli is Data:
  Cli{ckpt: String, tok: String, tokens: String, prompt: String, has: Bool, file: String, list: Bool, help: Bool, bad: String, usage: Bool, agent: Bool}

def cli.join(+prompt: String, +has: Bool, +x: String) -> String:
  Bool.pick(String, has, prompt ++ " " ++ x, x)

# after a second `--`: every word is the prompt's
def cli.words(xs: List<&2, String>, +ckpt: String, +tok: String, +tokens: String, +prompt: String, +has: Bool, +file: String, +list: Bool, +agent: Bool) -> Cli:
  match xs:
    case Nil{}:
      Cli{ckpt, tok, tokens, prompt, has, file, list, False{}, "", False{}, agent}
    case +x <> more:
      cli.words(more, ckpt, tok, tokens, cli.join(prompt, has, x), True{}, file, list, agent)

def cli.go(xs: List<&2, String>, +k: Nat, +ckpt: String, +tok: String, +tokens: String, +prompt: String, +has: Bool, +file: String, +list: Bool, +agent: Bool) -> Cli:
  match xs k:
    case x <> y <> +more 1n:
      cli.go(more, cli.flag.of(more), y, tok, tokens, prompt, has, file, list, agent)
    case x <> y <> +more 2n:
      cli.go(more, cli.flag.of(more), ckpt, y, tokens, prompt, has, file, list, agent)
    case x <> y <> +more 3n:
      cli.go(more, cli.flag.of(more), ckpt, tok, y, prompt, has, file, list, agent)
    case x <> y <> +more 4n:
      cli.go(more, cli.flag.of(more), ckpt, tok, tokens, y, True{}, file, list, agent)
    case x <> y <> +more 5n:
      cli.go(more, cli.flag.of(more), ckpt, tok, tokens, prompt, has, y, list, agent)
    case x <> +more 6n:
      cli.go(more, cli.flag.of(more), ckpt, tok, tokens, prompt, has, file, True{}, agent)
    case x <> more 7n:
      Cli{ckpt, tok, tokens, prompt, has, file, list, True{}, "", False{}, agent}
    case x <> more 8n:
      cli.words(more, ckpt, tok, tokens, prompt, has, file, list, agent)
    case x <> +more 10n:
      cli.go(more, cli.flag.of(more), ckpt, tok, tokens, prompt, has, file, list, True{})
    case x <> more 9n:
      Cli{ckpt, tok, tokens, prompt, has, file, list, False{}, "unknown option " ++ x, True{}, agent}
    case x <> +more 0n:
      cli.go(more, cli.flag.of(more), ckpt, tok, tokens, cli.join(prompt, has, x), True{}, file, list, agent)
    case x <> more _:
      Cli{ckpt, tok, tokens, prompt, has, file, list, False{}, x ++ " needs a value", False{}, agent}
    case _ _:
      Cli{ckpt, tok, tokens, prompt, has, file, list, False{}, "", False{}, agent}

def cli.or(+a: String, +b: String) -> String:
  Bool.pick(String, String.eq(a, ""), b, a)

def cli.die(+msg: String) -> IO(Unit):
  IO.die(Unit, 1, "ana: " ++ msg)

def cli.is.digit(c: Char) -> Bool:
  match c:
    case Chr{+n}:
      Bool.and(U32.is_ge(n, 48), U32.is_le(n, 57))

def cli.all.digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Bool.and(cli.is.digit(c), cli.all.digits(t))

# a non-negative integer: one digit or more
def cli.count.ok(+s: String) -> Bool:
  Bool.and(Bool.not(String.eq(s, "")), cli.all.digits(s))

# Files ------------------------------------------------------------------
#
# A file read to its end a chunk at a time (so a pipe ends at its end, not
# at its first read), or one line of it a byte at a time (the newline not
# kept); then its text, decoded from UTF-8.

type Rd is Type:
  Rd{f: File, acc: List<&2, U32>, line: Bool, done: Bool}

# the end of a line: the input's end, or the newline (a line is read a byte
# at a time, so xs is one byte or none)
def cli.nl(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      U32.is_eq(h, 10)

def cli.rd.got(+line: Bool, +acc: List<&2, U32>, fr: B.Chunk()) -> IO(Rd):
  (f, r) = fr
  do IO<Rd>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, r)
    +end : Bool = Bool.pick(Bool, line, cli.nl(xs), List.is_empty(&2, U32, xs))
    return Rd{f, Bool.pick(List<&2, U32>, Bool.and(line, end), acc, List.append(&2, U32, acc, xs)), line, end}

def cli.rd.step(s: Rd) -> IO(Rd):
  match s:
    case Rd{f, acc, +line, d}:
      do IO<Rd>:
        fr : B.Chunk() <- File.read_bytes(f, Bool.pick(U32, line, 1, 65536))
        cli.rd.got(line, acc, fr)

def cli.rd.go(fuel: Nat, s: Rd) -> IO(Rd):
  match fuel s:
    case 1n+k Rd{f, acc, line, False{}}:
      IO.bind(Rd, Rd, cli.rd.step(Rd{f, acc, line, False{}}), cli.rd.go(k))
    case _ s:
      IO.pure(Rd, s)

def cli.rd.fin(s: Rd) -> IO(List<&2, U32>):
  match s:
    case Rd{f, acc, l, d}:
      do IO<List<&2, U32>>:
        File.close(f)
        return acc

def cli.text(+xs: List<&2, U32>) -> String:
  D.dc.Dec.text(Tk.utf8.decode(Nat.add(List.length(&2, U32, xs), 1n), xs, Tk.utf8.mode(xs)))

# a whole file, or its first line, as text
def cli.rd(f: File, +line: Bool) -> IO(String):
  do IO<String>:
    s : Rd <- cli.rd.go(U32.to_nat(4294967295), Rd{f, Nil{}, line, False{}})
    +xs : List<&2, U32> <- cli.rd.fin(s)
    return cli.text(xs)

def cli.read.opened(r: Result<&1, &1, U32 & String, File>, +path: String) -> IO(String):
  match r:
    case Fail{e}:
      IO.die(String, 1, "ana: prompt file not found: " ++ path)
    case Done{f}:
      cli.rd(f, False{})

# the prompt file's text, byte for byte (- is standard input)
def cli.read.file(+path: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, File> <- File.open(Bool.pick(String, String.eq(path, "-"), "/dev/stdin", path), "r")
    cli.read.opened(r, path)

def cli.line.opened(r: Result<&1, &1, U32 & String, File>) -> IO(String):
  match r:
    case Fail{e}:
      IO.pure(String, "")
    case Done{f}:
      cli.rd(f, True{})

# one line of standard input, without its newline
def cli.read.line() -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, File> <- File.open("/dev/stdin", "r")
    cli.line.opened(r)

# Discovery --------------------------------------------------------------

type CkE is Data:
  CkE{mtime: Nat, step: Nat, size: String, date: String, status: String, path: String}

def cli.find.args() -> List<String>:
  ["-L", "run", "-mindepth", "1", "-maxdepth", "4", "-name", "*.checkpoint", "-type", "f",
   "-not", "-path", "*/.*", "-printf", "%T@\t%s\t%TY-%Tm-%Td %TH:%TM\t%p\n"]

def cli.head.digit(+s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{c, t}:
      cli.is.digit(c)

# the leading digits of a string (ok: the head of s is a digit)
def cli.lead.go(s: String, +acc: String, ok: Bool) -> String:
  match s ok:
    case SCon{+c, +t} True{}:
      cli.lead.go(t, acc ++ {SCon{c, SNil{}} : String}, cli.head.digit(t))
    case _ _:
      acc

def cli.lead(+s: String) -> String:
  cli.lead.go(s, "", cli.head.digit(s))

# the digits a "step" at the head of s takes: after one optional "-"
def cli.step.here(+rest: String) -> String:
  Bool.pick(String, Bool.and(String.starts_with(rest, "-"), Bool.not(String.eq(cli.lead(String.drop(rest, 1n)), ""))),
    cli.lead(String.drop(rest, 1n)), cli.lead(rest))

def cli.step.take(+ds: String, +acc: Nat) -> Nat:
  Bool.pick(Nat, String.eq(ds, ""), acc, Maybe.default(&2, Nat, Nat.read(ds), acc))

def cli.step.at(hit: Bool, +rest: String, +acc: Nat) -> Nat:
  match hit:
    case True{}:
      cli.step.take(cli.step.here(rest), acc)
    case False{}:
      acc

# sed -n 's|.*step-\{0,1\}\([0-9]\{1,\}\).*|\1|p': the last match wins
def cli.step.go(s: String, +acc: Nat) -> Nat:
  match s:
    case SNil{}:
      acc
    case SCon{+c, +t}:
      +here = {SCon{c, t} : String}
      cli.step.go(t, cli.step.at(String.starts_with(here, "step"), String.drop(here, 4n), acc))

def cli.step(+s: String) -> Nat:
  cli.step.go(s, 0n)

def cli.magic.str(+s: String) -> String:
  Bool.pick(String, Bool.or(String.eq(s, "FTC2"), String.eq(s, "BTC1")), s, "unreadable")

def cli.magic.res(r: Result<&1, &1, U32 & String, List<&2, U32>>) -> String:
  match r:
    case Done{xs}:
      cli.magic.str(D.dc.bytes.str(xs))
    case Fail{e}:
      "unreadable"

def cli.magic.got(fr: B.Chunk()) -> IO(String):
  (f, r) = fr
  do IO<String>:
    File.close(f)
    return cli.magic.res(r)

def cli.magic.opened(r: Result<&1, &1, U32 & String, File>) -> IO(String):
  match r:
    case Fail{e}:
      IO.pure(String, "unreadable")
    case Done{f}:
      do IO<String>:
        fr : B.Chunk() <- File.read_bytes(f, 4)
        cli.magic.got(fr)

# FTC2, BTC1, or unreadable
def cli.magic(+path: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    cli.magic.opened(r)

def cli.nth(xs: List<&2, String>, +i: Nat) -> String:
  match xs i:
    case x <> more 0n:
      x
    case x <> more 1n+k:
      cli.nth(more, k)
    case _ _:
      ""

def cli.secs(+t: String) -> Nat:
  Maybe.default(&2, Nat, Nat.read(cli.lead(t)), 0n)

# a line of find's: WRITE-TIME TAB SIZE TAB DATE TAB PATH
def cli.entry(+fs: List<&2, String>) -> IO(CkE):
  +path = cli.nth(fs, 3n)
  do IO<CkE>:
    +st : String <- cli.magic(path)
    return CkE{cli.secs(cli.nth(fs, 0n)), cli.step(path), cli.nth(fs, 1n), cli.nth(fs, 2n), st, path}

def cli.entries.add(ok: Bool, +fs: List<&2, String>, es: List<&2, CkE>) -> IO(List<&2, CkE>):
  match ok:
    case True{}:
      do IO<List<&2, CkE>>:
        +e : CkE <- cli.entry(fs)
        return e <> es
    case False{}:
      IO.pure(List<&2, CkE>, es)

def cli.entries(ls: List<&2, String>) -> IO(List<&2, CkE>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, CkE>, Nil{})
    case l <> more:
      +fs = String.split(l, '\t')
      do IO<List<&2, CkE>>:
        es : List<&2, CkE> <- cli.entries(more)
        cli.entries.add(Nat.is_ge(List.length(&2, String, fs), 4n), fs, es)

# newest first, then the higher step, then the path
def cli.le(a: CkE, c: CkE) -> Bool:
  match a c:
    case CkE{+m, +s, z, d, st, +p} CkE{+n, +t, y, e, su, +q}:
      Bool.or(Nat.is_gt(m, n), Bool.and(Nat.is_eq(m, n),
        Bool.or(Nat.is_gt(s, t), Bool.and(Nat.is_eq(s, t), String.is_le(p, q)))))

def cli.found(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> String:
  match r:
    case Done{(code, (out, err))}:
      out
    case Fail{e}:
      ""

# every candidate, ranked
def cli.ranked() -> IO(List<&2, CkE>):
  do IO<List<&2, CkE>>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("find", cli.find.args(), "", 67108864, 600000)
    es : List<&2, CkE> <- cli.entries(String.lines(cli.found(r)))
    return List.sort(~CkE, ~cli.le, es)

# a candidate's path when it is readable, else ""
def cli.readable(e: CkE) -> String:
  match e:
    case CkE{m, s, z, d, +st, +p}:
      Bool.pick(String, String.eq(st, "unreadable"), "", p)

# the newest readable one ("" when there is none)
def cli.newest(es: List<&2, CkE>) -> String:
  match es:
    case Nil{}:
      ""
    case e <> more:
      cli.or(cli.readable(e), cli.newest(more))

def cli.pad.r(+s: String, +w: Nat) -> String:
  s ++ String.repeat(" ", Nat.sub(w, String.length(s)))

def cli.pad.l(+s: String, +w: Nat) -> String:
  String.repeat(" ", Nat.sub(w, String.length(s))) ++ s

# printf '%s %-10s %12s bytes  %s  %s\n' MARK STATUS SIZE DATE PATH
def cli.row(e: CkE, +newest: String) -> String:
  match e:
    case CkE{m, s, +z, +d, +st, +p}:
      Bool.pick(String, String.eq(p, newest), "*", " ") ++ " " ++ cli.pad.r(st, 10n) ++ " " ++ cli.pad.l(z, 12n) ++ " bytes  " ++ d ++ "  " ++ p

def cli.rows(es: List<&2, CkE>, +newest: String) -> IO(Unit):
  match es:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case e <> more:
      do IO<Unit>:
        IO.print(cli.row(e, newest))
        cli.rows(more, newest)

def cli.list.if(none: Bool, +es: List<&2, CkE>) -> IO(Unit):
  match none:
    case True{}:
      cli.die("no checkpoints under run/")
    case False{}:
      cli.rows(es, cli.newest(es))

# --list: every candidate, the chosen one starred
def cli.list() -> IO(Unit):
  do IO<Unit>:
    +es : List<&2, CkE> <- cli.ranked()
    cli.list.if(List.is_empty(&2, CkE, es), es)

# The run ----------------------------------------------------------------

def cli.exists.got(r: Result<&1, &1, U32 & String, File>) -> IO(Bool):
  match r:
    case Fail{e}:
      IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        File.close(f)
        return True{}

def cli.exists(+path: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    cli.exists.got(r)

def cli.prompt.got(empty: Bool, +l: String) -> IO(String):
  match empty:
    case True{}:
      IO.die(String, 1, "ana: no prompt")
    case False{}:
      IO.pure(String, l)

def cli.prompt.env(set: Bool, +text: String, +ckpt: String) -> IO(String):
  match set:
    case True{}:
      IO.pure(String, text)
    case False{}:
      do IO<String>:
        IO.print_err("ana (" ++ ckpt ++ ")\nprompt> ")
        +l : String <- cli.read.line()
        cli.prompt.got(String.eq(l, ""), l)

# the prompt, once the checkpoint is known: the file's, the flags', the
# environment's, else a line of standard input (an empty one stops the run)
def cli.prompt.if(file: Bool, has: Bool, +inenv: Bool, +path: String, +text: String, +ckpt: String) -> IO(String):
  match file has:
    case True{} _:
      cli.read.file(path)
    case False{} True{}:
      IO.pure(String, text)
    case False{} False{}:
      cli.prompt.env(inenv, text, ckpt)

def cli.say(on: Bool, +ckpt: String) -> IO(Unit):
  match on:
    case True{}:
      IO.print_err("ana: " ++ ckpt)
    case False{}:
      IO.pure(Unit, Unit{})

def cli.run(ag: Bool, +ckpt: String, +text: String, +tokens: String, +pinned: String, +t0: Nat) -> IO(Unit):
  match ag:
    case True{}:
      agent(ckpt, text, tokens, pinned, t0)
    case False{}:
      generate(ckpt, text, tokens, pinned, t0)

def cli.gen(+c: Cli, +ckpt: String, +named: Bool, +t0: Nat) -> IO(Unit):
  match c:
    case Cli{ck, +tok, +tokens, +prompt, +has, +file, l, h, b, u, ag}:
      do IO<Unit>:
        +wp : String <- D.dc.env("WIKI_PROMPT", "")
        +pe : String <- D.dc.env("PROMPT", "")
        +wt : String <- D.dc.env("WIKI_TOKENIZER", "")
        +tf : String <- D.dc.env("TOKENIZER_FILE", "")
        +text : String <- cli.prompt.if(Bool.not(String.eq(file, "")), has, Bool.not(String.eq(cli.or(wp, pe), "")), file, Bool.pick(String, has, prompt, cli.or(wp, pe)), ckpt)
        cli.say(named, ckpt)
        cli.run(ag, ckpt, text, tokens, cli.or(tok, cli.or(wt, tf)), t0)

def cli.ckpt.found(ok: Bool, +c: Cli, +ckpt: String, +named: Bool, +t0: Nat) -> IO(Unit):
  match ok:
    case True{}:
      cli.gen(c, ckpt, named, t0)
    case False{}:
      cli.die("checkpoint not found: " ++ ckpt)

def cli.ckpt.newest(none: Bool, +c: Cli, +ckpt: String, +t0: Nat) -> IO(Unit):
  match none:
    case True{}:
      cli.die("no readable checkpoint under run/ (pass --checkpoint)")
    case False{}:
      cli.gen(c, ckpt, True{}, t0)

# the checkpoint: a flag's or WIKI_CHECKPOINT (announced), CKPT (as given),
# else the newest local one (announced)
def cli.ckpt(given: Bool, +c: Cli, +named: String, +ce: String, +t0: Nat) -> IO(Unit):
  match given:
    case True{}:
      do IO<Unit>:
        +path : String = cli.or(named, ce)
        ok : Bool <- cli.exists(path)
        cli.ckpt.found(ok, c, path, Bool.not(String.eq(named, "")), t0)
    case False{}:
      do IO<Unit>:
        +es : List<&2, CkE> <- cli.ranked()
        +n : String = cli.newest(es)
        cli.ckpt.newest(String.eq(n, ""), c, n, t0)

def cli.listed(list: Bool, +c: Cli, +ck: String, +t0: Nat) -> IO(Unit):
  match list:
    case True{}:
      cli.list()
    case False{}:
      do IO<Unit>:
        +wc : String <- D.dc.env("WIKI_CHECKPOINT", "")
        +ce : String <- D.dc.env("CKPT", "")
        cli.ckpt(Bool.not(String.eq(cli.or(ck, cli.or(wc, ce)), "")), c, cli.or(ck, wc), ce, t0)

def cli.counted.c(+c: Cli, +tokens: String, +t0: Nat) -> IO(Unit):
  match c:
    case Cli{+ck, tok, t, +prompt, +has, +file, +list, h, b, u, +ag}:
      cli.listed(list, Cli{ck, tok, tokens, prompt, has, file, list, False{}, "", False{}, ag}, ck, t0)

def cli.counted(ok: Bool, +c: Cli, +tokens: String, +t0: Nat) -> IO(Unit):
  match ok:
    case False{}:
      cli.die("--tokens must be a non-negative integer (got '" ++ tokens ++ "')")
    case True{}:
      cli.counted.c(c, tokens, t0)

def cli.tokens(+c: Cli, +t0: Nat) -> IO(Unit):
  match c:
    case Cli{ck, tok, +tokens, prompt, has, file, list, h, b, u, ag}:
      do IO<Unit>:
        +wt : String <- D.dc.env("WIKI_TOKENS", "")
        +te : String <- D.dc.env("TOKENS", "")
        +n : String = cli.or(tokens, cli.or(wt, cli.or(te, "128")))
        cli.counted(cli.count.ok(n), Cli{ck, tok, tokens, prompt, has, file, list, h, b, u, ag}, n, t0)

def cli.file.there(ok: Bool, +c: Cli, +file: String, +t0: Nat) -> IO(Unit):
  match ok:
    case True{}:
      cli.tokens(c, t0)
    case False{}:
      cli.die("prompt file not found: " ++ file)

def cli.file.check(both: Bool, look: Bool, +c: Cli, +file: String, +t0: Nat) -> IO(Unit):
  match both look:
    case True{} _:
      cli.die("give --prompt (or a trailing prompt) or --prompt-file, not both")
    case False{} True{}:
      do IO<Unit>:
        ok : Bool <- cli.exists(file)
        cli.file.there(ok, c, file, t0)
    case False{} False{}:
      cli.tokens(c, t0)

# a prompt file: there, and not beside another prompt
def cli.file.ok(+c: Cli, +t0: Nat) -> IO(Unit):
  match c:
    case Cli{+ck, +tok, +tokens, +prompt, +has, +file, +list, h, b, u, +ag}:
      cli.file.check(Bool.and(Bool.not(String.eq(file, "")), has), Bool.and(Bool.not(String.eq(file, "")), Bool.not(String.eq(file, "-"))),
        Cli{ck, tok, tokens, prompt, has, file, list, False{}, "", False{}, ag}, file, t0)

def cli.bad(+msg: String, usage: Bool) -> IO(Unit):
  match usage:
    case True{}:
      do IO<Unit>:
        IO.print_err("ana: " ++ msg)
        IO.die(Unit, 1, cli.usage())
    case False{}:
      cli.die(msg)

def cli.start.if(ok: Bool, help: Bool, +c: Cli, +bad: String, +usage: Bool, +t0: Nat) -> IO(Unit):
  match ok help:
    case False{} _:
      cli.bad(bad, usage)
    case True{} True{}:
      IO.print_err(cli.usage())
    case True{} False{}:
      cli.file.ok(c, t0)

def cli.start(+c: Cli, +t0: Nat) -> IO(Unit):
  match c:
    case Cli{+ck, +tok, +tokens, +prompt, +has, +file, +list, +help, +bad, +usage, +ag}:
      cli.start.if(String.eq(bad, ""), help, Cli{ck, tok, tokens, prompt, has, file, list, help, bad, usage, ag}, bad, usage, t0)

def main() -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    argv : List<String> <- IO.args()
    +xs : List<&2, String> = cli.strs(List.tail(&1, String, argv))
    cli.start(cli.go(xs, cli.flag.of(xs), "", "", "", "", False{}, "", False{}, False{}), t0)
