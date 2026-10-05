import Base
import ./Sys.bend as S
import ./Json.bend as J
import ./CorpusV2/Lib.bend as L
import ./CorpusV2/Holdout.bend as Ho
import ./CorpusV2/Pool.bend as P
import ./CorpusV2/Raw.bend as R
import ./CorpusV2/Combine.bend as Cb
import ./CorpusV2/Eval.bend as Ev
import ./CorpusV2/Steps.bend as St

# bend-corpus-v2: corpus v2's tools (docs/CORPUS-V2.md), one subcommand each,
# ported from the Python they replaced, each byte-identical to it on the
# outputs in run/v2/ (the user, 2026-10-04: no Python in ana). Run from the
# repository root; the tools that fan out re-run this program (argv[0]).
#
#   keys FILE                       id TAB repository TAB path TAB content key, a record a line
#   stream-index [DIR]              repositories each of run 1's streams holds   (CorpusV2/Holdout.bend)
#   vault [DIR]                     the vault: 150 untrained repositories a language
#   holdout [DIR]                   the repository holdout and its exclusion lists
#   exclude IN OUT [DIR]            a JSONL or NUL stream less what v2 holds out
#   pool [OUT]                      run 1's units, one set a language, train/holdout   (CorpusV2/Pool.bend)
#   filler [OUT [RES]]              the transcript windows' filler, each file once
#   raw [OUT [SRC...]]              the raw code, each file once, filtered, shuffled   (CorpusV2/Raw.bend)
#   split-nul SRC PREFIX N          a NUL stream into N shards
#   slice SRC DST K SIZE            slice K of a JSONL file, SIZE bytes, at line ends
#   combine SHARE OUT T R... [--steps N]   one interleaved plan   (CorpusV2/Combine.bend)
#   evalset [--both] [--drop F] [--out F] [N_DIRECT [N_REPAIR]]   E1/E2 prompts   (CorpusV2/Eval.bend)
#   gen CKPT DIR FORMAT [K]         a checkpoint's answers (CPU)
#   control DIR                     every prompt answered with its reference
#   check DIR                       the answers checked in their units; DIR/report.txt
#   credit [MIN]  credit-ok STAGES CREDIT CUR ADD  split-lang SRC OUT  nul-jsonl SRC DST
#   per N TOP  specs-mixnew OUT FILE...  specs-next REPLAY LABEL:COUNT...
#   replay-filler DIR SRC NEW...  drop-repos VAULT SRC DST  insert-stage STAGES LOG AFTER LINE...
#   vault-sample SRC DST            the run scripts' steps   (CorpusV2/Steps.bend)

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
  IO.die(Unit, 2, "usage: bend-corpus-v2 SUBCOMMAND ARGS (see bend/CorpusV2.bend's header)")

# the subcommand's number (a match cannot scrutinize a computed value)
def c2.code(+c: String) -> Nat:
  Bool.pick(Nat, String.eq(c, "keys"), 1n, Bool.pick(Nat, String.eq(c, "stream-index"), 2n, Bool.pick(Nat, String.eq(c, "vault"), 3n,
  Bool.pick(Nat, String.eq(c, "holdout"), 4n, Bool.pick(Nat, String.eq(c, "exclude"), 5n, Bool.pick(Nat, String.eq(c, "ho-part"), 6n,
  Bool.pick(Nat, P.po.is(c), 7n, Bool.pick(Nat, String.eq(c, "raw"), 8n, Bool.pick(Nat, String.eq(c, "split-nul"), 9n,
  Bool.pick(Nat, String.eq(c, "slice"), 10n, Bool.pick(Nat, String.eq(c, "combine"), 11n, Bool.pick(Nat, String.eq(c, "evalset"), 12n,
  Bool.pick(Nat, String.eq(c, "gen"), 13n, Bool.pick(Nat, String.eq(c, "control"), 14n, Bool.pick(Nat, String.eq(c, "check"), 15n,
  Bool.pick(Nat, String.eq(c, "credit"), 16n, Bool.pick(Nat, String.eq(c, "credit-ok"), 17n, Bool.pick(Nat, String.eq(c, "split-lang"), 18n,
  Bool.pick(Nat, String.eq(c, "nul-jsonl"), 19n, Bool.pick(Nat, String.eq(c, "per"), 20n, Bool.pick(Nat, String.eq(c, "specs-mixnew"), 21n,
  Bool.pick(Nat, String.eq(c, "specs-next"), 22n, Bool.pick(Nat, String.eq(c, "replay-filler"), 23n, Bool.pick(Nat, String.eq(c, "drop-repos"), 24n,
  Bool.pick(Nat, String.eq(c, "insert-stage"), 25n, Bool.pick(Nat, String.eq(c, "vault-sample"), 26n, 0n))))))))))))))))))))))))))

def c2.keys.cmd(xs: List<String>) -> IO(Unit):
  match xs:
    case p <> more:
      c2.keys(p)
    case _:
      c2.usage()

def c2.run(k: Nat, +c: String, xs: List<String>) -> IO(Unit):
  match k:
    case 1n:
      c2.keys.cmd(xs)
    case 2n:
      Ho.ho.stream.index(xs)
    case 3n:
      Ho.ho.vault(xs)
    case 4n:
      Ho.ho.holdout(xs)
    case 5n:
      Ho.ho.exclude(xs)
    case 6n:
      Ho.ho.part(xs)
    case 7n:
      P.po.run(c, xs)
    case 8n:
      R.rw.raw(xs)
    case 9n:
      R.rw.split.nul(xs)
    case 10n:
      R.rw.slice(xs)
    case 11n:
      Cb.cb.combine(xs)
    case 12n:
      Ev.ev.evalset(xs)
    case 13n:
      Ev.ev.gen(xs)
    case 14n:
      Ev.ev.control(xs)
    case 15n:
      Ev.ev.check(xs)
    case 16n:
      St.st.credit(xs)
    case 17n:
      St.st.credit.ok(xs)
    case 18n:
      St.st.split.lang(xs)
    case 19n:
      St.st.nul.jsonl(xs)
    case 20n:
      St.st.per(xs)
    case 21n:
      St.st.specs.mixnew(xs)
    case 22n:
      St.st.specs.next(xs)
    case 23n:
      St.st.replay.filler(xs)
    case 24n:
      St.st.drop.repos(xs)
    case 25n:
      St.st.insert.stage(xs)
    case 26n:
      St.st.vault.sample(xs)
    case _:
      c2.usage()

def c2.args(xs: List<String>) -> IO(Unit):
  match xs:
    case +c <> more:
      c2.run(c2.code(c), c, more)
    case _:
      c2.usage()

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    c2.args(xs)
