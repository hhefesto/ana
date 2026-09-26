import Base
import ./Sys.bend as S
import ./Json.bend as J
import ./Clock.bend as Ck

# bend-plan-corpus: shard and plan a JSONL {id, text} corpus in a single pass.
#
#   TOKENIZER=run/code32k.bpe \
#   bend-plan-corpus DATA.jsonl RUN_DIR SIZE BATCH [ARTICLES_PER_SHARD]
#
# Why this exists rather than `wiki-train`: that app extracted each shard with
#   awk -v a=first -v b=last 'NR>b{exit} NR>=a' "$data"
# which rescans from line 1 for every shard, so total reads grow as the square
# of the shard count. Splitting once up front makes it linear.
#
# The corpus tools are the Bend ones (bend/Pack.bend, bend/Prepare.bend,
# bend/PlanSegment.bend), byte-identical to master's Haskell pack-stdin,
# prepare-bpe-stdin and plan-segment (docs/BEND-CORPUS-TOOLS.md records the
# comparison). They read and write files, not pipes, so every shard passes
# through a NUL-framed file on disk.
#
# Shards are prepared in parallel, one single-threaded process each (a fork
# pool here, each worker running the tools): the Bend runtime scales this
# allocation-heavy work to about two cores inside one process, while separate
# processes scale with the cores. Planning (the cumulative step count, the
# completeness assertions) stays a sequential pass.
#
# The plan format, the segment records, the identity string and the
# offset-invariant document split are unchanged, so a plan written here is
# byte-identical to one written with the Haskell tools.
#
# Env:
#   TOKENIZER    the .bpe artifact (required).
#   PACK_TARGET  pack documents up to this many bytes before tokenizing, so
#                short documents survive windowing (128 KB clears 98% of bytes
#                at context 1024, against 52% unpacked). Pair it with a smaller
#                PER: at a 128 KB target, PER=2000 keeps a shard's text small.
#   PACK_GROUP   pack only within a repository (ids must be repo/path).
#   JOBS         shards prepared at once (default: available memory / 3 GB,
#                at most the core count; a 23 MB shard peaks near 1.7 GB).
#   PRUNE_PARTS  1 (default) deletes each part once its corpus exists.
#   BEND_PACK, BEND_PREPARE, BEND_PLAN_SEGMENT  the tools (default: bend-pack,
#                bend-prepare, bend-plan-segment in BEND_TOOLS when that is
#                set, else on PATH).
#
# Paths are relative to the working directory: run it from the repository
# root.  Progress lines are stamped in Mexico City time (UTC-6).

# Configuration ---------------------------------------------------------------

type Pc is Data:
  Pc{data: String, run: String, size: String, batch: String, per: String, pern: Nat, tok: String, pack: String, group: Bool, prune: Bool, bp: String, br: String, bs: String}

def Pc.run(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      r

def Pc.size(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      z

def Pc.batch(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      b

def Pc.per(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      p

def Pc.pern(+c: Pc) -> Nat:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      n

def Pc.tok(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      t

def Pc.pack(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      k

def Pc.group(+c: Pc) -> Bool:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      g

def Pc.prune(+c: Pc) -> Bool:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      u

def Pc.bp(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      bp

def Pc.br(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      br

def Pc.bs(+c: Pc) -> String:
  match c:
    case Pc{d, r, z, b, p, n, t, k, g, u, bp, br, bs}:
      bs

# is the run packed (PACK_TARGET set and not empty)
def Pc.packed(+c: Pc) -> Bool:
  Bool.not(String.is_empty(Pc.pack(c)))

def big() -> Nat:
  1000000000n

# a long run's timeout, in seconds (the shim needs one)
def forever() -> U32:
  2000000

def say(+msg: String) -> IO(Unit):
  Ck.log(msg)

# Names -------------------------------------------------------------------------

def pad6(+k: Nat) -> String:
  +s = Nat.show(k)
  String.concat(List.replicate(String, Nat.sub(6n, String.length(s)), "0")) ++ s

def part.of(+c: Pc, +k: Nat) -> String:
  Pc.run(c) ++ "/parts/part-" ++ pad6(k)

def corpus.of(+c: Pc, +k: Nat) -> String:
  Pc.run(c) ++ "/shard-" ++ Nat.show(k) ++ "-" ++ Pc.size(c) ++ ".corpus"

# Words and lines ---------------------------------------------------------------

def nonempty(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      +r = nonempty(more)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(x), 0n), r, x <> r)

# the words of a line (separated by spaces or tabs, as `read` splits them)
def tab.sp(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, U32.is_eq(h, 9), 32, h) <> tab.sp(t)

def wds(+l: List<&2, U32>) -> List<&2, List<&2, U32>>:
  nonempty(S.split(tab.sp(l), 32))

def nth(xs: List<&2, List<&2, U32>>, n: Nat) -> List<&2, U32>:
  match xs n:
    case x <> more 0n:
      x
    case x <> more 1n+k:
      nth(more, k)
    case Nil{} _:
      Nil{}

def nat.of(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n)

# the first word of what a command printed (`cut -d ' ' -f 1`)
def first.word(+xs: List<&2, U32>) -> String:
  S.str(nth(S.split(S.lines.first(xs), 32), 0n))

# Splitting: DATA in files of PER lines, part-000000, part-000001, ... ----------
# (what `split -l PER -d -a 6` wrote: part N holds documents [N*PER,
# (N+1)*PER), exactly the offsets the planner needs)

# A split in progress: no part open (the next is k), a part open with i
# lines, or the end (k parts written).
type Pt is Type:
  Pnone{rd: S.Rd, k: Nat}
  Popen{rd: S.Rd, f: File, k: Nat, i: Nat}
  Pdone{k: Nat}

def pt.full(full: Bool, rd: S.Rd, f: File, +k: Nat, +i: Nat) -> IO(Pt):
  match full:
    case True{}:
      do IO<Pt>:
        File.close(f)
        return Pnone{rd, 1n+k}
    case False{}:
      IO.pure(Pt, Popen{rd, f, k, i})

def pt.line(+per: Nat, rd: S.Rd, f: File, +k: Nat, +i: Nat, l: List<&2, U32>) -> IO(Pt):
  do IO<Pt>:
    g : File <- S.emit(f, S.append(l, [10]))
    pt.full(Nat.is_eq(1n+i, per), rd, g, k, 1n+i)

def pt.open(+pre: String, +per: Nat, rd: S.Rd, +k: Nat, l: List<&2, U32>) -> IO(Pt):
  do IO<Pt>:
    f : File <- IO.try(File, File.open(pre ++ pad6(k), "w"))
    pt.line(per, rd, f, k, 0n, l)

def pt.got.none(+pre: String, +per: Nat, rd: S.Rd, +k: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Pt):
  match m:
    case None{}:
      do IO<Pt>:
        S.Rd.close(rd)
        return Pdone{k}
    case Some{l}:
      pt.open(pre, per, rd, k, l)

def pt.got.open(+per: Nat, rd: S.Rd, f: File, +k: Nat, +i: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Pt):
  match m:
    case None{}:
      do IO<Pt>:
        File.close(f)
        S.Rd.close(rd)
        return Pdone{1n+k}
    case Some{l}:
      pt.line(per, rd, f, k, i, l)

def pt.pair.none(+pre: String, +per: Nat, +k: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pt):
  (rd, m) = r
  pt.got.none(pre, per, rd, k, m)

def pt.pair.open(+per: Nat, f: File, +k: Nat, +i: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pt):
  (rd, m) = r
  pt.got.open(per, rd, f, k, i, m)

def pt.step(+pre: String, +per: Nat, p: Pt) -> IO(Pt):
  match p:
    case Pnone{rd, +k}:
      do IO<Pt>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pt.pair.none(pre, per, k, r)
    case Popen{rd, f, +k, +i}:
      do IO<Pt>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pt.pair.open(per, f, k, i, r)
    case Pdone{k}:
      IO.pure(Pt, Pdone{k})

def pt.go(fuel: Nat, +pre: String, +per: Nat, p: Pt) -> IO(Nat):
  match fuel p:
    case 1n+q Pnone{rd, k}:
      IO.bind(Pt, Nat, pt.step(pre, per, Pnone{rd, k}), pt.go(q, pre, per))
    case 1n+q Popen{rd, f, k, i}:
      IO.bind(Pt, Nat, pt.step(pre, per, Popen{rd, f, k, i}), pt.go(q, pre, per))
    case _ Pdone{k}:
      IO.pure(Nat, k)
    case 0n Pnone{rd, k}:
      do IO<Nat>:
        S.Rd.close(rd)
        IO.die(Nat, 1, "plan-corpus: the split ran out of fuel")
    case 0n Popen{rd, f, k, i}:
      do IO<Nat>:
        File.close(f)
        S.Rd.close(rd)
        IO.die(Nat, 1, "plan-corpus: the split ran out of fuel")

def split.parts(+data: String, +pre: String, +per: Nat) -> IO(Nat):
  do IO<Nat>:
    rd : S.Rd <- S.Rd.lines(data)
    pt.go(big(), pre, per, Pnone{rd, 0n})

# A part as NUL-framed (id, text) pairs ----------------------------------------
# (jq --raw-output0 '.id, .text', with the text's NULs removed as
# `explode | map(select(. != 0)) | implode` does: web text holds the odd NUL,
# which --raw-output0 refuses; the bash applied that filter only to parts
# holding a \u0000 escape, which gives the same bytes)

# A conversion in progress: the lines read, whether to read on, whether
# every line so far was a corpus line.
type Nw is Type:
  Nw{rd: S.Rd, f: File, n: Nat, go: Bool, ok: Bool}

def nw.doc(rd: S.Rd, f: File, +n: Nat, d: Maybe<&2, J.Doc>) -> IO(Nw):
  match d:
    case None{}:
      IO.pure(Nw, Nw{rd, f, n, False{}, False{}})
    case Some{J.Doc{id, t}}:
      do IO<Nw>:
        g : File <- S.emit(f, S.append(id, 0 <> S.append(J.nonul(t), [0])))
        return Nw{rd, g, n, True{}, True{}}

# a blank line holds no JSON value (jq skips it)
def nw.line(blank: Bool, rd: S.Rd, f: File, +n: Nat, +l: List<&2, U32>) -> IO(Nw):
  match blank:
    case True{}:
      IO.pure(Nw, Nw{rd, f, n, True{}, True{}})
    case False{}:
      nw.doc(rd, f, n, J.doc(l))

def nw.got(rd: S.Rd, f: File, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Nw):
  match m:
    case None{}:
      IO.pure(Nw, Nw{rd, f, n, False{}, True{}})
    case Some{+l}:
      nw.line(J.ws.only(l), rd, f, 1n+n, l)

def nw.pair(f: File, +n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Nw):
  (rd, m) = r
  nw.got(rd, f, n, m)

def nw.step(w: Nw) -> IO(Nw):
  match w:
    case Nw{rd, f, +n, g, ok}:
      do IO<Nw>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        nw.pair(f, n, r)

# 0: every line converted, else the number of the first line that is not a
# corpus line
def nw.go(fuel: Nat, w: Nw) -> IO(Nat):
  match fuel w:
    case 1n+p Nw{rd, f, n, True{}, ok}:
      IO.bind(Nw, Nat, nw.step(Nw{rd, f, n, True{}, ok}), nw.go(p))
    case _ Nw{rd, f, +n, g, ok}:
      do IO<Nat>:
        S.Rd.close(rd)
        File.close(f)
        return Bool.pick(Nat, ok, 0n, n)

def nul.write(+part: String, +nul: String) -> IO(Nat):
  do IO<Nat>:
    rd : S.Rd <- S.Rd.lines(part)
    f : File <- IO.try(File, File.open(nul, "w"))
    nw.go(big(), Nw{rd, f, 0n, True{}, True{}})

# Preparing a shard: part -> NUL stream -> [pack] -> FTCC corpus ---------------
# Every intermediate is a file; the corpus appears under its final name only
# once complete (written to .tmp, then renamed), so an interrupted run never
# leaves a short corpus that looks finished. On a packed run the pack counts
# persist beside the corpus, for the completeness assertion below. The answer
# is whether the shard is prepared.

# `cat LOG` after a failure's first line
def show.log(+head: String, +log: String) -> IO(Bool):
  do IO<Bool>:
    xs : List<&2, U32> <- S.read(log)
    say(head)
    IO.print_err(S.str(S.chomp(xs)))
    return False{}

def mv.if(there: Bool, +a: String, +c: String) -> IO(Unit):
  match there:
    case True{}:
      S.mv(a, c)
    case False{}:
      IO.pure(Unit, Unit{})

def rm.if(yes: Bool, +p: String) -> IO(Unit):
  match yes:
    case True{}:
      S.rm(p)
    case False{}:
      IO.pure(Unit, Unit{})

def prep.prepared(ok: Bool, +c: Pc, +k: Nat, +nul: String) -> IO(Bool):
  match ok:
    case False{}:
      show.log("plan-corpus: shard " ++ Nat.show(k) ++ " failed to prepare from " ++ part.of(c, k) ++ ":", corpus.of(c, k) ++ ".log")
    case True{}:
      do IO<Bool>:
        S.rm(nul)
        S.rm(corpus.of(c, k) ++ ".log")
        +pk : Bool <- S.exists(corpus.of(c, k) ++ ".pack.tmp")
        mv.if(pk, corpus.of(c, k) ++ ".pack.tmp", corpus.of(c, k) ++ ".pack")
        S.mv(corpus.of(c, k) ++ ".tmp", corpus.of(c, k))
        # The split doubles the corpus on disk. Drop each part once its
        # corpus exists; an interrupted run re-splits from the source and
        # skips shards already prepared, so this costs a rescan rather than
        # correctness.
        rm.if(Pc.prune(c), part.of(c, k))
        return True{}

def prep.prepare(+c: Pc, +k: Nat, +nul: String) -> IO(Bool):
  +corpus = corpus.of(c, k)
  do IO<Bool>:
    +st : U32 <- S.run.log(".", [], forever(), Pc.br(c), ["--threads", "1", Pc.tok(c), nul, corpus ++ ".tmp"], corpus ++ ".log")
    prep.prepared(U32.is_eq(st, 0), c, k, nul)

# `sed -n 's/^pack-stdin: \([0-9]*\) documents in, \([0-9]*\) packed.*/\1 \2/p'`
def digits(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, Bool.and(U32.is_le(48, h), U32.is_le(h, 57)), h <> digits(t), Nil{})

def stat.after(+a: List<&2, U32>, +r: List<&2, U32>) -> List<&2, U32>:
  +b = digits(r)
  Bool.pick(List<&2, U32>, S.prefix(List.drop(&2, U32, r, S.len(b)), S.b(" packed")), S.append(a, 32 <> S.append(b, [10])), Nil{})

def stat.line(+l: List<&2, U32>) -> List<&2, U32>:
  +r = List.drop(&2, U32, l, 12n)
  +a = digits(r)
  +rest = List.drop(&2, U32, r, S.len(a))
  +mid = S.b(" documents in, ")
  Bool.pick(List<&2, U32>, Bool.and(S.prefix(l, S.b("pack-stdin: ")), S.prefix(rest, mid)), stat.after(a, List.drop(&2, U32, rest, S.len(mid))), Nil{})

def stat.lines(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      S.append(stat.line(l), stat.lines(more))

def prep.stats(empty: Bool, +c: Pc, +k: Nat, +stats: List<&2, U32>, +nul: String) -> IO(Bool):
  match empty:
    case True{}:
      show.log("plan-corpus: shard " ++ Nat.show(k) ++ " produced no pack stats line:", corpus.of(c, k) ++ ".pack.log")
    case False{}:
      do IO<Bool>:
        S.write(corpus.of(c, k) ++ ".pack.tmp", stats)
        S.rm(nul)
        S.rm(corpus.of(c, k) ++ ".pack.log")
        prep.prepare(c, k, part.of(c, k) ++ ".packed.nul")

def prep.packed(ok: Bool, +c: Pc, +k: Nat, +nul: String) -> IO(Bool):
  match ok:
    case False{}:
      show.log("plan-corpus: shard " ++ Nat.show(k) ++ " pack failed:", corpus.of(c, k) ++ ".pack.log")
    case True{}:
      do IO<Bool>:
        log : List<&2, U32> <- S.read(corpus.of(c, k) ++ ".pack.log")
        +stats : List<&2, U32> = stat.lines(S.split.lines(log))
        prep.stats(Nat.is_eq(S.len(stats), 0n), c, k, stats, nul)

def group.flag(g: Bool) -> List<String>:
  match g:
    case True{}:
      ["--group"]
    case False{}:
      []

def prep.pack(packing: Bool, +c: Pc, +k: Nat, +nul: String) -> IO(Bool):
  match packing:
    case True{}:
      # The prefix carries the shard index because ids restart per shard
      # and must stay globally distinct.
      do IO<Bool>:
        +st : U32 <- S.run.log(".", [], forever(), Pc.bp(c),
          List.append(&1, String, ["--threads", "1", nul, part.of(c, k) ++ ".packed.nul", "--target", Pc.pack(c), "--prefix", "pack" ++ Nat.show(k)],
            List.append(&1, String, group.flag(Pc.group(c)), ["--stats"])),
          corpus.of(c, k) ++ ".pack.log")
        prep.packed(U32.is_eq(st, 0), c, k, nul)
    case False{}:
      prep.prepare(c, k, nul)

def prep.nul(bad: Nat, +c: Pc, +k: Nat) -> IO(Bool):
  match bad:
    case 0n:
      prep.pack(Pc.packed(c), c, k, part.of(c, k) ++ ".nul")
    case 1n+j:
      do IO<Bool>:
        say("plan-corpus: shard " ++ Nat.show(k) ++ ": line " ++ Nat.show(bad) ++ " of " ++ part.of(c, k) ++ " is not an {\"id\", \"text\"} object")
        return False{}

def prep.part(have: Bool, +c: Pc, +k: Nat) -> IO(Bool):
  match have:
    case False{}:
      do IO<Bool>:
        say("plan-corpus: shard " ++ Nat.show(k) ++ " has no part (" ++ part.of(c, k) ++ ")")
        return False{}
    case True{}:
      do IO<Bool>:
        +bad : Nat <- nul.write(part.of(c, k), part.of(c, k) ++ ".nul")
        prep.nul(bad, c, k)

def prep.if(there: Bool, +c: Pc, +k: Nat) -> IO(Bool):
  match there:
    case True{}:
      IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        +have : Bool <- S.exists(part.of(c, k))
        prep.part(have, c, k)

def prep(+c: Pc, +k: Nat) -> IO(Bool):
  do IO<Bool>:
    +there : Bool <- S.exists(corpus.of(c, k))
    prep.if(there, c, k)

# The pool: JOBS workers pull shard numbers; each answers how many failed ------

type Sj is Type:
  Sj{k: Nat}

type Pw is Type:
  Pw{go: Bool, bad: Nat}

def pw.got(+c: Pc, m: Maybe<&1, Sj>, +bad: Nat) -> IO(Pw):
  match m:
    case None{}:
      IO.pure(Pw, Pw{False{}, bad})
    case Some{Sj{+k}}:
      do IO<Pw>:
        +ok : Bool <- prep(c, k)
        return Pw{True{}, Nat.add(bad, Bool.pick(Nat, ok, 0n, 1n))}

def pw.step(+c: Pc, +q: Chan(Sj), w: Pw) -> IO(Pw):
  match w:
    case Pw{g, +bad}:
      do IO<Pw>:
        m : Maybe<&1, Sj> <- Chan.recv(Sj, q)
        pw.got(c, m, bad)

def pw.go(fuel: Nat, +c: Pc, +q: Chan(Sj), w: Pw) -> IO(Nat):
  match fuel w:
    case 1n+p Pw{True{}, bad}:
      IO.bind(Pw, Nat, pw.step(c, q, Pw{True{}, bad}), pw.go(p, c, q))
    case _ Pw{g, bad}:
      IO.pure(Nat, bad)

def pw.fork(n: Nat, +c: Pc, +q: Chan(Sj)) -> IO(List<Chan(Nat)>):
  match n:
    case 0n:
      IO.pure(List<Chan(Nat)>, Nil{})
    case 1n+m:
      do IO<List<Chan(Nat)>>:
        ch : Chan(Nat) <- IO.fork(Nat, pw.go(big(), c, q, Pw{True{}, 0n}))
        rest : List<Chan(Nat)> <- pw.fork(m, c, q)
        return ch <> rest

def pw.join(chs: List<Chan(Nat)>, +bad: Nat) -> IO(Nat):
  match chs:
    case Nil{}:
      IO.pure(Nat, bad)
    case +ch <> more:
      do IO<Nat>:
        +b : Nat <- IO.join(Nat, ch)
        pw.join(more, Nat.add(bad, b))

def sj.send(n: Nat, +q: Chan(Sj), +k: Nat) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+m:
      do IO<Unit>:
        ok : Bool <- Chan.send(Sj, q, Sj{k})
        sj.send(m, q, 1n+k)

def pool(+c: Pc, +shards: Nat, +jobs: Nat) -> IO(Nat):
  do IO<Nat>:
    +q : Chan(Sj) <- Chan.new(Sj, U32.from_nat(jobs))
    chs : List<Chan(Nat)> <- pw.fork(jobs, c, q)
    sj.send(shards, q, 0n)
    Chan.close(Sj, q)
    pw.join(chs, 0n)

# Planning: one segment line per shard, every shard asserted complete ---------

type Pl is Data:
  Pl{k: Nat, cum: Nat, segs: List<&2, List<&2, U32>>}

def say.if(yes: Bool, +msg: String) -> IO(Unit):
  match yes:
    case True{}:
      say(msg)
    case False{}:
      IO.pure(Unit, Unit{})

def seg.line(+c: Pc, +shards: Nat, +k: Nat, +cum: Nat, segs: List<&2, List<&2, U32>>, +ws: List<&2, List<&2, U32>>) -> IO(Pl):
  +steps = nth(ws, 6n)
  +cum2 = Nat.add(cum, nat.of(steps))
  +line = S.b("segment " ++ Nat.show(k) ++ " " ++ Nat.show(Nat.mul(k, Pc.pern(c))) ++ " " ++ S.str(nth(ws, 2n)) ++ " " ++ S.str(nth(ws, 3n)) ++ " "
    ++ S.str(nth(ws, 4n)) ++ " " ++ S.str(nth(ws, 5n)) ++ " " ++ S.str(steps) ++ " " ++ Nat.show(cum) ++ " " ++ Nat.show(cum2) ++ "\n")
  do IO<Pl>:
    say.if(Nat.is_eq(Nat.mod(k, 100n), 0n), "plan-corpus: shard " ++ Nat.show(k) ++ "/" ++ Nat.show(shards) ++ "  cumulative steps " ++ Nat.show(cum2))
    return Pl{1n+k, cum2, line <> segs}

def fail.if(bad: Bool, +msg: String) -> IO(Unit):
  match bad:
    case True{}:
      IO.die(Unit, 1, msg)
    case False{}:
      IO.pure(Unit, Unit{})

# Assert the shard is complete. A producer that dies mid-stream leaves a
# corpus that is structurally valid but short, and nothing downstream would
# notice. This caught shard 83 holding 1,625 of 4,000 documents.
#
# Packing changes what to count: the corpus now holds packed documents, far
# fewer than PER, so the check moves upstream to what the packer was fed.
# The second half asserts that everything the packer emitted reached the
# corpus.
def seg.checks(+c: Pc, +shards: Nat, +k: Nat, +cum: Nat, segs: List<&2, List<&2, U32>>, +record: List<&2, U32>, +pin: List<&2, U32>, +pout: List<&2, U32>) -> IO(Pl):
  +ws = wds(S.lines.first(record))
  +per = S.b(Pc.per(c))
  +docs = nth(ws, 2n)
  +last = Nat.is_eq(k, Nat.sub(shards, 1n))
  +packing = Pc.packed(c)
  do IO<Pl>:
    fail.if(Bool.or(Bool.not(S.eq(nth(ws, 0n), S.b("segment"))), Bool.not(S.eq(nth(ws, 1n), S.b(Nat.show(Nat.mul(k, Pc.pern(c))))))),
      "plan-corpus: invalid segment plan for shard " ++ Nat.show(k) ++ ": " ++ S.str(S.chomp(record)))
    fail.if(Bool.and(packing, Bool.and(Bool.not(S.eq(pin, per)), Bool.not(last))),
      "plan-corpus: shard " ++ Nat.show(k) ++ " is short: packed " ++ S.str(pin) ++ " of " ++ Pc.per(c) ++ " documents")
    fail.if(Bool.and(packing, Bool.not(S.eq(docs, pout))),
      "plan-corpus: shard " ++ Nat.show(k) ++ " lost documents: packer emitted " ++ S.str(pout) ++ ", corpus holds " ++ S.str(docs))
    fail.if(Bool.and(Bool.not(packing), Bool.and(Bool.not(S.eq(docs, per)), Bool.not(last))),
      "plan-corpus: shard " ++ Nat.show(k) ++ " is short: " ++ S.str(docs) ++ " of " ++ Pc.per(c) ++ " documents\n  delete " ++ corpus.of(c, k) ++ " and re-run")
    seg.line(c, shards, k, cum, segs, ws)

def seg.out(+c: Pc, +shards: Nat, +k: Nat, +cum: Nat, segs: List<&2, List<&2, U32>>, o: S.Out, +pin: List<&2, U32>, +pout: List<&2, U32>) -> IO(Pl):
  match o:
    case S.Out{+st, +t}:
      do IO<Pl>:
        fail.if(U32.is_ne(st, 0), "plan-corpus: plan-segment failed for shard " ++ Nat.show(k) ++ " (exit " ++ U32.show(st) ++ "): " ++ S.str(S.chomp(t)))
        seg.checks(c, shards, k, cum, segs, t, pin, pout)

def seg.run(+c: Pc, +shards: Nat, +k: Nat, +cum: Nat, segs: List<&2, List<&2, U32>>, +pin: List<&2, U32>, +pout: List<&2, U32>) -> IO(Pl):
  do IO<Pl>:
    o : S.Out <- S.run(".", [], forever(), Pc.bs(c), ["--threads", "1", corpus.of(c, k), Nat.show(Nat.mul(k, Pc.pern(c))), Pc.batch(c), Pc.size(c)], Nil{})
    seg.out(c, shards, k, cum, segs, o, pin, pout)

def seg.sidecar(have: Bool, +c: Pc, +shards: Nat, +k: Nat, +cum: Nat, segs: List<&2, List<&2, U32>>) -> IO(Pl):
  match have:
    case False{}:
      IO.die(Pl, 1, "plan-corpus: shard " ++ Nat.show(k) ++ " has no pack-count sidecar (" ++ corpus.of(c, k) ++ ".pack)\n"
        ++ "  The corpus predates packing or was prepared by an older script,\n"
        ++ "  so its completeness cannot be asserted. Delete " ++ corpus.of(c, k) ++ " and re-run.")
    case True{}:
      do IO<Pl>:
        xs : List<&2, U32> <- S.read(corpus.of(c, k) ++ ".pack")
        +ws : List<&2, List<&2, U32>> = wds(S.lines.first(xs))
        seg.run(c, shards, k, cum, segs, nth(ws, 0n), nth(ws, 1n))

def seg.pack(packing: Bool, +c: Pc, +shards: Nat, +k: Nat, +cum: Nat, segs: List<&2, List<&2, U32>>) -> IO(Pl):
  match packing:
    case True{}:
      do IO<Pl>:
        +have : Bool <- S.exists(corpus.of(c, k) ++ ".pack")
        seg.sidecar(have, c, shards, k, cum, segs)
    case False{}:
      seg.run(c, shards, k, cum, segs, Nil{}, Nil{})

def seg.there(there: Bool, +c: Pc, +shards: Nat, +k: Nat, +cum: Nat, segs: List<&2, List<&2, U32>>) -> IO(Pl):
  match there:
    case False{}:
      IO.die(Pl, 1, "plan-corpus: shard " ++ Nat.show(k) ++ " has no corpus (" ++ corpus.of(c, k) ++ ")")
    case True{}:
      seg.pack(Pc.packed(c), c, shards, k, cum, segs)

def seg.step(+c: Pc, +shards: Nat, p: Pl) -> IO(Pl):
  match p:
    case Pl{+k, +cum, segs}:
      do IO<Pl>:
        +there : Bool <- S.exists(corpus.of(c, k))
        seg.there(there, c, shards, k, cum, segs)

def seg.go(n: Nat, +c: Pc, +shards: Nat, p: Pl) -> IO(Pl):
  match n:
    case 0n:
      IO.pure(Pl, p)
    case 1n+m:
      IO.bind(Pl, Pl, seg.step(c, shards, p), seg.go(m, c, shards))

# The run ---------------------------------------------------------------------

def plan.write(+plan: String, +head: String, +shards: Nat, p: Pl) -> IO(Unit):
  match p:
    case Pl{k, +cum, segs}:
      do IO<Unit>:
        S.write(plan ++ ".tmp", S.append(S.b("plan 1 " ++ Nat.show(cum) ++ " " ++ head ++ "\n"), List.concat(&2, U32, List.reverse(&2, List<&2, U32>, segs))))
        S.mv(plan ++ ".tmp", plan)
        say("plan-corpus: wrote " ++ plan ++ " (" ++ Nat.show(cum) ++ " global steps over " ++ Nat.show(shards) ++ " shards)")

def failed(bad: Nat) -> IO(Unit):
  match bad:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+j:
      IO.die(Unit, 1, "plan-corpus: " ++ Nat.show(bad) ++ " shard(s) failed to prepare")

# MemAvailable in /proc/meminfo, in GB (`int($2 / 1048576)`)
def avail.gb(ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> more:
      Bool.pick(Nat, S.prefix(l, S.b("MemAvailable:")), Nat.div(nat.of(nth(wds(l), 1n)), 1048576n), avail.gb(more))

def jobs.of(+j: Nat, +cores: Nat) -> Nat:
  Nat.min(Nat.max(j, 1n), cores)

def split.if(empty: Bool, +c: Pc, +data: String) -> IO(Unit):
  match empty:
    case True{}:
      do IO<Unit>:
        say("plan-corpus: splitting " ++ data ++ " into " ++ Pc.per(c) ++ "-document parts")
        n : Nat <- split.parts(data, Pc.run(c) ++ "/parts/part-", Pc.pern(c))
        return Unit{}
    case False{}:
      IO.pure(Unit, Unit{})

def packid(+c: Pc) -> String:
  Bool.pick(String, Pc.packed(c), ":pack=" ++ Pc.pack(c) ++ Bool.pick(String, Pc.group(c), "-grouped", ""), "")

def body(+c: Pc, +data: String, +plan: String) -> IO(Unit):
  do IO<Unit>:
    # One pass to split, when there are no parts yet.
    ls : S.Out <- S.run(".", [], 600, "ls", ["-A", Pc.run(c) ++ "/parts"], Nil{})
    split.if(Nat.is_eq(S.len(S.Out.text(ls)), 0n), c, data)
    say("plan-corpus: hashing the dataset and tokenizer")
    dh : List<&2, U32> <- S.must("sha256sum " ++ data, "sha256sum", [data])
    th : List<&2, U32> <- S.must("sha256sum " ++ Pc.tok(c), "sha256sum", [Pc.tok(c)])
    wc : List<&2, U32> <- S.must("wc -l " ++ data, "wc", ["-l", data])
    +dhash : String = first.word(dh)
    +thash : String = first.word(th)
    +total : String = first.word(wc)
    # Drive the loop from the document count, not from the surviving parts.
    # Parts are pruned as they are consumed, so on a resumed run the ones
    # already done no longer exist -- iterating over what is left would
    # silently omit those shards from the plan.
    +shards : Nat = Nat.div(Nat.sub(Nat.add(nat.of(S.b(total)), Pc.pern(c)), 1n), Pc.pern(c))
    say("plan-corpus: " ++ Nat.show(shards) ++ " shards")
    # Packing changes the corpus bytes, so it is identity-bearing exactly
    # like the batch and the tokenizer; unpacked plans keep the historical id.
    +gid : String = "mixed-global-v1:sha256=" ++ dhash ++ ":documents=" ++ total ++ ":shard=" ++ Pc.per(c) ++ ":batch=" ++ Pc.batch(c)
      ++ ":size=" ++ Pc.size(c) ++ ":tokenizer=" ++ thash ++ packid(c)
    np : List<&2, U32> <- S.must("nproc", "nproc", [])
    mi : List<&2, U32> <- S.read("/proc/meminfo")
    +j : Nat <- S.env.nat("JOBS", Nat.div(avail.gb(S.split.lines(mi)), 3n))
    +jobs : Nat = jobs.of(j, nat.of(S.chomp(np)))
    say("plan-corpus: preparing shards, " ++ Nat.show(jobs) ++ " at a time")
    +bad : Nat <- pool(c, shards, jobs)
    failed(bad)
    p : Pl <- seg.go(shards, c, shards, Pl{0n, 0n, Nil{}})
    plan.write(plan, gid ++ " " ++ dhash ++ " " ++ total ++ " " ++ Pc.per(c) ++ " " ++ Pc.batch(c) ++ " " ++ Pc.size(c) ++ " " ++ thash, shards, p)

def exists.plan(there: Bool, +c: Pc, +data: String, +plan: String) -> IO(Unit):
  match there:
    case True{}:
      say("plan-corpus: plan already exists: " ++ plan)
    case False{}:
      body(c, data, plan)

def start(+c: Pc, +data: String) -> IO(Unit):
  +plan = Pc.run(c) ++ "/plan-" ++ Pc.size(c) ++ "-b" ++ Pc.batch(c) ++ "-s" ++ Pc.per(c) ++ ".tsv"
  do IO<Unit>:
    +d : Bool <- S.exists(data)
    fail.if(Bool.not(d), "plan-corpus: no such file: " ++ data)
    +t : Bool <- S.exists(Pc.tok(c))
    fail.if(Bool.not(t), "plan-corpus: no such tokenizer: " ++ Pc.tok(c))
    S.mkdir(Pc.run(c) ++ "/parts")
    +there : Bool <- S.exists(plan)
    exists.plan(there, c, data, plan)

# the tool: BEND_X, else BEND_TOOLS/bend-x, else bend-x on PATH
def tool.or(+dir: String, +name: String) -> String:
  Bool.pick(String, String.is_empty(dir), name, dir ++ "/" ++ name)

def config(+data: String, +run: String, +size: String, +batch: String, +per: String, pern: Maybe<&2, Nat>) -> IO(Unit):
  match pern:
    case Some{1n+(+m)}:
      do IO<Unit>:
        +tok : String <- S.env("TOKENIZER", "")
        fail.if(String.is_empty(tok), "bend-plan-corpus: set TOKENIZER to the .bpe artifact")
        +pack : String <- S.env("PACK_TARGET", "")
        +group : String <- S.env("PACK_GROUP", "")
        +prune : String <- S.env("PRUNE_PARTS", "1")
        +tools : String <- S.env("BEND_TOOLS", "")
        +bp : String <- S.env("BEND_PACK", tool.or(tools, "bend-pack"))
        +br : String <- S.env("BEND_PREPARE", tool.or(tools, "bend-prepare"))
        +bs : String <- S.env("BEND_PLAN_SEGMENT", tool.or(tools, "bend-plan-segment"))
        start(Pc{data, run, size, batch, per, 1n+m, tok, pack, Bool.not(String.is_empty(group)), Bool.or(String.is_empty(prune), String.eq(prune, "1")), bp, br, bs}, data)
    case _:
      IO.die(Unit, 1, "plan-corpus: ARTICLES_PER_SHARD must be a positive integer: " ++ per)

def usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-plan-corpus DATA.jsonl RUN_DIR SIZE BATCH [ARTICLES_PER_SHARD]")

def args.go(xs: List<String>) -> IO(Unit):
  match xs:
    case +d <> +r <> +z <> +b <> Nil{}:
      config(d, r, z, b, "4000", Some{4000n})
    case +d <> +r <> +z <> +b <> +p <> Nil{}:
      config(d, r, z, b, p, Nat.read(p))
    case _:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args.go(xs)
