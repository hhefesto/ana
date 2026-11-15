import Base
import ../Sys.bend as S
import ../Units.bend as U
import ../Tokenizer.bend as Tk
import ../Bytes.bend as B

# bend-corpus-v2 mugenlog: mugen's own chats as sessions in the mugen shape (docs/MUGEN-SHAPE.md).
#
#   mugenlog TOKENIZER IN OUT [WINDOW]
#       IN: run/v9/mlog/export.sh's pairs (ID = CHAT US SEQ US KIND, then the text; a tool's text its
#       call, fields split by US).  OUT: the sessions that fit the window (tokens + BOS + EOS within
#       WINDOW - 64, WINDOW 2048), as pairs: `mugenlog:KEY#NAME@CHAT.SEQ`, the session.  The counts on
#       stdout.
#
# The user, 11-14: "Add mugen's transcripts to the corpus (should have a lot of bend code)"; 11-15: "Add
# laws where you can".  Which parts (11-15): "Only the turns that write or check Bend, with secrets, emails
# and netsem taken out"; which chats: "mugen's main chat and its 26 agents' chats".
#
# What a session is.  A turn runs from one user message to the next.  In it, a file P is a Bend file one
# of mugen's edit or write calls changed.  P's calls are the reads, edits and writes of P and the shell
# commands that name P's file; the rest of the turn is left out.  They start at P's first edit or write
# (the read of P just before it, if there is one, goes in too) and are cut after each check of P that
# passes (`--check-only`, ALL PROOFS CHECK, no SOME PROOFS FAIL) with an edit or a write before it: each
# piece is a session, so every session ends in a passing check, and its edits before the last are tries
# (Agent/Spec.bend: weight 0).  A piece with no passing check at its end is left out: it would end on a
# program the checker refused.  A pass with no edit before it starts the next piece afresh.
#
# What a session says.  `## user` is written from the first edit's facts, never the user's own words
# (they are about the whole turn, and hold what is private): "Add `A` to `P`." for the definitions it
# adds, "Change `A` in `P`." for the ones it rewrites, "Write `P`." for a write, else "Edit `P`.".  The
# calls as mugen's tools took them: `## read` PATH FROM LIMIT (LIMIT 0: to the end), `## edit` PATH and
# each edit's old lines (`-`) and new (`+`), an empty line between edits, `## write` PATH and the text,
# `## shell` the command; each `## echo` mugen's answer, fenced, a shell's `(exit N)` without its time,
# 40 lines at most (then `[K more lines]`), 300 bytes a line.  `## mugen` is written from the facts: what
# the first edit did, and that the check passes.
#
# Taken out (the user's "secrets, emails and netsem"): a session whose text names netsem, a password,
# sudo, a secret, an API key or token, a private key, agenix, a calendar or a message app, the user's
# family, or holds an email address, is left out whole; /home/hhefesto is written ~.  An edit call
# that also edits another file is left out with its session (its echo is both files' diff).
#
# KEY is the file's validation key (CorpusV2/ValidText.bend): ~/src/REPO/PATH as REPO/PATH (as own:'s
# units), /tmp/X as tmp/X, a relative path as work/PATH.  So the fixed validation split holds a file's
# mugen-log sessions out with the rest of it.
#
# Pure but for the stream; every def starts with `ml.`.

def ml.fuel() -> Nat:
  U32.to_nat(4294967295)

def ml.b(s: String) -> List<&2, U32>:
  U.b(s)

def ml.cat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  U.concat(xss)

def ml.eq(+a: List<&2, U32>, +c: List<&2, U32>) -> Bool:
  U.eq(a, c)

def ml.has(+xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  U.infix(xs, p)

def ml.empty(+xs: List<&2, U32>) -> Bool:
  Nat.is_eq(U.len(xs), 0n)

# Calls --------------------------------------------------------------------------------------------------

# a call: where it is (CHAT.SEQ), its tool (read, edit, write or shell), its fields, its echo
type Ml is Data:
  Ml{at: List<&2, U32>, tool: List<&2, U32>, fs: List<&2, List<&2, U32>>, echo: List<&2, U32>}

def ml.at(+c: Ml) -> List<&2, U32>:
  match c:
    case Ml{a, t, f, e}:
      a

def ml.tool(+c: Ml) -> List<&2, U32>:
  match c:
    case Ml{a, t, f, e}:
      t

def ml.fs(+c: Ml) -> List<&2, List<&2, U32>>:
  match c:
    case Ml{a, t, f, e}:
      f

def ml.echo(+c: Ml) -> List<&2, U32>:
  match c:
    case Ml{a, t, f, e}:
      e

def ml.with.echo(+c: Ml, +e: List<&2, U32>) -> Ml:
  match c:
    case Ml{a, t, f, e0}:
      Ml{a, t, f, e}

def ml.is(+c: Ml, +name: String) -> Bool:
  ml.eq(ml.tool(c), ml.b(name))

def ml.f(+c: Ml, +i: Nat) -> List<&2, U32>:
  U.nth(ml.fs(c), i)

# an edit call's edits: PATH OLD NEW ALL, four fields each
type Ed is Data:
  Ed{path: List<&2, U32>, old: List<&2, U32>, new: List<&2, U32>}

def ml.eds(+fs: List<&2, List<&2, U32>>) -> List<&2, Ed>:
  match fs:
    case +p <> +o <> +n <> +a <> +t:
      Ed{p, o, n} <> ml.eds(t)
    case _:
      Nil{}

def ml.ed.path(+e: Ed) -> List<&2, U32>:
  match e:
    case Ed{p, o, n}:
      p

def ml.ed.old(+e: Ed) -> List<&2, U32>:
  match e:
    case Ed{p, o, n}:
      o

def ml.ed.new(+e: Ed) -> List<&2, U32>:
  match e:
    case Ed{p, o, n}:
      n

# do all the edits change p
def ml.eds.on(+es: List<&2, Ed>, +p: List<&2, U32>) -> Bool:
  match es:
    case Nil{}:
      True{}
    case +e <> +t:
      Bool.and(ml.eq(ml.ed.path(e), p), ml.eds.on(t, p))

# the file a read, edit or write is on (an edit: its first edit's); none for a shell
def ml.path(+c: Ml) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, ml.is(c, "shell"), Nil{}, ml.f(c, 0n))

def ml.is.bend(+p: List<&2, U32>) -> Bool:
  S.suffix(p, ml.b(".bend"))

# an edit or a write of a Bend file
def ml.changes(+c: Ml) -> Bool:
  Bool.and(Bool.or(ml.is(c, "edit"), ml.is(c, "write")), ml.is.bend(ml.path(c)))

# a path's last part
def ml.base.go(xs: List<&2, U32>, cur: List<&2, U32>, slash: Bool) -> List<&2, U32>:
  match xs slash:
    case Nil{} _:
      List.reverse(&2, U32, cur)
    case h <> +t True{}:
      ml.base.go(t, Nil{}, S.head.is(t, 47))
    case h <> +t False{}:
      ml.base.go(t, h <> cur, S.head.is(t, 47))

def ml.base(+p: List<&2, U32>) -> List<&2, U32>:
  ml.base.go(p, Nil{}, S.head.is(p, 47))

# does the call touch p (base its last part): a read, edit or write of p, or a shell naming p's file
def ml.touches(+p: List<&2, U32>, +base: List<&2, U32>, +c: Ml) -> Bool:
  Bool.pick(Bool, ml.is(c, "shell"), ml.has(ml.f(c, 0n), base), ml.eq(ml.path(c), p))

# a check of p's file
def ml.checks(+base: List<&2, U32>, +c: Ml) -> Bool:
  Bool.and(ml.is(c, "shell"), Bool.and(ml.has(ml.f(c, 0n), ml.b("--check-only")), ml.has(ml.f(c, 0n), base)))

def ml.passes(+e: List<&2, U32>) -> Bool:
  Bool.and(ml.has(e, ml.b("ALL PROOFS CHECK")), Bool.not(ml.has(e, ml.b("SOME PROOFS FAIL"))))

# The pieces --------------------------------------------------------------------------------------------
#
# Bend checks a def only against the defs above it, so a walk that decides on its head takes the decision
# as a parameter, computed for the next head by a def above it (as Transcript.bend's split.go).

def ml.mem(+p: List<&2, U32>, +ps: List<&2, List<&2, U32>>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +q <> +t:
      Bool.or(ml.eq(p, q), ml.mem(p, t))

# does the list's first call change a Bend file not in acc yet
def ml.files.new(+cs: List<&2, Ml>, +acc: List<&2, List<&2, U32>>) -> Bool:
  match cs:
    case +c <> +t:
      Bool.and(ml.changes(c), Bool.not(ml.mem(ml.path(c), acc)))
    case Nil{}:
      False{}

# the Bend files the turn's edits and writes change, in order, once each
def ml.files.go(cs: List<&2, Ml>, +acc: List<&2, List<&2, U32>>, add: Bool) -> List<&2, List<&2, U32>>:
  match cs add:
    case Nil{} _:
      List.reverse(&2, List<&2, U32>, acc)
    case +c <> +t True{}:
      ml.files.go(t, ml.path(c) <> acc, ml.files.new(t, ml.path(c) <> acc))
    case +c <> +t False{}:
      ml.files.go(t, acc, ml.files.new(t, acc))

def ml.files(+cs: List<&2, Ml>) -> List<&2, List<&2, U32>>:
  ml.files.go(cs, Nil{}, ml.files.new(cs, Nil{}))

def ml.touches.head(+p: List<&2, U32>, +base: List<&2, U32>, +cs: List<&2, Ml>) -> Bool:
  match cs:
    case +c <> +t:
      ml.touches(p, base, c)
    case Nil{}:
      False{}

def ml.touching.go(cs: List<&2, Ml>, +p: List<&2, U32>, +base: List<&2, U32>, keep: Bool) -> List<&2, Ml>:
  match cs keep:
    case Nil{} _:
      Nil{}
    case +c <> +t True{}:
      c <> ml.touching.go(t, p, base, ml.touches.head(p, base, t))
    case +c <> +t False{}:
      ml.touching.go(t, p, base, ml.touches.head(p, base, t))

def ml.touching(+cs: List<&2, Ml>, +p: List<&2, U32>, +base: List<&2, U32>) -> List<&2, Ml>:
  ml.touching.go(cs, p, base, ml.touches.head(p, base, cs))

# does the list start with a change of p
def ml.changes.head(+p: List<&2, U32>, +cs: List<&2, Ml>) -> Bool:
  match cs:
    case +c <> +t:
      Bool.and(ml.changes(c), ml.eq(ml.path(c), p))
    case Nil{}:
      False{}

def ml.read.of(+c: Ml) -> List<&2, Ml>:
  Bool.pick(List<&2, Ml>, ml.is(c, "read"), [c], Nil{})

# from p's first edit or write on, after the read of p just before it if there is one
def ml.from.go(cs: List<&2, Ml>, +p: List<&2, U32>, +prev: List<&2, Ml>, at: Bool) -> List<&2, Ml>:
  match cs at:
    case Nil{} _:
      Nil{}
    case +c <> +t True{}:
      List.append(&2, Ml, prev, c <> t)
    case +c <> +t False{}:
      ml.from.go(t, p, ml.read.of(c), ml.changes.head(p, t))

def ml.from(+cs: List<&2, Ml>, +p: List<&2, U32>) -> List<&2, Ml>:
  ml.from.go(cs, p, Nil{}, ml.changes.head(p, cs))

# does the list start with a check of base that passes
def ml.pass.head(+base: List<&2, U32>, +cs: List<&2, Ml>) -> Bool:
  match cs:
    case +c <> +t:
      Bool.and(ml.checks(base, c), ml.passes(ml.echo(c)))
    case Nil{}:
      False{}

# cut after each passing check with a change before it; what follows the last such check is dropped
def ml.cut.go(cs: List<&2, Ml>, +base: List<&2, U32>, +cur: List<&2, Ml>, +changed: Bool, +acc: List<&2, List<&2, Ml>>, pass: Bool) -> List<&2, List<&2, Ml>>:
  match cs pass:
    case Nil{} _:
      List.reverse(&2, List<&2, Ml>, acc)
    case +c <> +t True{}:
      +ch = Bool.or(changed, ml.changes(c))
      ml.cut.go(t, base, Nil{}, False{}, Bool.pick(List<&2, List<&2, Ml>>, ch, List.reverse(&2, Ml, c <> cur) <> acc, acc), ml.pass.head(base, t))
    case +c <> +t False{}:
      ml.cut.go(t, base, c <> cur, Bool.or(changed, ml.changes(c)), acc, ml.pass.head(base, t))

def ml.cut(+cs: List<&2, Ml>, +base: List<&2, U32>) -> List<&2, List<&2, Ml>>:
  ml.cut.go(cs, base, Nil{}, False{}, Nil{}, ml.pass.head(base, cs))

def ml.pieces.of(+cs: List<&2, Ml>, +p: List<&2, U32>) -> List<&2, List<&2, Ml>>:
  +base = ml.base(p)
  ml.cut(ml.from(ml.touching(cs, p, base), p), base)

# Names ------------------------------------------------------------------------------------------------

def ml.name.end(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 40), U32.is_eq(c, 58)), Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 60)), U32.is_eq(c, 10)))

def ml.head.end(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      ml.name.end(h)
    case Nil{}:
      True{}

def ml.word.go(xs: List<&2, U32>, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> +t False{}:
      h <> ml.word.go(t, ml.head.end(t))
    case _ _:
      Nil{}

def ml.word(+xs: List<&2, U32>) -> List<&2, U32>:
  ml.word.go(xs, ml.head.end(xs))

# the name a line declares at column 0 (def or type), else none
def ml.decl(+l: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.prefix(l, ml.b("def ")), ml.word(List.drop(&2, U32, l, 4n)),
    Bool.pick(List<&2, U32>, S.prefix(l, ml.b("type ")), ml.word(List.drop(&2, U32, l, 5n)), Nil{}))

# does the first line declare a name not in acc
def ml.decls.new(+ls: List<&2, List<&2, U32>>, +acc: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case +l <> +t:
      +n = ml.decl(l)
      Bool.and(Bool.not(ml.empty(n)), Bool.not(ml.mem(n, acc)))
    case Nil{}:
      False{}

def ml.decls.go(ls: List<&2, List<&2, U32>>, +acc: List<&2, List<&2, U32>>, add: Bool) -> List<&2, List<&2, U32>>:
  match ls add:
    case Nil{} _:
      List.reverse(&2, List<&2, U32>, acc)
    case +l <> +t True{}:
      ml.decls.go(t, ml.decl(l) <> acc, ml.decls.new(t, ml.decl(l) <> acc))
    case +l <> +t False{}:
      ml.decls.go(t, acc, ml.decls.new(t, acc))

# the definitions and types a text declares, in order, once each (laws are not definitions)
def ml.decls(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ls = S.split.lines(xs)
  ml.decls.go(ls, Nil{}, ml.decls.new(ls, Nil{}))

def ml.in.head(+xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case +x <> +t:
      ml.mem(x, ys)
    case Nil{}:
      False{}

# xs's names in ys (keep True) or not in ys (keep False)
def ml.sift.go(xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>, +keep: Bool, isin: Bool) -> List<&2, List<&2, U32>>:
  match xs isin:
    case Nil{} _:
      Nil{}
    case +x <> +t True{}:
      +rest = ml.sift.go(t, ys, keep, ml.in.head(t, ys))
      Bool.pick(List<&2, List<&2, U32>>, keep, x <> rest, rest)
    case +x <> +t False{}:
      +rest = ml.sift.go(t, ys, keep, ml.in.head(t, ys))
      Bool.pick(List<&2, List<&2, U32>>, keep, rest, x <> rest)

def ml.minus(+xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  ml.sift.go(xs, ys, False{}, ml.in.head(xs, ys))

def ml.both(+xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  ml.sift.go(xs, ys, True{}, ml.in.head(xs, ys))

def ml.olds(+es: List<&2, Ed>) -> List<&2, U32>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> +t:
      ml.cat([ml.ed.old(e), [10], ml.olds(t)])

def ml.news(+es: List<&2, Ed>) -> List<&2, U32>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> +t:
      ml.cat([ml.ed.new(e), [10], ml.news(t)])

# what the first change did: 0 added names, 1 changed names, 2 wrote the file, 3 an edit with no name
type Did is Data:
  Did{how: Nat, names: List<&2, List<&2, U32>>}

def ml.did.edit(+es: List<&2, Ed>) -> Did:
  +o = ml.decls(ml.olds(es))
  +n = ml.decls(ml.news(es))
  +added = ml.minus(n, o)
  +changed = ml.both(n, o)
  Bool.pick(Did, Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, added), 0n)), Did{0n, added},
    Bool.pick(Did, Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, changed), 0n)), Did{1n, changed}, Did{3n, Nil{}}))

def ml.did(+c: Ml) -> Did:
  Bool.pick(Did, ml.is(c, "write"), Did{2n, ml.decls(ml.f(c, 1n))}, ml.did.edit(ml.eds(ml.fs(c))))

def ml.changes.any(+cs: List<&2, Ml>) -> Bool:
  match cs:
    case +c <> +t:
      ml.changes(c)
    case Nil{}:
      False{}

def ml.first.go(cs: List<&2, Ml>, at: Bool) -> Did:
  match cs at:
    case +c <> +t True{}:
      ml.did(c)
    case +c <> +t False{}:
      ml.first.go(t, ml.changes.any(t))
    case Nil{} _:
      Did{3n, Nil{}}

def ml.first.change(+cs: List<&2, Ml>) -> Did:
  ml.first.go(cs, ml.changes.any(cs))

def ml.did.how(+d: Did) -> Nat:
  match d:
    case Did{h, n}:
      h

def ml.did.names(+d: Did) -> List<&2, List<&2, U32>>:
  match d:
    case Did{h, n}:
      n

# `a`, `b` and `c` (six at most, then "K more")
def ml.ticked(+n: List<&2, U32>) -> List<&2, U32>:
  ml.cat([[96], n, [96]])

def ml.list.go(ns: List<&2, List<&2, U32>>, +k: Nat, full: Bool) -> List<&2, U32>:
  match ns full:
    case Nil{} _:
      Nil{}
    case +n <> Nil{} _:
      ml.ticked(n)
    case +n <> +m <> Nil{} False{}:
      ml.cat([ml.ticked(n), ml.b(" and "), ml.ticked(m)])
    case +n <> +t True{}:
      ml.b(Nat.show(List.length(&2, List<&2, U32>, n <> t)) ++ " more")
    case +n <> +t False{}:
      ml.cat([ml.ticked(n), ml.b(", "), ml.list.go(t, 1n+k, Nat.is_le(6n, 1n+k))])

def ml.list(+ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  ml.list.go(ns, 1n, False{})

# Rendering --------------------------------------------------------------------------------------------

def ml.turn(+label: String, +body: List<&2, U32>) -> List<&2, U32>:
  ml.cat([ml.b("## " ++ label ++ "\n\n"), body, [10]])

def ml.end.nl(+l: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.suffix(l, [10]), l, U.append(l, [10]))

def ml.chomp(+xs: List<&2, U32>) -> List<&2, U32>:
  U.trim.right(xs)

def ml.ask(+d: Did, +path: List<&2, U32>) -> List<&2, U32>:
  +h = ml.did.how(d)
  +ns = ml.did.names(d)
  +p = ml.ticked(path)
  Bool.pick(List<&2, U32>, Nat.is_eq(h, 0n), ml.cat([ml.b("Add "), ml.list(ns), ml.b(" to "), p, ml.b(".")]),
    Bool.pick(List<&2, U32>, Nat.is_eq(h, 1n), ml.cat([ml.b("Change "), ml.list(ns), ml.b(" in "), p, ml.b(".")]),
      Bool.pick(List<&2, U32>, Nat.is_eq(h, 2n), ml.cat([ml.b("Write "), p, ml.b(".")]), ml.cat([ml.b("Edit "), p, ml.b(".")]))))

def ml.reply(+d: Did, +path: List<&2, U32>) -> List<&2, U32>:
  +h = ml.did.how(d)
  +ns = ml.did.names(d)
  +p = ml.ticked(path)
  +done = Bool.pick(List<&2, U32>, Nat.is_eq(h, 0n), ml.cat([ml.b("Added "), ml.list(ns), ml.b(" to "), p]),
    Bool.pick(List<&2, U32>, Nat.is_eq(h, 1n), ml.cat([ml.b("Changed "), ml.list(ns), ml.b(" in "), p]),
      Bool.pick(List<&2, U32>, Nat.is_eq(h, 2n), ml.cat([ml.b("Wrote "), p]), ml.cat([ml.b("Edited "), p]))))
  ml.cat([done, ml.b(". bend check passes.")])

# a text's lines; a last newline gives no empty line after it
def ml.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, ml.empty(xs), Nil{}, S.split.lines(Bool.pick(List<&2, U32>, S.suffix(xs, [10]), List.take(&2, U32, xs, Nat.sub(U.len(xs), 1n)), xs)))

def ml.marked(+sign: U32, ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      ml.cat([[sign], l, [10], ml.marked(sign, t)])

def ml.groups(+es: List<&2, Ed>) -> List<&2, U32>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> Nil{}:
      ml.cat([ml.marked(45, ml.lines(ml.ed.old(e))), ml.marked(43, ml.lines(ml.ed.new(e)))])
    case +e <> +t:
      ml.cat([ml.marked(45, ml.lines(ml.ed.old(e))), ml.marked(43, ml.lines(ml.ed.new(e))), [10], ml.groups(t)])

# a line at most 300 bytes
def ml.line.cap(+l: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_le(U.len(l), 300n), l, U.append(List.take(&2, U32, l, 300n), ml.b(" [...]")))

def ml.caps(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      ml.line.cap(l) <> ml.caps(t)

# 40 lines at most, then how many more
def ml.body.cap(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +n = List.length(&2, List<&2, U32>, ls)
  +more = Bool.pick(List<&2, U32>, Nat.is_le(n, 40n), Nil{}, ml.b("\n[" ++ Nat.show(Nat.sub(n, 40n)) ++ " more lines]"))
  U.append(S.join(ml.caps(List.take(&2, List<&2, U32>, ls, 40n)), 10), more)

# `(exit N in T s)` as `(exit N)`
def ml.exit.of(+l: List<&2, U32>) -> List<&2, U32>:
  ml.cat([ml.b("(exit "), ml.word(List.drop(&2, U32, l, 6n)), ml.b(")")])

def ml.is.exit(+l: List<&2, U32>) -> Bool:
  S.prefix(l, ml.b("(exit "))

# a shell's echo: its output, capped, then its exit line without the time
def ml.shell.echo.at(ex: Bool, +last: List<&2, U32>, +rest: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ex:
    case True{}:
      +body = ml.chomp(ml.body.cap(List.reverse(&2, List<&2, U32>, rest)))
      ml.cat([body, Bool.pick(List<&2, U32>, ml.empty(body), Nil{}, [10]), ml.exit.of(last)])
    case False{}:
      ml.body.cap(List.reverse(&2, List<&2, U32>, last <> rest))

def ml.shell.echo.rev(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case +last <> +rest:
      ml.shell.echo.at(ml.is.exit(last), last, rest)
    case Nil{}:
      Nil{}

def ml.shell.echo(+e: List<&2, U32>) -> List<&2, U32>:
  ml.shell.echo.rev(List.reverse(&2, List<&2, U32>, S.split.lines(ml.chomp(e))))

def ml.echo.turn(+e: List<&2, U32>) -> List<&2, U32>:
  ml.turn("echo", ml.cat([ml.b("```\n"), e, ml.b("\n```\n")]))

def ml.call.text(+c: Ml) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, ml.is(c, "shell"),
    U.append(ml.turn("shell", ml.end.nl(ml.f(c, 0n))), ml.echo.turn(ml.shell.echo(ml.echo(c)))),
    Bool.pick(List<&2, U32>, ml.is(c, "read"),
      U.append(ml.turn("read", ml.cat([ml.f(c, 0n), [32], ml.f(c, 1n), [32], ml.f(c, 2n), [10]])), ml.echo.turn(ml.body.cap(S.split.lines(ml.chomp(ml.echo(c)))))),
      Bool.pick(List<&2, U32>, ml.is(c, "write"),
        U.append(ml.turn("write", ml.cat([ml.f(c, 0n), [10], ml.end.nl(ml.f(c, 1n))])), ml.echo.turn(ml.body.cap(S.split.lines(ml.chomp(ml.echo(c)))))),
        U.append(ml.turn("edit", ml.cat([ml.path(c), [10], ml.groups(ml.eds(ml.fs(c)))])), ml.echo.turn(ml.body.cap(S.split.lines(ml.chomp(ml.echo(c)))))))))

def ml.calls.text(+cs: List<&2, Ml>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> +t:
      U.append(ml.call.text(c), ml.calls.text(t))

# every edit in the piece is on p alone
def ml.one.file(+cs: List<&2, Ml>, +p: List<&2, U32>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case +c <> +t:
      Bool.and(Bool.or(Bool.not(ml.is(c, "edit")), ml.eds.on(ml.eds(ml.fs(c)), p)), ml.one.file(t, p))

# The scrub --------------------------------------------------------------------------------------------

def ml.lower.c(+c: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), U32.add(c, 32), c)

def ml.lower(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      ml.lower.c(h) <> ml.lower(t)

def ml.private.words() -> List<String>:
  ["netsem", "net-sem", "net_sem", "net sem", "passw", "sudo", "secret", "api key", "api_key", "apikey", "access_token",
   "auth_token", "api_token", "bearer ", "authorization:", "x-api-key", "private key", "begin openssh", "begin rsa",
   "ghp_", "github_pat", "sk-ant", "aws_", "agenix", "rdataa", "gcal", "calendar", "whatsapp", "telegram", "bautizo",
   "cristy", "wedding", "boda"]

def ml.any.word(+lo: List<&2, U32>, ws: List<String>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case w <> t:
      Bool.or(ml.has(lo, ml.b(w)), ml.any.word(lo, t))

def ml.word.c(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_le(97, c), U32.is_le(c, 122)), Bool.and(U32.is_le(48, c), U32.is_le(c, 57))),
    Bool.or(Bool.or(U32.is_eq(c, 46), U32.is_eq(c, 95)), Bool.or(U32.is_eq(c, 45), U32.is_eq(c, 43))))

def ml.host.c(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_le(97, c), U32.is_le(c, 122)), Bool.and(U32.is_le(48, c), U32.is_le(c, 57))),
    Bool.or(U32.is_eq(c, 46), U32.is_eq(c, 45)))

def ml.head.host(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      ml.host.c(h)
    case Nil{}:
      False{}

def ml.host.go(xs: List<&2, U32>, ok: Bool) -> List<&2, U32>:
  match xs ok:
    case h <> +t True{}:
      h <> ml.host.go(t, ml.head.host(t))
    case _ _:
      Nil{}

def ml.host(+xs: List<&2, U32>) -> List<&2, U32>:
  ml.host.go(xs, ml.head.host(xs))

def ml.letter(+c: U32) -> Bool:
  Bool.and(U32.is_le(97, c), U32.is_le(c, 122))

# a host with a dot in it that ends in a letter (example.com, not 10.0.0.1 or a bare name)
def ml.domain.rev(+r: List<&2, U32>) -> Bool:
  match r:
    case Nil{}:
      False{}
    case +l <> +t:
      Bool.and(U.has(t, 46), Bool.and(ml.letter(l), Bool.not(U32.is_eq(l, 46))))

def ml.domain(+h: List<&2, U32>) -> Bool:
  ml.domain.rev(List.reverse(&2, U32, h))

# an address: a name character, `@`, then a domain (on the lower-cased text)
def ml.email.go(xs: List<&2, U32>, +prev: Bool) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> +t:
      Bool.or(Bool.and(Bool.and(prev, U32.is_eq(h, 64)), ml.domain(ml.host(t))), ml.email.go(t, ml.word.c(h)))

def ml.private(+xs: List<&2, U32>) -> Bool:
  +lo = ml.lower(xs)
  Bool.or(ml.any.word(lo, ml.private.words()), ml.email.go(lo, False{}))

def ml.home(+xs: List<&2, U32>) -> List<&2, U32>:
  S.replace(xs, ml.b("/home/hhefesto"), ml.b("~"))

# Keys and ids -----------------------------------------------------------------------------------------

# the file's key (CorpusV2/ValidText.bend), from its path with ~ for the home
def ml.key(+p: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.prefix(p, ml.b("~/src/")), List.drop(&2, U32, p, 6n),
    Bool.pick(List<&2, U32>, S.prefix(p, ml.b("~/")), U.append(ml.b("home/"), List.drop(&2, U32, p, 2n)),
      Bool.pick(List<&2, U32>, S.prefix(p, ml.b("/")), List.drop(&2, U32, p, 1n), U.append(ml.b("work/"), p))))

def ml.first.of(+ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ns:
    case +n <> +t:
      n
    case Nil{}:
      ml.b("file")

def ml.first.name(+d: Did) -> List<&2, U32>:
  ml.first.of(ml.did.names(d))

def ml.id(+p: List<&2, U32>, +d: Did, +at: List<&2, U32>) -> List<&2, U32>:
  ml.cat([ml.b("mugenlog:"), ml.key(p), [35], ml.first.name(d), [64], at])

# A piece as a session ------------------------------------------------------------------------------------

# 0 kept, 1 private, 2 too long, 3 an edit of another file in it
type MlD is Data:
  MlD{code: Nat, id: List<&2, U32>, text: List<&2, U32>}

def ml.start.at(+cs: List<&2, Ml>) -> List<&2, U32>:
  match cs:
    case +c <> +t:
      ml.at(c)
    case Nil{}:
      Nil{}

def ml.fits(+b: Tk.Bpe, +limit: Nat, +text: List<&2, U32>) -> Bool:
  Nat.is_le(Nat.add(List.length(&2, U32, Tk.Bpe.encode(b, text)), 2n), limit)

def ml.session(+b: Tk.Bpe, +limit: Nat, +p0: List<&2, U32>, +cs: List<&2, Ml>) -> MlD:
  +d = ml.first.change(cs)
  +p = ml.home(p0)
  +text = ml.home(ml.cat([ml.turn("user", ml.end.nl(ml.ask(d, p))), ml.calls.text(cs), ml.turn("mugen", ml.end.nl(ml.reply(d, p)))]))
  +id = ml.id(p, d, ml.start.at(cs))
  Bool.pick(MlD, Bool.not(ml.one.file(cs, p0)), MlD{3n, id, Nil{}},
    Bool.pick(MlD, ml.private(text), MlD{1n, id, Nil{}},
      Bool.pick(MlD, ml.fits(b, limit, text), MlD{0n, id, text}, MlD{2n, id, Nil{}})))

def ml.sessions(+b: Tk.Bpe, +limit: Nat, +p: List<&2, U32>, ps: List<&2, List<&2, Ml>>) -> List<&2, MlD>:
  match ps:
    case Nil{}:
      Nil{}
    case +cs <> t:
      ml.session(b, limit, p, cs) <> ml.sessions(b, limit, p, t)

def ml.turn.of(+b: Tk.Bpe, +limit: Nat, +cs: List<&2, Ml>, fs: List<&2, List<&2, U32>>) -> List<&2, MlD>:
  match fs:
    case Nil{}:
      Nil{}
    case +p <> t:
      List.append(&2, MlD, ml.sessions(b, limit, p, ml.pieces.of(cs, p)), ml.turn.of(b, limit, cs, t))

# the sessions of a turn's calls (in order)
def ml.turn.sessions(+b: Tk.Bpe, +limit: Nat, +cs: List<&2, Ml>) -> List<&2, MlD>:
  ml.turn.of(b, limit, cs, ml.files(cs))

# The stream -------------------------------------------------------------------------------------------

# counts: turns, sessions kept, private, too long, another file's edit, pieces with no pass at the end
type MlC is Data:
  MlC{turns: Nat, kept: Nat, priv: Nat, long: Nat, other: Nat, calls: Nat}

def ml.count(+c: MlC, +k: Nat) -> MlC:
  match c:
    case MlC{t, a, p, l, o, n}:
      Bool.pick(MlC, Nat.is_eq(k, 0n), MlC{t, 1n+a, p, l, o, n},
        Bool.pick(MlC, Nat.is_eq(k, 1n), MlC{t, a, 1n+p, l, o, n},
          Bool.pick(MlC, Nat.is_eq(k, 2n), MlC{t, a, p, 1n+l, o, n}, MlC{t, a, p, l, 1n+o, n})))

# a turn with n calls kept (none: not counted)
def ml.count.turn(+c: MlC, +n: Nat) -> MlC:
  match c:
    case MlC{+t, a, p, l, o, k}:
      MlC{Bool.pick(Nat, Nat.is_eq(n, 0n), t, 1n+t), a, p, l, o, Nat.add(k, n)}

def ml.show(+c: MlC) -> String:
  match c:
    case MlC{t, a, p, l, o, n}:
      "mugenlog: " ++ Nat.show(t) ++ " turns with Bend calls (" ++ Nat.show(n) ++ " calls); " ++ Nat.show(a) ++ " sessions kept; left out: " ++ Nat.show(p) ++ " private, " ++ Nat.show(l) ++ " too long, " ++ Nat.show(o) ++ " with another file's edit"

type MlS is Type:
  MlS{rd: S.Rd, out: File, b: Tk.Bpe, lim: Nat, turn: List<&2, Ml>, pend: List<&2, Ml>, c: MlC, go: Bool}

# a kept session's pair; nothing for one left out
def ml.emit.one(out: File, +k: Nat, +i: List<&2, U32>, +x: List<&2, U32>) -> IO(File):
  match k:
    case 0n:
      S.emit(out, ml.cat([i, [0], x, [0]]))
    case _:
      IO.pure(File, out)

def ml.emit(ds: List<&2, MlD>, out: File, +c: MlC) -> IO(File & MlC):
  match ds:
    case Nil{}:
      IO.pure(File & MlC, (out, c))
    case +d <> t:
      match d:
        case MlD{+k, +i, +x}:
          IO.bind(File, File & MlC, ml.emit.one(out, k, i, x), o2 => ml.emit(t, o2, ml.count(c, k)))

def ml.flush.got(rd: S.Rd, +b: Tk.Bpe, +lim: Nat, +go: Bool, +n: Nat, r: File & MlC) -> IO(MlS):
  (out, c) = r
  IO.pure(MlS, MlS{rd, out, b, lim, Nil{}, Nil{}, ml.count.turn(c, n), go})

# the turn so far (newest first) as its sessions
def ml.flush(rd: S.Rd, out: File, +b: Tk.Bpe, +lim: Nat, +turn: List<&2, Ml>, +c: MlC, +go: Bool) -> IO(MlS):
  +cs = List.reverse(&2, Ml, turn)
  IO.bind(File & MlC, MlS, ml.emit(ml.turn.sessions(b, lim, cs), out, c), ml.flush.got(rd, b, lim, go, List.length(&2, Ml, cs)))

# a call worth keeping: a read, edit, write or shell whose call names a .bend file
def ml.wanted(+fs: List<&2, List<&2, U32>>) -> Bool:
  match fs:
    case +t <> +rest:
      Bool.and(Bool.or(Bool.or(U.eq(t, ml.b("read")), U.eq(t, ml.b("edit"))), Bool.or(U.eq(t, ml.b("write")), U.eq(t, ml.b("shell")))),
        ml.has(S.join(rest, 31), ml.b(".bend")))
    case Nil{}:
      False{}

def ml.call.of(+at: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> Ml:
  match fs:
    case +t <> +rest:
      Ml{at, t, rest, Nil{}}
    case Nil{}:
      Ml{at, Nil{}, Nil{}, Nil{}}

# an echo answers the call waiting for it, if one is (its first 16 KiB)
def ml.answered(+pend: List<&2, Ml>, +x: List<&2, U32>, +turn: List<&2, Ml>) -> List<&2, Ml>:
  match pend:
    case +p <> +t:
      ml.with.echo(p, List.take(&2, U32, x, 16384n)) <> turn
    case Nil{}:
      turn

# one record (k: 0 a user's message, 1 a call, 2 an echo, 3 anything else): a user's message ends the
# turn; a wanted call waits for its echo; an echo answers it
def ml.record.as(k: Nat, rd: S.Rd, out: File, +b: Tk.Bpe, +lim: Nat, +turn: List<&2, Ml>, +pend: List<&2, Ml>, +c: MlC, +at: List<&2, U32>, +x: List<&2, U32>) -> IO(MlS):
  match k:
    case 0n:
      ml.flush(rd, out, b, lim, turn, c, True{})
    case 1n:
      +fs = S.split(x, 31)
      IO.pure(MlS, MlS{rd, out, b, lim, turn, Bool.pick(List<&2, Ml>, ml.wanted(fs), [ml.call.of(at, fs)], Nil{}), c, True{}})
    case 2n:
      IO.pure(MlS, MlS{rd, out, b, lim, ml.answered(pend, x, turn), Nil{}, c, True{}})
    case _:
      IO.pure(MlS, MlS{rd, out, b, lim, turn, pend, c, True{}})

def ml.record(rd: S.Rd, out: File, +b: Tk.Bpe, +lim: Nat, +turn: List<&2, Ml>, +pend: List<&2, Ml>, +c: MlC, +id: List<&2, U32>, +x: List<&2, U32>) -> IO(MlS):
  +ps = S.split(id, 31)
  +kind = U.nth(ps, 2n)
  +at = ml.cat([U.nth(ps, 0n), [46], U.nth(ps, 1n)])
  +k = Bool.pick(Nat, U.eq(kind, ml.b("user")), 0n, Bool.pick(Nat, U.eq(kind, ml.b("tool")), 1n,
    Bool.pick(Nat, Bool.or(U.eq(kind, ml.b("echo")), U.eq(kind, ml.b("echo+"))), 2n, 3n)))
  ml.record.as(k, rd, out, b, lim, turn, pend, c, at, x)

def ml.text(out: File, +b: Tk.Bpe, +lim: Nat, +turn: List<&2, Ml>, +pend: List<&2, Ml>, +c: MlC, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(MlS):
  (rd, m) = r
  match m:
    case None{}:
      do IO<MlS>:
        S.Rd.close(rd)
        IO.die(MlS, 1, "mugenlog: an id without its text")
    case Some{+x}:
      ml.record(rd, out, b, lim, turn, pend, c, id, x)

def ml.id.got(out: File, +b: Tk.Bpe, +lim: Nat, +turn: List<&2, Ml>, +pend: List<&2, Ml>, +c: MlC, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(MlS):
  (rd, m) = r
  match m:
    case None{}:
      ml.flush(rd, out, b, lim, turn, c, False{})
    case Some{+i}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, MlS, S.Rd.next(rd), ml.text(out, b, lim, turn, pend, c, i))

def ml.step(s: MlS) -> IO(MlS):
  match s:
    case MlS{rd, out, b, lim, turn, pend, c, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, MlS, S.Rd.next(rd), ml.id.got(out, b, lim, turn, pend, c))

def ml.go(fuel: Nat, s: MlS) -> IO(MlS):
  match fuel s:
    case 1n+f MlS{rd, out, b, lim, turn, pend, c, True{}}:
      IO.bind(MlS, MlS, ml.step(MlS{rd, out, b, lim, turn, pend, c, True{}}), ml.go(f))
    case _ s2:
      IO.pure(MlS, s2)

def ml.fin(s: MlS) -> IO(Unit):
  match s:
    case MlS{rd, out, b, lim, turn, pend, c, g}:
      do IO<Unit>:
        S.Rd.close(rd)
        File.close(out)
        IO.print(ml.show(c))

def ml.run.with(m: Maybe<&2, Tk.Bpe>, +inp: String, +outp: String, +window: Nat) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "mugenlog: the tokenizer does not read")
    case Some{b}:
      do IO<Unit>:
        rd : S.Rd <- S.Rd.open(inp)
        out : File <- IO.try(File, File.open(outp, "w"))
        s : MlS <- ml.go(ml.fuel(), MlS{rd, out, b, Nat.sub(window, 64n), Nil{}, Nil{}, MlC{0n, 0n, 0n, 0n, 0n, 0n}, True{}})
        ml.fin(s)

def ml.run(+tok: String, +inp: String, +outp: String, +window: Nat) -> IO(Unit):
  do IO<Unit>:
    tx : List<&2, U32> <- B.Bytes.read_all(tok)
    ml.run.with(Tk.Bpe.parse(tx), inp, outp, window)

def ml.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +tok <> +inp <> +outp <> Nil{}:
      ml.run(tok, inp, outp, 2048n)
    case +tok <> +inp <> +outp <> +w <> Nil{}:
      ml.run(tok, inp, outp, Maybe.default(&2, Nat, Nat.read(w), 2048n))
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 mugenlog TOKENIZER IN OUT [WINDOW]")
