import Base
import ../CorpusV2/MugenLog.bend as Mlg

# bend-corpus-v2 mugenlog alone (CorpusV2/MugenLog.bend), for a build small enough to try a MugenLog change
# while the rest of the box is busy (the whole bend-corpus-v2 takes ~15 min and ~17 GB to build):
#
#   bend tests/mugenlog.bend -o OUT; OUT TOKENIZER IN OUT.nul [WINDOW]
#
# The same arguments as `bend-corpus-v2 mugenlog`.

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    Mlg.ml.main(xs)
