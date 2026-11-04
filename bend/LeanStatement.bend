import Base
import ./Sys.bend as S
import ./Check/Lib.bend as Cl

# Lean's first-time sessions with the whole statement (2026-11-03, for run 5).
#
# The source records split a theorem at its first `:=`, which for a statement
# with a `let` falls inside the statement: the prompt of a direct session
# stops at `let x : R`, she is asked for a theorem she cannot see, and a fill
# session's hole breaks the statement, not the proof.  19% of the direct
# prompts in a sample of 199.  This goes over the rendered sessions (the
# NUL-framed id and text, a unit's sessions together, the direct one first),
# before repair-mix:
#
#   a direct session cut inside the statement   its prompt gets the whole
#                                               statement, read off its own
#                                               answer; left out if that could
#                                               pass the size the renderer
#                                               keeps to
#   a fill session of such a unit               left out (repair-mix's ratio
#                                               counts no fills)
#   everything else                             byte for byte
#
#   bend-lean-statement IN SIZES OUT [LIMIT]
#
# Counts on stdout, what it changed in OUT.changed (`rewrote`, `dropped` or
# `too-large`, a tab, the id), the sessions it rewrote in OUT.rewritten (for
# bend-agent-laws).  SIZES is the render's (ID SHAPE TOKENS ...).  LIMIT, in
# tokens, is the renderer's own (a window of 2048 less 64, bend/Transcript.bend):
# bend-windows stops the whole plan on one session past a window of 2046.  A
# token is at least a byte, so a session's old tokens plus the bytes it gains
# bound its new tokens, with no need of the tokenizer.

# Where a statement stops -----------------------------------------------------

# the walk: m is where it is, d the brackets open, o the `let`s and `have`s of
# the statement still waiting for their `:=`, e whether this byte ended it
#   m  0 code, 5 a word, 1 a line comment, 7 and 2 and 6 a block comment (its
#      opening's second byte, its body, its closing's second byte), 3 a string,
#      4 past a backslash in a string
type St is Data:
  St{m: U32, d: Nat, o: Nat, e: Bool}

def St.e(+s: St) -> Bool:
  match s:
    case St{m, d, o, e}:
      e

# a letter, a digit, _ ' . ! ? or any byte of a character past ASCII
def ls.word(+c: U32) -> Bool:
  Bool.or(U32.is_lt(127, c), Bool.or(Bool.and(U32.is_lt(96, c), U32.is_lt(c, 123)), Bool.or(Bool.and(U32.is_lt(64, c), U32.is_lt(c, 91)),
    Bool.or(Bool.and(U32.is_lt(47, c), U32.is_lt(c, 58)), Bool.or(U32.is_eq(c, 95), Bool.or(U32.is_eq(c, 39), Bool.or(U32.is_eq(c, 46),
      Bool.or(U32.is_eq(c, 33), U32.is_eq(c, 63)))))))))

def ls.word.at(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      ls.word(h)

# ⟨ ⟦ ⦃ and ⟩ ⟧ ⦄, as bytes
def ls.opens(+c: U32, +t: List<&2, U32>) -> Bool:
  Bool.or(U32.is_eq(c, 40), Bool.or(U32.is_eq(c, 91), Bool.or(U32.is_eq(c, 123), Bool.and(U32.is_eq(c, 226),
    Bool.or(S.prefix(t, [159, 168]), Bool.or(S.prefix(t, [159, 166]), S.prefix(t, [166, 131])))))))

def ls.closes(+c: U32, +t: List<&2, U32>) -> Bool:
  Bool.or(U32.is_eq(c, 41), Bool.or(U32.is_eq(c, 93), Bool.or(U32.is_eq(c, 125), Bool.and(U32.is_eq(c, 226),
    Bool.or(S.prefix(t, [159, 169]), Bool.or(S.prefix(t, [159, 167]), S.prefix(t, [166, 132])))))))

def ls.pred(n: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+k:
      k

# xs starts with the word w, whole
def ls.kw(+xs: List<&2, U32>, +w: List<&2, U32>) -> Bool:
  Bool.and(S.prefix(xs, w), Bool.not(ls.word.at(List.drop(&2, U32, xs, S.len(w)))))

def ls.owns(+d: Nat, +xs: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_eq(d, 0n), Bool.or(ls.kw(xs, S.b("let")), ls.kw(xs, S.b("have")))), 1n, 0n)

def ls.code(+c: U32, +t: List<&2, U32>, +d: Nat, +o: Nat) -> St:
  Bool.pick(St, ls.opens(c, t), St{0, 1n+d, o, False{}},
    Bool.pick(St, ls.closes(c, t), St{0, ls.pred(d), o, False{}},
      Bool.pick(St, Bool.and(U32.is_eq(c, 45), S.head.is(t, 45)), St{1, d, o, False{}},
        Bool.pick(St, Bool.and(U32.is_eq(c, 47), S.head.is(t, 45)), St{7, d, o, False{}},
          Bool.pick(St, U32.is_eq(c, 34), St{3, d, o, False{}},
            Bool.pick(St, Bool.and(Nat.is_eq(d, 0n), Bool.and(U32.is_eq(c, 58), S.head.is(t, 61))), St{0, d, ls.pred(o), Nat.is_eq(o, 0n)},
              Bool.pick(St, ls.word(c), St{5, d, Nat.add(o, ls.owns(d, c <> t)), False{}}, St{0, d, o, False{}})))))))

def ls.in.word(+c: U32, +t: List<&2, U32>, +d: Nat, +o: Nat) -> St:
  Bool.pick(St, Bool.and(ls.word(c), Bool.not(Bool.or(ls.opens(c, t), ls.closes(c, t)))), St{5, d, o, False{}}, ls.code(c, t, d, o))

def ls.pick(+yes: Bool, +a: U32, +b: U32, +d: Nat, +o: Nat) -> St:
  St{Bool.pick(U32, yes, a, b), d, o, False{}}

def ls.step(+c: U32, +t: List<&2, U32>, +s: St) -> St:
  match s:
    case St{+m, +d, +o, e}:
      Bool.pick(St, U32.is_eq(m, 0), ls.code(c, t, d, o),
        Bool.pick(St, U32.is_eq(m, 5), ls.in.word(c, t, d, o),
          Bool.pick(St, U32.is_eq(m, 1), ls.pick(U32.is_eq(c, 10), 0, 1, d, o),
            Bool.pick(St, U32.is_eq(m, 2), ls.pick(Bool.and(U32.is_eq(c, 45), S.head.is(t, 47)), 6, 2, d, o),
              Bool.pick(St, U32.is_eq(m, 6), St{0, d, o, False{}},
                Bool.pick(St, U32.is_eq(m, 7), St{2, d, o, False{}},
                  Bool.pick(St, U32.is_eq(m, 4), St{3, d, o, False{}},
                    Bool.pick(St, U32.is_eq(c, 92), St{4, d, o, False{}}, ls.pick(U32.is_eq(c, 34), 0, 3, d, o)))))))))

def ls.walk(xs: List<&2, U32>, +s: St, +i: Nat) -> Maybe<&2, Nat>:
  match xs:
    case Nil{}:
      None{}
    case +c <> +t:
      +s2 = ls.step(c, t, s)
      Bool.pick(Maybe<&2, Nat>, St.e(s2), Some{i}, ls.walk(t, s2, 1n+i))

# Where the statement stops: the `:=` outside any bracket that no `let` or
# `have` of the statement owns; None without one (a `where`, or patterns).
def ls.end(xs: List<&2, U32>) -> Maybe<&2, Nat>:
  ls.walk(xs, St{0, 0n, 0n, False{}}, 0n)

# A session's parts -----------------------------------------------------------

def ls.space(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 32), Bool.or(U32.is_eq(c, 10), Bool.or(U32.is_eq(c, 9), U32.is_eq(c, 13))))

def ls.ltrim(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, ls.space(h), ls.ltrim(t), h <> t)

def ls.rtrim(+xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, ls.ltrim(List.reverse(&2, U32, xs)))

# the first p at or past k
def ls.after(+xs: List<&2, U32>, +p: List<&2, U32>, +k: Nat) -> Maybe<&2, Nat>:
  S.find(List.drop(&2, U32, xs, k), p, k)

type Sp is Data:
  Sp{a: Nat, b: Nat}

def ls.span.end(+a: Nat, m: Maybe<&2, Nat>) -> Maybe<&2, Sp>:
  match m:
    case None{}:
      None{}
    case Some{+b}:
      Some{Sp{a, b}}

def ls.before(+x: Nat, m: Maybe<&2, Nat>) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{+y}:
      Nat.is_lt(x, y)

def ls.span.at(+t: List<&2, U32>, h: Maybe<&2, Nat>, m: Maybe<&2, Nat>) -> Maybe<&2, Sp>:
  match m:
    case None{}:
      None{}
    case Some{+x}:
      Bool.pick(Maybe<&2, Sp>, ls.before(x, h), ls.span.end(Nat.add(x, 8n), ls.after(t, S.b("\n```"), Nat.add(x, 8n))), None{})

# the statement in a direct session's prompt: the code block before the
# session's second heading
def ls.span(+t: List<&2, U32>) -> Maybe<&2, Sp>:
  ls.span.at(t, ls.after(t, S.b("\n## "), 1n), S.find(t, S.b("```lean\n"), 0n))

def ls.plus(ls0: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls0:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = ls.plus(t)
      Bool.pick(List<&2, U32>, S.head.is(l, 43), S.append(List.drop(&2, U32, l, 1n), 10 <> rest), rest)

def ls.upto(+xs: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case None{}:
      xs
    case Some{+k}:
      List.take(&2, U32, xs, k)

def ls.added.at(+t: List<&2, U32>, m: Maybe<&2, Nat>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      None{}
    case Some{+k}:
      +body = List.drop(&2, U32, t, Nat.add(k, 10n))
      # its first line names the file
      Some{ls.plus(List.drop(&2, List<&2, U32>, S.split.lines(ls.upto(body, S.find(body, S.b("\n\n## "), 0n))), 1n))}

# what the session's first edit writes
def ls.added(+t: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  ls.added.at(t, S.find(t, S.b("\n## edit\n\n"), 0n))

# The whole statement ---------------------------------------------------------

type Wh is Data:
  WhCut{stated: List<&2, U32>, a: Nat, b: Nat}
  WhNot{why: String}

def ls.wh.end(+a: Nat, +b: Nat, +p: List<&2, U32>, +d: List<&2, U32>, m: Maybe<&2, Nat>) -> Wh:
  match m:
    case None{}:
      WhNot{"no-:="}
    case Some{+e}:
      +s = ls.rtrim(List.take(&2, U32, d, e))
      Bool.pick(Wh, Nat.is_lt(S.len(ls.rtrim(p)), S.len(s)), WhCut{s, a, b}, WhNot{"whole"})

def ls.wh.at(+a: Nat, +b: Nat, +p: List<&2, U32>, +n: List<&2, U32>, m: Maybe<&2, Nat>) -> Wh:
  match m:
    case None{}:
      WhNot{"prompt-not-in-answer"}
    case Some{+k}:
      +d = List.drop(&2, U32, n, k)
      ls.wh.end(a, b, p, d, ls.end(d))

def ls.wh.new(+a: Nat, +b: Nat, +p: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> Wh:
  match m:
    case None{}:
      WhNot{"no-edit"}
    case Some{+n}:
      ls.wh.at(a, b, p, n, S.find(n, p, 0n))

def ls.wh.span(+t: List<&2, U32>, m: Maybe<&2, Sp>) -> Wh:
  match m:
    case None{}:
      WhNot{"no-prompt"}
    case Some{Sp{+a, +b}}:
      ls.wh.new(a, b, List.take(&2, U32, List.drop(&2, U32, t, a), Nat.sub(b, a)), ls.added(t))

# a direct session: its whole statement when its prompt stops short of it
def ls.whole(+t: List<&2, U32>) -> Wh:
  ls.wh.span(t, ls.span(t))

# the session with the statement in the prompt's place
def ls.put(+t: List<&2, U32>, +s: List<&2, U32>, +a: Nat, +b: Nat) -> List<&2, U32>:
  S.append(List.take(&2, U32, t, a), S.append(s, List.drop(&2, U32, t, b)))

# a fill whose own check shows its hole in the statement
def ls.fill.bad(+t: List<&2, U32>) -> Bool:
  Bool.or(S.infix(t, S.b("All parameter types and holes")), S.infix(t, S.b("unexpected end of input")))

def ls.tag(+id: List<&2, U32>, +tag: String) -> Bool:
  S.suffix(id, S.b(tag))

def ls.unit(+id: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  List.take(&2, U32, id, Nat.sub(S.len(id), n))

# The tool ---------------------------------------------------------------------

def ls.pair(+id: List<&2, U32>, +t: List<&2, U32>) -> List<&2, U32>:
  S.append(id, 0 <> S.append(t, [0]))

def ls.line(+what: String, +id: List<&2, U32>) -> List<&2, U32>:
  S.append(S.b(what), 9 <> S.append(id, [10]))

type Lz is Type:
  Lz{r: S.Rd, z: Map<&2, Nat>, more: Bool}

def ls.z.put(z: Map<&2, Nat>, +i: List<&2, U32>, +n: List<&2, U32>, yes: Bool) -> Map<&2, Nat>:
  match yes:
    case True{}:
      Map.set(&2, Nat, z, S.str(i), 1n+Maybe.default(&2, Nat, Nat.read(S.str(n)), 0n))
    case False{}:
      z

def ls.z.fields(z: Map<&2, Nat>, fs: List<&2, List<&2, U32>>) -> Map<&2, Nat>:
  match fs:
    case +i <> sh <> +n <> more:
      ls.z.put(z, i, n, ls.tag(i, "/mugen-direct"))
    case _:
      z

def ls.z.got(z: Map<&2, Nat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Lz):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(Lz, Lz{r, z, False{}})
    case Some{+l}:
      IO.pure(Lz, Lz{r, ls.z.fields(z, S.split(l, 9)), True{}})

def ls.z.go(fuel: Nat, s: Lz) -> IO(Lz):
  match fuel s:
    case 1n+f Lz{r, z, True{}}:
      IO.bind(Lz, Lz, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, Lz, S.Rd.next(r), ls.z.got(z)), ls.z.go(f))
    case _ s2:
      IO.pure(Lz, s2)

def ls.z.fin(s: Lz) -> IO(Map<&2, Nat>):
  match s:
    case Lz{r, z, g}:
      do IO<Map<&2, Nat>>:
        S.Rd.close(r)
        return z

# each direct session's tokens, plus one (a miss is 0)
def ls.sizes(path: String) -> IO(Map<&2, Nat>):
  do IO<Map<&2, Nat>>:
    r : S.Rd <- S.Rd.lines(path)
    s : Lz <- ls.z.go(U32.to_nat(4294967295), Lz{r, Map.new(&2, Nat), True{}})
    ls.z.fin(s)

# the reader, the three outputs, the sizes, the last unit cut, the counts
type Ls is Type:
  Ls{r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, u: List<&2, U32>, st: List<&2, Cl.Stat>, more: Bool, odd: Bool}

def ls.keep(r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, u: List<&2, U32>, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(Ls):
  do IO<Ls>:
    o2 : File <- S.emit(o, ls.pair(id, t))
    return Ls{r, o2, c, v, z, u, st, True{}, False{}}

def ls.out(r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, u: List<&2, U32>, st: List<&2, Cl.Stat>, +what: String, +id: List<&2, U32>) -> IO(Ls):
  do IO<Ls>:
    c2 : File <- S.emit(c, ls.line(what, id))
    return Ls{r, o, c2, v, z, u, st, True{}, False{}}

def ls.rewrite(r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, u: List<&2, U32>, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(Ls):
  do IO<Ls>:
    o2 : File <- S.emit(o, ls.pair(id, t))
    v2 : File <- S.emit(v, ls.pair(id, t))
    c2 : File <- S.emit(c, ls.line("rewrote", id))
    return Ls{r, o2, c2, v2, z, u, st, True{}, False{}}

def ls.cut.fit(r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, u: List<&2, U32>, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>, fits: Bool) -> IO(Ls):
  match fits:
    case True{}:
      ls.rewrite(r, o, c, v, z, u, st, id, t)
    case False{}:
      ls.out(r, o, c, v, z, u, Cl.stat.bump("direct cut, too large whole", 1n, st), "too-large", id)

def ls.cut.on(r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, u: List<&2, U32>, st: List<&2, Cl.Stat>, +limit: Nat, +id: List<&2, U32>, +t: List<&2, U32>, +s: List<&2, U32>, +a: Nat, +b: Nat, n: Nat) -> IO(Ls):
  match n:
    case 0n:
      ls.out(r, o, c, v, z, u, Cl.stat.bump("direct cut, no size", 1n, st), "too-large", id)
    case 1n+k:
      ls.cut.fit(r, o, c, v, z, u, st, id, ls.put(t, s, a, b), Bool.not(Nat.is_lt(limit, Nat.add(k, Nat.sub(S.len(s), Nat.sub(b, a))))))

def ls.cut.size(r: S.Rd, o: File, c: File, v: File, u: List<&2, U32>, st: List<&2, Cl.Stat>, +limit: Nat, +id: List<&2, U32>, +t: List<&2, U32>, +s: List<&2, U32>, +a: Nat, +b: Nat, y: Map<&2, Nat> & Nat) -> IO(Ls):
  (z, n) = y
  ls.cut.on(r, o, c, v, z, u, st, limit, id, t, s, a, b, n)

def ls.direct(r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, u: List<&2, U32>, st: List<&2, Cl.Stat>, +limit: Nat, +id: List<&2, U32>, +t: List<&2, U32>, +w: Wh) -> IO(Ls):
  match w:
    case WhNot{+why}:
      ls.keep(r, o, c, v, z, u, Cl.stat.bump("direct " ++ why, 1n, st), id, t)
    case WhCut{+s, +a, +b}:
      ls.cut.size(r, o, c, v, ls.unit(id, 13n), Cl.stat.bump("direct cut", 1n, st), limit, id, t, s, a, b, Map.get(Nat, 0n, z, S.str(id)))

def ls.fill(r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, +u: List<&2, U32>, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>, cut: Bool, bad: Bool) -> IO(Ls):
  match cut bad:
    case True{} _:
      ls.out(r, o, c, v, z, u, Cl.stat.bump("fill dropped", 1n, st), "dropped", id)
    case False{} True{}:
      ls.out(r, o, c, v, z, u, Cl.stat.bump("fill dropped by its check", 1n, st), "dropped", id)
    case False{} False{}:
      ls.keep(r, o, c, v, z, u, st, id, t)

def ls.kind(r: S.Rd, o: File, c: File, v: File, z: Map<&2, Nat>, +u: List<&2, U32>, st: List<&2, Cl.Stat>, +limit: Nat, +id: List<&2, U32>, +t: List<&2, U32>, direct: Bool, fill: Bool) -> IO(Ls):
  match direct fill:
    case True{} _:
      ls.direct(r, o, c, v, z, u, st, limit, id, t, ls.whole(t))
    case False{} True{}:
      ls.fill(r, o, c, v, z, u, Cl.stat.bump("fill", 1n, st), id, t, S.eq(ls.unit(id, 11n), u), ls.fill.bad(t))
    case False{} False{}:
      ls.keep(r, o, c, v, z, u, Cl.stat.bump("other", 1n, st), id, t)

def ls.pair.got(o: File, c: File, v: File, z: Map<&2, Nat>, +u: List<&2, U32>, st: List<&2, Cl.Stat>, +limit: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Ls):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(Ls, Ls{r, o, c, v, z, u, st, False{}, True{}})
    case Some{+t}:
      ls.kind(r, o, c, v, z, u, st, limit, id, t, ls.tag(id, "/mugen-direct"), ls.tag(id, "/mugen-fill"))

def ls.id.got(o: File, c: File, v: File, z: Map<&2, Nat>, u: List<&2, U32>, st: List<&2, Cl.Stat>, +limit: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Ls):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(Ls, Ls{r, o, c, v, z, u, st, False{}, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, Ls, S.Rd.next(r), ls.pair.got(o, c, v, z, u, st, limit, id))

def ls.go(fuel: Nat, +limit: Nat, s: Ls) -> IO(Ls):
  match fuel s:
    case 1n+f Ls{r, o, c, v, z, u, st, True{}, odd}:
      IO.bind(Ls, Ls, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, Ls, S.Rd.next(r), ls.id.got(o, c, v, z, u, st, limit)), ls.go(f, limit))
    case _ s2:
      IO.pure(Ls, s2)

def ls.odd(+path: String, odd: Bool) -> IO(Unit):
  match odd:
    case True{}:
      IO.die(Unit, 1, "lean-statement: " ++ path ++ " ends with an id that has no text")
    case False{}:
      IO.pure(Unit, Unit{})

def ls.fin(+path: String, s: Ls) -> IO(String):
  match s:
    case Ls{r, o, c, v, z, u, +st, g, odd}:
      do IO<String>:
        S.Rd.close(r)
        File.close(o)
        File.close(c)
        File.close(v)
        ls.odd(path, odd)
        return Cl.stat.show(st)

# the counts, as `name n` lines
def ls.run(+inp: String, sizes: String, +out: String, +limit: Nat) -> IO(String):
  do IO<String>:
    z : Map<&2, Nat> <- ls.sizes(sizes)
    r : S.Rd <- S.Rd.open(inp)
    o : File <- IO.try(File, File.open(out, "w"))
    c : File <- IO.try(File, File.open(out ++ ".changed", "w"))
    v : File <- IO.try(File, File.open(out ++ ".rewritten", "w"))
    s : Ls <- ls.go(U32.to_nat(4294967295), limit, Ls{r, o, c, v, z, Nil{}, Nil{}, True{}, False{}})
    ls.fin(inp, s)

def ls.tool(+inp: String, sizes: String, +out: String, +limit: Nat) -> IO(Unit):
  do IO<Unit>:
    +counts : String <- ls.run(inp, sizes, out, limit)
    IO.print(counts)

def ls.args(xs: List<String>) -> IO(Unit):
  match xs:
    case +inp <> sizes <> +out <> Nil{}:
      ls.tool(inp, sizes, out, 1984n)
    case +inp <> sizes <> +out <> l <> Nil{}:
      ls.tool(inp, sizes, out, Maybe.default(&2, Nat, Nat.read(l), 1984n))
    case _:
      IO.die(Unit, 2, "usage: bend-lean-statement IN SIZES OUT [LIMIT]")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked (Bend 2.0.32)
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    ls.args(xs)
