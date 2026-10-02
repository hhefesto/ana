import Base
import ../Sys.bend as S
import ../Units.bend as U
import ./Tags.bend as Tg

# A text's lines and what its cues say about them.
#
# A cue is evidence written in the text itself: a fence's info string
# (```haskell), the tool header a session prints before a fenced block
# (### Write — `path.hs`, ### Read — `path`, ### Edit — ..., whose block is
# a diff), or **stdout:** / **stderr:**.  Fences follow CommonMark: up to
# three spaces, three or more backticks and an info string; the block ends
# at a line of at least as many backticks and nothing else (so a ```` fence
# holds ``` lines, as the session renderer writes a file that has fences).
#
# For each line, `Lab`:
#   gold  the tag the cues give it: open and close for fence lines, the
#         block's tag inside a fenced block (unknown when no cue names it),
#         prose outside fences.  The labels legere is trained and scored on.
#   mask  the tag the cues FORCE in production (unknown: the line model
#         decides): fence lines and the lines of a named block.  Outside
#         fences nothing is forced, so code with no fence can still be found.

type Lab is Data:
  Lab{gold: Nat, mask: Nat}

def Lab.gold(+l: Lab) -> Nat:
  match l:
    case Lab{g, m}:
      g

def Lab.mask(+l: Lab) -> Nat:
  match l:
    case Lab{g, m}:
      m

def lines(+text: List<&2, U32>) -> List<&2, List<&2, U32>>:
  U.lines(text)

# how many leading bytes equal c
def count.go(xs: List<&2, U32>, go: Bool, +c: U32, +n: Nat) -> Nat:
  match xs go:
    case +h <> t True{}:
      +b = U32.is_eq(h, c)
      count.go(t, b, c, Nat.add(n, Bool.pick(Nat, b, 1n, 0n)))
    case _ _:
      n

def count(+xs: List<&2, U32>, +c: U32) -> Nat:
  count.go(xs, True{}, c, 0n)

def ws(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 10), U32.is_eq(c, 13)))

def ws.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      ws(h)
    case Nil{}:
      False{}

# xs without its leading whitespace; go: the head is whitespace
def ws.drop(+xs: List<&2, U32>, go: Bool) -> List<&2, U32>:
  match xs go:
    case h <> +t True{}:
      ws.drop(t, ws.head(t))
    case _ _:
      xs

def trim.r(+xs: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, xs)
  List.reverse(&2, U32, ws.drop(r, ws.head(r)))

def trim(+xs: List<&2, U32>) -> List<&2, U32>:
  trim.r(ws.drop(xs, ws.head(xs)))

type Fence is Data:
  NoFence{}
  Fence{n: Nat, info: List<&2, U32>}

def fence.at(+sp: Nat, +rest: List<&2, U32>) -> Fence:
  +n = count(rest, 96)
  Bool.pick(Fence, Bool.and(Nat.is_le(sp, 3n), Nat.is_le(3n, n)), Fence{n, trim(List.drop(&2, U32, rest, n))}, NoFence{})

def fence(+l: List<&2, U32>) -> Fence:
  +sp = count(l, 32)
  fence.at(sp, List.drop(&2, U32, l, sp))

# a fence line that closes a block opened by n backticks
def closes(f: Fence, +n: Nat) -> Bool:
  match f:
    case Fence{m, +info}:
      Bool.and(Nat.is_le(n, m), S.eq(info, Nil{}))
    case NoFence{}:
      False{}

def is.fence(f: Fence) -> Bool:
  match f:
    case Fence{m, info}:
      True{}
    case NoFence{}:
      False{}

# the extension of a path (after its last dot, if the dot is in the last
# component), empty when it has none
def ext.go(rs: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(c, 46), acc,
        Bool.pick(List<&2, U32>, U32.is_eq(c, 47), Nil{}, ext.go(t, c <> acc)))

def ext(+path: List<&2, U32>) -> List<&2, U32>:
  ext.go(List.reverse(&2, U32, path), Nil{})

# the bytes before the first c
def upto(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), Nil{}, h <> upto(t, c))

def header.tag(+l: List<&2, U32>, +p: List<&2, U32>) -> Nat:
  Tg.of.ext(ext(upto(List.drop(&2, U32, l, S.len(p)), 96)))

# the cue a line leaves for the next fenced block: a tool header or an
# output marker names it; a blank line keeps the one before; any other line
# clears it
def cue(+l: List<&2, U32>, +pend: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  +w = S.b("### Write — `")
  +r = S.b("### Read — `")
  Bool.pick(Maybe<&2, Nat>, U.blank(l), pend,
  Bool.pick(Maybe<&2, Nat>, S.prefix(l, w), Some{header.tag(l, w)},
  Bool.pick(Maybe<&2, Nat>, S.prefix(l, r), Some{header.tag(l, r)},
  Bool.pick(Maybe<&2, Nat>, S.prefix(l, S.b("### Edit — ")), Some{7n},
  Bool.pick(Maybe<&2, Nat>, Bool.or(S.prefix(l, S.b("**stdout:**")), S.prefix(l, S.b("**stderr:**"))), Some{8n}, None{})))))

def known(m: Maybe<&2, Nat>) -> Nat:
  match m:
    case Some{t}:
      t
    case None{}:
      Tg.unknown()

def or(a: Maybe<&2, Nat>, b: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match a:
    case Some{t}:
      Some{t}
    case None{}:
      b

# Out: outside a fence, with the pending cue; In: inside a block opened by
# n backticks, whose tag is t (unknown when no cue named it)
type St is Data:
  Out{pend: Maybe<&2, Nat>}
  In{n: Nat, t: Nat}

def lab.out(f: Fence) -> Lab:
  match f:
    case Fence{m, info}:
      Lab{Tg.open(), Tg.open()}
    case NoFence{}:
      Lab{0n, Tg.unknown()}

def lab.in(c: Bool, +t: Nat) -> Lab:
  match c:
    case True{}:
      Lab{Tg.close(), Tg.close()}
    case False{}:
      Lab{t, t}

def lab(+st: St, +l: List<&2, U32>) -> Lab:
  match st:
    case Out{p}:
      lab.out(fence(l))
    case In{n, t}:
      lab.in(closes(fence(l), n), t)

def step.out(f: Fence, +l: List<&2, U32>, pend: Maybe<&2, Nat>) -> St:
  match f:
    case Fence{m, +info}:
      In{m, known(or(Tg.of.info(info), pend))}
    case NoFence{}:
      Out{cue(l, pend)}

def step.in(c: Bool, +n: Nat, +t: Nat) -> St:
  match c:
    case True{}:
      Out{None{}}
    case False{}:
      In{n, t}

def step(+st: St, +l: List<&2, U32>) -> St:
  match st:
    case Out{p}:
      step.out(fence(l), l, p)
    case In{+n, t}:
      step.in(closes(fence(l), n), n, t)

def labs.go(ls: List<&2, List<&2, U32>>, +st: St, acc: List<&2, Lab>) -> List<&2, Lab>:
  match ls:
    case Nil{}:
      List.reverse(&2, Lab, acc)
    case +l <> rest:
      labs.go(rest, step(st, l), lab(st, l) <> acc)

# one Lab per line
def labs(ls: List<&2, List<&2, U32>>) -> List<&2, Lab>:
  labs.go(ls, Out{None{}}, Nil{})
