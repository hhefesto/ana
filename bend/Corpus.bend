import Base
import ./Bytes.bend as B
import ./Parse.bend as P
import ./Train/Data.bend as D

# FTCC, master's compact corpus artifact (written by prepare / build-eval):
# magic, version, tokenizer identity, dataset identity, then the documents,
# each an id and its big-endian 16-bit tokens. Read by evaluate and by the
# dense trainer (a run plan's shards).
type Corpus is Data:
  Corpus{magic: U32, version: U32, tok: String, dataset: String, docs: List<&2, List<&2, U32>>}

type Toks is Data:
  Toks{xs: List<&2, U32>, rest: List<&2, U32>}

# n big-endian 16-bit tokens, accumulated newest first
def toks.go(n: Nat, xs: List<&2, U32>, +acc: List<&2, U32>) -> Toks:
  match n xs:
    case 1n+p a <> b <> t:
      toks.go(p, t, U32.or(U32.mul(a, 256), b) <> acc)
    case _ rest:
      Toks{List.reverse(&2, U32, acc), rest}

def Toks.rest(+t: Toks) -> List<&2, U32>:
  match t:
    case Toks{a, r}:
      r

def Toks.xs(+t: Toks) -> List<&2, U32>:
  match t:
    case Toks{a, r}:
      a

def doc.toks(r: Nat & List<&2, U32>) -> Toks:
  (n, rest) = r
  toks.go(n, rest, Nil{})

def doc.fin(r: String & List<&2, U32>) -> Toks:
  (s, rest) = r
  doc.toks(P.Parse.run(Nat, P.Parse.nat(), rest))

# the documents' token lists, newest first (the ids are not needed)
def docs.go(n: Nat, +xs: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>> & List<&2, U32>:
  match n:
    case 0n:
      (acc, xs)
    case 1n+p:
      +t = doc.fin(P.Parse.run(String, P.Parse.string(), xs))
      docs.go(p, Toks.rest(t), Toks.xs(t) <> acc)

def corpus.head() -> P.Parse(Corpus):
  do P.Parse<Corpus>:
    m : U32 <- P.Parse.u32be()
    v : U32 <- P.Parse.u32be()
    t : String <- P.Parse.string()
    d : String <- P.Parse.string()
    return Corpus{m, v, t, d, Nil{}}

def corpus.all.fin(r: List<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, List<&2, U32>>:
  (ds, rest) = r
  D.lrev(ds, Nil{})


def corpus.all(r: Nat & List<&2, U32>) -> List<&2, List<&2, U32>>:
  (n, rest) = r
  corpus.all.fin(docs.go(n, rest, Nil{}))

def corpus.fin(r: Corpus & List<&2, U32>) -> Corpus:
  (c, rest) = r
  match c:
    case Corpus{m, v, t, d, x}:
      Corpus{m, v, t, d, corpus.all(P.Parse.run(Nat, P.Parse.nat(), rest))}

def corpus(+xs: List<&2, U32>) -> Corpus:
  corpus.fin(P.Parse.run(Corpus, corpus.head(), xs))

def Corpus.problem.if(magic: Bool, same: Bool, +got: String, +want: String) -> String:
  match magic same:
    case False{} _:
      "not a compact corpus (magic is not FTCC)"
    case True{} False{}:
      "corpus tokenizer identity does not match the checkpoint\n  corpus:     " ++ got ++ "\n  checkpoint: " ++ want
    case True{} True{}:
      ""

def Corpus.problem(+c: Corpus, +want: String) -> String:
  match c:
    case Corpus{m, v, t, d, x}:
      Corpus.problem.if(U32.is_eq(m, 1179927363), String.eq(t, want), t, want)

def Corpus.docs(+c: Corpus) -> List<&2, List<&2, U32>>:
  match c:
    case Corpus{m, v, t, d, x}:
      x

def Corpus.dataset(+c: Corpus) -> String:
  match c:
    case Corpus{m, v, t, d, x}:
      d
