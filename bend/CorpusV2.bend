import Base
import ./Sys.bend as S
import ./Json.bend as J
import ./CorpusV2/Lib.bend as L

# bend-corpus-v2: corpus v2's tools (docs/CORPUS-V2.md), one subcommand each.
#
#   bend-corpus-v2 keys FILE        every record of a JSONL ({"id","text"}) or NUL
#                                   (id, text) file as `id TAB repository TAB path TAB
#                                   content key` lines: the names and keys the other
#                                   tools decide by
#
# Run from the repository root (paths are the repository's).

# A record stream ---------------------------------------------------------------
#
# A JSONL file a line at a time (each line a {"id","text"} object; a line that
# is not one is passed over), or a NUL file a pair at a time.

def c2.is.jsonl(+path: String) -> Bool:
  S.suffix(S.b(path), S.b(".jsonl"))

type C2St is Type:
  C2St{r: S.Rd, jsonl: Bool, n: Nat, eof: Bool}

# keys: one line a record
def c2.keys.line(+id: List<&2, U32>, +text: List<&2, U32>) -> List<&2, U32>:
  L.v2.concat([id, [9], L.v2.repo.of(id), [9], L.v2.path.of(id), [9], S.b(L.v2.key(text)), [10]])

def c2.keys.doc(m: Maybe<&2, J.Doc>) -> List<&2, U32>:
  match m:
    case None{}:
      Nil{}
    case Some{J.Doc{+i, +t}}:
      c2.keys.line(i, t)

# the id field read, the text next (NUL streams)
def c2.keys.text(+j: Bool, +n: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(C2St):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(C2St, C2St{r, j, n, True{}})
    case Some{+t}:
      do IO<C2St>:
        IO.print(S.str(S.chomp(c2.keys.line(id, t))))
        return C2St{r, j, 1n+n, False{}}

def c2.keys.rec(m: Maybe<&2, List<&2, U32>>, jsonl: Bool, r: S.Rd, +n: Nat) -> IO(C2St):
  match m jsonl:
    case None{} j:
      IO.pure(C2St, C2St{r, j, n, True{}})
    case Some{+l} True{}:
      do IO<C2St>:
        IO.print(S.str(S.chomp(c2.keys.doc(J.doc(l)))))
        return C2St{r, True{}, 1n+n, False{}}
    case Some{+i} False{}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, C2St, S.Rd.next(r), c2.keys.text(False{}, n, i))

def c2.keys.got(+jsonl: Bool, +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(C2St):
  (r, m) = x
  c2.keys.rec(m, jsonl, r, n)

def c2.keys.step(s: C2St) -> IO(C2St):
  match s:
    case C2St{r, +j, +n, e}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, C2St, S.Rd.next(r), c2.keys.got(j, n))

def c2.keys.go(fuel: Nat, s: C2St) -> IO(C2St):
  match fuel s:
    case 1n+f C2St{r, j, n, False{}}:
      IO.bind(C2St, C2St, c2.keys.step(C2St{r, j, n, False{}}), c2.keys.go(f))
    case _ C2St{r, j, n, e}:
      IO.pure(C2St, C2St{r, j, n, e})

def c2.keys.fin(s: C2St) -> IO(Unit):
  match s:
    case C2St{r, j, n, e}:
      S.Rd.close(r)

def c2.keys(+path: String) -> IO(Unit):
  do IO<Unit>:
    r : S.Rd <- Bool.pick(IO(S.Rd), c2.is.jsonl(path), S.Rd.lines(path), S.Rd.open(path))
    s : C2St <- c2.keys.go(U32.to_nat(4294967295), C2St{r, c2.is.jsonl(path), 0n, False{}})
    c2.keys.fin(s)

# Main --------------------------------------------------------------------------

def c2.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-corpus-v2 keys FILE")

def c2.args.cmd(is.keys: Bool, xs: List<String>) -> IO(Unit):
  match is.keys xs:
    case True{} p <> more:
      c2.keys(p)
    case _ _:
      c2.usage()

def c2.args(xs: List<String>) -> IO(Unit):
  match xs:
    case c <> more:
      c2.args.cmd(String.eq(c, "keys"), more)
    case _:
      c2.usage()

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    c2.args(xs)
