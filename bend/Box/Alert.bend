import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Local.bend as Lc

# Alert: the chain's log and what a person must see (2026-10-14, the plan's
# Phase 0).
#
#   alr.log LOG MSG           `[YYYY-MM-DD HH:MM:SS UTC-6] MSG` appended to LOG (chain.log) and on
#                             stderr (flushed line by line, unlike IO.print), as fp-chain.sh's
#                             log() teed it
#   alr.alert LOG TITLE MSG   alr.log's `ALERT: MSG`, then a desktop notification that stays up
#                             until dismissed (notify-send -u critical TITLE MSG), then ALERT_CMD
#                             when it is set: `sh -c "$ALERT_CMD" _ MSG` (e.g. a phone push).  A
#                             notification or ALERT_CMD that fails is passed over: the log line
#                             is the alert that always lands.
#
# Every name starts with `alr.`.

# a log line for the wall-clock time ms (Clock.stamp: UTC-6, no DST)
def alr.line(+ms: Nat, +msg: String) -> String:
  Ck.stamp(ms) ++ " " ++ msg

def alr.log(+path: String, +msg: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- Ck.ck.wall()
    +l : String = alr.line(t, msg)
    S.add(path, S.b(l ++ "\n"))
    IO.print_err(l)

def alr.cmd(has: Bool, +cmd: String, +msg: String) -> IO(Unit):
  match has:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        o : Lc.LclOut <- Lc.lcl.run(120, "sh", ["-c", cmd, "_", msg])
        return Unit{}

def alr.alert(+path: String, +title: String, +msg: String) -> IO(Unit):
  do IO<Unit>:
    alr.log(path, "ALERT: " ++ msg)
    n : Lc.LclOut <- Lc.lcl.run(30, "notify-send", ["-u", "critical", title, msg])
    +cmd : String <- S.env("ALERT_CMD", "")
    alr.cmd(Bool.not(String.is_empty(cmd)), cmd, msg)
