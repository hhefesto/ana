import Base
import ../Sys.bend as S
import ./Local.bend as Lc

# bend-ops lint: shell stays a thin shim (2026-10-14: the user, "I want all
# logic to be in bend. I want sh to only be a thin shim").
#
#   bend-ops lint [--tree DIR] [--allow FILE] [--report FILE] [--bend] [--run-since DATE] [-v] [PATH...]
#
# What is read: PATH... when given; else every file under DIR (--tree, for a
# copy of the source without git, as the shell-lint flake check has); else
# `git ls-files -z` here.  Of those, a shell file is one named *.sh or whose
# first line is a sh/bash shebang, and flake.nix's shell bodies count too:
# each `text = ''...''` and each runCommand's ''...'' body, named
# flake.nix:NAME (the runCommand's literal name, a writeShellApplication's
# `name`, else the attribute it is bound to, e.g. flake.nix:bendBinary).
#
# A shell file passes when it holds at most 12 lines of code, each one of
#   set -euo pipefail          export K=V ...          cd DIR          exec CMD ARGS (the last line)
# with expansions only $V, ${V}, ${V:-x}, ${V-x}, ${V:?msg}, ${V?msg} and
# ${@:N}, besides its shebang and comments.  It fails on a control word (if
# for while until case select function ...), a test ([, [[, test), a pipe,
# ||, &&, ;, a background &, ( (a subshell, function or array), $( and $((,
# a backtick, a heredoc, and the text tools (awk sed jq grep cut tr sort uniq
# xargs head tail wc diff cmp python).  A file whose first comment line
# starts with `# UNWIRED ` is skipped (kept for reference, made to exit 2).
#
# The ratchet: tools/lint/shell-allow.txt (or --allow FILE; relative to DIR
# with --tree) lists the live files, one a line (a path, or flake.nix:NAME),
# that may still fail until they are ported to Bend.  A failing file it does
# not list fails the lint (exit 1); a listed one that passes is reported, to
# be taken off.  --report FILE writes the summary there when the lint passes
# (the flake check's $out).  Warnings only, until the plan's Phase 7:
# --bend flags `sh -c` strings with control flow in the Bend sources read;
# --run-since DATE flags run/**/*.sh newer than DATE (new untracked drivers).
#
# Every name starts with `lnt.`; the checker is pure (lnt.check.*), tested in
# bend/tests/ops.bend.

# Bytes ----------------------------------------------------------------------------------

def lnt.at(+xs: List<&2, U32>, +i: Nat) -> U32:
  Lc.lcl.at(xs, i)

def lnt.is.digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def lnt.is.alpha(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_le(97, c), U32.is_le(c, 122)), Bool.and(U32.is_le(65, c), U32.is_le(c, 90))), U32.is_eq(c, 95))

def lnt.is.id(+c: U32) -> Bool:
  Bool.or(lnt.is.alpha(c), lnt.is.digit(c))

def lnt.drop.id(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      lnt.drop.id(t, lnt.is.id(lnt.at(t, 0n)))
    case r _:
      r

def lnt.drop.digits(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      lnt.drop.digits(t, lnt.is.digit(lnt.at(t, 0n)))
    case r _:
      r

def lnt.blank(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9))

def lnt.ltrim.go(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      lnt.ltrim.go(t, lnt.blank(lnt.at(t, 0n)))
    case r _:
      r

def lnt.ltrim(+xs: List<&2, U32>) -> List<&2, U32>:
  lnt.ltrim.go(xs, lnt.blank(lnt.at(xs, 0n)))

def lnt.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, lnt.ltrim(List.reverse(&2, U32, lnt.ltrim(xs))))

def lnt.in(names: List<&2, String>, +w: List<&2, U32>) -> Bool:
  match names:
    case Nil{}:
      False{}
    case n <> t:
      Bool.or(S.eq(S.b(n), w), lnt.in(t, w))

def lnt.in.bytes(xs: List<&2, List<&2, U32>>, +w: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      Bool.or(S.eq(x, w), lnt.in.bytes(t, w))

# Expansions ---------------------------------------------------------------------------------

# after ${ and the parameter's name: `}`, `:-`, `-`, `:?`, `?` (and for @ or
# *, `:N}`, the arguments from the Nth)
def lnt.param.after(+r: List<&2, U32>, special: Bool) -> Bool:
  +c0 = lnt.at(r, 0n)
  +c1 = lnt.at(r, 1n)
  +slice = Bool.and(special, Bool.and(U32.is_eq(c0, 58), Bool.and(lnt.is.digit(c1),
    U32.is_eq(lnt.at(lnt.drop.digits(List.drop(&2, U32, r, 1n), True{}), 0n), 125))))
  Bool.or(Bool.or(U32.is_eq(c0, 125), Bool.or(U32.is_eq(c0, 45), U32.is_eq(c0, 63))),
    Bool.or(Bool.and(U32.is_eq(c0, 58), Bool.or(U32.is_eq(c1, 45), U32.is_eq(c1, 63))), slice))

# xs: what follows `${`
def lnt.param.ok(+xs: List<&2, U32>) -> Bool:
  +c = lnt.at(xs, 0n)
  +special = Bool.or(U32.is_eq(c, 64), U32.is_eq(c, 42))
  +digit = lnt.is.digit(c)
  +ident = lnt.is.alpha(c)
  +rest = Bool.pick(List<&2, U32>, special, List.drop(&2, U32, xs, 1n),
    Bool.pick(List<&2, U32>, digit, lnt.drop.digits(xs, True{}), lnt.drop.id(xs, True{})))
  Bool.and(Bool.or(Bool.or(special, digit), ident), lnt.param.after(rest, special))

# The scanner ---------------------------------------------------------------------------------
#
# One line of shell, a byte at a time: inside single quotes, double quotes
# or a ${...}, or none; words split at blanks outside them; the problems met.

type LnA is Data:
  LnAChar{}
  LnAGap{}
  LnAHash{}
  LnAQuote{q: Nat}
  LnAEsc{}
  LnABad{why: String, n: Nat}
  LnAOpen{}
  LnAShut{}
  LnAIgnore{}
  LnASkip{}

# q: 0 no quote, 1 single, 2 double; br: open ${; skip: bytes taken already;
# cm: in a comment; w: the word so far (reversed); ws: the words (reversed);
# ps: the problems (reversed)
type LnSt is Data:
  LnSt{q: Nat, br: Nat, skip: Nat, cm: Bool, w: List<&2, U32>, ws: List<&2, List<&2, U32>>, ps: List<&2, String>}

def lnt.act.plain(+wempty: Bool, +prev: U32, +c: U32, +n1: U32) -> LnA:
  Bool.pick(LnA, U32.is_eq(c, 39), LnAQuote{1n}, Bool.pick(LnA, U32.is_eq(c, 34), LnAQuote{2n},
  Bool.pick(LnA, lnt.blank(c), LnAGap{},
  Bool.pick(LnA, Bool.and(U32.is_eq(c, 35), wempty), LnAHash{},
  Bool.pick(LnA, Bool.and(U32.is_eq(c, 124), U32.is_eq(n1, 124)), LnABad{"|| (logic belongs in Bend)", 1n},
  Bool.pick(LnA, U32.is_eq(c, 124), LnABad{"a pipe | (logic belongs in Bend)", 0n},
  Bool.pick(LnA, Bool.and(U32.is_eq(c, 38), U32.is_eq(n1, 38)), LnABad{"&& (logic belongs in Bend)", 1n},
  Bool.pick(LnA, Bool.and(U32.is_eq(c, 38), Bool.or(Bool.or(U32.is_eq(prev, 62), U32.is_eq(prev, 60)), U32.is_eq(n1, 62))), LnAChar{},
  Bool.pick(LnA, U32.is_eq(c, 38), LnABad{"a background job & (S.background is the Bend way)", 0n},
  Bool.pick(LnA, U32.is_eq(c, 59), LnABad{"; (one command a line)", 0n},
  Bool.pick(LnA, U32.is_eq(c, 40), LnABad{"( (a subshell, function or array)", 0n},
  Bool.pick(LnA, Bool.and(U32.is_eq(c, 60), U32.is_eq(n1, 60)), LnABad{"a heredoc <<", 1n}, LnAChar{}))))))))))))

def lnt.act(+q: Nat, +br: Nat, +skip: Nat, cm: Bool, +wempty: Bool, +prev: U32, +c: U32, +t: List<&2, U32>) -> LnA:
  +n1 = lnt.at(t, 0n)
  Bool.pick(LnA, cm, LnAIgnore{},
  Bool.pick(LnA, Nat.is_ne(skip, 0n), LnASkip{},
  Bool.pick(LnA, Nat.is_eq(q, 1n), Bool.pick(LnA, U32.is_eq(c, 39), LnAQuote{0n}, LnAChar{}),
  Bool.pick(LnA, U32.is_eq(c, 92), LnAEsc{},
  Bool.pick(LnA, Bool.and(U32.is_eq(c, 36), U32.is_eq(n1, 40)), LnABad{"$( ) or $(( )) (logic belongs in Bend)", 1n},
  Bool.pick(LnA, Bool.and(U32.is_eq(c, 36), U32.is_eq(n1, 123)), LnAOpen{},
  Bool.pick(LnA, U32.is_eq(c, 96), LnABad{"a backtick (logic belongs in Bend)", 0n},
  Bool.pick(LnA, Nat.is_ne(br, 0n), Bool.pick(LnA, U32.is_eq(c, 125), LnAShut{}, LnAChar{}),
  Bool.pick(LnA, Nat.is_eq(q, 2n), Bool.pick(LnA, U32.is_eq(c, 34), LnAQuote{0n}, LnAChar{}),
    lnt.act.plain(wempty, prev, c, n1))))))))))

def lnt.flush(+w: List<&2, U32>, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(w), 0n), ws, List.reverse(&2, U32, w) <> ws)

def lnt.apply(a: LnA, st: LnSt, +c: U32, +t: List<&2, U32>) -> LnSt:
  match a st:
    case LnAIgnore{} s:
      s
    case LnASkip{} LnSt{q, br, sk, cm, w, ws, ps}:
      LnSt{q, br, Nat.sub(sk, 1n), cm, c <> w, ws, ps}
    case LnAChar{} LnSt{q, br, sk, cm, w, ws, ps}:
      LnSt{q, br, sk, cm, c <> w, ws, ps}
    case LnAGap{} LnSt{q, br, sk, cm, w, ws, ps}:
      LnSt{q, br, sk, cm, Nil{}, lnt.flush(w, ws), ps}
    case LnAHash{} LnSt{q, br, sk, cm, w, ws, ps}:
      LnSt{q, br, sk, True{}, w, ws, ps}
    case LnAQuote{nq} LnSt{q, br, sk, cm, w, ws, ps}:
      LnSt{nq, br, sk, cm, c <> w, ws, ps}
    case LnAEsc{} LnSt{q, br, sk, cm, w, ws, ps}:
      LnSt{q, br, 1n, cm, c <> w, ws, ps}
    case LnABad{why, n} LnSt{q, br, sk, cm, w, ws, ps}:
      LnSt{q, br, n, cm, c <> w, ws, why <> ps}
    case LnAOpen{} LnSt{q, br, sk, cm, w, ws, +ps}:
      LnSt{q, 1n+br, 1n, cm, c <> w, ws,
        Bool.pick(List<&2, String>, lnt.param.ok(List.drop(&2, U32, t, 1n)), ps,
          "a parameter expansion other than ${V}, ${V:-x}, ${V:?msg}, ${@:N}" <> ps)}
    case LnAShut{} LnSt{q, br, sk, cm, w, ws, ps}:
      LnSt{q, Nat.sub(br, 1n), sk, cm, c <> w, ws, ps}

def lnt.step(st: LnSt, +c: U32, +t: List<&2, U32>) -> LnSt:
  match st:
    case LnSt{+q, +br, +sk, +cm, +w, ws, ps}:
      lnt.apply(lnt.act(q, br, sk, cm, Nat.is_eq(S.len(w), 0n), lnt.at(w, 0n), c, t), LnSt{q, br, sk, cm, w, ws, ps}, c, t)

def lnt.scan.go(xs: List<&2, U32>, st: LnSt) -> LnSt:
  match xs:
    case Nil{}:
      st
    case +c <> +t:
      lnt.scan.go(t, lnt.step(st, c, t))

# a scanned line: its words (quotes kept) and its problems, in order
type LnLine is Data:
  LnLine{words: List<&2, List<&2, U32>>, probs: List<&2, String>}

def lnt.scan.end(st: LnSt) -> LnLine:
  match st:
    case LnSt{+q, +br, sk, cm, w, ws, +ps}:
      +p1 = Bool.pick(List<&2, String>, Nat.is_ne(q, 0n), "a quote not closed on its line" <> ps, ps)
      +p2 = Bool.pick(List<&2, String>, Nat.is_ne(br, 0n), "a ${ not closed on its line" <> p1, p1)
      LnLine{List.reverse(&2, List<&2, U32>, lnt.flush(w, ws)), List.reverse(&2, String, p2)}

def lnt.scan(+xs: List<&2, U32>) -> LnLine:
  lnt.scan.end(lnt.scan.go(xs, LnSt{0n, 0n, 0n, False{}, Nil{}, Nil{}, Nil{}}))

# The statements -------------------------------------------------------------------------------

def lnt.controls() -> List<&2, String>:
  ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select", "function",
   "time", "coproc", "!", "{", "}", "[[", "]]", "((", "))", "eval", "trap", "source", ".", "read", "shift", "return",
   "break", "continue", "exit", "local", "declare", "readonly", "let", "alias"]

def lnt.tests() -> List<&2, String>:
  ["[", "test"]

def lnt.tools() -> List<&2, String>:
  ["awk", "gawk", "mawk", "sed", "jq", "grep", "egrep", "fgrep", "cut", "tr", "sort", "uniq", "xargs", "head", "tail",
   "wc", "diff", "cmp", "python", "python2", "python3"]

def lnt.wrappers() -> List<&2, String>:
  ["env", "nohup", "setsid", "stdbuf", "command", "builtin", "nice"]

# a word without its quotes and backslashes (what the shell makes of a plain word)
def lnt.unq(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      +rest = lnt.unq(t)
      Bool.pick(List<&2, U32>, Bool.or(Bool.or(U32.is_eq(c, 39), U32.is_eq(c, 34)), U32.is_eq(c, 92)), rest, c <> rest)

def lnt.unq.all(ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> t:
      lnt.unq(w) <> lnt.unq.all(t)

def lnt.at.w(xs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  Lc.lcl.nth(xs, i)

def lnt.assign(+w: List<&2, U32>) -> Bool:
  Bool.and(lnt.is.alpha(lnt.at(w, 0n)), U32.is_eq(lnt.at(lnt.drop.id(w, True{}), 0n), 61))

def lnt.word.problem(+w: List<&2, U32>, +wh: String) -> List<&2, String>:
  +base = S.base.go(w, Nil{})
  Bool.pick(List<&2, String>, lnt.in(lnt.controls(), w), ["a control word" ++ wh ++ ": " ++ S.str(w) ++ " (logic belongs in Bend)"],
    Bool.pick(List<&2, String>, lnt.in(lnt.tests(), w), ["a test" ++ wh ++ ": " ++ S.str(w) ++ " (logic belongs in Bend)"],
      Bool.pick(List<&2, String>, lnt.in(lnt.tools(), base), ["a text tool" ++ wh ++ ": " ++ S.str(w) ++ " (parsing belongs in Bend)"], Nil{})))

# exec's command: past options, assignments and wrappers like env and nohup
def lnt.exec.cmd(ws: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      +skip = Bool.or(Bool.or(U32.is_eq(lnt.at(w, 0n), 45), lnt.assign(w)), lnt.in(lnt.wrappers(), w))
      Bool.pick(List<&2, U32>, skip, lnt.exec.cmd(t), w)

def lnt.all.assign(ws: List<&2, List<&2, U32>>) -> Bool:
  match ws:
    case Nil{}:
      True{}
    case +w <> t:
      Bool.and(lnt.assign(w), lnt.all.assign(t))

def lnt.words.is(ws: List<&2, List<&2, U32>>, names: List<&2, String>) -> Bool:
  match ws names:
    case Nil{} Nil{}:
      True{}
    case w <> wt n <> nt:
      Bool.and(S.eq(w, S.b(n)), lnt.words.is(wt, nt))
    case _ _:
      False{}

# what one statement (its words, unquoted) breaks: last says whether it is
# the file's last line of code
def lnt.stmt(+ws: List<&2, List<&2, U32>>, +last: Bool) -> List<&2, String>:
  +w0 = lnt.at.w(ws, 0n)
  +rest = List.drop(&2, List<&2, U32>, ws, 1n)
  +n = List.length(&2, List<&2, U32>, ws)
  +own = lnt.word.problem(w0, "")
  +isset = S.eq(w0, S.b("set"))
  +isexp = S.eq(w0, S.b("export"))
  +iscd = S.eq(w0, S.b("cd"))
  +isexec = S.eq(w0, S.b("exec"))
  +cmd = lnt.exec.cmd(rest)
  +p = Bool.pick(List<&2, String>, isset,
      Bool.pick(List<&2, String>, lnt.words.is(ws, ["set", "-euo", "pipefail"]), Nil{}, ["set other than `set -euo pipefail`"]),
    Bool.pick(List<&2, String>, isexp,
      Bool.pick(List<&2, String>, Bool.and(Nat.is_lt(1n, n), lnt.all.assign(rest)), Nil{}, ["export other than export K=V"]),
    Bool.pick(List<&2, String>, iscd,
      Bool.pick(List<&2, String>, Nat.is_le(n, 2n), Nil{}, ["cd takes one directory"]),
    Bool.pick(List<&2, String>, isexec,
      List.append(&2, String, Bool.pick(List<&2, String>, last, Nil{}, ["exec before the last line (one final exec)"]),
        Bool.pick(List<&2, String>, Nat.is_eq(S.len(cmd), 0n), ["exec without a command"], lnt.word.problem(cmd, " after exec"))),
    Bool.pick(List<&2, String>, Nat.is_ne(List.length(&2, String, own), 0n), own,
      Bool.pick(List<&2, String>, lnt.assign(w0), ["an assignment (only export K=V)"],
        ["a command other than set -euo pipefail, export, cd and a final exec: " ++ S.str(w0)]))))))
  p

# Lines ---------------------------------------------------------------------------------------

type LnL is Data:
  LnL{n: Nat, text: List<&2, U32>}

def lnt.number(ls: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, LnL>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      LnL{n, l} <> lnt.number(t, 1n+n)

def lnt.is.comment(+xs: List<&2, U32>) -> Bool:
  U32.is_eq(lnt.at(lnt.ltrim(xs), 0n), 35)

# a logical line being joined: open (the line before ended in a backslash),
# where it started, its text so far
type LnJ is Data:
  LnJ{open: Bool, n: Nat, text: List<&2, U32>}

def lnt.join.emit(cont: Bool, +n: Nat, +x: List<&2, U32>, rest: List<&2, LnL>) -> List<&2, LnL>:
  match cont:
    case True{}:
      rest
    case False{}:
      LnL{n, x} <> rest

def lnt.join.go(ls: List<&2, LnL>, j: LnJ) -> List<&2, LnL>:
  match ls j:
    case Nil{} LnJ{True{}, n, x}:
      [LnL{n, x}]
    case Nil{} LnJ{False{}, n, x}:
      Nil{}
    case LnL{+m, +x} <> t LnJ{+o, +n, +y}:
      +start = Bool.pick(Nat, o, n, m)
      +text = Bool.pick(List<&2, U32>, o, List.append(&2, U32, y, x), x)
      +cont = Bool.and(S.suffix(text, [92]), Bool.or(o, Bool.not(lnt.is.comment(text))))
      lnt.join.emit(cont, start, text, lnt.join.go(t, LnJ{cont, start, List.take(&2, U32, text, Nat.sub(S.len(text), 1n))}))

# the logical lines: a line of code ending in a backslash goes on with the next
def lnt.join(ls: List<&2, LnL>) -> List<&2, LnL>:
  lnt.join.go(ls, LnJ{False{}, 0n, Nil{}})

# a statement: its first line, its words, the scanner's problems
type LnSm is Data:
  LnSm{n: Nat, words: List<&2, List<&2, U32>>, probs: List<&2, String>}

def lnt.stmt.put(+n: Nat, l: LnLine, +rest: List<&2, LnSm>) -> List<&2, LnSm>:
  match l:
    case LnLine{+ws, ps}:
      Bool.pick(List<&2, LnSm>, Nat.is_eq(List.length(&2, List<&2, U32>, ws), 0n), rest, LnSm{n, ws, ps} <> rest)

def lnt.stmts(ls: List<&2, LnL>) -> List<&2, LnSm>:
  match ls:
    case Nil{}:
      Nil{}
    case LnL{+n, +x} <> t:
      lnt.stmt.put(n, lnt.scan(x), lnt.stmts(t))

def lnt.msgs(+label: String, +tag: String, +n: Nat, ps: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> t:
      (label ++ ":" ++ Nat.show(n) ++ ": " ++ p ++ tag) <> lnt.msgs(label, tag, n, t)

def lnt.check.stmts(+label: String, +tag: String, ss: List<&2, LnSm>, +k: Nat, +total: Nat) -> List<&2, String>:
  match ss:
    case Nil{}:
      Nil{}
    case LnSm{+n, ws, ps} <> t:
      List.append(&2, String, lnt.msgs(label, tag, n, List.append(&2, String, ps, lnt.stmt(lnt.unq.all(ws), Nat.is_eq(1n+k, total)))),
        lnt.check.stmts(label, tag, t, 1n+k, total))

# the problems of a body of shell (numbered lines), each `LABEL:LINE: why TAG`
def lnt.check.lines(+label: String, +tag: String, ls: List<&2, LnL>) -> List<&2, String>:
  +ss = lnt.stmts(lnt.join(ls))
  +total = List.length(&2, LnSm, ss)
  +over = Bool.pick(List<&2, String>, Nat.is_lt(12n, total),
    [label ++ ": " ++ Nat.show(total) ++ " lines of code (a shim has at most 12)" ++ tag], Nil{})
  List.append(&2, String, over, lnt.check.stmts(label, tag, ss, 0n, total))

# Files ---------------------------------------------------------------------------------------

type LnRep is Data:
  LnRep{name: String, unwired: Bool, probs: List<&2, String>}

def lnt.shells() -> List<&2, String>:
  ["sh", "bash", "dash", "ash", "ksh", "mksh", "zsh"]

def lnt.env.prog(ws: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(lnt.at(w, 0n), 45), lnt.env.prog(t), w)

# does a first line name a shell: #!/bin/sh, #!/usr/bin/env bash, #! /bin/bash -e, ...
def lnt.shebang(+l: List<&2, U32>) -> Bool:
  +ws = Lc.lcl.words(List.drop(&2, U32, l, 2n))
  +p0 = S.base.go(lnt.at.w(ws, 0n), Nil{})
  +prog = Bool.pick(List<&2, U32>, S.eq(p0, S.b("env")), S.base.go(lnt.env.prog(List.drop(&2, List<&2, U32>, ws, 1n)), Nil{}), p0)
  Bool.and(S.prefix(l, S.b("#!")), lnt.in(lnt.shells(), prog))

def lnt.first.comment(ls: List<&2, LnL>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case LnL{n, +x} <> t:
      +y = lnt.ltrim(x)
      Bool.pick(List<&2, U32>, U32.is_eq(lnt.at(y, 0n), 35), y, lnt.first.comment(t))

# a shell file: skipped when its first comment line (past the shebang) starts with `# UNWIRED `
def lnt.check.sh(+path: String, +xs: List<&2, U32>) -> LnRep:
  +ls = lnt.number(S.split.lines(xs), 1n)
  +after = Bool.pick(List<&2, LnL>, S.prefix(xs, S.b("#!")), List.drop(&2, LnL, ls, 1n), ls)
  +unw = S.prefix(lnt.first.comment(after), S.b("# UNWIRED "))
  LnRep{path, unw, Bool.pick(List<&2, String>, unw, Nil{}, lnt.check.lines(path, "", ls))}

# flake.nix's shell bodies ----------------------------------------------------------------------

type LnBody is Data:
  LnBody{name: List<&2, U32>, lines: List<&2, LnL>}

# where a Nix indented string ends: a '' that is not one of its escapes
# (''' ''$ ''\x); esc: the bytes an escape starting here takes past its first
def lnt.nix.esc(+xs: List<&2, U32>) -> Nat:
  +q2 = Bool.and(U32.is_eq(lnt.at(xs, 0n), 39), U32.is_eq(lnt.at(xs, 1n), 39))
  +c = lnt.at(xs, 2n)
  Bool.pick(Nat, Bool.and(q2, Bool.or(U32.is_eq(c, 39), U32.is_eq(c, 36))), 2n, Bool.pick(Nat, Bool.and(q2, U32.is_eq(c, 92)), 3n, 0n))

def lnt.nix.hit(+skip: Nat, +xs: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(Nat.is_eq(skip, 0n), Nat.is_eq(lnt.nix.esc(xs), 0n)),
    Bool.and(U32.is_eq(lnt.at(xs, 0n), 39), U32.is_eq(lnt.at(xs, 1n), 39)))

def lnt.nix.close.go(xs: List<&2, U32>, +i: Nat, +skip: Nat, hit: Bool) -> Maybe<&2, Nat>:
  match xs hit:
    case _ True{}:
      Some{i}
    case Nil{} False{}:
      None{}
    case +c <> +t False{}:
      +sk = Bool.pick(Nat, Nat.is_ne(skip, 0n), Nat.sub(skip, 1n), lnt.nix.esc(c <> t))
      lnt.nix.close.go(t, 1n+i, sk, lnt.nix.hit(sk, t))

def lnt.nix.close(+xs: List<&2, U32>) -> Maybe<&2, Nat>:
  lnt.nix.close.go(xs, 0n, 0n, lnt.nix.hit(0n, xs))

# a body line as the shell sees it: Nix's ${...} becomes the word NIX, its
# escapes ''$ ''' ''\x their bytes (so ''${V:-x} is the shell's ${V:-x})
type LnNx is Data:
  LnNx{out: List<&2, U32>, depth: Nat, skip: Nat}

def lnt.nix.next(+depth: Nat, +skip: Nat, +c: U32, +t: List<&2, U32>) -> LnNx:
  +n1 = lnt.at(t, 0n)
  +n2 = lnt.at(t, 1n)
  +q2 = Bool.and(U32.is_eq(c, 39), U32.is_eq(n1, 39))
  Bool.pick(LnNx, Nat.is_ne(skip, 0n), LnNx{Nil{}, depth, Nat.sub(skip, 1n)},
  Bool.pick(LnNx, Nat.is_ne(depth, 0n),
    LnNx{Nil{}, Bool.pick(Nat, U32.is_eq(c, 123), 1n+depth, Bool.pick(Nat, U32.is_eq(c, 125), Nat.sub(depth, 1n), depth)), 0n},
  Bool.pick(LnNx, Bool.and(q2, U32.is_eq(n2, 36)), LnNx{[36], 0n, 2n},
  Bool.pick(LnNx, Bool.and(q2, U32.is_eq(n2, 39)), LnNx{[39, 39], 0n, 2n},
  Bool.pick(LnNx, Bool.and(q2, U32.is_eq(n2, 92)), LnNx{[lnt.at(t, 2n)], 0n, 3n},
  Bool.pick(LnNx, Bool.and(U32.is_eq(c, 36), U32.is_eq(n1, 123)), LnNx{[88, 73, 78], 1n, 1n},
    LnNx{[c], 0n, 0n}))))))

def lnt.nix.go(xs: List<&2, U32>, nx: LnNx, acc: List<&2, U32>) -> List<&2, U32>:
  match xs nx:
    case Nil{} LnNx{o, d, s}:
      List.reverse(&2, U32, List.append(&2, U32, o, acc))
    case +c <> +t LnNx{o, +d, +s}:
      lnt.nix.go(t, lnt.nix.next(d, s, c, t), List.append(&2, U32, o, acc))

def lnt.nix.line(+xs: List<&2, U32>) -> List<&2, U32>:
  lnt.nix.go(xs, LnNx{Nil{}, 0n, 0n}, Nil{})

def lnt.nix.lines(ls: List<&2, LnL>) -> List<&2, LnL>:
  match ls:
    case Nil{}:
      Nil{}
    case LnL{n, +x} <> t:
      LnL{n, lnt.nix.line(x)} <> lnt.nix.lines(t)

# the bytes of xs up to the first c
def lnt.upto(xs: List<&2, U32>, +c: U32, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t False{}:
      h <> lnt.upto(t, c, U32.is_eq(lnt.at(t, 0n), c))
    case _ _:
      Nil{}

def lnt.after(+xs: List<&2, U32>, +p: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case Some{+k}:
      List.drop(&2, U32, xs, Nat.add(k, S.len(p)))
    case None{}:
      Nil{}

def lnt.is.attr(+c: U32) -> Bool:
  Bool.or(Bool.or(lnt.is.id(c), U32.is_eq(c, 45)), Bool.or(U32.is_eq(c, 39), U32.is_eq(c, 46)))

def lnt.attr.go(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      h <> lnt.attr.go(t, lnt.is.attr(lnt.at(t, 0n)))
    case _ _:
      Nil{}

# `name = "X";` gives X; a binding `ID =` with nothing or a pkgs.* call
# after it gives ID (bendBinary =, deploy = pkgs.writeShellApplication {)
def lnt.fk.name.of(+t: List<&2, U32>, +last: List<&2, U32>) -> List<&2, U32>:
  +p = S.b("name = \"")
  +r = lnt.after(t, p, S.find(t, p, 0n))
  Bool.pick(List<&2, U32>, S.infix(t, p), lnt.upto(r, 34, U32.is_eq(lnt.at(r, 0n), 34)), last)

def lnt.fk.attr.of(+t: List<&2, U32>, +last: List<&2, U32>) -> List<&2, U32>:
  +id = lnt.attr.go(t, lnt.is.attr(lnt.at(t, 0n)))
  +r = lnt.ltrim(List.drop(&2, U32, t, S.len(id)))
  +rhs = lnt.trim(List.drop(&2, U32, r, 1n))
  +bind = Bool.and(Bool.and(Nat.is_ne(S.len(id), 0n), U32.is_eq(lnt.at(r, 0n), 61)), U32.is_ne(lnt.at(r, 1n), 61))
  Bool.pick(List<&2, U32>, Bool.and(bind, Bool.or(Nat.is_eq(S.len(rhs), 0n), S.prefix(rhs, S.b("pkgs.")))), id, last)

# a runCommand's name: its literal, else the attribute it is bound to
def lnt.fk.run.name(+x: List<&2, U32>, +attr: List<&2, U32>) -> List<&2, U32>:
  +p = S.b("runCommand ")
  +r = lnt.ltrim(lnt.after(x, p, S.find(x, p, 0n)))
  Bool.pick(List<&2, U32>, U32.is_eq(lnt.at(r, 0n), 34), lnt.upto(List.drop(&2, U32, r, 1n), 34, U32.is_eq(lnt.at(r, 1n), 34)), attr)

# the scan over flake.nix: in a body or not, its name and lines so far, the
# last `name = "X"` and binding seen, the bodies found (newest first)
type LnFk is Data:
  LnFk{inb: Bool, name: List<&2, U32>, acc: List<&2, LnL>, nm: List<&2, U32>, attr: List<&2, U32>, out: List<&2, LnBody>}

def lnt.fk.outside(+nm0: List<&2, U32>, +at0: List<&2, U32>, +out: List<&2, LnBody>, +n: Nat, +x: List<&2, U32>) -> LnFk:
  +t = lnt.ltrim(x)
  +nm = lnt.fk.name.of(t, nm0)
  +at = lnt.fk.attr.of(t, at0)
  +tk = S.find(x, S.b("text = ''"), 0n)
  +text = Maybe.is_some(&2, Nat, tk)
  +run = Bool.and(S.infix(x, S.b("runCommand")), S.infix(x, [39, 39]))
  +k = Bool.pick(Nat, text, Nat.add(Maybe.default(&2, Nat, tk, 0n), 7n), Maybe.default(&2, Nat, S.find(x, [39, 39], 0n), 0n))
  +r = List.drop(&2, U32, x, Nat.add(k, 2n))
  +owner = Bool.pick(List<&2, U32>, text, nm, lnt.fk.run.name(x, at))
  +cl = lnt.nix.close(r)
  +closed = Maybe.is_some(&2, Nat, cl)
  +one = {LnBody{owner, [LnL{n, List.take(&2, U32, r, Maybe.default(&2, Nat, cl, 0n))}]} : LnBody}
  Bool.pick(LnFk, Bool.or(text, run),
    Bool.pick(LnFk, closed, LnFk{False{}, Nil{}, Nil{}, nm, at, one <> out}, LnFk{True{}, owner, [LnL{n, r}], nm, at, out}),
    LnFk{False{}, Nil{}, Nil{}, nm, at, out})

def lnt.fk.inside(+name: List<&2, U32>, +acc: List<&2, LnL>, +nm: List<&2, U32>, +at: List<&2, U32>, +out: List<&2, LnBody>, +n: Nat, +x: List<&2, U32>) -> LnFk:
  +cl = lnt.nix.close(x)
  +closed = Maybe.is_some(&2, Nat, cl)
  +acc2 = {LnL{n, Bool.pick(List<&2, U32>, closed, List.take(&2, U32, x, Maybe.default(&2, Nat, cl, 0n)), x)} <> acc : List<&2, LnL>}
  Bool.pick(LnFk, closed, LnFk{False{}, Nil{}, Nil{}, nm, at, LnBody{name, List.reverse(&2, LnL, acc2)} <> out},
    LnFk{True{}, name, acc2, nm, at, out})

def lnt.fk.step(st: LnFk, l: LnL) -> LnFk:
  match st l:
    case LnFk{False{}, name, acc, nm, at, out} LnL{n, x}:
      lnt.fk.outside(nm, at, out, n, x)
    case LnFk{True{}, name, acc, nm, at, out} LnL{n, x}:
      lnt.fk.inside(name, acc, nm, at, out, n, x)

def lnt.fk.fin(st: LnFk) -> List<&2, LnBody>:
  match st:
    case LnFk{False{}, name, acc, nm, at, out}:
      List.reverse(&2, LnBody, out)
    case LnFk{True{}, name, acc, nm, at, out}:
      List.reverse(&2, LnBody, LnBody{name, List.reverse(&2, LnL, acc)} <> out)

def lnt.fk.go(ls: List<&2, LnL>, st: LnFk) -> List<&2, LnBody>:
  match ls:
    case Nil{}:
      lnt.fk.fin(st)
    case l <> t:
      lnt.fk.go(t, lnt.fk.step(st, l))

# flake.nix's `text = ''...''` and runCommand ''...'' bodies, each with its
# lines (flake.nix's line numbers) as the shell sees them
def lnt.flake.bodies(+xs: List<&2, U32>) -> List<&2, LnBody>:
  lnt.fk.go(lnt.number(S.split.lines(xs), 1n), LnFk{False{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}})

def lnt.check.bodies(+path: String, bs: List<&2, LnBody>) -> List<&2, LnRep>:
  match bs:
    case Nil{}:
      Nil{}
    case LnBody{+name, ls} <> t:
      LnRep{path ++ ":" ++ S.str(name), False{}, lnt.check.lines(path, " (in " ++ S.str(name) ++ ")", lnt.nix.lines(ls))}
        <> lnt.check.bodies(path, t)

def lnt.check.flake(+path: String, +xs: List<&2, U32>) -> List<&2, LnRep>:
  lnt.check.bodies(path, lnt.flake.bodies(xs))

# The ratchet --------------------------------------------------------------------------------------

# the allowlist's entries: a path or flake.nix:NAME a line (# comments, blank lines)
def lnt.allow.lines(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +x = lnt.trim(lnt.upto(l, 35, U32.is_eq(lnt.at(l, 0n), 35)))
      +rest = lnt.allow.lines(t)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(x), 0n), rest, x <> rest)

def lnt.allow.of(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  lnt.allow.lines(S.split.lines(xs))

# pass, allowed to fail, unwired, failing; the failures' report, the notes,
# the allowed ones (each newest first)
type LnTally is Data:
  LnTally{pass: Nat, allowed: Nat, unwired: Nat, failed: Nat, out: List<&2, String>, notes: List<&2, String>, al: List<&2, String>}

def lnt.indent(ps: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      acc
    case p <> t:
      lnt.indent(t, ("  " ++ p) <> acc)

def lnt.tally.one(unw: Bool, ok: Bool, listed: Bool, +name: String, +ps: List<&2, String>, +allow: String, t: LnTally) -> LnTally:
  match unw ok listed t:
    case True{} _ _ LnTally{p, a, u, f, o, n, al}:
      LnTally{p, a, 1n+u, f, o, n, al}
    case False{} True{} False{} LnTally{p, a, u, f, o, n, al}:
      LnTally{1n+p, a, u, f, o, n, al}
    case False{} True{} True{} LnTally{p, a, u, f, o, n, al}:
      LnTally{1n+p, a, u, f, o, ("lint: " ++ name ++ " passes now: take it off " ++ allow) <> n, al}
    case False{} False{} True{} LnTally{p, a, u, f, o, n, al}:
      LnTally{p, 1n+a, u, f, o, n, (name ++ " (" ++ Nat.show(List.length(&2, String, ps)) ++ " problems)") <> al}
    case False{} False{} False{} LnTally{p, a, u, f, o, n, al}:
      LnTally{p, a, u, 1n+f, lnt.indent(ps, ("lint: FAIL " ++ name) <> o), n, al}

def lnt.tally(reps: List<&2, LnRep>, +allow: List<&2, List<&2, U32>>, +allowName: String, t: LnTally) -> LnTally:
  match reps:
    case Nil{}:
      t
    case LnRep{+name, unw, +ps} <> more:
      lnt.tally(more, allow, allowName,
        lnt.tally.one(unw, Nat.is_eq(List.length(&2, String, ps), 0n), lnt.in.bytes(allow, S.b(name)), name, ps, allowName, t))

def lnt.names(reps: List<&2, LnRep>) -> List<&2, List<&2, U32>>:
  match reps:
    case Nil{}:
      Nil{}
    case LnRep{name, u, ps} <> t:
      S.b(name) <> lnt.names(t)

# the allowlist's entries that name no file read (gone or renamed)
def lnt.stale(es: List<&2, List<&2, U32>>, +names: List<&2, List<&2, U32>>, +allowName: String) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> t:
      +rest = lnt.stale(t, names, allowName)
      Bool.pick(List<&2, String>, lnt.in.bytes(names, e), rest,
        ("lint: " ++ allowName ++ " lists " ++ S.str(e) ++ ", which is not among the files read: take it off") <> rest)

# The Bend sources' sh -c strings (--bend, a warning until Phase 7) ----------------------------------

def lnt.lit.q(+xs: List<&2, U32>) -> Bool:
  U32.is_eq(lnt.at(xs, 0n), 34)

def lnt.lit.bs(+xs: List<&2, U32>) -> Bool:
  U32.is_eq(lnt.at(xs, 0n), 92)

# a Bend string literal's bytes (xs: what follows its opening quote)
def lnt.lit.go(xs: List<&2, U32>, esc: Bool, q: Bool, bs: Bool) -> List<&2, U32>:
  match xs esc q bs:
    case Nil{} _ _ _:
      Nil{}
    case +c <> +t True{} _ _:
      Bool.pick(U32, U32.is_eq(c, 110), 10, c) <> lnt.lit.go(t, False{}, lnt.lit.q(t), lnt.lit.bs(t))
    case c <> t False{} True{} _:
      Nil{}
    case c <> +t False{} False{} True{}:
      lnt.lit.go(t, True{}, lnt.lit.q(t), lnt.lit.bs(t))
    case c <> +t False{} False{} False{}:
      c <> lnt.lit.go(t, False{}, lnt.lit.q(t), lnt.lit.bs(t))

def lnt.lit(+xs: List<&2, U32>) -> List<&2, U32>:
  lnt.lit.go(xs, False{}, lnt.lit.q(xs), lnt.lit.bs(xs))

# the shell string a Bend line hands sh: the literal after `"-c", `, else
# the first literal of a line that quotes "$1" or "$@" (S.shim's kind)
def lnt.bend.lit(+l: List<&2, U32>) -> List<&2, U32>:
  +a = S.b("\"-c\", \"")
  +shellish = Bool.or(S.infix(l, S.b("\\\"$1\\\"")), S.infix(l, S.b("\\\"$@\\\"")))
  Bool.pick(List<&2, U32>, S.infix(l, a), lnt.lit(lnt.after(l, a, S.find(l, a, 0n))),
    Bool.pick(List<&2, U32>, shellish, lnt.lit(lnt.after(l, [34], S.find(l, [34], 0n))), Nil{}))

def lnt.line.probs(l: LnLine) -> List<&2, String>:
  match l:
    case LnLine{w, p}:
      p

def lnt.scan.probs(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.append(&2, String, lnt.line.probs(lnt.scan(l)), lnt.scan.probs(t))

def lnt.has.str(xs: List<&2, String>, +s: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      Bool.or(String.eq(x, s), lnt.has.str(t, s))

# each problem once, in order of first appearance (acc: newest first)
def lnt.uniq(ps: List<&2, String>, +acc: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      List.reverse(&2, String, acc)
    case +p <> t:
      lnt.uniq(t, Bool.pick(List<&2, String>, lnt.has.str(acc, p), acc, p <> acc))

def lnt.bend.lines(+path: String, ls: List<&2, LnL>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case LnL{+n, +x} <> t:
      List.append(&2, String, lnt.msgs("lint: warning: " ++ path, " (an sh -c string in Bend: Phase 7 makes it sequential process calls)", n,
        lnt.uniq(lnt.scan.probs(S.split.lines(lnt.bend.lit(x))), Nil{})), lnt.bend.lines(path, t))

# Reading -------------------------------------------------------------------------------------------

def lnt.head.of(x: Result<&1, &1, U32 & String, List<&2, U32>>) -> List<&2, U32>:
  match x:
    case Done{xs}:
      xs
    case Fail{e}:
      Nil{}

def lnt.head.got(r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(List<&2, U32>):
  (f, x) = r
  do IO<List<&2, U32>>:
    File.close(f)
    return lnt.head.of(x)

def lnt.head.opened(r: Result<&1, &1, U32 & String, File>) -> IO(List<&2, U32>):
  match r:
    case Fail{e}:
      IO.pure(List<&2, U32>, Nil{})
    case Done{f}:
      do IO<List<&2, U32>>:
        g : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 256)
        lnt.head.got(g)

# a file's first bytes (enough for its shebang); nothing when it cannot be read
def lnt.head(+path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    lnt.head.opened(r)

def lnt.full(+root: String, +p: List<&2, U32>) -> String:
  Bool.pick(String, String.is_empty(root), S.str(p), root ++ "/" ++ S.str(p))

def lnt.is.flake(+p: List<&2, U32>) -> Bool:
  Bool.or(S.eq(p, S.b("flake.nix")), S.suffix(p, S.b("/flake.nix")))

def lnt.one.sb(sb: Bool, +root: String, +p: List<&2, U32>) -> IO(List<&2, LnRep>):
  match sb:
    case False{}:
      IO.pure(List<&2, LnRep>, Nil{})
    case True{}:
      do IO<List<&2, LnRep>>:
        xs : List<&2, U32> <- S.read(lnt.full(root, p))
        return [lnt.check.sh(S.str(p), xs)]

def lnt.one.at(sh: Bool, flake: Bool, +root: String, +p: List<&2, U32>) -> IO(List<&2, LnRep>):
  match sh flake:
    case True{} _:
      lnt.one.sb(True{}, root, p)
    case False{} True{}:
      do IO<List<&2, LnRep>>:
        xs : List<&2, U32> <- S.read(lnt.full(root, p))
        return lnt.check.flake(S.str(p), xs)
    case False{} False{}:
      do IO<List<&2, LnRep>>:
        h : List<&2, U32> <- lnt.head(lnt.full(root, p))
        lnt.one.sb(lnt.shebang(S.lines.first(h)), root, p)

def lnt.one(+root: String, +p: List<&2, U32>) -> IO(List<&2, LnRep>):
  lnt.one.at(S.suffix(p, S.b(".sh")), lnt.is.flake(p), root, p)

def lnt.all(ps: List<&2, List<&2, U32>>, +root: String) -> IO(List<&2, LnRep>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, LnRep>, Nil{})
    case +p <> t:
      do IO<List<&2, LnRep>>:
        a : List<&2, LnRep> <- lnt.one(root, p)
        b : List<&2, LnRep> <- lnt.all(t, root)
        return List.append(&2, LnRep, a, b)

def lnt.bend.one.at(yes: Bool, +root: String, +p: List<&2, U32>) -> IO(List<&2, String>):
  match yes:
    case False{}:
      IO.pure(List<&2, String>, Nil{})
    case True{}:
      do IO<List<&2, String>>:
        xs : List<&2, U32> <- S.read(lnt.full(root, p))
        return lnt.bend.lines(S.str(p), lnt.number(S.split.lines(xs), 1n))

def lnt.bend.one(+root: String, +p: List<&2, U32>) -> IO(List<&2, String>):
  lnt.bend.one.at(S.suffix(p, S.b(".bend")), root, p)

def lnt.bend.all(ps: List<&2, List<&2, U32>>, +root: String) -> IO(List<&2, String>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +p <> t:
      do IO<List<&2, String>>:
        a : List<&2, String> <- lnt.bend.one(root, p)
        b : List<&2, String> <- lnt.bend.all(t, root)
        return List.append(&2, String, a, b)

def lnt.since.lines(ps: List<&2, List<&2, U32>>, +dir: String, +date: String) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> t:
      ("lint: warning: " ++ dir ++ "/" ++ S.str(p) ++ " is a shell driver newer than " ++ date
        ++ " (a run's driver is a config file and Bend now)") <> lnt.since.lines(t, dir, date)

def lnt.since(+on: Bool, +root: String, +date: String) -> IO(List<&2, String>):
  match on:
    case False{}:
      IO.pure(List<&2, String>, Nil{})
    case True{}:
      +dir = Bool.pick(String, String.is_empty(root), "run", root ++ "/run")
      do IO<List<&2, String>>:
        m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.find(dir, ["-type", "f", "-name", "*.sh", "-newermt", date])
        return lnt.since.lines(Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{}), dir, date)

# The command ---------------------------------------------------------------------------------------

def lnt.usage() -> String:
  "usage: bend-ops lint [--tree DIR] [--allow FILE] [--report FILE] [--bend] [--run-since DATE] [-v] [PATH...]"

# the options; paths newest first
type LnOpt is Data:
  LnOpt{tree: String, allow: String, report: String, bend: Bool, since: String, verbose: Bool, paths: List<&2, String>}

def lnt.o.tree(o: LnOpt, d: String) -> LnOpt:
  match o:
    case LnOpt{t, a, r, b, s, v, ps}:
      LnOpt{d, a, r, b, s, v, ps}

def lnt.o.allow(o: LnOpt, f: String) -> LnOpt:
  match o:
    case LnOpt{t, a, r, b, s, v, ps}:
      LnOpt{t, f, r, b, s, v, ps}

def lnt.o.report(o: LnOpt, f: String) -> LnOpt:
  match o:
    case LnOpt{t, a, r, b, s, v, ps}:
      LnOpt{t, a, f, b, s, v, ps}

def lnt.o.since(o: LnOpt, d: String) -> LnOpt:
  match o:
    case LnOpt{t, a, r, b, s, v, ps}:
      LnOpt{t, a, r, b, d, v, ps}

def lnt.o.bend(o: LnOpt) -> LnOpt:
  match o:
    case LnOpt{t, a, r, b, s, v, ps}:
      LnOpt{t, a, r, True{}, s, v, ps}

def lnt.o.verbose(o: LnOpt) -> LnOpt:
  match o:
    case LnOpt{t, a, r, b, s, v, ps}:
      LnOpt{t, a, r, b, s, True{}, ps}

def lnt.o.path(o: LnOpt, p: String) -> LnOpt:
  match o:
    case LnOpt{t, a, r, b, s, v, ps}:
      LnOpt{t, a, r, b, s, v, p <> ps}

def lnt.opt.go(xs: List<String>, o: LnOpt) -> Maybe<&2, LnOpt>:
  match xs:
    case Nil{}:
      Some{o}
    case "--tree" <> d <> more:
      lnt.opt.go(more, lnt.o.tree(o, d))
    case "--allow" <> f <> more:
      lnt.opt.go(more, lnt.o.allow(o, f))
    case "--report" <> f <> more:
      lnt.opt.go(more, lnt.o.report(o, f))
    case "--run-since" <> d <> more:
      lnt.opt.go(more, lnt.o.since(o, d))
    case "--bend" <> more:
      lnt.opt.go(more, lnt.o.bend(o))
    case "-v" <> more:
      lnt.opt.go(more, lnt.o.verbose(o))
    case +p <> more:
      Bool.pick(Maybe<&2, LnOpt>, String.starts_with(p, "-"), None{}, lnt.opt.go(more, lnt.o.path(o, p)))

def lnt.strs(xs: List<&2, String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.b(x) <> lnt.strs(t)

def lnt.list.got(ok: Bool, +o: Lc.LclOut, +what: String) -> IO(List<&2, List<&2, U32>>):
  match ok:
    case True{}:
      IO.pure(List<&2, List<&2, U32>>, S.split(Lc.lcl.out(o), 0))
    case False{}:
      IO.die(List<&2, List<&2, U32>>, 2, "lint: " ++ what ++ " failed (exit " ++ U32.show(Lc.lcl.status(o)) ++ "): "
        ++ S.str(Lc.lcl.err(o)) ++ "; run it in a checkout, or pass --tree DIR or the paths")

def lnt.list.tree(m: Maybe<&2, List<&2, List<&2, U32>>>, +dir: String) -> IO(List<&2, List<&2, U32>>):
  match m:
    case Some{ps}:
      IO.pure(List<&2, List<&2, U32>>, ps)
    case None{}:
      IO.die(List<&2, List<&2, U32>>, 2, "lint: cannot list " ++ dir)

# what to read: the paths given, every file under --tree's DIR, or git's files here
def lnt.list(given: Bool, tree: Bool, +dir: String, +paths: List<&2, String>) -> IO(List<&2, List<&2, U32>>):
  match given tree:
    case True{} _:
      IO.pure(List<&2, List<&2, U32>>, lnt.strs(paths))
    case False{} True{}:
      do IO<List<&2, List<&2, U32>>>:
        m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.files(dir)
        lnt.list.tree(m, dir)
    case False{} False{}:
      do IO<List<&2, List<&2, U32>>>:
        +o : Lc.LclOut <- Lc.lcl.run(300, "git", ["ls-files", "-z"])
        lnt.list.got(Lc.lcl.ok(o), o, "git ls-files")

def lnt.say(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case x <> t:
      do IO<Unit>:
        IO.print(x)
        lnt.say(t)

def lnt.lines.text(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      x ++ "\n" ++ lnt.lines.text(t)

def lnt.summary(t: LnTally, +n: Nat, +allowName: String) -> String:
  match t:
    case LnTally{p, a, u, f, o, ns, al}:
      "lint: " ++ Nat.show(n) ++ " shell files and flake.nix bodies: " ++ Nat.show(p) ++ " pass, " ++ Nat.show(a)
        ++ " allowed to fail until ported (" ++ allowName ++ "), " ++ Nat.show(u) ++ " unwired (skipped), " ++ Nat.show(f) ++ " failing"

def lnt.report(none: Bool, +report: String, +text: String) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      S.write(report, S.b(text))

def lnt.verdict(ok: Bool, +f: Nat, +allowName: String, +report: String, +text: String) -> IO(Unit):
  match ok:
    case True{}:
      lnt.report(String.is_empty(report), report, text)
    case False{}:
      IO.die(Unit, 1, "lint: " ++ Nat.show(f) ++ " file(s) hold shell logic and are not on " ++ allowName
        ++ ": move the logic into Bend (a shim may only set -euo pipefail, export, cd and exec), or unwire the file (# UNWIRED DATE: why)")

def lnt.finish(t: LnTally, +n: Nat, +allowName: String, +report: String, +verbose: Bool, +extra: List<&2, String>) -> IO(Unit):
  match t:
    case LnTally{+p, +a, +u, +f, o, ns, al}:
      +sum = lnt.summary(LnTally{p, a, u, f, Nil{}, Nil{}, Nil{}}, n, allowName)
      +als = List.reverse(&2, String, al)
      do IO<Unit>:
        lnt.say(List.reverse(&2, String, o))
        lnt.say(List.reverse(&2, String, ns))
        lnt.say(extra)
        lnt.say(Bool.pick(List<&2, String>, verbose, List.reverse(&2, String, lnt.indent(als, ["lint: allowed to fail until ported:"])), Nil{}))
        IO.print(sum)
        lnt.verdict(Nat.is_eq(f, 0n), f, allowName, report, lnt.lines.text(sum <> ("lint: allowed to fail until ported:" <> List.reverse(&2, String, lnt.indent(als, Nil{})))))

def lnt.run(o: LnOpt) -> IO(Unit):
  match o:
    case LnOpt{+tree, +allow, +report, +bend, +since, +verbose, +paths0}:
      +paths = List.reverse(&2, String, paths0)
      +given = Nat.is_ne(List.length(&2, String, paths), 0n)
      +hastree = Bool.not(String.is_empty(tree))
      +root = Bool.pick(String, given, "", Bool.pick(String, hastree, tree, "."))
      +allowName = Bool.pick(String, String.is_empty(allow),
        Bool.pick(String, Bool.and(hastree, Bool.not(given)), tree ++ "/tools/lint/shell-allow.txt", "tools/lint/shell-allow.txt"), allow)
      do IO<Unit>:
        +ps : List<&2, List<&2, U32>> <- lnt.list(given, hastree, tree, paths)
        +reps : List<&2, LnRep> <- lnt.all(ps, root)
        al : List<&2, U32> <- S.read(allowName)
        +allowed : List<&2, List<&2, U32>> = lnt.allow.of(al)
        bw : List<&2, String> <- Bool.pick(IO(List<&2, String>), bend, lnt.bend.all(ps, root), IO.pure(List<&2, String>, Nil{}))
        sw : List<&2, String> <- lnt.since(Bool.not(String.is_empty(since)), root, since)
        +stale : List<&2, String> = Bool.pick(List<&2, String>, given, Nil{}, lnt.stale(allowed, lnt.names(reps), allowName))
        lnt.finish(lnt.tally(reps, allowed, allowName, LnTally{0n, 0n, 0n, 0n, Nil{}, Nil{}, Nil{}}),
          List.length(&2, LnRep, reps), allowName, report, verbose, List.concat(&2, String, [stale, bw, sw]))

def lnt.main.opt(m: Maybe<&2, LnOpt>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 2, lnt.usage())
    case Some{o}:
      lnt.run(o)

def lnt.main(xs: List<String>) -> IO(Unit):
  lnt.main.opt(lnt.opt.go(xs, LnOpt{"", "", "", False{}, "", False{}, Nil{}}))

