import Base
import ../Sys.bend as S
import ../CorpusV2/Steps.bend as St
import ./Local.bend as Lc

# Vast: the vastai CLI (2026-10-14, the plan's Phase 0).  vastai stays the
# external Python program it is (~/.local/share/vastai-venv, or $V), called
# like ssh; what it prints with --raw (Python's json.dumps) is read here
# through Steps' JSON values (st.js.values), never with grep.
#
#   vst.bin                 $V, or ~/.local/share/vastai-venv/bin/vastai
#   vst.credit V MIN        `vastai show user --raw`'s top-level credit, and whether it is under MIN
#   vst.listed V INST       `vastai show instances --raw`: is instance INST listed (Yes, No, or
#                           Unknown when the listing failed or did not read: never "destroyed")
#   vst.destroy V INST      `vastai destroy instance INST -y`, its answer
#
# Every name starts with `vst.`; the pure parts (credit.of, listed.of) are
# tested on a real `show user --raw` and a listing in vast's shape
# (bend/tests/fixtures/ops).

def vst.bin() -> IO(String):
  do IO<String>:
    home : String <- S.env("HOME", "")
    S.env("V", home ++ "/.local/share/vastai-venv/bin/vastai")

def vst.run(+v: String, args: List<String>) -> IO(Lc.LclOut):
  Lc.lcl.run(300, v, args)

# The credit -----------------------------------------------------------------------------

type VstCr is Data:
  VstCrOf{credit: List<&2, U32>, low: Bool}
  VstCrNone{why: String}

# credit-watch.sh's `vastai show user --raw | bend-corpus-v2 credit MIN`:
# the credit's text (st.credit.tok: Python's repr of it), and whether it is
# under MIN (both read as doubles, compared exactly)
def vst.credit.cmp(+tok: List<&2, U32>, c: Maybe<&2, St.StF>, m: Maybe<&2, St.StF>) -> VstCr:
  match c m:
    case Some{+a} Some{+b}:
      VstCrOf{tok, Cmp.is_lt(St.st.f.cmp(a, b))}
    case None{} _:
      VstCrNone{"the credit " ++ S.str(tok) ++ " is not a number"}
    case _ None{}:
      VstCrNone{"MIN is not a number"}

def vst.credit.got(m: Maybe<&2, List<&2, U32>>, +min: String) -> VstCr:
  match m:
    case None{}:
      VstCrNone{"no top-level credit in vastai show user --raw"}
    case Some{+tok}:
      vst.credit.cmp(tok, St.st.f.read(tok), St.st.f.read(S.b(min)))

def vst.credit.of(+json: List<&2, U32>, +min: String) -> VstCr:
  vst.credit.got(St.st.credit.tok(json), min)

def vst.credit.fin(+o: Lc.LclOut, +min: String) -> VstCr:
  Bool.pick(VstCr, Lc.lcl.ok(o), vst.credit.of(Lc.lcl.out(o), min),
    VstCrNone{"vastai show user failed (exit " ++ U32.show(Lc.lcl.status(o)) ++ ")"})

def vst.credit(+v: String, +min: String) -> IO(VstCr):
  do IO<VstCr>:
    +o : Lc.LclOut <- vst.run(v, ["show", "user", "--raw"])
    return vst.credit.fin(o, min)

# The listing ------------------------------------------------------------------------------
#
# fp-chain.sh asked `vastai show instances --raw | grep -q "\"id\": $inst\b"`,
# so a failed listing read as "not listed" and the box as destroyed.  Here
# only a listing that reads (a JSON list of instances) answers No.

type VstLs is Data:
  VstLsYes{}
  VstLsNo{}
  VstLsUnknown{why: String}

def vst.ls.yes(+b: Bool) -> VstLs:
  Bool.pick(VstLs, b, VstLsYes{}, VstLsNo{})

# an instance's id: the value at [K, "id"] of the top-level list
def vst.id.is(vs: List<&2, St.StJv>, +inst: List<&2, U32>) -> Bool:
  match vs:
    case Nil{}:
      False{}
    case St.StJv{St.StJkI{k} <> St.StJkK{+key} <> Nil{}, St.StTkV{+t}} <> more:
      Bool.or(Bool.and(S.eq(key, S.b("id")), S.eq(t, inst)), vst.id.is(more, inst))
    case v <> more:
      vst.id.is(more, inst)

# a list at the top: every value's path starts with an index, or the list is empty
def vst.top.list(vs: List<&2, St.StJv>) -> Bool:
  match vs:
    case Nil{}:
      True{}
    case St.StJv{St.StJkI{k} <> p, t} <> more:
      vst.top.list(more)
    case St.StJv{Nil{}, St.StTkP{+c}} <> more:
      Bool.and(U32.is_eq(c, 91), vst.top.list(more))
    case v <> more:
      False{}

def vst.listed.vals(m: Maybe<&2, List<&2, St.StJv>>, +inst: String) -> VstLs:
  match m:
    case None{}:
      VstLsUnknown{"the listing is not JSON"}
    case Some{+vs}:
      Bool.pick(VstLs, vst.top.list(vs), vst.ls.yes(vst.id.is(vs, S.b(inst))), VstLsUnknown{"the listing is not a list of instances"})

def vst.listed.of(+json: List<&2, U32>, +inst: String) -> VstLs:
  vst.listed.vals(St.st.js.values(json), inst)

def vst.listed.fin(+o: Lc.LclOut, +inst: String) -> VstLs:
  Bool.pick(VstLs, Lc.lcl.ok(o), vst.listed.of(Lc.lcl.out(o), inst),
    VstLsUnknown{"vastai show instances failed (exit " ++ U32.show(Lc.lcl.status(o)) ++ ")"})

def vst.listed(+v: String, +inst: String) -> IO(VstLs):
  do IO<VstLs>:
    +o : Lc.LclOut <- vst.run(v, ["show", "instances", "--raw"])
    return vst.listed.fin(o, inst)

def vst.ls.show(+l: VstLs) -> String:
  match l:
    case VstLsYes{}:
      "listed"
    case VstLsNo{}:
      "not listed"
    case VstLsUnknown{w}:
      "unknown: " ++ w

# a field of a listed instance: the value at [K, KEY] of the object whose
# id is INST (None: no such instance or field)
def vst.field.in(vs: List<&2, St.StJv>, +k: Nat, +key: String) -> Maybe<&2, St.StTk>:
  St.st.js.at(vs, [St.StJkI{k}, St.StJkK{S.b(key)}])

def vst.index.of(vs: List<&2, St.StJv>, +inst: List<&2, U32>) -> Maybe<&2, Nat>:
  match vs:
    case Nil{}:
      None{}
    case St.StJv{St.StJkI{+k} <> St.StJkK{+key} <> Nil{}, St.StTkV{+t}} <> more:
      Bool.pick(Maybe<&2, Nat>, Bool.and(S.eq(key, S.b("id")), S.eq(t, inst)), Some{k}, vst.index.of(more, inst))
    case v <> more:
      vst.index.of(more, inst)

def vst.field.at(vs: List<&2, St.StJv>, m: Maybe<&2, Nat>, +key: String) -> Maybe<&2, St.StTk>:
  match m:
    case Some{+k}:
      vst.field.in(vs, k, key)
    case None{}:
      None{}

def vst.field(+vs: List<&2, St.StJv>, +inst: String, +key: String) -> Maybe<&2, St.StTk>:
  vst.field.at(vs, vst.index.of(vs, S.b(inst)), key)

# Destroy -----------------------------------------------------------------------------------

# `vastai destroy instance INST -y` (its answer, e.g. "destroying instance N.",
# is for the log; whether it took is the listing's to say)
def vst.destroy(+v: String, +inst: String) -> IO(Lc.LclOut):
  vst.run(v, ["destroy", "instance", inst, "-y"])
