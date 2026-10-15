import Base
import ../Sys.bend as S
import ../CorpusV2/Steps.bend as St
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./Vast.bend as Vs
import ./Alert.bend as Al
import ./Lint.bend as Ln
import ./Chain.bend as Ch
import ./Watch.bend as Wt
import ./Scenario.bend as Sc
import ./Stage.bend as Sg
import ./Drive.bend as Dr
import ./Evals.bend as Ev
import ./Act.bend as Ac

# bend-ops: the box operations, run from this machine (2026-10-14, the plan
# "all logic in Bend, shell only a thin shim"; docs in bend/Box/*.bend).
#
#   bend-ops lint [--tree DIR] [--allow FILE] [--report FILE] [--bend] [--run-since DATE] [-v] [PATH...]
#                       tracked shell stays a thin shim (bend/Box/Lint.bend); exit 1 on a file
#                       with shell logic that tools/lint/shell-allow.txt does not list
#                       (and, with --bend, on an sh -c string with logic in Bend)
#   bend-ops chain HOST PORT INSTANCE DEST STAGES
#                       a chain of stages on one box, then the scores, the pulls, the sha256
#                       check and the DESTROY (bend/Box/Chain.bend; fp-chain.sh's port)
#   bend-ops watch HOST PORT DEST [MIN]
#                       the credit and the box under a chain (bend/Box/Watch.bend; credit-watch.sh's)
#   bend-ops sim N DIR | sim all DIR | sim soak DIR SECONDS
#                       the chain and the watch against a box in a sandbox (bend-sim's ssh,
#                       rsync, vastai, ...), old scripts against new (bend/Box/Scenario.bend)
#   bend-ops stage box HOST PORT | push NAME RUN HOST PORT | restage HOST PORT CKPT STAGE... | shards PLAN
#                       a run onto a box (bend/Box/Stage.bend: fp-stage.sh, next-stage.sh push,
#                       fp-restage.sh); bend-box, the driver on the box, is built there from box.c
#   bend-ops dense-identity OUT_DIR [TRAINER]
#                       the dense trainer's six-step trajectories as bytes (dense-identity.sh)
#   bend-ops stage next | stage raw mix|mixnew FILE...|build K|push K HOST PORT
#                       a stage built here (bend/Box/Drive.bend: next-stage.sh build, raw-stage.sh)
#   bend-ops feed HOST PORT STAGES [FIRST] [LAST]
#                       raw slices built, credit-guarded, pushed and appended to STAGES (raw-driver.sh)
#   bend-ops evals CFG  a run's evals from a tracked config (tools/evals/run3.cfg), skipping
#                       what is done, then paired by prompt with exact McNemar (bend/Box/Evals.bend:
#                       eval-run3.sh, eval-run2.sh)
#   bend-ops act setup|ckpt|check|start|pull|ensure HOST PORT ... | --dry-run OUT | procs NPROC [CPU_MAX]
#                       ana's act rounds on a box (bend/Box/Act.bend: act-box.sh, act-restart.sh)
#
# Later phases add guard, handover, move and unit.  The `probe`
# subcommands run one primitive each,
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
    ++ "       bend-ops chain HOST PORT INSTANCE DEST STAGES\n"
    ++ "       bend-ops watch HOST PORT DEST [MIN]\n"
    ++ "       bend-ops sim N DIR | sim all DIR | sim soak DIR SECONDS\n"
    ++ "       bend-ops probe saved LOG | sums DIR NAME... | listed INST | credit MIN | which NAME | alert LOG MSG | ssh HOST PORT CMD\n"
    ++ "       bend-ops stage box HOST PORT | push NAME RUN HOST PORT | restage HOST PORT CKPT STAGE... | shards PLAN\n"
    ++ "       bend-ops dense-identity OUT_DIR [TRAINER]\n"
    ++ "       bend-ops stage next | stage raw mix|mixnew FILE...|build K|push K HOST PORT | feed HOST PORT STAGES [FIRST] [LAST]\n"
    ++ "       bend-ops evals CFG\n"
    ++ "       bend-ops act setup|ckpt|check|start|pull|ensure HOST PORT ... | --dry-run OUT | procs NPROC [CPU_MAX]"

def ops.args(xs: List<String>) -> IO(Unit):
  match xs:
    case "lint" <> rest:
      Ln.lnt.main(rest)
    case "chain" <> rest:
      Ch.chn.main(rest)
    case "watch" <> rest:
      Wt.cwt.main(rest)
    case "probe" <> rest:
      ops.probe(rest)
    case "stage" <> "next" <> Nil{}:
      Dr.drv.next()
    case "stage" <> "raw" <> rest:
      Dr.drv.raw.main(rest)
    case "feed" <> rest:
      Dr.drv.feed.args(rest)
    case "evals" <> rest:
      Ev.evr.main(rest)
    case "stage" <> rest:
      Sg.stg.main(rest)
    case "dense-identity" <> rest:
      Sg.stg.ident.main(rest)
    case "act" <> rest:
      Ac.acb.main(rest)
    case _:
      IO.die(Unit, 2, ops.usage())

# `sim` needs argv[0]: the chain it tests is this same binary
def ops.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +a0 <> "sim" <> rest:
      Sc.scn.main(a0, rest)
    case a0 <> rest:
      ops.args(rest)
    case Nil{}:
      IO.die(Unit, 2, ops.usage())

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    ops.main(argv)
