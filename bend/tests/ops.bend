import Base
import ../Sys.bend as S
import ../CorpusV2/Steps.bend as St
import ../Box/Local.bend as Lc
import ../Box/Remote.bend as Rm
import ../Box/Vast.bend as Vs
import ../Box/Alert.bend as Al
import ../Box/Lint.bend as Ln

# bend-ops' primitives (bend/Box, 2026-10-14) on real files: run 3's
# chain.log, sha256 listings and a trainer's log (fixtures/ops, excerpts of
# run/v3/run3), a real `vastai show user --raw` (its secrets replaced) and a
# listing in vast's --raw shape; the lint's rules on small scripts and a
# flake; st.f.floor; the processes.  Each check prints `ok NAME` or `FAIL
# NAME`; any FAIL exits 1 (the decision is here, not in the flake's shell).
# Run from bend/tests (the fixtures are read relative to it).

type OpsCk is Data:
  OpsCk{name: String, ok: Bool}

def ops.t.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "ops: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def ops.t.say(cs: List<&2, OpsCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      ops.t.end(Nat.is_eq(bad, 0n), bad, names)
    case OpsCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        ops.t.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

# Helpers -------------------------------------------------------------------------------------

def ops.b(+s: String) -> List<&2, U32>:
  S.b(s)

def ops.names.eq(xs: List<&2, List<&2, U32>>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(S.eq(x, S.b(y)), ops.names.eq(xt, yt))
    case _ _:
      False{}

def ops.cks.eq(cs: List<&2, Rm.RmtCk>, ys: List<&2, String>) -> Bool:
  ops.names.eq(Rm.rmt.ck.files(cs), ys)

def ops.steps(cs: List<&2, Rm.RmtCk>) -> List<&2, Nat>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Rm.rmt.ck.step(c) <> ops.steps(t)

def ops.nats.eq(xs: List<&2, Nat>, ys: List<&2, Nat>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(Nat.is_eq(x, y), ops.nats.eq(xt, yt))
    case _ _:
      False{}

def ops.sum.names(ss: List<&2, Lc.LclSum>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      Lc.lcl.sum.name(s) <> ops.sum.names(t)

# a listing with its k-th line's sha256 changed (its first digit; k from 1)
def ops.sha.flip(ss: List<&2, Lc.LclSum>, +k: Nat) -> List<&2, Lc.LclSum>:
  match ss:
    case Nil{}:
      Nil{}
    case Lc.LclSum{+h, n} <> t:
      Lc.LclSum{Bool.pick(List<&2, U32>, Nat.is_eq(k, 1n), 48 <> List.drop(&2, U32, h, 1n), h), n} <> ops.sha.flip(t, Nat.sub(k, 1n))

def ops.tok.is(m: Maybe<&2, St.StTk>, +want: String) -> Bool:
  match m:
    case Some{t}:
      S.eq(St.st.js.text(t), S.b(want))
    case None{}:
      False{}

def ops.tok.p(m: Maybe<&2, St.StTk>, +c: U32) -> Bool:
  match m:
    case Some{St.StTkP{d}}:
      U32.is_eq(c, d)
    case _:
      False{}

def ops.vals(m: Maybe<&2, List<&2, St.StJv>>) -> List<&2, St.StJv>:
  Maybe.default(&2, List<&2, St.StJv>, m, Nil{})

def ops.parses(+json: String) -> Bool:
  Maybe.is_some(&2, List<&2, St.StJv>, St.st.js.values(S.b(json)))

def ops.k(+s: String) -> St.StJk:
  St.StJkK{S.b(s)}

def ops.ls.is(l: Vs.VstLs, +want: Nat) -> Bool:
  match l:
    case Vs.VstLsYes{}:
      Nat.is_eq(want, 0n)
    case Vs.VstLsNo{}:
      Nat.is_eq(want, 1n)
    case Vs.VstLsUnknown{w}:
      Nat.is_eq(want, 2n)

def ops.cr.is(c: Vs.VstCr, +want: String, +low: Bool) -> Bool:
  match c:
    case Vs.VstCrOf{t, l}:
      Bool.and(S.eq(t, S.b(want)), Bool.not(Bool.xor(l, low)))
    case Vs.VstCrNone{w}:
      False{}

def ops.cr.none(c: Vs.VstCr) -> Bool:
  match c:
    case Vs.VstCrOf{t, l}:
      False{}
    case Vs.VstCrNone{w}:
      True{}

def ops.floor.of(m: Maybe<&2, St.StF>, +want: String) -> Bool:
  match m:
    case Some{+f}:
      String.eq(St.st.f.fixed(St.st.f.floor(f), 1n), want)
    case None{}:
      False{}

def ops.floor(+x: String, +want: String) -> Bool:
  ops.floor.of(St.st.f.read(S.b(x)), want)

# Lint helpers ------------------------------------------------------------------------------

def ops.rep.probs(r: Ln.LnRep) -> List<&2, String>:
  match r:
    case Ln.LnRep{n, u, ps}:
      ps

def ops.rep.unwired(r: Ln.LnRep) -> Bool:
  match r:
    case Ln.LnRep{n, u, ps}:
      u

def ops.lint(+text: String) -> List<&2, String>:
  ops.rep.probs(Ln.lnt.check.sh("t.sh", S.b(text)))

def ops.lint.unwired(+text: String) -> Bool:
  ops.rep.unwired(Ln.lnt.check.sh("t.sh", S.b(text)))

def ops.has(ps: List<&2, String>, +frag: String) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> t:
      Bool.or(S.infix(S.b(p), S.b(frag)), ops.has(t, frag))

def ops.len(ps: List<&2, String>) -> Nat:
  List.length(&2, String, ps)

def ops.lint.only(+text: String, +frag: String) -> Bool:
  +ps = ops.lint(text)
  Bool.and(ops.has(ps, frag), Nat.is_ne(ops.len(ps), 0n))

def ops.reps.names(rs: List<&2, Ln.LnRep>) -> List<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      Nil{}
    case Ln.LnRep{n, u, ps} <> t:
      S.b(n) <> ops.reps.names(t)

def ops.reps.probs(rs: List<&2, Ln.LnRep>, +name: String) -> List<&2, String>:
  match rs:
    case Nil{}:
      ["no such body"]
    case Ln.LnRep{+n, u, ps} <> t:
      Bool.pick(List<&2, String>, String.eq(n, name), ps, ops.reps.probs(t, name))

# The lint's flake.nix and Bend inputs are fixtures (fixtures/ops/lint-*.txt,
# 2026-10-15): shell text in this file's strings would be what --bend reads.

# a flake body's problems: one holds frag; there are none
def ops.body.has(+fk: List<&2, Ln.LnRep>, +name: String, +frag: String) -> Bool:
  ops.has(ops.reps.probs(fk, "flake.nix:" ++ name), frag)

def ops.body.ok(+fk: List<&2, Ln.LnRep>, +name: String) -> Bool:
  Nat.is_eq(ops.len(ops.reps.probs(fk, "flake.nix:" ++ name)), 0n)

def ops.bend.probs(+path: String, +xs: List<&2, U32>) -> List<&2, String>:
  Ln.lnt.bend.lines(path, Ln.lnt.number(S.split.lines(xs), 1n))

# Checks ------------------------------------------------------------------------------------

# the flake-body rule (2026-10-15) and --bend (strict since then), on fixtures
def ops.lint2(+flake2: List<&2, U32>, +lb: List<&2, U32>, +ls: List<&2, U32>) -> List<&2, OpsCk>:
  +fk = Ln.lnt.check.flake("flake.nix", flake2)
  +bp = ops.bend.probs("x.bend", lb)
  +sp = ops.bend.probs("bend/Sys.bend", ls)
  +xp = ops.bend.probs("x.bend", ls)
  [OpsCk{"lint flake body: plain commands pass, no line cap", Bool.and(ops.body.ok(fk, "good"),
     Nat.is_lt(12n, List.length(&2, Ln.LnSm, Ln.lnt.stmts(Ln.lnt.join(Ln.lnt.number(S.split.lines(flake2), 1n))))))},
   OpsCk{"lint flake body: && || ; fail", Bool.and(Bool.and(ops.body.has(fk, "and", "&&"), ops.body.has(fk, "or", "||")), ops.body.has(fk, "semi", "; (one"))},
   OpsCk{"lint flake body: subshell $( backtick heredoc background fail", Bool.and(Bool.and(Bool.and(ops.body.has(fk, "sub", "( (a subshell"), ops.body.has(fk, "cmdsub", "$( )")),
     Bool.and(ops.body.has(fk, "tick", "backtick"), ops.body.has(fk, "heredoc", "a heredoc"))), ops.body.has(fk, "bg", "a background job"))},
   OpsCk{"lint flake body: control words, tests and pipes fail", Bool.and(Bool.and(Bool.and(ops.body.has(fk, "if", "a control word: if"), ops.body.has(fk, "while", "a control word: done")),
     ops.body.has(fk, "test", "a test: [")), ops.body.has(fk, "pipe", "a pipe"))},
   OpsCk{"lint flake body: text tools fail, after env and exec too", Bool.and(Bool.and(ops.body.has(fk, "tool", "a text tool: sort"),
     ops.body.has(fk, "envtool", "a text tool after an assignment or wrapper: awk")), ops.body.has(fk, "exectool", "a text tool after exec: grep"))},
   OpsCk{"lint flake body: one final exec", ops.body.has(fk, "midexec", "flake.nix:67: exec before the last line")},
   OpsCk{"lint .sh keeps its rule (cp, mkdir, touch fail; 12 lines)", Bool.and(Bool.and(ops.lint.only("cp -r x fixtures\n", "a command other than"),
     ops.lint.only("mkdir -p $out/bin\n", "a command other than")), Bool.and(ops.lint.only("touch $out\n", "a command other than"), ops.lint.only(String.repeat("cd x\n", 13n), "13 lines of code")))},
   OpsCk{"lint --bend flags what a line hands sh (joined by ++)", Bool.and(Nat.is_eq(ops.len(bp), 4n),
     Bool.and(Bool.and(ops.has(bp, "x.bend:6: ; (one"), ops.has(bp, "x.bend:7: ; (one")), Bool.and(ops.has(bp, "x.bend:9: a pipe"), ops.has(bp, "x.bend:13: ; (one"))))},
   OpsCk{"lint --bend: Sys.bend's fixed exec lines exempt by def", Bool.and(Bool.and(Nat.is_eq(ops.len(sp), 1n), ops.has(sp, "bend/Sys.bend:11: &&")),
     Nat.is_eq(ops.len(xp), 4n))}]

def ops.pure(+box: List<&2, U32>, +here: List<&2, U32>, +s2: List<&2, U32>, +chain: List<&2, U32>, +user: List<&2, U32>, +inst: List<&2, U32>, +err: List<&2, U32>, +flake: List<&2, U32>) -> List<&2, OpsCk>:
  +bs = Lc.lcl.sha.parse(box)
  +hs = Lc.lcl.sha.parse(here)
  +saved = Rm.rmt.saved.of(s2)
  +pulled = Lc.lcl.pulled.of(chain)
  +uv = ops.vals(St.st.js.values(user))
  +iv = ops.vals(St.st.js.values(inst))
  +ms = Nat.mul(U32.to_nat(1791956915), U32.to_nat(1000))
  +fk = Ln.lnt.check.flake("flake.nix", flake)
  [OpsCk{"sha parse (13 on the box, 15 here)", Bool.and(Nat.is_eq(List.length(&2, Lc.LclSum, bs), 13n), Nat.is_eq(List.length(&2, Lc.LclSum, hs), 15n))},
   OpsCk{"sha text round trip", Bool.and(S.eq(Lc.lcl.sha.text(bs), box), S.eq(Lc.lcl.sha.text(hs), here))},
   OpsCk{"sha verify (run 3: every box checkpoint here)", Nat.is_eq(List.length(&2, List<&2, U32>, Lc.lcl.sha.unmatched(bs, hs)), 0n)},
   OpsCk{"sha verify (one differs)", ops.names.eq(Lc.lcl.sha.unmatched(ops.sha.flip(bs, 5n), hs), ["s1-step30000.checkpoint"])},
   OpsCk{"sha verify (one missing here)", ops.names.eq(Lc.lcl.sha.unmatched(bs, List.drop(&2, Lc.LclSum, hs, 1n)), ["s1-step10000.checkpoint"])},
   OpsCk{"sha of", S.eq(Maybe.default(&2, List<&2, U32>, Lc.lcl.sha.of(hs, S.b("s2-step56725.checkpoint")), Nil{}),
     S.b("e9cea4edc818ae6e063a3a0e87039479df81a1dfbfda5efd9bece3919ebb31b3"))},
   OpsCk{"sha paths and banner", ops.names.eq(ops.sum.names(Lc.lcl.sha.parse(S.b("Welcome to vast.ai. Have fun!\n633e5a847b17918dd4f5c0087df53950677c73f4b484dcc5f4fe25da5394860d  formalTransformer/out/s2-step40000.checkpoint\nsha256sum: x: No such file\n"))),
     ["s2-step40000.checkpoint"])},
   OpsCk{"saved (s2.log)", ops.cks.eq(saved, ["s2-step37000.checkpoint", "s2-step37500.checkpoint", "s2-step56725.checkpoint"])},
   OpsCk{"saved steps", ops.nats.eq(ops.steps(saved), [U32.to_nat(37000), U32.to_nat(37500), U32.to_nat(56725)])},
   OpsCk{"saved every 500", ops.cks.eq(Rm.rmt.ck.every(saved, U32.to_nat(500)), ["s2-step37000.checkpoint", "s2-step37500.checkpoint"])},
   OpsCk{"saved every 0", Nat.is_eq(List.length(&2, Rm.RmtCk, Rm.rmt.ck.every(saved, 0n)), 0n)},
   OpsCk{"saved as sed sees it", ops.cks.eq(Rm.rmt.saved.of(S.b("x saved out/a-step3.checkpoint saved out/b-step10.checkpoint.x.checkpoint (1 ms)\nsaved out/c-stepx.checkpoint\nsaved out/a-step2.checkpoint")),
     ["a-step2.checkpoint", "a-step3.checkpoint"])},
   OpsCk{"pulled (chain.log: 13, as the box held)", Bool.and(Nat.is_eq(List.length(&2, List<&2, U32>, pulled), 13n),
     ops.names.eq(Lc.lcl.sort(pulled), ["s1-step10000.checkpoint", "s1-step15000.checkpoint", "s1-step20000.checkpoint", "s1-step25000.checkpoint",
       "s1-step30000.checkpoint", "s1-step35000.checkpoint", "s1-step36696.checkpoint", "s1-step5000.checkpoint", "s2-step40000.checkpoint",
       "s2-step45000.checkpoint", "s2-step50000.checkpoint", "s2-step55000.checkpoint", "s2-step56725.checkpoint"]))},
   OpsCk{"pulled = the box's names", S.eq(S.join(Lc.lcl.sort(pulled), 10), S.join(Lc.lcl.sort(ops.sum.names(bs)), 10))},
   OpsCk{"log line (chain.log's destroy)", Bool.and(String.eq(Al.alr.line(ms, "destroy instance 55567872"), "[2026-10-13 23:48:35 UTC-6] destroy instance 55567872"),
     S.infix(chain, S.b("\n[2026-10-13 23:48:35 UTC-6] destroy instance 55567872\n")))},
   OpsCk{"marker line", S.eq(Lc.lcl.mark.line(ms, "DESTROYED"), S.b("[2026-10-13 23:48:35 UTC-6] DESTROYED\n"))},
   OpsCk{"epoch", Nat.is_eq(Maybe.default(&2, Nat, Lc.lcl.epoch.of(S.b("1791956915\n")), 0n), U32.to_nat(1791956915))},
   OpsCk{"banner", S.eq(Rm.rmt.unbanner(S.b("Welcome to vast.ai. Have fun!\nabc\nHave fun!\ndef\n")), S.b("abc\ndef\n"))},
   OpsCk{"quote", String.eq(Rm.rmt.q("it's"), "'it'\\''s'")},
   OpsCk{"ssh retry rule", Bool.and(Bool.and(Rm.rmt.again(255, 1n, 10n), Bool.not(Rm.rmt.again(255, 10n, 10n))),
     Bool.and(Bool.not(Rm.rmt.again(1, 1n, 10n)), Bool.not(Rm.rmt.again(0, 1n, 10n))))},
   OpsCk{"stat answer", Nat.is_eq(Lc.lcl.st.size(Maybe.default(&2, Lc.LclSt, Lc.lcl.stat.of(Lc.LclOut{0, S.b("1407 1791956915\n"), Nil{}}), Lc.LclSt{0n, 0n})), U32.to_nat(1407))},
   OpsCk{"json user", Bool.and(ops.tok.is(St.st.js.at(uv, [ops.k("credit")]), "1.5924896101989248"),
     ops.tok.is(St.st.js.at(uv, [ops.k("total_spend")]), "-138.40751038980108"))},
   OpsCk{"json depth", Bool.and(ops.tok.p(St.st.js.at(uv, [ops.k("rights"), ops.k("api"), ops.k("*"), ops.k("api.auth.apikeys"), ops.k("GET")]), 123),
     ops.tok.is(St.st.js.at(uv, [ops.k("balance_threshold_enabled")]), "true"))},
   OpsCk{"json instances", Bool.and(Bool.and(ops.tok.is(Vs.vst.field(iv, "55567872", "ssh_port"), "27872"), ops.tok.is(Vs.vst.field(iv, "55552041", "ssh_host"), "ssh2.vast.ai")),
     ops.tok.is(St.st.js.at(iv, [St.StJkI{0n}, ops.k("ports"), ops.k("22/tcp"), St.StJkI{0n}, ops.k("HostPort")]), "27872"))},
   OpsCk{"json escapes", Bool.and(ops.tok.is(St.st.js.at(iv, [St.StJkI{0n}, ops.k("onstart")]), "env | grep _ >> /etc/environment; echo \\\"starting up\\\"\\n"),
     ops.tok.p(St.st.js.at(iv, [St.StJkI{1n}, ops.k("ports")]), 123))},
   OpsCk{"json refuses", Bool.and(Bool.and(Bool.and(Bool.not(ops.parses("{\"a\" 1}")), Bool.not(ops.parses("{\"a\": 1,}"))), Bool.and(Bool.not(ops.parses("[1 2]")), Bool.not(ops.parses("{\"a\": tru}")))),
     Bool.and(Bool.and(Bool.not(ops.parses("{\"a\": 1} x")), Bool.not(ops.parses(""))), Bool.and(Bool.not(ops.parses("[1, 2")), Bool.not(ops.parses("]")))))},
   OpsCk{"json takes", Bool.and(Bool.and(ops.parses("[]"), ops.parses(" {\"a\": [1, -2.5e3, NaN, null, {}], \"b\": {\"c\": \"d\"}}\n")), ops.parses("[{\"id\": 1}, {\"id\": 2}]"))},
   OpsCk{"credit", Bool.and(Bool.and(ops.cr.is(Vs.vst.credit.of(user, "1.00"), "1.5924896101989248", False{}), ops.cr.is(Vs.vst.credit.of(user, "2"), "1.5924896101989248", True{})),
     Bool.and(ops.cr.none(Vs.vst.credit.of(err, "1.00")), ops.cr.none(Vs.vst.credit.of(user, "x"))))},
   OpsCk{"listed", Bool.and(Bool.and(ops.ls.is(Vs.vst.listed.of(inst, "55567872"), 0n), ops.ls.is(Vs.vst.listed.of(inst, "55552041"), 0n)),
     Bool.and(ops.ls.is(Vs.vst.listed.of(inst, "9999"), 1n), ops.ls.is(Vs.vst.listed.of(inst, "5556787"), 1n)))},
   OpsCk{"listed unknown", Bool.and(Bool.and(ops.ls.is(Vs.vst.listed.of(err, "55567872"), 2n), ops.ls.is(Vs.vst.listed.of(S.b("[]\n"), "55567872"), 1n)),
     Bool.and(ops.ls.is(Vs.vst.listed.of(List.take(&2, U32, inst, 100n), "55567872"), 2n), ops.ls.is(Vs.vst.listed.of(S.b("failed to fetch"), "55567872"), 2n)))},
   OpsCk{"floor", Bool.and(Bool.and(Bool.and(ops.floor("2.5", "2.0"), ops.floor("-2.5", "-3.0")), Bool.and(ops.floor("-0.5", "-1.0"), ops.floor("0.9999", "0.0"))),
     Bool.and(Bool.and(ops.floor("3", "3.0"), ops.floor("4503599627370495.5", "4503599627370495.0")), Bool.and(ops.floor("-1e-300", "-1.0"), ops.floor("101.00000000000001", "101.0"))))},
   OpsCk{"lint shim passes", Nat.is_eq(ops.len(ops.lint("#!/usr/bin/env bash\n# a shim\nset -euo pipefail\nexport A=1 B=\"x y\" C=${C:-3}\ncd \"${DIR:?usage: x DIR}\"\nexec bend-ops lint \"$@\" \"${@:2}\" 2>&1\n")), 0n)},
   OpsCk{"lint if", ops.lint.only("#!/bin/sh\nif [ -f x ]; then\n  echo y\nfi\n", "a control word: if")},
   OpsCk{"lint pipe", ops.lint.only("#!/bin/sh\nexec foo | tee x\n", "a pipe")},
   OpsCk{"lint && || ;", Bool.and(Bool.and(ops.lint.only("cd x && exec y\n", "&&"), ops.lint.only("cd x || exec y\n", "||")), ops.lint.only("cd x; exec y\n", "; (one"))},
   OpsCk{"lint $( and backtick", Bool.and(ops.lint.only("export A=$(date)\n", "$( )"), ops.lint.only("export A=\"`date`\"\n", "backtick"))},
   OpsCk{"lint text tools", Bool.and(Bool.and(ops.lint.only("awk 1 x\n", "a text tool: awk"), ops.lint.only("exec /usr/bin/grep -q x y\n", "a text tool after exec")),
     ops.lint.only("exec env A=1 sed x\n", "a text tool after exec: sed"))},
   OpsCk{"lint tests and functions", Bool.and(Bool.and(ops.lint.only("[ -f x ]\n", "a test: ["), ops.lint.only("test -f x\n", "a test: test")), ops.lint.only("f() {\n  exec x\n}\n", "( (a subshell"))},
   OpsCk{"lint expansions", Bool.and(Bool.and(ops.lint.only("export A=${B#x}\n", "a parameter expansion"), ops.lint.only("export A=${#B}\n", "a parameter expansion")),
     Nat.is_eq(ops.len(ops.lint("export A=${B-x} C=${D?no} E=${1:-y} F=$G\n")), 0n))},
   OpsCk{"lint background and heredoc", Bool.and(ops.lint.only("exec x &\n", "a background job"), ops.lint.only("exec cat <<EOF\n", "a heredoc"))},
   OpsCk{"lint commands", Bool.and(Bool.and(ops.lint.only("echo hi\n", "a command other than"), ops.lint.only("A=1\n", "an assignment")),
     Bool.and(ops.lint.only("exec a\ncd b\n", "exec before the last line"), ops.lint.only("set -e\n", "set other than")))},
   OpsCk{"lint quotes", Bool.and(Nat.is_eq(ops.len(ops.lint("exec x 'a | b; c && $(d)' \"e # f\" # g | h\n")), 0n), ops.lint.only("exec x \"$(d)\"\n", "$( )"))},
   OpsCk{"lint 12 lines", ops.lint.only(String.repeat("export A=1\n", 13n), "13 lines of code")},
   OpsCk{"lint continued line", Nat.is_eq(ops.len(ops.lint("exec x \\\n  --y z \\\n  w\n")), 0n)},
   OpsCk{"lint unwired", Bool.and(ops.lint.unwired("#!/usr/bin/env bash\n# UNWIRED 2026-10-14: done; kept for reference\nexit 2\nif x; then y; fi\n"),
     Bool.not(ops.lint.unwired("#!/usr/bin/env bash\n# a script\n# UNWIRED 2026-10-14: too late\n")))},
   OpsCk{"lint shebang", Bool.and(Bool.and(Bool.and(Ln.lnt.shebang(S.b("#!/usr/bin/env bash")), Ln.lnt.shebang(S.b("#! /bin/sh -e"))), Ln.lnt.shebang(S.b("#!/usr/bin/env -S bash -e"))),
     Bool.and(Bool.not(Ln.lnt.shebang(S.b("#!/usr/bin/env python3"))), Bool.not(Ln.lnt.shebang(S.b("# no")))))},
   OpsCk{"lint flake bodies", ops.names.eq(ops.reps.names(fk), ["flake.nix:bin", "flake.nix:deploy", "flake.nix:ok", "flake.nix:one", "flake.nix:bad"])},
   OpsCk{"lint flake verdicts (bin's cp and bend pass: the flake-body rule)", Bool.and(Bool.and(Nat.is_eq(ops.len(ops.reps.probs(fk, "flake.nix:deploy")), 0n), Nat.is_eq(ops.len(ops.reps.probs(fk, "flake.nix:ok")), 0n)),
     Bool.and(Bool.and(ops.has(ops.reps.probs(fk, "flake.nix:one"), "a pipe"), ops.has(ops.reps.probs(fk, "flake.nix:bad"), "a control word: for")),
       Bool.and(Nat.is_eq(ops.len(ops.reps.probs(fk, "flake.nix:bin")), 0n),
         ops.has(ops.reps.probs(fk, "flake.nix:bad"), "a text tool: grep"))))},
   OpsCk{"lint allowlist", ops.names.eq(Ln.lnt.allow.of(S.b("# the ratchet\n\nbend/gpu/fp.sh\n  flake.nix:bend-tests  # phase 6\n")), ["bend/gpu/fp.sh", "flake.nix:bend-tests"])}]

# a file a background job writes, read until it equals WANT: every 100 ms, at
# most 100 times (a fixed 500 ms sleep, with both jobs on one log, raced under
# load, 2026-10-15)
type OpsRd is Data:
  OpsRd{done: Bool, got: List<&2, U32>}

def ops.rd.step(+path: String, +want: List<&2, U32>, r: OpsRd) -> IO(OpsRd):
  match r:
    case OpsRd{d, g}:
      do IO<OpsRd>:
        IO.sleep(100)
        +got : List<&2, U32> <- S.read(path)
        return OpsRd{S.eq(got, want), got}

def ops.rd.go(fuel: Nat, +path: String, +want: List<&2, U32>, r: OpsRd) -> IO(List<&2, U32>):
  match fuel r:
    case 1n+f OpsRd{False{}, g}:
      IO.bind(OpsRd, List<&2, U32>, ops.rd.step(path, want, OpsRd{False{}, g}), ops.rd.go(f, path, want))
    case _ OpsRd{d, g}:
      IO.pure(List<&2, U32>, g)

def ops.wait.read(+path: String, +want: List<&2, U32>) -> IO(List<&2, U32>):
  ops.rd.go(100n, path, want, OpsRd{False{}, Nil{}})

def ops.io(+dir: String) -> IO(List<&2, OpsCk>):
  do IO<List<&2, OpsCk>>:
    w : Maybe<&2, String> <- S.which("sh")
    nw : Maybe<&2, String> <- S.which("no-such-program-bend-ops")
    S.write(dir ++ "/b", S.b("b"))
    S.write(dir ++ "/a", S.b("abc"))
    S.write(dir ++ "/B", S.b("B"))
    S.mkdir(dir ++ "/sub/.partial")
    S.write(dir ++ "/sub/c", S.b("c"))
    S.write(dir ++ "/sub/.partial/c", S.b("c"))
    +fs : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.files(dir)
    +ls : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(dir)
    +no : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.files(dir ++ "/missing")
    +st : Maybe<&2, Lc.LclSt> <- Lc.lcl.stat(dir ++ "/a")
    +age : Maybe<&2, Nat> <- Lc.lcl.age(dir ++ "/a")
    +h : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(dir ++ "/a")
    +ss : List<&2, Lc.LclSum> <- Lc.lcl.sums(dir, [S.b("a"), S.b("zz"), S.b("b")])
    ha : Bool <- Lc.lcl.have(dir, "a")
    hc : Bool <- Lc.lcl.have(dir ++ "/sub", "c")
    S.write(dir ++ "/bg.log", S.b("stale\n"))
    S.write(dir ++ "/bg2.log", S.b("one\n"))
    pid : String <- S.background(dir, ["OPS_TEST=bar"], "bg.log", False{}, "printenv", ["OPS_TEST"])
    pid2 : String <- S.background(dir, [], "bg2.log", True{}, "echo", ["two"])
    +bg : List<&2, U32> <- ops.wait.read(dir ++ "/bg.log", S.b("bar\n"))
    +bg2 : List<&2, U32> <- ops.wait.read(dir ++ "/bg2.log", S.b("one\ntwo\n"))
    Lc.lcl.mark(dir ++ "/HOLD", "held")
    +mk : List<&2, U32> <- S.read(dir ++ "/HOLD")
    Al.alr.log(dir ++ "/chain.log", "pulled s1-step5000.checkpoint")
    +cl : List<&2, U32> <- S.read(dir ++ "/chain.log")
    return [OpsCk{"which", Bool.and(Maybe.is_some(&2, String, w), Bool.not(Maybe.is_some(&2, String, nw)))},
      OpsCk{"find sorted bytewise", ops.names.eq(Maybe.default(&2, List<&2, List<&2, U32>>, fs, Nil{}), ["B", "a", "b", "sub/.partial/c", "sub/c"])},
      OpsCk{"ls", ops.names.eq(Maybe.default(&2, List<&2, List<&2, U32>>, ls, Nil{}), ["B", "a", "b", "sub"])},
      OpsCk{"find missing", Bool.not(Maybe.is_some(&2, List<&2, List<&2, U32>>, no))},
      OpsCk{"stat", Nat.is_eq(Lc.lcl.st.size(Maybe.default(&2, Lc.LclSt, st, Lc.LclSt{0n, 0n})), 3n)},
      OpsCk{"age", Nat.is_lt(Maybe.default(&2, Nat, age, 9999n), 120n)},
      OpsCk{"sha256", S.eq(Maybe.default(&2, List<&2, U32>, h, Nil{}), S.b("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))},
      OpsCk{"sums", ops.names.eq(ops.sum.names(ss), ["a", "b"])},
      OpsCk{"have (and not while partial)", Bool.and(ha, Bool.not(hc))},
      OpsCk{"background", Bool.and(Bool.and(S.eq(bg, S.b("bar\n")), S.eq(bg2, S.b("one\ntwo\n"))), Bool.and(Ln.lnt.is.digit(Lc.lcl.at(S.b(pid), 0n)), Ln.lnt.is.digit(Lc.lcl.at(S.b(pid2), 0n))))},
      OpsCk{"mark", Bool.and(S.prefix(mk, S.b("[")), S.suffix(mk, S.b(" UTC-6] held\n")))},
      OpsCk{"log", Bool.and(S.prefix(cl, S.b("[")), Bool.and(S.suffix(cl, S.b(" UTC-6] pulled s1-step5000.checkpoint\n")),
        ops.names.eq(Lc.lcl.pulled.of(cl), ["s1-step5000.checkpoint"])))}]

def main() -> IO(Unit):
  do IO<Unit>:
    +box : List<&2, U32> <- S.read("fixtures/ops/sha256.box.txt")
    +here : List<&2, U32> <- S.read("fixtures/ops/sha256.txt")
    +s2 : List<&2, U32> <- S.read("fixtures/ops/s2.log")
    +chain : List<&2, U32> <- S.read("fixtures/ops/chain.log")
    +user : List<&2, U32> <- S.read("fixtures/ops/vast-user.json")
    +inst : List<&2, U32> <- S.read("fixtures/ops/vast-instances.json")
    +err : List<&2, U32> <- S.read("fixtures/ops/vast-error.json")
    +flake : List<&2, U32> <- S.read("fixtures/ops/lint-flake.txt")
    +flake2 : List<&2, U32> <- S.read("fixtures/ops/lint-flake2.txt")
    +lb : List<&2, U32> <- S.read("fixtures/ops/lint-bend.txt")
    +ls : List<&2, U32> <- S.read("fixtures/ops/lint-sys.txt")
    +dir : String <- S.mktemp()
    io : List<&2, OpsCk> <- ops.io(dir)
    S.rm(dir)
    ops.t.say(List.concat(&2, OpsCk, [ops.pure(box, here, s2, chain, user, inst, err, flake), ops.lint2(flake2, lb, ls), io]), 0n, "")
