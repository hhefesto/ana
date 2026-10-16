import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../Clock.bend as Ck
import ../Tokenizer.bend as Tk
import ../Transcript.bend as Tr
import ../Check/Bend.bend as Bd
import ../Check/Lib.bend as Cl
import ./Lib.bend as L
import ./Keyed.bend as K
import ./Combine.bend as Cb
import ./Eval.bend as Ev
import ./MutOps.bend as M

# mutate: Bend repair transcripts from checked units, the checker's real
# errors on realistic breakages (2026-10-16).
#
#   bend-corpus-v2 mutate UNITS OUT [N]
#
# UNITS is a checked unit file (NUL pairs: an id, then bend-check's record,
# fields joined by 0x1E as Check/Lib.bend lists them: run/v2/results/
# bend.train.nul, a run/transcripts*/bend/results.train.nul).  A *.holdout.nul
# or a path holding `vault` is refused, and an id of HELDOUT (default
# run/v2/results/bend.holdout.nul; NUL pairs) is passed over.
#
# 1. The units in keyed order: sha256("corpus-v2 mutate" NUL id), the first
#    N of them (all without N), Bend's only.  OUT/work/part.K.in: PART (100)
#    of them a part, each as its pair's offset and length in UNITS.
# 2. Each part (PROCS (4) processes of this program, `mutate-part UNITS WORK
#    K`; PROCS 1: in this one): a unit is checked as bend-check checks it
#    (Check/Bend.bend's layout: the file's head, the declaration's pre, the
#    body, as Unit.bend beside its file in a copy of its repository's .bend
#    files; `bend Unit.bend --check-only` under `timeout TIMEOUT` (60), BEND
#    the locked run/gcroot-bend/bin/bend when present, else bend), in its
#    source tree (BEND_SRC when set, else the tree Eval.bend's ev.bend.src
#    finds: run/code-sources*/CLASS, then ~/src).  A unit whose original no
#    longer passes is stale: counted, never mutated.  Its tries
#    (MutOps.bend's mto.tries: the operators in turn, at most CAP (2) an
#    operator) are checked in order, at most TRIES (8) checks, an operator
#    already kept passed over: a mutant the checker passes or times out on
#    (exit 0, 124) is dropped, any other exit rejects it.  A rejected mutant
#    is kept when its error kind (mtt.kind) is new for the unit, else held
#    back; at most KEEP (3) a unit, held-back ones (of operators not kept)
#    filling the room left.
# 3. Each kept mutant is one transcript, format 2's repair (Transcript.bend
#    `render2` shape 1, the layout run 4's bend-fix holds): the ask and "This
#    attempt fails. Fix it.", the unit's Context and Type, the mutant as the
#    Attempt, the checker's answer to it (Transcript's `checker`: 40 lines,
#    then `[exit N]`; Agent/Spec's `ag.echo`, the live tool's, is held to
#    it), then the original Term and the checker's verdict on it (both
#    checks run now).  Its id is `mut:UNIT/OPERATOR-K` (the operator's K-th
#    mutant of the unit).  One over the window (TOKENIZER
#    weights/code32k.bpe, WINDOW 2048: Transcript's `fits`) is left out.
# 4. OUT/accepted/bend-mut/transcripts.train.nul: the parts' transcripts in
#    part order (OUT is an act directory for `s2`, whose kinds hold
#    LANG-mut); OUT/summary.txt: the counts (units, stale, kept, by operator
#    and by error kind, the checks' times), also printed.
#
# Resumable: a part whose OUT/work/part.K.stats exists is done (written
# last); the selection is reused when OUT/work/select.txt names the same
# UNITS and N (another stops: use another OUT).  Run from the repository
# root (Eval's source trees are run/'s).  Logs go to stderr (a part's to
# OUT/work/part.K.log, its output and errors to part.K.out), stamped UTC-6.
# Every def is prefixed `mtt.`; the operators' laws are bend/tests/mutops.bend,
# the tool's bend/tests/mutate.bend.

def mtt.log(+msg: String) -> IO(Unit):
  K.kor.log("mutate", msg)

def mtt.need(ok: Bool, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      K.kor.die("mutate", msg)

def mtt.salt() -> String:
  "corpus-v2 mutate"

def mtt.key(+id: List<&2, U32>) -> String:
  K.kor.key(S.b(mtt.salt()), id)

def mtt.unlines(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.append(x, 10 <> mtt.unlines(t))

# Settings -------------------------------------------------------------------------------------------

type MttCfg is Data:
  MttCfg{bend: String, src: String, t: Nat, keep: Nat, tries: Nat, cap: Nat, tok: String, window: Nat, part: Nat, procs: Nat, held: String}

def mtt.c.bend(+c: MttCfg) -> String:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      b

def mtt.c.src(+c: MttCfg) -> String:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      s

def mtt.c.t(+c: MttCfg) -> Nat:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      t

def mtt.c.keep(+c: MttCfg) -> Nat:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      k

def mtt.c.tries(+c: MttCfg) -> Nat:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      n

def mtt.c.cap(+c: MttCfg) -> Nat:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      p

def mtt.c.tok(+c: MttCfg) -> String:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      o

def mtt.c.window(+c: MttCfg) -> Nat:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      w

def mtt.c.part(+c: MttCfg) -> Nat:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      a

def mtt.c.procs(+c: MttCfg) -> Nat:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      r

def mtt.c.held(+c: MttCfg) -> String:
  match c:
    case MttCfg{b, s, t, k, n, p, o, w, a, r, h}:
      h

def mtt.locked() -> String:
  "run/gcroot-bend/bin/bend"

def mtt.bend.of(+v: String, have: Bool) -> IO(String):
  match have:
    case True{}:
      S.realpath(mtt.locked())
    case False{}:
      IO.pure(String, Bool.pick(String, String.is_empty(v), "bend", v))

# BEND, else the locked compiler when it is here, else bend
def mtt.bend() -> IO(String):
  do IO<String>:
    +v : String <- S.env("BEND", "")
    +have : Bool <- S.exists(mtt.locked())
    mtt.bend.of(v, Bool.and(String.is_empty(v), have))

def mtt.cfg() -> IO(MttCfg):
  do IO<MttCfg>:
    +bend : String <- mtt.bend()
    +src : String <- S.env("BEND_SRC", "")
    +t : Nat <- S.env.nat("TIMEOUT", 60n)
    +keep : Nat <- S.env.nat("KEEP", 3n)
    +tries : Nat <- S.env.nat("TRIES", 8n)
    +cap : Nat <- S.env.nat("CAP", 2n)
    +tok : String <- S.env("TOKENIZER", "weights/code32k.bpe")
    +w : Nat <- S.env.nat("WINDOW", 2048n)
    +part : Nat <- S.env.nat("PART", 100n)
    +procs : Nat <- S.env.nat("PROCS", 4n)
    +held : String <- S.env("HELDOUT", "run/v2/results/bend.holdout.nul")
    return MttCfg{bend, src, t, keep, tries, cap, tok, w, Nat.max(part, 1n), procs, held}

# Counts ------------------------------------------------------------------------------------------------
#
# A part's counts: (key, n) pairs, keys in first-counted order.

type MttKv is Data:
  MttKv{k: String, n: Nat}

def mtt.kv.hit(+kvs: List<&2, MttKv>, +k: String) -> Bool:
  match kvs:
    case MttKv{+x, n} <> t:
      String.eq(x, k)
    case Nil{}:
      False{}

def mtt.bump.go(kvs: List<&2, MttKv>, +k: String, +d: Nat, at: Bool) -> List<&2, MttKv>:
  match kvs at:
    case MttKv{x, n} <> t True{}:
      MttKv{x, Nat.add(n, d)} <> t
    case y <> +t False{}:
      y <> mtt.bump.go(t, k, d, mtt.kv.hit(t, k))
    case Nil{} _:
      [MttKv{k, d}]

# kvs with d added to k's count (k last when new)
def mtt.bump(+kvs: List<&2, MttKv>, +k: String, +d: Nat) -> List<&2, MttKv>:
  mtt.bump.go(kvs, k, d, mtt.kv.hit(kvs, k))

def mtt.bumps.go(ks: List<&2, String>, kvs: List<&2, MttKv>) -> List<&2, MttKv>:
  match ks:
    case Nil{}:
      kvs
    case +k <> t:
      mtt.bumps.go(t, mtt.bump(kvs, k, 1n))

# one more of each key
def mtt.bumps(kvs: List<&2, MttKv>, ks: List<&2, String>) -> List<&2, MttKv>:
  mtt.bumps.go(ks, kvs)

def mtt.get(kvs: List<&2, MttKv>, +k: String) -> Nat:
  match kvs:
    case Nil{}:
      0n
    case MttKv{+x, +n} <> t:
      Nat.add(Bool.pick(Nat, String.eq(x, k), n, 0n), mtt.get(t, k))

def mtt.merge(kvs: List<&2, MttKv>, +acc: List<&2, MttKv>) -> List<&2, MttKv>:
  match kvs:
    case Nil{}:
      acc
    case MttKv{+k, +n} <> t:
      mtt.merge(t, mtt.bump(acc, k, n))

def mtt.kv.bytes(kvs: List<&2, MttKv>) -> List<&2, U32>:
  match kvs:
    case Nil{}:
      Nil{}
    case MttKv{k, n} <> t:
      S.append(S.b(k ++ " " ++ Nat.show(n) ++ "\n"), mtt.kv.bytes(t))

# a stats file's lines (`KEY N`) added to kvs
def mtt.kv.read(ls: List<&2, List<&2, U32>>, +kvs: List<&2, MttKv>) -> List<&2, MttKv>:
  match ls:
    case Nil{}:
      kvs
    case +l <> t:
      +ws = S.split(l, 32)
      +ok = Nat.is_eq(List.length(&2, List<&2, U32>, ws), 2n)
      mtt.kv.read(t, Bool.pick(List<&2, MttKv>, ok, mtt.bump(kvs, S.str(K.kor.field(ws, 0n)), K.kor.nat(K.kor.field(ws, 1n))), kvs))

# Error kinds (pure) -------------------------------------------------------------------------------------
#
# A rejected mutant's error, from the checker's output, the first that
# holds: foreign (defs that rely on foreign or unsafe code: Bend 2.0.37
# fails such a file where 2.0.34 passed it, so its units are stale; a stale
# unit's error is counted by kind too), affine (a value consumed more than
# once), unbound (a name or a constructor not defined), missing-case (a
# match without all its cases), termination (a self-call that does not
# decrease), match (a binder matched where it cannot be), pattern (a
# constructor pattern with the wrong number of fields), duplicate (a name
# or constructor declared twice: the stale units of repositories written
# for another Bend), message (any
# other `- message` error), parse (an error at no definition: a line
# `Location:` alone), arity (a function where a value was expected or the
# other way round, not both: an argument missing or one too many), type
# (any other expected/observed), other.

def mtt.has.line(ls: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(S.eq(l, x), mtt.has.line(t, x))

def mtt.kind(+out: List<&2, U32>) -> String:
  +has = S.infix(out, S.b("- expected : "))
  +fun = Bool.xor(S.infix(out, S.b("- expected : @")), S.infix(out, S.b("- observed : @")))
  Bool.pick(String, S.infix(out, S.b("on unsafe or foreign code")), "foreign",
  Bool.pick(String, S.infix(out, S.b("(consumed more than once)")), "affine",
    Bool.pick(String, Bool.or(S.infix(out, S.b("- expected : a defined name")), S.infix(out, S.b(" (unknown: "))), "unbound",
      Bool.pick(String, S.infix(out, S.b("- expected : cases for")), "missing-case",
        Bool.pick(String, S.infix(out, S.b("- expected : a decreasing self-call")), "termination",
          Bool.pick(String, S.infix(out, S.b("can't be matched")), "match",
          Bool.pick(String, S.infix(out, S.b(" pattern with ")), "pattern",
          Bool.pick(String, S.infix(out, S.b("(duplicate declaration")), "duplicate",
            Bool.pick(String, S.infix(out, S.b("- message  : ")), "message",
              Bool.pick(String, mtt.has.line(S.split.lines(out), S.b("Location:")), "parse",
                Bool.pick(String, fun, "arity",
                  Bool.pick(String, has, "type", "other"))))))))))))

# the error's first line worth a log: the first `- expected`, `- message` or
# `Error` line (empty: none)
def mtt.why.hit(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case +l <> t:
      Bool.or(Bool.or(S.prefix(l, S.b("- expected")), S.prefix(l, S.b("- message"))), Bool.and(S.prefix(l, S.b("Error: ")), Nat.is_lt(7n, S.len(l))))
    case Nil{}:
      False{}

def mtt.why.go(ls: List<&2, List<&2, U32>>, at: Bool) -> List<&2, U32>:
  match ls at:
    case +l <> t True{}:
      l
    case l <> +t False{}:
      mtt.why.go(t, mtt.why.hit(t))
    case Nil{} _:
      Nil{}

def mtt.why(+out: List<&2, U32>) -> String:
  +ls = S.split.lines(out)
  S.str(List.take(&2, U32, mtt.why.go(ls, mtt.why.hit(ls)), 160n))

# A unit's tries (pure) --------------------------------------------------------------------------------

# a kept (or held-back) mutant: its try, its error kind, its check
type MttK is Data:
  MttK{op: Nat, k: Nat, kind: String, text: List<&2, U32>, check: List<&2, U32>}

def mtt.k.op(+x: MttK) -> Nat:
  match x:
    case MttK{o, k, d, t, c}:
      o

def mtt.k.kind(+x: MttK) -> String:
  match x:
    case MttK{o, k, d, t, c}:
      d

# A unit's checks so far: kept, held back, checks made, their ms, the counts
type MttSt is Data:
  MttSt{kept: List<&2, MttK>, back: List<&2, MttK>, n: Nat, ms: Nat, st: List<&2, MttKv>}

def mtt.ops.of(ks: List<&2, MttK>) -> List<&2, Nat>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> t:
      mtt.k.op(k) <> mtt.ops.of(t)

def mtt.kinds.of(ks: List<&2, MttK>) -> List<&2, String>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> t:
      mtt.k.kind(k) <> mtt.kinds.of(t)

def mtt.nat.in(xs: List<&2, Nat>, +x: Nat) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(Nat.is_eq(h, x), mtt.nat.in(t, x))

def mtt.str.in(xs: List<&2, String>, +x: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(String.eq(h, x), mtt.str.in(t, x))

# whether a try is checked: room to keep, checks left, its operator not kept
def mtt.want(+c: MttCfg, +s: MttSt, +t: M.MtoTry) -> Bool:
  match s:
    case MttSt{+kept, back, +n, ms, st}:
      Bool.and(Bool.and(Nat.is_lt(List.length(&2, MttK, kept), mtt.c.keep(c)), Nat.is_lt(n, mtt.c.tries(c))),
        Bool.not(mtt.nat.in(mtt.ops.of(kept), M.mto.try.op(t))))

# a checked try's verdict into the unit's state (exit e, check ck, d ms)
def mtt.judge(+t: M.MtoTry, +e: U32, +ck: List<&2, U32>, +d: Nat, s: MttSt) -> MttSt:
  match s:
    case MttSt{+kept, +back, +n, +ms, +st}:
      +op = M.mto.op.name(M.mto.try.op(t))
      +pass = U32.is_eq(e, 0)
      +late = U32.is_eq(e, 124)
      +kind = mtt.kind(Cl.check.text(ck))
      +x = {MttK{M.mto.try.op(t), M.mto.try.k(t), kind, M.mto.try.text(t), ck} : MttK}
      +fresh = Bool.not(mtt.str.in(mtt.kinds.of(kept), kind))
      +rej = Bool.not(Bool.or(pass, late))
      +st1 = mtt.bumps(st, ["tried." ++ op])
      +st2 = Bool.pick(List<&2, MttKv>, pass, mtt.bumps(st1, ["passed." ++ op]), Bool.pick(List<&2, MttKv>, late, mtt.bumps(st1, ["timeout." ++ op]),
        mtt.bumps(st1, ["rejected." ++ op, "rejected-kind." ++ kind])))
      +kept2 = Bool.pick(List<&2, MttK>, Bool.and(rej, fresh), List.append(&2, MttK, kept, [x]), kept)
      +back2 = Bool.pick(List<&2, MttK>, Bool.and(rej, Bool.not(fresh)), List.append(&2, MttK, back, [x]), back)
      MttSt{kept2, back2, 1n+n, Nat.add(ms, d), st2}

# the held-back ones filling the room left (each of an operator not kept yet)
def mtt.fill(bs: List<&2, MttK>, +kept: List<&2, MttK>, +room: Nat) -> List<&2, MttK>:
  match bs:
    case Nil{}:
      kept
    case +b <> t:
      +ok = Bool.and(Nat.is_lt(List.length(&2, MttK, kept), room), Bool.not(mtt.nat.in(mtt.ops.of(kept), mtt.k.op(b))))
      mtt.fill(t, Bool.pick(List<&2, MttK>, ok, List.append(&2, MttK, kept, [b]), kept), room)

# Transcripts (pure) --------------------------------------------------------------------------------
#
# A kept mutant's transcript: the record bend-check writes for the unit with
# it as its one kept mutant (fields 0..10, the original's check, the
# Context, no hole, no type, the mutant and its check), rendered as format
# 2's repair with mutant 0.

def mtt.record(+fs: List<&2, List<&2, U32>>, +orig: List<&2, U32>, +x: MttK) -> List<&2, List<&2, U32>>:
  match x:
    case MttK{o, k, d, +t, +c}:
      List.append(&2, List<&2, U32>, List.take(&2, List<&2, U32>, fs, 11n), [orig, Ev.ev.nth(fs, 12n), Nil{}, Nil{}, t, c])

def mtt.text(+fs: List<&2, List<&2, U32>>, +orig: List<&2, U32>, +x: MttK) -> List<&2, U32>:
  Tr.render2(1n, mtt.record(fs, orig, x), 0n)

def mtt.id(+uid: List<&2, U32>, +x: MttK) -> List<&2, U32>:
  match x:
    case MttK{+o, +k, d, t, c}:
      L.v2.concat([S.b("mut:"), uid, S.b("/" ++ M.mto.op.name(o) ++ "-" ++ Nat.show(k))])

# the window's law (Transcript's fits)
type MttW is Data:
  MttW{bpe: Tk.Bpe, lim: Nat}

def mtt.fits(+w: MttW, +text: List<&2, U32>) -> Bool:
  match w:
    case MttW{b, lim}:
      Tr.fits(b, lim, text)

# the pairs of the kept mutants that fit, and the counts
type MttOut is Data:
  MttOut{bytes: List<&2, U32>, st: List<&2, MttKv>}

def mtt.emit.one(acc: MttOut, +fit: Bool, +id: List<&2, U32>, +text: List<&2, U32>, +op: String, +kind: String) -> MttOut:
  match acc:
    case MttOut{+b, +st}:
      +b2 = Bool.pick(List<&2, U32>, fit, L.v2.concat([b, id, [0], text, [0]]), b)
      +st2 = Bool.pick(List<&2, MttKv>, fit, mtt.bumps(st, ["kept", "kept." ++ op, "kind." ++ kind]), mtt.bumps(st, ["long", "long." ++ op]))
      MttOut{b2, st2}

def mtt.emit(ks: List<&2, MttK>, +w: MttW, +uid: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +orig: List<&2, U32>, +acc: MttOut) -> MttOut:
  match ks:
    case Nil{}:
      acc
    case +x <> t:
      +text = mtt.text(fs, orig, x)
      mtt.emit(t, w, uid, fs, orig, mtt.emit.one(acc, mtt.fits(w, text), mtt.id(uid, x), text, M.mto.op.name(mtt.k.op(x)), mtt.k.kind(x)))

# A unit (IO) -------------------------------------------------------------------------------------------

# what a part needs for each unit
type MttCx is Data:
  MttCx{c: MttCfg, w: MttW, roots: List<&2, String>, home: String, tmp: String}

def mtt.cx.c(+x: MttCx) -> MttCfg:
  match x:
    case MttCx{c, w, r, h, t}:
      c

def mtt.cx.w(+x: MttCx) -> MttW:
  match x:
    case MttCx{c, w, r, h, t}:
      w

def mtt.cx.roots(+x: MttCx) -> List<&2, String>:
  match x:
    case MttCx{c, w, r, h, t}:
      r

def mtt.cx.home(+x: MttCx) -> String:
  match x:
    case MttCx{c, w, r, h, t}:
      h

def mtt.cx.tmp(+x: MttCx) -> String:
  match x:
    case MttCx{c, w, r, h, t}:
      t

# a unit's outcome: its transcripts' pairs, its counts, its log line
type MttU is Data:
  MttU{bytes: List<&2, U32>, st: List<&2, MttKv>, line: String}

def mtt.tries.one(want: Bool, +cf: Bd.Cf, +tdir: String, +udir: String, +u: Cl.U, +t: M.MtoTry, s: MttSt) -> IO(MttSt):
  match want:
    case False{}:
      IO.pure(MttSt, s)
    case True{}:
      do IO<MttSt>:
        +t0 : Nat <- IO.now()
        +o : S.Out <- Bd.run(cf, udir, u, M.mto.try.text(t))
        +t1 : Nat <- IO.now()
        return mtt.judge(t, S.Out.status(o), Bd.check.of(tdir, 100n, o), Nat.sub(t1, t0), s)

def mtt.tries.go(ts: List<&2, M.MtoTry>, +c: MttCfg, +cf: Bd.Cf, +tdir: String, +udir: String, +u: Cl.U, +s: MttSt) -> IO(MttSt):
  match ts:
    case Nil{}:
      IO.pure(MttSt, s)
    case +t <> more:
      do IO<MttSt>:
        +s2 : MttSt <- mtt.tries.one(mtt.want(c, s, t), cf, tdir, udir, u, t, s)
        mtt.tries.go(more, c, cf, tdir, udir, u, s2)

def mtt.names(ks: List<&2, MttK>) -> String:
  match ks:
    case Nil{}:
      ""
    case +k <> t:
      " " ++ M.mto.op.name(mtt.k.op(k)) ++ "(" ++ mtt.k.kind(k) ++ ")" ++ mtt.names(t)

def mtt.done.fin(out: MttOut, +line: String) -> MttU:
  match out:
    case MttOut{b, st}:
      MttU{b, st, line}

# the checks done: the kept ones rendered
def mtt.done(+cx: MttCx, +uid: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +orig: List<&2, U32>, +od: Nat, +ntries: Nat, s: MttSt) -> MttU:
  match s:
    case MttSt{kept, back, +n, +ms, st}:
      +ks = mtt.fill(back, kept, mtt.c.keep(mtt.cx.c(cx)))
      +st1 = mtt.bump(mtt.bump(mtt.bump(mtt.bump(mtt.bumps(st, ["checked", "checks.original"]), "checks.mutant", n), "ms.original", od), "ms.mutant", ms), "tries.planned", ntries)
      +none = Bool.pick(List<&2, String>, Nat.is_eq(ntries, 0n), ["no-tries"], ["none-kept"])
      +st2 = Bool.pick(List<&2, MttKv>, List.is_empty(&2, MttK, ks), mtt.bumps(st1, none), mtt.bumps(st1, ["units-kept"]))
      mtt.done.fin(mtt.emit(ks, mtt.cx.w(cx), uid, fs, orig, MttOut{Nil{}, st2}),
        S.str(uid) ++ ": " ++ Nat.show(n) ++ " checks of " ++ Nat.show(ntries) ++ " tries, kept" ++ mtt.names(ks))

def mtt.stale(+uid: List<&2, U32>, +e: String, +out: List<&2, U32>, +od: Nat) -> MttU:
  MttU{Nil{}, [MttKv{"stale", 1n}, MttKv{"stale.exit_" ++ e, 1n}, MttKv{"stale-kind." ++ mtt.kind(out), 1n}, MttKv{"checks.original", 1n}, MttKv{"ms.original", od}],
    S.str(uid) ++ ": stale (the original exits " ++ e ++ ": " ++ mtt.why(out) ++ ")"}

def mtt.orig(ok: Bool, +c: MttCfg, +cx: MttCx, +cf: Bd.Cf, +tdir: String, +udir: String, +u: Cl.U, +fs: List<&2, List<&2, U32>>, +o: S.Out, +od: Nat) -> IO(MttU):
  match ok:
    case False{}:
      IO.pure(MttU, mtt.stale(Cl.U.id(u), U32.show(S.Out.status(o)), S.Out.text(o), od))
    case True{}:
      +uid = Cl.U.id(u)
      +mu = {M.MtoU{Ev.ev.nth(fs, 5n), Ev.ev.nth(fs, 6n), Ev.ev.nth(fs, 7n), S.eq(Ev.ev.nth(fs, 1n), S.b("proposition"))} : M.MtoU}
      +ts = M.mto.tries(S.b(mtt.key(uid)), mtt.c.cap(c), mu)
      do IO<MttU>:
        +s : MttSt <- mtt.tries.go(ts, c, cf, tdir, udir, u, MttSt{Nil{}, Nil{}, 0n, 0n, Nil{}})
        return mtt.done(cx, uid, fs, Bd.check.of(tdir, 100n, o), od, List.length(&2, M.MtoTry, ts), s)

# the unit's repository's .bend files under tdir/src, once (`cp -t` takes
# many files a process; bend-check's `-exec cp ... ;` runs one a file)
def mtt.copy(have: Bool, +src: String, +tdir: String, +repo: String) -> IO(Unit):
  match have:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        S.mkdir(tdir ++ "/src")
        +o : S.Out <- S.run(src, [], 3600, "find", [repo, "-name", "*.bend", "-not", "-path", "*/node_modules/*", "-exec", "cp", "--parents", "-t", tdir ++ "/src/", "{}", "+"], Nil{})
        return Unit{}

def mtt.placed(+cx: MttCx, +src: String, +fs: List<&2, List<&2, U32>>, +u: Cl.U, +rel: List<&2, U32>) -> IO(MttU):
  +c = mtt.cx.c(cx)
  +tdir = mtt.cx.tmp(cx) ++ "/t" ++ String.take(H.sha256(S.b(src)), 8n)
  +repo = S.str(Bd.repo.of(rel))
  +udir = tdir ++ "/src/" ++ S.str(Cl.before.last(rel, [47]))
  +cf = {Bd.Cf{mtt.c.bend(c), src, U32.from_nat(mtt.c.t(c)), 100n} : Bd.Cf}
  do IO<MttU>:
    +h : Bool <- S.exists(tdir ++ "/src/" ++ repo)
    mtt.copy(h, src, tdir, repo)
    +t0 : Nat <- IO.now()
    +o : S.Out <- Bd.run(cf, udir, u, Ev.ev.nth(fs, 7n))
    +t1 : Nat <- IO.now()
    r : MttU <- mtt.orig(U32.is_eq(S.Out.status(o), 0), c, cx, cf, tdir, udir, u, fs, o, Nat.sub(t1, t0))
    S.rm(udir ++ "/Unit.bend")
    return r

def mtt.found(ok: Bool, +cx: MttCx, +src: String, +fs: List<&2, List<&2, U32>>, +u: Cl.U, +rel: List<&2, U32>) -> IO(MttU):
  match ok:
    case False{}:
      IO.pure(MttU, MttU{Nil{}, [MttKv{"no-source", 1n}], S.str(Cl.U.id(u)) ++ ": no source (" ++ src ++ "/" ++ S.str(rel) ++ ")"})
    case True{}:
      mtt.placed(cx, src, fs, u, rel)

def mtt.src(+cx: MttCx, +uid: List<&2, U32>, +body: List<&2, U32>) -> IO(String):
  +fixed = mtt.c.src(mtt.cx.c(cx))
  Bool.pick(IO(String), String.is_empty(fixed), Ev.ev.bend.src(mtt.cx.roots(cx), mtt.cx.home(cx), uid, body), S.realpath(fixed))

def mtt.bend.unit(+cx: MttCx, +uid: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> IO(MttU):
  +rel = Bd.rel.of(uid, Ev.ev.nth(fs, 2n))
  +u = {Cl.U{0n, uid, List.take(&2, List<&2, U32>, fs, 11n)} : Cl.U}
  do IO<MttU>:
    +src : String <- mtt.src(cx, uid, Ev.ev.nth(fs, 7n))
    +ok : Bool <- S.exists(src ++ "/" ++ S.str(rel))
    mtt.found(ok, cx, src, fs, u, rel)

def mtt.unit.of(bend: Bool, +cx: MttCx, +uid: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> IO(MttU):
  match bend:
    case True{}:
      mtt.bend.unit(cx, uid, fs)
    case False{}:
      IO.pure(MttU, MttU{Nil{}, [MttKv{"not-bend", 1n}], S.str(uid) ++ ": not a Bend unit"})

# a unit from its pair's bytes (id NUL record NUL)
def mtt.unit(+cx: MttCx, +xs: List<&2, U32>) -> IO(MttU):
  +uid = L.v2.before(xs, 0)
  +rec = L.v2.before(List.drop(&2, U32, xs, 1n+S.len(uid)), 0)
  +fs = Ev.ev.split(rec, 30)
  mtt.unit.of(S.eq(Ev.ev.nth(fs, 0n), S.b("bend")), cx, uid, fs)

# A part (IO) -------------------------------------------------------------------------------------------

type MttRd is Type:
  MttRd{f: File, st: List<&2, MttKv>}

def mtt.at.put(+work: String, +k: String, f: File, +st: List<&2, MttKv>, u: MttU) -> IO(MttRd):
  match u:
    case MttU{b, +s, +line}:
      do IO<MttRd>:
        S.add(work ++ "/part." ++ k ++ ".nul.tmp", b)
        +t : Nat <- Ck.ck.wall()
        S.add(work ++ "/part." ++ k ++ ".log", S.b(Ck.stamp(t) ++ " " ++ line ++ "\n"))
        return MttRd{f, mtt.merge(s, mtt.bump(st, "units", 1n))}

def mtt.at.got(+cx: MttCx, +work: String, +k: String, +st: List<&2, MttKv>, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(MttRd):
  (f, x) = r
  do IO<MttRd>:
    xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    u : MttU <- mtt.unit(cx, xs)
    mtt.at.put(work, k, f, st, u)

def mtt.at.rd(rd: MttRd, +cx: MttCx, +work: String, +k: String, +off: Nat, +len: Nat) -> IO(MttRd):
  match rd:
    case MttRd{f, +st}:
      do IO<MttRd>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(off), U32.from_nat(len))
        mtt.at.got(cx, work, k, st, r)

# one unit of the part: its place's line `OFF TAB LEN`
def mtt.at(+cx: MttCx, +work: String, +k: String, +l: List<&2, U32>, rd: MttRd) -> IO(MttRd):
  +ws = S.split(l, 9)
  mtt.at.rd(rd, cx, work, k, K.kor.nat(K.kor.field(ws, 0n)), K.kor.nat(K.kor.field(ws, 1n)))

def mtt.all(ls: List<&2, List<&2, U32>>, +cx: MttCx, +work: String, +k: String, rd: MttRd) -> IO(MttRd):
  match ls:
    case Nil{}:
      IO.pure(MttRd, rd)
    case +l <> t:
      IO.bind(MttRd, MttRd, mtt.at(cx, work, k, l, rd), mtt.all(t, cx, work, k))

def mtt.win(+tok: String, +lim: Nat, m: Maybe<&2, Tk.Bpe>) -> IO(MttW):
  match m:
    case Some{b}:
      IO.pure(MttW, MttW{b, lim})
    case None{}:
      IO.die(MttW, 1, "mutate: the tokenizer " ++ tok ++ " does not parse")

def mtt.part.fin(+work: String, +k: String, +ms: Nat, rd: MttRd) -> IO(Unit):
  match rd:
    case MttRd{f, +st}:
      +p = work ++ "/part." ++ k
      +st2 = mtt.bump(st, "ms.part", ms)
      do IO<Unit>:
        File.close(f)
        S.mv(p ++ ".nul.tmp", p ++ ".nul")
        S.write(p ++ ".stats.tmp", mtt.kv.bytes(st2))
        S.mv(p ++ ".stats.tmp", p ++ ".stats")
        S.rm(p ++ ".tmp")
        IO.print("part " ++ k ++ ": " ++ Nat.show(mtt.get(st2, "units")) ++ " units, " ++ Nat.show(mtt.get(st2, "stale")) ++ " stale, "
          ++ Nat.show(mtt.get(st2, "kept")) ++ " mutants kept, " ++ Nat.show(Nat.div(ms, 1000n)) ++ " s")

# mutate-part UNITS WORK K: part K's units (WORK/part.K.in), its
# transcripts into WORK/part.K.nul and its counts into WORK/part.K.stats
def mtt.part.with(+c: MttCfg, +units: String, +work: String, +k: String) -> IO(Unit):
  +p = work ++ "/part." ++ k
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    tx : List<&2, U32> <- S.read(mtt.c.tok(c))
    +w : MttW <- mtt.win(mtt.c.tok(c), Nat.sub(mtt.c.window(c), 64n), Tk.Bpe.parse(tx))
    +roots : List<&2, String> <- Ev.ev.roots()
    +home : String <- S.env("HOME", "")
    S.rm(p ++ ".tmp")
    S.mkdir(p ++ ".tmp")
    # absolute: the copies are made from the source tree, the checks run in them
    +tmp : String <- S.realpath(p ++ ".tmp")
    S.write(p ++ ".nul.tmp", Nil{})
    S.write(p ++ ".log", Nil{})
    ls : List<&2, U32> <- S.read(p ++ ".in")
    +cx : MttCx = MttCx{c, w, roots, Cb.cb.path(home, "src"), tmp}
    f : File <- IO.try(File, File.open(units, "r"))
    rd : MttRd <- mtt.all(S.split.lines(ls), cx, work, k, MttRd{f, Nil{}})
    +t1 : Nat <- IO.now()
    mtt.part.fin(work, k, Nat.sub(t1, t0), rd)

def mtt.part(+units: String, +work: String, +k: String) -> IO(Unit):
  do IO<Unit>:
    +c : MttCfg <- mtt.cfg()
    mtt.part.with(c, units, work, k)

def mtt.part.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +units <> +work <> +k <> Nil{}:
      mtt.part(units, work, k)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 mutate-part UNITS WORK K")

# Selection ---------------------------------------------------------------------------------------------
#
# One pass over UNITS: each Bend unit not held out as `KEY TAB OFF TAB LEN`
# into a spool; `LC_ALL=C sort` orders it; the first N lines cut into parts.

# HELDOUT's ids (a NUL pair file read a field at a time; none when missing)
type MttIds is Type:
  MttIds{r: S.Rd, acc: List<&2, String>, id: Bool, more: Bool}

def mtt.ids.got(+acc: List<&2, String>, +id: Bool, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(MttIds):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(MttIds, MttIds{r, acc, id, False{}})
    case Some{+v}:
      IO.pure(MttIds, MttIds{r, Bool.pick(List<&2, String>, id, S.str(v) <> acc, acc), Bool.not(id), True{}})

def mtt.ids.step(s: MttIds) -> IO(MttIds):
  match s:
    case MttIds{r, +acc, +id, more}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, MttIds, S.Rd.next(r), mtt.ids.got(acc, id))

def mtt.ids.go(fuel: Nat, s: MttIds) -> IO(MttIds):
  match fuel s:
    case 1n+f MttIds{r, acc, id, True{}}:
      IO.bind(MttIds, MttIds, mtt.ids.step(MttIds{r, acc, id, True{}}), mtt.ids.go(f))
    case _ z:
      IO.pure(MttIds, z)

def mtt.ids.fin(s: MttIds) -> IO(List<&2, String>):
  match s:
    case MttIds{r, acc, id, more}:
      do IO<List<&2, String>>:
        S.Rd.close(r)
        return acc

def mtt.ids(have: Bool, +path: String) -> IO(List<&2, String>):
  match have:
    case False{}:
      IO.pure(List<&2, String>, Nil{})
    case True{}:
      do IO<List<&2, String>>:
        r : S.Rd <- S.Rd.open(path)
        s : MttIds <- mtt.ids.go(K.kor.fuel(), MttIds{r, Nil{}, True{}, True{}})
        mtt.ids.fin(s)

type MttSel is Type:
  MttSel{r: S.Rd, o: File, off: Nat, n: Nat, kept: Nat, held: Nat, more: Bool}

def mtt.emit.if(ok: Bool, o: File, xs: List<&2, U32>) -> IO(File):
  match ok:
    case True{}:
      S.emit(o, xs)
    case False{}:
      IO.pure(File, o)

def mtt.sel.pair(+held: Set(), o: File, +off: Nat, +n: Nat, +kept: Nat, +hn: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(MttSel):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(MttSel, MttSel{r, o, off, n, kept, hn, False{}})
    case Some{+t}:
      +len = Nat.add(Nat.add(S.len(id), S.len(t)), 2n)
      +bend = S.prefix(t, S.append(S.b("bend"), [30]))
      +h = L.v2.in(held, S.str(id))
      +ok = Bool.and(bend, Bool.not(h))
      +line = S.b(mtt.key(id) ++ "\t" ++ Nat.show(off) ++ "\t" ++ Nat.show(len) ++ "\n")
      do IO<MttSel>:
        o2 : File <- mtt.emit.if(ok, o, line)
        return MttSel{r, o2, Nat.add(off, len), 1n+n, Nat.add(kept, Bool.pick(Nat, ok, 1n, 0n)), Nat.add(hn, Bool.pick(Nat, Bool.and(bend, h), 1n, 0n)), True{}}

def mtt.sel.id(m: Maybe<&2, List<&2, U32>>, +held: Set(), r: S.Rd, o: File, +off: Nat, +n: Nat, +kept: Nat, +hn: Nat) -> IO(MttSel):
  match m:
    case None{}:
      IO.pure(MttSel, MttSel{r, o, off, n, kept, hn, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, MttSel, S.Rd.next(r), mtt.sel.pair(held, o, off, n, kept, hn, id))

def mtt.sel.got(+held: Set(), o: File, +off: Nat, +n: Nat, +kept: Nat, +hn: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(MttSel):
  (r, m) = x
  mtt.sel.id(m, held, r, o, off, n, kept, hn)

def mtt.sel.step(+held: Set(), s: MttSel) -> IO(MttSel):
  match s:
    case MttSel{r, o, +off, +n, +kept, +hn, more}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, MttSel, S.Rd.next(r), mtt.sel.got(held, o, off, n, kept, hn))

def mtt.sel.go(fuel: Nat, +held: Set(), s: MttSel) -> IO(MttSel):
  match fuel s:
    case 1n+f MttSel{r, o, off, n, kept, hn, True{}}:
      IO.bind(MttSel, MttSel, mtt.sel.step(held, MttSel{r, o, off, n, kept, hn, True{}}), mtt.sel.go(f, held))
    case _ z:
      IO.pure(MttSel, z)

# the pass's counts: pairs read, Bend units kept, Bend units held out
type MttN is Data:
  MttN{n: Nat, kept: Nat, held: Nat}

def mtt.sel.close(s: MttSel) -> IO(MttN):
  match s:
    case MttSel{r, o, off, +n, +kept, +hn, more}:
      do IO<MttN>:
        S.Rd.close(r)
        File.close(o)
        return MttN{n, kept, hn}

# the lines cut into part files of size lines each; the number of parts
def mtt.parts.write(fuel: Nat, +ls: List<&2, List<&2, U32>>, +work: String, +size: Nat, +k: Nat, more: Bool) -> IO(Nat):
  match fuel more:
    case 1n+f True{}:
      +rest = List.drop(&2, List<&2, U32>, ls, size)
      do IO<Nat>:
        S.write(work ++ "/part." ++ Nat.show(k) ++ ".in", mtt.unlines(List.take(&2, List<&2, U32>, ls, size)))
        mtt.parts.write(f, rest, work, size, 1n+k, Bool.not(List.is_empty(&2, List<&2, U32>, rest)))
    case _ _:
      IO.pure(Nat, k)

# a sorted spool line less its key (`OFF TAB LEN`)
def mtt.places(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.drop(&2, U32, l, 65n) <> mtt.places(t)

def mtt.take(m: Maybe<&2, Nat>, +ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match m:
    case Some{n}:
      List.take(&2, List<&2, U32>, ls, n)
    case None{}:
      ls

def mtt.sel.text(+units: String, +ntext: String, +sel: Nat, +np: Nat, +part: Nat, +cn: MttN) -> List<&2, U32>:
  match cn:
    case MttN{+n, +kept, +held}:
      S.b("units " ++ units ++ "\nn " ++ ntext ++ "\nselected " ++ Nat.show(sel) ++ "\nparts " ++ Nat.show(np) ++ "\npart " ++ Nat.show(part)
        ++ "\npairs " ++ Nat.show(n) ++ "\nbend " ++ Nat.show(Nat.add(kept, held)) ++ "\nheld " ++ Nat.show(held) ++ "\n")

def mtt.select(+c: MttCfg, +units: String, +work: String, +ntext: String, n: Maybe<&2, Nat>) -> IO(Nat):
  +spool = work ++ "/select.spool"
  +sorted = work ++ "/select.sorted"
  do IO<Nat>:
    +hp : Bool <- S.exists(mtt.c.held(c))
    +hs : List<&2, String> <- mtt.ids(hp, mtt.c.held(c))
    mtt.log("selection: " ++ units ++ " in keyed order (\"" ++ mtt.salt() ++ "\"), " ++ Nat.show(List.length(&2, String, hs)) ++ " ids of " ++ mtt.c.held(c) ++ " passed over")
    r : S.Rd <- S.Rd.open(units)
    o : File <- IO.try(File, File.open(spool, "w"))
    s : MttSel <- mtt.sel.go(K.kor.fuel(), Set.from_list(hs), MttSel{r, o, 0n, 0n, 0n, 0n, True{}})
    +cn : MttN <- mtt.sel.close(s)
    +so : S.Out <- S.run(".", ["LC_ALL=C"], 86400, "sort", ["-o", sorted, spool], Nil{})
    mtt.need(U32.is_eq(S.Out.status(so), 0), "sort failed: " ++ S.str(S.Out.text(so)))
    xs : List<&2, U32> <- S.read(sorted)
    +ls : List<&2, List<&2, U32>> = mtt.places(mtt.take(n, S.split.lines(xs)))
    +np : Nat <- mtt.parts.write(K.kor.fuel(), ls, work, mtt.c.part(c), 0n, Bool.not(List.is_empty(&2, List<&2, U32>, ls)))
    S.write(work ++ "/select.txt", mtt.sel.text(units, ntext, List.length(&2, List<&2, U32>, ls), np, mtt.c.part(c), cn))
    S.rm(spool)
    S.rm(sorted)
    mtt.log("selection: " ++ Nat.show(List.length(&2, List<&2, U32>, ls)) ++ " units in " ++ Nat.show(np) ++ " parts of " ++ Nat.show(mtt.c.part(c)))
    return np

# select.txt's value for a key (its `KEY VALUE` lines; "" when none)
def mtt.val.hit(+ls: List<&2, List<&2, U32>>, +key: String) -> Bool:
  match ls:
    case +l <> t:
      S.prefix(l, S.b(key ++ " "))
    case Nil{}:
      False{}

def mtt.val.go(ls: List<&2, List<&2, U32>>, +key: String, at: Bool) -> String:
  match ls at:
    case +l <> t True{}:
      S.str(List.drop(&2, U32, l, 1n+S.len(S.b(key))))
    case l <> +t False{}:
      mtt.val.go(t, key, mtt.val.hit(t, key))
    case Nil{} _:
      ""

def mtt.sel.val(+ls: List<&2, List<&2, U32>>, +key: String) -> String:
  mtt.val.go(ls, key, mtt.val.hit(ls, key))

def mtt.selected(+units: String, +work: String, +ntext: String) -> IO(Nat):
  do IO<Nat>:
    xs : List<&2, U32> <- S.read(work ++ "/select.txt")
    +ls : List<&2, List<&2, U32>> = S.split.lines(xs)
    +u : String = mtt.sel.val(ls, "units")
    +nv : String = mtt.sel.val(ls, "n")
    mtt.need(Bool.and(String.eq(u, units), String.eq(nv, ntext)), work ++ "/select.txt chose " ++ nv ++ " of " ++ u ++ ", not " ++ ntext ++ " of " ++ units ++ ": use another OUT")
    mtt.log("selection: reused " ++ work ++ "/select.txt (" ++ mtt.sel.val(ls, "selected") ++ " units, " ++ mtt.sel.val(ls, "parts") ++ " parts)")
    return K.kor.nat(S.b(mtt.sel.val(ls, "parts")))

def mtt.sel.if(have: Bool, +c: MttCfg, +units: String, +work: String, +ntext: String, n: Maybe<&2, Nat>) -> IO(Nat):
  match have:
    case True{}:
      mtt.selected(units, work, ntext)
    case False{}:
      mtt.select(c, units, work, ntext, n)

# The parts ------------------------------------------------------------------------------------------------

# the parts not done yet (no part.K.stats), from k on
def mtt.todo(n: Nat, +work: String, +k: Nat) -> IO(List<&2, Nat>):
  match n:
    case 0n:
      IO.pure(List<&2, Nat>, Nil{})
    case 1n+m:
      do IO<List<&2, Nat>>:
        +done : Bool <- S.exists(work ++ "/part." ++ Nat.show(k) ++ ".stats")
        +rest : List<&2, Nat> <- mtt.todo(m, work, 1n+k)
        return Bool.pick(List<&2, Nat>, done, rest, k <> rest)

# The workers: PROCS forked threads, each taking the next part from a
# channel and running `SELF mutate-part UNITS WORK K` with its standard output
# and error into WORK/part.K.out (Sys's run.log), its exit status back
# through a second channel (Combine.bend's pool keeps the output in memory
# and drops stderr: a part's crash would leave no trace).
type MttRes is Data:
  MttRes{k: Nat, st: U32}

def mtt.wk.got(+self: String, +units: String, +work: String, +res: Chan(MttRes), m: Maybe<&1, Nat>) -> IO(Bool):
  match m:
    case None{}:
      IO.pure(Bool, False{})
    case Some{+k}:
      do IO<Bool>:
        +st : U32 <- S.run.log(".", [], 864000, self, ["mutate-part", units, work, Nat.show(k)], work ++ "/part." ++ Nat.show(k) ++ ".out")
        ok : Result<&1, &1, MttRes, Unit> <- Chan.send(MttRes, res, MttRes{k, st})
        return True{}

def mtt.wk.step(+self: String, +units: String, +work: String, +jobs: Chan(Nat), +res: Chan(MttRes)) -> IO(Bool):
  do IO<Bool>:
    m : Maybe<&1, Nat> <- Chan.recv(Nat, jobs)
    mtt.wk.got(self, units, work, res, m)

def mtt.wk.go(fuel: Nat, +self: String, +units: String, +work: String, +jobs: Chan(Nat), +res: Chan(MttRes), more: Bool) -> IO(Unit):
  match fuel more:
    case 1n+f True{}:
      IO.bind(Bool, Unit, mtt.wk.step(self, units, work, jobs, res), mtt.wk.go(f, self, units, work, jobs, res))
    case _ _:
      IO.pure(Unit, Unit{})

def mtt.fork(n: Nat, +self: String, +units: String, +work: String, +jobs: Chan(Nat), +res: Chan(MttRes)) -> IO(List<Chan(Unit)>):
  match n:
    case 0n:
      IO.pure(List<Chan(Unit)>, Nil{})
    case 1n+m:
      do IO<List<Chan(Unit)>>:
        ch : Chan(Unit) <- IO.fork(Unit, mtt.wk.go(K.kor.fuel(), self, units, work, jobs, res, True{}))
        rest : List<Chan(Unit)> <- mtt.fork(m, self, units, work, jobs, res)
        return ch <> rest

def mtt.send(+jobs: Chan(Nat), ks: List<&2, Nat>) -> IO(Unit):
  match ks:
    case Nil{}:
      Chan.close(Nat, jobs)
    case k <> more:
      do IO<Unit>:
        ok : Result<&1, &1, Nat, Unit> <- Chan.send(Nat, jobs, k)
        mtt.send(jobs, more)

def mtt.last.line(+xs: List<&2, U32>) -> String:
  S.str(List.reverse(&2, U32, L.v2.before(List.reverse(&2, U32, S.chomp(xs)), 10)))

def mtt.res.got(m: Maybe<&1, MttRes>) -> IO(MttRes):
  match m:
    case Some{r}:
      IO.pure(MttRes, r)
    case None{}:
      IO.die(MttRes, 1, "mutate: the parts' channel closed early")

def mtt.said(+ok: Bool, +k: String, +st: U32, +work: String, +out: List<&2, U32>, +done: Nat, +total: Nat) -> String:
  Bool.pick(String, ok, mtt.last.line(out), "part " ++ k ++ " FAILED (exit " ++ U32.show(st) ++ ": " ++ mtt.last.line(out) ++ "; " ++ work ++ "/part." ++ k ++ ".out)")
    ++ " [" ++ Nat.show(1n+done) ++ "/" ++ Nat.show(total) ++ "]"

def mtt.wait.got(+res: Chan(MttRes), +work: String, +total: Nat, +done: Nat, +bad: Nat, r: MttRes) -> IO(Nat):
  match r:
    case MttRes{+k, +st}:
      +ok = U32.is_eq(st, 0)
      do IO<Nat>:
        +out : List<&2, U32> <- S.read(work ++ "/part." ++ Nat.show(k) ++ ".out")
        mtt.log(mtt.said(ok, Nat.show(k), st, work, out, done, total))
        return Nat.add(bad, Bool.pick(Nat, ok, 0n, 1n))

# the parts' answers as they finish, each logged; the failures
def mtt.wait(n: Nat, +res: Chan(MttRes), +work: String, +total: Nat, +done: Nat, +bad: Nat) -> IO(Nat):
  match n:
    case 0n:
      IO.pure(Nat, bad)
    case 1n+m:
      do IO<Nat>:
        mr : Maybe<&1, MttRes> <- Chan.recv(MttRes, res)
        r : MttRes <- mtt.res.got(mr)
        +bad2 : Nat <- mtt.wait.got(res, work, total, done, bad, r)
        mtt.wait(m, res, work, total, 1n+done, bad2)

def mtt.pool(+procs: Nat, +self: String, +units: String, +work: String, +ks: List<&2, Nat>) -> IO(Nat):
  +n = List.length(&2, Nat, ks)
  do IO<Nat>:
    +jobs : Chan(Nat) <- Chan.new(Nat, U32.from_nat(1n+n))
    +res : Chan(MttRes) <- Chan.new(MttRes, U32.from_nat(1n+n))
    mtt.send(jobs, ks)
    ws : List<Chan(Unit)> <- mtt.fork(Nat.max(procs, 1n), self, units, work, jobs, res)
    +bad : Nat <- mtt.wait(n, res, work, n, 0n, 0n)
    Cb.cb.join.all(ws)
    return bad

# PROCS 1: every part in this process
def mtt.here(ks: List<&2, Nat>, +c: MttCfg, +units: String, +work: String) -> IO(Nat):
  match ks:
    case Nil{}:
      IO.pure(Nat, 0n)
    case +k <> t:
      do IO<Nat>:
        mtt.part.with(c, units, work, Nat.show(k))
        mtt.here(t, c, units, work)

# the parts: PROCS processes of this program (each reads the settings from
# the environment it inherits), or (PROCS 1) here with c
def mtt.parts.run(one: Bool, +c: MttCfg, +self: String, +units: String, +work: String, +ks: List<&2, Nat>) -> IO(Nat):
  match one:
    case True{}:
      mtt.here(ks, c, units, work)
    case False{}:
      mtt.pool(mtt.c.procs(c), self, units, work, ks)

# OUT/accepted/bend-mut/transcripts.train.nul: the parts' transcripts in order
def mtt.cat(n: Nat, +work: String, +k: Nat, o: File) -> IO(File):
  match n:
    case 0n:
      IO.pure(File, o)
    case 1n+m:
      IO.bind(File, File, K.kor.cp.one(work ++ "/part." ++ Nat.show(k) ++ ".nul", o), mtt.cat(m, work, 1n+k))

def mtt.out(+out: String, +work: String, +np: Nat) -> IO(Unit):
  +dir = out ++ "/accepted/bend-mut"
  do IO<Unit>:
    S.mkdir(dir)
    o : File <- IO.try(File, File.open(dir ++ "/transcripts.train.nul.tmp", "w"))
    o2 : File <- mtt.cat(np, work, 0n, o)
    File.close(o2)
    S.mv(dir ++ "/transcripts.train.nul.tmp", dir ++ "/transcripts.train.nul")

def mtt.stats(n: Nat, +work: String, +k: Nat, +acc: List<&2, MttKv>) -> IO(List<&2, MttKv>):
  match n:
    case 0n:
      IO.pure(List<&2, MttKv>, acc)
    case 1n+m:
      do IO<List<&2, MttKv>>:
        xs : List<&2, U32> <- S.read(work ++ "/part." ++ Nat.show(k) ++ ".stats")
        mtt.stats(m, work, 1n+k, mtt.kv.read(S.split.lines(xs), acc))

# The summary (pure) ----------------------------------------------------------------------------------------

def mtt.spaces(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+k:
      " " ++ mtt.spaces(k)

def mtt.lj(+w: Nat, +s: String) -> String:
  s ++ mtt.spaces(Nat.sub(w, String.length(s)))

def mtt.rj(+w: Nat, +s: String) -> String:
  mtt.spaces(Nat.sub(w, String.length(s))) ++ s

def mtt.d2(+q: Nat) -> String:
  Bool.pick(String, Nat.is_lt(q, 10n), "0", "") ++ Nat.show(q)

# a / b to two places, rounded half up ("-" when b is 0)
def mtt.ratio(+a: Nat, +b: Nat) -> String:
  +q = Nat.div(Nat.add(Nat.mul(a, 200n), b), Nat.mul(2n, Nat.max(b, 1n)))
  Bool.pick(String, Nat.is_eq(b, 0n), "-", Nat.show(Nat.div(q, 100n)) ++ "." ++ mtt.d2(Nat.mod(q, 100n)))

# a / b as a percentage to one place
def mtt.pct(+a: Nat, +b: Nat) -> String:
  +q = Nat.div(Nat.add(Nat.mul(a, 2000n), b), Nat.mul(2n, Nat.max(b, 1n)))
  Bool.pick(String, Nat.is_eq(b, 0n), "-", Nat.show(Nat.div(q, 10n)) ++ "." ++ Nat.show(Nat.mod(q, 10n)) ++ "%")

# the counts whose key starts with p, as ` KEY N` pieces (the prefix cut)
def mtt.with.prefix(kvs: List<&2, MttKv>, +p: String) -> String:
  match kvs:
    case Nil{}:
      ""
    case MttKv{+k, +n} <> t:
      +hit = S.prefix(S.b(k), S.b(p))
      Bool.pick(String, hit, " " ++ S.str(List.drop(&2, U32, S.b(k), S.len(S.b(p)))) ++ " " ++ Nat.show(n), "") ++ mtt.with.prefix(t, p)

def mtt.cell(+kvs: List<&2, MttKv>, +x: String, +name: String) -> String:
  mtt.rj(9n, Nat.show(mtt.get(kvs, x ++ "." ++ name)))

def mtt.op.row(+kvs: List<&2, MttKv>, +o: Nat) -> String:
  +name = M.mto.op.name(o)
  mtt.lj(12n, name) ++ mtt.cell(kvs, "tried", name) ++ mtt.cell(kvs, "rejected", name) ++ mtt.cell(kvs, "passed", name) ++ mtt.cell(kvs, "timeout", name)
    ++ mtt.cell(kvs, "kept", name) ++ mtt.cell(kvs, "long", name) ++ "\n"

def mtt.op.rows(os: List<&2, Nat>, +kvs: List<&2, MttKv>) -> String:
  match os:
    case Nil{}:
      ""
    case +o <> t:
      mtt.op.row(kvs, o) ++ mtt.op.rows(t, kvs)

def mtt.summary(+units: String, +sel: List<&2, List<&2, U32>>, +kvs: List<&2, MttKv>, +wall: Nat, +procs: Nat) -> String:
  +u = mtt.get(kvs, "units")
  +ch = mtt.get(kvs, "checked")
  +kept = mtt.get(kvs, "kept")
  +uk = mtt.get(kvs, "units-kept")
  +co = mtt.get(kvs, "checks.original")
  +cm = mtt.get(kvs, "checks.mutant")
  +tp = mtt.get(kvs, "tries.planned")
  +mp = mtt.get(kvs, "ms.part")
  +m = M.mto.op.count()
  "mutate: " ++ units ++ " (n " ++ mtt.sel.val(sel, "n") ++ "): " ++ mtt.sel.val(sel, "selected") ++ " units chosen of its " ++ mtt.sel.val(sel, "bend")
    ++ " Bend units (" ++ mtt.sel.val(sel, "held") ++ " held out), " ++ mtt.sel.val(sel, "parts") ++ " parts\n"
    ++ "units seen         " ++ Nat.show(u) ++ "\n"
    ++ "  not Bend         " ++ Nat.show(mtt.get(kvs, "not-bend")) ++ "\n"
    ++ "  no source        " ++ Nat.show(mtt.get(kvs, "no-source")) ++ "\n"
    ++ "  stale            " ++ Nat.show(mtt.get(kvs, "stale")) ++ "   (the original fails now; by exit:" ++ mtt.with.prefix(kvs, "stale.exit_") ++ "; by kind:" ++ mtt.with.prefix(kvs, "stale-kind.") ++ ")\n"
    ++ "  checked          " ++ Nat.show(ch) ++ "   (the original passes)\n"
    ++ "    no tries       " ++ Nat.show(mtt.get(kvs, "no-tries")) ++ "   (no operator applies)\n"
    ++ "    none kept      " ++ Nat.show(mtt.get(kvs, "none-kept")) ++ "   (every try checked passed or timed out)\n"
    ++ "    a mutant kept  " ++ Nat.show(uk) ++ "   (" ++ mtt.pct(uk, ch) ++ " of the checked)\n"
    ++ "transcripts        " ++ Nat.show(kept) ++ "   (" ++ mtt.ratio(kept, u) ++ " a unit seen, " ++ mtt.ratio(kept, ch) ++ " a checked unit); over the window, left out: "
    ++ Nat.show(mtt.get(kvs, "long")) ++ "\n"
    ++ "tries planned      " ++ Nat.show(tp) ++ "   (" ++ mtt.ratio(tp, ch) ++ " a checked unit)\n"
    ++ "checks             " ++ Nat.show(Nat.add(co, cm)) ++ ": originals " ++ Nat.show(co) ++ " (" ++ mtt.ratio(mtt.get(kvs, "ms.original"), Nat.mul(co, 1000n)) ++ " s each), mutants "
    ++ Nat.show(cm) ++ " (" ++ mtt.ratio(cm, ch) ++ " a checked unit, " ++ mtt.ratio(mtt.get(kvs, "ms.mutant"), Nat.mul(cm, 1000n)) ++ " s each)\n"
    ++ "time               " ++ mtt.ratio(mp, Nat.mul(u, 1000n)) ++ " s a unit in one process (the parts' clocks, " ++ mtt.ratio(mp, 3600000n) ++ " process-hours);"
    ++ " this run's wall " ++ mtt.ratio(wall, 1000n) ++ " s at PROCS " ++ Nat.show(procs) ++ "\n\n"
    ++ mtt.lj(12n, "operator") ++ mtt.rj(9n, "tried") ++ mtt.rj(9n, "rejected") ++ mtt.rj(9n, "passed") ++ mtt.rj(9n, "timeout") ++ mtt.rj(9n, "kept") ++ mtt.rj(9n, "long") ++ "\n"
    ++ mtt.op.rows(M.mto.order(m, 0n, m), kvs) ++ "\n"
    ++ "error kinds, kept:" ++ mtt.with.prefix(kvs, "kind.") ++ "\n"
    ++ "error kinds, every rejected try:" ++ mtt.with.prefix(kvs, "rejected-kind.") ++ "\n"

# Main ----------------------------------------------------------------------------------------------------

# the tool with settings c (the command line's come from the environment)
def mtt.run.with(+c: MttCfg, +units: String, +out: String, +ntext: String, n: Maybe<&2, Nat>) -> IO(Unit):
  +work = out ++ "/work"
  do IO<Unit>:
    mtt.need(Bool.not(Bool.or(S.suffix(S.b(units), S.b(".holdout.nul")), S.infix(S.b(units), S.b("vault")))), units ++ " is a holdout or a vault file: never mutated")
    +size : Nat <- S.size(units)
    mtt.need(Bool.and(Nat.is_lt(0n, size), Nat.is_lt(size, U32.to_nat(4294967295))), units ++ ": missing, empty, or 4 GiB or more (the reads are 32-bit)")
    S.mkdir(work)
    +have : Bool <- S.exists(work ++ "/select.txt")
    +np : Nat <- mtt.sel.if(have, c, units, work, ntext, n)
    +todo : List<&2, Nat> <- mtt.todo(np, work, 0n)
    +self : String <- K.kor.self()
    mtt.log(Nat.show(np) ++ " parts, " ++ Nat.show(List.length(&2, Nat, todo)) ++ " to do; PROCS " ++ Nat.show(mtt.c.procs(c)) ++ ", BEND " ++ mtt.c.bend(c) ++ ", TIMEOUT "
      ++ Nat.show(mtt.c.t(c)) ++ ", KEEP " ++ Nat.show(mtt.c.keep(c)) ++ ", TRIES " ++ Nat.show(mtt.c.tries(c)) ++ ", CAP " ++ Nat.show(mtt.c.cap(c)))
    +t0 : Nat <- IO.now()
    +bad : Nat <- mtt.parts.run(Nat.is_le(mtt.c.procs(c), 1n), c, self, units, work, todo)
    +t1 : Nat <- IO.now()
    mtt.need(Nat.is_eq(bad, 0n), Nat.show(bad) ++ " part(s) failed (their logs: " ++ work ++ "/part.K.log); run again to redo them")
    mtt.out(out, work, np)
    +kvs : List<&2, MttKv> <- mtt.stats(np, work, 0n, Nil{})
    sel : List<&2, U32> <- S.read(work ++ "/select.txt")
    +text : String = mtt.summary(units, S.split.lines(sel), kvs, Nat.sub(t1, t0), mtt.c.procs(c))
    S.write(out ++ "/summary.txt", S.b(text))
    IO.write(text)
    mtt.log("done: " ++ out ++ "/accepted/bend-mut/transcripts.train.nul (" ++ Nat.show(mtt.get(kvs, "kept")) ++ " transcripts), " ++ out ++ "/summary.txt")

def mtt.run(+units: String, +out: String, +ntext: String, n: Maybe<&2, Nat>) -> IO(Unit):
  do IO<Unit>:
    +c : MttCfg <- mtt.cfg()
    mtt.run.with(c, units, out, ntext, n)

def mtt.run.n(+units: String, +out: String, +ntext: String, m: Maybe<&2, Nat>) -> IO(Unit):
  match m:
    case Some{k}:
      mtt.run(units, out, ntext, Some{k})
    case None{}:
      IO.die(Unit, 2, "mutate: N is not a number: " ++ ntext)

def mtt.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +units <> +out <> Nil{}:
      mtt.run(units, out, "all", None{})
    case +units <> +out <> +n <> Nil{}:
      mtt.run.n(units, out, n, Nat.read(n))
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 mutate UNITS OUT [N]   (env: PROCS PART KEEP TRIES CAP TIMEOUT BEND BEND_SRC HELDOUT TOKENIZER WINDOW)")
