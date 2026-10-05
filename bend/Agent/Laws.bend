import Base
import ../Bytes.bend as B
import ../Tokenizer.bend as Tk
import ../Sys.bend as S
import ./Spec.bend as A
import ../Mask.bend as Ms

# bend-agent-laws TOKENIZER TRANSCRIPTS.nul: Agent/Spec.bend's laws on every
# transcript of a NUL file (`id\0text\0` pairs, ids ending in /SHAPE), and
# the token reading the trainer uses (Mask.bend) against the byte reading:
#
#   roundtrip  reading the text cuts it into turns, never changes it
#   calls      every echo answers a call, every call is answered
#   shape      the roles its shape means: one act (none for verify), the
#              Term (term-to-type: the Type); one attempt for repair, fill
#              and verify, none for direct and term-to-type; the User first
#   tokens     the tokens read back to the same tokens, as a transcript
#   agree      each token's role is the role of every one of its bytes
#
# A failing transcript prints `FAIL ID: LAWS`; the last line counts them.
# SHARD and SHARDS (environment, 0 and 1) check the documents whose index is
# SHARD mod SHARDS, so a file fans out over processes.

def la.after.slash(+xs: List<&2, U32>, +cur: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      List.reverse(&2, U32, cur)
    case h <> t:
      la.after.slash(t, Bool.pick(List<&2, U32>, U32.is_eq(h, 47), Nil{}, h <> cur))

# the id's shape: after its last /
def la.shape(+id: List<&2, U32>) -> List<&2, U32>:
  la.after.slash(id, Nil{})

def la.is(+s: List<&2, U32>, +name: String) -> Bool:
  A.ag.eq(s, A.ag.ascii(name))

def la.act.text(e: List<&2, A.Turn>) -> List<&2, U32>:
  match e:
    case Nil{}:
      Nil{}
    case A.Turn{+r, +x} <> t:
      Bool.pick(List<&2, U32>, Nat.is_eq(A.ag.role.code(r), 3n), x, la.act.text(t))

def la.first.user(+e: List<&2, A.Turn>) -> Bool:
  match e:
    case A.Turn{r, x} <> t:
      Nat.is_eq(A.ag.role.code(r), 0n)
    case Nil{}:
      False{}

def la.shape.ok(+s: List<&2, U32>, +e: List<&2, A.Turn>) -> Bool:
  +verify = la.is(s, "verify")
  +t2t = la.is(s, "term-to-type")
  +att = Bool.or(verify, Bool.or(la.is(s, "repair"), la.is(s, "fill")))
  +acts = Nat.is_eq(A.ag.count(e, 3n), Bool.pick(Nat, verify, 0n, 1n))
  +atts = Nat.is_eq(A.ag.count(e, 2n), Bool.pick(Nat, att, 1n, 0n))
  +label = Bool.or(verify, A.ag.prefix(la.act.text(e), A.ag.ascii(Bool.pick(String, t2t, "## Type\n", "## Term\n"))))
  Bool.and(Bool.and(acts, atts), Bool.and(label, la.first.user(e)))

def la.codes(rs: List<&2, A.Role>) -> List<&2, Nat>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      A.ag.role.code(r) <> la.codes(t)

def la.nats.eq(xs: List<&2, Nat>, ys: List<&2, Nat>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case a <> s c <> t:
      Bool.and(Nat.is_eq(a, c), la.nats.eq(s, t))
    case _ _:
      False{}

# each token's role code, once per byte of the token
def la.expand(ts: List<&2, U32>, rs: List<&2, A.Role>, +b: Tk.Bpe) -> List<&2, Nat>:
  match ts rs:
    case +t <> tt +r <> rt:
      List.append(&2, Nat, List.replicate(Nat, List.length(&2, U32, Tk.Bpe.decode(b, t)), A.ag.role.code(r)), la.expand(tt, rt, b))
    case _ _:
      Nil{}

def la.if(ok: Bool, +name: String, rest: List<&2, String>) -> List<&2, String>:
  match ok:
    case True{}:
      rest
    case False{}:
      name <> rest

# the laws a transcript fails
def la.doc(+b: Tk.Bpe, +ids: Ms.Ids, +id: List<&2, U32>, +text: List<&2, U32>) -> List<&2, String>:
  +e = A.ag.read.bytes(text)
  +ts = Tk.Bpe.encode(b, text)
  +te = Ms.ms.read(ids, ts)
  +tok = Bool.and(Ms.ms.is.transcript(ids, ts), A.ag.law.roundtrip(Ms.ms.nl(ids), Ms.ms.hds(ids), ts))
  +agree = la.nats.eq(la.expand(ts, A.ag.roles(te), b), la.codes(A.ag.roles(e)))
  la.if(A.ag.law.roundtrip(10, A.ag.hds.bytes(), text), "roundtrip",
    la.if(A.ag.law.calls(e), "calls",
      la.if(la.shape.ok(la.shape(id), e), "shape",
        la.if(tok, "tokens",
          la.if(agree, "agree", Nil{})))))

def la.names(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      " " ++ x ++ la.names(t)

def la.report(+id: List<&2, U32>, fs: List<&2, String>) -> IO(Unit):
  match fs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case f <> t:
      IO.print("FAIL " ++ S.str(id) ++ ":" ++ la.names(f <> t))

def la.bad(fs: List<&2, String>) -> Nat:
  match fs:
    case Nil{}:
      0n
    case f <> t:
      1n

# the pass so far: the reader, documents read, checked, failed, whether the
# stream ended
type Lw is Type:
  Lw{rd: S.Rd, i: Nat, n: Nat, bad: Nat, eof: Bool}

def la.check(mine: Bool, +b: Tk.Bpe, +ids: Ms.Ids, rd: S.Rd, +i: Nat, +n: Nat, +bad: Nat, +id: List<&2, U32>, +text: List<&2, U32>) -> IO(Lw):
  match mine:
    case False{}:
      IO.pure(Lw, Lw{rd, 1n+i, n, bad, False{}})
    case True{}:
      +fs = la.doc(b, ids, id, text)
      do IO<Lw>:
        la.report(id, fs)
        return Lw{rd, 1n+i, 1n+n, Nat.add(bad, la.bad(fs)), False{}}

def la.text(+b: Tk.Bpe, +ids: Ms.Ids, +sh: Nat, +shs: Nat, +i: Nat, +n: Nat, +bad: Nat, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Lw):
  (rd, m) = r
  match m:
    case None{}:
      IO.die(Lw, 1, "agent-laws: an id without its text")
    case Some{+t}:
      la.check(Nat.is_eq(Nat.mod(i, shs), sh), b, ids, rd, i, n, bad, id, t)

def la.id(+b: Tk.Bpe, +ids: Ms.Ids, +sh: Nat, +shs: Nat, +i: Nat, +n: Nat, +bad: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Lw):
  (rd, m) = r
  match m:
    case None{}:
      IO.pure(Lw, Lw{rd, i, n, bad, True{}})
    case Some{+id}:
      do IO<Lw>:
        r2 : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        la.text(b, ids, sh, shs, i, n, bad, id, r2)

def la.step(+b: Tk.Bpe, +ids: Ms.Ids, +sh: Nat, +shs: Nat, s: Lw) -> IO(Lw):
  match s:
    case Lw{rd, i, n, bad, e}:
      do IO<Lw>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        la.id(b, ids, sh, shs, i, n, bad, r)

def la.go(fuel: Nat, +b: Tk.Bpe, +ids: Ms.Ids, +sh: Nat, +shs: Nat, s: Lw) -> IO(Lw):
  match fuel s:
    case 1n+p Lw{rd, i, n, bad, False{}}:
      IO.bind(Lw, Lw, la.step(b, ids, sh, shs, Lw{rd, i, n, bad, False{}}), la.go(p, b, ids, sh, shs))
    case _ Lw{rd, i, n, bad, e}:
      IO.pure(Lw, Lw{rd, i, n, bad, e})

def la.done(+path: String, +sh: Nat, +shs: Nat, s: Lw) -> IO(Unit):
  match s:
    case Lw{rd, i, n, bad, e}:
      do IO<Unit>:
        S.Rd.close(rd)
        IO.print("laws " ++ path ++ " shard " ++ Nat.show(sh) ++ "/" ++ Nat.show(shs) ++ ": " ++ Nat.show(n)
          ++ " checked, " ++ Nat.show(bad) ++ " failed (" ++ Nat.show(i) ++ " in the file)")

def la.need(ok: Bool, +why: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, why)

def la.start(+path: String, +b: Tk.Bpe, +sh: Nat, +shs: Nat) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- la.need(Ms.ms.ids.ok(b), "agent-laws: the tokenizer's newline is not one token")
    rd : S.Rd <- S.Rd.open(path)
    s : Lw <- la.go(U32.to_nat(4294967295), b, Ms.ms.ids(b), sh, shs, Lw{rd, 0n, 0n, 0n, False{}})
    la.done(path, sh, shs, s)

def la.run(+path: String, m: Maybe<&2, Tk.Bpe>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "agent-laws: the tokenizer did not parse")
    case Some{+b}:
      do IO<Unit>:
        +sh : Nat <- S.env.nat("SHARD", 0n)
        +shs : Nat <- S.env.nat("SHARDS", 1n)
        la.start(path, b, sh, Nat.max(shs, 1n))

def la.args(xs: List<String>) -> IO(Unit):
  match xs:
    case tok <> path <> Nil{}:
      do IO<Unit>:
        tx : List<&2, U32> <- B.Bytes.read_all(tok)
        la.run(path, Tk.Bpe.parse(tx))
    case _:
      IO.die(Unit, 2, "usage: bend-agent-laws TOKENIZER TRANSCRIPTS.nul")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    la.args(List.tail(&1, String, argv))
