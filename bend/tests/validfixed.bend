import Base
import ../Train.bend as Tr
import ../TrainDense.bend as T

# R7's fixed validation set read as TrainDense reads VALID_CORPUS (T.valid.fixed), on the CPU, before a GPU
# first does (docs/r7/PLAN.md, change 8): the corpus's magic (FTCC) and tokenizer identity against
# TOKENIZER_FILE's, and its first EVALS windows at fp100m's context (2,048).  It prints TrainDense's own
# "validation: N fixed windows of PATH" line, the one run/v9/run7go.sh waits for in r7.log.
#   VALID_CORPUS=run/v9/R7valid/shard-0-fp100m.corpus TOKENIZER_FILE=weights/code32k.bpe bend bend/tests/validfixed.bend

def vf.go(+vp: String, +tokf: String, +tb: List<&2, U32>, +evals: Nat) -> IO(Unit):
  do IO<Unit>:
    vw : List<&2, List<&2, U32>> <- T.valid.fixed(vp, 2048n, evals, Tr.Tok.id(Tr.tok.of(tokf, tb)), Nil{})
    T.say("validfixed: " ++ Nat.show(List.length(&2, List<&2, U32>, vw)) ++ " windows read")

def main() -> IO(Unit):
  do IO<Unit>:
    +vp : String <- Tr.env("VALID_CORPUS", "")
    +tokf : String <- Tr.env("TOKENIZER_FILE", "weights/code32k.bpe")
    +tb : List<&2, U32> <- Tr.tok.read(tokf)
    vf.go(vp, tokf, tb, 64n)
