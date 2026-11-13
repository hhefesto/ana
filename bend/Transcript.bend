import Base
import ./Bytes.bend as B
import ./Tokenizer.bend as Tk
import ./Nul.bend as Ns
import ./Units.bend as U
import ./Sys.bend as S
import ./Mugen/Diff.bend as D
import ./Agent/Spec.bend as A
import ./Spec/Form2.bend as F2
import ./Spec/Kinds.bend as Kd

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
#
# That is format 1. TRANSCRIPT_FORMAT=2 renders format 2 (docs/CORPUS-V2.md,
# C1 and C2; below, "Format 2"): the Term is only ever the original, and a
# term given to the assistant (a mutant, the hole, a term to judge) is an
# `## Attempt`; COPIES (2) transcripts a unit, each a different presentation.
#
# TRANSCRIPT_FORMAT=mugen renders a Bend unit as a session with mugen (below,
# "Format mugen"; docs/MUGEN-SHAPE.md): read, edit and shell calls with
# their echoes as mugen's tools print them. It reads BASE (the first lines
# of `bend base`, from `bend-transcript base RESULTS.nul BASE [BEND]`) and
# writes every presentation's size to SIZES; MUGEN_ONLY=repair writes only
# the repair-M presentations to OUTPUT (a history stream's).

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

# the spaces a line starts with
def lead.spaces(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +h <> t:
      Bool.pick(Nat, U32.is_eq(h, 32), lead.spaces(t, 1n+n), n)

def unindent.go(ls: List<&2, List<&2, U32>>, +k: Nat) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      U.append(List.drop(&2, U32, l, Nat.min(k, lead.spaces(l, 0n))), unindent.go(more, k))

# a body that starts a line (haskell and agda equations, a bend def's body)
# loses its first line's indent on every line: a method's equations in an
# instance, or a bend def's `match` over its cases, keep their layout (tidy
# trims the first line alone, which is right after lean's `:=` only)
def unindent(+xs: List<&2, U32>) -> List<&2, U32>:
  +ys = Bool.pick(List<&2, U32>, head.is(xs, 10), drop.nls.go(xs, True{}), xs)
  U.trim.right(unindent.go(U.lines(ys), lead.spaces(ys, 0n)))

def tidy.term(+lang: List<&2, U32>, +xs: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Bool.or(U.eq(lang, U.b("lean")), U.eq(lang, U.b("nix"))), tidy(xs), unindent(xs))

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
  turn(U.b("Term"), fence(field(fs, 0n), tidy.term(field(fs, 0n), body)))

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

# Format 2 -----------------------------------------------------------------------
#
# Run 1 (format 1) taught ana that its first Term is usually wrong (a mutant
# or a hole, then the error, then the original), that its own answer fails,
# and Nix files from nothing. Format 2 never puts a wrong term under `## Term`:
#
#   0 direct        User, Context, Type, Term (the original), the verdict
#   1 repair (m)    User (the ask, then "This attempt fails. Fix it."),
#                   Context, Type, Attempt (mutant m), its error, Term, the verdict
#   2 term to type  as format 1 (where the checker gave the type: ghc)
#   3 fill          User (the ask, then "Fill the hole."), Context, Type,
#                   Attempt (the hole), the goal, Term, the verdict
#   4 verify        User "Does this check?", Context, Type, Attempt (the
#                   original), the checker's turn: the transcript's end
#   5 verify (m)    the same with mutant m and its error
#
# Each shape opens with its own User line, so after an ask and its Type the
# next turn is always the Term. A unit's first presentation comes from a hash
# of its id: direct 50, repair 25, fill 10, verify 5 (4 or 5, half each), term
# to type 10; Nix (a whole file: nothing to write it from) repair 80, verify
# 20, never direct. One the unit cannot give (no failing mutant, no hole, no
# type) becomes direct (Nix: verify 4). Then up to COPIES - 1 more, the first
# of these the unit can give and has not given (m1, m2: the next mutants; V
# the unit's verify, 4 or 5 m1 by its hash, and W the other, so a verify
# passes half the time): direct, repair m, fill, term to type, repair m1, V,
# W, repair m2 (Nix: repair m, V, repair m1, W, repair m2). They are
# `ID/SHAPE`, then `ID+1/SHAPE`, ...

def attempt(+fs: List<&2, List<&2, U32>>, +body: List<&2, U32>) -> List<&2, U32>:
  turn(U.b("Attempt"), fence(field(fs, 0n), tidy.term(field(fs, 0n), body)))

def ask2(+fs: List<&2, List<&2, U32>>, +shape: Nat) -> List<&2, U32>:
  match shape:
    case 0n:
      ask(fs, 0n)
    case 1n:
      cat([ask(fs, 0n), U.b("\n\nThis attempt fails. Fix it.")])
    case 2n:
      ask(fs, 2n)
    case 3n:
      cat([ask(fs, 0n), U.b("\n\nFill the hole.")])
    case _:
      U.b("Does this check?")

def user2(+fs: List<&2, List<&2, U32>>, +shape: Nat) -> List<&2, U32>:
  turn(U.b("User"), U.append(ask2(fs, shape), nl()))

def mutant(+fs: List<&2, List<&2, U32>>, +m: Nat) -> List<&2, U32>:
  field(fs, Nat.add(15n, Nat.mul(2n, m)))

def mutant.check(+fs: List<&2, List<&2, U32>>, +m: Nat) -> List<&2, U32>:
  field(fs, Nat.add(16n, Nat.mul(2n, m)))

def render2(+shape: Nat, +fs: List<&2, List<&2, U32>>, +m: Nat) -> List<&2, U32>:
  match shape:
    case 0n:
      cat([user2(fs, 0n), context(fs), typ(fs), answer(fs)])
    case 1n:
      cat([user2(fs, 1n), context(fs), typ(fs), attempt(fs, mutant(fs, m)), check.turn(fs, mutant.check(fs, m)), answer(fs)])
    case 2n:
      render(2n, fs, m)
    case 3n:
      cat([user2(fs, 3n), context(fs), typ(fs), attempt(fs, field(fs, 10n)), check.turn(fs, field(fs, 13n)), answer(fs)])
    case 4n:
      cat([user2(fs, 4n), context(fs), typ(fs), attempt(fs, field(fs, 7n)), check.turn(fs, field(fs, 11n))])
    case _:
      cat([user2(fs, 5n), context(fs), typ(fs), attempt(fs, mutant(fs, m)), check.turn(fs, mutant.check(fs, m))])

def shape2.name(+shape: Nat) -> List<&2, U32>:
  U.nth([U.b("direct"), U.b("repair"), U.b("term-to-type"), U.b("fill"), U.b("verify"), U.b("verify")], shape)

# whether the unit can give presentation p
def can(+fs: List<&2, List<&2, U32>>, +p: Plan) -> Bool:
  match p:
    case Plan{+shape, +m}:
      match shape:
        case 0n:
          Bool.not(is.nix(field(fs, 0n)))
        case 1n:
          Nat.is_lt(m, mutant.count(fs))
        case 2n:
          Bool.not(empty(field(fs, 14n)))
        case 3n:
          Bool.not(empty(field(fs, 13n)))
        case 4n:
          True{}
        case _:
          Nat.is_lt(m, mutant.count(fs))

def plan.eq(+a: Plan, +b: Plan) -> Bool:
  match a b:
    case Plan{+s, +m} Plan{+t, +n}:
      Bool.and(Nat.is_eq(s, t), Nat.is_eq(m, n))

def has(+p: Plan, xs: List<&2, Plan>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +x <> more:
      Bool.or(plan.eq(p, x), has(p, more))

# the next mutant after m (m itself when there are none)
def next.m(+m: Nat, +k: Nat, +nm: Nat) -> Nat:
  Nat.mod(Nat.add(m, k), Nat.add(nm, Bool.pick(Nat, Nat.is_eq(nm, 0n), 1n, 0n)))

# the unit's verify (pass: 4; fail: 5 with mutant m1) and the other one
def ver(+id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +other: Bool) -> Plan:
  +nm = mutant.count(fs)
  +pass = Bool.xor(Nat.is_eq(roll(id, 10n, 2n), 0n), other)
  Bool.pick(Plan, pass, Plan{4n, 0n}, Plan{5n, next.m(roll(id, 9n, nm), 1n, nm)})

# the first presentation
def plan2(+id: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> Plan:
  +r = roll(id, 7n, 100n)
  +m = roll(id, 9n, mutant.count(fs))
  +nix = is.nix(field(fs, 0n))
  +ver = ver(id, fs, False{})
  +want = Bool.pick(Plan, nix, Bool.pick(Plan, Nat.is_lt(r, 80n), Plan{1n, m}, ver),
    Bool.pick(Plan, Nat.is_lt(r, 50n), Plan{0n, 0n}, Bool.pick(Plan, Nat.is_lt(r, 75n), Plan{1n, m},
      Bool.pick(Plan, Nat.is_lt(r, 85n), Plan{3n, 0n}, Bool.pick(Plan, Nat.is_lt(r, 90n), ver, Plan{2n, 0n})))))
  Bool.pick(Plan, can(fs, want), want, Bool.pick(Plan, nix, Plan{4n, 0n}, Plan{0n, 0n}))

# the presentations after the first, in the order they are taken
def more2(+id: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> List<&2, Plan>:
  +nm = mutant.count(fs)
  +m = roll(id, 9n, nm)
  +m1 = next.m(m, 1n, nm)
  +m2 = next.m(m, 2n, nm)
  Bool.pick(List<&2, Plan>, is.nix(field(fs, 0n)),
    [Plan{1n, m}, ver(id, fs, False{}), Plan{1n, m1}, ver(id, fs, True{}), Plan{1n, m2}],
    [Plan{0n, 0n}, Plan{1n, m}, Plan{3n, 0n}, Plan{2n, 0n}, Plan{1n, m1}, ver(id, fs, False{}), ver(id, fs, True{}), Plan{1n, m2}])

# up to k presentations of cs, each one the unit can give and none twice
def choose(+fs: List<&2, List<&2, U32>>, cs: List<&2, Plan>, +chosen: List<&2, Plan>, +k: Nat) -> List<&2, Plan>:
  match cs:
    case Nil{}:
      List.reverse(&2, Plan, chosen)
    case +c <> more:
      +take = Bool.and(Nat.is_lt(List.length(&2, Plan, chosen), k), Bool.and(can(fs, c), Bool.not(has(c, chosen))))
      choose(fs, more, Bool.pick(List<&2, Plan>, take, c <> chosen, chosen), k)

def doc2(+b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +shape: Nat, +m: Nat, rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  +text = render2(shape, fs, m)
  emit.if(fits(b, limit, text), Ns.Doc{cat([id, U.b("/"), shape2.name(shape)]), text}, rest)

def docs2(+b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, ps: List<&2, Plan>, +i: Nat, rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match ps:
    case Nil{}:
      rest
    case Plan{+shape, +m} <> more:
      +pid = Bool.pick(List<&2, U32>, Nat.is_eq(i, 0n), id, cat([id, U.b("+"), U.b(Nat.show(i))]))
      doc2(b, limit, pid, fs, shape, m, docs2(b, limit, id, fs, more, 1n+i, rest))

def unit2(+b: Tk.Bpe, +limit: Nat, +k: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  docs2(b, limit, id, fs, choose(fs, plan2(id, fs) <> more2(id, fs), Nil{}, k), 0n, rest)

def all2(+b: Tk.Bpe, +limit: Nat, +k: Nat, rs: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      unit2(b, limit, k, i, split(t, 30), all2(b, limit, k, more))

# Chains (TRANSCRIPT_FORMAT=chain) ---------------------------------------------------
#
# A multi-turn episode as the tool loop writes it (Agent/Loop.bend's plain
# append; Agent/Episode.bend): ana's Term, the checker's rejection, ana's
# next Term, ... the original, the checker's pass.  Every rejected Term is
# one of the unit's kept mutants and its check is the checker's own output,
# so the text is a real episode whose tries happen to be the mutants; the
# reader (Agent/Spec.bend) reads each rejected Term as a try (weight 0), the
# original as the act.  One chain a unit:
#
#   chain-J         User, Context, Type, J tries, Term (the original), the verdict
#   chain-repair-J  format 2's repair prompt (Attempt mutant m, its error), then
#                   J tries, Term, the verdict
#
# J is 1, 2 or 3 (55/30/15 by the unit's hash), at most the mutants left and
# chain.k() - 1 (an episode makes at most K calls); the tries take the
# mutants after m in turn.  A unit with two mutants or more is chain-repair
# 30 times in 100 (Nix: always, it is never asked directly); a unit with no
# mutant to try gives none.

def chain.k() -> Nat:
  4n

def chain.tries(+fs: List<&2, List<&2, U32>>, j: Nat, +m: Nat, +nm: Nat) -> List<&2, U32>:
  match j:
    case 0n:
      Nil{}
    case 1n+p:
      cat([term(fs, mutant(fs, m)), check.turn(fs, mutant.check(fs, m)), chain.tries(fs, p, next.m(m, 1n, nm), nm)])

def chain.text(repair: Bool, +fs: List<&2, List<&2, U32>>, +m: Nat, +j: Nat, +nm: Nat) -> List<&2, U32>:
  match repair:
    case True{}:
      cat([user2(fs, 1n), context(fs), typ(fs), attempt(fs, mutant(fs, m)), check.turn(fs, mutant.check(fs, m)),
        chain.tries(fs, j, next.m(m, 1n, nm), nm), answer(fs)])
    case False{}:
      cat([user2(fs, 0n), context(fs), typ(fs), chain.tries(fs, j, m, nm), answer(fs)])

def chain.doc(some: Bool, +b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +repair: Bool, +m: Nat, +j: Nat, +nm: Nat,
              rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match some:
    case True{}:
      +text = chain.text(repair, fs, m, j, nm)
      +name = cat([U.b(Bool.pick(String, repair, "chain-repair-", "chain-")), U.b(Nat.show(j))])
      emit.if(fits(b, limit, text), Ns.Doc{cat([id, U.b("/"), name]), text}, rest)
    case False{}:
      rest

def chain.unit(+b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  +nm = mutant.count(fs)
  +nix = is.nix(field(fs, 0n))
  +repair = Bool.and(Nat.is_lt(1n, nm), Bool.or(nix, Nat.is_lt(roll(id, 12n, 100n), 30n)))
  +r = roll(id, 11n, 100n)
  +want = Bool.pick(Nat, Nat.is_lt(r, 55n), 1n, Bool.pick(Nat, Nat.is_lt(r, 85n), 2n, 3n))
  +left = Bool.pick(Nat, repair, Nat.sub(nm, 1n), nm)
  +j = Nat.min(want, Nat.min(left, Nat.sub(chain.k(), 1n)))
  chain.doc(Bool.and(Nat.is_lt(0n, j), Bool.or(repair, Bool.not(nix))), b, limit, id, fs, repair, roll(id, 9n, nm), j, nm, rest)

def chain.all(+b: Tk.Bpe, +limit: Nat, rs: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      chain.unit(b, limit, i, split(t, 30), chain.all(b, limit, more))

def all.fmt.k(+fmt: Nat, +b: Tk.Bpe, +limit: Nat, rs: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match fmt:
    case 0n:
      all(b, limit, rs)
    case _:
      all2(b, limit, fmt, rs)

# fmt 0: format 1; chain.fmt(): chains; any other k > 0: format 2 with k
# presentations a unit
def chain.fmt() -> Nat:
  999n

def all.fmt.if(chains: Bool, +fmt: Nat, +b: Tk.Bpe, +limit: Nat, rs: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match chains:
    case True{}:
      chain.all(b, limit, rs)
    case False{}:
      all.fmt.k(fmt, b, limit, rs)

def all.fmt(+fmt: Nat, +b: Tk.Bpe, +limit: Nat, rs: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  all.fmt.if(Nat.is_eq(fmt, chain.fmt()), fmt, b, limit, rs)

# Format mugen (TRANSCRIPT_FORMAT=mugen) --------------------------------------------
#
# A unit as a session with mugen (docs/MUGEN-SHAPE.md): the user's ask, ana's
# tool calls, each answered by its echo exactly as mugen's own tools print it
# (mugen's bend/Tools.bend; its edits' diffs by Mugen/Diff.bend, mugen's
# copy), then ana's reply. The work dir is the unit's tree (BEND_SRC: the
# path in the id), and the file is the unit's file as the checker checked it
# (Check/Bend.bend: the head, the declaration's first part, the variant; the
# tail left out), so every echo is the checker's own output or text cut from
# that file:
#
#   ## user    the ask
#   ## read    PATH FROM LIMIT                        a call
#   ## edit    PATH, then the old lines (`-` each),   a call: whole lines,
#              then the new (`+` each)                old found once
#   ## shell   a command line                         a call
#   ## echo    the call's answer, fenced              the tool's (weight 0)
#   ## mugen   ana's reply to the user
#
# Echoes: a read's lines then `[lines A-B of N]`; an edit's unified diff; a
# shell's output then `(exit N)` (mugen also says how long it ran: `(exit N
# in 0.4 s)`, which no corpus can give). Mugen pages a text past 30,000
# characters and the checker kept 100 lines of output: no unit that fits a
# window comes near either.
#
# Every language (2026-11-03; Bend's first). Shapes:
#
#   direct     the file without the declaration; the ask gives its signature
#              and doc: read the file's last 24 lines, look the names up, add
#              it, check, reply
#   fill       its body is `?goal`: check (the goal and its context), look
#              up, fill, check, reply
#   repair-M   its body is mutant M: check (its error), read the
#              declaration, look up, fix, check, reply
#
# The look-ups are the checker's Context (a name's header: the file's own
# `def NAME(`/`law NAME:` line, else the first line of `bend base NAME` when
# it opens a def, law or type), as two calls: `grep -nE '^(def|law)
# (A|B)[(:]' PATH` for the names the head defines, and `bend base A | head
# -1` (a loop for more) for the others Base defines. Their first lines come
# from BASE (lines NAME TAB LINE: tools/corpus-v2/mugen-base.sh runs `bend
# base` under the corpus's Bend), which must give back every unit's Context.
#
# Another language's unit is the same session with its checker's call (the
# command bend/Check/*.bend runs, on the file: `ghc -fno-code -w PATH`, `agda
# PATH`, `lake env lean PATH`, `nix-instantiate --eval --strict PATH`) and its
# output, the checker's Unit.EXT written as the file's path and this machine's
# run/ directory left out. Its look-ups are one call, `ana-type PATH NAME...`,
# answered by the unit's recorded Context (GHCi's `:type`, Agda's
# Cmd_infer_toplevel, Lean's `#check`; a name it cannot type is left out). An
# Agda hole's check is `ana-goal PATH`, Cmd_goal_type_context's display, since
# `agda` alone does not print it. Nix has no direct shape (a whole file from
# nothing is unanswerable, docs/CORPUS-V2.md C2), no look-ups and no holes.
#
# Every presentation is rendered: OUTPUT gets those that fit the window,
# SIZES (a file, default /dev/null) a line each: ID SHAPE TOKENS F2_TOKENS
# BYTES F2_BYTES, tab-separated, F2 the format 2 presentation of the same
# shape (direct, fill, repair with mutant M) for comparison.

def mg.fmt() -> Nat:
  1000n

# only: MUGEN_ONLY (2026-11-03), "" for every shape, else OUTPUT gets only the
# presentations whose shape starts with it (`repair`: a history stream's
# repairs, whose units' other shapes their own stream already has; `chain`,
# 2026-11-04: renders the chains, which "" does not, and nothing else;
# `night`: renders the units NIGHT holds, from ana's own tries).  night: NIGHT's
# transcripts by unit, each its shape, a NUL and its text.
type Mgc is Data:
  Mgc{base: Map<&2, List<&2, U32>>, sizes: String, only: String, night: Map<&2, List<&2, U32>>}

def Mgc.base(+c: Mgc) -> Map<&2, List<&2, U32>>:
  match c:
    case Mgc{m, s, o, n}:
      m

def Mgc.sizes(+c: Mgc) -> String:
  match c:
    case Mgc{m, s, o, n}:
      s

def Mgc.only(+c: Mgc) -> String:
  match c:
    case Mgc{m, s, o, n}:
      o

def Mgc.night(+c: Mgc) -> Map<&2, List<&2, U32>>:
  match c:
    case Mgc{m, s, o, n}:
      n

def mg.none() -> Mgc:
  Mgc{Map.new(&2, List<&2, U32>), "/dev/null", "", Map.new(&2, List<&2, U32>)}

# bytes as a String of one Chr a byte, and back (Mugen/Diff.bend's lines only
# split at the newline byte, so the diff of the bytes is the diff of the text)
def mg.str(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case h <> t:
      SCon{Chr{h}, mg.str(t)}

def mg.bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      c <> mg.bytes(t)

def mg.n(+k: Nat) -> List<&2, U32>:
  U.b(Nat.show(k))

# xs after its first c (none: empty), and before it (none: all of xs)
def mg.after.go(xs: List<&2, U32>, +c: U32, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> t True{}:
      t
    case h <> +t False{}:
      mg.after.go(t, c, head.is(t, c))
    case _ _:
      Nil{}

def mg.after(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  mg.after.go(xs, c, head.is(xs, c))

def mg.upto.go(xs: List<&2, U32>, +c: U32, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t False{}:
      h <> mg.upto.go(t, c, head.is(t, c))
    case _ _:
      Nil{}

def mg.upto(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  mg.upto.go(xs, c, head.is(xs, c))

# the file's path in its tree: the id after its class, before `#NAME@LINE`
def mg.path(+id: List<&2, U32>) -> List<&2, U32>:
  mg.upto(mg.after(id, 58), 35)

def mg.chomp.r(r: List<&2, U32>) -> List<&2, U32>:
  match r:
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 10), t, h <> t)
    case Nil{}:
      Nil{}

# the last newline gone (mugen's tl.chomp)
def mg.chomp(+xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, mg.chomp.r(List.reverse(&2, U32, xs)))

def mg.join(ls: List<&2, List<&2, U32>>, +sep: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      x
    case x <> +t:
      cat([x, sep, mg.join(t, sep)])

def mg.nls(xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      Nat.add(Bool.pick(Nat, U32.is_eq(h, 10), 1n, 0n), mg.nls(t))

# a file's lines as mugen's read counts them (the text less its last newline,
# split at every newline)
def mg.rows(+f: List<&2, U32>) -> List<&2, List<&2, U32>>:
  split(mg.chomp(f), 10)

def mg.keep.on(keep: Bool, +n: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match keep:
    case True{}:
      n <> rest
    case False{}:
      rest

def mg.words.go(ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      mg.keep.on(Bool.not(empty(w)), w, mg.words.go(t))

def mg.words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  mg.words.go(split(xs, 32))

# Echoes ---------------------------------------------------------------------------

# Machine.read: the lines from `from`, `limit` of them
def mg.read.echo(+f: List<&2, U32>, +from: Nat, +limit: Nat) -> List<&2, U32>:
  +ls = mg.rows(f)
  +rows = List.take(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, ls, Nat.sub(from, 1n)), limit)
  +k = List.length(&2, List<&2, U32>, rows)
  cat([mg.chomp(mg.join(rows, nl())), U.b("\n[lines "), mg.n(from), U.b("-"), mg.n(Nat.sub(Nat.add(from, k), 1n)), U.b(" of "),
    mg.n(List.length(&2, List<&2, U32>, ls)), U.b("]")])

# a shell's answer, less its time
def mg.shell.echo(+out: List<&2, U32>, +code: List<&2, U32>) -> List<&2, U32>:
  +body = mg.chomp(out)
  cat([Bool.pick(List<&2, U32>, empty(body), Nil{}, U.append(body, nl())), U.b("(exit "), code, U.b(")")])

def mg.echo(+text: List<&2, U32>) -> List<&2, U32>:
  turn(U.b("echo"), fence(Nil{}, text))

def mg.shell(+cmd: List<&2, U32>, +echo: List<&2, U32>) -> List<&2, U32>:
  U.append(turn(U.b("shell"), U.append(cmd, nl())), mg.echo(echo))

def mg.read(+path: List<&2, U32>, +f: List<&2, U32>, +from: Nat, +limit: Nat) -> List<&2, U32>:
  U.append(turn(U.b("read"), cat([path, U.b(" "), mg.n(from), U.b(" "), mg.n(limit), nl()])), mg.echo(mg.read.echo(f, from, limit)))

# the checker run on the file, and its answer (c a check: status, 0x1F, output)
def mg.check(+path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  +k = check.of(c)
  mg.shell(cat([U.b("bend "), path, U.b(" --check-only")]), mg.shell.echo(check.out(k), check.status(k)))

# Other languages ------------------------------------------------------------------

def mg.is.bend(+fs: List<&2, List<&2, U32>>) -> Bool:
  U.eq(field(fs, 0n), U.b("bend"))

def mg.is.nix(+fs: List<&2, List<&2, U32>>) -> Bool:
  U.eq(field(fs, 0n), U.b("nix"))

def mg.is.agda(+fs: List<&2, List<&2, U32>>) -> Bool:
  U.eq(field(fs, 0n), U.b("agda"))

def mg.lang.at(+lang: List<&2, U32>, +xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  U.nth(xs, U.lang.code.go(U.lang.names(), lang, 0n))

# xs with every old as new
def mg.swap.go(fuel: Nat, xs: List<&2, U32>, +old: List<&2, U32>, +new: List<&2, U32>, +k: Nat, hit: Bool) -> List<&2, U32>:
  match fuel xs hit:
    case 1n+f h <> t True{}:
      +rest = List.drop(&2, U32, h <> t, k)
      U.append(new, mg.swap.go(f, rest, old, new, k, U.prefix(rest, old)))
    case 1n+f h <> +t False{}:
      h <> mg.swap.go(f, t, old, new, k, U.prefix(t, old))
    case _ xs2 _:
      xs2

def mg.swap(+xs: List<&2, U32>, +old: List<&2, U32>, +new: List<&2, U32>) -> List<&2, U32>:
  mg.swap.go(1n+U.len(xs), xs, old, new, U.len(old), U.prefix(xs, old))

def mg.unit.name(+lang: List<&2, U32>) -> List<&2, U32>:
  mg.lang.at(lang, [U.b("Unit.hs"), U.b("Unit.agda"), U.b("Unit.lean"), U.b("Unit.bend"), U.b("Unit.nix")])

# a checker's output as if it ran on the file here
def mg.out(+lang: List<&2, U32>, +path: List<&2, U32>, +text: List<&2, U32>) -> List<&2, U32>:
  mg.swap(mg.swap(text, mg.unit.name(lang), path), U.b("/home/hhefesto/src/formalTransformer/run/"), Nil{})

def mg.cmd(+lang: List<&2, U32>, +path: List<&2, U32>) -> List<&2, U32>:
  mg.lang.at(lang, [cat([U.b("ghc -fno-code -w "), path]), cat([U.b("agda "), path]), cat([U.b("lake env lean "), path]),
    cat([U.b("bend "), path, U.b(" --check-only")]), cat([U.b("nix-instantiate --eval --strict "), path])])

# a failed variant's recorded status `-` (GHC, Agda: the first error, no exit) is a failure
def mg.status(+s: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U.eq(s, U.b("-")), U.b("1"), s)

def mg.check.other(+lang: List<&2, U32>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  +k = check.of(c)
  mg.shell(mg.cmd(lang, path), mg.shell.echo(mg.out(lang, path, check.out(k)), mg.status(check.status(k))))

def mg.check.on(bend: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  match bend:
    case True{}:
      mg.check(path, c)
    case False{}:
      mg.check.other(field(fs, 0n), path, c)

def mg.check.in(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  mg.check.on(mg.is.bend(fs), fs, path, c)

# a hole's check: Agda's is its goal display, which answers (exit 0)
def mg.check.goal(agda: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  match agda:
    case True{}:
      mg.shell(cat([U.b("ana-goal "), path]), mg.shell.echo(mg.out(field(fs, 0n), path, check.out(check.of(c))), U.b("0")))
    case False{}:
      mg.check.in(fs, path, c)

def mg.check.hole(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  mg.check.goal(mg.is.agda(fs), fs, path, c)

# a name as a shell word
def mg.q.safe(+c: U32) -> Bool:
  Bool.or(U32.is_lt(126, c), Bool.or(Bool.and(U32.is_lt(96, c), U32.is_lt(c, 123)), Bool.or(Bool.and(U32.is_lt(64, c), U32.is_lt(c, 91)),
    Bool.or(Bool.and(U32.is_lt(47, c), U32.is_lt(c, 58)), Bool.or(U32.is_eq(c, 95), Bool.or(U32.is_eq(c, 46), U32.is_eq(c, 45)))))))

def mg.q.all(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.and(mg.q.safe(h), mg.q.all(t))

def mg.q(+n: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, mg.q.all(n), n, Bool.pick(List<&2, U32>, U.has(n, 39), cat([[34], n, [34]]), cat([[39], n, [39]])))

def mg.qs(ns: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      mg.q(n) <> mg.qs(t)

def mg.type.if(some: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  match some:
    case True{}:
      mg.shell(cat([U.b("ana-type "), path, [32], mg.join(mg.qs(mg.words(field(fs, 9n))), [32])]),
        mg.shell.echo(mg.out(field(fs, 0n), path, field(fs, 12n)), U.b("0")))
    case False{}:
      Nil{}

def mg.looks.other(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  mg.type.if(Bool.and(Bool.not(empty(field(fs, 12n))), Bool.not(empty(mg.chomp(field(fs, 9n))))), fs, path)

# Edits ----------------------------------------------------------------------------

def mg.heads.eq(+a: List<&2, List<&2, U32>>, +b: List<&2, List<&2, U32>>) -> Bool:
  match a b:
    case x <> s y <> t:
      U.eq(x, y)
    case _ _:
      False{}

def mg.common.go(a: List<&2, List<&2, U32>>, b: List<&2, List<&2, U32>>, +n: Nat, same: Bool) -> Nat:
  match a b same:
    case x <> +ta y <> +tb True{}:
      mg.common.go(ta, tb, 1n+n, mg.heads.eq(ta, tb))
    case _ _ _:
      n

# how many lines two lists of lines open with in common
def mg.common(+a: List<&2, List<&2, U32>>, +b: List<&2, List<&2, U32>>) -> Nat:
  mg.common.go(a, b, 0n, mg.heads.eq(a, b))

def mg.slice(+ls: List<&2, List<&2, U32>>, +a: Nat, +e: Nat) -> List<&2, List<&2, U32>>:
  List.take(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, ls, a), Nat.sub(e, a))

# whether xs opens with p, and xs given back.  U.prefix took a copy of xs at every
# position and walked p to its end whatever it met: a pass over a 90 KB file with a
# long p was 3e9 steps (gdb: Units.prefix, term_drop).  This stops at the first
# difference and copies nothing.
def mg.rev.onto(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      ys
    case h <> t:
      mg.rev.onto(t, h <> ys)

def mg.pre(p: List<&2, U32>, xs: List<&2, U32>, acc: List<&2, U32>, ok: Bool) -> Bool & List<&2, U32>:
  match p xs ok:
    case _ xs2 False{}:
      (False{}, mg.rev.onto(acc, xs2))
    case Nil{} xs2 True{}:
      (True{}, mg.rev.onto(acc, xs2))
    case +c <> t +a <> s True{}:
      mg.pre(t, s, a <> acc, U32.is_eq(a, c))
    case c <> t Nil{} True{}:
      (False{}, mg.rev.onto(acc, Nil{}))

# how many times old occurs in xs, apart, as mugen's edit splits on it (2: two or more)
type Mcs is Data:
  Mcs{go: Bool, xs: List<&2, U32>, n: Nat}

def mg.count.on(r: Bool & List<&2, U32>, +k: Nat, +n: Nat) -> Mcs:
  (hit, ys) = r
  match hit ys:
    case True{} ys2:
      Mcs{Nat.is_lt(n, 1n), List.drop(&2, U32, ys2, k), 1n+n}
    case False{} y <> t:
      Mcs{True{}, t, n}
    case False{} Nil{}:
      Mcs{False{}, Nil{}, n}

def mg.count.go(fuel: Nat, +old: List<&2, U32>, +k: Nat, st: Mcs) -> Nat:
  match fuel st:
    case 1n+f Mcs{True{}, xs, +n}:
      mg.count.go(f, old, k, mg.count.on(mg.pre(old, xs, Nil{}, True{}), k, n))
    case _ Mcs{g, xs, n}:
      n

def mg.count(+xs: List<&2, U32>, +old: List<&2, U32>) -> Nat:
  mg.count.go(2n+U.len(xs), old, U.len(old), Mcs{True{}, xs, 0n})

# the lines an edit replaces: [p, n0 - s) of the old file, grown (a line up,
# else down) until they are some text that occurs there once
type Rg is Data:
  Rg{p: Nat, s: Nat}

# (32 KB: a text that size is past any window, so the session goes for its size.  Two
# defs alike for hundreds of lines made this a day's work on one unit: every line up,
# mg.count over the file; bendo/proof/percent.bend, col7's render stood still 5 hours.)
def mg.grow.ok(+l0: List<&2, List<&2, U32>>, +f0: List<&2, U32>, +n0: Nat, +p: Nat, +s: Nat) -> Bool:
  +old = U.concat(mg.slice(l0, p, Nat.sub(n0, s)))
  Bool.or(Nat.is_lt(32768n, U.len(old)), Bool.and(Bool.not(empty(old)), Nat.is_eq(mg.count(f0, old), 1n)))

def mg.grow.go(fuel: Nat, ok: Bool, +l0: List<&2, List<&2, U32>>, +f0: List<&2, U32>, +n0: Nat, +p: Nat, +s: Nat) -> Rg:
  match fuel ok:
    case 1n+f False{}:
      +up = Nat.is_lt(0n, p)
      +p2 = Bool.pick(Nat, up, Nat.sub(p, 1n), p)
      +s2 = Bool.pick(Nat, up, s, Nat.sub(s, 1n))
      mg.grow.go(f, mg.grow.ok(l0, f0, n0, p2, s2), l0, f0, n0, p2, s2)
    case _ _:
      Rg{p, s}

def mg.grow(fuel: Nat, +l0: List<&2, List<&2, U32>>, +f0: List<&2, U32>, +n0: Nat, +p: Nat, +s: Nat) -> Rg:
  mg.grow.go(fuel, mg.grow.ok(l0, f0, n0, p, s), l0, f0, n0, p, s)

def mg.end.nl(+l: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U.suffix(l, nl()), l, U.append(l, nl()))

def mg.marked(+sign: U32, ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      cat([[sign], mg.end.nl(l), mg.marked(sign, t)])

def mg.diff(+path: List<&2, U32>, +f0: List<&2, U32>, +f1: List<&2, U32>) -> List<&2, U32>:
  mg.bytes(D.df.diff(mg.str(path), mg.str(f0), mg.str(f1)))

def mg.edit.at(r: Rg, +path: List<&2, U32>, +f0: List<&2, U32>, +f1: List<&2, U32>, +l0: List<&2, List<&2, U32>>, +l1: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match r:
    case Rg{+a, +z}:
      +old = mg.slice(l0, a, Nat.sub(List.length(&2, List<&2, U32>, l0), z))
      +new = mg.slice(l1, a, Nat.sub(List.length(&2, List<&2, U32>, l1), z))
      U.append(turn(U.b("edit"), cat([path, nl(), mg.marked(45, old), mg.marked(43, new)])), mg.echo(mg.diff(path, f0, f1)))

# the edit that makes f1 of f0, and mugen's answer
def mg.edit(+path: List<&2, U32>, +f0: List<&2, U32>, +f1: List<&2, U32>) -> List<&2, U32>:
  +l0 = U.lines(f0)
  +l1 = U.lines(f1)
  +n0 = List.length(&2, List<&2, U32>, l0)
  +n1 = List.length(&2, List<&2, U32>, l1)
  +p = mg.common(l0, l1)
  +s = Nat.min(mg.common(List.reverse(&2, List<&2, U32>, l0), List.reverse(&2, List<&2, U32>, l1)), Nat.min(Nat.sub(n0, p), Nat.sub(n1, p)))
  mg.edit.at(mg.grow(Nat.add(n0, 2n), l0, f0, n0, p, s), path, f0, f1, l0, l1)

# Look-ups -------------------------------------------------------------------------

# `^(def|law) NAME[(:]` (Check/Bend.bend's sig.line)
def mg.sig.line(+name: List<&2, U32>, +l: List<&2, U32>) -> Bool:
  +d = U.append(U.b("def "), name)
  +w = U.append(U.b("law "), name)
  Bool.or(Bool.or(U.prefix(l, U.append(d, [40])), U.prefix(l, U.append(d, [58]))),
    Bool.or(U.prefix(l, U.append(w, [40])), U.prefix(l, U.append(w, [58]))))

def mg.sig.any(ls: List<&2, List<&2, U32>>, +name: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> more:
      Bool.or(mg.sig.line(name, l), mg.sig.any(more, name))

def mg.sig.some(ns: List<&2, List<&2, U32>>, +l: List<&2, U32>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case +n <> more:
      Bool.or(mg.sig.line(n, l), mg.sig.some(more, l))

# the names the head defines (want), or those it does not
def mg.keep(ns: List<&2, List<&2, U32>>, +hls: List<&2, List<&2, U32>>, +want: Bool) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> more:
      mg.keep.on(Bool.not(Bool.xor(mg.sig.any(hls, n), want)), n, mg.keep(more, hls, want))

# grep -n's lines: each line of the file a header of the names opens
def mg.grep.on(hit: Bool, +l: List<&2, U32>, +k: Nat, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match hit:
    case True{}:
      cat([mg.n(k), [58], l]) <> rest
    case False{}:
      rest

def mg.grep.go(ls: List<&2, List<&2, U32>>, +ns: List<&2, List<&2, U32>>, +k: Nat) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      mg.grep.on(mg.sig.some(ns, l), l, k, mg.grep.go(more, ns, 1n+k))

# a name in an extended regex: its dots escaped
def mg.re(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      U.append(Bool.pick(List<&2, U32>, U32.is_eq(h, 46), [92, 46], [h]), mg.re(t))

def mg.res(ns: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case n <> t:
      mg.re(n) <> mg.res(t)

def mg.grep.if(some: Bool, +path: List<&2, U32>, +f0: List<&2, U32>, +ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match some:
    case True{}:
      +hits = mg.grep.go(split(f0, 10), ns, 1n)
      mg.shell(cat([U.b("grep -nE '^(def|law) ("), mg.join(mg.res(ns), [124]), U.b(")[(:]' "), path]),
        mg.shell.echo(mg.join(hits, nl()), Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, hits), 0n), U.b("1"), U.b("0"))))
    case False{}:
      Nil{}

type Bl is Data:
  Bl{name: List<&2, U32>, line: List<&2, U32>}

def Bl.name(+b: Bl) -> List<&2, U32>:
  match b:
    case Bl{n, l}:
      n

def Bl.line(+b: Bl) -> List<&2, U32>:
  match b:
    case Bl{n, l}:
      l

def mg.got(r: Map<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, U32>:
  match r:
    case (m, v):
      v

def mg.based.on(ok: Bool, +n: List<&2, U32>, +l: List<&2, U32>, rest: List<&2, Bl>) -> List<&2, Bl>:
  match ok:
    case True{}:
      Bl{n, l} <> rest
    case False{}:
      rest

# the names Base gives a def, law or type, with its first line
def mg.based(ns: List<&2, List<&2, U32>>, +base: Map<&2, List<&2, U32>>) -> List<&2, Bl>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> more:
      +l = mg.got(Map.get(List<&2, U32>, Nil{}, base, mg.str(n)))
      mg.based.on(Bool.not(empty(l)), n, l, mg.based(more, base))

def mg.bl.names(bs: List<&2, Bl>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      Bl.name(b) <> mg.bl.names(t)

def mg.bl.lines(bs: List<&2, Bl>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      Bl.line(b) <> mg.bl.lines(t)

def mg.base.cmd(+ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, ns), 1n), cat([U.b("bend base "), mg.join(ns, [32]), U.b(" | head -1")]),
    cat([U.b("for n in "), mg.join(ns, [32]), U.b("; do bend base $n | head -1; done")]))

def mg.base.if(some: Bool, +bs: List<&2, Bl>) -> List<&2, U32>:
  match some:
    case True{}:
      mg.shell(mg.base.cmd(mg.bl.names(bs)), mg.shell.echo(mg.join(mg.bl.lines(bs), nl()), U.b("0")))
    case False{}:
      Nil{}

# the Context as calls: grep for the names the head defines, bend base for Base's
def mg.looks.bend(+path: List<&2, U32>, +f0: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  +ns = mg.words(field(fs, 9n))
  +hls = split(field(fs, 5n), 10)
  +inf = mg.keep(ns, hls, True{})
  +bs = mg.based(mg.keep(ns, hls, False{}), base)
  U.append(mg.grep.if(Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, inf), 0n)), path, f0, inf),
    mg.base.if(Bool.not(Nat.is_eq(List.length(&2, Bl, bs), 0n)), bs))

def mg.looks.on(bend: Bool, +path: List<&2, U32>, +f0: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  match bend:
    case True{}:
      mg.looks.bend(path, f0, fs, base)
    case False{}:
      mg.looks.other(fs, path)

def mg.looks(+path: List<&2, U32>, +f0: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  mg.looks.on(mg.is.bend(fs), path, f0, fs, base)

# The asks and replies -------------------------------------------------------------

def mg.user(+text: List<&2, U32>) -> List<&2, U32>:
  turn(U.b("user"), U.append(text, nl()))

def mg.reply(+text: List<&2, U32>) -> List<&2, U32>:
  turn(U.b("mugen"), U.append(text, nl()))

def mg.doc(+fs: List<&2, List<&2, U32>>, +line: List<&2, U32>) -> List<&2, U32>:
  +doc = tidy(field(fs, 3n))
  Bool.pick(List<&2, U32>, empty(doc), line, cat([line, U.b("\n\n"), doc]))

def mg.prop(+fs: List<&2, List<&2, U32>>) -> Bool:
  U.eq(field(fs, 1n), U.b("proposition"))

def mg.ask.direct(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  +name = code(field(fs, 2n))
  +line = Bool.pick(List<&2, U32>, mg.prop(fs), cat([U.b("Prove "), name, U.b(" in "), path, U.b(".")]), cat([U.b("Add "), name, U.b(" to "), path, U.b(".")]))
  cat([mg.doc(fs, line), U.b("\n\n"), mg.chomp(fence(field(fs, 0n), tidy(field(fs, 4n))))])

# how the checker is named in a sentence
def mg.said(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  mg.lang.at(field(fs, 0n), [U.b("ghc"), U.b("agda"), U.b("lean"), U.b("bend check"), U.b("nix")])

def mg.mark(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  mg.lang.at(field(fs, 0n), [U.b("_"), U.b("?"), U.b("_"), U.b("?goal"), U.b("?")])

def mg.ask.fill(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  mg.doc(fs, cat([U.b("Fill the hole ("), code(mg.mark(fs)), U.b(") in "), code(field(fs, 2n)), U.b(" in "), path, U.b(".")]))

def mg.ask.repair(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  mg.doc(fs, cat([code(field(fs, 2n)), U.b(" in "), path, U.b(" fails "), mg.said(fs), U.b(". Fix it.")]))

def mg.find.hit(+ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Bool:
  match ls:
    case l <> t:
      U.prefix(l, p)
    case Nil{}:
      False{}

def mg.find.go(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>, hit: Bool) -> List<&2, U32>:
  match ls hit:
    case l <> more True{}:
      l
    case l <> +more False{}:
      mg.find.go(more, p, mg.find.hit(more, p))
    case _ _:
      Nil{}

# the first line that opens with p (none: empty)
def mg.find(+ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, U32>:
  mg.find.go(ls, p, mg.find.hit(ls, p))

def mg.loc.hit(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case l <> t:
      U.infix(l, U.b(">|"))
    case Nil{}:
      False{}

def mg.loc.go(ls: List<&2, List<&2, U32>>, hit: Bool) -> List<&2, U32>:
  match ls hit:
    case l <> more True{}:
      U.trim.right(U.trim.left(mg.upto(l, 62)))
    case l <> +more False{}:
      mg.loc.go(more, mg.loc.hit(more))
    case _ _:
      Nil{}

# the line the error points at (`263>|`): its number
def mg.loc(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  mg.loc.go(ls, mg.loc.hit(ls))

def mg.val(+l: List<&2, U32>) -> List<&2, U32>:
  U.trim.right(U.trim.left(mg.after(l, 58)))

# what the checker said, from its output: `: bend check said WHAT at line N`
def mg.why(+out: List<&2, U32>) -> List<&2, U32>:
  +ls = split(out, 10)
  +msg = mg.find(ls, U.b("- message"))
  +exp = mg.find(ls, U.b("- expected"))
  +obs = mg.find(ls, U.b("- observed"))
  +loc = mg.loc(ls)
  +seen = Bool.pick(List<&2, U32>, empty(obs), Nil{}, U.append(U.b(", observed "), mg.val(obs)))
  +what = Bool.pick(List<&2, U32>, Bool.not(empty(msg)), mg.val(msg), Bool.pick(List<&2, U32>, Bool.not(empty(exp)), cat([U.b("expected "), mg.val(exp), seen]), Nil{}))
  +at = Bool.pick(List<&2, U32>, empty(loc), Nil{}, U.append(U.b(" at line "), loc))
  Bool.pick(List<&2, U32>, empty(what), Nil{}, cat([U.b(": bend check said "), what, at]))

# what another checker said: the first line naming an error, after its `error...:`,
# and the line after the checker's `Unit.EXT:`
def mg.first.go(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Bool.pick(List<&2, U32>, U.infix(l, U.b("error")), l, mg.first.go(t))

def mg.past(+xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, xs, Nat.add(U.find(xs, p, 0n), U.len(p)))

def mg.digits(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, Bool.and(U32.is_lt(47, h), U32.is_lt(h, 58)), h <> mg.digits(t), Nil{})

def mg.why.other(+fs: List<&2, List<&2, U32>>, +out: List<&2, U32>) -> List<&2, U32>:
  +line = mg.first.go(split(out, 10))
  +what = List.take(&2, U32, U.trim.right(U.trim.left(mg.after(mg.past(line, U.b("error")), 58))), 120n)
  +nums = mg.digits(mg.past(out, U.append(mg.unit.name(field(fs, 0n)), [58])))
  +at = Bool.pick(List<&2, U32>, empty(nums), Nil{}, U.append(U.b(" at line "), nums))
  Bool.pick(List<&2, U32>, empty(what), Nil{}, cat([U.b(": "), mg.said(fs), U.b(" said "), what, at]))

def mg.why.on(bend: Bool, +fs: List<&2, List<&2, U32>>, +out: List<&2, U32>) -> List<&2, U32>:
  match bend:
    case True{}:
      mg.why(out)
    case False{}:
      mg.why.other(fs, out)

def mg.reply.direct(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  +name = code(field(fs, 2n))
  +ok = cat([U.b("; "), mg.said(fs), U.b(" passes.")])
  Bool.pick(List<&2, U32>, mg.prop(fs), cat([U.b("Proved "), name, U.b(" in "), path, ok]),
    cat([U.b("Added "), name, U.b(" to "), path, ok]))

# The sessions ---------------------------------------------------------------------

def mg.head(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  field(fs, 5n)

def mg.with(+fs: List<&2, List<&2, U32>>, +body: List<&2, U32>) -> List<&2, U32>:
  cat([field(fs, 5n), field(fs, 6n), body])

# A chain (2026-11-04; docs/MUGEN-SHAPE.md "Chains"): j wrong edits, the
# mutants from m on, each answered by its recorded check, then the edit that
# makes the original and its pass.  j = 0 is the session's one edit.
def mg.tries(j: Nat, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +f0: List<&2, U32>, +m: Nat, +nm: Nat) -> List<&2, U32>:
  match j:
    case 0n:
      cat([mg.edit(path, f0, mg.with(fs, field(fs, 7n))), mg.check.in(fs, path, field(fs, 11n))])
    case 1n+p:
      +f1 = mg.with(fs, mutant(fs, m))
      cat([mg.edit(path, f0, f1), mg.check.in(fs, path, mutant.check(fs, m)), mg.tries(p, fs, path, f1, next.m(m, 1n, nm), nm)])

# whether each of those edits changes the body before it (a mutant can repeat one)
def mg.tries.ok(j: Nat, +fs: List<&2, List<&2, U32>>, +prev: List<&2, U32>, +m: Nat, +nm: Nat) -> Bool:
  match j:
    case 0n:
      Bool.not(U.eq(prev, field(fs, 7n)))
    case 1n+p:
      +x = mutant(fs, m)
      Bool.and(Bool.not(U.eq(prev, x)), mg.tries.ok(p, fs, x, next.m(m, 1n, nm), nm))

def mg.direct.j(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +j: Nat, +m: Nat, +nm: Nat) -> List<&2, U32>:
  +f0 = mg.head(fs)
  +n = List.length(&2, List<&2, U32>, mg.rows(f0))
  +from = Bool.pick(Nat, Nat.is_lt(n, 25n), 1n, Nat.sub(n, 23n))
  cat([mg.user(mg.ask.direct(fs, path)), mg.read(path, f0, from, Nat.sub(Nat.add(n, 1n), from)), mg.looks(path, f0, fs, base),
    mg.tries(j, fs, path, f0, m, nm), mg.reply(mg.reply.direct(fs, path))])

def mg.direct(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  mg.direct.j(fs, path, base, 0n, 0n, 0n)

def mg.fill.j(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +j: Nat, +m: Nat, +nm: Nat) -> List<&2, U32>:
  +f0 = mg.with(fs, field(fs, 10n))
  cat([mg.user(mg.ask.fill(fs, path)), mg.check.hole(fs, path, field(fs, 13n)), mg.looks(path, f0, fs, base),
    mg.tries(j, fs, path, f0, m, nm),
    mg.reply(cat([U.b("Filled the hole in "), code(field(fs, 2n)), U.b(" ("), path, U.b("); "), mg.said(fs), U.b(" passes.")]))])

def mg.fill(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  mg.fill.j(fs, path, base, 0n, 0n, 0n)

# mutant m handed over, then j wrong edits from the next mutant on
def mg.repair.j(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +m: Nat, +j: Nat, +nm: Nat) -> List<&2, U32>:
  +mut = mutant(fs, m)
  +f0 = mg.with(fs, mut)
  +from = Nat.add(1n, mg.nls(mg.head(fs)))
  +rows = List.length(&2, List<&2, U32>, U.lines(U.append(field(fs, 6n), mut)))
  cat([mg.user(mg.ask.repair(fs, path)), mg.check.in(fs, path, mutant.check(fs, m)), mg.read(path, f0, from, rows), mg.looks(path, f0, fs, base),
    mg.tries(j, fs, path, f0, next.m(m, 1n, nm), nm),
    mg.reply(cat([U.b("Fixed "), code(field(fs, 2n)), U.b(" in "), path, mg.why.on(mg.is.bend(fs), fs, check.out(check.of(mutant.check(fs, m)))), U.b(". It passes now.")]))])

def mg.repair(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +m: Nat) -> List<&2, U32>:
  mg.repair.j(fs, path, base, m, 0n, 1n)

# Presentations, their sizes -------------------------------------------------------

type Mg is Data:
  Mg{doc: Ns.Doc, line: List<&2, U32>, fits: Bool}

def mg.one(+b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +shape: List<&2, U32>, +text: List<&2, U32>, +f2: List<&2, U32>) -> Mg:
  +n = List.length(&2, U32, Tk.Bpe.encode(b, text))
  +n2 = List.length(&2, U32, Tk.Bpe.encode(b, f2))
  +did = cat([id, U.b("/mugen-"), shape])
  Mg{Ns.Doc{did, text}, cat([did, [9], shape, [9], mg.n(n), [9], mg.n(n2), [9], mg.n(U.len(text)), [9], mg.n(U.len(f2)), nl()]),
    Nat.is_le(Nat.add(n, 2n), limit)}

# k presentations repair-M, M from m on
def mg.repairs(k: Nat, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +m: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match k:
    case 0n:
      rest
    case 1n+j:
      mg.one(b, limit, id, U.append(U.b("repair-"), mg.n(m)), mg.repair(fs, path, base, m), render2(1n, fs, m))
        <> mg.repairs(j, b, limit, base, id, fs, path, 1n+m, rest)

def mg.fill.if(some: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match some:
    case True{}:
      mg.one(b, limit, id, U.b("fill"), mg.fill(fs, path, base), render2(3n, fs, 0n)) <> rest
    case False{}:
      rest

def mg.direct.if(some: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match some:
    case True{}:
      mg.one(b, limit, id, U.b("direct"), mg.direct(fs, path, base), render2(0n, fs, 0n)) <> rest
    case False{}:
      rest

def mg.unit(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  +path = mg.path(id)
  mg.direct.if(Bool.not(mg.is.nix(fs)), b, limit, base, id, fs, path,
    mg.fill.if(Bool.not(empty(field(fs, 13n))), b, limit, base, id, fs, path, mg.repairs(mutant.count(fs), b, limit, base, id, fs, path, 0n, rest)))

# Another language's file past 64 KB gives no session: mugen's edit and diff run over
# the whole file (one Alex table of GHC's, 448 KB, stopped a render for half an hour
# with 49 MB written; 43 of the 104,484 Haskell, Agda and Lean train units).  Bend's
# stay as they were rendered.
def mg.small(+fs: List<&2, List<&2, U32>>) -> Bool:
  Bool.or(mg.is.bend(fs), Nat.is_lt(Nat.add(U.len(field(fs, 5n)), Nat.add(U.len(field(fs, 6n)), U.len(field(fs, 7n)))), 65536n))

def mg.unit.if(ok: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match ok:
    case True{}:
      mg.unit(b, limit, base, id, fs, rest)
    case False{}:
      rest

# One chain a unit, as format chain chooses (chain.unit): J wrong edits by the
# unit's hash, 30 in 100 units with two mutants or more from a repair (Nix:
# always, it is never asked directly), the rest from a fill (half of those
# with a hole) or the direct ask.  Rendered only under MUGEN_ONLY=chain, so a
# stream's own render keeps its bytes and the chains are a stream of their own.
def mg.one.keep(ok: Bool, +b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +shape: List<&2, U32>, +text: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match ok:
    case True{}:
      mg.one(b, limit, id, shape, text, Nil{}) <> rest
    case False{}:
      rest

def mg.one.if(ok: Bool, +b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +shape: String, +j: Nat, +text: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  mg.one.keep(ok, b, limit, id, U.append(U.b(shape), mg.n(j)), text, rest)

def mg.chain.at(repair: Bool, hole: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +j: Nat, +m: Nat, +nm: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match repair hole:
    case True{} _:
      mg.one.if(mg.tries.ok(j, fs, mutant(fs, m), next.m(m, 1n, nm), nm), b, limit, id, "chain-repair-", j, mg.repair.j(fs, path, base, m, j, nm), rest)
    case False{} True{}:
      mg.one.if(mg.tries.ok(j, fs, field(fs, 10n), m, nm), b, limit, id, "chain-fill-", j, mg.fill.j(fs, path, base, j, m, nm), rest)
    case False{} False{}:
      mg.one.if(mg.tries.ok(j, fs, Nil{}, m, nm), b, limit, id, "chain-", j, mg.direct.j(fs, path, base, j, m, nm), rest)

def mg.chain.if(some: Bool, +repair: Bool, +hole: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +j: Nat, +nm: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match some:
    case True{}:
      mg.chain.at(repair, hole, b, limit, base, id, fs, mg.path(id), j, roll(id, 9n, nm), nm, rest)
    case False{}:
      rest

def mg.chain.unit(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  +nm = mutant.count(fs)
  +nix = mg.is.nix(fs)
  +repair = Bool.and(Nat.is_lt(1n, nm), Bool.or(nix, Nat.is_lt(roll(id, 12n, 100n), 30n)))
  +r = roll(id, 11n, 100n)
  +want = Bool.pick(Nat, Nat.is_lt(r, 55n), 1n, Bool.pick(Nat, Nat.is_lt(r, 85n), 2n, 3n))
  +left = Bool.pick(Nat, repair, Nat.sub(nm, 1n), nm)
  +j = Nat.min(want, Nat.min(left, Nat.sub(chain.k(), 1n)))
  +hole = Bool.and(Bool.not(empty(field(fs, 13n))), Nat.is_lt(roll(id, 14n, 100n), 50n))
  mg.chain.if(Bool.and(Nat.is_lt(0n, j), Bool.or(repair, Bool.not(nix))), repair, hole, b, limit, base, id, fs, j, nm, rest)

def mg.chain.unit.if(ok: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match ok:
    case True{}:
      mg.chain.unit(b, limit, base, id, fs, rest)
    case False{}:
      rest

def mg.all.chain(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      +fs = split(t, 30)
      mg.chain.unit.if(mg.small(fs), b, limit, base, i, fs, mg.all.chain(b, limit, base, more))

def mg.all(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      +fs = split(t, 30)
      mg.unit.if(mg.small(fs), b, limit, base, i, fs, mg.all(b, limit, base, more))

# Fixes (2026-11-12; docs/MUGEN-SHAPE.md "Fixes") -------------------------------------
#
# What run 5's checkpoints did wrong on the 176 tasks, and R5d's sessions never
# showed (its first 583,180: 45 with a refused edit, 2 that did not end in a pass,
# 97% with one edit): at 120k, of 124 failed tasks 58 ended in a false "passes",
# 45 sent the same call again, 33 had an edit that did not apply.  The user
# (11-12): "add sessions where an edit fails and is retried; add sessions where
# the check fails more than once before it's fixed; add sessions that end with
# an honest 'couldn't do it, here's the error'".  MUGEN_ONLY=fix renders, a unit,
# with no checker run (each check is a recorded one):
#
#   mugen-fix-miss-SHAPE      (direct, fill, repair-M) the fix sent first with its
#                             first line that is not blank as ana might
#                             misremember it, refused; a read of those lines;
#                             the fix, its pass
#   mugen-fix-stale[-S]-J     (S fill or repair) J wrong edits, then the fix sent
#                             first as though the last of them had not been made
#                             (the old text is the one before it), refused; a
#                             read of the declaration; the fix, its pass
#   mugen-fix-giveup[-fill]-J J wrong edits and no fix: an edit that puts the
#                             file back as it was, and a reply that says so and
#                             the last check's error
#
# Every wrong or refused edit has a later edit, so the reader takes it as a try
# (weight 0); the give-up's last edit is the one that puts the file back, so no
# wrong program is trained, nor the mutant a repair hands over (a give-up starts
# from the direct ask or the fill only).

type Mx is Data:
  Mx{ok: Bool, text: List<&2, U32>}

def mx.pre(+t: List<&2, U32>, r: Mx) -> Mx:
  match r:
    case Mx{ok, u}:
      Mx{ok, U.append(t, u)}

def mx.post(r: Mx, +t: List<&2, U32>) -> Mx:
  match r:
    case Mx{ok, u}:
      Mx{ok, U.append(u, t)}

def mx.and(+ok: Bool, r: Mx) -> Mx:
  match r:
    case Mx{o, u}:
      Mx{Bool.and(ok, o), u}

# mugen's refusal of an edit whose old text is not in the file (Tools.bend
# tl.edit.apply; AgentMugen's am.edit.why)
def mg.refused(+path: List<&2, U32>) -> List<&2, U32>:
  cat([U.b("Edit 1 ("), path, U.b("): old was not found. No file was changed.")])

def mg.edit.turn(+path: List<&2, U32>, +old: List<&2, List<&2, U32>>, +new: List<&2, List<&2, U32>>) -> List<&2, U32>:
  turn(U.b("edit"), cat([path, nl(), mg.marked(45, old), mg.marked(43, new)]))

# the lines mg.edit would replace to make l1 of f0 (its lines l0)
def mg.rg(+f0: List<&2, U32>, +l0: List<&2, List<&2, U32>>, +l1: List<&2, List<&2, U32>>) -> Rg:
  +n0 = List.length(&2, List<&2, U32>, l0)
  +n1 = List.length(&2, List<&2, U32>, l1)
  +p = mg.common(l0, l1)
  +s = Nat.min(mg.common(List.reverse(&2, List<&2, U32>, l0), List.reverse(&2, List<&2, U32>, l1)), Nat.min(Nat.sub(n0, p), Nat.sub(n1, p)))
  mg.grow(Nat.add(n0, 2n), l0, f0, n0, p, s)

# the index of the first line of ls that is not blank (none: past the last)
def mg.nb(ls: List<&2, List<&2, U32>>, +i: Nat) -> Nat:
  match ls:
    case Nil{}:
      i
    case +l <> t:
      Bool.pick(Nat, U.blank(l), mg.nb(t, 1n+i), i)

def mg.set.at(ls: List<&2, List<&2, U32>>, i: Nat, +x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls i:
    case Nil{} _:
      Nil{}
    case l <> t 0n:
      x <> t
    case l <> t 1n+j:
      l <> mg.set.at(t, j, x)

# a line as ana might misremember it: one character short in its middle (k odd,
# a line of 4 characters or more), else two spaces more indent
def mg.typo(+l: List<&2, U32>, +k: Nat) -> List<&2, U32>:
  +n = U.len(mg.chomp(l))
  +h = Nat.div(n, 2n)
  +cut = Bool.and(Nat.is_eq(Nat.mod(k, 2n), 1n), Nat.is_lt(3n, n))
  Bool.pick(List<&2, U32>, cut, U.append(List.take(&2, U32, l, h), List.drop(&2, U32, l, 1n+h)), U.append(U.b("  "), l))

# a refused edit: its text (the call and mugen's refusal), the index of its
# first old line in the file, how many old lines; ok when its old text is
# nowhere in the file
type Mm is Data:
  Mm{ok: Bool, text: List<&2, U32>, at: Nat, rows: Nat}

# the edit that makes l1 of f0, with its first old line that is not blank as
# mg.typo writes it (and its first new line, when that is the same line)
def mg.miss.typo(r: Rg, +k: Nat, +path: List<&2, U32>, +f0: List<&2, U32>, +l0: List<&2, List<&2, U32>>, +l1: List<&2, List<&2, U32>>) -> Mm:
  match r:
    case Rg{+a, +z}:
      +old = mg.slice(l0, a, Nat.sub(List.length(&2, List<&2, U32>, l0), z))
      +new = mg.slice(l1, a, Nat.sub(List.length(&2, List<&2, U32>, l1), z))
      +i = mg.nb(old, 0n)
      +o = U.nth(old, i)
      +bad = mg.typo(o, k)
      +old2 = mg.set.at(old, i, bad)
      +new2 = Bool.pick(List<&2, List<&2, U32>>, U.eq(U.nth(new, i), o), mg.set.at(new, i, bad), new)
      +ok = Bool.and(Nat.is_lt(i, List.length(&2, List<&2, U32>, old)), Nat.is_eq(mg.count(f0, U.concat(old2)), 0n))
      Mm{ok, U.append(mg.edit.turn(path, old2, new2), mg.echo(mg.refused(path))), a, List.length(&2, List<&2, U32>, old)}

# the edit that makes l1 of the file before ana's last edit (lb, fb), sent to
# the file as that edit left it (f0): refused when its old text is not there
def mg.miss.stale(r: Rg, +path: List<&2, U32>, +f0: List<&2, U32>, +lb: List<&2, List<&2, U32>>, +l1: List<&2, List<&2, U32>>) -> Mm:
  match r:
    case Rg{+a, +z}:
      +old = mg.slice(lb, a, Nat.sub(List.length(&2, List<&2, U32>, lb), z))
      +new = mg.slice(l1, a, Nat.sub(List.length(&2, List<&2, U32>, l1), z))
      +ok = Bool.and(Bool.not(empty(U.concat(old))), Nat.is_eq(mg.count(f0, U.concat(old)), 0n))
      Mm{ok, U.append(mg.edit.turn(path, old, new), mg.echo(mg.refused(path))), a, List.length(&2, List<&2, U32>, old)}

# after a typo's refusal: a read of the old lines, two more each side
def mg.missed.typo(m: Mm, +path: List<&2, U32>, +f0: List<&2, U32>, +fix: List<&2, U32>) -> Mx:
  match m:
    case Mm{ok, t, +a, n}:
      +from = Bool.pick(Nat, Nat.is_lt(a, 2n), 1n, Nat.sub(a, 1n))
      Mx{ok, cat([t, mg.read(path, f0, from, Nat.add(n, 4n)), fix])}

# after a stale edit's refusal: a read of the declaration as it is now
def mg.missed.stale(m: Mm, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +f0: List<&2, U32>, +fix: List<&2, U32>) -> Mx:
  match m:
    case Mm{ok, t, a, n}:
      +h = mg.nls(mg.head(fs))
      Mx{ok, cat([t, mg.read(path, f0, 1n+h, Nat.sub(List.length(&2, List<&2, U32>, mg.rows(f0)), h)), fix])}

# the end of a session as x has it, f0 the file now, fb the file before ana's
# last edit, s0 the file the session started from: 0 the fix and its check; 1
# the fix first with a typo; 2 the fix first as an edit of fb; 3 no fix, the
# file put back as s0
def mg.fix.edit(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +f0: List<&2, U32>) -> List<&2, U32>:
  cat([mg.edit(path, f0, mg.with(fs, field(fs, 7n))), mg.check.in(fs, path, field(fs, 11n))])

def mg.fix.last(x: Nat, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +s0: List<&2, U32>, +fb: List<&2, U32>, +f0: List<&2, U32>, +k: Nat) -> Mx:
  match x:
    case 0n:
      Mx{True{}, mg.fix.edit(fs, path, f0)}
    case 1n:
      +l0 = U.lines(f0)
      +l1 = U.lines(mg.with(fs, field(fs, 7n)))
      mg.missed.typo(mg.miss.typo(mg.rg(f0, l0, l1), k, path, f0, l0, l1), path, f0, mg.fix.edit(fs, path, f0))
    case 2n:
      +lb = U.lines(fb)
      +l1 = U.lines(mg.with(fs, field(fs, 7n)))
      mg.missed.stale(mg.miss.stale(mg.rg(fb, lb, l1), path, f0, lb, l1), fs, path, f0, mg.fix.edit(fs, path, f0))
    case _:
      Mx{Bool.not(U.eq(f0, s0)), mg.edit(path, f0, s0)}

# j wrong edits (the mutants from m on, each with its recorded check), then
# the end x gives
def mg.tries.x(x: Nat, j: Nat, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +s0: List<&2, U32>, +fb: List<&2, U32>, +f0: List<&2, U32>, +m: Nat, +nm: Nat, +k: Nat) -> Mx:
  match j:
    case 0n:
      mg.fix.last(x, fs, path, s0, fb, f0, k)
    case 1n+p:
      +f1 = mg.with(fs, mutant(fs, m))
      mx.pre(cat([mg.edit(path, f0, f1), mg.check.in(fs, path, mutant.check(fs, m))]), mg.tries.x(x, p, fs, path, s0, f0, f1, next.m(m, 1n, nm), nm, k))

# a give-up's reply: the tries it made, the last check's error, the file back
def mg.reply.giveup(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +j: Nat, +c: List<&2, U32>) -> List<&2, U32>:
  cat([U.b("I could not get "), code(field(fs, 2n)), U.b(" in "), path, U.b(" to pass in "), mg.n(j), U.b(" tries"),
    mg.why.on(mg.is.bend(fs), fs, check.out(check.of(c))), U.b(". I put "), path, U.b(" back as it was.")])

# the reply: the shape's own, or a give-up's (the last try's mutant, l)
def mg.reply.x(+x: Nat, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +j: Nat, +l: Nat, +done: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(x, 3n), mg.reply.giveup(fs, path, j, mutant.check(fs, l)), done)

# the mutant the last of j tries from m edits in
def mg.last.m(+m: Nat, +j: Nat, +nm: Nat) -> Nat:
  next.m(m, Nat.sub(j, 1n), nm)

def mg.direct.x(+x: Nat, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +j: Nat, +m: Nat, +nm: Nat, +k: Nat) -> Mx:
  +f0 = mg.head(fs)
  +n = List.length(&2, List<&2, U32>, mg.rows(f0))
  +from = Bool.pick(Nat, Nat.is_lt(n, 25n), 1n, Nat.sub(n, 23n))
  +r = mg.tries.x(x, j, fs, path, f0, f0, f0, m, nm, k)
  mx.and(mg.tries.ok(j, fs, Nil{}, m, nm),
    mx.post(mx.pre(cat([mg.user(mg.ask.direct(fs, path)), mg.read(path, f0, from, Nat.sub(Nat.add(n, 1n), from)), mg.looks(path, f0, fs, base)]), r),
      mg.reply(mg.reply.x(x, fs, path, j, mg.last.m(m, j, nm), mg.reply.direct(fs, path)))))

def mg.fill.x(+x: Nat, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +j: Nat, +m: Nat, +nm: Nat, +k: Nat) -> Mx:
  +f0 = mg.with(fs, field(fs, 10n))
  +r = mg.tries.x(x, j, fs, path, f0, f0, f0, m, nm, k)
  +done = cat([U.b("Filled the hole in "), code(field(fs, 2n)), U.b(" ("), path, U.b("); "), mg.said(fs), U.b(" passes.")])
  mx.and(mg.tries.ok(j, fs, field(fs, 10n), m, nm),
    mx.post(mx.pre(cat([mg.user(mg.ask.fill(fs, path)), mg.check.hole(fs, path, field(fs, 13n)), mg.looks(path, f0, fs, base)]), r),
      mg.reply(mg.reply.x(x, fs, path, j, mg.last.m(m, j, nm), done))))

# mutant m handed over, then j wrong edits from the next mutant on (no give-up)
def mg.repair.x(+x: Nat, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +m: Nat, +j: Nat, +nm: Nat, +k: Nat) -> Mx:
  +mut = mutant(fs, m)
  +f0 = mg.with(fs, mut)
  +from = Nat.add(1n, mg.nls(mg.head(fs)))
  +rows = List.length(&2, List<&2, U32>, U.lines(U.append(field(fs, 6n), mut)))
  +r = mg.tries.x(x, j, fs, path, f0, f0, f0, next.m(m, 1n, nm), nm, k)
  +done = cat([U.b("Fixed "), code(field(fs, 2n)), U.b(" in "), path, mg.why.on(mg.is.bend(fs), fs, check.out(check.of(mutant.check(fs, m)))), U.b(". It passes now.")])
  mx.and(Bool.and(Nat.is_lt(x, 3n), mg.tries.ok(j, fs, mut, next.m(m, 1n, nm), nm)),
    mx.post(mx.pre(cat([mg.user(mg.ask.repair(fs, path)), mg.check.in(fs, path, mutant.check(fs, m)), mg.read(path, f0, from, rows), mg.looks(path, f0, fs, base)]), r),
      mg.reply(done)))

# a start the unit has: s (0 direct, 1 fill, 2 repair) when it has it, else the
# first of them it has (3: none)
def mg.start(+s: Nat, +d: Bool, +f: Bool, +r: Bool) -> Nat:
  +first = Bool.pick(Nat, d, 0n, Bool.pick(Nat, f, 1n, Bool.pick(Nat, r, 2n, 3n)))
  Bool.pick(Nat, Bool.or(Bool.and(Nat.is_eq(s, 0n), d), Bool.or(Bool.and(Nat.is_eq(s, 1n), f), Bool.and(Nat.is_eq(s, 2n), r))), s, first)

def mg.fix.keep(r: Mx, +b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +shape: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match r:
    case Mx{ok, t}:
      mg.one.keep(ok, b, limit, id, shape, t, rest)

# `-J` after a shape's name (a miss has no tries: none)
def mg.fix.jn(+x: Nat, +j: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(x, 1n), Nil{}, U.append(U.b("-"), mg.n(j)))

# a session of x from start s, its shape fix-NAME-...
def mg.fix.at(s: Nat, +x: Nat, +name: String, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +j: Nat, +m: Nat, +nm: Nat, +k: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match s:
    case 0n:
      mg.fix.keep(mg.direct.x(x, fs, mg.path(id), base, j, m, nm, k), b, limit, id, cat([U.b("fix-"), U.b(name), Bool.pick(List<&2, U32>, Nat.is_eq(x, 1n), U.b("-direct"), mg.fix.jn(x, j))]), rest)
    case 1n:
      mg.fix.keep(mg.fill.x(x, fs, mg.path(id), base, j, m, nm, k), b, limit, id, cat([U.b("fix-"), U.b(name), U.b("-fill"), mg.fix.jn(x, j)]), rest)
    case 2n:
      mg.fix.keep(mg.repair.x(x, fs, mg.path(id), base, m, j, nm, k), b, limit, id, cat([U.b("fix-"), U.b(name), U.b("-repair"), Bool.pick(List<&2, U32>, Nat.is_eq(x, 1n), U.append(U.b("-"), mg.n(m)), mg.fix.jn(x, j))]), rest)
    case _:
      rest

# a unit's fixes, each where the unit has what it needs, the choices by its
# hash: a miss (direct, fill or repair, a third each), a stale fix after 1, 2
# or 3 tries (30/40/30; from a fill or a repair, or from the direct ask after 2
# or more), and for half the units with two mutants or more a give-up after 2
# or 3 (from the direct ask or the fill).  Nix is never asked directly and has
# no hole: its repairs only.
def mg.fix.unit(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  +nm = mutant.count(fs)
  +d = Bool.not(mg.is.nix(fs))
  +f = Bool.and(d, Bool.not(empty(field(fs, 13n))))
  +m = roll(id, 9n, nm)
  +k = roll(id, 21n, 2n)
  # the miss
  +ms = mg.start(roll(id, 15n, 3n), d, f, Nat.is_lt(0n, nm))
  # the stale fix: J tries, as many mutants as there are (a repair hands one over)
  +r = roll(id, 17n, 100n)
  +want = Bool.pick(Nat, Nat.is_lt(r, 30n), 1n, Bool.pick(Nat, Nat.is_lt(r, 70n), 2n, 3n))
  +ss = mg.start(roll(id, 16n, 3n), Bool.and(d, Nat.is_lt(1n, nm)), f, Nat.is_lt(1n, nm))
  +left = Bool.pick(Nat, Nat.is_eq(ss, 2n), Nat.sub(nm, 1n), nm)
  +js = Nat.min(Nat.min(left, Nat.sub(chain.k(), 1n)), Bool.pick(Nat, Nat.is_eq(ss, 0n), Nat.max(want, 2n), want))
  # the give-up
  +gj = Nat.min(nm, Bool.pick(Nat, Nat.is_eq(roll(id, 19n, 2n), 0n), 2n, 3n))
  +give = Bool.and(Bool.and(Nat.is_lt(1n, nm), Nat.is_lt(roll(id, 18n, 100n), 50n)), Bool.or(d, f))
  +gs = Bool.pick(Nat, give, mg.start(roll(id, 20n, 2n), d, f, False{}), 3n)
  mg.fix.at(ms, 1n, "miss", b, limit, base, id, fs, 0n, m, nm, k,
    mg.fix.at(Bool.pick(Nat, Nat.is_lt(0n, js), ss, 3n), 2n, "stale", b, limit, base, id, fs, js, m, nm, k,
      mg.fix.at(gs, 3n, "giveup", b, limit, base, id, fs, gj, m, nm, k, rest)))

def mg.fix.unit.if(ok: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match ok:
    case True{}:
      mg.fix.unit(b, limit, base, id, fs, rest)
    case False{}:
      rest

# (a unit past 512 KB gives no fixes: col9's lexbend Pipeline.bend#ReportEvidence.report_correct
# is 45 MB, and its three sessions, each with copies of the file, went past 3 GB; 11-12)
def mg.all.fix(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      +fs = split(t, 30)
      mg.fix.unit.if(Bool.and(mg.small(fs), Nat.is_lt(U.len(t), 524288n)), b, limit, base, i, fs, mg.all.fix(b, limit, base, more))

# Ana's own mistakes in the shape (2026-11-04; docs/MUGEN-SHAPE.md "Chains"):
# the nights' transcripts (run/v5/act5, format 2: her Terms, each with the check
# it got, the last the pass) as a direct session on the file, each Term an edit
# of the one before.  A repeat of the Term before it is left out (mugen refuses
# an edit that changes nothing; she made 3 of the same in many).  Her Term is
# tidy.term's, so its lines go back under the def's indent; the checks are as
# they were recorded, no checker run.
type Nt is Data:
  Nt{body: List<&2, U32>, check: List<&2, U32>}

def nt.fence.drop(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> +t:
      Bool.pick(List<&2, List<&2, U32>>, U.eq(l, U.b("```\n")), t, nt.fence.drop(t))

# a turn's fenced lines: after its heading, empty line and opening fence, up
# to its last fence
def nt.inner(+x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  List.reverse(&2, List<&2, U32>, nt.fence.drop(List.reverse(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, A.ag.lines(10, x), 3n))))

def nt.indent(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      U.append(Bool.pick(List<&2, U32>, U.eq(l, nl()), l, U.append(U.b("  "), l)), nt.indent(t))

def nt.is.exit(+l: List<&2, U32>) -> Bool:
  U.prefix(l, U.b("[exit "))

# a checker's turn, back to a check: the status of its last line, and the rest
def nt.check.of(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +rs = List.reverse(&2, List<&2, U32>, ls)
  +last = Maybe.default(&2, List<&2, U32>, List.head(&2, List<&2, U32>, rs), Nil{})
  +has = nt.is.exit(last)
  +status = Bool.pick(List<&2, U32>, has, List.take(&2, U32, List.drop(&2, U32, last, 6n), Nat.sub(U.len(last), 8n)), U.b("1"))
  +rest = Bool.pick(List<&2, List<&2, U32>>, has, List.reverse(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, rs, 1n)), ls)
  cat([status, [31], U.concat(rest)])

def nt.term.at(bs: List<&2, A.Blk>) -> Bool:
  match bs:
    case A.Blk{+c, +x} <> t:
      Bool.and(Nat.is_eq(c, 4n), U.prefix(x, U.b("## Term\n")))
    case _:
      False{}

def nt.go(bs: List<&2, A.Blk>, hit: Bool) -> List<&2, Nt>:
  match bs hit:
    case Nil{} _:
      Nil{}
    case A.Blk{c, +x} <> A.Blk{d, +y} <> +r True{}:
      Nt{nt.indent(nt.inner(x)), nt.check.of(nt.inner(y))} <> nt.go(r, nt.term.at(r))
    case A.Blk{c, x} <> +t _:
      nt.go(t, nt.term.at(t))

# a transcript's Terms and their checks
def nt.of(+bs: List<&2, A.Blk>) -> List<&2, Nt>:
  nt.go(bs, nt.term.at(bs))

def nt.uniq(ns: List<&2, Nt>, +prev: List<&2, U32>) -> List<&2, Nt>:
  match ns:
    case Nil{}:
      Nil{}
    case Nt{+b, +c} <> +t:
      +same = U.eq(b, prev)
      +r = nt.uniq(t, Bool.pick(List<&2, U32>, same, prev, b))
      Bool.pick(List<&2, Nt>, same, r, Nt{b, c} <> r)

def nt.edits(ns: List<&2, Nt>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +f0: List<&2, U32>) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case Nt{+b, +c} <> t:
      +f1 = mg.with(fs, b)
      cat([mg.edit(path, f0, f1), mg.check.in(fs, path, c), nt.edits(t, fs, path, f1)])

def nt.last.passed(ns: List<&2, Nt>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case Nt{b, c} <> Nil{}:
      U.eq(check.status(check.of(c)), U.b("0"))
    case Nt{b, c} <> t:
      nt.last.passed(t)

def nt.session(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +ns: List<&2, Nt>) -> List<&2, U32>:
  +f0 = mg.head(fs)
  +n = List.length(&2, List<&2, U32>, mg.rows(f0))
  +from = Bool.pick(Nat, Nat.is_lt(n, 25n), 1n, Nat.sub(n, 23n))
  cat([mg.user(mg.ask.direct(fs, path)), mg.read(path, f0, from, Nat.sub(Nat.add(n, 1n), from)), mg.looks(path, f0, fs, base),
    nt.edits(ns, fs, path, f0), mg.reply(mg.reply.direct(fs, path))])

# a unit's night transcript, its shape up to the last `-`: mugen-night-fixed-J,
# mugen-night-episode-J, J her wrong edits
def nt.shape(+sh: List<&2, U32>, +j: Nat) -> List<&2, U32>:
  cat([U.b("night-"), List.take(&2, U32, sh, U.find(sh, [45], 0n)), [45], mg.n(j)])

# Her last Term passed the check, which is not to say it was right (11-12):
# own:hs2bend/00289/Problem033.bend#gcdLoop's was `gcdLoop(f, a, b)`, a loop
# that never looks at b, and it never used the Nat.mod it looked up.  So her
# last Term stands only when it is the unit's original, spaces aside; else the
# original takes its place after her wrong Terms, and a night with no wrong
# Term before it gives nothing (it would be the direct session again).
def nt.ws(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 32), Bool.or(U32.is_eq(c, 10), Bool.or(U32.is_eq(c, 9), U32.is_eq(c, 13))))

# the bytes less spaces, tabs and newlines
def nt.sq(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      +r = nt.sq(t)
      Bool.pick(List<&2, U32>, nt.ws(h), r, h <> r)

type Nr is Data:
  Nr{ns: List<&2, Nt>, swapped: Bool}

def nr.cons(+n: Nt, r: Nr) -> Nr:
  match r:
    case Nr{ns, s}:
      Nr{n <> ns, s}

# her Terms with the last the original's (o, its check oc) unless it is the original
def nt.right(ns: List<&2, Nt>, +o: List<&2, U32>, +oc: List<&2, U32>) -> Nr:
  match ns:
    case Nil{}:
      Nr{Nil{}, False{}}
    case Nt{+b, +c} <> Nil{}:
      +same = U.eq(nt.sq(b), nt.sq(o))
      Nr{Bool.pick(Nt, same, Nt{b, c}, Nt{o, oc}) <> Nil{}, Bool.not(same)}
    case Nt{b, c} <> t:
      nr.cons(Nt{b, c}, nt.right(t, o, oc))

def nt.unit.r(r: Nr, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +sh: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match r:
    case Nr{+ns, +sw}:
      +j = Nat.sub(List.length(&2, Nt, ns), 1n)
      +ok = Bool.and(nt.last.passed(ns), Bool.not(Bool.and(sw, Nat.is_eq(j, 0n))))
      mg.one.keep(ok, b, limit, id, nt.shape(sh, j), nt.session(fs, mg.path(id), base, ns), rest)

def nt.unit.on(some: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +v: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match some:
    case True{}:
      +k = U.find(v, [0], 0n)
      +ns = nt.uniq(nt.of(A.ag.blocks(10, A.ag.hds.bytes(), List.drop(&2, U32, v, 1n+k))), Nil{})
      nt.unit.r(nt.right(ns, field(fs, 7n), field(fs, 11n)), b, limit, base, id, fs, List.take(&2, U32, v, k), rest)
    case False{}:
      rest

def mg.all.night(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +night: Map<&2, List<&2, U32>>, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      +v = mg.got(Map.get(List<&2, U32>, Nil{}, night, mg.str(i)))
      nt.unit.on(Bool.not(empty(v)), b, limit, base, i, split(t, 30), v, mg.all.night(b, limit, base, night, more))

# Form 2 (2026-11-12; docs/form2/README.md) -------------------------------------------
#
# The user, 11-12: "I do want ana to learn to do mugen dynamics, but I also want
# it to do it in the easiest way for ana to learn".  MUGEN_ONLY=form2 renders a
# unit's direct, fill and repair-M sessions, form2-chain its chain, form2-fix its
# fixes, form2-night ana's own nights, and form2-all the first three at once, in
# form 2's calls:
#
#   ## check  PATH                      the checker's output as it is, then `(exit N)`
#   ## look   PATH, then names, a line  each name the file defines: `NAME, lines
#             each                      A-B:` and its whole definition; a Base name
#                                       (Bend) `NAME, in Base:` and its first line;
#                                       another language's names the checker's
#                                       Context (their types)
#   ## add    PATH, then a definition   a new one, after the last: `added: NAME,
#                                       lines A-B`, then the check, as `## check`'s
#   ## def    PATH, then a definition   the one of its name replaced: `ok: NAME,
#                                       lines A-B`, then the check; a name the file
#                                       does not define is refused, with the
#                                       nearest one, and no file changes
#   ## read   PATH FROM LIMIT           as format mugen's (a direct ask's context)
#
# No shell and no line edits.  The reply opens with the verdict of the check
# just above it (Bend's first line, and what it said when it failed; another
# checker's `ghc passes (exit 0).`, or `ghc fails (exit 1): WHAT.`).  Look and
# def mean Spec/Form2.bend's get and put (a lens over the file's pieces); the
# unit's declaration is its file's last piece (Check/Bend.bend: the head, the
# declaration, the tail left out), its lines from the head's end.  Every echo
# is a recorded check or text of the file: no checker runs.
#
# The fixes (the user, 11-12: an edit that fails and is retried, a check that
# fails more than once, an honest give-up):
#
#   mugen-fix-miss-SHAPE        (direct, fill, repair-M) a def refused: the
#                               direct ask's new name sent to `## def`, or a
#                               fill's or repair's name misspelt (a character
#                               short); then the right call
#   mugen-fix-repeat[-S]-J      (S fill or repair) J wrong definitions (the
#                               mutants, each with its check), then the right one
#   mugen-fix-giveup[-fill]-J   J wrong definitions, then the one that puts the
#                               hole back (`?goal`, `_`, `?`), and a reply with
#                               the verdict, the tries and the last error
#
# Format mugen's misses and stale edits (an edit's old text not in the file)
# have no counterpart: a def copies no old text.  Every refused or wrong write
# has a later write, so the reader takes it as a try (weight 0); a give-up's
# last write is the hole, never a wrong program, and a give-up needs a hole
# whose check fails (an Agda goal display passes: none there).

# a call's turn: its label, the path's line, the rest
def f2.call(+label: String, +path: List<&2, U32>, +rest: List<&2, U32>) -> List<&2, U32>:
  turn(U.b(label), cat([path, nl(), rest]))

# a check's echo text: the output (another checker's as if run on the file here), `(exit N)`
def f2.out.on(bend: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  match bend:
    case True{}:
      +k = check.of(c)
      mg.shell.echo(check.out(k), check.status(k))
    case False{}:
      +k = check.of(c)
      mg.shell.echo(mg.out(field(fs, 0n), path, check.out(k)), mg.status(check.status(k)))

def f2.out(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  f2.out.on(mg.is.bend(fs), fs, path, c)

# a hole's check: Agda's is its goal display (Cmd_goal_type_context), which passes
def f2.hole.on(agda: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  match agda:
    case True{}:
      mg.shell.echo(mg.out(field(fs, 0n), path, check.out(check.of(c))), U.b("0"))
    case False{}:
      f2.out(fs, path, c)

def f2.hole.out(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  f2.hole.on(mg.is.agda(fs), fs, path, c)

def f2.check(+path: List<&2, U32>, +text: List<&2, U32>) -> List<&2, U32>:
  U.append(f2.call("check", path, Nil{}), mg.echo(text))

# the declaration with body as the file has it, and its first line there
def f2.decl(+fs: List<&2, List<&2, U32>>, +body: List<&2, U32>) -> List<&2, U32>:
  U.append(field(fs, 6n), body)

def f2.from(+fs: List<&2, List<&2, U32>>) -> Nat:
  1n+mg.nls(mg.head(fs))

def f2.span(+from: Nat, +text: List<&2, U32>) -> List<&2, U32>:
  +n = List.length(&2, List<&2, U32>, mg.rows(text))
  cat([U.b("lines "), mg.n(from), U.b("-"), mg.n(Nat.sub(Nat.add(from, n), 1n))])

# a write of the declaration with body (label add or def), its echo: said
# (added, ok), the name, its lines, then the check's text
def f2.write(+label: String, +said: String, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +body: List<&2, U32>, +ctext: List<&2, U32>) -> List<&2, U32>:
  +decl = f2.decl(fs, body)
  U.append(f2.call(label, path, mg.end.nl(decl)),
    mg.echo(cat([U.b(said), U.b(": "), field(fs, 2n), U.b(", "), f2.span(f2.from(fs), decl), nl(), ctext])))

def f2.lab(+first: Bool) -> String:
  Bool.pick(String, first, "add", "def")

def f2.said(+first: Bool) -> String:
  Bool.pick(String, first, "added", "ok")

# A misspelt name -------------------------------------------------------------------

# a byte a name may hold (ASCII letters, digits, _ . '; any byte past ASCII)
def f2.namech(+c: U32) -> Bool:
  Bool.or(U32.is_lt(126, c), Bool.or(Bool.and(U32.is_lt(96, c), U32.is_lt(c, 123)), Bool.or(Bool.and(U32.is_lt(64, c), U32.is_lt(c, 91)),
    Bool.or(Bool.and(U32.is_lt(47, c), U32.is_lt(c, 58)), Bool.or(U32.is_eq(c, 95), Bool.or(U32.is_eq(c, 46), U32.is_eq(c, 39)))))))

def f2.ascii(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.and(U32.is_lt(h, 127), f2.ascii(t))

def f2.ends.word(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.not(f2.namech(h))

# xs with its first whole-word old (k its length) as new, and whether it had one
type F2s is Data:
  F2s{hit: Bool, text: List<&2, U32>}

def f2.s.cons(+h: U32, r: F2s) -> F2s:
  match r:
    case F2s{b, t}:
      F2s{b, h <> t}

def f2.swap.go(fuel: Nat, xs: List<&2, U32>, +old: List<&2, U32>, +new: List<&2, U32>, +k: Nat, +edge: Bool) -> F2s:
  match fuel xs:
    case 1n+f +h <> +t:
      +hit = Bool.and(edge, Bool.and(U.prefix(h <> t, old), f2.ends.word(List.drop(&2, U32, h <> t, k))))
      Bool.pick(F2s, hit, F2s{True{}, U.append(new, List.drop(&2, U32, h <> t, k))}, f2.s.cons(h, f2.swap.go(f, t, old, new, k, Bool.not(f2.namech(h)))))
    case _ xs2:
      F2s{False{}, xs2}

def f2.swap(+xs: List<&2, U32>, +old: List<&2, U32>, +new: List<&2, U32>) -> F2s:
  f2.swap.go(1n+U.len(xs), xs, old, new, U.len(old), True{})

# the name a character short in its middle (an ASCII name of 4 or more)
def f2.typo(+n: List<&2, U32>) -> List<&2, U32>:
  +h = Nat.div(U.len(n), 2n)
  U.append(List.take(&2, U32, n, h), List.drop(&2, U32, n, 1n+h))

def f2.typo.ok(+n: List<&2, U32>) -> Bool:
  Bool.and(f2.ascii(n), Nat.is_lt(3n, U.len(n)))

# mugen's refusal of a def whose name the file does not define
def f2.refusal(+bad: List<&2, U32>, +path: List<&2, U32>, +near: List<&2, U32>) -> List<&2, U32>:
  cat([U.b("refused: no "), bad, U.b(" in "), path, U.b(" (a new definition is `## add`); the nearest: "), near, U.b(". No file was changed.")])

# a fill's or repair's def of body with the name misspelt, refused (hit: the
# declaration had the name as a word)
def f2.miss.of(s: F2s, +name: List<&2, U32>, +bad: List<&2, U32>, +path: List<&2, U32>) -> Mx:
  match s:
    case F2s{hit, text}:
      Mx{Bool.and(hit, f2.typo.ok(name)), U.append(f2.call("def", path, mg.end.nl(text)), mg.echo(f2.refusal(bad, path, name)))}

def f2.miss.def(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +body: List<&2, U32>) -> Mx:
  +name = field(fs, 2n)
  +bad = f2.typo(name)
  f2.miss.of(f2.swap(f2.decl(fs, body), name, bad), name, bad, path)

# a direct ask's new definition sent to `## def`: refused, nothing near it
def f2.miss.add(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  U.append(f2.call("def", path, mg.end.nl(f2.decl(fs, field(fs, 7n)))),
    mg.echo(cat([U.b("refused: no "), field(fs, 2n), U.b(" in "), path, U.b(" (a new definition is `## add`). No file was changed.")])))

# Look --------------------------------------------------------------------------------

# a definition as look shows it
def f2.entry(+name: List<&2, U32>, +from: Nat, +text: List<&2, U32>) -> List<&2, U32>:
  cat([name, U.b(", "), f2.span(from, text), U.b(":\n"), mg.chomp(text)])

# Bend's pieces (Spec/Form2.bend's instance, over a line's bytes): a head is
# `def NAME`, `law NAME` or `type NAME` at column 0, a gap line blank or a comment
def f2.bname(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(List<&2, U32>, Bool.not(Bool.or(U32.is_eq(c, 40), Bool.or(U32.is_eq(c, 58), Bool.or(U32.is_eq(c, 60), U.is_space(c))))), c <> f2.bname(t), Nil{})

def f2.bafter(+l: List<&2, U32>, +p: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  Bool.pick(Maybe<&2, List<&2, U32>>, U.prefix(l, p), Some{f2.bname(List.drop(&2, U32, l, U.len(p)))}, None{})

def f2.bhd(+l: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  Maybe.or(&2, List<&2, U32>, f2.bafter(l, U.b("def ")), Maybe.or(&2, List<&2, U32>, f2.bafter(l, U.b("law ")), f2.bafter(l, U.b("type "))))

def f2.bgp(+l: List<&2, U32>) -> Bool:
  Bool.or(U.blank(l), head.is(l, 35))

def f2.beq(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  U.eq(a, b)

def f2.bdoc(+head: List<&2, U32>) -> F2.Doc<List<&2, U32>, List<&2, U32>>:
  F2.split(~List<&2, U32>, ~List<&2, U32>, ~f2.bhd, ~f2.bgp, ~f2.beq, U.lines(head))

# the entry of the piece named n, the pieces from line k on (none: empty)
def f2.piece.at(ds: List<&2, F2.Piece<List<&2, U32>, List<&2, U32>>>, +k: Nat, +n: List<&2, U32>) -> List<&2, U32>:
  match ds:
    case Nil{}:
      Nil{}
    case F2.Piece{nm, +b, +g} <> t:
      Bool.pick(List<&2, U32>, U.eq(nm, n), f2.entry(n, k, U.concat(b)),
        f2.piece.at(t, Nat.add(k, Nat.add(List.length(&2, List<&2, U32>, b), List.length(&2, List<&2, U32>, g))), n))

def f2.in.doc(+d: F2.Doc<List<&2, U32>, List<&2, U32>>, +n: List<&2, U32>) -> List<&2, U32>:
  match d:
    case F2.Doc{+p, +g, ds}:
      f2.piece.at(ds, 1n+Nat.add(List.length(&2, List<&2, U32>, p), List.length(&2, List<&2, U32>, g)), n)

# a looked-up name and its answer
type F2e is Data:
  F2e{name: List<&2, U32>, text: List<&2, U32>}

def f2.e.on(ok: Bool, +n: List<&2, U32>, +t: List<&2, U32>, rest: List<&2, F2e>) -> List<&2, F2e>:
  match ok:
    case True{}:
      F2e{n, t} <> rest
    case False{}:
      rest

# the names the head defines, each with its piece
def f2.heads(ns: List<&2, List<&2, U32>>, +d: F2.Doc<List<&2, U32>, List<&2, U32>>) -> List<&2, F2e>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +x = f2.in.doc(d, n)
      f2.e.on(Bool.not(empty(x)), n, x, f2.heads(t, d))

# (the head cut into pieces only when the Context names one it defines)
def f2.heads.if(some: Bool, ns: List<&2, List<&2, U32>>, +head: List<&2, U32>) -> List<&2, F2e>:
  match some:
    case True{}:
      f2.heads(ns, f2.bdoc(head))
    case False{}:
      Nil{}

def f2.bases(bs: List<&2, Bl>) -> List<&2, F2e>:
  match bs:
    case Nil{}:
      Nil{}
    case Bl{+n, +l} <> t:
      F2e{n, cat([n, U.b(", in Base:\n"), l])} <> f2.bases(t)

def f2.e.names(es: List<&2, F2e>) -> List<&2, List<&2, U32>>:
  match es:
    case Nil{}:
      Nil{}
    case F2e{n, t} <> r:
      n <> f2.e.names(r)

def f2.e.texts(es: List<&2, F2e>) -> List<&2, List<&2, U32>>:
  match es:
    case Nil{}:
      Nil{}
    case F2e{n, t} <> r:
      t <> f2.e.texts(r)

# the look call for es (none: no call)
def f2.look.of(+path: List<&2, U32>, +es: List<&2, F2e>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, F2e, es), 0n), Nil{},
    U.append(f2.call("look", path, U.append(mg.join(f2.e.names(es), nl()), nl())), mg.echo(mg.join(f2.e.texts(es), U.b("\n\n")))))

# the declaration (body: as the file has it; none: a direct ask's, not there yet)
# and the names the Context lists: Bend's from the head's pieces and Base
def f2.looks.bend(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +mine: List<&2, F2e>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  +ns = mg.words(field(fs, 9n))
  +hls = split(field(fs, 5n), 10)
  +inf = mg.keep(ns, hls, True{})
  f2.look.of(path, List.concat(&2, F2e, [mine, f2.heads.if(Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, inf), 0n)), inf, field(fs, 5n)),
    f2.bases(mg.based(mg.keep(ns, hls, False{}), base))]))

# another language's: the declaration, then the Context under the names it lists
def f2.looks.other(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +mine: List<&2, F2e>) -> List<&2, U32>:
  +ns = mg.words(field(fs, 9n))
  +ctx = mg.chomp(mg.out(field(fs, 0n), path, field(fs, 12n)))
  +some = Bool.and(Bool.not(empty(ctx)), Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, ns), 0n)))
  +es = Bool.pick(List<&2, F2e>, some, List.append(&2, F2e, mine, [F2e{mg.join(ns, nl()), ctx}]), mine)
  f2.look.of(path, es)

def f2.looks.on(bend: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +mine: List<&2, F2e>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  match bend:
    case True{}:
      f2.looks.bend(fs, path, mine, base)
    case False{}:
      f2.looks.other(fs, path, mine)

# a look at the declaration with body (fill, repair) and the Context's names
def f2.looks(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +body: List<&2, U32>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  f2.looks.on(mg.is.bend(fs), fs, path, [F2e{field(fs, 2n), f2.entry(field(fs, 2n), f2.from(fs), f2.decl(fs, body))}], base)

# a direct ask's: the Context's names only
def f2.looks.new(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  f2.looks.on(mg.is.bend(fs), fs, path, Nil{}, base)

# Laws in the replies (Form 2 kinds, below) ------------------------------------------

# a Bend unit's laws: the text after its definition in the file (none: empty)
def f3.laws(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +x = field(fs, 14n)
  Bool.pick(List<&2, U32>, Bool.and(mg.is.bend(fs), Bool.not(U.has(x, 31))), x, Nil{})

def f3.in(ns: List<&2, List<&2, U32>>, +n: List<&2, U32>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case +x <> t:
      Bool.or(U.eq(x, n), f3.in(t, n))

def f3.dedupe(ns: List<&2, List<&2, U32>>, +seen: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +had = f3.in(seen, n)
      mg.keep.on(Bool.not(had), n, f3.dedupe(t, Bool.pick(List<&2, List<&2, U32>>, had, seen, n <> seen)))

# a text's pieces' names, in order, each once (Bend's heads: a law and its
# proof's def share one)
def f3.names.d(+d: F2.Doc<List<&2, U32>, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match d:
    case F2.Doc{+p, +g, ds}:
      F2.names(List<&2, U32>, List<&2, U32>, ds)

def f3.names(+x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  f3.dedupe(f3.names.d(f2.bdoc(x)), Nil{})

# a check that failed at one of the unit's laws: what the law says and what
# the definition computed (Bend's `- expected` is the left side's value, the
# definition's; `- observed` the law's right side); none when it did not
def f3.why.law(+fs: List<&2, List<&2, U32>>, +out: List<&2, U32>) -> List<&2, U32>:
  +ls = split(out, 10)
  +at = U.trim.right(U.strip(mg.find(ls, U.b("Location: ")), U.b("Location: ")))
  +hit = Bool.and(Bool.not(empty(f3.laws(fs))), f3.in(f3.names(f3.laws(fs)), at))
  Bool.pick(List<&2, U32>, hit, cat([U.b(": its law "), code(at), U.b(" says "), mg.val(mg.find(ls, U.b("- observed"))), U.b(", and it computed "), mg.val(mg.find(ls, U.b("- expected")))]), Nil{})

# a failed check's why in a reply: at one of the unit's laws, the law's; else
# as mg.why.on (the checker's message and line)
def f3.why.on(bend: Bool, +fs: List<&2, List<&2, U32>>, +out: List<&2, U32>) -> List<&2, U32>:
  match bend:
    case True{}:
      +w = f3.why.law(fs, out)
      Bool.pick(List<&2, U32>, empty(w), mg.why(out), w)
    case False{}:
      mg.why.other(fs, out)

# Verdicts and replies ---------------------------------------------------------------

def f2.unpunct.r(r: List<&2, U32>) -> List<&2, U32>:
  match r:
    case +h <> +t:
      Bool.pick(List<&2, U32>, Bool.or(U32.is_eq(h, 46), U32.is_eq(h, 58)), f2.unpunct.r(t), h <> t)
    case Nil{}:
      Nil{}

# a line less its last `.` or `:`
def f2.unpunct(+l: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, f2.unpunct.r(List.reverse(&2, U32, U.trim.right(l))))

def f2.passed(+c: List<&2, U32>) -> Bool:
  U.eq(mg.status(check.status(check.of(c))), U.b("0"))

# Bend's: the output's first line, and when it failed what it said and where
def f2.verdict.bend(+c: List<&2, U32>) -> List<&2, U32>:
  +o = check.out(check.of(c))
  +l = f2.unpunct(mg.upto(lead.trim(o), 10))
  +w = List.drop(&2, U32, mg.why(o), 18n)
  Bool.pick(List<&2, U32>, Bool.or(f2.passed(c), empty(w)), U.append(l, U.b(".")), cat([l, U.b(": "), w, U.b(".")]))

# another checker's: passes or fails, the exit, and what it said
def f2.verdict.other(+fs: List<&2, List<&2, U32>>, +c: List<&2, U32>) -> List<&2, U32>:
  +s = mg.status(check.status(check.of(c)))
  +w = List.drop(&2, U32, mg.why.other(fs, check.out(check.of(c))), Nat.add(U.len(mg.said(fs)), 8n))
  +fail = cat([mg.said(fs), U.b(" fails (exit "), s, U.b(")"), Bool.pick(List<&2, U32>, empty(w), Nil{}, U.append(U.b(": "), w)), U.b(".")])
  Bool.pick(List<&2, U32>, f2.passed(c), cat([mg.said(fs), U.b(" passes (exit 0).")]), fail)

def f2.verdict.on(bend: Bool, +fs: List<&2, List<&2, U32>>, +c: List<&2, U32>) -> List<&2, U32>:
  match bend:
    case True{}:
      f2.verdict.bend(c)
    case False{}:
      f2.verdict.other(fs, c)

def f2.verdict(+fs: List<&2, List<&2, U32>>, +c: List<&2, U32>) -> List<&2, U32>:
  f2.verdict.on(mg.is.bend(fs), fs, c)

def f2.done.direct(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  +name = code(field(fs, 2n))
  cat([f2.verdict(fs, field(fs, 11n)), [32], Bool.pick(List<&2, U32>, mg.prop(fs), cat([U.b("Proved "), name, U.b(" in "), path, U.b(".")]),
    cat([U.b("Added "), name, U.b(" to "), path, U.b(".")]))])

def f2.done.fill(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  cat([f2.verdict(fs, field(fs, 11n)), U.b(" Filled the hole in "), code(field(fs, 2n)), U.b(" ("), path, U.b(").")])

def f2.done.repair(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +m: Nat) -> List<&2, U32>:
  cat([f2.verdict(fs, field(fs, 11n)), U.b(" Fixed "), code(field(fs, 2n)), U.b(" in "), path,
    f3.why.on(mg.is.bend(fs), fs, check.out(check.of(mutant.check(fs, m)))), U.b(".")])

# a give-up's: the verdict on the hole put back, the tries, the last one's error
def f2.giveup(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +j: Nat, +l: Nat) -> List<&2, U32>:
  cat([f2.verdict(fs, field(fs, 13n)), U.b(" I could not get "), code(field(fs, 2n)), U.b(" in "), path, U.b(" to pass in "), mg.n(j), U.b(" tries"),
    f3.why.on(mg.is.bend(fs), fs, check.out(check.of(mutant.check(fs, l)))), U.b(". I put the hole back in "), code(field(fs, 2n)), U.b(".")])

def f2.reply.x(+x: Nat, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +j: Nat, +l: Nat, +done: List<&2, U32>) -> List<&2, U32>:
  mg.reply(Bool.pick(List<&2, U32>, Nat.is_eq(x, 1n), f2.giveup(fs, path, j, l), done))

# a give-up needs a hole whose check fails
def f2.can.give(+fs: List<&2, List<&2, U32>>) -> Bool:
  Bool.and(Bool.not(empty(field(fs, 13n))), Bool.not(f2.passed(field(fs, 13n))))

# Form 2's kinds (2026-11-13; docs/form2/KINDS.md, Spec/Kinds.bend) ---------------------
#
# The user, 11-13: the prose "In the request, and ana also writes it as a `#`
# comment above her function"; laws "Example laws from running the original,
# plus the file's own general laws when it has them"; a function with no
# comment "Keep them, with the type and laws but no prose".  A Bend unit's
# direct session (and the chains and fixes that start from the direct ask)
# reads its head cut at a line (Spec/Kinds.bend's cut): before the function's
# comment, and before the definitions right above it that it calls, through
# one another (at most 3; up to 8 when they reach back to the file's first
# definition: a nearly empty file, `scratch`).  Her first add writes the lines
# from the cut, her definition and its laws, so the file it leaves is the
# unit's and the recorded check stands; its echo names every definition it
# added (`added: h, f, f.ex1, lines A-B`, as AgentMugen's).  The laws (bend-corpus-v2
# exlaw) are field 14, Bend's empty type field: a check holds 0x1F, laws never
# do; they follow the definition in every shape's file.  Every Base name the
# written code calls is looked up (the Context's 16 names, then the rest), and
# 1 in 8 direct asks that call Base first look up a near name that does not
# exist (`NAME: not in PATH or Base`).

def f3.minus(ns: List<&2, List<&2, U32>>, +out: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      mg.keep.on(Bool.not(f3.in(out, n)), n, f3.minus(t, out))

# The cut --------------------------------------------------------------------------------

# how many of a gap's last lines are comments (`#` at column 0): the piece below's
def f3.tcom.go(rs: List<&2, List<&2, U32>>, +n: Nat) -> Nat:
  match rs:
    case Nil{}:
      n
    case +l <> t:
      Bool.pick(Nat, head.is(l, 35), f3.tcom.go(t, 1n+n), n)

def f3.tcom(+ls: List<&2, List<&2, U32>>) -> Nat:
  f3.tcom.go(List.reverse(&2, List<&2, U32>, ls), 0n)

# a head's piece: its name, the line its comment starts at, its text, whether a def or a law
type F3p is Data:
  F3p{name: List<&2, U32>, at: Nat, text: List<&2, U32>, isdef: Bool}

def F3p.at(+p: F3p) -> Nat:
  match p:
    case F3p{n, a, x, d}:
      a

def F3p.def(+p: F3p) -> Bool:
  match p:
    case F3p{n, a, x, d}:
      d

# the pieces from line s on, c comment lines above the first
def f3.ps(ds: List<&2, F2.Piece<List<&2, U32>, List<&2, U32>>>, +s: Nat, +c: Nat) -> List<&2, F3p>:
  match ds:
    case Nil{}:
      Nil{}
    case F2.Piece{+nm, +b, +g} <> t:
      +x = U.concat(b)
      +d = Bool.or(U.prefix(x, U.b("def ")), U.prefix(x, U.b("law ")))
      +s2 = Nat.add(s, Nat.add(List.length(&2, List<&2, U32>, b), List.length(&2, List<&2, U32>, g)))
      F3p{nm, Nat.sub(s, c), x, d} <> f3.ps(t, s2, f3.tcom(g))

# whether the first byte is a name's
def f3.namehd(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      f2.namech(h)

# whether text uses the name n: n there with no name byte on either side
def f3.uses.go(xs: List<&2, U32>, +n: List<&2, U32>, +prev: Bool) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> +t:
      +hit = Bool.and(Bool.not(prev), Bool.and(U.prefix(h <> t, n), Bool.not(f3.namehd(List.drop(&2, U32, h <> t, U.len(n))))))
      Bool.or(hit, f3.uses.go(t, n, f2.namech(h)))

def f3.uses(+xs: List<&2, U32>, +n: List<&2, U32>) -> Bool:
  Bool.and(Bool.not(empty(n)), f3.uses.go(xs, n, False{}))

# the walk from the last piece up: the next is taken when it is a def or a law
# the text so far uses (at most 8)
type F3w is Data:
  F3w{k: Nat, at: Nat}

def f3.take.ok(+rs: List<&2, F3p>, +need: List<&2, U32>, +k: Nat) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case F3p{+nm, a, x, +d} <> t:
      Bool.and(Bool.and(d, Nat.is_lt(k, 8n)), f3.uses(need, nm))

def f3.walk(rs: List<&2, F3p>, ok: Bool, +need: List<&2, U32>, +k: Nat, +at: Nat) -> F3w:
  match rs ok:
    case F3p{nm, +a, +x, d} <> +t True{}:
      +need2 = U.append(need, x)
      f3.walk(t, f3.take.ok(t, need2, 1n+k), need2, 1n+k, a)
    case _ _:
      F3w{k, at}

def f3.types(ps: List<&2, F3p>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case +p <> t:
      Bool.and(Bool.not(F3p.def(p)), f3.types(t))

def f3.nth.at(ps: List<&2, F3p>, +i: Nat, +d: Nat) -> Nat:
  match ps:
    case Nil{}:
      d
    case +p <> t:
      Bool.pick(Nat, Nat.is_eq(i, 0n), F3p.at(p), f3.nth.at(t, Nat.sub(i, 1n), d))

# the cut: the line ana's file ends before, the definitions her add writes
# before hers, whether nothing else is left (only imports, types, comments)
type F3c is Data:
  F3c{at: Nat, k: Nat, scratch: Bool}

def f3.cut.on(+ps: List<&2, F3p>, +w: F3w) -> F3c:
  match w:
    case F3w{+k, +at}:
      +np = List.length(&2, F3p, ps)
      +scratch = Bool.and(Nat.is_lt(0n, k), f3.types(List.take(&2, F3p, ps, Nat.sub(np, k))))
      +three = Bool.and(Bool.not(scratch), Nat.is_lt(3n, k))
      Bool.pick(F3c, three, F3c{f3.nth.at(ps, Nat.sub(np, 3n), at), 3n, False{}}, F3c{at, k, scratch})

def f3.cut.d(+d: F2.Doc<List<&2, U32>, List<&2, U32>>, +ls: List<&2, List<&2, U32>>, +need: List<&2, U32>) -> F3c:
  match d:
    case F2.Doc{+p, +g, ds}:
      +ps = f3.ps(ds, Nat.add(List.length(&2, List<&2, U32>, p), List.length(&2, List<&2, U32>, g)), f3.tcom(g))
      +at0 = Nat.sub(List.length(&2, List<&2, U32>, ls), f3.tcom(ls))
      +rs = List.reverse(&2, F3p, ps)
      f3.cut.on(ps, f3.walk(rs, f3.take.ok(rs, need, 0n), need, 0n, at0))

def f3.cut.of(+head: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +need: List<&2, U32>) -> F3c:
  f3.cut.d(f2.bdoc(head), ls, need)

# a direct session's view of the unit: the file she reads, the lines her add
# writes before the declaration, how many definitions those hold, scratch
type F3v is Data:
  F3v{head: List<&2, U32>, lead: List<&2, U32>, k: Nat, scratch: Bool}

def F3v.head(+v: F3v) -> List<&2, U32>:
  match v:
    case F3v{h, l, k, s}:
      h

def F3v.lead(+v: F3v) -> List<&2, U32>:
  match v:
    case F3v{h, l, k, s}:
      l

def F3v.k(+v: F3v) -> Nat:
  match v:
    case F3v{h, l, k, s}:
      k

def F3v.scratch(+v: F3v) -> Bool:
  match v:
    case F3v{h, l, k, s}:
      s

# the whole head, nothing cut (another language, a fill or a repair)
def f3.none(+fs: List<&2, List<&2, U32>>) -> F3v:
  F3v{mg.head(fs), Nil{}, 0n, False{}}

def f3.view.ab(p: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>, +k: Nat, +s: Bool) -> F3v:
  match p:
    case (a, b):
      F3v{U.concat(a), U.concat(b), k, s}

def f3.view.of(+ls: List<&2, List<&2, U32>>, +c: F3c) -> F3v:
  match c:
    case F3c{+at, k, s}:
      f3.view.ab(Kd.cut(List<&2, U32>, ls, at), k, s)

def f3.view.on(bend: Bool, +fs: List<&2, List<&2, U32>>) -> F3v:
  match bend:
    case True{}:
      +ls = U.lines(mg.head(fs))
      f3.view.of(ls, f3.cut.of(mg.head(fs), ls, f2.decl(fs, field(fs, 7n))))
    case False{}:
      f3.none(fs)

def f3.view(+fs: List<&2, List<&2, U32>>) -> F3v:
  f3.view.on(mg.is.bend(fs), fs)

# The writes -----------------------------------------------------------------------------

# the first add's text: the lines from the cut, the declaration with body, its laws
def f3.add.text(+v: F3v, +fs: List<&2, List<&2, U32>>, +body: List<&2, U32>) -> List<&2, U32>:
  mg.end.nl(cat([F3v.lead(v), f2.decl(fs, body), f3.laws(fs)]))

def f3.add(+v: F3v, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +body: List<&2, U32>, +ctext: List<&2, U32>) -> List<&2, U32>:
  +x = f3.add.text(v, fs, body)
  U.append(f2.call("add", path, x),
    mg.echo(cat([U.b("added: "), mg.join(f3.names(x), U.b(", ")), U.b(", "), f2.span(1n+mg.nls(F3v.head(v)), x), nl(), ctext])))

# a session's first write (an add when first): Bend's through the view
def f3.write(+first: Bool, +v: F3v, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +body: List<&2, U32>, +ctext: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Bool.and(first, mg.is.bend(fs)), f3.add(v, fs, path, body, ctext), f2.write(f2.lab(first), f2.said(first), fs, path, body, ctext))

# The ask and the reply ------------------------------------------------------------------

# the laws' statements, their proofs left out: each `law` line and the lines
# under it up to the next head or blank line, a blank line between laws
def f3.stmts.go(ls: List<&2, List<&2, U32>>, +inside: Bool, +first: Bool) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +islaw = U.prefix(l, U.b("law "))
      +stop = Bool.or(U.blank(l), Bool.or(U.prefix(l, U.b("def ")), U.prefix(l, U.b("type "))))
      +sep = Bool.pick(List<&2, U32>, Bool.and(islaw, Bool.not(first)), nl(), Nil{})
      +keep = Bool.or(islaw, Bool.and(inside, Bool.not(stop)))
      U.append(Bool.pick(List<&2, U32>, keep, U.append(sep, l), Nil{}), f3.stmts.go(t, keep, Bool.and(first, Bool.not(islaw))))

def f3.stmts(+laws: List<&2, U32>) -> List<&2, U32>:
  mg.chomp(f3.stmts.go(U.lines(laws), False{}, True{}))

# a direct ask: as mg.ask.direct's, the laws' statements under the signature
def f3.ask.direct(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  +laws = f3.laws(fs)
  +name = code(field(fs, 2n))
  +line = Bool.pick(List<&2, U32>, mg.prop(fs), cat([U.b("Prove "), name, U.b(" in "), path, U.b(".")]), cat([U.b("Add "), name, U.b(" to "), path, U.b(".")]))
  +sig = Bool.pick(List<&2, U32>, empty(laws), tidy(field(fs, 4n)), cat([tidy(field(fs, 4n)), U.b("\n\n"), f3.stmts(laws)]))
  cat([mg.doc(fs, line), U.b("\n\n"), mg.chomp(fence(field(fs, 0n), sig))])

# `a`, `a` and `b`, `a`, `b` and `c`
def f3.ands(ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> +t:
      +k = List.length(&2, List<&2, U32>, t)
      Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), code(n), cat([code(n), Bool.pick(List<&2, U32>, Nat.is_eq(k, 1n), U.b(" and "), U.b(", ")), f3.ands(t)]))

def f3.before(ns: List<&2, List<&2, U32>>, +n: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +x <> t:
      Bool.pick(List<&2, List<&2, U32>>, U.eq(x, n), Nil{}, x <> f3.before(t, n))

def f3.after(ns: List<&2, List<&2, U32>>, +n: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +x <> +t:
      Bool.pick(List<&2, List<&2, U32>>, U.eq(x, n), t, f3.after(t, n))

# direct's reply: the verdict, what was added (the helpers before hers), its laws
def f3.done.direct(+v: F3v, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  +n = field(fs, 2n)
  +ns = f3.names(f3.add.text(v, fs, field(fs, 7n)))
  +hs = f3.before(ns, n)
  +ls = f3.after(ns, n)
  +wl = Bool.pick(List<&2, U32>, empty(f3.laws(fs)), Nil{}, U.append(U.b(", with its laws "), f3.ands(ls)))
  +what = Bool.pick(List<&2, U32>, mg.prop(fs),
    cat([U.b("Proved "), code(n), U.b(" in "), path, Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, hs), 0n), Nil{}, U.append(U.b(", after "), f3.ands(hs)))]),
    cat([U.b("Added "), f3.ands(List.append(&2, List<&2, U32>, hs, [n])), U.b(" to "), path]))
  cat([f2.verdict(fs, field(fs, 11n)), [32], what, wl, U.b(".")])

# the first mutant from m on that fails at a law (nm: none)
def f3.lawmut(k: Nat, +fs: List<&2, List<&2, U32>>, +m: Nat, +nm: Nat) -> Nat:
  match k:
    case 0n:
      nm
    case 1n+j:
      Bool.pick(Nat, Bool.not(empty(f3.why.law(fs, check.out(check.of(mutant.check(fs, m)))))), m, f3.lawmut(j, fs, 1n+m, nm))

# The look-ups ---------------------------------------------------------------------------

# the names a text's code lines hold (a letter or `_` first; comments left out)
def f3.toks.go(xs: List<&2, U32>, +cur: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, empty(cur), acc, List.reverse(&2, U32, cur) <> acc))
    case +h <> t:
      +more = Bool.or(f2.namech(h), Bool.and(Bool.not(empty(cur)), Bool.and(U32.is_lt(47, h), U32.is_lt(h, 58))))
      +start = Bool.and(empty(cur), Bool.or(U32.is_eq(h, 95), Bool.or(Bool.and(U32.is_lt(96, h), U32.is_lt(h, 123)), Bool.and(U32.is_lt(64, h), U32.is_lt(h, 91)))))
      +keep = Bool.or(start, Bool.and(Bool.not(empty(cur)), more))
      +acc2 = Bool.pick(List<&2, List<&2, U32>>, Bool.or(keep, empty(cur)), acc, List.reverse(&2, U32, cur) <> acc)
      f3.toks.go(t, Bool.pick(List<&2, U32>, keep, h <> cur, Nil{}), acc2)

def f3.code.lines(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      U.append(Bool.pick(List<&2, U32>, head.is(lead.trim(l), 35), Nil{}, l), f3.code.lines(t))

def f3.toks(+x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  f3.dedupe(f3.toks.go(f3.code.lines(U.lines(x)), Nil{}, Nil{}), Nil{})

# Base's defs and laws among ns (not its types: every signature names those)
def f3.based.fn(ns: List<&2, List<&2, U32>>, +base: Map<&2, List<&2, U32>>) -> List<&2, Bl>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> more:
      +l = mg.got(Map.get(List<&2, U32>, Nil{}, base, mg.str(n)))
      mg.based.on(Bool.or(U.prefix(l, U.b("def ")), U.prefix(l, U.b("law "))), n, l, f3.based.fn(more, base))

# a direct ask's look-ups through the view: the Context's names, then every
# other name the add's code uses (Base's defs and laws, the file's
# definitions), less the ones it defines: the file's whole pieces, Base's
# first lines
def f3.look.ctx(+v: F3v, +fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  f3.minus(mg.words(field(fs, 9n)), f3.names(f3.add.text(v, fs, field(fs, 7n))))

def f3.look.more(+v: F3v, +fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  +x = f3.add.text(v, fs, field(fs, 7n))
  f3.minus(f3.toks(x), List.append(&2, List<&2, U32>, mg.words(field(fs, 9n)), f3.names(x)))

def f3.look.bases(+v: F3v, +fs: List<&2, List<&2, U32>>, +hls: List<&2, List<&2, U32>>, +base: Map<&2, List<&2, U32>>) -> List<&2, Bl>:
  List.append(&2, Bl, mg.based(mg.keep(f3.look.ctx(v, fs), hls, False{}), base), f3.based.fn(mg.keep(f3.look.more(v, fs), hls, False{}), base))

def f3.looks(+v: F3v, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  +head = F3v.head(v)
  +hls = split(head, 10)
  +inf = mg.keep(List.append(&2, List<&2, U32>, f3.look.ctx(v, fs), f3.look.more(v, fs)), hls, True{})
  f2.look.of(path, List.append(&2, F2e, f2.heads.if(Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, inf), 0n)), inf, head),
    f2.bases(f3.look.bases(v, fs, hls, base))))

# A near name that is not there: a Base name the add calls with another
# namespace (one of the file's types first, then Base's), or with an `s` more
# or less, or `is_` less or more; the first that neither Base nor the file has
def f3.ns.of(+n: List<&2, U32>) -> List<&2, U32>:
  mg.upto(n, 46)

def f3.fn.of(+n: List<&2, U32>) -> List<&2, U32>:
  mg.after(n, 46)

def f3.bytes.all(ss: List<&2, String>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      U.b(s) <> f3.bytes.all(t)

# each namespace with fn after it
def f3.prefixed(ps: List<&2, List<&2, U32>>, +fn: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      cat([p, [46], fn]) <> f3.prefixed(t, fn)

def f3.near.cands(+n: List<&2, U32>, +types: List<&2, List<&2, U32>>, +r: Nat) -> List<&2, List<&2, U32>>:
  +fn = f3.fn.of(n)
  +sib : List<&2, String> = ["List", "Nat", "U32", "String", "Bool", "Maybe", "Char", "Map", "I32", "Pair"]
  +k = Nat.mod(r, 10n)
  +rot = List.append(&2, String, List.drop(&2, String, sib, k), List.take(&2, String, sib, k))
  +ons = f3.prefixed(f3.bytes.all(rot), fn)
  +own = f3.prefixed(types, fn)
  +edits : List<&2, List<&2, U32>> = [U.append(n, [115]), List.take(&2, U32, n, Nat.sub(U.len(n), 1n)), cat([f3.ns.of(n), [46], U.strip(fn, U.b("is_"))]), cat([f3.ns.of(n), U.b(".is_"), fn])]
  List.concat(&2, List<&2, U32>, [own, ons, edits])

def f3.absent(+c: List<&2, U32>, +n: List<&2, U32>, +hls: List<&2, List<&2, U32>>, +base: Map<&2, List<&2, U32>>) -> Bool:
  Bool.and(Bool.and(Bool.not(U.eq(c, n)), Bool.and(f3.namehd(c), Nat.is_lt(2n, U.len(c)))),
    Bool.and(Nat.is_eq(List.length(&2, Bl, mg.based([c], base)), 0n), Bool.not(mg.sig.any(hls, c))))

def f3.near.go(cs: List<&2, List<&2, U32>>, +n: List<&2, U32>, +hls: List<&2, List<&2, U32>>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(List<&2, U32>, f3.absent(c, n, hls, base), c, f3.near.go(t, n, hls, base))

def f3.types.of(ps: List<&2, F2.Piece<List<&2, U32>, List<&2, U32>>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case F2.Piece{+nm, +b, g} <> t:
      mg.keep.on(Bool.and(U.prefix(U.concat(b), U.b("type ")), Bool.not(U.has(nm, 46))), nm, f3.types.of(t))

def f3.types.d(+d: F2.Doc<List<&2, U32>, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match d:
    case F2.Doc{+p, +g, ds}:
      f3.types.of(ds)

def f3.types.in(+head: List<&2, U32>) -> List<&2, List<&2, U32>>:
  f3.types.d(f2.bdoc(head))

def f3.dotted(ns: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      mg.keep.on(Bool.and(U.has(n, 46), Bool.not(empty(f3.fn.of(n)))), n, f3.dotted(t))

# the miss: a look of the near name and its echo (none: no Base name to miss)
def f3.miss.look(+v: F3v, +fs: List<&2, List<&2, U32>>, +id: List<&2, U32>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  +head = F3v.head(v)
  +hls = split(head, 10)
  +bs = f3.dotted(mg.bl.names(f3.based.fn(mg.keep(List.append(&2, List<&2, U32>, f3.look.ctx(v, fs), f3.look.more(v, fs)), hls, False{}), base)))
  +k = List.length(&2, List<&2, U32>, bs)
  +n = U.nth(bs, roll(id, 22n, Nat.max(k, 1n)))
  +types = f3.types.in(head)
  +c = Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), Nil{}, f3.near.go(f3.near.cands(n, types, roll(id, 23n, 10n)), n, hls, base))
  Bool.pick(List<&2, U32>, empty(c), Nil{}, f2.look.of(path, [F2e{c, cat([c, U.b(": not in "), path, U.b(" or Base")])}]))

def f3.read.tail(+head: List<&2, U32>, +path: List<&2, U32>) -> List<&2, U32>:
  +n = List.length(&2, List<&2, U32>, mg.rows(head))
  +from = Bool.pick(Nat, Nat.is_lt(n, 25n), 1n, Nat.sub(n, 23n))
  mg.read(path, head, from, Nat.sub(Nat.add(n, 1n), from))

# Sessions ------------------------------------------------------------------------------

# the last write: x 0 the original, its check; 1 the hole back, its check
def f2.end(x: Nat, +first: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  match x:
    case 0n:
      f2.write(f2.lab(first), f2.said(first), fs, path, field(fs, 7n), f2.out(fs, path, field(fs, 11n)))
    case _:
      f2.write(f2.lab(first), f2.said(first), fs, path, field(fs, 10n), f2.hole.out(fs, path, field(fs, 13n)))

# j wrong writes, the mutants from m on, each with its recorded check, then
# the end x gives; first: the file has no declaration yet (its first write an add)
def f2.tries(+x: Nat, j: Nat, +first: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +m: Nat, +nm: Nat) -> List<&2, U32>:
  match j:
    case 0n:
      f2.end(x, first, fs, path)
    case 1n+p:
      U.append(f2.write(f2.lab(first), f2.said(first), fs, path, mutant(fs, m), f2.out(fs, path, mutant.check(fs, m))),
        f2.tries(x, p, False{}, fs, path, next.m(m, 1n, nm), nm))

def f2.read.tail(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  +f0 = mg.head(fs)
  +n = List.length(&2, List<&2, U32>, mg.rows(f0))
  +from = Bool.pick(Nat, Nat.is_lt(n, 25n), 1n, Nat.sub(n, 23n))
  mg.read(path, f0, from, Nat.sub(Nat.add(n, 1n), from))

# direct: the ask, the file's last lines, the look-ups, [a def refused], the
# writes (an add first), the reply (another language's: R5g's, as it was)
def f2.direct.other(+x: Nat, +miss: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +j: Nat, +m: Nat, +nm: Nat) -> Mx:
  +ok = Bool.and(mg.tries.ok(j, fs, Nil{}, m, nm), Bool.or(Nat.is_eq(x, 0n), f2.can.give(fs)))
  Mx{ok, cat([mg.user(mg.ask.direct(fs, path)), f2.read.tail(fs, path), f2.looks.new(fs, path, base),
    Bool.pick(List<&2, U32>, miss, f2.miss.add(fs, path), Nil{}), f2.tries(x, j, True{}, fs, path, m, nm),
    f2.reply.x(x, fs, path, j, mg.last.m(m, j, nm), f2.done.direct(fs, path))])}

# Bend's last write and tries as f2.end's and f2.tries's, the first through the
# view (an add of the lines from the cut, the declaration, its laws)
def f3.end(x: Nat, +first: Bool, +v: F3v, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  match x:
    case 0n:
      f3.write(first, v, fs, path, field(fs, 7n), f2.out(fs, path, field(fs, 11n)))
    case _:
      f3.write(first, v, fs, path, field(fs, 10n), f2.hole.out(fs, path, field(fs, 13n)))

def f3.tries(+x: Nat, j: Nat, +first: Bool, +v: F3v, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +m: Nat, +nm: Nat) -> List<&2, U32>:
  match j:
    case 0n:
      f3.end(x, first, v, fs, path)
    case 1n+p:
      U.append(f3.write(first, v, fs, path, mutant(fs, m), f2.out(fs, path, mutant.check(fs, m))),
        f3.tries(x, p, False{}, v, fs, path, next.m(m, 1n, nm), nm))

# about 1 in 8 Bend direct asks look up a near name first (none when the add
# calls no Base definition)
def f3.near(+id: List<&2, U32>) -> Bool:
  Nat.is_eq(roll(id, 24n, 8n), 0n)

def f3.miss.if(near: Bool, +v: F3v, +fs: List<&2, List<&2, U32>>, +id: List<&2, U32>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  match near:
    case True{}:
      f3.miss.look(v, fs, id, path, base)
    case False{}:
      Nil{}

# a Bend direct ask through the view: the ask (with the laws' statements), the
# cut file's last lines, [a near name not found], the look-ups, [a def
# refused], the writes (the first an add from the cut), the reply
def f3.direct(+x: Nat, +miss: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +j: Nat, +m: Nat, +nm: Nat) -> Mx:
  +v = f3.view(fs)
  +ok = Bool.and(mg.tries.ok(j, fs, Nil{}, m, nm), Bool.or(Nat.is_eq(x, 0n), f2.can.give(fs)))
  Mx{ok, cat([mg.user(f3.ask.direct(fs, path)), f3.read.tail(F3v.head(v), path), f3.miss.if(f3.near(id), v, fs, id, path, base),
    f3.looks(v, fs, path, base), Bool.pick(List<&2, U32>, miss, f2.miss.add(fs, path), Nil{}), f3.tries(x, j, True{}, v, fs, path, m, nm),
    f2.reply.x(x, fs, path, j, mg.last.m(m, j, nm), f3.done.direct(v, fs, path))])}

def f2.direct.on(bend: Bool, +x: Nat, +miss: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +j: Nat, +m: Nat, +nm: Nat) -> Mx:
  match bend:
    case True{}:
      f3.direct(x, miss, fs, path, base, id, j, m, nm)
    case False{}:
      f2.direct.other(x, miss, fs, path, base, j, m, nm)

def f2.direct(+x: Nat, +miss: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +j: Nat, +m: Nat, +nm: Nat) -> Mx:
  f2.direct.on(mg.is.bend(fs), x, miss, fs, path, base, id, j, m, nm)

# a direct session's tag: `direct`, `direct-helper-K` (K definitions above
# hers in her add), `direct-scratch-K` (a nearly empty file), `-miss` after
# when she looks up a near name first
def f3.tag(+fs: List<&2, List<&2, U32>>, +id: List<&2, U32>, +base: Map<&2, List<&2, U32>>) -> List<&2, U32>:
  +v = f3.view(fs)
  +k = F3v.k(v)
  +kind = Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), Nil{}, cat([Bool.pick(List<&2, U32>, F3v.scratch(v), U.b("-scratch-"), U.b("-helper-")), mg.n(k)]))
  +near = Bool.not(empty(f3.miss.if(Bool.and(mg.is.bend(fs), f3.near(id)), v, fs, id, mg.path(id), base)))
  cat([U.b("direct"), kind, Bool.pick(List<&2, U32>, near, U.b("-miss"), Nil{})])

# fill: the ask, the hole's check, a look at the declaration and the
# Context's names, [a def refused], the writes, the reply
def f2.fill(+x: Nat, +miss: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +j: Nat, +m: Nat, +nm: Nat) -> Mx:
  +ok = Bool.and(mg.tries.ok(j, fs, field(fs, 10n), m, nm), Bool.or(Nat.is_eq(x, 0n), f2.can.give(fs)))
  +r = Bool.pick(Mx, miss, f2.miss.def(fs, path, field(fs, 7n)), Mx{True{}, Nil{}})
  mx.and(ok, mx.pre(cat([mg.user(mg.ask.fill(fs, path)), f2.check(path, f2.hole.out(fs, path, field(fs, 13n))), f2.looks(fs, path, field(fs, 10n), base)]),
    mx.post(r, U.append(f2.tries(x, j, False{}, fs, path, m, nm), f2.reply.x(x, fs, path, j, mg.last.m(m, j, nm), f2.done.fill(fs, path))))))

# repair: mutant m handed over: the ask, its check, a look, [a def refused],
# j wrong writes from the next mutant on, the right one, the reply
def f2.repair(+miss: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +m: Nat, +j: Nat, +nm: Nat) -> Mx:
  +mut = mutant(fs, m)
  +ok = mg.tries.ok(j, fs, mut, next.m(m, 1n, nm), nm)
  +r = Bool.pick(Mx, miss, f2.miss.def(fs, path, field(fs, 7n)), Mx{True{}, Nil{}})
  mx.and(ok, mx.pre(cat([mg.user(mg.ask.repair(fs, path)), f2.check(path, f2.out(fs, path, mutant.check(fs, m))), f2.looks(fs, path, mut, base)]),
    mx.post(r, U.append(f2.tries(0n, j, False{}, fs, path, next.m(m, 1n, nm), nm), mg.reply(f2.done.repair(fs, path, m))))))

# Presentations -------------------------------------------------------------------------

def f2.keep(r: Mx, +b: Tk.Bpe, +limit: Nat, +id: List<&2, U32>, +shape: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match r:
    case Mx{ok, t}:
      mg.one.keep(ok, b, limit, id, shape, t, rest)

def f2.repairs(k: Nat, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +m: Nat, +nm: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match k:
    case 0n:
      rest
    case 1n+j:
      f2.keep(f2.repair(False{}, fs, path, base, m, 0n, nm), b, limit, id, U.append(U.b("repair-"), mg.n(m)),
        f2.repairs(j, b, limit, base, id, fs, path, 1n+m, nm, rest))

# a unit's sessions, as format mugen's mg.unit: direct (not Nix), fill (a hole), a repair a mutant
def f2.fill.if(some: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +nm: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match some:
    case True{}:
      f2.keep(f2.fill(0n, False{}, fs, path, base, 0n, 0n, nm), b, limit, id, U.b("fill"), rest)
    case False{}:
      rest

def f2.direct.if(some: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +nm: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match some:
    case True{}:
      f2.keep(f2.direct(0n, False{}, fs, path, base, id, 0n, 0n, nm), b, limit, id, f3.tag(fs, id, base), rest)
    case False{}:
      rest

def f2.unit(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  +path = mg.path(id)
  +nm = mutant.count(fs)
  f2.direct.if(Bool.not(mg.is.nix(fs)), b, limit, base, id, fs, path, nm,
    f2.fill.if(Bool.not(empty(field(fs, 13n))), b, limit, base, id, fs, path, nm, f2.repairs(nm, b, limit, base, id, fs, path, 0n, nm, rest)))

# the unit's chain, as format chain's mg.chain.unit chooses it
def f2.chain.at(repair: Bool, hole: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +j: Nat, +m: Nat, +nm: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match repair hole:
    case True{} _:
      f2.keep(f2.repair(False{}, fs, path, base, m, j, nm), b, limit, id, U.append(U.b("chain-repair-"), mg.n(j)), rest)
    case False{} True{}:
      f2.keep(f2.fill(0n, False{}, fs, path, base, j, m, nm), b, limit, id, U.append(U.b("chain-fill-"), mg.n(j)), rest)
    case False{} False{}:
      f2.keep(f2.direct(0n, False{}, fs, path, base, id, j, m, nm), b, limit, id, U.append(U.b("chain-"), mg.n(j)), rest)

def f2.chain.if(some: Bool, +repair: Bool, +hole: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +j: Nat, +nm: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match some:
    case True{}:
      f2.chain.at(repair, hole, b, limit, base, id, fs, mg.path(id), j, roll(id, 9n, nm), nm, rest)
    case False{}:
      rest

def f2.chain(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  +nm = mutant.count(fs)
  +nix = mg.is.nix(fs)
  +repair = Bool.and(Nat.is_lt(1n, nm), Bool.or(nix, Nat.is_lt(roll(id, 12n, 100n), 30n)))
  +r = roll(id, 11n, 100n)
  +want = Bool.pick(Nat, Nat.is_lt(r, 55n), 1n, Bool.pick(Nat, Nat.is_lt(r, 85n), 2n, 3n))
  +left = Bool.pick(Nat, repair, Nat.sub(nm, 1n), nm)
  +j = Nat.min(want, Nat.min(left, Nat.sub(chain.k(), 1n)))
  +hole = Bool.and(Bool.not(empty(field(fs, 13n))), Nat.is_lt(roll(id, 14n, 100n), 50n))
  f2.chain.if(Bool.and(Nat.is_lt(0n, j), Bool.or(repair, Bool.not(nix))), repair, hole, b, limit, base, id, fs, j, nm, rest)

# a fix of x (0 repeat, 1 give-up, 2 miss) from start s (0 direct, 1 fill, 2 repair; 3 none)
def f2.fix.at(s: Nat, +x: Nat, +name: String, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +j: Nat, +m: Nat, +nm: Nat, rest: List<&2, Mg>) -> List<&2, Mg>:
  match s:
    case 0n:
      +miss = Nat.is_eq(x, 2n)
      +jn = Bool.pick(List<&2, U32>, miss, U.b("-direct"), U.append(U.b("-"), mg.n(j)))
      f2.keep(f2.direct(Bool.pick(Nat, Nat.is_eq(x, 1n), 1n, 0n), miss, fs, mg.path(id), base, id, Bool.pick(Nat, miss, 0n, j), m, nm), b, limit, id, cat([U.b("fix-"), U.b(name), jn]), rest)
    case 1n:
      +miss = Nat.is_eq(x, 2n)
      +jn = Bool.pick(List<&2, U32>, miss, Nil{}, U.append(U.b("-"), mg.n(j)))
      f2.keep(f2.fill(Bool.pick(Nat, Nat.is_eq(x, 1n), 1n, 0n), miss, fs, mg.path(id), base, Bool.pick(Nat, miss, 0n, j), m, nm), b, limit, id, cat([U.b("fix-"), U.b(name), U.b("-fill"), jn]), rest)
    case 2n:
      +miss = Nat.is_eq(x, 2n)
      +jn = Bool.pick(List<&2, U32>, miss, U.append(U.b("-"), mg.n(m)), U.append(U.b("-"), mg.n(j)))
      f2.keep(f2.repair(miss, fs, mg.path(id), base, m, Bool.pick(Nat, miss, 0n, j), nm), b, limit, id, cat([U.b("fix-"), U.b(name), U.b("-repair"), jn]), rest)
    case _:
      rest

# a unit's fixes, by its hash as format mugen's mg.fix.unit: a miss (direct,
# fill or repair), a repeat after 1, 2 or 3 wrong tries (30/40/30; from the
# direct ask after 2 or more), and for half the units with two mutants or
# more and a failing hole a give-up after 2 or 3 (from the direct ask or the fill)
def f2.fix(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  +nm = mutant.count(fs)
  +d = Bool.not(mg.is.nix(fs))
  +f = Bool.and(d, Bool.not(empty(field(fs, 13n))))
  +m = roll(id, 9n, nm)
  +ms = mg.start(roll(id, 15n, 3n), d, f, Nat.is_lt(0n, nm))
  +r = roll(id, 17n, 100n)
  +want = Bool.pick(Nat, Nat.is_lt(r, 30n), 1n, Bool.pick(Nat, Nat.is_lt(r, 70n), 2n, 3n))
  +ss = mg.start(roll(id, 16n, 3n), Bool.and(d, Nat.is_lt(1n, nm)), f, Nat.is_lt(1n, nm))
  +left = Bool.pick(Nat, Nat.is_eq(ss, 2n), Nat.sub(nm, 1n), nm)
  +js = Nat.min(Nat.min(left, Nat.sub(chain.k(), 1n)), Bool.pick(Nat, Nat.is_eq(ss, 0n), Nat.max(want, 2n), want))
  +gj = Nat.min(nm, Bool.pick(Nat, Nat.is_eq(roll(id, 19n, 2n), 0n), 2n, 3n))
  +give = Bool.and(Bool.and(Nat.is_lt(1n, nm), Nat.is_lt(roll(id, 18n, 100n), 50n)), Bool.and(Bool.or(d, f), f2.can.give(fs)))
  +gs = Bool.pick(Nat, give, mg.start(roll(id, 20n, 2n), d, f, False{}), 3n)
  f2.fix.at(ms, 2n, "miss", b, limit, base, id, fs, 0n, m, nm,
    f2.fix.at(Bool.pick(Nat, Nat.is_lt(0n, js), ss, 3n), 0n, "repeat", b, limit, base, id, fs, js, m, nm,
      f2.fix.at(gs, 1n, "giveup", b, limit, base, id, fs, gj, m, nm, rest)))

# Ana's own nights in form 2: her Terms as writes of the declaration (an add
# first), each with its check, the last the original unless hers was (nt.right)
def f2.nt.writes(ns: List<&2, Nt>, +first: Bool, +fs: List<&2, List<&2, U32>>, +path: List<&2, U32>) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case Nt{+b, +c} <> t:
      U.append(f2.write(f2.lab(first), f2.said(first), fs, path, b, f2.out(fs, path, c)), f2.nt.writes(t, False{}, fs, path))

def f2.nt.session(+fs: List<&2, List<&2, U32>>, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +ns: List<&2, Nt>) -> List<&2, U32>:
  cat([mg.user(mg.ask.direct(fs, path)), f2.read.tail(fs, path), f2.looks.new(fs, path, base), f2.nt.writes(ns, True{}, fs, path),
    mg.reply(f2.done.direct(fs, path))])

def f2.nt.r(r: Nr, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +sh: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match r:
    case Nr{+ns, +sw}:
      +j = Nat.sub(List.length(&2, Nt, ns), 1n)
      +ok = Bool.and(nt.last.passed(ns), Bool.not(Bool.and(sw, Nat.is_eq(j, 0n))))
      mg.one.keep(ok, b, limit, id, nt.shape(sh, j), f2.nt.session(fs, mg.path(id), base, ns), rest)

def f2.nt.on(some: Bool, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +v: List<&2, U32>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match some:
    case True{}:
      +k = U.find(v, [0], 0n)
      +ns = nt.uniq(nt.of(A.ag.blocks(10, A.ag.hds.bytes(), List.drop(&2, U32, v, 1n+k))), Nil{})
      f2.nt.r(nt.right(ns, field(fs, 7n), field(fs, 11n)), b, limit, base, id, fs, List.take(&2, U32, v, k), rest)
    case False{}:
      rest

# which: 0 every shape, 1 the chain, 2 the fixes, 3 all three, 5 the repairs only (a history stream's)
def f2.of(+which: Nat, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match which:
    case 0n:
      f2.unit(b, limit, base, id, fs, rest)
    case 1n:
      f2.chain(b, limit, base, id, fs, rest)
    case 2n:
      f2.fix(b, limit, base, id, fs, rest)
    case 5n:
      f2.repairs(mutant.count(fs), b, limit, base, id, fs, mg.path(id), 0n, mutant.count(fs), rest)
    case _:
      f2.unit(b, limit, base, id, fs, f2.chain(b, limit, base, id, fs, f2.fix(b, limit, base, id, fs, rest)))

def f2.of.if(ok: Bool, +which: Nat, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, rest: List<&2, Mg>) -> List<&2, Mg>:
  match ok:
    case True{}:
      f2.of(which, b, limit, base, id, fs, rest)
    case False{}:
      rest

# (a unit past 512 KB gives none, as the fixes: a look splits its head)
def f2.all(+which: Nat, +b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      +fs = split(t, 30)
      f2.of.if(Bool.and(mg.small(fs), Nat.is_lt(U.len(t), 524288n)), which, b, limit, base, i, fs, f2.all(which, b, limit, base, more))

def f2.all.night(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +night: Map<&2, List<&2, U32>>, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match rs:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> more:
      +v = mg.got(Map.get(List<&2, U32>, Nil{}, night, mg.str(i)))
      f2.nt.on(Bool.not(empty(v)), b, limit, base, i, split(t, 30), v, f2.all.night(b, limit, base, night, more))

# MUGEN_ONLY's form 2 modes: form2, form2-chain, form2-fix, form2-all (which 0-3), form2-night (4),
# form2-repair (5)
def f2.which(+only: String) -> Nat:
  Bool.pick(Nat, String.eq(only, "form2-chain"), 1n, Bool.pick(Nat, String.eq(only, "form2-fix"), 2n,
    Bool.pick(Nat, String.eq(only, "form2-all"), 3n, Bool.pick(Nat, String.eq(only, "form2-night"), 4n,
      Bool.pick(Nat, String.eq(only, "form2-repair"), 5n, 0n)))))

def f2.is(+only: String) -> Bool:
  String.starts_with(only, "form2")

def f2.render.on(night: Bool, +which: Nat, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match night:
    case True{}:
      f2.all.night(b, limit, Mgc.base(cf), Mgc.night(cf), rs)
    case False{}:
      f2.all(which, b, limit, Mgc.base(cf), rs)

def f2.render(+only: String, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  f2.render.on(Nat.is_eq(f2.which(only), 4n), f2.which(only), b, limit, cf, rs)

# the units a render takes: the chains, the night's, the fixes, or every shape
def mg.all.on(chain: Bool, night: Bool, fix: Bool, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match chain night fix:
    case True{} _ _:
      mg.all.chain(b, limit, Mgc.base(cf), rs)
    case False{} True{} _:
      mg.all.night(b, limit, Mgc.base(cf), Mgc.night(cf), rs)
    case False{} False{} True{}:
      mg.all.fix(b, limit, Mgc.base(cf), rs)
    case False{} False{} False{}:
      mg.all(b, limit, Mgc.base(cf), rs)

def mg.all.f2(form2: Bool, +only: String, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  match form2:
    case True{}:
      f2.render(only, b, limit, cf, rs)
    case False{}:
      mg.all.on(String.eq(only, "chain"), String.eq(only, "night"), String.eq(only, "fix"), b, limit, cf, rs)

def mg.all.of(+only: String, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, rs: List<&2, Ns.Doc>) -> List<&2, Mg>:
  mg.all.f2(f2.is(only), only, b, limit, cf, rs)

def mg.docs(ms: List<&2, Mg>) -> List<&2, Ns.Doc>:
  match ms:
    case Nil{}:
      Nil{}
    case Mg{d, l, True{}} <> t:
      d <> mg.docs(t)
    case Mg{d, l, False{}} <> t:
      mg.docs(t)

def mg.seg.go(xs: List<&2, U32>, +cur: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      List.reverse(&2, U32, cur)
    case +h <> t:
      mg.seg.go(t, Bool.pick(List<&2, U32>, U32.is_eq(h, 47), Nil{}, h <> cur))

# a presentation's shape: its id after the last /
def mg.shape.of(+id: List<&2, U32>) -> List<&2, U32>:
  mg.seg.go(id, Nil{})

def mg.only.ok(+only: String, +id: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(String.is_empty(only), f2.is(only)), S.prefix(mg.shape.of(id), S.b("mugen-" ++ only)))

# the presentations MUGEN_ONLY keeps
def mg.docs.only(+only: String, ds: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match ds:
    case Nil{}:
      Nil{}
    case Ns.Doc{+i, +t} <> rest:
      +r = mg.docs.only(only, rest)
      Bool.pick(List<&2, Ns.Doc>, mg.only.ok(only, i), Ns.Doc{i, t} <> r, r)

def mg.lines(ms: List<&2, Mg>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      Nil{}
    case Mg{d, l, f} <> t:
      U.append(l, mg.lines(t))

# BASE's lines: NAME TAB LINE, those whose LINE opens a def, law or type
def mg.base.put(ok: Bool, m: Map<&2, List<&2, U32>>, +k: List<&2, U32>, +v: List<&2, U32>) -> Map<&2, List<&2, U32>>:
  match ok:
    case True{}:
      Map.set(&2, List<&2, U32>, m, mg.str(k), v)
    case False{}:
      m

def mg.base.of(ls: List<&2, List<&2, U32>>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      m
    case +l <> more:
      +v = mg.after(l, 9)
      +ok = Bool.or(Bool.or(U.prefix(v, U.b("def ")), U.prefix(v, U.b("law "))), U.prefix(v, U.b("type ")))
      mg.base.of(more, mg.base.put(ok, m, mg.upto(l, 9), v))

def mg.base.read.on(none: Bool, +p: String) -> IO(List<&2, U32>):
  match none:
    case True{}:
      IO.pure(List<&2, U32>, Nil{})
    case False{}:
      S.read(p)

def mg.cfg(+bx: List<&2, U32>, +sizes: String) -> Mgc:
  Mgc{mg.base.of(split(bx, 10), Map.new(&2, List<&2, U32>)), sizes, "", Map.new(&2, List<&2, U32>)}

def mg.cfg.only(+bx: List<&2, U32>, +sizes: String, +only: String) -> Mgc:
  Mgc{mg.base.of(split(bx, 10), Map.new(&2, List<&2, U32>)), sizes, only, Map.new(&2, List<&2, U32>)}

# NIGHT's pairs (id NUL text NUL ...) by unit: the id less its last segment
def mg.night.of(xs: List<&2, List<&2, U32>>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match xs:
    case +i <> +t <> more:
      +sh = mg.shape.of(i)
      +u = List.take(&2, U32, i, Nat.sub(U.len(i), Nat.add(U.len(sh), 1n)))
      mg.night.of(more, Map.set(&2, List<&2, U32>, m, mg.str(u), cat([sh, [0], t])))
    case _:
      m

def mg.cfg.night(+bx: List<&2, U32>, +sizes: String, +only: String, +nx: List<&2, U32>) -> Mgc:
  Mgc{mg.base.of(split(bx, 10), Map.new(&2, List<&2, U32>)), sizes, only, mg.night.of(split(nx, 0), Map.new(&2, List<&2, U32>))}

# Main ---------------------------------------------------------------------------

# The input streams a unit at a time (Sys.Rd: memory is a chunk plus the
# longest field) and renders batch() units at a time, each batch's
# transcripts appended to the output as it is done, so an input of any size
# renders; a unit renders alone, so the output is the whole file's.
def batch() -> Nat:
  1000n

# MUGEN_ONLY=fix renders three sessions a unit, most with three or four copies of
# the file: a thousand units of col9's or a2bum12's went past 3 GB (11-12), so its
# batches are a hundred
def batch.of(+only: String) -> Nat:
  Bool.pick(Nat, Bool.or(String.eq(only, "fix"), f2.is(only)), 100n, batch())

def big() -> Nat:
  U32.to_nat(4294967295)

# A batch being read: the reader, its units (newest first), whether the
# stream ended.
type Bt is Type:
  Bt{rd: S.Rd, us: List<&2, Ns.Doc>, eof: Bool}

def bt.rec(+i: List<&2, U32>, us: List<&2, Ns.Doc>, rd: S.Rd, m: Maybe<&2, List<&2, U32>>) -> IO(Bt):
  match m:
    case None{}:
      do IO<Bt>:
        S.Rd.close(rd)
        IO.die(Bt, 1, "transcript: a unit id without its record")
    case Some{+t}:
      IO.pure(Bt, Bt{rd, Ns.Doc{i, t} <> us, False{}})

def bt.rec.r(+i: List<&2, U32>, us: List<&2, Ns.Doc>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Bt):
  (rd, m) = r
  bt.rec(i, us, rd, m)

def bt.id(us: List<&2, Ns.Doc>, rd: S.Rd, m: Maybe<&2, List<&2, U32>>) -> IO(Bt):
  match m:
    case None{}:
      IO.pure(Bt, Bt{rd, us, True{}})
    case Some{+i}:
      do IO<Bt>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        bt.rec.r(i, us, r)

def bt.id.r(us: List<&2, Ns.Doc>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Bt):
  (rd, m) = r
  bt.id(us, rd, m)

def bt.step(b: Bt) -> IO(Bt):
  match b:
    case Bt{rd, us, e}:
      do IO<Bt>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        bt.id.r(us, r)

# up to fuel more units into the batch, stopping at the end of the stream
def bt.go(fuel: Nat, b: Bt) -> IO(Bt):
  match fuel b:
    case 1n+p Bt{rd, us, False{}}:
      IO.bind(Bt, Bt, bt.step(Bt{rd, us, False{}}), bt.go(p))
    case _ Bt{rd, us, e}:
      IO.pure(Bt, Bt{rd, us, e})

# The pass so far: the reader, units in, transcripts out, whether the
# stream ended.
type Ps is Type:
  Ps{rd: S.Rd, n: Nat, m: Nat, eof: Bool}

# a batch's transcripts (format mugen: also their sizes) written
def ps.write(mugen: Bool, +fmt: Nat, +out: String, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, +rs: List<&2, Ns.Doc>, +n: Nat, +m: Nat, rd: S.Rd, e: Bool) -> IO(Ps):
  match mugen:
    case True{}:
      +ms = mg.all.of(Mgc.only(cf), b, limit, cf, rs)
      +ts = mg.docs.only(Mgc.only(cf), mg.docs(ms))
      do IO<Ps>:
        S.add(out, Ns.put(ts, Nil{}))
        S.add(Mgc.sizes(cf), mg.lines(ms))
        return Ps{rd, Nat.add(n, List.length(&2, Ns.Doc, rs)), Nat.add(m, List.length(&2, Ns.Doc, ts)), e}
    case False{}:
      +ts = all.fmt(fmt, b, limit, rs)
      do IO<Ps>:
        S.add(out, Ns.put(ts, Nil{}))
        return Ps{rd, Nat.add(n, List.length(&2, Ns.Doc, rs)), Nat.add(m, List.length(&2, Ns.Doc, ts)), e}

def ps.batch(+fmt: Nat, +out: String, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, +n: Nat, +m: Nat, bt: Bt) -> IO(Ps):
  match bt:
    case Bt{rd, us, e}:
      ps.write(Nat.is_eq(fmt, mg.fmt()), fmt, out, b, limit, cf, List.reverse(&2, Ns.Doc, us), n, m, rd, e)

def ps.step(+fmt: Nat, +out: String, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, p: Ps) -> IO(Ps):
  match p:
    case Ps{rd, +n, +m, e}:
      do IO<Ps>:
        bt : Bt <- bt.go(batch.of(Mgc.only(cf)), Bt{rd, Nil{}, False{}})
        ps.batch(fmt, out, b, limit, cf, n, m, bt)

# batches until the stream ends
def ps.go(fuel: Nat, +fmt: Nat, +out: String, +b: Tk.Bpe, +limit: Nat, +cf: Mgc, p: Ps) -> IO(Ps):
  match fuel p:
    case 1n+q Ps{rd, n, m, False{}}:
      IO.bind(Ps, Ps, ps.step(fmt, out, b, limit, cf, Ps{rd, n, m, False{}}), ps.go(q, fmt, out, b, limit, cf))
    case _ Ps{rd, n, m, e}:
      IO.pure(Ps, Ps{rd, n, m, e})

def done(p: Ps) -> IO(Unit):
  match p:
    case Ps{rd, +n, +m, True{}}:
      do IO<Unit>:
        S.Rd.close(rd)
        IO.print("transcript: " ++ Nat.show(n) ++ " units in, " ++ Nat.show(m) ++ " transcripts out")
    case Ps{rd, n, m, False{}}:
      do IO<Unit>:
        S.Rd.close(rd)
        IO.die(Unit, 1, "transcript: out of fuel before the input ended (a bug)")

# BASE for format mugen: `bend-transcript base RESULTS.nul BASE [BEND]` runs
# `BEND base NAME` (BEND: bend) once for each name a Bend unit's body uses
# that its head does not define, and writes NAME, a tab, its output's first
# line, a line each (the renderer keeps those that open a def, law or type:
# Check/Bend.bend's Context, which they must give back)

type Sn is Data:
  Sn{seen: Map<&2, Unit>, names: List<&2, String>}

def sn.add.on(had: Bool, m: Map<&2, Unit>, +k: String, ns: List<&2, String>) -> Sn:
  match had:
    case True{}:
      Sn{m, ns}
    case False{}:
      Sn{Map.set(&2, Unit, m, k, Unit{}), k <> ns}

def sn.add.got(r: Map<&2, Unit> & Bool, +k: String, ns: List<&2, String>) -> Sn:
  match r:
    case (m, b):
      sn.add.on(b, m, k, ns)

def sn.add(xs: List<&2, List<&2, U32>>, s: Sn) -> Sn:
  match xs s:
    case +x <> t Sn{m, ns}:
      +k = S.str(x)
      sn.add(t, sn.add.got(Map.has(&2, Unit, m, k), k, ns))
    case _ s:
      s

def sn.unit(bend: Bool, +fs: List<&2, List<&2, U32>>, s: Sn) -> Sn:
  match bend:
    case True{}:
      sn.add(mg.keep(mg.words(field(fs, 9n)), split(field(fs, 5n), 10), False{}), s)
    case False{}:
      s

def sn.docs(ds: List<&2, Ns.Doc>, s: Sn) -> Sn:
  match ds:
    case Nil{}:
      s
    case Ns.Doc{i, +t} <> more:
      +fs = split(t, 30)
      sn.docs(more, sn.unit(U.eq(field(fs, 0n), U.b("bend")), fs, s))

type Bn is Type:
  Bn{rd: S.Rd, s: Sn, eof: Bool}

def bn.of(bt: Bt, s: Sn) -> Bn:
  match bt:
    case Bt{rd, us, e}:
      Bn{rd, sn.docs(List.reverse(&2, Ns.Doc, us), s), e}

def bn.step(b: Bn) -> IO(Bn):
  match b:
    case Bn{rd, s, e}:
      do IO<Bn>:
        bt : Bt <- bt.go(batch(), Bt{rd, Nil{}, False{}})
        return bn.of(bt, s)

def bn.go(fuel: Nat, b: Bn) -> IO(Bn):
  match fuel b:
    case 1n+q Bn{rd, s, False{}}:
      IO.bind(Bn, Bn, bn.step(Bn{rd, s, False{}}), bn.go(q))
    case _ Bn{rd, s, e}:
      IO.pure(Bn, Bn{rd, s, e})

def bn.look(ns: List<&2, String>, +bend: String, +out: String, +k: Nat) -> IO(Nat):
  match ns:
    case Nil{}:
      IO.pure(Nat, k)
    case +n <> t:
      do IO<Nat>:
        +o : S.Out <- S.run.quiet(".", [], 60, bend, ["base", n], Nil{})
        S.add(out, cat([U.b(n), [9], S.lines.first(S.Out.text(o)), nl()]))
        bn.look(t, bend, out, 1n+k)

def bn.done(b: Bn, +bend: String, +out: String) -> IO(Unit):
  match b:
    case Bn{rd, Sn{m, ns}, e}:
      do IO<Unit>:
        S.Rd.close(rd)
        S.write(out, Nil{})
        +k : Nat <- bn.look(List.reverse(&2, String, ns), bend, out, 0n)
        IO.print("transcript base: " ++ Nat.show(k) ++ " names")

def base.run(inp: String, +out: String, +bend: String) -> IO(Unit):
  do IO<Unit>:
    rd : S.Rd <- S.Rd.open(inp)
    b : Bn <- bn.go(big(), Bn{rd, Sn{Map.new(&2, Unit), Nil{}}, False{}})
    bn.done(b, bend, out)

def tokenizer(+fmt: Nat, +inp: String, +out: String, +limit: Nat, +cf: Mgc, m: Maybe<&2, Tk.Bpe>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "transcript: the tokenizer did not parse")
    case Some{+b}:
      do IO<Unit>:
        rd : S.Rd <- S.Rd.open(inp)
        S.write(out, Nil{})
        S.write(Mgc.sizes(cf), Nil{})
        p : Ps <- ps.go(big(), fmt, out, b, limit, cf, Ps{rd, 0n, 0n, False{}})
        done(p)

# TRANSCRIPT_FORMAT (1, 2, chain or mugen) and, for format 2, COPIES (2, at least 1):
# all.fmt's fmt
def fmt.of(+f: String, +k: Nat) -> Nat:
  Bool.pick(Nat, String.eq(f, "mugen"), mg.fmt(), Bool.pick(Nat, String.eq(f, "chain"), chain.fmt(), Bool.pick(Nat, String.eq(f, "2"), Bool.pick(Nat, Nat.is_eq(Nat.min(k, 998n), 0n), 1n, Nat.min(k, 998n)), 0n)))

def run(tok: String, inp: String, +out: String, +window: Nat) -> IO(Unit):
  do IO<Unit>:
    tx : List<&2, U32> <- B.Bytes.read_all(tok)
    +f : String <- S.env("TRANSCRIPT_FORMAT", "1")
    +k : Nat <- S.env.nat("COPIES", 2n)
    +bp : String <- S.env("BASE", "")
    +sz : String <- S.env("SIZES", "/dev/null")
    +on : String <- S.env("MUGEN_ONLY", "")
    +np : String <- S.env("NIGHT", "")
    bx : List<&2, U32> <- mg.base.read.on(String.eq(bp, ""), bp)
    nx : List<&2, U32> <- mg.base.read.on(String.eq(np, ""), np)
    tokenizer(fmt.of(f, k), inp, out, Nat.sub(window, 64n), mg.cfg.night(bx, sz, on, nx), Tk.Bpe.parse(tx))

def window.of(xs: List<String>) -> Nat:
  match xs:
    case Nil{}:
      2048n
    case x <> t:
      Maybe.default(&2, Nat, Nat.read(x), 2048n)

def args.base(xs: List<String>) -> IO(Unit):
  match xs:
    case b <> inp <> out <> Nil{}:
      base.run(inp, out, "bend")
    case b <> inp <> out <> bend <> more:
      base.run(inp, out, bend)
    case _:
      IO.die(Unit, 2, "usage: bend-transcript base RESULTS.nul BASE [BEND]")

def args.go(base: Bool, xs: List<String>) -> IO(Unit):
  match base xs:
    case True{} xs:
      args.base(xs)
    case False{} tok <> inp <> out <> more:
      run(tok, inp, out, window.of(more))
    case _ _:
      IO.die(Unit, 2, "usage: bend-transcript TOKENIZER RESULTS.nul OUTPUT.nul [WINDOW], or bend-transcript base RESULTS.nul BASE [BEND]")

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case +x <> t:
      args.go(String.eq(x, "base"), x <> t)
    case Nil{}:
      args.go(False{}, Nil{})

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked (Bend 2.0.32)
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    args(xs)
