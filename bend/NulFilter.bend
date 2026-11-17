import Base
import ./Sys.bend as S
import ./Check/Lib.bend as Cl
import ./CorpusV2/Pool.bend as P

# bend-nul-filter: R8's last pass over a NUL stream of (id, text) pairs (2026-11-17, docs/r8/PLAN.md).
#
#   bend-nul-filter IN.nul OUT.nul      env NF_MAXB (bytes; 0: no cut), NF_PRIVATE (a file of needles, a line each)
#
# Two jobs, the user's, 11-17:
#   - "Fix" R8's packing: bend-windows' best fit uses a whole filler document for a window's gap (100 to 500
#     tokens), so a shard of 4,194 documents ran out at window ~3,800 although it held 14 times the tokens it
#     needed.  A text over NF_MAXB + NF_MAXB/4 bytes is cut (nf.cut) into pieces of at most NF_MAXB bytes, each
#     at its last line break past NF_MAXB/2 (else its last blank there, else at NF_MAXB): the pieces, in order,
#     are the text (law nf.cut.ex1, nf.cut.ex2), and each gap draws on one of them.  The first piece keeps the
#     id; the next ones are ID~1, ID~2, ...
#   - the user, 11-15: "secrets, emails and netsem out".  A pair goes (drop-private) when its text or id holds
#     a needle of NF_PRIVATE (the user's own addresses: the file is not in git), or it is the user's own code
#     (an id `own:...`) and its id names a secret or its text holds an email address (nf.email).
# OUT.stats and stdout: in, out (the pairs written), cut (the texts cut), pieces, drop-private.

def nf.letter(+c: U32) -> Bool:
  Bool.or(Bool.and(U32.is_lt(64, c), U32.is_lt(c, 91)), Bool.and(U32.is_lt(96, c), U32.is_lt(c, 123)))

def nf.alnum(+c: U32) -> Bool:
  Bool.or(nf.letter(c), Bool.and(U32.is_lt(47, c), U32.is_lt(c, 58)))

# a byte of an address's local part: a letter, a digit or . _ % + -
def nf.loc(+c: U32) -> Bool:
  Bool.or(nf.alnum(c), Bool.or(U32.is_eq(c, 46), Bool.or(U32.is_eq(c, 95), Bool.or(U32.is_eq(c, 37), Bool.or(U32.is_eq(c, 43), U32.is_eq(c, 45))))))

# a byte of a domain: a letter, a digit, . or -
def nf.dch(+c: U32) -> Bool:
  Bool.or(nf.alnum(c), Bool.or(U32.is_eq(c, 46), U32.is_eq(c, 45)))

def nf.hd(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      nf.dch(c)

# the domain at xs's front
def nf.dom(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case +c <> +t True{}:
      c <> nf.dom(t, nf.hd(t))
    case _ _:
      Nil{}

def nf.hdot(+xs: List<&2, U32>) -> Bool:
  S.head.is(xs, 46)

def nf.undot(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case c <> +t True{}:
      nf.undot(t, nf.hdot(t))
    case _ _:
      xs

def nf.hnd(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      Bool.not(U32.is_eq(c, 46))

# xs up to its first `.`
def nf.label(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case +c <> +t True{}:
      c <> nf.label(t, nf.hnd(t))
    case _ _:
      Nil{}

def nf.letters(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(nf.letter(c), nf.letters(t))

# does d (a domain, as nf.dom reads it) end in `.` and a label of 2 or more letters
def nf.isdom(+d: List<&2, U32>) -> Bool:
  +r = nf.undot(List.reverse(&2, U32, d), nf.hdot(List.reverse(&2, U32, d)))
  +l = nf.label(r, nf.hnd(r))
  Bool.and(Nat.is_lt(1n, S.len(l)), Bool.and(nf.letters(l), Nat.is_lt(S.len(l), S.len(r))))

# the class of the byte after t's head: 2 an address starts at t's `@` (prev: the byte before is a local part's)
def nf.k2(at: Bool, +t: List<&2, U32>) -> Nat:
  match at:
    case True{}:
      +d = List.drop(&2, U32, t, 1n)
      Bool.pick(Nat, nf.isdom(nf.dom(d, nf.hd(d))), 2n, 0n)
    case False{}:
      0n

def nf.k(+prev: Bool, +t: List<&2, U32>) -> Nat:
  nf.k2(Bool.and(prev, S.head.is(t, 64)), t)

def nf.email.go(xs: List<&2, U32>, k: Nat) -> Bool:
  match xs k:
    case Nil{} _:
      False{}
    case _ 2n:
      True{}
    case +c <> +t _:
      nf.email.go(t, nf.k(nf.loc(c), t))

# does xs hold an email address (`a.b@c.de`)
def nf.email(+xs: List<&2, U32>) -> Bool:
  nf.email.go(xs, 0n)

law nf.email.ex1:
  {nf.email(S.b("write to jo.x@ex-1.org now")) == True{} : Bool}

def nf.email.ex1():
  {==}

law nf.email.ex2:
  {nf.email(S.b("inputs@{ self, nixpkgs }: and x@y.z1 and @me.com")) == False{} : Bool}

def nf.email.ex2():
  {==}

def nf.any(+x: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case +n <> t:
      Bool.or(S.infix(x, n), nf.any(x, t))

# does a pair go: a needle in its id or text, or the user's own code naming a secret or holding an address
def nf.private(+ns: List<&2, List<&2, U32>>, +id: List<&2, U32>, +t: List<&2, U32>) -> Bool:
  +own = S.prefix(id, S.b("own:"))
  Bool.or(nf.any(id, ns), Bool.or(nf.any(t, ns),
    Bool.and(own, Bool.or(S.infix(id, S.b("secret")), nf.email(t)))))

law nf.private.ex1:
  {nf.private(Nil{}, S.b("own:a/secrets/secrets.nix"), S.b("x = 1;")) == True{} : Bool}

def nf.private.ex1():
  {==}

law nf.private.ex2:
  {nf.private(Nil{}, S.b("repo:a/b.hs"), S.b("-- Author: a@b.org")) == False{} : Bool}

def nf.private.ex2():
  {==}

# the length past xs's last byte c (0 when xs has none), i the bytes before xs
def nf.last.go(xs: List<&2, U32>, +c: U32, +i: Nat, +best: Nat) -> Nat:
  match xs:
    case Nil{}:
      best
    case +h <> t:
      nf.last.go(t, c, 1n+i, Bool.pick(Nat, U32.is_eq(h, c), 1n+i, best))

# a first piece's length from w, the text's first maxb bytes
def nf.brk(+maxb: Nat, +w: List<&2, U32>) -> Nat:
  +h = Nat.div(maxb, 2n)
  +nl = nf.last.go(w, 10, 0n, 0n)
  +sp = nf.last.go(w, 32, 0n, 0n)
  Bool.pick(Nat, Nat.is_lt(h, nl), nl, Bool.pick(Nat, Nat.is_lt(h, sp), sp, maxb))

# is a text left whole: no cut (maxb 0), or at most maxb + maxb/4 bytes
def nf.small(+maxb: Nat, +xs: List<&2, U32>) -> Bool:
  Bool.or(Nat.is_eq(maxb, 0n), Nat.is_le(S.len(xs), Nat.add(maxb, Nat.div(maxb, 4n))))

def nf.cut.go(fuel: Nat, +maxb: Nat, +t: List<&2, U32>, small: Bool) -> List<&2, List<&2, U32>>:
  match fuel small:
    case 0n _:
      [t]
    case _ True{}:
      [t]
    case 1n+f False{}:
      +k = nf.brk(maxb, List.take(&2, U32, t, maxb))
      +r = List.drop(&2, U32, t, k)
      List.take(&2, U32, t, k) <> nf.cut.go(f, maxb, r, nf.small(maxb, r))

# a text's pieces
def nf.cut(+maxb: Nat, +t: List<&2, U32>) -> List<&2, List<&2, U32>>:
  nf.cut.go(1n+S.len(t), maxb, t, nf.small(maxb, t))

law nf.cut.ex1:
  {nf.cut(8n, S.b("aaaa bbbb cccc dddd")) == [S.b("aaaa "), S.b("bbbb "), S.b("cccc dddd")] : List<&2, List<&2, U32>>}

def nf.cut.ex1():
  {==}

law nf.cut.ex2:
  {nf.cut(8n, S.b("ab\ncdefghijklmn")) == [S.b("ab\ncdefg"), S.b("hijklmn")] : List<&2, List<&2, U32>>}

def nf.cut.ex2():
  {==}

law nf.cut.ex3:
  {nf.cut(0n, S.b("whole")) == [S.b("whole")] : List<&2, List<&2, U32>>}

def nf.cut.ex3():
  {==}

# a piece's id: the first keeps the text's, the i-th (i > 0) is ID~i
def nf.pid(+id: List<&2, U32>, +i: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(i, 0n), id, S.append(id, S.b("~" ++ Nat.show(i))))

def nf.emit(ps: List<&2, List<&2, U32>>, +id: List<&2, U32>, +i: Nat, o: File) -> IO(File):
  match ps:
    case Nil{}:
      IO.pure(File, o)
    case +p <> t:
      do IO<File>:
        o2 : File <- P.po.emit3(o, S.append(nf.pid(id, i), [0]), p)
        nf.emit(t, id, 1n+i, o2)

type NfSt is Type:
  NfSt{r: S.Rd, o: File, st: List<&2, Cl.Stat>, more: Bool}

def nf.put(+maxb: Nat, drop: Bool, r: S.Rd, o: File, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(NfSt):
  match drop:
    case True{}:
      IO.pure(NfSt, NfSt{r, o, Cl.stat.bump("drop-private", 1n, st), True{}})
    case False{}:
      +ps = nf.cut(maxb, t)
      +n = List.length(&2, List<&2, U32>, ps)
      do IO<NfSt>:
        o2 : File <- nf.emit(ps, id, 0n, o)
        return NfSt{r, o2, Cl.stat.bump("out", n, Cl.stat.bump("cut", Bool.pick(Nat, Nat.is_lt(1n, n), 1n, 0n), st)), True{}}

def nf.text(+maxb: Nat, +ns: List<&2, List<&2, U32>>, o: File, st: List<&2, Cl.Stat>, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(NfSt):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(NfSt, NfSt{r, o, Cl.stat.bump("odd", 1n, st), False{}})
    case Some{+t}:
      nf.put(maxb, nf.private(ns, id, t), r, o, Cl.stat.bump("in", 1n, st), id, t)

def nf.id(+maxb: Nat, +ns: List<&2, List<&2, U32>>, r: S.Rd, o: File, st: List<&2, Cl.Stat>, m: Maybe<&2, List<&2, U32>>) -> IO(NfSt):
  match m:
    case None{}:
      IO.pure(NfSt, NfSt{r, o, st, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, NfSt, S.Rd.next(r), nf.text(maxb, ns, o, st, id))

def nf.got(+maxb: Nat, +ns: List<&2, List<&2, U32>>, o: File, st: List<&2, Cl.Stat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(NfSt):
  (r, m) = x
  nf.id(maxb, ns, r, o, st, m)

def nf.step(+maxb: Nat, +ns: List<&2, List<&2, U32>>, s: NfSt) -> IO(NfSt):
  match s:
    case NfSt{r, o, st, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, NfSt, S.Rd.next(r), nf.got(maxb, ns, o, st))

def nf.go(fuel: Nat, +maxb: Nat, +ns: List<&2, List<&2, U32>>, s: NfSt) -> IO(NfSt):
  match fuel s:
    case 1n+f NfSt{r, o, st, True{}}:
      IO.bind(NfSt, NfSt, nf.step(maxb, ns, NfSt{r, o, st, True{}}), nf.go(f, maxb, ns))
    case _ s2:
      IO.pure(NfSt, s2)

def nf.fin(+out: String, s: NfSt) -> IO(Unit):
  match s:
    case NfSt{r, o, +st, g}:
      do IO<Unit>:
        S.Rd.close(r)
        File.close(o)
        S.write(out ++ ".stats", S.b(Cl.stat.show(st)))
        IO.print(S.str(S.chomp(S.b(Cl.stat.show(st)))))

# the needles: NF_PRIVATE's lines, the empty ones left out
def nf.lines(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = nf.lines(t)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(l), 0n), r, l <> r)

def nf.needles(+path: String, ok: Bool) -> IO(List<&2, List<&2, U32>>):
  match ok:
    case True{}:
      do IO<List<&2, List<&2, U32>>>:
        xs : List<&2, U32> <- S.read(path)
        return nf.lines(S.split(xs, 10))
    case False{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})

def nf.run(+maxb: Nat, +ns: List<&2, List<&2, U32>>, +inp: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    r : S.Rd <- S.Rd.open(inp)
    o : File <- IO.try(File, File.open(out, "w"))
    s : NfSt <- nf.go(U32.to_nat(4294967295), maxb, ns, NfSt{r, o, Nil{}, True{}})
    nf.fin(out, s)

def nf.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +i <> +o <> Nil{}:
      do IO<Unit>:
        maxb : Nat <- S.env.nat("NF_MAXB", 0n)
        +p : String <- S.env("NF_PRIVATE", "")
        ok : Bool <- S.exists(p)
        ns : List<&2, List<&2, U32>> <- nf.needles(p, Bool.and(Bool.not(Nat.is_eq(S.len(S.b(p)), 0n)), ok))
        nf.run(maxb, ns, i, o)
    case _:
      IO.die(Unit, 2, "usage: bend-nul-filter IN.nul OUT.nul   (env NF_MAXB: cut texts over it, bytes, 0 none; NF_PRIVATE: needles file)")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    nf.main(xs)
