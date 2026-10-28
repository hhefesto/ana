import Base
import ../Sys.bend as S
import ../Tokenizer.bend as Tk
import ../Check/Lib.bend as Cl
import ./Lib.bend as L
import ./Keyed.bend as K
import ./Port.bend as Pt
import ./Ratio.bend as R

# Run 5's raw Bend intake (2026-10-22): the steps between the sources Codex,
# the collection and the port wrote and the raw pool a run's steady-mix
# takes, with the leak checks in them (HANDOFF: run 5's raw intake drops
# run/v5/collect/bend/held-decl.files; the port's, Codex's and the fixed
# files' declarations are checked against the vaults and holdouts first).
#
#   bend-corpus-v2 files-jsonl PREFIX DIR OUT [skip=GLOB]... [drop=NAME]...
#       every *.bend file under DIR (`find`, bytewise order) as a JSON line
#       `{"id": "PREFIX/REL", "text": ...}` (Lib's v2.py.line, as Python's
#       json.dumps wrote them); a file holding a NUL byte is left out and
#       counted; OUT.stats.  (2026-10-27) skip=GLOB leaves out the files
#       find's `-path GLOB` matches (the whole path, DIR in it: `*/Test.bend`,
#       `*/fixtures/*`); drop=NAME takes every top-level def named NAME out
#       of each file (NAME ending in `*`: every name with that prefix), with
#       the comment lines just above it, the rest of the file as it was, a
#       newline after every line (for a test harness: `drop=main
#       drop=observations*`); the stats then add `defs-dropped` and
#       `bytes-dropped`.  With neither option the output is as before.
#
#   bend-corpus-v2 raw-drop OUT IN.jsonl... drop=FILE...
#       the records of each IN (JSON lines), in order, less those whose id a
#       drop FILE names: a line is an id (a file's, as held-decl.files lists
#       them), or decl-new's `REASON TAB UNIT` (the reasons v2-held,
#       held-file, held-text and held-decl only), which names the unit's
#       file, its id before `#`; OUT.stats (per input: read, kept, dropped)
#
#   bend-corpus-v2 port-fix INBOX FIXED OUT
#       the port's failing files once fixed: FIXED/REPO/FIXED.tsv, a row a
#       file (`PATH TAB fixed|unfixable TAB note`; any other status is
#       counted and passed over).  A fixed file goes into OUT/bend.jsonl as
#       `port-fix:REPO/PATH` (the fixed text), and becomes a whole-file
#       repair transcript in OUT/transcripts.train.nul, id
#       `port-fix:REPO/PATH/repair`, as port renders its own (Port.bend's
#       pt.fs and pt.render: User "Write the Bend file `PATH`." and "This
#       attempt fails. Fix it.", INBOX/REPO/PATH as the Attempt with the
#       locked loader's answer, the fixed file as the Term with its pass),
#       when the fixed file passes, the inbox's fails (not a timeout), the two
#       differ and the transcript fits the window (2048 less 64 code32k
#       tokens).  The loader is $BEND (else `bend`), run in each file's own
#       directory, `LC_ALL=C timeout SECS BEND FILE --check-only`, SECS
#       $PORT_FIX_SECS (120).  OUT/stats.  repair-mix then holds each repair
#       to the ratio (a whole-file unit: derive=whole gives its first-time
#       transcript, the fixed file written correct from the start).
#
# Logs go to stderr, stamped UTC-6.  The laws are bend/tests/ratio.bend.
# Every def is prefixed `itk.`.

def itk.log(+msg: String) -> IO(Unit):
  K.kor.log("intake", msg)

def itk.big() -> Nat:
  U32.to_nat(4294967295)

def itk.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  R.rto.nonempty(S.split(xs, 10))

# files-jsonl ----------------------------------------------------------------------------------

def itk.has.nul(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      Bool.or(U32.is_eq(c, 0), itk.has.nul(t))

# drop=: a file's lines, each a kind: a top-level comment (`#` in column
# 0), a top-level line that starts a def to keep or one to drop, or any
# other line (blank or indented: the current block's)
type ItDk is Data:
  DkBody{}
  DkNote{}
  DkKeep{}
  DkDrop{}

# the lines kept (latest first), the comment lines not yet placed (latest
# first), the defs and bytes dropped
type ItDd is Type:
  ItDd{out: List<&2, List<&2, U32>>, buf: List<&2, List<&2, U32>>, n: Nat, b: Nat}

# a def header's name: up to `(`, `:`, ` ` or `<` (stop: the next byte is one)
def itk.dd.stop(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> _:
      Bool.or(Bool.or(U32.is_eq(c, 40), U32.is_eq(c, 58)), Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 60)))

def itk.dd.name(xs: List<&2, U32>, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case Nil{} _:
      Nil{}
    case _ True{}:
      Nil{}
    case c <> +t False{}:
      c <> itk.dd.name(t, itk.dd.stop(t))

# does a drop= word (NAME, or PREFIX*) name it
def itk.dd.one(+w: List<&2, U32>, +name: List<&2, U32>) -> Bool:
  +star = List.reverse(&2, U32, w)
  Bool.pick(Bool, S.head.is(star, 42), S.prefix(name, List.reverse(&2, U32, List.drop(&2, U32, star, 1n))), S.eq(name, w))

def itk.dd.any(ws: List<&2, List<&2, U32>>, +name: List<&2, U32>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case w <> more:
      Bool.or(itk.dd.one(w, name), itk.dd.any(more, name))

def itk.dd.pick(note: Bool, body: Bool, hit: Bool) -> ItDk:
  match note body hit:
    case True{} _ _:
      DkNote{}
    case False{} True{} _:
      DkBody{}
    case False{} False{} True{}:
      DkDrop{}
    case False{} False{} False{}:
      DkKeep{}

def itk.dd.kind.of(+ws: List<&2, List<&2, U32>>, +l: List<&2, U32>) -> ItDk:
  +body = Bool.or(Nat.is_eq(S.len(l), 0n), Bool.or(S.head.is(l, 32), S.head.is(l, 9)))
  +rest = List.drop(&2, U32, l, 4n)
  +hit = Bool.and(S.prefix(l, S.b("def ")), itk.dd.any(ws, itk.dd.name(rest, itk.dd.stop(rest))))
  itk.dd.pick(S.head.is(l, 35), body, hit)

def itk.dd.kind(+ws: List<&2, List<&2, U32>>, ls: List<&2, List<&2, U32>>) -> ItDk:
  match ls:
    case Nil{}:
      DkBody{}
    case l <> _:
      itk.dd.kind.of(ws, l)

def itk.dd.bytes(xs: List<&2, List<&2, U32>>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case x <> more:
      Nat.add(1n+S.len(x), itk.dd.bytes(more))

# the pending comments and a line, kept or dropped with the current block
def itk.dd.put(drop: Bool, +l: List<&2, U32>, s: ItDd) -> ItDd:
  match drop s:
    case True{} ItDd{o, +f, n, +b}:
      ItDd{o, Nil{}, n, Nat.add(b, Nat.add(1n+S.len(l), itk.dd.bytes(f)))}
    case False{} ItDd{o, f, n, b}:
      ItDd{l <> List.append(&2, List<&2, U32>, f, o), Nil{}, n, b}

def itk.dd.go(ls: List<&2, List<&2, U32>>, k: ItDk, +ws: List<&2, List<&2, U32>>, +drop: Bool, s: ItDd) -> ItDd:
  match ls k s:
    case Nil{} _ ItDd{o, f, n, b}:
      ItDd{List.append(&2, List<&2, U32>, f, o), Nil{}, n, b}
    case +l <> +more DkNote{} ItDd{o, f, n, b}:
      itk.dd.go(more, itk.dd.kind(ws, more), ws, drop, ItDd{o, l <> f, n, b})
    case +l <> +more DkKeep{} st:
      itk.dd.go(more, itk.dd.kind(ws, more), ws, False{}, itk.dd.put(False{}, l, st))
    case +l <> +more DkDrop{} ItDd{o, f, n, b}:
      itk.dd.go(more, itk.dd.kind(ws, more), ws, True{}, itk.dd.put(True{}, l, ItDd{o, f, 1n+n, b}))
    case +l <> +more DkBody{} st:
      itk.dd.go(more, itk.dd.kind(ws, more), ws, drop, itk.dd.put(drop, l, st))

def itk.dd.lines(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      List.append(&2, U32, x, 10 <> itk.dd.lines(more))

def itk.dd.out(s: ItDd) -> List<&2, U32> & Nat & Nat:
  match s:
    case ItDd{o, _, n, b}:
      (itk.dd.lines(List.reverse(&2, List<&2, U32>, o)), n, b)

# a file less its dropped defs, and how many defs and bytes went
def itk.dd.file(+ws: List<&2, List<&2, U32>>, +t: List<&2, U32>) -> List<&2, U32> & Nat & Nat:
  +ls = S.split(t, 10)
  itk.dd.out(itk.dd.go(ls, itk.dd.kind(ws, ls), ws, False{}, ItDd{Nil{}, Nil{}, 0n, 0n}))

type ItFj is Type:
  ItFj{o: File, n: Nat, nul: Nat, b: Nat, dn: Nat, db: Nat}

def itk.fj.emit(+id: List<&2, U32>, x: List<&2, U32> & Nat & Nat, s: ItFj) -> IO(ItFj):
  (t, dn2, db2) = x
  match s:
    case ItFj{o, +n, +z, +b, +dn, +db}:
      do IO<ItFj>:
        +u : List<&2, U32> <- IO.pure(List<&2, U32>, t)
        o2 : File <- S.emit(o, L.v2.py.line(id, u))
        return ItFj{o2, 1n+n, z, Nat.add(b, S.len(u)), Nat.add(dn, dn2), Nat.add(db, db2)}

def itk.fj.put(+ws: List<&2, List<&2, U32>>, +nul: Bool, +id: List<&2, U32>, +t: List<&2, U32>, s: ItFj, dd: Bool) -> IO(ItFj):
  match nul s dd:
    case True{} ItFj{o, +n, +z, +b, +dn, +db} _:
      IO.pure(ItFj, ItFj{o, n, 1n+z, b, dn, db})
    case False{} st False{}:
      itk.fj.emit(id, (t, 0n, 0n), st)
    case False{} st True{}:
      itk.fj.emit(id, itk.dd.file(ws, t), st)

def itk.fj.go(+ws: List<&2, List<&2, U32>>, +pre: String, +dir: String, rs: List<&2, List<&2, U32>>, s: ItFj) -> IO(ItFj):
  match rs:
    case Nil{}:
      IO.pure(ItFj, s)
    case +rel <> more:
      do IO<ItFj>:
        +t : List<&2, U32> <- S.read(dir ++ "/" ++ S.str(rel))
        s2 : ItFj <- itk.fj.put(ws, itk.has.nul(t), L.v2.concat([S.b(pre), [47], rel]), t, s, Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, ws), 0n)))
        itk.fj.go(ws, pre, dir, more, s2)

def itk.fj.fin(+dropping: Bool, +out: String, s: ItFj) -> IO(Unit):
  match s:
    case ItFj{o, +n, +z, +b, +dn, +db}:
      +more = Bool.pick(String, dropping, "defs-dropped " ++ Nat.show(dn) ++ "\nbytes-dropped " ++ Nat.show(db) ++ "\n", "")
      +st = "bytes " ++ Nat.show(b) ++ "\nfiles " ++ Nat.show(n) ++ "\nnul " ++ Nat.show(z) ++ "\n" ++ more
      do IO<Unit>:
        File.close(o)
        S.write(out ++ ".stats", S.b(st))
        itk.log(out ++ ": " ++ Nat.show(n) ++ " files, " ++ Nat.show(b) ++ " bytes; " ++ Nat.show(z) ++ " with a NUL left out" ++ Bool.pick(String, dropping, "; " ++ Nat.show(dn) ++ " defs (" ++ Nat.show(db) ++ " bytes) dropped", ""))

# the files under DIR, as paths relative to it, in bytewise order
def itk.find(+dir: String, +name: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 600, "find", [dir, "-type", "f", "-name", name, "-printf", "%P\\n"], Nil{})
    Bool.pick(IO(List<&2, List<&2, U32>>), U32.is_eq(S.Out.status(o), 0), IO.pure(List<&2, List<&2, U32>>, S.bytes.sort(itk.lines(S.Out.text(o)))),
      IO.die(List<&2, List<&2, U32>>, 1, "intake: find " ++ dir ++ " failed: " ++ S.str(S.lines.take(S.Out.text(o), 3n))))

# find's `-not -path GLOB` for each skip= word
def itk.find.not(gs: List<&2, String>) -> List<String>:
  match gs:
    case Nil{}:
      ["-printf", "%P\\n"]
    case g <> more:
      "-not" <> "-path" <> g <> itk.find.not(more)

def itk.find.skip(+dir: String, +name: String, +gs: List<&2, String>) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 600, "find", dir <> "-type" <> "f" <> "-name" <> name <> itk.find.not(gs), Nil{})
    Bool.pick(IO(List<&2, List<&2, U32>>), U32.is_eq(S.Out.status(o), 0), IO.pure(List<&2, List<&2, U32>>, S.bytes.sort(itk.lines(S.Out.text(o)))),
      IO.die(List<&2, List<&2, U32>>, 1, "intake: find " ++ dir ++ " failed: " ++ S.str(S.lines.take(S.Out.text(o), 3n))))

def itk.files.jsonl.with(+pre: String, +dir: String, +out: String, +gs: List<&2, String>, +ws: List<&2, List<&2, U32>>) -> IO(Unit):
  do IO<Unit>:
    rs : List<&2, List<&2, U32>> <- itk.find.skip(dir, "*.bend", gs)
    o : File <- IO.try(File, File.open(out, "w"))
    s : ItFj <- itk.fj.go(ws, pre, dir, rs, ItFj{o, 0n, 0n, 0n, 0n, 0n})
    itk.fj.fin(Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, ws), 0n)), out, s)

def itk.files.jsonl(+pre: String, +dir: String, +out: String) -> IO(Unit):
  itk.files.jsonl.with(pre, dir, out, Nil{}, Nil{})

# raw-drop -------------------------------------------------------------------------------------

# a drop file's line: the file id it drops, if any
def itk.drop.line(+l: List<&2, U32>) -> Maybe<&2, String>:
  R.rto.held.file(R.rto.held.line(l))

type ItDl is Type:
  ItDl{r: S.Rd, h: Set(), n: Nat, more: Bool}

def itk.dl.got(h: Set(), +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(ItDl):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(ItDl, ItDl{r, h, n, False{}})
    case Some{+l}:
      IO.pure(ItDl, ItDl{r, R.rto.set.add(itk.drop.line(l), h), 1n+n, True{}})

def itk.dl.go(fuel: Nat, s: ItDl) -> IO(ItDl):
  match fuel s:
    case 1n+f ItDl{r, h, n, True{}}:
      IO.bind(ItDl, ItDl, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, ItDl, S.Rd.next(r), itk.dl.got(h, n)), itk.dl.go(f))
    case _ s2:
      IO.pure(ItDl, s2)

def itk.dl.fin(+p: String, s: ItDl) -> IO(Set()):
  match s:
    case ItDl{r, h, +n, g}:
      do IO<Set()>:
        S.Rd.close(r)
        itk.log("drop " ++ p ++ ": " ++ Nat.show(n) ++ " lines")
        return h

def itk.drops(ps: List<&2, String>, h: Set()) -> IO(Set()):
  match ps:
    case Nil{}:
      IO.pure(Set(), h)
    case +p <> more:
      do IO<Set()>:
        r : S.Rd <- S.Rd.lines(p)
        s : ItDl <- itk.dl.go(itk.big(), ItDl{r, h, 0n, True{}})
        h2 : Set() <- itk.dl.fin(p, s)
        itk.drops(more, h2)

type ItRd is Type:
  ItRd{r: S.Rd, o: File, h: Set(), n: Nat, k: Nat, b: Nat, more: Bool}

def itk.rd.keep(+l: List<&2, U32>, r: S.Rd, o: File, +n: Nat, +k: Nat, +b: Nat, y: Set() & Bool) -> IO(ItRd):
  (h, drop) = y
  match drop:
    case True{}:
      IO.pure(ItRd, ItRd{r, o, h, 1n+n, k, b, True{}})
    case False{}:
      do IO<ItRd>:
        o2 : File <- S.emit(o, S.append(l, [10]))
        return ItRd{r, o2, h, 1n+n, 1n+k, Nat.add(b, 1n+S.len(l)), True{}}

def itk.rd.got(o: File, h: Set(), +n: Nat, +k: Nat, +b: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(ItRd):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(ItRd, ItRd{r, o, h, n, k, b, False{}})
    case Some{+l}:
      itk.rd.keep(l, r, o, n, k, b, Set.has(h, S.str(K.kor.line.id(l))))

def itk.rd.go(fuel: Nat, s: ItRd) -> IO(ItRd):
  match fuel s:
    case 1n+f ItRd{r, o, h, n, k, b, True{}}:
      IO.bind(ItRd, ItRd, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, ItRd, S.Rd.next(r), itk.rd.got(o, h, n, k, b)), itk.rd.go(f))
    case _ s2:
      IO.pure(ItRd, s2)

type ItRo is Type:
  ItRo{o: File, h: Set(), st: List<&2, Cl.Stat>}

def itk.rd.fin(+p: String, s: ItRd, st: List<&2, Cl.Stat>) -> IO(ItRo):
  match s:
    case ItRd{r, o, h, +n, +k, +b, g}:
      do IO<ItRo>:
        S.Rd.close(r)
        itk.log(p ++ ": " ++ Nat.show(n) ++ " read, " ++ Nat.show(k) ++ " kept (" ++ Nat.show(b) ++ " bytes), " ++ Nat.show(Nat.sub(n, k)) ++ " dropped")
        return ItRo{o, h, Cl.stat.bump(p ++ " read", n, Cl.stat.bump(p ++ " kept", k, Cl.stat.bump(p ++ " kept-bytes", b, Cl.stat.bump(p ++ " dropped", Nat.sub(n, k), st))))}

def itk.rd.one(+p: String, w: ItRo) -> IO(ItRo):
  match w:
    case ItRo{o, h, st}:
      do IO<ItRo>:
        r : S.Rd <- S.Rd.lines(p)
        s : ItRd <- itk.rd.go(itk.big(), ItRd{r, o, h, 0n, 0n, 0n, True{}})
        itk.rd.fin(p, s, st)

def itk.rd.all(ps: List<&2, String>, w: ItRo) -> IO(ItRo):
  match ps:
    case Nil{}:
      IO.pure(ItRo, w)
    case +p <> more:
      IO.bind(ItRo, ItRo, itk.rd.one(p, w), itk.rd.all(more))

def itk.rd.end(+out: String, w: ItRo) -> IO(Unit):
  match w:
    case ItRo{o, h, +st}:
      do IO<Unit>:
        File.close(o)
        S.mv(out ++ ".tmp", out)
        S.write(out ++ ".stats", S.b(Cl.stat.show(st)))

def itk.raw.drop(+out: String, ins: List<&2, String>, drops: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    h : Set() <- itk.drops(drops, Set.new())
    o : File <- IO.try(File, File.open(out ++ ".tmp", "w"))
    w : ItRo <- itk.rd.all(ins, ItRo{o, h, Nil{}})
    itk.rd.end(out, w)

type ItRa is Data:
  ItRa{ins: List<&2, String>, drops: List<&2, String>}

def itk.rd.arg(+w: String, a: ItRa) -> ItRa:
  match a:
    case ItRa{+i, +d}:
      +x = S.b(w)
      Bool.pick(ItRa, S.prefix(x, S.b("drop=")), ItRa{i, S.str(List.drop(&2, U32, x, 5n)) <> d}, ItRa{w <> i, d})

def itk.rd.args(ws: List<String>) -> ItRa:
  match ws:
    case Nil{}:
      ItRa{Nil{}, Nil{}}
    case +w <> more:
      itk.rd.arg(w, itk.rd.args(more))

# port-fix ---------------------------------------------------------------------------------------

def itk.ck(+o: S.Out) -> List<&2, U32>:
  L.v2.concat([S.b(U32.show(S.Out.status(o))), [31], S.Out.text(o)])

# the locked loader on a file, in its own directory: STATUS 0x1F OUTPUT, as port keeps a check
def itk.check(+loader: String, +secs: U32, +path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    +o : S.Out <- S.run(S.parent(path), ["LC_ALL=C"], secs, loader, [S.base(path), "--check-only"], Nil{})
    return itk.ck(o)

type ItPx is Data:
  ItPx{loader: String, secs: U32, inbox: String, fixed: String}

type ItPf is Type:
  ItPf{oj: File, ot: File, st: List<&2, Cl.Stat>}

def itk.pf.why(+w: Nat) -> String:
  Bool.pick(String, Nat.is_eq(w, 0n), "repair transcripts", Bool.pick(String, Nat.is_eq(w, 1n), "no repair (unchanged, not a pass, or the inbox's passes)",
    Bool.pick(String, Nat.is_eq(w, 2n), "the inbox's error points elsewhere", "over the window")))

def itk.pf.tr(w: Nat, +id: List<&2, U32>, +text: List<&2, U32>, ot: File) -> IO(File):
  match w:
    case 0n:
      S.emit(ot, L.v2.concat([id, S.b("/repair"), [0], text, [0]]))
    case _:
      IO.pure(File, ot)

# a fixed file: its JSON line, its checks, its transcript
def itk.pf.fixed(+x: ItPx, +win: Pt.PtW, +repo: List<&2, U32>, +path: List<&2, U32>, s: ItPf) -> IO(ItPf):
  match x s:
    case ItPx{+ld, +secs, +ib, +fx} ItPf{oj, ot, st}:
      +rel = S.str(L.v2.concat([repo, [47], path]))
      +id = S.b("port-fix:" ++ rel)
      do IO<ItPf>:
        +port : List<&2, U32> <- S.read(fx ++ "/" ++ rel)
        +orig : List<&2, U32> <- S.read(ib ++ "/" ++ rel)
        oj2 : File <- S.emit(oj, L.v2.py.line(id, port))
        +pck : List<&2, U32> <- itk.check(ld, secs, fx ++ "/" ++ rel)
        +ock : List<&2, U32> <- itk.check(ld, secs, ib ++ "/" ++ rel)
        +why0 : Nat = Pt.pt.tr.why(Bool.not(S.eq(port, orig)), pck, ock, orig)
        +text : List<&2, U32> = Pt.pt.tr.text(Nat.is_eq(why0, 0n), win, Pt.pt.fs(path, port, pck, orig, ock))
        +why : Nat = Bool.pick(Nat, Bool.and(Nat.is_eq(why0, 0n), Nat.is_eq(S.len(text), 0n)), 3n, why0)
        ot2 : File <- itk.pf.tr(why, id, text, ot)
        return ItPf{oj2, ot2, Cl.stat.bump(itk.pf.why(why), 1n, Cl.stat.bump("fixed", 1n, st))}

def itk.pf.code(+status: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.eq(status, S.b("fixed")), 0n, Bool.pick(Nat, S.eq(status, S.b("unfixable")), 1n, 2n))

def itk.pf.row.k(k: Nat, +x: ItPx, +win: Pt.PtW, +repo: List<&2, U32>, +path: List<&2, U32>, s: ItPf) -> IO(ItPf):
  match k s:
    case 0n s2:
      itk.pf.fixed(x, win, repo, path, s2)
    case 1n ItPf{oj, ot, st}:
      IO.pure(ItPf, ItPf{oj, ot, Cl.stat.bump("unfixable", 1n, st)})
    case _ ItPf{oj, ot, st}:
      IO.pure(ItPf, ItPf{oj, ot, Cl.stat.bump("status other", 1n, st)})

def itk.pf.row(+x: ItPx, +win: Pt.PtW, +repo: List<&2, U32>, +l: List<&2, U32>, s: ItPf) -> IO(ItPf):
  +fs = S.split(l, 9)
  itk.pf.row.k(itk.pf.code(L.v2.nth(fs, 1n)), x, win, repo, L.v2.nth(fs, 0n), s)

def itk.pf.rows(+x: ItPx, +win: Pt.PtW, +repo: List<&2, U32>, ls: List<&2, List<&2, U32>>, s: ItPf) -> IO(ItPf):
  match ls:
    case Nil{}:
      IO.pure(ItPf, s)
    case +l <> more:
      IO.bind(ItPf, ItPf, itk.pf.row(x, win, repo, l, s), itk.pf.rows(x, win, repo, more))

def itk.pf.repo(+x: ItPx, +win: Pt.PtW, +tsv: List<&2, U32>, s: ItPf) -> IO(ItPf):
  match x:
    case ItPx{+ld, +secs, +ib, +fx}:
      +repo = L.v2.parent(tsv, 47)
      do IO<ItPf>:
        +t : List<&2, U32> <- S.read(fx ++ "/" ++ S.str(tsv))
        itk.pf.rows(x, win, repo, itk.lines(t), s)

def itk.pf.repos(+x: ItPx, +win: Pt.PtW, ts: List<&2, List<&2, U32>>, s: ItPf) -> IO(ItPf):
  match ts:
    case Nil{}:
      IO.pure(ItPf, s)
    case +t <> more:
      IO.bind(ItPf, ItPf, itk.pf.repo(x, win, t, s), itk.pf.repos(x, win, more))

def itk.pf.end(+out: String, +n: Nat, s: ItPf) -> IO(Unit):
  match s:
    case ItPf{oj, ot, +st}:
      +st2 = Cl.stat.bump("repositories with a FIXED.tsv", n, st)
      do IO<Unit>:
        File.close(oj)
        File.close(ot)
        S.write(out ++ "/stats", S.b(Cl.stat.show(st2)))

def itk.port.fix(+inbox: String, +fixed: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +ld : String <- S.env("BEND", "bend")
    +secs : Nat <- S.env.nat("PORT_FIX_SECS", 120n)
    +ts : List<&2, List<&2, U32>> <- itk.find(fixed, "FIXED.tsv")
    +tx : List<&2, U32> <- S.read("weights/code32k.bpe")
    +win : Pt.PtW <- Pt.pt.win("weights/code32k.bpe", 1984n, Tk.Bpe.parse(tx))
    S.mkdir(out)
    oj : File <- IO.try(File, File.open(out ++ "/bend.jsonl", "w"))
    ot : File <- IO.try(File, File.open(out ++ "/transcripts.train.nul", "w"))
    itk.log("port-fix: " ++ Nat.show(List.length(&2, List<&2, U32>, ts)) ++ " FIXED.tsv under " ++ fixed ++ "; loader " ++ ld)
    s : ItPf <- itk.pf.repos(ItPx{ld, U32.from_nat(secs), inbox, fixed}, win, ts, ItPf{oj, ot, Nil{}})
    itk.pf.end(out, List.length(&2, List<&2, U32>, ts), s)

# Main -------------------------------------------------------------------------------------------

# a stats file onto stdout (the tests call the steps and read the files)
def itk.say(+p: String) -> IO(Unit):
  do IO<Unit>:
    +t : List<&2, U32> <- S.read(p)
    IO.print(S.str(t))

type ItFo is Data:
  ItFo{skips: List<&2, String>, drops: List<&2, List<&2, U32>>, bad: List<&2, String>}

def itk.fo.arg(+w: String, a: ItFo) -> ItFo:
  match a:
    case ItFo{+g, +d, +x}:
      +b = S.b(w)
      Bool.pick(ItFo, S.prefix(b, S.b("skip=")), ItFo{S.str(List.drop(&2, U32, b, 5n)) <> g, d, x},
        Bool.pick(ItFo, S.prefix(b, S.b("drop=")), ItFo{g, List.drop(&2, U32, b, 5n) <> d, x}, ItFo{g, d, w <> x}))

def itk.fo.args(ws: List<String>) -> ItFo:
  match ws:
    case Nil{}:
      ItFo{Nil{}, Nil{}, Nil{}}
    case +w <> more:
      itk.fo.arg(w, itk.fo.args(more))

def itk.main.files.of(+pre: String, +dir: String, +out: String, a: ItFo) -> IO(Unit):
  match a:
    case ItFo{g, d, Nil{}}:
      itk.files.jsonl.with(pre, dir, out, g, d)
    case ItFo{_, _, w <> _}:
      IO.die(Unit, 2, "files-jsonl: not an option: " ++ w ++ " (skip=GLOB or drop=NAME)")

def itk.main.files(xs: List<String>) -> IO(Unit):
  match xs:
    case +pre <> +dir <> +out <> more:
      itk.main.files.of(pre, dir, out, itk.fo.args(more))
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 files-jsonl PREFIX DIR OUT [skip=GLOB]... [drop=NAME]...")

def itk.main.drop.of(+out: String, a: ItRa) -> IO(Unit):
  match a:
    case ItRa{i, d}:
      do IO<Unit>:
        itk.raw.drop(out, i, d)
        itk.say(out ++ ".stats")

def itk.main.drop(xs: List<String>) -> IO(Unit):
  match xs:
    case +out <> more:
      itk.main.drop.of(out, itk.rd.args(more))
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 raw-drop OUT IN.jsonl... drop=FILE...")

def itk.main.fix(xs: List<String>) -> IO(Unit):
  match xs:
    case +ib <> +fx <> +out <> Nil{}:
      do IO<Unit>:
        itk.port.fix(ib, fx, out)
        itk.say(out ++ "/stats")
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 port-fix INBOX FIXED OUT")
