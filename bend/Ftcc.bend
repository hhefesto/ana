import Base
import ./Num.bend as N
import ./Tokenizer.bend as Tk

# FTCC, written.  The inverse of Corpus.bend's reader, and byte for byte
# what master's encodeCorpusCompact wrote (Artifact.hs):
#
#   "FTCC" (0x46544343), the version (2), both as big-endian 32-bit words;
#   the tokenizer identity and the dataset identity, each a string;
#   the document count, a big-endian 64-bit word;
#   per document: its id, a string; its token count, a 64-bit word; its
#   tokens, each a big-endian 16-bit word.
#
# A string is Data.Binary's: its length in characters as a 64-bit word,
# then every character in UTF-8.  Ids are characters, not bytes: master
# read an id's bytes as Latin-1 characters (BSC.unpack), so an id byte of
# 128 or more is one character here and two bytes in the file.
#
# The dataset identity is master's datasetFingerprintDocuments: FNV-1a 64
# over the Data.Binary encoding of (tokenizer identity, documents), where a
# document is its id (a string) and its tokens as a list of Int (a 64-bit
# count, then each token as a big-endian 64-bit word).

type Doc is Data:
  Doc{id: List<&2, U32>, toks: List<&2, U32>}

# Bytes, prepended to `rest` ---------------------------------------------

def be32(+x: U32, rest: List<&2, U32>) -> List<&2, U32>:
  U32.shrn(x, 24n) <> U32.and(U32.shrn(x, 16n), 255) <> U32.and(U32.shrn(x, 8n), 255) <> U32.and(x, 255) <> rest

# a count below 2^32, as a 64-bit word
def be64(+n: Nat, rest: List<&2, U32>) -> List<&2, U32>:
  0 <> 0 <> 0 <> 0 <> be32(U32.from_nat(n), rest)

def utf8s(cs: List<&2, U32>, rest: List<&2, U32>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      rest
    case c <> t:
      List.append(&2, U32, Tk.utf8.encode(c), utf8s(t, rest))

# a string given as its characters (code points)
def str(+cs: List<&2, U32>, rest: List<&2, U32>) -> List<&2, U32>:
  be64(List.length(&2, U32, cs), utf8s(cs, rest))

def toks16(ts: List<&2, U32>, rest: List<&2, U32>) -> List<&2, U32>:
  match ts:
    case Nil{}:
      rest
    case +t <> more:
      U32.shrn(t, 8n) <> U32.and(t, 255) <> toks16(more, rest)

def doc(d: Doc, rest: List<&2, U32>) -> List<&2, U32>:
  match d:
    case Doc{i, +ts}:
      str(i, be64(List.length(&2, U32, ts), toks16(ts, rest)))

def docs(ds: List<&2, Doc>, rest: List<&2, U32>) -> List<&2, U32>:
  match ds:
    case Nil{}:
      rest
    case d <> more:
      doc(d, docs(more, rest))

def magic() -> U32:
  1179927363

# the whole artifact
def bytes(+tok: List<&2, U32>, +dataset: List<&2, U32>, +ds: List<&2, Doc>) -> List<&2, U32>:
  be32(magic(), be32(2, str(tok, str(dataset, be64(List.length(&2, Doc, ds), docs(ds, Nil{}))))))

# FNV-1a 64 -----------------------------------------------------------------

def fnv.basis() -> N.U64:
  N.U64{3421674724, 2216829733}

def fnv.mulp.fin(w: N.U64, +add: U32) -> N.U64:
  match w:
    case N.U64{wh, wl}:
      N.U64{U32.add(wh, add), wl}

# h * 1099511628211 mod 2^64, where the prime is 2^40 + 435: the low word's
# 2^40 term lands in the high word shifted by 8
def fnv.mulp(h: N.U64) -> N.U64:
  match h:
    case N.U64{hi, +lo}:
      fnv.mulp.fin(N.U32.mul_wide(lo, 435), U32.add(U32.mul(hi, 435), U32.shln(lo, 8n)))

def fnv.byte(h: N.U64, +b: U32) -> N.U64:
  match h:
    case N.U64{hi, lo}:
      fnv.mulp(N.U64{hi, U32.xor(lo, b)})

def fnv.bytes(bs: List<&2, U32>, h: N.U64) -> N.U64:
  match bs:
    case Nil{}:
      h
    case b <> t:
      fnv.bytes(t, fnv.byte(h, b))

def fnv.be32(h: N.U64, +x: U32) -> N.U64:
  fnv.byte(fnv.byte(fnv.byte(fnv.byte(h, U32.shrn(x, 24n)), U32.and(U32.shrn(x, 16n), 255)), U32.and(U32.shrn(x, 8n), 255)), U32.and(x, 255))

# four zero bytes: xor with zero is the identity
def fnv.zero4(h: N.U64) -> N.U64:
  fnv.mulp(fnv.mulp(fnv.mulp(fnv.mulp(h))))

def fnv.be64(h: N.U64, +n: Nat) -> N.U64:
  fnv.be32(fnv.zero4(h), U32.from_nat(n))

def fnv.utf8s(cs: List<&2, U32>, h: N.U64) -> N.U64:
  match cs:
    case Nil{}:
      h
    case c <> t:
      fnv.utf8s(t, fnv.bytes(Tk.utf8.encode(c), h))

def fnv.str(h: N.U64, +cs: List<&2, U32>) -> N.U64:
  fnv.utf8s(cs, fnv.be64(h, List.length(&2, U32, cs)))

# a token as a 64-bit Int: six zero bytes, then its two
def fnv.toks(ts: List<&2, U32>, h: N.U64) -> N.U64:
  match ts:
    case Nil{}:
      h
    case +t <> more:
      fnv.toks(more, fnv.byte(fnv.byte(fnv.mulp(fnv.mulp(fnv.zero4(h))), U32.shrn(t, 8n)), U32.and(t, 255)))

def fnv.doc(h: N.U64, d: Doc) -> N.U64:
  match d:
    case Doc{i, +ts}:
      fnv.toks(ts, fnv.be64(fnv.str(h, i), List.length(&2, U32, ts)))

def fnv.docs(ds: List<&2, Doc>, h: N.U64) -> N.U64:
  match ds:
    case Nil{}:
      h
    case d <> t:
      fnv.docs(t, fnv.doc(h, d))

def dataset(+tok: List<&2, U32>, +ds: List<&2, Doc>) -> String:
  "fnv1a64-token-documents-v1:" ++ N.U64.hex(fnv.docs(ds, fnv.be64(fnv.str(fnv.basis(), tok), List.length(&2, Doc, ds))))
