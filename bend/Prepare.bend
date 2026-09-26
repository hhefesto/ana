import Base
import ./Bytes.bend as B
import ./Tokenizer.bend as Tk
import ./Nul.bend as Ns
import ./Ftcc.bend as Fc

# prepare: master's `formal-transformer prepare-bpe-stdin TOKENIZER OUTPUT`
# (Main.hs prepareStdinWith), with the stream in a file instead of stdin
# (Bend reads files, not stdin):
#
#   bend-prepare TOKENIZER INPUT.nul OUTPUT.corpus
#
# Meaning: every (id, text) pair of the NUL stream becomes one document,
# in stream order: the id "curid-" ++ id (its bytes read as Latin-1
# characters), the tokens the BPE encoding of text.  The artifact is FTCC v2
# with master's dataset fingerprint (Ftcc.bend), so a corpus written here is
# byte-identical to master's for the same stream and tokenizer.
#
# Master printed failures and still exited 0; this exits 1 and writes
# nothing on any refusal (an empty id, a duplicate id, an incomplete final
# pair, an empty stream, an unparseable tokenizer).
#
# Run it with `--threads 1`, one process per shard (bend-plan-corpus
# does).  Splitting a shard's documents across the runtime's lanes was
# measured (2026-09-25, 16 cores, a 4,000-document code shard): 23 s wall
# for 41 s of CPU, where one lane takes 41 s, because this allocation-heavy
# work scales to about two cores inside one process; separate processes
# scale with the cores.  A shard of 4,000 code documents (23 MB) takes
# 41 s and 1.2 GB.

def curid() -> List<&2, U32>:
  Tk.str.bytes("curid-")

def encode(+b: Tk.Bpe, ns: List<&2, Ns.Doc>) -> List<&2, Fc.Doc>:
  match ns:
    case Nil{}:
      Nil{}
    case Ns.Doc{i, +t} <> more:
      Fc.Doc{List.append(&2, U32, curid(), i), Tk.Bpe.encode(b, t)} <> encode(b, more)

def any.empty(ns: List<&2, Ns.Doc>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case Ns.Doc{i, t} <> more:
      Bool.or(Nat.is_eq(List.length(&2, U32, i), 0n), any.empty(more))

def ids(ds: List<&2, Fc.Doc>) -> List<&2, String>:
  match ds:
    case Nil{}:
      Nil{}
    case Fc.Doc{i, t} <> more:
      B.Bytes.to_string(i) <> ids(more)

def unique(+ds: List<&2, Fc.Doc>) -> Bool:
  Nat.is_eq(Set.size(Set.from_list(ids(ds))), List.length(&2, Fc.Doc, ds))

def tokens(ds: List<&2, Fc.Doc>) -> Nat:
  match ds:
    case Nil{}:
      0n
    case Fc.Doc{i, t} <> more:
      Nat.add(List.length(&2, U32, t), tokens(more))

def write.go(+out: String, +tok: List<&2, U32>, +ds: List<&2, Fc.Doc>, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "prepare: corpus document IDs must be unique")
    case True{}:
      +dataset = Fc.dataset(tok, ds)
      do IO<Unit>:
        Ns.write(out, Fc.bytes(tok, Tk.str.bytes(dataset), ds))
        IO.print("wrote corpus: " ++ out)
        IO.print("documents: " ++ Nat.show(List.length(&2, Fc.Doc, ds)))
        IO.print("ordinary tokens: " ++ Nat.show(tokens(ds)))
        IO.print("dataset fingerprint: " ++ dataset)

def write(+out: String, +b: Tk.Bpe, +ns: List<&2, Ns.Doc>, bad: Bool, none: Bool) -> IO(Unit):
  match bad none:
    case True{} _:
      IO.die(Unit, 1, "prepare: document id must not be empty")
    case False{} True{}:
      IO.die(Unit, 1, "prepare: no documents (expected NUL-delimited id/text pairs)")
    case False{} False{}:
      +ds = encode(b, ns)
      write.go(out, Tk.str.bytes(Tk.Bpe.identity(b)), ds, unique(ds))

def stream(+out: String, +b: Tk.Bpe, +d: Ns.Docs, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "prepare: " ++ Ns.Docs.problem(d))
    case True{}:
      +ns = Ns.Docs.docs(d)
      write(out, b, ns, any.empty(ns), Nat.is_eq(List.length(&2, Ns.Doc, ns), 0n))

def tokenizer(+out: String, m: Maybe<&2, Tk.Bpe>, +d: Ns.Docs) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "prepare: the tokenizer did not parse")
    case Some{+b}:
      stream(out, b, d, String.is_empty(Ns.Docs.problem(d)))

def run(tok: String, inp: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    tx : List<&2, U32> <- B.Bytes.read_all(tok)
    +xs : List<&2, U32> <- Ns.read(inp)
    tokenizer(out, Tk.Bpe.parse(tx), Ns.docs(xs))

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case tok <> inp <> out <> Nil{}:
      run(tok, inp, out)
    case _:
      IO.die(Unit, 2, "usage: bend-prepare TOKENIZER INPUT.nul OUTPUT.corpus")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args(xs)
