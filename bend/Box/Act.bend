import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./OnBox.bend as Ob
import ../CorpusV2/AgentAct.bend as Aa

# bend-ops act: ana's act rounds on a rented box, beside the trainer (2026-10-15,
# the plan's Phase 3: all logic in Bend, the shell a thin shim).  It is
# bend/gpu/act-box.sh mode for mode, and run 3's act-restart.sh made generic:
#
#   bend-ops act setup HOST PORT        nix on the box (nixpkgs' static nix, one binary, as root),
#                                       the tools by `nix copy -s` (the box substitutes from
#                                       cache.nixos.org), their gcroots, the tracked files, the act
#                                       set, its units' train records and every held-out record, S2's
#                                       filler, the evaluation's prompts and transcripts, the units'
#                                       source trees, Mathlib's source, then on the box elan's
#                                       toolchain and `lake exe cache get`
#   bend-ops act ckpt HOST PORT CKPT    a checkpoint into the box's workspace, its sha256 compared
#   bend-ops act check HOST PORT CKPT   agent-act on 1 prompt of each language and shape, 2 seeds:
#                                       the render law holds on every episode, all 9 languages and
#                                       shapes answer, and no language's checker fails more than
#                                       it answers (`bend-episode langs`)
#   bend-ops act start HOST PORT CKPT DIR
#                                       agent-act on the whole act set, detached in a session of its
#                                       own on the box (DIR.log beside DIR)
#   bend-ops act pull HOST PORT DIR     DIR's accepted episodes, records, log and report here
#   bend-ops act ensure HOST PORT CKPT DIR [RESUME]
#                                       act-restart.sh: setup, ckpt (each tried TRIES (12) times,
#                                       RETRY_SLEEP (30) s apart), RESUME (a local act round cut to
#                                       whole records, e.g. by bend-box cut-frames/cut-pairs) as DIR
#                                       on the box (RESUME.log as DIR.log-resumed, its agent.nul's
#                                       sha256 compared), then start, only when no bend-corpus-v2
#                                       process runs there; ENSURE_WAIT (120) s later, how it goes
#   bend-ops act --dry-run OUT          setup's local part: OUT/units.txt, OUT/LANG.train.nul and
#                                       OUT/trees.txt, nothing sent
#   bend-ops act procs NPROC [CPU_MAX]  start's PROCS for a box's `nproc` and cgroup cpu.max
#
# The workspace is ACT_WS (/home/hhefesto/src/formalTransformer) on both sides,
# and HOME on the box is ACT_HOME ($HOME here): the Agda library file, the
# checkers' caches, elan's toolchains and the scripts name them.  The box's
# nix lives in ACT_BOX_BIN (/usr/local/bin), first on the PATH of every
# command run in the workspace.  Paths CKPT, DIR and ACTSET
# (run/v2/act/prompts.nul) are relative to the workspace.  The deploy that
# runs agent-act on the box is ACT_DEPLOY (run/v2/gcroot-deploy-agent/bin/
# deploy) and its bend-episode ACT_EPISODE (run/agent/gcroot-bend-episode/
# bin/bend-episode): both must be built from a tree with `corpus-v2
# agent-act` and `bend-episode langs` (this one).  The trainer's
# ~/formalTransformer is not touched, and nothing here stops the trainer: a
# failure only delays a round.
#
# The box is reached as Remote.bend reaches it (SSH_OPTS, SSH_TRIES,
# RSYNC_TRIES, ...): every command sent is a fixed command line with no
# control flow (`env -C WS HOME=.. PATH=BIN:"$PATH" PROG ARGS`, a redirect
# at most), every answer is parsed here, and every copy is rsync with a
# partial directory and retries.  Log lines are `[stamp UTC-6] act-box:
# ...` as the script's were, on stdout and appended to ACT_LOG when it is
# set (act-restart's chain.log).
#
# What differs from act-box.sh, on purpose: start's PROCS (unless PROCS is
# set) is (min(nproc, the cgroup's cpu.max quota) - 4) / 2, at least 1 (the
# script's (nproc - 4) / 2 would have started 94 processes on run 3's
# second box, whose nproc is 192 and quota 46 cores), and check's is that
# core count / 2 (the script's nproc / 2); start warns when a round already
# runs; units.txt and trees.txt are sorted bytewise (sort in the locale
# before: the same lines, in another order); the five LANG.train.nul
# filters run as five processes of this program (`act filter`); check.txt
# is read without the vast banner; pull keeps partial files in .partial
# (rsync --partial made a truncated file look whole) and does not retry;
# setup's copies retry (RSYNC_TRIES) and print no rsync stats; a check
# whose episodes log does not read fails (the script's table read 0 tool
# errors then, and passed); ensure's resume is any local DIR and is checked
# by sha256 (act-restart's was r1 and its NUL count); the box's nix.conf is
# copied, not printf'd there; the toolchain name is read from the local
# lean-toolchain (the copy just sent).  Every name starts with `acb.`; the
# pure parts are tested in bend/tests/act.bend.
#
# 2026-10-15 (Phase 1c): act-box.sh and agent-act.sh are unwired; `bend-ops sim stage act-*`
# holds every mode, and `ensure` against run 3's act-restart.sh, to copies of them in the
# sandbox (bend/Box/ScnStage.bend).

# Text ------------------------------------------------------------------------------------------

def acb.unlines(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Ob.obx.unlines(ls)

def acb.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  Ob.obx.strs(xs)

def acb.l1(xs: List<&2, String>) -> List<String>:
  Ob.obx.l1(xs)

def acb.l2(xs: List<String>) -> List<&2, String>:
  Ob.obx.l2(xs)

def acb.dedup.go(xs: List<&2, List<&2, U32>>, +prev: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = acb.dedup.go(t, x)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(x, prev), rest, x <> rest)

def acb.dedup(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      x <> acb.dedup.go(t, x)

# `LC_ALL=C sort -u`: bytewise, each line once
def acb.sort.u(+xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  acb.dedup(Lc.lcl.sort(xs))

def acb.trim.l(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      acb.trim.l(t, Bool.or(S.head.is(t, 32), S.head.is(t, 9)))
    case r _:
      r

# `read -r`: the line without blanks around it
def acb.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  +l = acb.trim.l(xs, Bool.or(S.head.is(xs, 32), S.head.is(xs, 9)))
  +r = List.reverse(&2, U32, l)
  List.reverse(&2, U32, acb.trim.l(r, Bool.or(S.head.is(r, 32), S.head.is(r, 9))))

# xs up to (not with) its first byte c, all of it without one
def acb.before(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  List.take(&2, U32, xs, Maybe.default(&2, Nat, S.find(xs, [c], 0n), S.len(xs)))

# xs after its first byte c (empty without one)
def acb.after(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  List.drop(&2, U32, xs, Nat.add(Maybe.default(&2, Nat, S.find(xs, [c], 0n), S.len(xs)), 1n))

def acb.is.digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def acb.digits(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(acb.is.digit(c), acb.digits(t))

def acb.nat(+xs: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_lt(0n, S.len(xs)), Bool.and(Nat.is_le(S.len(xs), 12n), acb.digits(xs))),
    Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n), 0n)

def acb.nat.ok(+xs: List<&2, U32>) -> Bool:
  Bool.and(Nat.is_lt(0n, S.len(xs)), Bool.and(Nat.is_le(S.len(xs), 12n), acb.digits(xs)))

# Units (pure) ----------------------------------------------------------------------------------
#
# units_of: `cat FILES | awk -v RS='\0' 'NR % 2 == 1 { sub(/\/[^\/]*$/, ""); print }'`: the ids
# (every other field, counted across the files) less their last `/` part (UNIT/SHAPE is UNIT);
# the held-out records' ids as they are; each printed as lines, all of them `sort -u`.

# an id without its last `/` and what follows it (the id itself without one)
def acb.unit.of(+id: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, id)
  Bool.pick(List<&2, U32>, S.infix(id, [47]), List.reverse(&2, U32, acb.after(r, 47)), id)

# the lines `print` makes of a record (a record holding newlines is lines)
def acb.lines.of(+x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  S.split(List.append(&2, U32, x, [10]), 10)

# Source trees (pure) -----------------------------------------------------------------------------
#
# trees(): the source trees units need.  repo:NAME/.. is run/code-sources/repos/NAME;
# hackage:PKG/.. is every run/check-cache/hs/src/PKG-[0-9]* and run/code-sources/tarballs/
# PKG-[0-9]*.tar.gz there is; own: and curated: are their whole directories, and the target of each
# link a unit names inside them, relative to the workspace when it is inside it; the Agda library
# file's checkouts under run/code-sources/repos; the checkers' caches.

def acb.strip(+xs: List<&2, U32>, +p: String) -> Maybe<&2, List<&2, U32>>:
  Bool.pick(Maybe<&2, List<&2, U32>>, S.prefix(xs, S.b(p)), Some{List.drop(&2, U32, xs, S.len(S.b(p)))}, None{})

def acb.put(m: Maybe<&2, List<&2, U32>>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match m:
    case Some{x}:
      x <> rest
    case None{}:
      rest

def acb.map.maybe(m: Maybe<&2, List<&2, U32>>, +pre: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case Some{+x}:
      Some{List.append(&2, U32, pre, acb.before(x, 47))}
    case None{}:
      None{}

# `/^repo:/ { sub(/^repo:/, ""); sub(/\/.*/, ""); print "run/code-sources/repos/" $0 }`
def acb.tr.repo(+l: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  acb.map.maybe(acb.strip(l, "repo:"), S.b("run/code-sources/repos/"))

# `/^hackage:/ { sub(/^hackage:/, ""); sub(/\/.*/, ""); print }`
def acb.tr.hackage(+l: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  acb.map.maybe(acb.strip(l, "hackage:"), Nil{})

# `/^(own|curated):/ { k = $0; sub(/:.*/, "", k); sub(/^[^:]*:/, ""); sub(/\/.*/, ""); print
# "run/code-sources/" k "/" $0 }`
def acb.tr.oc(+l: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  +k = acb.before(l, 58)
  Bool.pick(Maybe<&2, List<&2, U32>>, Bool.and(S.infix(l, [58]), Bool.or(S.eq(k, S.b("own")), S.eq(k, S.b("curated")))),
    Some{List.concat(&2, U32, [S.b("run/code-sources/"), k, [47], acb.before(acb.after(l, 58), 47)])}, None{})

def acb.collect(ls: List<&2, List<&2, U32>>, +which: Nat) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +m = Bool.pick(Maybe<&2, List<&2, U32>>, Nat.is_eq(which, 0n), acb.tr.repo(l),
        Bool.pick(Maybe<&2, List<&2, U32>>, Nat.is_eq(which, 1n), acb.tr.hackage(l), acb.tr.oc(l)))
      acb.put(m, acb.collect(t, which))

# the run of bytes other than `/` at the head of xs
def acb.nonslash(+xs: List<&2, U32>) -> List<&2, U32>:
  acb.before(xs, 47)

def acb.grep.o.go(fuel: Nat, +l: List<&2, U32>, +p: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, List<&2, U32>>:
  match fuel m:
    case 0n _:
      Nil{}
    case _ None{}:
      Nil{}
    case 1n+f Some{+k}:
      +rest = List.drop(&2, U32, l, Nat.add(k, S.len(p)))
      +name = acb.nonslash(rest)
      +after = List.drop(&2, U32, rest, S.len(name))
      List.append(&2, U32, p, name) <> acb.grep.o.go(f, after, p, S.find(after, p, 0n))

# `grep -o "P[^/]*" LINE`: each match of the literal P and the bytes after it up to a `/`, left
# to right, the next looked for after the last
def acb.grep.o(+l: List<&2, U32>, +p: List<&2, U32>) -> List<&2, List<&2, U32>>:
  acb.grep.o.go(1n+S.len(l), l, p, S.find(l, p, 0n))

def acb.unws(ms: List<&2, List<&2, U32>>, +ws: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ms:
    case Nil{}:
      Nil{}
    case +m <> t:
      S.strip(m, ws) <> acb.unws(t, ws)

def acb.tr.agda.go(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>, +ws: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.append(&2, List<&2, U32>, acb.unws(acb.grep.o(l, p), ws), acb.tr.agda.go(t, p, ws))

# `grep -o "$ws/run/code-sources/repos/[^/]*" run/check-cache/agda/libraries | sed "s|^$ws/||"`
def acb.tr.agda(+lib: List<&2, U32>, +ws: String) -> List<&2, List<&2, U32>>:
  acb.tr.agda.go(S.split.lines(lib), S.b(ws ++ "/run/code-sources/repos/"), S.b(ws ++ "/"))

def acb.tr.fixed() -> List<&2, List<&2, U32>>:
  [S.b("run/code-sources/own"), S.b("run/code-sources/curated"), S.b("run/check-cache/agda"), S.b("run/check-cache/hs/hi"),
   S.b("run/check-cache/hs/info"), S.b("run/check-cache/hs/cabal-dirs")]

# A package's candidates in a directory listing: an entry E is PKG-[0-9]* for each PKG that is the
# part of E before a `-` and a digit.  The listing is indexed once by those parts.
def acb.cands.go(xs: List<&2, U32>, +pre: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      acc
    case +c <> +t:
      +hit = Bool.and(U32.is_eq(c, 45), acb.is.digit(Lc.lcl.at(t, 0n)))
      acb.cands.go(t, List.append(&2, U32, pre, [c]), Bool.pick(List<&2, List<&2, U32>>, hit, pre <> acc, acc))

def acb.idx.put(g: Map<&2, List<&2, List<&2, U32>>> & List<&2, List<&2, U32>>, +k: String, +e: List<&2, U32>) -> Map<&2, List<&2, List<&2, U32>>>:
  (m, es) = g
  Map.set(&2, List<&2, List<&2, U32>>, m, k, e <> es)

def acb.idx.add(cs: List<&2, List<&2, U32>>, +e: List<&2, U32>, m: Map<&2, List<&2, List<&2, U32>>>) -> Map<&2, List<&2, List<&2, U32>>>:
  match cs:
    case Nil{}:
      m
    case +c <> t:
      acb.idx.add(t, e, acb.idx.put(Map.get(List<&2, List<&2, U32>>, Nil{}, m, S.str(c)), S.str(c), e))

def acb.tar.ok(cs: List<&2, List<&2, U32>>, +e: List<&2, U32>, +tar: Bool) -> List<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> t:
      +rest = acb.tar.ok(t, e, tar)
      Bool.pick(List<&2, List<&2, U32>>, Bool.or(Bool.not(tar), Nat.is_le(Nat.add(S.len(c), 9n), S.len(e))), c <> rest, rest)

# entries by their PKG parts; tar: only E ending .tar.gz with a byte or more between the digit
# and it may count (the glob PKG-[0-9]*.tar.gz)
def acb.idx(es: List<&2, List<&2, U32>>, +tar: Bool, +m: Map<&2, List<&2, List<&2, U32>>>) -> Map<&2, List<&2, List<&2, U32>>>:
  match es:
    case Nil{}:
      m
    case +e <> t:
      +cs = acb.cands.go(e, Nil{}, Nil{})
      +ok = Bool.pick(Bool, tar, S.suffix(e, S.b(".tar.gz")), True{})
      acb.idx(t, tar, Bool.pick(Map<&2, List<&2, List<&2, U32>>>, ok, acb.idx.add(acb.tar.ok(cs, e, tar), e, m), m))

def acb.idx.of(+es: List<&2, List<&2, U32>>, +tar: Bool) -> Map<&2, List<&2, List<&2, U32>>>:
  acb.idx(es, tar, Map.new(&2, List<&2, List<&2, U32>>))

def acb.prefixed(es: List<&2, List<&2, U32>>, +dir: String) -> List<&2, List<&2, U32>>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> t:
      List.append(&2, U32, S.b(dir ++ "/"), e) <> acb.prefixed(t, dir)

def acb.hk.got(g: Map<&2, List<&2, List<&2, U32>>> & List<&2, List<&2, U32>>, +dir: String) -> List<&2, List<&2, U32>>:
  (m, es) = g
  acb.prefixed(es, dir)

# every name's matches in the two listings
def acb.tr.hk(ns: List<&2, List<&2, U32>>, +src: Map<&2, List<&2, List<&2, U32>>>, +tars: Map<&2, List<&2, List<&2, U32>>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +k = S.str(acb.trim(n))
      List.concat(&2, List<&2, U32>, [acb.hk.got(Map.get(List<&2, List<&2, U32>>, Nil{}, src, k), "run/check-cache/hs/src"),
        acb.hk.got(Map.get(List<&2, List<&2, U32>>, Nil{}, tars, k), "run/code-sources/tarballs"), acb.tr.hk(t, src, tars)])

# realpath's lines that do not leave the workspace (`grep -v '^\.\./'`)
def acb.inside(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = acb.inside(t)
      Bool.pick(List<&2, List<&2, U32>>, S.prefix(l, S.b("../")), rest, l <> rest)

# PROCS (pure) ----------------------------------------------------------------------------------
#
# The box's cores: `nproc`, and under a cgroup v2 quota (`/sys/fs/cgroup/cpu.max`: QUOTA PERIOD,
# or `max PERIOD` for none) at most QUOTA / PERIOD, rounded down.  start's PROCS leaves the
# trainer 4 of them, 2 threads a process: (cores - 4) / 2, at least 1.

def acb.quota(+cm: List<&2, U32>) -> Maybe<&2, Nat>:
  +ws = Lc.lcl.words(cm)
  +q = Lc.lcl.nth(ws, 0n)
  +p = Lc.lcl.nth(ws, 1n)
  Bool.pick(Maybe<&2, Nat>, Bool.and(Bool.and(acb.nat.ok(q), acb.nat.ok(p)), Nat.is_lt(0n, acb.nat(p))), Some{Nat.div(acb.nat(q), acb.nat(p))}, None{})

def acb.quota.min(m: Maybe<&2, Nat>, +n: Nat) -> Maybe<&2, Nat>:
  match m:
    case None{}:
      None{}
    case Some{q}:
      Some{Nat.min(q, n)}

def acb.cores.got(m: Maybe<&2, List<&2, U32>>, +n: Nat) -> Nat:
  match m:
    case None{}:
      n
    case Some{+cm}:
      Maybe.default(&2, Nat, acb.quota.min(acb.quota(cm), n), n)

# the cores for `nproc`'s answer and cpu.max's (None: it did not read)
def acb.cores(+nproc: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> Nat:
  acb.cores.got(m, acb.nat(Lc.lcl.nth(Lc.lcl.words(nproc), 0n)))

def acb.procs.of(+nproc: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> Nat:
  Nat.max(1n, Nat.div(Nat.sub(acb.cores(nproc, m), 4n), 2n))

# Check (pure) ----------------------------------------------------------------------------------
#
# check.txt is the probe's report.txt and the last 3 lines of its log.  It passes when
#   grep -Eq '^render law ([0-9]+)/\1$'                  the render law held on every episode
#   grep -cE 'solved within 1:[0-9]+/[1-9]' = 9          all 9 languages and shapes asked
# and `bend-episode langs` names no language with more tool errors than answered episodes
# (`awk '$4 > 0 && $2 > $3 { print $1 }'`).

def acb.law.line(+l: List<&2, U32>) -> Bool:
  +r = Maybe.default(&2, List<&2, U32>, acb.strip(l, "render law "), Nil{})
  +a = acb.before(r, 47)
  +b = acb.after(r, 47)
  Bool.and(Bool.and(S.prefix(l, S.b("render law ")), S.infix(r, [47])), Bool.and(Bool.and(Nat.is_lt(0n, S.len(a)), acb.digits(a)), S.eq(a, b)))

def acb.any(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(acb.law.line(l), acb.any(t))

def acb.law.ok(+txt: List<&2, U32>) -> Bool:
  acb.any(S.split.lines(txt))

def acb.lead(+xs: List<&2, U32>) -> Nat:
  Ob.obx.lead(xs)

# at the head of xs: [0-9]+/[1-9]
def acb.frac.at(+xs: List<&2, U32>) -> Bool:
  +d = acb.lead(xs)
  +r = List.drop(&2, U32, xs, d)
  +c = Lc.lcl.at(r, 1n)
  Bool.and(Bool.and(Nat.is_lt(0n, d), S.head.is(r, 47)), Bool.and(U32.is_le(49, c), U32.is_le(c, 57)))

def acb.solved.go(fuel: Nat, +l: List<&2, U32>, +p: List<&2, U32>, m: Maybe<&2, Nat>) -> Bool:
  match fuel m:
    case 0n _:
      False{}
    case _ None{}:
      False{}
    case 1n+f Some{+k}:
      +rest = List.drop(&2, U32, l, Nat.add(k, S.len(p)))
      Bool.or(acb.frac.at(rest), acb.solved.go(f, List.drop(&2, U32, l, 1n+k), p, S.find(List.drop(&2, U32, l, 1n+k), p, 0n)))

def acb.solved.line(+l: List<&2, U32>) -> Bool:
  +p = S.b("solved within 1:")
  acb.solved.go(1n+S.len(l), l, p, S.find(l, p, 0n))

def acb.count(ls: List<&2, List<&2, U32>>, +n: Nat) -> Nat:
  match ls:
    case Nil{}:
      n
    case +l <> t:
      acb.count(t, Nat.add(n, Bool.pick(Nat, acb.solved.line(l), 1n, 0n)))

# how many lines of check.txt say a language and shape was asked
def acb.answered(+txt: List<&2, U32>) -> Nat:
  acb.count(S.split.lines(txt), 0n)

def acb.bad.go(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +ws = Lc.lcl.words(l)
      +e = acb.nat(Lc.lcl.nth(ws, 1n))
      +a = acb.nat(Lc.lcl.nth(ws, 2n))
      +n = acb.nat(Lc.lcl.nth(ws, 3n))
      +rest = acb.bad.go(t)
      Bool.pick(List<&2, List<&2, U32>>, Bool.and(Nat.is_lt(0n, n), Nat.is_lt(a, e)), Lc.lcl.nth(ws, 0n) <> rest, rest)

# the languages of a langs table whose tool errors outnumber the episodes the tool answered
def acb.bad(+table: List<&2, U32>) -> List<&2, List<&2, U32>>:
  acb.bad.go(S.split.lines(table))

# `tr '\n' ' '`: each followed by a space
def acb.spaced(xs: List<&2, List<&2, U32>>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      S.str(x) ++ " " ++ acb.spaced(t)

# The setting -----------------------------------------------------------------------------------

type AcbCx is Data:
  AcbCx{ws: String, home: String, bin: String, dep: String, ep: String}

def acb.ws(+c: AcbCx) -> String:
  match c:
    case AcbCx{w, h, b, d, e}:
      w

def acb.home(+c: AcbCx) -> String:
  match c:
    case AcbCx{w, h, b, d, e}:
      h

def acb.bin(+c: AcbCx) -> String:
  match c:
    case AcbCx{w, h, b, d, e}:
      b

def acb.dep(+c: AcbCx) -> String:
  match c:
    case AcbCx{w, h, b, d, e}:
      d

def acb.ep(+c: AcbCx) -> String:
  match c:
    case AcbCx{w, h, b, d, e}:
      e

def acb.or(+name: String, +d: String) -> IO(String):
  do IO<String>:
    v : String <- S.env(name, "")
    return Aa.aac.or(v, d)

def acb.cx() -> IO(AcbCx):
  do IO<AcbCx>:
    +h : String <- S.env("HOME", "")
    +w : String <- acb.or("ACT_WS", "/home/hhefesto/src/formalTransformer")
    +hm : String <- acb.or("ACT_HOME", h)
    +b : String <- acb.or("ACT_BOX_BIN", "/usr/local/bin")
    +d : String <- acb.or("ACT_DEPLOY", "run/v2/gcroot-deploy-agent/bin/deploy")
    +e : String <- acb.or("ACT_EPISODE", "run/agent/gcroot-bend-episode/bin/bend-episode")
    return AcbCx{w, hm, b, d, e}

# a workspace path (an absolute one as it is)
def acb.at(+c: AcbCx, +p: String) -> String:
  Bool.pick(String, S.head.is(S.b(p), 47), p, acb.ws(c) ++ "/" ++ p)

def acb.log(+msg: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- Ck.ck.wall()
    +l : String = Ck.stamp(t) ++ " act-box: " ++ msg
    IO.print(l)
    +f : String <- S.env("ACT_LOG", "")
    Bool.pick(IO(Unit), String.is_empty(f), IO.pure(Unit, Unit{}), S.add(f, S.b(l ++ "\n")))

def acb.fail(+msg: String) -> IO(Unit):
  do IO<Unit>:
    acb.log(msg)
    IO.die(Unit, 1, "act-box: stopped")

def acb.out(+o: Lc.LclOut) -> IO(Unit):
  Ob.obx.pass(o)

# The box -------------------------------------------------------------------------------------

def acb.q(+s: String) -> String:
  Rm.rmt.q(s)

def acb.qs(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      " " ++ acb.q(x) ++ acb.qs(t)

# `env -C DIR HOME=BH PATH=BIN:"$PATH" ENV.. PROG ARGS..`: a command in a directory of the box's
# workspace as the script's rw() ran it (its HOME, the box's nix first on the PATH)
def acb.rw.path(+c: AcbCx, +dir: String, +pre: String, env: List<&2, String>, +prog: String, args: List<&2, String>) -> String:
  "env -C " ++ acb.q(dir) ++ " HOME=" ++ acb.q(acb.home(c)) ++ " PATH=" ++ acb.q(pre ++ acb.bin(c)) ++ ":\"$PATH\"" ++ acb.qs(env)
    ++ acb.qs([prog]) ++ acb.qs(args)

def acb.rw.in(+c: AcbCx, +dir: String, env: List<&2, String>, +prog: String, args: List<&2, String>) -> String:
  acb.rw.path(c, dir, "", env, prog, args)

def acb.rw(+c: AcbCx, env: List<&2, String>, +prog: String, args: List<&2, String>) -> String:
  acb.rw.in(c, acb.ws(c), env, prog, args)

def acb.ssh(+b: Rm.RmtBox, +secs: U32, +cmd: String) -> IO(Lc.LclOut):
  Rm.rmt.ssh(b, secs, cmd)

def acb.ssh.ok(+o: Lc.LclOut, +what: String) -> IO(Unit):
  Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.pure(Unit, Unit{}),
    acb.fail(what ++ " failed on the box (exit " ++ U32.show(Lc.lcl.status(o)) ++ "): " ++ S.str(S.lines.take(List.append(&2, U32, Lc.lcl.err(o), Lc.lcl.out(o)), 10n))))

def acb.must(+b: Rm.RmtBox, +secs: U32, +cmd: String) -> IO(Lc.LclOut):
  do IO<Lc.LclOut>:
    +o : Lc.LclOut <- acb.ssh(b, secs, cmd)
    acb.ssh.ok(o, cmd)
    return o

def acb.mkdirs(+b: Rm.RmtBox, ps: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    o : Lc.LclOut <- acb.must(b, 300, "mkdir -p" ++ acb.qs(ps))
    return Unit{}

# rsync -a EXTRA --partial-dir=.partial -e SSH SRC.. DST (retried); stops the tool when it fails
def acb.send(+b: Rm.RmtBox, extra: List<&2, String>, srcs: List<&2, String>, +dst: String) -> IO(Unit):
  +args = List.concat(&2, String, [["-a"], extra, ["--partial-dir=.partial", "-e", Rm.rmt.rsh(b)], srcs, [dst]])
  do IO<Unit>:
    ok : Bool <- Rm.rmt.rsync(b, acb.l1(args))
    Bool.pick(IO(Unit), ok, IO.pure(Unit, Unit{}), acb.fail("rsync to " ++ dst ++ " failed"))

def acb.to(+b: Rm.RmtBox, +p: String) -> String:
  Rm.rmt.remote(b, p)

# Local programs --------------------------------------------------------------------------------

def acb.run(+secs: U32, +prog: String, args: List<&2, String>) -> IO(Lc.LclOut):
  Lc.lcl.run(secs, prog, acb.l1(args))

def acb.run.ok(+o: Lc.LclOut, +what: String) -> IO(Unit):
  Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.pure(Unit, Unit{}),
    acb.fail(what ++ " failed (exit " ++ U32.show(Lc.lcl.status(o)) ++ "): " ++ S.str(S.lines.take(Lc.lcl.err(o), 10n))))

def acb.readlink(+p: String) -> IO(String):
  do IO<String>:
    +o : Lc.LclOut <- acb.run(60, "readlink", ["-f", p])
    acb.run.ok(o, "readlink -f " ++ p)
    return S.str(S.chomp(Lc.lcl.out(o)))

# readlink -f P, empty when it fails (the script's $(readlink -f ...))
def acb.readlink.or(+p: String) -> IO(String):
  do IO<String>:
    +o : Lc.LclOut <- acb.run(60, "readlink", ["-f", p])
    return S.str(S.chomp(Lc.lcl.out(o)))

def acb.exe(+p: String) -> IO(Bool):
  do IO<Bool>:
    +o : Lc.LclOut <- acb.run(60, "test", ["-x", p])
    return Lc.lcl.ok(o)

def acb.ls(+dir: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(dir)
    return Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{})

def acb.self() -> IO(String):
  do IO<String>:
    argv : List<String> <- IO.args()
    Ob.obx.self(Maybe.default(&1, String, List.head(&1, String, argv), "bend-ops"))

# The records ----------------------------------------------------------------------------------

# a NUL stream's every other field, from the first (odd: the next field is one), across files
type AcbU is Type:
  AcbU{r: S.Rd, odd: Bool, acc: List<&2, List<&2, U32>>, more: Bool}

def acb.u.put(odd: Bool, cut: Bool, +x: List<&2, U32>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match odd:
    case True{}:
      List.append(&2, List<&2, U32>, List.reverse(&2, List<&2, U32>, acb.lines.of(Bool.pick(List<&2, U32>, cut, acb.unit.of(x), x))), acc)
    case False{}:
      acc

def acb.u.got(+cut: Bool, +odd: Bool, acc: List<&2, List<&2, U32>>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(AcbU):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(AcbU, AcbU{r, odd, acc, False{}})
    case Some{+f}:
      IO.pure(AcbU, AcbU{r, Bool.not(odd), acb.u.put(odd, cut, f, acc), True{}})

def acb.u.go(fuel: Nat, +cut: Bool, s: AcbU) -> IO(AcbU):
  match fuel s:
    case 1n+k AcbU{r, +odd, acc, True{}}:
      IO.bind(AcbU, AcbU, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, AcbU, S.Rd.next(r), acb.u.got(cut, odd, acc)), acb.u.go(k, cut))
    case _ AcbU{r, odd, acc, m}:
      IO.pure(AcbU, AcbU{r, odd, acc, m})

def acb.u.fin(s: AcbU) -> IO(Bool & List<&2, List<&2, U32>>):
  match s:
    case AcbU{r, odd, acc, m}:
      do IO<Bool & List<&2, List<&2, U32>>>:
        S.Rd.close(r)
        return (odd, acc)

def acb.u.file(+path: String, +cut: Bool, +odd: Bool, acc: List<&2, List<&2, U32>>) -> IO(Bool & List<&2, List<&2, U32>>):
  do IO<Bool & List<&2, List<&2, U32>>>:
    r : S.Rd <- S.Rd.open(path)
    s : AcbU <- acb.u.go(U32.to_nat(4294967295), cut, AcbU{r, odd, acc, True{}})
    acb.u.fin(s)

def acb.u.at(+p: String, +cut: Bool, x: Bool & List<&2, List<&2, U32>>) -> IO(Bool & List<&2, List<&2, U32>>):
  (odd, acc) = x
  acb.u.file(p, cut, odd, acc)

def acb.u.snd(x: Bool & List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  (odd, acc) = x
  acc

# the files' odd fields (newest first), as `cat FILES | awk -v RS='\0' 'NR % 2 == 1'` takes them
def acb.u.files(ps: List<&2, String>, +cut: Bool, x: Bool & List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, acb.u.snd(x))
    case +p <> t:
      IO.bind(Bool & List<&2, List<&2, U32>>, List<&2, List<&2, U32>>, acb.u.at(p, cut, x), acb.u.files(t, cut))

def acb.named(es: List<&2, List<&2, U32>>, +pre: String, +suf: String, +dir: String) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> t:
      +rest = acb.named(t, pre, suf, dir)
      Bool.pick(List<&2, String>, Bool.and(S.prefix(e, S.b(pre)), S.suffix(e, S.b(suf))), (dir ++ "/" ++ S.str(e)) <> rest, rest)

# a glob DIR/PRE*SUF as the shell expands it (bytewise; no hidden entry unless PRE says so)
def acb.glob(+dir: String, +pre: String, +suf: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +es : List<&2, List<&2, U32>> <- acb.ls(dir)
    return acb.named(Lc.lcl.sort(es), pre, suf, dir)

def acb.langs() -> List<&2, String>:
  ["haskell", "agda", "lean", "nix", "bend"]

def acb.actset() -> IO(String):
  acb.or("ACTSET", "run/v2/act/prompts.nul")

# units.txt: the act set's and the evaluation's units, and every held-out record's id
def acb.units(+c: AcbCx) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +as : String <- acb.actset()
    +ev : List<&2, String> <- acb.glob(acb.at(c, "run/v2/evalset"), "prompts", ".nul")
    +ho : List<&2, String> <- acb.glob(acb.at(c, "run/v2/results"), "", ".holdout.nul")
    +a : List<&2, List<&2, U32>> <- acb.u.files(acb.at(c, as) <> ev, True{}, (True{}, Nil{}))
    +h : List<&2, List<&2, U32>> <- acb.u.files(ho, False{}, (True{}, Nil{}))
    return acb.sort.u(List.append(&2, List<&2, U32>, a, h))

# filter: SRC's pairs whose id is a line of UNITS (awk's `FNR % 2 == 1 { keep = ($0 in u) } keep`)
type AcbK is Type:
  AcbK{r: S.Rd, o: File, keep: Bool, odd: Bool, more: Bool}

def acb.k.emit(o: File, on: Bool, +x: List<&2, U32>) -> IO(File):
  match on:
    case True{}:
      S.emit(o, List.append(&2, U32, x, [0]))
    case False{}:
      IO.pure(File, o)

def acb.k.has(r: Set() & Bool) -> Bool:
  (t, b) = r
  b

def acb.k.in(s: Set(), +x: List<&2, U32>) -> Bool:
  acb.k.has(Set.has(s, S.str(x)))

# an id field decides (a match: Bool.pick would look every text field up too)
def acb.k.keep(odd: Bool, +us: Set(), +f: List<&2, U32>, +keep: Bool) -> Bool:
  match odd:
    case True{}:
      acb.k.in(us, f)
    case False{}:
      keep

def acb.k.got(+us: Set(), o: File, +keep: Bool, +odd: Bool, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(AcbK):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(AcbK, AcbK{r, o, keep, odd, False{}})
    case Some{+f}:
      +k = acb.k.keep(odd, us, f, keep)
      do IO<AcbK>:
        o2 : File <- acb.k.emit(o, k, f)
        return AcbK{r, o2, k, Bool.not(odd), True{}}

def acb.k.go(fuel: Nat, +us: Set(), s: AcbK) -> IO(AcbK):
  match fuel s:
    case 1n+n AcbK{r, o, +keep, +odd, True{}}:
      IO.bind(AcbK, AcbK, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, AcbK, S.Rd.next(r), acb.k.got(us, o, keep, odd)), acb.k.go(n, us))
    case _ AcbK{r, o, keep, odd, m}:
      IO.pure(AcbK, AcbK{r, o, keep, odd, m})

def acb.k.fin(s: AcbK) -> IO(Unit):
  match s:
    case AcbK{r, o, k, d, m}:
      do IO<Unit>:
        S.Rd.close(r)
        File.close(o)

def acb.set(ls: List<&2, List<&2, U32>>, s: Set()) -> Set():
  match ls:
    case Nil{}:
      s
    case l <> t:
      acb.set(t, Set.add(s, S.str(l)))

def acb.filter(+units: String, +src: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +ut : List<&2, U32> <- S.read(units)
    +us : Set() = acb.set(S.split.lines(ut), Set.new())
    r : S.Rd <- S.Rd.open(src)
    o : File <- IO.try(File, File.open(out, "w"))
    s : AcbK <- acb.k.go(U32.to_nat(4294967295), us, AcbK{r, o, False{}, True{}, True{}})
    acb.k.fin(s)

def acb.f.join(chs: List<Chan(Lc.LclOut)>, +bad: Nat) -> IO(Nat):
  match chs:
    case Nil{}:
      IO.pure(Nat, bad)
    case +ch <> t:
      do IO<Nat>:
        +o : Lc.LclOut <- IO.join(Lc.LclOut, ch)
        acb.out(Lc.LclOut{0, Nil{}, Lc.lcl.err(o)})
        acb.f.join(t, Bool.pick(Nat, Lc.lcl.ok(o), bad, 1n+bad))

def acb.f.fork(ls: List<&2, String>, +self: String, +units: String, +c: AcbCx, +out: String) -> IO(List<Chan(Lc.LclOut)>):
  match ls:
    case Nil{}:
      IO.pure(List<Chan(Lc.LclOut)>, Nil{})
    case +l <> t:
      do IO<List<Chan(Lc.LclOut)>>:
        ch : Chan(Lc.LclOut) <- IO.fork(Lc.LclOut, acb.run(86400, self, ["act", "filter", units, acb.at(c, "run/v2/results/" ++ l ++ ".train.nul"), out ++ "/" ++ l ++ ".train.nul"]))
        rest : List<Chan(Lc.LclOut)> <- acb.f.fork(t, self, units, c, out)
        return ch <> rest

# OUT/units.txt, then OUT/LANG.train.nul, a process a language
def acb.records(+c: AcbCx, +out: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +us : List<&2, List<&2, U32>> <- acb.units(c)
    S.write(out ++ "/units.txt", acb.unlines(us))
    +self : String <- acb.self()
    chs : List<Chan(Lc.LclOut)> <- acb.f.fork(acb.langs(), self, out ++ "/units.txt", c, out)
    +bad : Nat <- acb.f.join(chs, 0n)
    Bool.pick(IO(Unit), Nat.is_eq(bad, 0n), IO.pure(Unit, Unit{}), acb.fail(Nat.show(bad) ++ " of the train record filters failed"))
    return us

# The trees ------------------------------------------------------------------------------------

def acb.p0(xs: List<&2, List<&2, U32>>, +c: AcbCx) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      acb.at(c, S.str(acb.trim(x))) <> acb.p0(t, c)

def acb.links.real(+c: AcbCx, ls: List<&2, String>) -> IO(List<&2, List<&2, U32>>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +l <> t:
      do IO<List<&2, List<&2, U32>>>:
        +r : Lc.LclOut <- acb.run(600, "realpath", List.concat(&2, String, [["--relative-to=" ++ acb.ws(c), "--"], l <> t]))
        acb.out(Lc.LclOut{0, Nil{}, Lc.lcl.err(r)})
        return acb.inside(S.split.lines(Lc.lcl.out(r)))

# the own:/curated: directories that are links, resolved inside the workspace
def acb.links(+c: AcbCx, +ds: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match ds:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +d <> t:
      do IO<List<&2, List<&2, U32>>>:
        +f : Lc.LclOut <- acb.run(600, "find", List.concat(&2, String, [acb.p0(d <> t, c), ["-maxdepth", "0", "-type", "l", "-printf", "%p\\0"]]))
        +ls : List<&2, String> = acb.strs(S.split(Lc.lcl.out(f), 0))
        acb.links.real(c, ls)

# trees.txt's lines for units.txt's lines
def acb.trees(+c: AcbCx, +us: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +lib : List<&2, U32> <- S.read(acb.at(c, "run/check-cache/agda/libraries"))
    +src : List<&2, List<&2, U32>> <- acb.ls(acb.at(c, "run/check-cache/hs/src"))
    +tars : List<&2, List<&2, U32>> <- acb.ls(acb.at(c, "run/code-sources/tarballs"))
    +ns : List<&2, List<&2, U32>> = acb.sort.u(acb.collect(us, 1n))
    +hk : List<&2, List<&2, U32>> = acb.tr.hk(ns, acb.idx.of(src, False{}), acb.idx.of(tars, True{}))
    +lk : List<&2, List<&2, U32>> <- acb.links(c, acb.sort.u(acb.collect(us, 2n)))
    return acb.sort.u(List.concat(&2, List<&2, U32>, [acb.collect(us, 0n), acb.tr.agda(lib, acb.ws(c)), acb.tr.fixed(), hk, lk]))

def acb.du.of(+o: Lc.LclOut) -> String:
  +ls = S.split.lines(Lc.lcl.out(o))
  S.str(acb.before(Ob.obx.last(ls), 9))

# `$(wc -l < trees.txt) trees, $(du -shc $(cat trees.txt) | tail -1 | cut -f1)`
def acb.trees.say(+c: AcbCx, +ts: List<&2, List<&2, U32>>) -> IO(Unit):
  do IO<Unit>:
    +o : Lc.LclOut <- acb.run(3600, "du", "-shc" <> acb.p0(ts, c))
    acb.log(Nat.show(List.length(&2, List<&2, U32>, ts)) ++ " trees, " ++ acb.du.of(o))

# --dry-run OUT: setup's three files, nothing sent
def acb.dry(+out: String) -> IO(Unit):
  do IO<Unit>:
    +c : AcbCx <- acb.cx()
    S.mkdir(out)
    acb.log("act set, records (the act units' train records, every held-out record) into " ++ out)
    +us : List<&2, List<&2, U32>> <- acb.records(c, out)
    acb.log("source trees")
    +ts : List<&2, List<&2, U32>> <- acb.trees(c, us)
    S.write(out ++ "/trees.txt", acb.unlines(ts))
    acb.trees.say(c, ts)

# setup ------------------------------------------------------------------------------------------

# the tools' gcroots, each linked on the box to its store path.
# run/v2/gcroot-bend-plan-segment: combine (CorpusV2/Combine.bend) runs it by that path, and S2's
# plan runs combine on the box (2026-10-13: without it S2 stopped at exit 127).
# run/check-cache/ghc-harness: the Haskell checker's ghc (Check.bend cfg.haskell); without it every
# Haskell unit is placed nowhere (2026-10-13)
def acb.gcroots() -> List<&2, String>:
  ["run/v2/gcroot-deploy-agent", "run/gcroot-bend-generate-agent", "run/agent/gcroot-bend-episode", "run/gcroot-ana",
   "run/v2/gcroot-bend-plan-segment", "run/check-cache/ghc-harness"]

def acb.nix.tools() -> List<&2, String>:
  ["nix-daemon", "nix-store", "nix-instantiate", "nix-build", "nix-env", "nix-copy-closure"]

def acb.nix.conf() -> String:
  "experimental-features = nix-command flakes\nbuild-users-group =\nsandbox = false\nmax-jobs = auto\n"

def acb.links.box(ts: List<&2, String>, +b: Rm.RmtBox, +bin: String) -> IO(Unit):
  match ts:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +t <> rest:
      do IO<Unit>:
        o : Lc.LclOut <- acb.must(b, 120, "ln -sfn nix " ++ acb.q(bin ++ "/" ++ t))
        acb.links.box(rest, b, bin)

# the box's nix: the static binary under its tools' names, a root store with no build users
# (substitution and copies only, nothing is built there)
def acb.nix.put(+c: AcbCx, +b: Rm.RmtBox, +n: String) -> IO(Unit):
  +bin = acb.bin(c)
  do IO<Unit>:
    acb.send(b, Nil{}, [n], acb.to(b, bin ++ "/nix"))
    acb.links.box(acb.nix.tools(), b, bin)
    acb.mkdirs(b, ["/etc/nix"])
    +tmp : String <- S.mktemp()
    S.write(tmp ++ "/nix.conf", S.b(acb.nix.conf()))
    acb.send(b, Nil{}, [tmp ++ "/nix.conf"], acb.to(b, "/etc/nix/nix.conf"))
    S.rm(tmp)
    +v : Lc.LclOut <- acb.must(b, 120, acb.q(bin ++ "/nix") ++ " --version")
    acb.out(v)

def acb.nix.got(+st: U32, +c: AcbCx, +b: Rm.RmtBox, +n: String) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(st, 0), acb.log("nix: on the box"),
    Bool.pick(IO(Unit), U32.is_eq(st, 255), acb.fail("the box did not answer"), acb.nix.put(c, b, n)))

def acb.nix.if(x: Bool, +c: AcbCx, +b: Rm.RmtBox, +n: String) -> IO(Unit):
  match x:
    case False{}:
      acb.fail("no static nix: nix build --inputs-from . nixpkgs#pkgsStatic.nix -o run/v3/gcroot-nix-static")
    case True{}:
      do IO<Unit>:
        +o : Lc.LclOut <- acb.ssh(b, 120, "test -x " ++ acb.q(acb.bin(c) ++ "/nix"))
        acb.nix.got(Lc.lcl.status(o), c, b, n)

def acb.box.nix(+c: AcbCx, +b: Rm.RmtBox) -> IO(Unit):
  do IO<Unit>:
    +n : String <- acb.readlink.or(acb.at(c, "run/v3/gcroot-nix-static/bin/nix"))
    x : Bool <- acb.exe(Aa.aac.or(n, "/nonexistent"))
    acb.nix.if(x, c, b, n)

def acb.readlinks(ls: List<&2, String>, +c: AcbCx) -> IO(List<&2, String>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +l <> t:
      do IO<List<&2, String>>:
        +p : String <- acb.readlink(acb.at(c, l))
        rest : List<&2, String> <- acb.readlinks(t, c)
        return p <> rest

def acb.ln.box(ls: List<&2, String>, ps: List<&2, String>, +c: AcbCx, +b: Rm.RmtBox) -> IO(Unit):
  match ls ps:
    case +l <> lt +p <> pt:
      do IO<Unit>:
        o : Lc.LclOut <- acb.must(b, 120, "ln -sfn " ++ acb.q(p) ++ " " ++ acb.q(acb.at(c, l)))
        acb.ln.box(lt, pt, c, b)
    case _ _:
      IO.pure(Unit, Unit{})

# NIX_SSHOPTS: the port, the keepalive, and SSH_OPTS (a sandbox's key)
def acb.nix.ssh(+b: Rm.RmtBox) -> String:
  String.join(List.append(&2, String, ["-p", Rm.rmt.port(b), "-o", "ServerAliveInterval=30", "-o", "StrictHostKeyChecking=no"], Rm.rmt.opts(b)), " ")

def acb.nix.copy(+c: AcbCx, +b: Rm.RmtBox, +ps: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    acb.log("nix copy: " ++ Nat.show(List.length(&2, String, ps)) ++ " tools, their closures substituted on the box")
    +o : Lc.LclOut <- acb.run(86400, "env", List.append(&2, String, ["NIX_SSHOPTS=" ++ acb.nix.ssh(b), "nix", "copy", "-s", "--no-check-sigs", "--to",
      "ssh-ng://" ++ Rm.rmt.host(b) ++ "?remote-program=" ++ acb.bin(c) ++ "/nix-daemon"], ps))
    acb.out(o)
    acb.run.ok(o, "nix copy")

def acb.tracked(+c: AcbCx, +b: Rm.RmtBox, +tmp: String) -> IO(Unit):
  do IO<Unit>:
    acb.log("tracked files")
    +g : Lc.LclOut <- acb.run(600, "git", ["-C", acb.ws(c), "ls-files", "-z"])
    acb.run.ok(g, "git ls-files")
    S.write(tmp ++ "/tracked.nul", Lc.lcl.out(g))
    acb.send(b, ["--from0", "--files-from=" ++ tmp ++ "/tracked.nul"], [acb.ws(c) ++ "/"], acb.to(b, acb.ws(c) ++ "/"))

def acb.in.ws(ns: List<&2, String>, +c: AcbCx, +pre: String) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      (acb.ws(c) ++ "/./" ++ pre ++ n) <> acb.in.ws(t, c, pre)

def acb.there(ps: List<&2, String>) -> IO(List<&2, String>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +p <> t:
      do IO<List<&2, String>>:
        ok : Bool <- S.exists(p)
        +rest : List<&2, String> <- acb.there(t)
        return Bool.pick(List<&2, String>, ok, p <> rest, rest)

def acb.visible(es: List<&2, List<&2, U32>>, +suf: String) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> t:
      +rest = acb.visible(t, suf)
      Bool.pick(List<&2, String>, S.head.is(e, 46), rest, (S.str(e) ++ suf) <> rest)

# run/v2/transcripts/*/NAME, the shell's glob (bytewise, no hidden directory, those there)
def acb.tr.glob(+c: AcbCx, +name: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +ds : List<&2, List<&2, U32>> <- acb.ls(acb.at(c, "run/v2/transcripts"))
    +ps : List<&2, String> = acb.visible(Lc.lcl.sort(ds), "/" ++ name)
    acb.there(acb.in.ws(ps, c, "run/v2/transcripts/"))

def acb.lang.files(ls: List<&2, String>, +dir: String) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      (dir ++ "/" ++ l ++ ".train.nul") <> acb.lang.files(t, dir)

# the act set, its units' train records and every held-out record, S2's filler, the
# evaluation's prompts and held-out transcripts
def acb.records.send(+c: AcbCx, +b: Rm.RmtBox, +tmp: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    acb.log("act set, records (the act units' train records, every held-out record)")
    +us : List<&2, List<&2, U32>> <- acb.records(c, tmp)
    +ho : List<&2, String> <- acb.glob(acb.at(c, "run/v2/results"), "", ".holdout.nul")
    acb.send(b, Nil{}, List.append(&2, String, acb.lang.files(acb.langs(), tmp), ho), acb.to(b, acb.at(c, "run/v2/results") ++ "/"))
    +as : String <- acb.actset()
    acb.mkdirs(b, [S.parent(acb.at(c, as))])
    acb.send(b, Nil{}, [acb.at(c, as)], acb.to(b, S.parent(acb.at(c, as)) ++ "/"))
    # S2's episode windows take their gaps' filler from here (`bend-corpus-v2 s2`; tools/corpus-v2/s2.sh until 2026-10-15)
    acb.send(b, Nil{}, [acb.at(c, "run/v3/s2fill")], acb.to(b, acb.at(c, "run/v3") ++ "/"))
    +t1 : List<&2, String> <- acb.tr.glob(c, "transcripts.holdout.nul")
    +t2 : List<&2, String> <- acb.tr.glob(c, "results.holdout.nul")
    acb.send(b, ["-R"], List.concat(&2, String, [[acb.ws(c) ++ "/./run/v2/evalset"], t1, t2]), acb.to(b, acb.ws(c) ++ "/"))
    return us

def acb.trees.send(+c: AcbCx, +b: Rm.RmtBox, +tmp: String, +us: List<&2, List<&2, U32>>) -> IO(Unit):
  do IO<Unit>:
    acb.log("source trees")
    +ts : List<&2, List<&2, U32>> <- acb.trees(c, us)
    S.write(tmp ++ "/trees.txt", acb.unlines(ts))
    acb.trees.say(c, ts)
    # -r: --files-from turns off -a's recursion
    acb.send(b, ["-r", "--files-from=" ++ tmp ++ "/trees.txt"], [acb.ws(c) ++ "/"], acb.to(b, acb.ws(c) ++ "/"))

def acb.elan.of(ls: List<&2, List<&2, U32>>) -> Maybe<&2, String>:
  match ls:
    case Nil{}:
      None{}
    case +l <> t:
      +hit = Maybe.default(&2, Nat, S.find(l, S.b("-elan-"), 0n), S.len(l))
      Bool.pick(Maybe<&2, String>, acb.is.digit(Lc.lcl.at(l, Nat.add(hit, 6n))), Some{S.str(l)}, acb.elan.of(t))

def acb.elan.got(m: Maybe<&2, String>) -> IO(String):
  match m:
    case Some{e}:
      IO.pure(String, e)
    case None{}:
      do IO<String>:
        acb.fail("no elan in the deploy's closure")
        return ""

# `nix path-info -r DEPLOY | grep -E -- '-elan-[0-9]'`: the first such path
def acb.elan(+c: AcbCx) -> IO(String):
  do IO<String>:
    +dp : String <- acb.readlink(acb.at(c, "run/v2/gcroot-deploy-agent"))
    +o : Lc.LclOut <- acb.run(600, "nix", ["path-info", "-r", dp])
    acb.run.ok(o, "nix path-info")
    acb.elan.got(acb.elan.of(S.split.lines(Lc.lcl.out(o))))

def acb.lake.fin(ok: Bool, +txt: List<&2, U32>) -> IO(Unit):
  match ok:
    case True{}:
      Ob.obx.out(Ob.obx.tail(txt, 3n))
    case False{}:
      do IO<Unit>:
        Ob.obx.out(Ob.obx.tail(txt, 20n))
        acb.fail("lake exe cache get failed")

def acb.text(+o: Lc.LclOut) -> List<&2, U32>:
  List.append(&2, U32, Lc.lcl.out(o), Lc.lcl.err(o))

def acb.lake.get(ok: Bool, +c: AcbCx, +b: Rm.RmtBox, +elan: String, +o1: Lc.LclOut) -> IO(Unit):
  match ok:
    case False{}:
      acb.lake.fin(False{}, acb.text(o1))
    case True{}:
      do IO<Unit>:
        +o2 : Lc.LclOut <- acb.ssh(b, 7200, acb.rw.path(c, acb.at(c, "run/harness/mathlib4"), elan ++ "/bin:", Nil{}, "lake", ["exe", "cache", "get"]))
        acb.lake.fin(Lc.lcl.ok(o2), List.append(&2, U32, acb.text(o1), acb.text(o2)))

# elan's toolchain (lean-toolchain's) and Mathlib's build from its cache, on the box
def acb.lake(+c: AcbCx, +b: Rm.RmtBox) -> IO(Unit):
  do IO<Unit>:
    acb.log("Mathlib: the checkout here, its build from Mathlib's cache there")
    acb.send(b, ["--exclude=.lake"], [acb.at(c, "run/harness/mathlib4")], acb.to(b, acb.at(c, "run/harness") ++ "/"))
    +elan : String <- acb.elan(c)
    +tc : List<&2, U32> <- S.read(acb.at(c, "run/harness/mathlib4/lean-toolchain"))
    +o1 : Lc.LclOut <- acb.ssh(b, 7200, acb.rw.path(c, acb.at(c, "run/harness/mathlib4"), elan ++ "/bin:", Nil{}, "elan",
      List.append(&2, String, ["toolchain", "install"], acb.strs(Lc.lcl.words(tc)))))
    acb.lake.get(Lc.lcl.ok(o1), c, b, elan, o1)

def acb.setup(+host: String, +port: String) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- Ck.ck.wall()
    +c : AcbCx <- acb.cx()
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    +tmp : String <- S.mktemp()
    acb.box.nix(c, b)
    +ps : List<&2, String> <- acb.readlinks(acb.gcroots(), c)
    acb.nix.copy(c, b, ps)
    acb.mkdirs(b, [acb.at(c, "run/v2/act"), acb.at(c, "run/v2/results"), acb.at(c, "run/v3"), acb.at(c, "run/agent"), acb.at(c, "run/harness"),
      acb.at(c, "run/check-cache"), acb.home(c)])
    acb.ln.box(acb.gcroots(), ps, c, b)
    +d : Lc.LclOut <- acb.ssh(b, 120, acb.rw(c, Nil{}, "run/v2/gcroot-deploy-agent/bin/deploy", Nil{}) ++ " 2>&1")
    IO.print(S.str(S.lines.first(Lc.lcl.out(d))))
    acb.tracked(c, b, tmp)
    +us : List<&2, List<&2, U32>> <- acb.records.send(c, b, tmp)
    acb.trees.send(c, b, tmp, us)
    acb.lake(c, b)
    S.rm(tmp)
    +t1 : Nat <- Ck.ck.wall()
    acb.log("setup done in " ++ Nat.show(Nat.div(Nat.sub(t1, t0), 60000n)) ++ " min")

# ckpt -------------------------------------------------------------------------------------------

def acb.same(+here: Maybe<&2, List<&2, U32>>, +there: Maybe<&2, List<&2, U32>>) -> Bool:
  match here there:
    case Some{+a} Some{+b}:
      S.eq(a, b)
    case _ _:
      False{}

def acb.sums.of(+r: Rm.RmtSums) -> List<&2, Lc.LclSum>:
  match r:
    case Rm.RmtSums{a, s}:
      s

# is PATH (a workspace path) the same bytes here and on the box
def acb.sha.same(+c: AcbCx, +b: Rm.RmtBox, +path: String) -> IO(Bool):
  do IO<Bool>:
    +here : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(acb.at(c, path))
    +box : Rm.RmtSums <- Rm.rmt.sums(b, acb.q(acb.at(c, path)))
    return acb.same(here, Lc.lcl.sha.of(acb.sums.of(box), S.b(S.base(path))))

def acb.ckpt(+host: String, +port: String, +ck: String) -> IO(Unit):
  do IO<Unit>:
    +c : AcbCx <- acb.cx()
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    acb.mkdirs(b, [S.parent(acb.at(c, ck))])
    acb.send(b, Nil{}, [acb.at(c, ck)], acb.to(b, acb.at(c, ck)))
    same : Bool <- acb.sha.same(c, b, ck)
    Bool.pick(IO(Unit), same, acb.log(ck ++ " on the box, sha256 matches"), acb.fail(ck ++ ": sha256 differs on the box"))

# The box's cores ----------------------------------------------------------------------------------

def acb.cpu.max(+o: Lc.LclOut) -> Maybe<&2, List<&2, U32>>:
  Bool.pick(Maybe<&2, List<&2, U32>>, Lc.lcl.ok(o), Some{Lc.lcl.out(o)}, None{})

def acb.box.cores(+b: Rm.RmtBox) -> IO(Nat):
  do IO<Nat>:
    +n : Lc.LclOut <- acb.must(b, 60, "nproc")
    +m : Lc.LclOut <- acb.ssh(b, 60, "cat /sys/fs/cgroup/cpu.max")
    +k : Nat = acb.cores(Lc.lcl.out(n), acb.cpu.max(m))
    acb.log("the box: " ++ Nat.show(k) ++ " cores (nproc " ++ S.str(S.chomp(Lc.lcl.out(n))) ++ ", cpu.max "
      ++ Bool.pick(String, Lc.lcl.ok(m), S.str(S.chomp(Lc.lcl.out(m))), "unread") ++ ")")
    return k

# check ------------------------------------------------------------------------------------------

def acb.check.d() -> String:
  "run/v3/act/check"

def acb.check.bad(bs: List<&2, List<&2, U32>>) -> IO(Unit):
  match bs:
    case Nil{}:
      acb.log("check: passed")
    case +x <> t:
      acb.fail("check: the checker failed more than it answered for " ++ acb.spaced(x <> t))

def acb.check.langs(+o: Lc.LclOut) -> IO(Unit):
  do IO<Unit>:
    Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.pure(Unit, Unit{}),
      acb.fail("check: the episodes' log did not read (bend-episode langs exit " ++ U32.show(Lc.lcl.status(o)) ++ "): " ++ S.str(S.chomp(Lc.lcl.err(o)))))
    Ob.obx.out(Lc.lcl.out(o))
    acb.check.bad(acb.bad(Lc.lcl.out(o)))

def acb.check.txt(+c: AcbCx, +b: Rm.RmtBox, +txt: List<&2, U32>) -> IO(Unit):
  +n = acb.answered(txt)
  do IO<Unit>:
    Ob.obx.out(txt)
    Bool.pick(IO(Unit), acb.law.ok(txt), IO.pure(Unit, Unit{}), acb.fail("check: the render law did not hold on every episode"))
    Bool.pick(IO(Unit), Nat.is_eq(n, 9n), IO.pure(Unit, Unit{}), acb.fail("check: " ++ Nat.show(n) ++ " of the 9 languages and shapes answered"))
    # every language's checker answers ana: a language with more episodes ended by a tool error
    # than episodes the tool answered has a checker that cannot place its units (2026-10-13:
    # round 1's Haskell, 2,596 errors and none answered, and Bend's curated units, 611 and 64)
    +t : Lc.LclOut <- acb.ssh(b, 1800, acb.rw(c, Nil{}, acb.ep(c), ["langs", acb.check.d() ++ "/episodes.eplog", "4"]))
    acb.check.langs(t)

def acb.check(+host: String, +port: String, +ck: String) -> IO(Unit):
  +d = acb.check.d()
  do IO<Unit>:
    +c : AcbCx <- acb.cx()
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    o : Lc.LclOut <- acb.must(b, 300, "rm -rf " ++ acb.q(acb.at(c, d)) ++ " " ++ acb.q(acb.at(c, d ++ ".log")))
    acb.mkdirs(b, [S.parent(acb.at(c, d))])
    +k : Nat <- acb.box.cores(b)
    +p : Lc.LclOut <- acb.ssh(b, 14400, acb.rw(c, ["PROCS=" ++ Nat.show(Nat.max(1n, Nat.div(k, 2n))), "THREADS=2"], acb.dep(c),
      ["corpus-v2", "agent-act", ck, d, "1"]) ++ " > " ++ acb.q(acb.at(c, d ++ ".log")) ++ " 2>&1")
    +r : Lc.LclOut <- acb.ssh(b, 120, "cat " ++ acb.q(acb.at(c, d ++ "/report.txt")))
    +l : Lc.LclOut <- acb.ssh(b, 120, "tail -n 3 " ++ acb.q(acb.at(c, d ++ ".log")))
    acb.check.txt(c, b, List.append(&2, U32, Lc.lcl.out(r), Lc.lcl.out(l)))

# start ------------------------------------------------------------------------------------------

def acb.procs.box(+b: Rm.RmtBox) -> IO(String):
  do IO<String>:
    +k : Nat <- acb.box.cores(b)
    return Nat.show(Nat.max(1n, Nat.div(Nat.sub(k, 4n), 2n)))

def acb.procs.got(+env: String, +b: Rm.RmtBox) -> IO(String):
  Bool.pick(IO(String), String.is_empty(env), acb.procs.box(b), IO.pure(String, env))

def acb.running.say(m: Maybe<&2, Nat>) -> IO(Unit):
  match m:
    case Some{+n}:
      Bool.pick(IO(Unit), Nat.is_eq(n, 0n), IO.pure(Unit, Unit{}),
        acb.log("warning: " ++ Nat.show(n) ++ " bend-corpus-v2 processes already run on the box"))
    case None{}:
      IO.pure(Unit, Unit{})

# agent-act detached in a session of its own: `nohup setsid -f` returns at once (the ssh with it),
# the round's output goes to DIR.log, and a hangup does not reach it
def acb.start(+host: String, +port: String, +ck: String, +d: String) -> IO(Unit):
  do IO<Unit>:
    +c : AcbCx <- acb.cx()
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    acb.mkdirs(b, [S.parent(acb.at(c, d))])
    +pe : String <- S.env("PROCS", "")
    +procs : String <- acb.procs.got(pe, b)
    +threads : String <- acb.or("THREADS", "2")
    m : Maybe<&2, Nat> <- Rm.rmt.count(b, "bend-corpus-v2")
    acb.running.say(m)
    o : Lc.LclOut <- acb.must(b, 120, acb.rw(c, ["PROCS=" ++ procs, "THREADS=" ++ threads], "nohup", ["setsid", "-f", acb.dep(c), "corpus-v2", "agent-act", ck, d])
      ++ " > " ++ acb.q(acb.at(c, d ++ ".log")) ++ " 2>&1 < /dev/null")
    acb.log("act: " ++ ck ++ " into " ++ d ++ " on the box (log " ++ d ++ ".log), " ++ procs ++ " processes x " ++ threads ++ " threads")

# pull -------------------------------------------------------------------------------------------

def acb.pull(+host: String, +port: String, +d: String) -> IO(Unit):
  do IO<Unit>:
    +c : AcbCx <- acb.cx()
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    +here : String = acb.at(c, d)
    S.mkdir(here)
    +o : Lc.LclOut <- acb.run(21600, "rsync", ["-a", "--partial-dir=.partial", "-e", Rm.rmt.rsh(b), acb.to(b, here ++ "/accepted"), acb.to(b, here ++ "/agent.nul"),
      acb.to(b, here ++ "/episodes.eplog"), acb.to(b, here ++ "/report.txt"), here ++ "/"])
    acb.out(o)
    +l : Lc.LclOut <- acb.run(21600, "rsync", ["-a", "--partial-dir=.partial", "-e", Rm.rmt.rsh(b), acb.to(b, here ++ ".log"), here ++ ".log"])
    acb.out(l)
    +ls : Lc.LclOut <- acb.run(60, "ls", ["-la", here, here ++ "/accepted"])
    Ob.obx.out(Lc.lcl.out(ls))

# ensure -----------------------------------------------------------------------------------------
#
# act-restart.sh (2026-10-12): the box's sshd drops a client after two missed 10 s keepalives, and
# a saturated link delays the replies, so setup and ckpt are each run again until they pass
# (TRIES times, RETRY_SLEEP apart; rsync goes on from what landed), as this program's own
# subcommands, their output passed on; every copy after them retries by itself (RSYNC_TRIES).

def acb.retry.go(fuel: Nat, +self: String, +args: List<&2, String>, +what: String, +sl: Nat, +i: Nat, ok: Bool) -> IO(Bool):
  match fuel ok:
    case _ True{}:
      IO.pure(Bool, True{})
    case 0n False{}:
      IO.pure(Bool, False{})
    case 1n+f False{}:
      do IO<Bool>:
        acb.log("try " ++ Nat.show(i) ++ " of " ++ what ++ " failed; again in " ++ Nat.show(sl) ++ " s")
        IO.sleep(U32.mul(U32.from_nat(Nat.min(sl, 86400n)), 1000))
        +st : U32 <- Aa.aac.follow(Nil{}, self, args)
        acb.retry.go(f, self, args, what, sl, 1n+i, U32.is_eq(st, 0))

def acb.retry(+tries: Nat, +sl: Nat, +self: String, +args: List<&2, String>, +what: String) -> IO(Bool):
  do IO<Bool>:
    +st : U32 <- Aa.aac.follow(Nil{}, self, args)
    acb.retry.go(Nat.sub(tries, 1n), self, args, what, sl, 1n, U32.is_eq(st, 0))

def acb.resume.log(there: Bool, +c: AcbCx, +b: Rm.RmtBox, +r: String, +d: String) -> IO(Unit):
  match there:
    case True{}:
      acb.send(b, Nil{}, [acb.at(c, r) ++ ".log"], acb.to(b, acb.at(c, d) ++ ".log-resumed"))
    case False{}:
      IO.pure(Unit, Unit{})

def acb.resume.check(there: Bool, +c: AcbCx, +b: Rm.RmtBox, +r: String, +d: String) -> IO(Unit):
  match there:
    case False{}:
      acb.log(r ++ " holds no agent.nul; nothing to compare")
    case True{}:
      do IO<Unit>:
        +here : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(acb.at(c, r) ++ "/agent.nul")
        +box : Rm.RmtSums <- Rm.rmt.sums(b, acb.q(acb.at(c, d) ++ "/agent.nul"))
        Bool.pick(IO(Unit), acb.same(here, Lc.lcl.sha.of(acb.sums.of(box), S.b("agent.nul"))),
          acb.log(r ++ " on the box as " ++ d ++ ", agent.nul's sha256 matches"),
          acb.fail(d ++ " on the box: agent.nul differs from " ++ r ++ "'s; act round not restarted"))

# a local act round (cut to whole records) as DIR on the box, its log beside it
def acb.resume(m: Maybe<&2, String>, +c: AcbCx, +b: Rm.RmtBox, +d: String) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{+r}:
      do IO<Unit>:
        acb.mkdirs(b, [acb.at(c, d)])
        acb.send(b, ["--exclude=*.whole-before-cut"], [acb.at(c, r) ++ "/"], acb.to(b, acb.at(c, d) ++ "/"))
        lg : Bool <- S.exists(acb.at(c, r) ++ ".log")
        acb.resume.log(lg, c, b, r, d)
        an : Bool <- S.exists(acb.at(c, r) ++ "/agent.nul")
        acb.resume.check(an, c, b, r, d)

def acb.ensure.start(m: Maybe<&2, Nat>, +host: String, +port: String, +ck: String, +d: String) -> IO(Unit):
  match m:
    case None{}:
      acb.fail("the box did not answer; act round not started")
    case Some{+n}:
      Bool.pick(IO(Unit), Nat.is_eq(n, 0n), acb.start(host, port, ck, d),
        acb.log("an act round is already running (" ++ Nat.show(n) ++ " bend-corpus-v2 processes); not started"))

def acb.ensure.ok(ok: Bool, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      acb.fail(msg)

def acb.count.show(m: Maybe<&2, Nat>) -> String:
  match m:
    case Some{n}:
      Nat.show(n)
    case None{}:
      "?"

def acb.ensure(+host: String, +port: String, +ck: String, +d: String, r: Maybe<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +c : AcbCx <- acb.cx()
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    +self : String <- acb.self()
    +tries : Nat <- S.env.nat("TRIES", 12n)
    +sl : Nat <- S.env.nat("RETRY_SLEEP", 30n)
    +wait : Nat <- S.env.nat("ENSURE_WAIT", 120n)
    s : Bool <- acb.retry(tries, sl, self, ["act", "setup", host, port], "act setup")
    acb.ensure.ok(s, "act setup failed " ++ Nat.show(tries) ++ " times; act round not restarted")
    acb.log("act setup done")
    k : Bool <- acb.retry(tries, sl, self, ["act", "ckpt", host, port, ck], "act ckpt")
    acb.ensure.ok(k, ck ++ " did not land; act round not restarted")
    acb.resume(r, c, b, d)
    m : Maybe<&2, Nat> <- Rm.rmt.count(b, "bend-corpus-v2")
    acb.ensure.start(m, host, port, ck, d)
    IO.sleep(U32.mul(U32.from_nat(Nat.min(wait, 86400n)), 1000))
    m2 : Maybe<&2, Nat> <- Rm.rmt.count(b, "bend-corpus-v2")
    +t : Lc.LclOut <- acb.ssh(b, 60, "tail -n 1 " ++ acb.q(acb.at(c, d ++ ".log")))
    acb.log("act round " ++ d ++ ": " ++ acb.count.show(m2) ++ " bend-corpus-v2 processes; " ++ d ++ ".log: " ++ S.str(S.chomp(Lc.lcl.out(t))))

# Main -------------------------------------------------------------------------------------------

def acb.usage() -> String:
  "usage: bend-ops act setup HOST PORT | ckpt HOST PORT CKPT | check HOST PORT CKPT | start HOST PORT CKPT DIR\n"
    ++ "       bend-ops act pull HOST PORT DIR | ensure HOST PORT CKPT DIR [RESUME] | --dry-run OUT | procs NPROC [CPU_MAX]\n"
    ++ "  (bend/Box/Act.bend: ACT_WS, ACT_HOME, ACT_BOX_BIN, ACT_DEPLOY, ACT_EPISODE, ACTSET, PROCS, THREADS, ACT_LOG)"

def acb.go(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case "setup" <> +h <> +p <> Nil{}:
      acb.setup(h, p)
    case "ckpt" <> +h <> +p <> +ck <> Nil{}:
      acb.ckpt(h, p, ck)
    case "check" <> +h <> +p <> +ck <> Nil{}:
      acb.check(h, p, ck)
    case "start" <> +h <> +p <> +ck <> +d <> Nil{}:
      acb.start(h, p, ck, d)
    case "pull" <> +h <> +p <> +d <> Nil{}:
      acb.pull(h, p, d)
    case "ensure" <> +h <> +p <> +ck <> +d <> Nil{}:
      acb.ensure(h, p, ck, d, None{})
    case "ensure" <> +h <> +p <> +ck <> +d <> +r <> Nil{}:
      acb.ensure(h, p, ck, d, Some{r})
    case "--dry-run" <> +out <> Nil{}:
      acb.dry(out)
    case "filter" <> +u <> +s <> +o <> Nil{}:
      acb.filter(u, s, o)
    case "procs" <> +n <> Nil{}:
      IO.print(Nat.show(acb.procs.of(S.b(n), None{})))
    case "procs" <> +n <> +cm <> Nil{}:
      IO.print(Nat.show(acb.procs.of(S.b(n), Some{S.b(cm)})))
    case _:
      IO.die(Unit, 2, acb.usage())

def acb.main(xs: List<String>) -> IO(Unit):
  acb.go(acb.l2(xs))
