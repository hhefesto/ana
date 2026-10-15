import Base
import ../Sys.bend as S
import ./Local.bend as Lc

# ActBox: bend-box's modes for an act round (2026-10-15, the plan's Phase 3),
# from run 3's s2-driver.sh and move.sh (2026-10-12), which ran them as shell
# on the box or here:
#
#   bend-box act-stop              stop the act round: the session of the oldest process named
#                                  ACT_PROC (bend-corpus-v2), TERM, ACT_STOP_WAIT (15) s, KILL; then
#                                  the ACT_PROC processes left, or `act round stopped`
#   bend-box cut-frames FILE       an episodes.eplog cut back to whole `EP1 LEN\n` frames (a kill can
#                                  land inside an append): `cut FILE to OFF of SIZE bytes` (the
#                                  whole file kept as FILE.whole-before-cut) and `N whole episodes
#                                  in FILE`
#   bend-box cut-pairs FILE        a NUL-pair file (agent.nul, episodes.nul: id NUL fields NUL) cut
#                                  back to whole pairs: `cut FILE to GOOD of SIZE bytes` (the same
#                                  copy kept) and `FILE: N records`
#
# The scripts' own lines are printed as they printed them.
#
# act-stop is s2-driver's `c=$(pgrep -o -x bend-corpus-v2); [ -n "$c" ] && { s=$(ps -o sid= -p
# $c); pkill -TERM -s $s; sleep 15; pkill -KILL -s $s; }; pgrep -x bend-corpus-v2 || echo 'act
# round stopped'`: every process of the round shares the session `bend-ops act start` (as
# act-box.sh did) started it in, while each job runs under timeout in a process group of its
# own, so the session is what to stop.  The session is read from /proc/PID/stat, not ps; a
# session this program is in itself, or one below 2 (pkill -s 0 is pkill's own session), is
# refused (new: the script would have stopped its own caller).
#
# cut-frames is their frame parser: from offset 0, the header is the first line of the next 40
# bytes (NUL bytes dropped, as bash's $(...) drops them); it must be `EP1 ` and digits, and the
# frame ends header + 1 + LEN bytes on, within the file; else the walk stops there.  LEN is read
# in decimal (bash read a leading zero as octal; the eplog writer never writes one).  cut-pairs
# is move.sh's `awk -v RS='\0' '{ off += length($0) + 1; if (NR % 2 == 0 && off <= size) good =
# off }'`: the offset after the last NUL that ends a pair.  A file at or past 4 GiB is refused
# (File.read_at's offsets are U32).  Every name starts with `abx.`; the pure parts are tested in
# bend/tests/act.bend.

# Frames (pure) -----------------------------------------------------------------------------------

def abx.digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def abx.digits(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(abx.digit(c), abx.digits(t))

def abx.nat(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n)

def abx.next.if(ok: Bool, +off: Nat, +hl: Nat, +len: List<&2, U32>, +size: Nat) -> Maybe<&2, Nat>:
  match ok:
    case False{}:
      None{}
    case True{}:
      +next = Nat.add(Nat.add(off, Nat.add(hl, 1n)), abx.nat(len))
      Bool.pick(Maybe<&2, Nat>, Nat.is_le(next, size), Some{next}, None{})

# The frame at off, given the (up to) 40 bytes there and the file's size:
# the offset after it, or None where the walk stops.  hdr: the first line
# without NUL bytes; LEN: what follows `EP1 `, non-empty digits (at most 12:
# a longer LEN is past any file read here, and a Nat past 2^48 crashes).
def abx.frame.next(+hb: List<&2, U32>, +off: Nat, +size: Nat) -> Maybe<&2, Nat>:
  +hdr = S.no.nul(S.lines.first(hb))
  +len = List.drop(&2, U32, hdr, 4n)
  +ok = Bool.and(S.prefix(hdr, S.b("EP1 ")), Bool.and(Bool.and(Nat.is_lt(0n, S.len(len)), Nat.is_le(S.len(len), 12n)), abx.digits(len)))
  abx.next.if(ok, off, S.len(hdr), len, size)

# a walk's state: where it is, how many whole frames it passed
type AbxW is Data:
  AbxW{off: Nat, n: Nat}

def abx.w.off(+w: AbxW) -> Nat:
  match w:
    case AbxW{o, n}:
      o

def abx.w.n(+w: AbxW) -> Nat:
  match w:
    case AbxW{o, n}:
      n

def abx.step.of(m: Maybe<&2, Nat>, +n: Nat) -> Maybe<&2, AbxW>:
  match m:
    case None{}:
      None{}
    case Some{next}:
      Some{AbxW{next, 1n+n}}

# one frame further over bytes in memory (the tests')
def abx.mem.try(+xs: List<&2, U32>, +size: Nat, +w: AbxW) -> Maybe<&2, AbxW>:
  +off = abx.w.off(w)
  abx.step.of(abx.frame.next(List.take(&2, U32, List.drop(&2, U32, xs, off), 40n), off, size), abx.w.n(w))

def abx.mem.go(fuel: Nat, +xs: List<&2, U32>, +size: Nat, w: AbxW, m: Maybe<&2, AbxW>) -> AbxW:
  match fuel m:
    case _ None{}:
      w
    case 0n Some{w2}:
      w2
    case 1n+f Some{+w2}:
      abx.mem.go(f, xs, size, w2, abx.mem.try(xs, size, w2))

# where the walk over a whole file's bytes stops, and how many frames it passed
def abx.frames.of(+xs: List<&2, U32>) -> AbxW:
  +size = S.len(xs)
  abx.mem.go(1n+size, xs, size, AbxW{0n, 0n}, abx.mem.try(xs, size, AbxW{0n, 0n}))

# Pairs (pure) ------------------------------------------------------------------------------------

# a scan's state: bytes passed, NULs passed, the offset after the last NUL
# that ended a pair, the pairs ended there
type AbxP is Data:
  AbxP{pos: Nat, nuls: Nat, good: Nat, pairs: Nat}

def abx.p.good(+p: AbxP) -> Nat:
  match p:
    case AbxP{a, b, g, q}:
      g

def abx.p.pairs(+p: AbxP) -> Nat:
  match p:
    case AbxP{a, b, g, q}:
      q

def abx.p.byte(+c: U32, +p: AbxP) -> AbxP:
  match p:
    case AbxP{+pos, +nuls, +good, +pairs}:
      +nul = U32.is_eq(c, 0)
      +k = Nat.add(nuls, Bool.pick(Nat, nul, 1n, 0n))
      +ends = Bool.and(nul, Nat.is_eq(Nat.mod(k, 2n), 0n))
      AbxP{1n+pos, k, Bool.pick(Nat, ends, 1n+pos, good), Bool.pick(Nat, ends, Nat.div(k, 2n), pairs)}

def abx.pairs.scan(xs: List<&2, U32>, p: AbxP) -> AbxP:
  match xs:
    case Nil{}:
      p
    case +c <> t:
      abx.pairs.scan(t, abx.p.byte(c, p))

# Files -------------------------------------------------------------------------------------------

def abx.say(+s: String) -> IO(Unit):
  IO.print(s)

def abx.size.got(m: Maybe<&2, Lc.LclSt>, +path: String) -> IO(Nat):
  match m:
    case None{}:
      IO.die(Nat, 1, "bend-box: cannot stat " ++ path)
    case Some{+st}:
      +z = Lc.lcl.st.size(st)
      Bool.pick(IO(Nat), Nat.is_lt(z, U32.to_nat(4294967295)), IO.pure(Nat, z), IO.die(Nat, 1, "bend-box: " ++ path ++ " is 4 GiB or more"))

# a file's size (stat: File.size is a U32), below 4 GiB
def abx.size(+path: String) -> IO(Nat):
  do IO<Nat>:
    m : Maybe<&2, Lc.LclSt> <- Lc.lcl.stat(path)
    abx.size.got(m, path)

def abx.ok(+o: Lc.LclOut, +what: String) -> IO(Unit):
  Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "bend-box: " ++ what ++ " failed: " ++ S.str(Lc.lcl.err(o))))

# `cp F F.whole-before-cut; truncate -s AT F; echo "cut F to AT of SIZE bytes"`
def abx.cut(+path: String, +at: Nat, +size: Nat) -> IO(Unit):
  do IO<Unit>:
    +c : Lc.LclOut <- Lc.lcl.run(3600, "cp", ["--", path, path ++ ".whole-before-cut"])
    abx.ok(c, "cp " ++ path)
    +t : Lc.LclOut <- Lc.lcl.run(600, "truncate", ["-s", Nat.show(at), "--", path])
    abx.ok(t, "truncate " ++ path)
    abx.say("cut " ++ path ++ " to " ++ Nat.show(at) ++ " of " ++ Nat.show(size) ++ " bytes")

def abx.cut.if(short: Bool, +path: String, +at: Nat, +size: Nat) -> IO(Unit):
  match short:
    case True{}:
      abx.cut(path, at, size)
    case False{}:
      IO.pure(Unit, Unit{})

# the frame walk over a file: each header read where it is (File.read_at)
type AbxF is Type:
  AbxF{f: File, w: AbxW, m: Maybe<&2, AbxW>}

def abx.hdr.got(+size: Nat, +w: AbxW, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(AbxF):
  (g, x) = r
  match x:
    case Fail{e}:
      IO.pure(AbxF, AbxF{g, w, None{}})
    case Done{+hb}:
      IO.pure(AbxF, AbxF{g, w, abx.step.of(abx.frame.next(hb, abx.w.off(w), size), abx.w.n(w))})

def abx.hdr(f: File, +size: Nat, +w: AbxW) -> IO(AbxF):
  do IO<AbxF>:
    r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(abx.w.off(w)), 40)
    abx.hdr.got(size, w, r)

def abx.fw.go(fuel: Nat, +size: Nat, s: AbxF) -> IO(File & AbxW):
  match fuel s:
    case _ AbxF{f, w, None{}}:
      IO.pure(File & AbxW, (f, w))
    case 0n AbxF{f, w, Some{w2}}:
      IO.pure(File & AbxW, (f, w2))
    case 1n+k AbxF{f, w, Some{+w2}}:
      IO.bind(AbxF, File & AbxW, abx.hdr(f, size, w2), abx.fw.go(k, size))

def abx.frames.fin(+path: String, +size: Nat, r: File & AbxW) -> IO(Unit):
  (f, +w) = r
  do IO<Unit>:
    File.close(f)
    abx.cut.if(Nat.is_lt(abx.w.off(w), size), path, abx.w.off(w), size)
    abx.say(Nat.show(abx.w.n(w)) ++ " whole episodes in " ++ path)

def abx.cut.frames(+path: String) -> IO(Unit):
  do IO<Unit>:
    +size : Nat <- abx.size(path)
    f : File <- IO.try(File, File.open(path, "r"))
    s : AbxF <- abx.hdr(f, size, AbxW{0n, 0n})
    r : File & AbxW <- abx.fw.go(1n+size, size, s)
    abx.frames.fin(path, size, r)

# the pair scan over a file, 8 MiB a read
type AbxS is Type:
  AbxS{f: File, p: AbxP, more: Bool}

def abx.ps.got(p: AbxP, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(AbxS):
  (g, x) = r
  match x:
    case Fail{e}:
      do IO<AbxS>:
        File.close(g)
        IO.die(AbxS, 1, "bend-box: a read failed")
    case Done{+xs}:
      IO.pure(AbxS, AbxS{g, abx.pairs.scan(xs, p), Bool.not(List.is_empty(&2, U32, xs))})

def abx.ps.step(s: AbxS) -> IO(AbxS):
  match s:
    case AbxS{f, p, m}:
      do IO<AbxS>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 8388608)
        abx.ps.got(p, r)

def abx.ps.go(fuel: Nat, s: AbxS) -> IO(AbxS):
  match fuel s:
    case 1n+k AbxS{f, p, True{}}:
      IO.bind(AbxS, AbxS, abx.ps.step(AbxS{f, p, True{}}), abx.ps.go(k))
    case _ AbxS{f, p, m}:
      IO.pure(AbxS, AbxS{f, p, m})

def abx.pairs.fin(+path: String, +size: Nat, s: AbxS) -> IO(Unit):
  match s:
    case AbxS{f, +p, m}:
      do IO<Unit>:
        File.close(f)
        abx.cut.if(Nat.is_lt(abx.p.good(p), size), path, abx.p.good(p), size)
        abx.say(path ++ ": " ++ Nat.show(abx.p.pairs(p)) ++ " records")

def abx.cut.pairs(+path: String) -> IO(Unit):
  do IO<Unit>:
    +size : Nat <- abx.size(path)
    f : File <- IO.try(File, File.open(path, "r"))
    s : AbxS <- abx.ps.go(4096n, AbxS{f, AbxP{0n, 0n, 0n, 0n}, True{}})
    abx.pairs.fin(path, size, s)

# act-stop ----------------------------------------------------------------------------------------

def abx.after.paren(xs: List<&2, U32>, +best: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      best
    case +c <> +t:
      abx.after.paren(t, Bool.pick(List<&2, U32>, U32.is_eq(c, 41), t, best))

# /proc/PID/stat's session (its 6th field: after the command's last `)`,
# state, ppid, pgrp, session); None when it does not read
def abx.sid.of(+stat: List<&2, U32>) -> Maybe<&2, Nat>:
  +rest = abx.after.paren(stat, Nil{})
  +ws = Lc.lcl.words(rest)
  Bool.pick(Maybe<&2, Nat>, Bool.and(S.infix(stat, [41]), abx.digits(Lc.lcl.nth(ws, 3n))), Lc.lcl.nat(Lc.lcl.nth(ws, 3n)), None{})

def abx.proc() -> IO(String):
  do IO<String>:
    +p : String <- S.env("ACT_PROC", "")
    return Bool.pick(String, String.is_empty(p), "bend-corpus-v2", p)

def abx.left(+proc: String) -> IO(Unit):
  do IO<Unit>:
    +o : Lc.LclOut <- Lc.lcl.run(60, "pgrep", ["-x", proc])
    Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.write(S.str(Lc.lcl.out(o))), abx.say("act round stopped"))

def abx.kill(+sid: Nat, +proc: String, +pid: String) -> IO(Unit):
  do IO<Unit>:
    +wait : Nat <- S.env.nat("ACT_STOP_WAIT", 15n)
    abx.say("act-stop: session " ++ Nat.show(sid) ++ " of " ++ proc ++ " " ++ pid ++ ": TERM, KILL after " ++ Nat.show(wait) ++ " s")
    +t : Lc.LclOut <- Lc.lcl.run(60, "pkill", ["-TERM", "-s", Nat.show(sid)])
    IO.sleep(U32.mul(U32.from_nat(Nat.min(wait, 3600n)), 1000))
    +k : Lc.LclOut <- Lc.lcl.run(60, "pkill", ["-KILL", "-s", Nat.show(sid)])
    abx.left(proc)

def abx.stop.sid(m: Maybe<&2, Nat>, +mine: Maybe<&2, Nat>, +proc: String, +pid: String) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "act-stop: cannot read the session of " ++ proc ++ " " ++ pid)
    case Some{+sid}:
      +own = Maybe.default(&2, Nat, mine, 0n)
      Bool.pick(IO(Unit), Bool.or(Nat.is_lt(sid, 2n), Nat.is_eq(sid, own)),
        IO.die(Unit, 1, "act-stop: refusing session " ++ Nat.show(sid) ++ " (this program's own, or below 2)"),
        abx.kill(sid, proc, pid))

def abx.stop.pid(+pid: String, +proc: String) -> IO(Unit):
  do IO<Unit>:
    +st : List<&2, U32> <- S.read("/proc/" ++ pid ++ "/stat")
    +me : List<&2, U32> <- S.read("/proc/self/stat")
    abx.stop.sid(abx.sid.of(st), abx.sid.of(me), proc, pid)

def abx.stop.got(+pid: List<&2, U32>, +proc: String) -> IO(Unit):
  Bool.pick(IO(Unit), Bool.and(Nat.is_lt(0n, S.len(pid)), abx.digits(pid)), abx.stop.pid(S.str(pid), proc), abx.left(proc))

def abx.act.stop() -> IO(Unit):
  do IO<Unit>:
    +proc : String <- abx.proc()
    +o : Lc.LclOut <- Lc.lcl.run(60, "pgrep", ["-o", "-x", proc])
    abx.stop.got(S.chomp(Lc.lcl.out(o)), proc)
