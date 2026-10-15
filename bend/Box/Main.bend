import Base
import ../Sys.bend as S
import ../CorpusV2/Steps.bend as St
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./Vast.bend as Vs
import ./Alert.bend as Al
import ./Lint.bend as Ln

# bend-ops: the box operations, run from this machine (2026-10-14, the plan
# "all logic in Bend, shell only a thin shim"; docs in bend/Box/*.bend).
#
#   bend-ops lint [--tree DIR] [--allow FILE] [--report FILE] [--bend] [--run-since DATE] [-v] [PATH...]
#                       tracked shell stays a thin shim (bend/Box/Lint.bend); exit 1 on a file
#                       with shell logic that tools/lint/shell-allow.txt does not list
#
# Later phases add chain, watch, stage, act, guard, handover, move, evals,
# unit and dense-identity.  The `probe` subcommands run one primitive each,
# for a person checking a box or a fixture by hand:
#
#   bend-ops probe saved LOG          the saves a trainer's log records: `STEP FILE` lines (fp-chain's saved())
#   bend-ops probe sums DIR NAME...   sha256sum's lines for DIR's NAMEs
#   bend-ops probe listed INST        `vastai show instances --raw` on stdin: listed, not listed, unknown
#   bend-ops probe credit MIN         `vastai show user --raw` on stdin: the credit, and `low` when under MIN
#   bend-ops probe which NAME         the first NAME on $PATH
#   bend-ops probe alert LOG MSG      an alert: LOG's line, the notification, ALERT_CMD
#   bend-ops probe ssh HOST PORT CMD  CMD on the box (SSH_OPTS, SSH_TRIES, SSH_RETRY_SLEEP): its status and output

def ops.cks(cs: List<&2, Rm.RmtCk>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> t:
      List.concat(&2, U32, [S.b(Nat.show(Rm.rmt.ck.step(c))), [32], Rm.rmt.ck.file(c), [10], ops.cks(t)])

def ops.names(xs: List<String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.b(x) <> ops.names(t)

def ops.cr.show(c: Vs.VstCr) -> IO(Unit):
  match c:
    case Vs.VstCrOf{t, low}:
      IO.print(S.str(t) ++ Bool.pick(String, low, " low", ""))
    case Vs.VstCrNone{w}:
      IO.die(Unit, 2, "probe credit: " ++ w)

def ops.which.show(m: Maybe<&2, String>, +name: String) -> IO(Unit):
  match m:
    case Some{p}:
      IO.print(p)
    case None{}:
      IO.die(Unit, 1, "probe which: no " ++ name ++ " on $PATH")

def ops.probe(xs: List<String>) -> IO(Unit):
  match xs:
    case "saved" <> path <> Nil{}:
      do IO<Unit>:
        +t : List<&2, U32> <- S.read(path)
        IO.write(S.str(ops.cks(Rm.rmt.saved.of(t))))
    case "sums" <> +dir <> names:
      do IO<Unit>:
        ss : List<&2, Lc.LclSum> <- Lc.lcl.sums(dir, ops.names(names))
        IO.write(S.str(Lc.lcl.sha.text(ss)))
    case "listed" <> +inst <> Nil{}:
      do IO<Unit>:
        +j : List<&2, U32> <- S.read("/dev/stdin")
        IO.print(Vs.vst.ls.show(Vs.vst.listed.of(j, inst)))
    case "credit" <> +min <> Nil{}:
      do IO<Unit>:
        +j : List<&2, U32> <- S.read("/dev/stdin")
        ops.cr.show(Vs.vst.credit.of(j, min))
    case "which" <> +name <> Nil{}:
      do IO<Unit>:
        m : Maybe<&2, String> <- S.which(name)
        ops.which.show(m, name)
    case "alert" <> +log <> +msg <> Nil{}:
      Al.alr.alert(log, "ana box", msg)
    case "ssh" <> +host <> +port <> +cmd <> Nil{}:
      do IO<Unit>:
        +b : Rm.RmtBox <- Rm.rmt.box(host, port)
        +o : Lc.LclOut <- Rm.rmt.ssh(b, 600, cmd)
        IO.write(S.str(Lc.lcl.out(o)))
        IO.print_err("status " ++ U32.show(Lc.lcl.status(o)))
    case _:
      IO.die(Unit, 2, "usage: bend-ops probe saved LOG | sums DIR NAME... | listed INST | credit MIN | which NAME | alert LOG MSG | ssh HOST PORT CMD")

def ops.usage() -> String:
  "usage: bend-ops lint [--tree DIR] [--allow FILE] [--report FILE] [--bend] [--run-since DATE] [-v] [PATH...]\n"
    ++ "       bend-ops probe saved LOG | sums DIR NAME... | listed INST | credit MIN | which NAME | alert LOG MSG | ssh HOST PORT CMD"

def ops.args(xs: List<String>) -> IO(Unit):
  match xs:
    case "lint" <> rest:
      Ln.lnt.main(rest)
    case "probe" <> rest:
      ops.probe(rest)
    case _:
      IO.die(Unit, 2, ops.usage())

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    ops.args(List.tail(&1, String, argv))
