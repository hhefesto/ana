import Base

# The meaning of ana's episodes (docs/AGENT.md).
#
# An episode is a list of turns; a turn is a text and who wrote it, its role:
#
#   RoUser     the task's words                      `## User`
#   RoGiven    what the task hands ana: its context, `## Context`, a given `## Type`
#              a given type or term, any text         or `## Term`, the text before
#              before the first turn                  the first turn
#   RoAttempt  a term handed to ana as wrong or       `## Attempt`
#              partial
#   RoAct      ana's answer                           the last `## Term` or `## Type`
#                                                     after any Attempt
#   RoCall     ana calling a tool                     the tool's line: `## ghc` ...
#   RoEcho     the tool's answer                      the fenced output after the line
#
# A tool is a function of the episode so far, so the probability of an
# episode under ana (parameters θ) factors as
#
#   P(τ) = Π_{act, call} π_θ(turn | prefix)
#        · Π_{echo} [turn = tool(prefix)]
#        · Π_{user, given, attempt} D(turn | prefix)
#
# and only the first product depends on θ: the gradient of ana's likelihood
# is a sum over ana's own turns.  Fitting an echo is fitting the tool (run 1
# learned to write ghc's errors that way, docs/CORPUS-V2.md); ana never
# writes one, at training or at inference.  `weight` says so: 1 on act and
# call, 0 on echo.  User and given text keep 1 as plain language modelling
# (real asks and real code, the raw corpus's kind of text); an attempt is 0
# (code handed over as wrong).
#
# The loop (bend/Agent.bend) refines `unfold`: ana is sampled, the tool is
# Process.run, the episode is the log.  Training (bend/Mask.bend) reads the
# roles back from a window's tokens with the same `read` this module reads
# bytes with: the reader is defined over any alphabet of U32 symbols (bytes,
# or token ids) given its newline symbol and its heading strings, and the
# laws in bend/tests/agent.bend hold the token reading to the byte reading.

type Role is Data:
  RoUser{}
  RoGiven{}
  RoAttempt{}
  RoAct{}
  RoCall{}
  RoEcho{}

type Turn is Data:
  Turn{role: Role, text: List<&2, U32>}

def ag.role.code(+r: Role) -> Nat:
  match r:
    case RoUser{}:
      0n
    case RoGiven{}:
      1n
    case RoAttempt{}:
      2n
    case RoAct{}:
      3n
    case RoCall{}:
      4n
    case RoEcho{}:
      5n

def ag.role.eq(+a: Role, +b: Role) -> Bool:
  Nat.is_eq(ag.role.code(a), ag.role.code(b))

def ag.role.name(+r: Role) -> String:
  match r:
    case RoUser{}:
      "user"
    case RoGiven{}:
      "given"
    case RoAttempt{}:
      "attempt"
    case RoAct{}:
      "act"
    case RoCall{}:
      "call"
    case RoEcho{}:
      "echo"

# the training weight of a token of this role
def ag.weight(+r: Role) -> F32:
  match r:
    case RoAttempt{}:
      0.0
    case RoEcho{}:
      0.0
    case _:
      1.0

def ag.turn.role(+t: Turn) -> Role:
  match t:
    case Turn{r, x}:
      r

def ag.turn.text(+t: Turn) -> List<&2, U32>:
  match t:
    case Turn{r, x}:
      x

# Episodes -------------------------------------------------------------------

# the episode's text: its turns in order
def ag.render(e: List<&2, Turn>) -> List<&2, U32>:
  match e:
    case Nil{}:
      Nil{}
    case Turn{r, x} <> t:
      List.append(&2, U32, x, ag.render(t))

# each symbol's role
def ag.roles(e: List<&2, Turn>) -> List<&2, Role>:
  match e:
    case Nil{}:
      Nil{}
    case Turn{+r, +x} <> t:
      List.append(&2, Role, List.replicate(Role, List.length(&2, U32, x), r), ag.roles(t))

# each symbol's weight
def ag.weights(e: List<&2, Turn>) -> List<&2, F32>:
  match e:
    case Nil{}:
      Nil{}
    case Turn{+r, +x} <> t:
      List.append(&2, F32, List.replicate(F32, List.length(&2, U32, x), ag.weight(r)), ag.weights(t))

# whether the episode's last turn is a call (the tool answers next)
def ag.calls.last(+e: List<&2, Turn>) -> Bool:
  match e:
    case Nil{}:
      False{}
    case Turn{r, x} <> Nil{}:
      ag.role.eq(r, RoCall{})
    case h <> t:
      ag.calls.last(t)

def ag.unfold.go(~ana: List<&2, Turn> -> List<&2, Turn>, ~tool: List<&2, Turn> -> List<&2, U32>, fuel: Nat, +e: List<&2, Turn>, called: Bool) -> List<&2, Turn>:
  match fuel called:
    case 1n+p True{}:
      +e2 = List.append(&2, Turn, e, [Turn{RoEcho{}, tool(e)}])
      +e3 = List.append(&2, Turn, e2, ana(e2))
      ag.unfold.go(~ana, ~tool, p, e3, ag.calls.last(e3))
    case _ _:
      e

# The loop: ana's turns after the task; while ana's last turn is a call, the
# tool's answer to the episode so far (always an echo: the tool writes it)
# and ana's next turns; at most `fuel` tool answers.
def ag.unfold(~ana: List<&2, Turn> -> List<&2, Turn>, ~tool: List<&2, Turn> -> List<&2, U32>, fuel: Nat, +e: List<&2, Turn>) -> List<&2, Turn>:
  +e1 = List.append(&2, Turn, e, ana(e))
  ag.unfold.go(~ana, ~tool, fuel, e1, ag.calls.last(e1))

# Reading the roles back from text -------------------------------------------
#
# A turn starts at a heading line, `## LABEL` and a newline, that opens the
# text or follows an empty line (format 2 puts one before every turn).  The
# label gives the role: User; Context (given); Attempt; Term and Type (the
# answer, act, when it is the last of them after any Attempt, else given);
# a tool's name (the heading line is the call, the rest of the turn the
# echo).  Text before the first heading is given.  The reader works on any
# alphabet: `nl` is the newline symbol, each heading a symbol string ending
# with it.

type Hd is Data:
  Hd{syms: List<&2, U32>, cls: Nat}

# heading classes
#   1 User, 2 Context, 3 Attempt, 4 Term or Type, 5 a tool; 0 not a heading
def ag.ascii(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      c <> ag.ascii(t)

# a label's heading line, as bytes
def ag.hd(+label: String, +k: Nat) -> Hd:
  Hd{List.append(&2, U32, ag.ascii("## " ++ label), [10]), k}

# the headings as bytes
def ag.hds.bytes() -> List<&2, Hd>:
  [ag.hd("User", 1n), ag.hd("Context", 2n), ag.hd("Attempt", 3n), ag.hd("Term", 4n), ag.hd("Type", 4n),
   ag.hd("ghc", 5n), ag.hd("agda", 5n), ag.hd("lean", 5n), ag.hd("bend", 5n), ag.hd("nix", 5n)]

def ag.eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case a <> s c <> t:
      Bool.and(U32.is_eq(a, c), ag.eq(s, t))
    case _ _:
      False{}

def ag.prefix(xs: List<&2, U32>, p: List<&2, U32>) -> Bool:
  match xs p:
    case _ Nil{}:
      True{}
    case a <> s c <> t:
      Bool.and(U32.is_eq(a, c), ag.prefix(s, t))
    case _ _:
      False{}

def ag.head.is(+xs: List<&2, U32>, +c: U32) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, c)
    case Nil{}:
      False{}

def ag.close(cur: List<&2, U32>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match cur:
    case Nil{}:
      acc
    case h <> t:
      List.reverse(&2, U32, h <> t) <> acc

# the lines, each with its newline (the last may lack one)
def ag.lines.go(xs: List<&2, U32>, +nl: U32, cur: List<&2, U32>, acc: List<&2, List<&2, U32>>, at: Bool) -> List<&2, List<&2, U32>>:
  match xs at:
    case Nil{} _:
      List.reverse(&2, List<&2, U32>, ag.close(cur, acc))
    case h <> +t True{}:
      ag.lines.go(t, nl, Nil{}, List.reverse(&2, U32, h <> cur) <> acc, ag.head.is(t, nl))
    case h <> +t False{}:
      ag.lines.go(t, nl, h <> cur, acc, ag.head.is(t, nl))

def ag.lines(+nl: U32, +xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  ag.lines.go(xs, nl, Nil{}, Nil{}, ag.head.is(xs, nl))

# the heading class of a line
def ag.class(hs: List<&2, Hd>, +l: List<&2, U32>) -> Nat:
  match hs:
    case Nil{}:
      0n
    case Hd{x, k} <> t:
      Bool.pick(Nat, ag.eq(x, l), k, ag.class(t, l))

def ag.empty.line(+nl: U32, +l: List<&2, U32>) -> Bool:
  ag.eq(l, [nl])

# the class of the first line when it opens a turn (it follows an empty
# line or opens the text), else 0
def ag.start(+hs: List<&2, Hd>, +pe: Bool, +ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      Bool.pick(Nat, pe, ag.class(hs, l), 0n)

type Blk is Data:
  Blk{cls: Nat, text: List<&2, U32>}

def ag.push(+k: Nat, cur: List<&2, List<&2, U32>>, acc: List<&2, Blk>) -> List<&2, Blk>:
  match cur:
    case Nil{}:
      acc
    case h <> t:
      Blk{k, List.concat(&2, U32, List.reverse(&2, List<&2, U32>, h <> t))} <> acc

def ag.blocks.go(ls: List<&2, List<&2, U32>>, +nl: U32, +hs: List<&2, Hd>, +k: Nat, cur: List<&2, List<&2, U32>>, acc: List<&2, Blk>, +c: Nat) -> List<&2, Blk>:
  match ls c:
    case Nil{} _:
      List.reverse(&2, Blk, ag.push(k, cur, acc))
    case +l <> +t 0n:
      ag.blocks.go(t, nl, hs, k, l <> cur, acc, ag.start(hs, ag.empty.line(nl, l), t))
    case +l <> +t _:
      ag.blocks.go(t, nl, hs, c, [l], ag.push(k, cur, acc), ag.start(hs, ag.empty.line(nl, l), t))

# the text cut at its turn headings, each block with its heading's class
def ag.blocks(+nl: U32, +hs: List<&2, Hd>, +xs: List<&2, U32>) -> List<&2, Blk>:
  +ls = ag.lines(nl, xs)
  ag.blocks.go(ls, nl, hs, 0n, Nil{}, Nil{}, ag.start(hs, True{}, ls))

# 1 + the index of the last block of class k (0: none)
def ag.last(bs: List<&2, Blk>, +k: Nat, +i: Nat, +best: Nat) -> Nat:
  match bs:
    case Nil{}:
      best
    case Blk{c, x} <> t:
      ag.last(t, k, 1n+i, Bool.pick(Nat, Nat.is_eq(c, k), 1n+i, best))

# 1 + the index of the answer: the last Term or Type after the last Attempt
def ag.answer(bs: List<&2, Blk>, +la: Nat, +i: Nat, +best: Nat) -> Nat:
  match bs:
    case Nil{}:
      best
    case Blk{c, x} <> t:
      ag.answer(t, la, 1n+i, Bool.pick(Nat, Bool.and(Nat.is_eq(c, 4n), Nat.is_lt(la, 1n+i)), 1n+i, best))

# the first line and the rest
def ag.line1(+nl: U32, +xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, nl), [h], h <> ag.line1(nl, t))

def ag.after1(+nl: U32, +xs: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, xs, List.length(&2, U32, ag.line1(nl, xs)))

def ag.nonempty(+r: Role, +x: List<&2, U32>, rest: List<&2, Turn>) -> List<&2, Turn>:
  match x:
    case Nil{}:
      rest
    case h <> t:
      Turn{r, h <> t} <> rest

# a block's turns
def ag.turns.blk(+nl: U32, +c: Nat, +act: Bool, +x: List<&2, U32>, rest: List<&2, Turn>) -> List<&2, Turn>:
  match c:
    case 1n:
      Turn{RoUser{}, x} <> rest
    case 3n:
      Turn{RoAttempt{}, x} <> rest
    case 4n:
      Turn{Bool.pick(Role, act, RoAct{}, RoGiven{}), x} <> rest
    case 5n:
      Turn{RoCall{}, ag.line1(nl, x)} <> ag.nonempty(RoEcho{}, ag.after1(nl, x), rest)
    case _:
      Turn{RoGiven{}, x} <> rest

def ag.turns.go(bs: List<&2, Blk>, +nl: U32, +act: Nat, +i: Nat) -> List<&2, Turn>:
  match bs:
    case Nil{}:
      Nil{}
    case Blk{+c, +x} <> t:
      ag.turns.blk(nl, c, Nat.is_eq(act, 1n+i), x, ag.turns.go(t, nl, act, 1n+i))

# the episode a text denotes, over the alphabet (nl, hs)
def ag.read(+nl: U32, +hs: List<&2, Hd>, +xs: List<&2, U32>) -> List<&2, Turn>:
  +bs = ag.blocks(nl, hs, xs)
  ag.turns.go(bs, nl, ag.answer(bs, ag.last(bs, 3n, 0n, 0n), 0n, 0n), 0n)

# ... over bytes
def ag.read.bytes(+xs: List<&2, U32>) -> List<&2, Turn>:
  ag.read(10, ag.hds.bytes(), xs)

# Laws -----------------------------------------------------------------------

# reading cuts a text into turns, never changes it
def ag.law.roundtrip(+nl: U32, +hs: List<&2, Hd>, +xs: List<&2, U32>) -> Bool:
  ag.eq(ag.render(ag.read(nl, hs, xs)), xs)

def ag.law.calls.go(e: List<&2, Turn>, +prev: Nat) -> Bool:
  match e:
    case Nil{}:
      True{}
    case Turn{+r, x} <> t:
      +c = ag.role.code(r)
      +eok = Bool.pick(Bool, Nat.is_eq(c, 5n), Nat.is_eq(prev, 4n), True{})
      +cok = Bool.pick(Bool, Nat.is_eq(prev, 4n), Nat.is_eq(c, 5n), True{})
      Bool.and(Bool.and(eok, cok), ag.law.calls.go(t, c))

# every echo answers a call, and every call is answered (or ends the
# episode: the harness's stop)
def ag.law.calls(+e: List<&2, Turn>) -> Bool:
  ag.law.calls.go(e, 9n)

def ag.count(e: List<&2, Turn>, +code: Nat) -> Nat:
  match e:
    case Nil{}:
      0n
    case Turn{r, x} <> t:
      Nat.add(Bool.pick(Nat, Nat.is_eq(ag.role.code(r), code), 1n, 0n), ag.count(t, code))

# The echo -------------------------------------------------------------------
#
# A tool's turn as the transcripts render it (Transcript.bend `checker`):
# `## TOOL`, an empty line, then a fence holding the output (leading
# newlines, or else a first line's leading blanks, and all trailing
# whitespace trimmed; at most 40 lines, then `[N more lines]`) and the exit
# line `[exit STATUS]` (none for an interactive session's `-`).  The call is
# the heading line; the echo is the rest: `ag.echo`.  A check is STATUS,
# the byte 0x1F, then the output.  bend-agent-laws holds `ag.echo` to
# Transcript.bend's `checker` on every check of the corpus.

def ag.is.blank(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 10), U32.is_eq(c, 13)))

def ag.head.blank(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      ag.is.blank(h)
    case Nil{}:
      False{}

# whether the head is to drop: a newline (nl), else a blank that is not one
def ag.drop.head(+xs: List<&2, U32>, +nl: Bool) -> Bool:
  match xs:
    case h <> t:
      Bool.pick(Bool, nl, U32.is_eq(h, 10), Bool.and(ag.is.blank(h), Bool.not(U32.is_eq(h, 10))))
    case Nil{}:
      False{}

def ag.drop.go(+xs: List<&2, U32>, +nl: Bool, go: Bool) -> List<&2, U32>:
  match xs go:
    case h <> +t True{}:
      ag.drop.go(t, nl, ag.drop.head(t, nl))
    case _ _:
      xs

# leading newlines, or else the first line's leading blanks
def ag.lead.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  +nl = ag.head.is(xs, 10)
  ag.drop.go(xs, nl, ag.drop.head(xs, nl))

def ag.drop.blank(+xs: List<&2, U32>, go: Bool) -> List<&2, U32>:
  match xs go:
    case h <> +t True{}:
      ag.drop.blank(t, ag.head.blank(t))
    case _ _:
      xs

def ag.trim.right(+xs: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, xs)
  List.reverse(&2, U32, ag.drop.blank(r, ag.head.blank(r)))

def ag.tidy(+xs: List<&2, U32>) -> List<&2, U32>:
  ag.trim.right(ag.lead.trim(xs))

# at most 40 lines, then a line for the rest
def ag.capped(+out: List<&2, U32>) -> List<&2, U32>:
  +ls = ag.lines(10, ag.tidy(out))
  +n = List.length(&2, List<&2, U32>, ls)
  +more = Bool.pick(List<&2, U32>, Nat.is_le(n, 40n), Nil{}, ag.ascii("\n[" ++ Nat.show(Nat.sub(n, 40n)) ++ " more lines]"))
  List.append(&2, U32, ag.trim.right(List.concat(&2, U32, List.take(&2, List<&2, U32>, ls, 40n))), more)

# a check's status (before its first 0x1F) and output (after it)
def ag.before.us(+xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 31), Nil{}, h <> ag.before.us(t))

def ag.after.us(+xs: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, xs, Nat.add(List.length(&2, U32, ag.before.us(xs)), 1n))

# the echo of a check: the tool's turn after its heading line
def ag.echo(+c: List<&2, U32>) -> List<&2, U32>:
  +st = ag.before.us(c)
  +o = ag.capped(ag.after.us(c))
  +body = Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, U32, o), 0n), Nil{}, List.append(&2, U32, o, [10]))
  +ex = Bool.pick(List<&2, U32>, ag.eq(st, [45]), Nil{}, List.append(&2, U32, ag.ascii("[exit "), List.append(&2, U32, st, [93, 10])))
  List.concat(&2, U32, [[10, 96, 96, 96, 10], body, ex, [96, 96, 96, 10, 10]])

# The answer's code --------------------------------------------------------------
#
# What a tool checks: the code inside the fence of the episode's answer (its
# act turn), and of its given Type when there is one: each turn's first
# fence, up to its closing fence (or the turn's end, when ana never closed
# it), every line with its newline.

def ag.fence.open(+l: List<&2, U32>) -> Bool:
  ag.prefix(l, [96, 96, 96])

def ag.fence.close(+l: List<&2, U32>) -> Bool:
  Bool.or(ag.eq(l, [96, 96, 96, 10]), ag.eq(l, [96, 96, 96]))

def ag.inside(ls: List<&2, List<&2, U32>>, in: Bool, +acc: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls in:
    case Nil{} _:
      List.concat(&2, U32, List.reverse(&2, List<&2, U32>, acc))
    case +l <> t False{}:
      ag.inside(t, ag.fence.open(l), acc)
    case +l <> t True{}:
      Bool.pick(List<&2, U32>, ag.fence.close(l), List.concat(&2, U32, List.reverse(&2, List<&2, U32>, acc)), ag.inside(t, True{}, l <> acc))

# a turn's fenced code
def ag.code(+x: List<&2, U32>) -> List<&2, U32>:
  ag.inside(ag.lines(10, x), False{}, Nil{})

# the text of the last turn of role `code` whose text opens with `head`
def ag.last.turn(e: List<&2, Turn>, +code: Nat, +head: List<&2, U32>, +best: List<&2, U32>) -> List<&2, U32>:
  match e:
    case Nil{}:
      best
    case Turn{+r, +x} <> t:
      ag.last.turn(t, code, head, Bool.pick(List<&2, U32>, Bool.and(Nat.is_eq(ag.role.code(r), code), ag.prefix(x, head)), x, best))

def ag.answer.code(+e: List<&2, Turn>) -> List<&2, U32>:
  ag.code(ag.last.turn(e, 3n, Nil{}, Nil{}))

def ag.type.code(+e: List<&2, Turn>) -> List<&2, U32>:
  ag.code(ag.last.turn(e, 1n, ag.ascii("## Type\n"), Nil{}))

# The episode's outcome, read from its text: solved when its last turn is an
# echo whose exit line is `[exit 0]`; its calls, the call turns answered.
def ag.ends.with(+xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  ag.prefix(List.reverse(&2, U32, xs), List.reverse(&2, U32, p))

def ag.last.of(e: List<&2, Turn>, +best: Turn) -> Turn:
  match e:
    case Nil{}:
      best
    case +x <> t:
      ag.last.of(t, x)

def ag.passed(+t: Turn) -> Bool:
  match t:
    case Turn{+r, +x}:
      Bool.and(Nat.is_eq(ag.role.code(r), 5n), ag.ends.with(x, ag.ascii("[exit 0]\n```\n\n")))

def ag.solved(+e: List<&2, Turn>) -> Bool:
  ag.passed(ag.last.of(e, Turn{RoUser{}, Nil{}}))
