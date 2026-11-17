import Base
import ../Sys.bend as S
import ../R8.bend as R

# bend-r8 (bend/R8.bend, 2026-11-17): a session's declaration and kind from its id, and the cap's choice.
# Each check prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.
#   bend tests/r8.bend -o /tmp/r8t && /tmp/r8t

type RkCk is Data:
  RkCk{name: String, ok: Bool}

def rk.is(+name: String, +got: List<&2, U32>, +want: String) -> RkCk:
  RkCk{name, S.eq(got, S.b(want))}

def rk.checks() -> List<&2, RkCk>:
  [rk.is("key", R.r8.key(S.b("repo:a__b~p22/bend/core/edit.bend#utf8_step.lead@290/mugen-chain-fill-1")), "repo:a__b~p22/bend/core/edit.bend#utf8_step.lead"),
   rk.is("key-mut", R.r8.key(S.b("mut:own:x/y.bend#f@3/swap-2")), "own:x/y.bend#f"),
   rk.is("key-whole", R.r8.key(S.b("port:lib/Data/List.bend/repair")), "port:lib/Data/List.bend"),
   rk.is("tag", R.r8.tag(S.b("own:x/y.bend#f@3/mugen-fix-miss-repair-0")), "mugen-fix-miss-repair"),
   rk.is("tag-plain", R.r8.tag(S.b("own:x/y.bend#f@3/mugen-fix-miss-direct")), "mugen-fix-miss-direct"),
   RkCk{"giveup", R.r8.giveup(S.b("curated:g/common.bend#a_seed@69/mugen-fix-giveup-2"))},
   RkCk{"not-giveup", Bool.not(R.r8.giveup(S.b("own:x/y.bend#f@3/mugen-fix-miss-direct")))},
   RkCk{"giveup-dropped", Nat.is_eq(R.r8.decide(3n, True{}, True{}, 0n, 0n), 0n)},
   RkCk{"giveup-kept", Nat.is_eq(R.r8.decide(3n, False{}, True{}, 0n, 0n), 2n)},
   RkCk{"first-out", Nat.is_eq(R.r8.decide(3n, True{}, False{}, 0n, 0n), 2n)},
   RkCk{"second-same-kind-out", Nat.is_eq(R.r8.decide(3n, True{}, False{}, 1n, 1n), 2n)},
   RkCk{"third-same-kind-capped", Nat.is_eq(R.r8.decide(3n, True{}, False{}, 2n, 2n), 1n)},
   RkCk{"third-new-kind-out", Nat.is_eq(R.r8.decide(3n, True{}, False{}, 2n, 0n), 2n)},
   RkCk{"fourth-capped", Nat.is_eq(R.r8.decide(3n, True{}, False{}, 3n, 0n), 1n)}]

def rk.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "r8: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def rk.say(cs: List<&2, RkCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      rk.end(Nat.is_eq(bad, 0n), bad, names)
    case RkCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        rk.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def main() -> IO(Unit):
  rk.say(rk.checks(), 0n, "")
