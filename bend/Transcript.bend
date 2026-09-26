import Base
import ./Bytes.bend as B
import ./Tokenizer.bend as Tk
import ./Nul.bend as Ns
import ./Units.bend as U

# transcripts: the checked units (bend-check LANG) rendered as the
# coding-agent documents of docs/TRANSCRIPT-FORMAT.md.
#
#   bend-transcript TOKENIZER RESULTS.nul OUTPUT.nul [WINDOW]
#
# Each input pair is a unit with its checks (bend/Check.bend lists the
# fields). The output is one (id, text) pair per transcript, the id the
# unit's with `/<shape>` appended; a transcript whose tokens (under
# TOKENIZER, plus BOS and EOS) pass WINDOW - 64 (WINDOW default 2048) is
# dropped, never cut.
#
# The shape comes from a hash of the unit's id: 60 type-to-term, 25 hole,
# 15 term-to-type. A unit without what its shape needs (a hole check; a
# type check, which only ghc gives) is rendered type-to-term. Within
# type-to-term a quarter answer right the first time (or all, when no
# mutant failed); the others answer with a mutant first, read the checker,
# and answer again with the original. A unit with a mutant its first
# transcript did not use gives one more type-to-term repair with it, so a
# declaration gives at most two transcripts.
#
# Turns: `## User`, `## Context`, `## Type` (a flag line, proposition or
# type, then the fence), `## Term`, and the checker's (`## ghc`, `## agda`,
# `## lean`, `## bend`, `## nix`): its output verbatim, at most 40 lines
# (a longer output ends with a line saying how many were left out), then
# `[exit N]`. A goal display from Agda's interaction mode has no exit line.

# Bytes -------------------------------------------------------------------------

def head.is(+xs: List<&2, U32>, +s: U32) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, s)
    case Nil{}:
      False{}

# xs cut at every s
def split.go(xs: List<&2, U32>, +s: U32, cur: List<&2, U32>, acc: List<&2, List<&2, U32>>, at: Bool) -> List<&2, List<&2, U32>>:
  match xs at:
    case Nil{} _:
      List.reverse(&2, List<&2, U32>, List.reverse(&2, U32, cur) <> acc)
    case h <> +t True{}:
      split.go(t, s, Nil{}, List.reverse(&2, U32, cur) <> acc, head.is(t, s))
    case h <> +t False{}:
      split.go(t, s, h <> cur, acc, head.is(t, s))

def split(+xs: List<&2, U32>, +s: U32) -> List<&2, List<&2, U32>>:
  split.go(xs, s, Nil{}, Nil{}, head.is(xs, s))

def field(+fs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  U.nth(fs, i)

def empty(+xs: List<&2, U32>) -> Bool:
  Nat.is_eq(U.len(xs), 0n)

def cat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  U.concat(xss)

def nl() -> List<&2, U32>:
  [10]

# without leading newlines, and without the first line's leading spaces when
# it starts the text (lean's `:= by` leaves one)
def drop.nls.go(+xs: List<&2, U32>, nl: Bool) -> List<&2, U32>:
  match xs nl:
    case h <> +t True{}:
      drop.nls.go(t, head.is(t, 10))
    case _ _:
      xs

def lead.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, head.is(xs, 10), drop.nls.go(xs, True{}), U.trim.left(xs))

def tidy(+xs: List<&2, U32>) -> List<&2, U32>:
  U.trim.right(lead.trim(xs))

# Checks ------------------------------------------------------------------------
#
# A check is its status, the byte 0x1F, its output.

type Check is Data:
  Check{status: List<&2, U32>, out: List<&2, U32>}

def check.of(+c: List<&2, U32>) -> Check:
  +k = U.find(c, [31], 0n)
  Check{List.take(&2, U32, c, k), List.drop(&2, U32, c, 1n+k)}

def check.status(+c: Check) -> List<&2, U32>:
  match c:
    case Check{s, o}:
      s

def check.out(+c: Check) -> List<&2, U32>:
  match c:
    case Check{s, o}:
      o

# at most 40 lines, then a line for the rest
def capped(+out: List<&2, U32>) -> List<&2, U32>:
  +ls = U.lines(tidy(out))
  +n = U.lines.count(ls)
  +more = Bool.pick(List<&2, U32>, Nat.is_le(n, 40n), Nil{}, U.b("\n[" ++ Nat.show(Nat.sub(n, 40n)) ++ " more lines]"))
  U.append(U.trim.right(U.concat(List.take(&2, List<&2, U32>, ls, 40n))), more)

def exit.line(+s: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U.eq(s, U.b("-")), Nil{}, cat([U.b("[exit "), s, U.b("]\n")]))

def fence(+lang: List<&2, U32>, +text: List<&2, U32>) -> List<&2, U32>:
  cat([U.b("```"), lang, nl(), text, nl(), U.b("```\n")])

def turn(+label: List<&2, U32>, +body: List<&2, U32>) -> List<&2, U32>:
  cat([U.b("## "), label, U.b("\n\n"), body, nl()])

# the checker's turn: its output (none: an empty fence), then the status
def checker(+tool: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  +k = check.of(c)
  +o = capped(check.out(k))
  +body = Bool.pick(List<&2, U32>, empty(o), Nil{}, U.append(o, nl()))
  turn(tool, cat([U.b("```\n"), body, exit.line(check.status(k)), U.b("```\n")]))

# Turns --------------------------------------------------------------------------

def tool(+lang: List<&2, U32>) -> List<&2, U32>:
  U.nth([U.b("ghc"), U.b("agda"), U.b("lean"), U.b("bend"), U.b("nix")], U.lang.code.go(U.lang.names(), lang, 0n))

def is.nix(+lang: List<&2, U32>) -> Bool:
  U.eq(lang, U.b("nix"))

def code(+name: List<&2, U32>) -> List<&2, U32>:
  cat([[96], name, [96]])

def ask(+fs: List<&2, List<&2, U32>>, +shape: Nat) -> List<&2, U32>:
  +doc = tidy(field(fs, 3n))
  +name = field(fs, 2n)
  +prop = U.eq(field(fs, 1n), U.b("proposition"))
  +plain = Bool.pick(List<&2, U32>, is.nix(field(fs, 0n)), U.b("Write this Nix expression."),
    Bool.pick(List<&2, U32>, prop, cat([U.b("Prove "), code(name), U.b(".")]), cat([U.b("Define "), code(name), U.b(".")])))
  +typing = cat([U.b("Write the type signature of "), code(name), U.b(".")])
  Bool.pick(List<&2, U32>, Nat.is_eq(shape, 2n), typing, Bool.pick(List<&2, U32>, empty(doc), plain, doc))

def user(+fs: List<&2, List<&2, U32>>, +shape: Nat) -> List<&2, U32>:
  turn(U.b("User"), U.append(ask(fs, shape), nl()))

def context(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +c = tidy(field(fs, 12n))
  Bool.pick(List<&2, U32>, empty(c), Nil{}, turn(U.b("Context"), fence(field(fs, 0n), c)))

def typ(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, is.nix(field(fs, 0n)), Nil{}, turn(U.b("Type"), cat([field(fs, 1n), nl(), fence(field(fs, 0n), tidy(field(fs, 4n)))])))

def term(+fs: List<&2, List<&2, U32>>, +body: List<&2, U32>) -> List<&2, U32>:
  turn(U.b("Term"), fence(field(fs, 0n), tidy(body)))

def check.turn(+fs: List<&2, List<&2, U32>>, +c: List<&2, U32>) -> List<&2, U32>:
  checker(tool(field(fs, 0n)), c)

# Shapes -------------------------------------------------------------------------
#
# 0 type to term, right the first time; 1 type to term with a repair (m is
# the mutant's index); 2 term to type; 3 hole.

def mutant.count(+fs: List<&2, List<&2, U32>>) -> Nat:
  Nat.div(Nat.sub(List.length(&2, List<&2, U32>, fs), 15n), 2n)

# the original answer and the checker's verdict on it
def answer(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  U.append(term(fs, field(fs, 7n)), check.turn(fs, field(fs, 11n)))

def render(+shape: Nat, +fs: List<&2, List<&2, U32>>, +m: Nat) -> List<&2, U32>:
  match shape:
    case 0n:
      cat([user(fs, 0n), context(fs), typ(fs), answer(fs)])
    case 1n:
      +mut = field(fs, Nat.add(15n, Nat.mul(2n, m)))
      +mc = field(fs, Nat.add(16n, Nat.mul(2n, m)))
      cat([user(fs, 1n), context(fs), typ(fs), term(fs, mut), check.turn(fs, mc), answer(fs)])
    case 2n:
      cat([user(fs, 2n), context(fs), term(fs, field(fs, 7n)), check.turn(fs, field(fs, 14n)), typ(fs), check.turn(fs, field(fs, 11n))])
    case _:
      cat([user(fs, 3n), context(fs), typ(fs), term(fs, field(fs, 10n)), check.turn(fs, field(fs, 13n)), answer(fs)])

def shape.name(+shape: Nat) -> List<&2, U32>:
  U.nth([U.b("first-time"), U.b("repair"), U.b("term-to-type"), U.b("hole")], shape)

def roll(+id: List<&2, U32>, +salt: Nat, +n: Nat) -> Nat:
  U.pick.at(id, salt, n)

# the first transcript's shape and mutant
type Plan is Data:
  Plan{shape: Nat, m: Nat}

def plan(+id: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> Plan:
  +r = roll(id, 7n, 100n)
  +nm = mutant.count(fs)
  +hashole = Bool.not(empty(field(fs, 13n)))
  +hastype = Bool.not(empty(field(fs, 14n)))
  +repair = Bool.and(Nat.is_lt(0n, nm), Bool.not(Nat.is_eq(roll(id, 8n, 4n), 0n)))
  +t2t = Bool.pick(Nat, repair, 1n, 0n)
  +shape = Bool.pick(Nat, Nat.is_lt(r, 60n), t2t, Bool.pick(Nat, Nat.is_lt(r, 85n), Bool.pick(Nat, hashole, 3n, t2t), Bool.pick(Nat, hastype, 2n, t2t)))
  Plan{shape, roll(id, 9n, nm)}

# Transcripts --------------------------------------------------------------------

def emit.if(ok: Bool, d: Ns.Doc, ds: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match ok:
    case True{}:
      d <> ds
    case False{}:
      ds

def fits(+b: Tk.Bpe, +limit: Nat, +text: List<&2, U32>) -> Bool:
  Nat.is_le(Nat.add(List.length(&2, U32, Tk.Bpe.encode(b, text)), 2n), limit)

def doc(+b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +shape: Nat, +m: Nat, rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  +text = render(shape, fs, m)
  emit.if(fits(b, limit, text), Ns.Doc{cat([id, U.b("/"), shape.name(shape)]), text}, rest)

# the transcripts of one unit: its plan's, and a repair with another mutant
# the second transcript: a repair with mutant m, when there is one to use
def extra.if(ok: Bool, +b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +m: Nat, rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match ok:
    case True{}:
      doc(b, limit, U.append(id, U.b("+")), fs, 1n, m, rest)
    case False{}:
      rest

def unit.go(p: Plan, +b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match p:
    case Plan{+shape, +m}:
      +nm = mutant.count(fs)
      +used = Nat.is_eq(shape, 1n)
      +extra = Bool.pick(Bool, used, Nat.is_le(2n, nm), Nat.is_le(1n, nm))
      +m2 = Bool.pick(Nat, used, Nat.mod(1n+m, 1n+Nat.sub(nm, 1n)), m)
      doc(b, limit, id, fs, shape, m, extra.if(extra, b, limit, id, fs, m2, rest))

def unit(+b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  unit.go(plan(id, fs), b, limit, id, fs, rest)

def all(+b: Tk.Bpe, +limit: Nat, rs: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      unit(b, limit, i, split(t, 30), all(b, limit, more))

# Main ---------------------------------------------------------------------------

def emit(+out: String, +b: Tk.Bpe, +limit: Nat, +d: Ns.Docs, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "transcript: " ++ Ns.Docs.problem(d))
    case True{}:
      +rs = Ns.Docs.docs(d)
      +ts = all(b, limit, rs)
      do IO<Unit>:
        Ns.write(out, Ns.put(ts, Nil{}))
        IO.print("transcript: " ++ Nat.show(List.length(&2, Ns.Doc, rs)) ++ " units in, " ++ Nat.show(List.length(&2, Ns.Doc, ts)) ++ " transcripts out")

def tokenizer(+out: String, +limit: Nat, m: Maybe<&2, Tk.Bpe>, +d: Ns.Docs) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "transcript: the tokenizer did not parse")
    case Some{+b}:
      emit(out, b, limit, d, String.is_empty(Ns.Docs.problem(d)))

def run(tok: String, inp: String, +out: String, +window: Nat) -> IO(Unit):
  do IO<Unit>:
    tx : List<&2, U32> <- B.Bytes.read_all(tok)
    +xs : List<&2, U32> <- Ns.read(inp)
    tokenizer(out, Nat.sub(window, 64n), Tk.Bpe.parse(tx), Ns.docs(xs))

def window.of(xs: List<String>) -> Nat:
  match xs:
    case Nil{}:
      2048n
    case x <> t:
      Maybe.default(&2, Nat, Nat.read(x), 2048n)

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case tok <> inp <> out <> more:
      run(tok, inp, out, window.of(more))
    case _:
      IO.die(Unit, 2, "usage: bend-transcript TOKENIZER RESULTS.nul OUTPUT.nul [WINDOW]")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args(xs)
