import Base
import ../Sys.bend as S
import ./Evals.bend as Ev
import ../CorpusV2/Keyed.bend as K

# RunCfg: a run's drivers as one tracked config file (2026-10-15, the plan "all
# logic in Bend", Phase 4b: run 3's hand-written run/v3/run3/boot-guard.sh,
# s2-driver.sh, move.sh and act-restart.sh made generic, so a run's driver is a
# config, not a new script).  `bend-ops guard CFG`, `handover CFG` and `move CFG
# STEP` read it; tools/runs/run3.cfg is run 3's, tools/runs/TEMPLATE.cfg says
# what each key does.
#
# A setting a line: its first word the key, the rest its words (blank lines and
# `#` comments skipped, and a word starting with `#` ends a line: an inline comment;
# Evals.bend's reader, the evals configs' format).  A key
# given twice: the last line wins, except the keys read with rcf.every (env,
# s2-env, act-env, stop-units, move-need) and `unit`, which gather every line.
# Every name starts with `rcf.`; tested in bend/tests/drive.bend.

# a line's words up to a word that starts with # (an inline comment)
def rcf.cut(ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      Bool.pick(List<&2, List<&2, U32>>, S.head.is(w, 35), Nil{}, w <> rcf.cut(t))

def rcf.strip(kvs: List<&2, Ev.EvKv>) -> List<&2, Ev.EvKv>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{k, ws} <> t:
      Ev.EvKv{k, rcf.cut(ws)} <> rcf.strip(t)

def rcf.of(+xs: List<&2, U32>) -> List<&2, Ev.EvKv>:
  rcf.strip(Ev.evr.cfg(xs))

def rcf.read.got(m: Maybe<&2, List<&2, U32>>, +path: String) -> IO(List<&2, Ev.EvKv>):
  match m:
    case Some{+xs}:
      IO.pure(List<&2, Ev.EvKv>, rcf.of(xs))
    case None{}:
      IO.die(List<&2, Ev.EvKv>, 2, "no run config " ++ path)

def rcf.read(+path: String) -> IO(List<&2, Ev.EvKv>):
  do IO<List<&2, Ev.EvKv>>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(path)
    rcf.read.got(m, path)

def rcf.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> rcf.l1(t)

def rcf.or(+v: String, +d: String) -> String:
  Bool.pick(String, String.is_empty(v), d, v)

def rcf.first(xs: List<&2, String>, +d: String) -> String:
  match xs:
    case Nil{}:
      d
    case x <> t:
      x

# the last line's words (Nil when the key is not there)
def rcf.words(+kvs: List<&2, Ev.EvKv>, +key: String) -> List<&2, String>:
  Ev.evr.get(kvs, key, Nil{})

# the last line's first word, d when the key is not there or has no word
def rcf.get(+kvs: List<&2, Ev.EvKv>, +key: String, +d: String) -> String:
  rcf.first(rcf.words(kvs, key), d)

# the last line's words joined by one space (d when there are none)
def rcf.line(+kvs: List<&2, Ev.EvKv>, +key: String, +d: String) -> String:
  +ws = rcf.words(kvs, key)
  Bool.pick(String, List.is_empty(&2, String, ws), d, String.join(ws, " "))

def rcf.cat(vs: List<&2, List<&2, List<&2, U32>>>) -> List<&2, String>:
  match vs:
    case Nil{}:
      Nil{}
    case ws <> t:
      List.append(&2, String, K.kor.strs(ws), rcf.cat(t))

# every line's words, in order (env K=V lines, units to stop, ...)
def rcf.every(+kvs: List<&2, Ev.EvKv>, +key: String) -> List<&2, String>:
  rcf.cat(Ev.evr.all(kvs, key))

def rcf.digits(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), rcf.digits(t))

# a number of at most 12 digits (a Nat past 2^48 crashes), else None
def rcf.nat.of(+s: String) -> Maybe<&2, Nat>:
  +xs = S.b(s)
  Bool.pick(Maybe<&2, Nat>, Bool.and(Bool.and(Nat.is_lt(0n, S.len(xs)), Nat.is_le(S.len(xs), 12n)), rcf.digits(xs)), Nat.read(s), None{})

def rcf.nat(+kvs: List<&2, Ev.EvKv>, +key: String, +d: Nat) -> Nat:
  Maybe.default(&2, Nat, rcf.nat.of(rcf.get(kvs, key, "")), d)

# yes/no (anything else, or no line: d)
def rcf.yes(+kvs: List<&2, Ev.EvKv>, +key: String, +d: Bool) -> Bool:
  +v = rcf.get(kvs, key, "")
  Bool.pick(Bool, String.eq(v, "yes"), True{}, Bool.pick(Bool, String.eq(v, "no"), False{}, d))

# Units: `unit ROLE NAME [MEM [OUT]]` (ROLE chain, watch or handover; MEM the
# unit's MemoryMax, 4G; OUT the file its stdout and stderr are appended to)

type RcfUnit is Data:
  RcfUnit{name: String, mem: String, out: String}

def rcf.u.name(+u: RcfUnit) -> String:
  match u:
    case RcfUnit{n, m, o}:
      n

def rcf.u.mem(+u: RcfUnit) -> String:
  match u:
    case RcfUnit{n, m, o}:
      m

def rcf.u.out(+u: RcfUnit) -> String:
  match u:
    case RcfUnit{n, m, o}:
      o

def rcf.unit.of(+ws: List<&2, List<&2, U32>>) -> RcfUnit:
  RcfUnit{S.str(K.kor.field(ws, 1n)), rcf.or(S.str(K.kor.field(ws, 2n)), "4G"), S.str(K.kor.field(ws, 3n))}

def rcf.unit.go(vs: List<&2, List<&2, List<&2, U32>>>, +role: String, found: Maybe<&2, RcfUnit>) -> Maybe<&2, RcfUnit>:
  match vs:
    case Nil{}:
      found
    case +ws <> t:
      +hit = Bool.and(S.eq(K.kor.field(ws, 0n), S.b(role)), Nat.is_lt(0n, S.len(K.kor.field(ws, 1n))))
      rcf.unit.go(t, role, Bool.pick(Maybe<&2, RcfUnit>, hit, Some{rcf.unit.of(ws)}, found))

# the unit a role runs as (its last `unit ROLE ...` line), None when the config names none
def rcf.unit(+kvs: List<&2, Ev.EvKv>, +role: String) -> Maybe<&2, RcfUnit>:
  rcf.unit.go(Ev.evr.all(kvs, "unit"), role, None{})

# the keys a step cannot do without: those missing, by name
def rcf.missing(+kvs: List<&2, Ev.EvKv>, keys: List<&2, String>) -> List<&2, String>:
  match keys:
    case Nil{}:
      Nil{}
    case +k <> t:
      +rest = rcf.missing(kvs, t)
      Bool.pick(List<&2, String>, String.is_empty(rcf.get(kvs, k, "")), k <> rest, rest)

def rcf.need.if(none: Bool, +ms: List<&2, String>, +path: String) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 2, path ++ ": no " ++ String.join(ms, ", "))

# stop (exit 2) when the config lacks one of these keys
def rcf.need(+kvs: List<&2, Ev.EvKv>, keys: List<&2, String>, +path: String) -> IO(Unit):
  +ms = rcf.missing(kvs, keys)
  rcf.need.if(List.is_empty(&2, String, ms), ms, path)

# Paths ------------------------------------------------------------------------------------------

# P under DIR (an absolute P as it is; a leading ./ dropped)
def rcf.at(+dir: String, +p: String) -> String:
  +xs = S.b(p)
  Bool.pick(String, S.head.is(xs, 47), p, dir ++ "/" ++ S.str(S.strip(xs, S.b("./"))))

# this program's own path (argv[0], found on $PATH when it has no slash)
def rcf.self.at(slash: Bool, +argv0: String) -> IO(String):
  match slash:
    case True{}:
      S.realpath(argv0)
    case False{}:
      do IO<String>:
        m : Maybe<&2, String> <- S.which(argv0)
        S.realpath(Maybe.default(&2, String, m, argv0))

def rcf.self() -> IO(String):
  do IO<String>:
    argv : List<String> <- IO.args()
    +a0 : String = Maybe.default(&1, String, List.head(&1, String, argv), "bend-ops")
    rcf.self.at(S.infix(S.b(a0), [47]), a0)

def rcf.ops.got(there: Bool, +p: String) -> IO(String):
  match there:
    case True{}:
      IO.pure(String, p)
    case False{}:
      IO.die(String, 2, "no bend-ops at " ++ p ++ " (the config's ops: a gcroot of .#bend-ops, e.g. `nix build .#bend-ops -o run/gcroot-bend-ops`)")

def rcf.ops.at(+p: String) -> IO(String):
  do IO<String>:
    e : Bool <- S.exists(p)
    rcf.ops.got(e, p)

# the bend-ops the units run (key `ops`, under DIR; a gcroot of .#bend-ops, the
# wrapper with ssh and rsync on its PATH), else this program
def rcf.ops(+kvs: List<&2, Ev.EvKv>, +dir: String) -> IO(String):
  +o = rcf.get(kvs, "ops", "")
  Bool.pick(IO(String), String.is_empty(o), rcf.self(), rcf.ops.at(rcf.at(dir, o)))

# the last line's words, or ds when the key is not there
def rcf.words.or(+kvs: List<&2, Ev.EvKv>, +key: String, +ds: List<&2, String>) -> List<&2, String>:
  +ws = rcf.words(kvs, key)
  Bool.pick(List<&2, String>, List.is_empty(&2, String, ws), ds, ws)
