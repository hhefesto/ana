import Base
import ./Tokenizer.bend as Tk
import ./Agent/Spec.bend as A

# The training mask (docs/AGENT.md): a target token's weight is its role's
# (Agent/Spec.bend `ag.weight`: 0 on a tool's echo and on a given attempt,
# 1 elsewhere), the roles read from the window's own tokens.  No shard
# carries a side channel: the roles are a function of the tokens.
#
# The reading is Spec's `ag.read`, run over the token alphabet: the newline
# token and the heading lines encoded.  It agrees with the byte reading
# because the tokenizer (code32k, pretokenizer v2) never lets a token cross
# a newline: a newline is its own word, and a heading line followed by an
# empty line is the words `##`, ` LABEL`, `\n`.  `bend-agent-laws` checks
# the agreement on every transcript of the corpus.
#
# A window is token ids, BOS (0) and EOS (1) between documents.  A document
# that opens with the User heading is a transcript and is read; any other
# (raw code, filler, a document cut by the window's start) is given.  BOS is
# given; an EOS ends ana's turn after a transcript (act) and is given after
# anything else: both weigh 1.

type Ids is Data:
  Ids{nl: U32, hds: List<&2, A.Hd>, user: List<&2, U32>}

def ms.nl(+ids: Ids) -> U32:
  match ids:
    case Ids{n, h, u}:
      n

def ms.hds(+ids: Ids) -> List<&2, A.Hd>:
  match ids:
    case Ids{n, h, u}:
      h

def ms.user(+ids: Ids) -> List<&2, U32>:
  match ids:
    case Ids{n, h, u}:
      u

def ms.hds.go(+b: Tk.Bpe, hs: List<&2, A.Hd>) -> List<&2, A.Hd>:
  match hs:
    case Nil{}:
      Nil{}
    case A.Hd{x, k} <> t:
      A.Hd{Tk.Bpe.encode(b, x), k} <> ms.hds.go(b, t)

def ms.first(+xs: List<&2, U32>) -> U32:
  match xs:
    case h <> t:
      h
    case Nil{}:
      10

# the reader's symbols under a tokenizer
def ms.ids(+b: Tk.Bpe) -> Ids:
  Ids{ms.first(Tk.Bpe.encode(b, [10])), ms.hds.go(b, A.ag.hds.bytes()), Tk.Bpe.encode(b, A.ag.ascii("## User\n"))}

# whether the encoded newline is one token (the reader needs it)
def ms.ids.ok(+b: Tk.Bpe) -> Bool:
  Nat.is_eq(List.length(&2, U32, Tk.Bpe.encode(b, [10])), 1n)

# a document's tokens as an episode
def ms.read(+ids: Ids, +xs: List<&2, U32>) -> List<&2, A.Turn>:
  A.ag.read(ms.nl(ids), ms.hds(ids), xs)

def ms.is.transcript(+ids: Ids, +seg: List<&2, U32>) -> Bool:
  A.ag.prefix(seg, ms.user(ids))

def ms.seg.if(tr: Bool, +ids: Ids, +seg: List<&2, U32>) -> List<&2, A.Role>:
  match tr:
    case True{}:
      A.ag.roles(ms.read(ids, seg))
    case False{}:
      List.replicate(A.Role, List.length(&2, U32, seg), A.RoGiven{})

# the document read so far (newest first), then its separator: pushed onto
# acc, the chunks of roles newest first
def ms.flush(+ids: Ids, cur: List<&2, U32>, +sep: U32, acc: List<&2, List<&2, A.Role>>) -> List<&2, List<&2, A.Role>>:
  +seg = List.reverse(&2, U32, cur)
  +tr = ms.is.transcript(ids, seg)
  [Bool.pick(A.Role, Bool.and(tr, U32.is_eq(sep, 1)), A.RoAct{}, A.RoGiven{})] <> (ms.seg.if(tr, ids, seg) <> acc)

def ms.end(+ids: Ids, cur: List<&2, U32>, acc: List<&2, List<&2, A.Role>>) -> List<&2, List<&2, A.Role>>:
  +seg = List.reverse(&2, U32, cur)
  ms.seg.if(ms.is.transcript(ids, seg), ids, seg) <> acc

def ms.head.sep(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_lt(h, 2)
    case Nil{}:
      False{}

def ms.go(w: List<&2, U32>, +ids: Ids, cur: List<&2, U32>, acc: List<&2, List<&2, A.Role>>, sep: Bool) -> List<&2, A.Role>:
  match w sep:
    case Nil{} _:
      List.concat(&2, A.Role, List.reverse(&2, List<&2, A.Role>, ms.end(ids, cur, acc)))
    case +h <> +t True{}:
      ms.go(t, ids, Nil{}, ms.flush(ids, cur, h, acc), ms.head.sep(t))
    case h <> +t False{}:
      ms.go(t, ids, h <> cur, acc, ms.head.sep(t))

# each token's role in a window
def ms.roles(+ids: Ids, +w: List<&2, U32>) -> List<&2, A.Role>:
  ms.go(w, ids, Nil{}, Nil{}, ms.head.sep(w))

def ms.wmap(rs: List<&2, A.Role>) -> List<&2, F32>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      A.ag.weight(r) <> ms.wmap(t)

# a window of k + 1 tokens makes k predictions; prediction i's target is
# token i + 1, and its weight that token's role's
def ms.weights(+ids: Ids, +w: List<&2, U32>) -> List<&2, F32>:
  ms.wmap(List.drop(&2, A.Role, ms.roles(ids, w), 1n))

# The trainer's choice (TRAIN_MASK): every target weighs 1 (off, run 1's
# objective), or each weighs its role's (`kinds`).
type Mask is Data:
  MsOff{}
  MsOn{ids: Ids}

# TRAIN_MASK's value under a tokenizer: "" off, "kinds" on; anything else
# (or a tokenizer whose newline is not one token) none
def ms.of(+s: String, +b: Tk.Bpe) -> Maybe<&2, Mask>:
  Bool.pick(Maybe<&2, Mask>, String.is_empty(s), Some{MsOff{}},
    Bool.pick(Maybe<&2, Mask>, Bool.and(String.eq(s, "kinds"), ms.ids.ok(b)), Some{MsOn{ms.ids(b)}}, None{}))

# each window's weights
def ms.weights.all(+ids: Ids, ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, F32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      ms.weights(ids, w) <> ms.weights.all(ids, t)

def ms.name(+m: Mask) -> String:
  match m:
    case MsOff{}:
      "all weigh 1 (TRAIN_MASK unset)"
    case MsOn{ids}:
      "by role (TRAIN_MASK=kinds: a tool's echo and a given attempt weigh 0)"
