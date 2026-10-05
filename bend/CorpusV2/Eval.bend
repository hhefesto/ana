import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../Clock.bend as Ck
import ./Lib.bend as L
import ./Combine.bend as C

# Corpus v2's generation evaluation (docs/CORPUS-V2.md, E1 direct pass@1 and
# E2 repair@1): the prompts, the answers and their checking (the old
# evalset.py and evalrun.py, report for report).
#
#   evalset [--both] [--drop FILE] [--out FILE] [N_DIRECT [N_REPAIR]]
#       The prompts, cut from render.sh's held-out format 2 transcripts
#       (run/v2/transcripts/LANG/transcripts.holdout.nul), LANG haskell, agda,
#       lean, nix, bend in that order:
#         direct  the transcript up to its Term's fence (the last
#                 "## Term\n\n```LANG\n"): the answer is ana's whole Term
#                 (E1). The same text is format 1's, so run 1 and run 2 get
#                 one prompt.
#         repair  up to the Term after the given Attempt and the checker's
#                 error (E2); prompt1 is format 1's version for run 1 (the
#                 ask alone: "\n\nThis attempt fails. Fix it." dropped, the
#                 first "## Attempt\n\n" as "## Term\n\n").
#       The reference is the text after the fence up to the first "\n```",
#       plus a newline. A transcript id is UNIT/SHAPE, UNIT less a `+N` after
#       its last `#`; a unit's first direct and first repair transcript are
#       its. Units go in the order of sha256("corpus-v2 evalset\0" UNIT) as
#       hex; up to N_DIRECT (40) direct prompts a language, then up to
#       N_REPAIR (20) repair prompts from the units not asked yet (Nix:
#       repair only, 2 x N_REPAIR). Writes run/v2/evalset/prompts.nul.
#       --both: only the units run 1 held out too (an id in any
#       run/transcripts*/*/results.holdout.nul), each with its direct and its
#       repair prompt, no limits; writes run/v2/evalset/prompts-both.nul.
#       --drop FILE: leaves out the prompts FILE lists (`UNIT TAB SHAPE`
#       lines: run/v2/evalset/dropped-by-control.txt, the prompts whose own
#       reference fails the harness: `control` then `check` shows them).
#       --out FILE: writes FILE instead. Prints each language's counts (before
#       the drop), then the prompts written.
#
#   gen CKPT DIR FORMAT [K]
#       Each prompt of EVALSET (run/v2/evalset/prompts.nul) answered greedily
#       on the CPU: run/gcroot-bend-generate/bin/bend-generate --threads
#       THREADS (5) with CKPT, PROMPT, TOKENS (100), TEMPERATURE=0 and
#       TOKENIZER_FILE=weights/code32k.bpe, PROCS (3) at a time; FORMAT 1 asks
#       repairs with prompt1 (run 1), 2 with prompt; K: only the first K
#       prompts of each language and shape. The term is the output after the
#       prompt up to the first ``` (all of it when there is none: not closed;
#       nothing when the output does not hold the prompt). Writes
#       DIR/results.nul (each answer added as it finishes, then all of them in
#       prompt order) and DIR/raw.nul (the generator's whole output).
#
#   control DIR
#       DIR/results.nul with every prompt of EVALSET answered by its own
#       reference: the harness's control.
#
#   check DIR
#       Each answer's term lifted into its held-out unit
#       (run/v2/results/LANG.holdout.nul; the transcript shows the body
#       dedented, so the change that maps the reference to the stored body
#       maps the term: the same; every non-blank line indented by the body's
#       leading spaces; the first line only; or the same text between the
#       body's own leading and trailing whitespace), checked by `nix run
#       .#deploy -- check LANG ANS RESULTS CHECK_JOBS (4)` a group: a language,
#       and Bend a source tree each (BEND_SRC: of run/code-sources*/CLASS, in
#       name order, then ~/src, the first whose copy of the unit's file holds
#       the body, else the first that has the file; the directory above where
#       the repository really is, past a link). Writes DIR/ans.G.nul,
#       DIR/r.G.nul and DIR/log.G a group (G: the language, bend-<sha256 of
#       the tree, 8 hex>), and DIR/report.txt: a line a language and shape
#       (pass, closed, lifted), `all pass P/N`, then PASS or fail a prompt.
#
# Files (NUL-framed (id, text) pairs, as every corpus file; RS is 0x1E):
#   prompts.nul  id UNIT/SHAPE; text LANG RS UNIT RS SHAPE RS PROMPT RS
#                PROMPT1 RS REF (PROMPT1 empty for a direct prompt)
#   results.nul  id UNIT/SHAPE; text N RS LANG RS UNIT RS SHAPE RS CLOSED (1/0)
#                RS SECS RS ASKED RS REF RS TERM (N: the prompt's place in
#                EVALSET after the K cut, counting from 0; TERM last, so it
#                may hold any byte but NUL, which the generator's output is
#                stripped of)
#   raw.nul      id N; text the generator's output
#
# Run from the repository root.

# Bytes -------------------------------------------------------------------------

def ev.rs() -> U32:
  30

# Python's bytes.split(sep): n separators, n + 1 pieces
def ev.split.go(xs: List<&2, U32>, +s: U32, cur: List<&2, U32>, acc: List<&2, List<&2, U32>>, at: Bool) -> List<&2, List<&2, U32>>:
  match xs at:
    case Nil{} _:
      List.reverse(&2, List<&2, U32>, List.reverse(&2, U32, cur) <> acc)
    case h <> +t True{}:
      ev.split.go(t, s, Nil{}, List.reverse(&2, U32, cur) <> acc, L.v2.head.is(t, s))
    case h <> +t False{}:
      ev.split.go(t, s, h <> cur, acc, L.v2.head.is(t, s))

def ev.split(+xs: List<&2, U32>, +s: U32) -> List<&2, List<&2, U32>>:
  ev.split.go(xs, s, Nil{}, Nil{}, L.v2.head.is(xs, s))

def ev.nth(+fs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  L.v2.nth(fs, i)

# the fields from i on, joined again (a last field that may hold RS)
def ev.rest(+fs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  S.join(List.drop(&2, List<&2, U32>, fs, i), 30)

def ev.show(+n: Nat) -> List<&2, U32>:
  S.b(Nat.show(n))

def ev.strs(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> ev.strs(more)

def ev.lines.str(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      S.str(l) <> ev.lines.str(more)

def ev.is.some(+m: Maybe<&2, Nat>) -> Bool:
  match m:
    case Some{k}:
      True{}
    case None{}:
      False{}

# the bytes before the first match (all of xs when there is none)
def ev.upto.at(+xs: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case None{}:
      xs
    case Some{k}:
      List.take(&2, U32, xs, k)

def ev.upto(+xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  ev.upto.at(xs, S.find(xs, p, 0n))

# the bytes after the first p (nothing when there is none)
def ev.past.at(+xs: List<&2, U32>, +n: Nat, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case None{}:
      Nil{}
    case Some{k}:
      List.drop(&2, U32, xs, Nat.add(k, n))

def ev.past(+xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  ev.past.at(xs, S.len(p), S.find(xs, p, 0n))

# the bytes after the last c (all of xs when there is none)
def ev.last(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  List.reverse(&2, U32, L.v2.before(List.reverse(&2, U32, xs), c))

def ev.rfind.at(+n: Nat, +m: Nat, f: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match f:
    case None{}:
      None{}
    case Some{j}:
      Some{Nat.sub(Nat.sub(n, j), m)}

# where the last p starts
def ev.rfind(+t: List<&2, U32>, +p: List<&2, U32>) -> Maybe<&2, Nat>:
  ev.rfind.at(S.len(t), S.len(p), S.find(List.reverse(&2, U32, t), List.reverse(&2, U32, p), 0n))

def ev.spaces(n: Nat) -> List<&2, U32>:
  List.replicate(U32, n, 32)

# left-aligned in w columns (ASCII), and a number right-aligned
def ev.padr(+xs: List<&2, U32>, +w: Nat) -> List<&2, U32>:
  S.append(xs, ev.spaces(Nat.sub(w, S.len(xs))))

def ev.padl(+n: Nat, +w: Nat) -> List<&2, U32>:
  +d = ev.show(n)
  S.append(ev.spaces(Nat.sub(w, S.len(d))), d)

def ev.cont(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.and(U32.is_le(128, h), U32.is_le(h, 191))

# the first n characters of UTF-8 text
def ev.chars.go(xs: List<&2, U32>, n: Nat, cont: Bool) -> List<&2, U32>:
  match xs n cont:
    case Nil{} _ _:
      Nil{}
    case h <> +t k True{}:
      h <> ev.chars.go(t, k, ev.cont(t))
    case h <> t 0n False{}:
      Nil{}
    case h <> +t 1n+k False{}:
      h <> ev.chars.go(t, k, ev.cont(t))

def ev.chars(+xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  ev.chars.go(xs, n, ev.cont(xs))

# Whitespace and lines as Python's str has them ------------------------------------
#
# str.isspace: \t \n \v \f \r, 0x1C-0x1F, space, U+0085, U+00A0, U+1680,
# U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 (Lib's v2.rstrip
# reads them backwards; these read forwards). str.splitlines ends a line at
# \n, \r, \r\n, \v, \f, 0x1C, 0x1D, 0x1E, U+0085, U+2028 and U+2029.

# the bytes the whitespace character starting at a takes (b, c the bytes after)
def ev.ws.len(+a: U32, +b: U32, +c: U32) -> Nat:
  +ascii = Bool.or(Bool.and(U32.is_le(9, a), U32.is_le(a, 13)), Bool.and(U32.is_le(28, a), U32.is_le(a, 32)))
  +two = Bool.and(U32.is_eq(a, 194), Bool.or(U32.is_eq(b, 133), U32.is_eq(b, 160)))
  +e2 = Bool.and(U32.is_eq(a, 226), Bool.or(Bool.and(U32.is_eq(b, 128), Bool.or(Bool.and(U32.is_le(128, c), U32.is_le(c, 138)),
          Bool.or(U32.is_eq(c, 168), Bool.or(U32.is_eq(c, 169), U32.is_eq(c, 175))))), Bool.and(U32.is_eq(b, 129), U32.is_eq(c, 159))))
  +three = Bool.or(Bool.and(U32.is_eq(a, 225), Bool.and(U32.is_eq(b, 154), U32.is_eq(c, 128))),
    Bool.or(e2, Bool.and(U32.is_eq(a, 227), Bool.and(U32.is_eq(b, 128), U32.is_eq(c, 128)))))
  Bool.pick(Nat, ascii, 1n, Bool.pick(Nat, two, 2n, Bool.pick(Nat, three, 3n, 0n)))

def ev.ws.n(+xs: List<&2, U32>) -> Nat:
  ev.ws.len(L.v2.byte.at(xs, 0n), L.v2.byte.at(xs, 1n), L.v2.byte.at(xs, 2n))

def ev.lstrip.go(fuel: Nat, xs: List<&2, U32>, n: Nat) -> List<&2, U32>:
  match fuel n:
    case 1n+f 1n+k:
      +r = List.drop(&2, U32, xs, 1n+k)
      ev.lstrip.go(f, r, ev.ws.n(r))
    case _ _:
      xs

def ev.lstrip(+xs: List<&2, U32>) -> List<&2, U32>:
  ev.lstrip.go(S.len(xs), xs, ev.ws.n(xs))

def ev.strip(+xs: List<&2, U32>) -> List<&2, U32>:
  L.v2.rstrip(ev.lstrip(xs))

# does the text hold a character that is not whitespace (str.strip() != "")
def ev.solid.go(fuel: Nat, xs: List<&2, U32>, n: Nat) -> Bool:
  match fuel xs n:
    case _ Nil{} _:
      False{}
    case _ h <> t 0n:
      True{}
    case 1n+f h <> t 1n+k:
      +r = List.drop(&2, U32, h <> t, 1n+k)
      ev.solid.go(f, r, ev.ws.n(r))
    case _ _ _:
      False{}

def ev.solid(+xs: List<&2, U32>) -> Bool:
  ev.solid.go(S.len(xs), xs, ev.ws.n(xs))

# the bytes the line break starting here takes (0: none)
def ev.nl.len(+xs: List<&2, U32>) -> Nat:
  +a = L.v2.byte.at(xs, 0n)
  +b = L.v2.byte.at(xs, 1n)
  +c = L.v2.byte.at(xs, 2n)
  +one = Bool.or(Bool.or(U32.is_eq(a, 10), Bool.and(U32.is_le(11, a), U32.is_le(a, 12))), Bool.and(U32.is_le(28, a), U32.is_le(a, 30)))
  +u = Bool.or(Bool.and(U32.is_eq(a, 194), U32.is_eq(b, 133)), Bool.and(Bool.and(U32.is_eq(a, 226), U32.is_eq(b, 128)), Bool.or(U32.is_eq(c, 168), U32.is_eq(c, 169))))
  Bool.pick(Nat, U32.is_eq(a, 13), Bool.pick(Nat, U32.is_eq(b, 10), 2n, 1n),
    Bool.pick(Nat, one, 1n, Bool.pick(Nat, u, Bool.pick(Nat, U32.is_eq(a, 194), 2n, 3n), 0n)))

def ev.cur.push(+cur: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(cur), 0n), acc, List.reverse(&2, U32, cur) <> acc)

# str.splitlines(True): the lines with their breaks
def ev.lines.go(fuel: Nat, xs: List<&2, U32>, n: Nat, cur: List<&2, U32>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match fuel xs n:
    case _ Nil{} _:
      List.reverse(&2, List<&2, U32>, ev.cur.push(cur, acc))
    case 1n+f h <> +t 0n:
      ev.lines.go(f, t, ev.nl.len(t), h <> cur, acc)
    case 1n+f h <> t 1n+k:
      +ys = {h <> t : List<&2, U32>}
      +m = {1n+k : Nat}
      +r = List.drop(&2, U32, ys, m)
      ev.lines.go(f, r, ev.nl.len(r), Nil{}, List.append(&2, U32, List.reverse(&2, U32, cur), List.take(&2, U32, ys, m)) <> acc)
    case 0n _ _:
      List.reverse(&2, List<&2, U32>, ev.cur.push(cur, acc))

def ev.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  ev.lines.go(1n+S.len(xs), xs, ev.nl.len(xs), Nil{}, Nil{})

# every line that is not blank behind lead
def ev.ind.go(+lead: List<&2, U32>, ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      S.append(Bool.pick(List<&2, U32>, ev.solid(l), S.append(lead, l), l), ev.ind.go(lead, more))

def ev.ind(+lead: List<&2, U32>, +t: List<&2, U32>) -> List<&2, U32>:
  ev.ind.go(lead, ev.lines(t))

def ev.lead.go(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      h <> ev.lead.go(t, L.v2.head.is(t, 32))
    case _ _:
      Nil{}

# the body's leading spaces
def ev.lead(+xs: List<&2, U32>) -> List<&2, U32>:
  ev.lead.go(xs, L.v2.head.is(xs, 32))

# body.replace(body.strip(), term.strip()): the stripped body occurs once, so
# the body's own leading and trailing whitespace around the stripped term (a
# body of whitespace alone, where Python inserts the term between every
# character, does not reach here: its reference would be one too)
def ev.restrip(+body: List<&2, U32>, +term: List<&2, U32>) -> List<&2, U32>:
  +front = Nat.sub(S.len(body), S.len(ev.lstrip(body)))
  +keep = S.len(L.v2.rstrip(body))
  L.v2.concat([List.take(&2, U32, body, front), ev.strip(term), List.drop(&2, U32, body, keep)])

# ana's term lifted into the unit, as the reference maps to the stored body
def ev.lift(+ref: List<&2, U32>, +body: List<&2, U32>, +term: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  +lead = ev.lead(body)
  Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(ref, body), Some{term},
    Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(ev.ind(lead, ref), body), Some{ev.ind(lead, term)},
      Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(S.append(lead, ref), body), Some{S.append(lead, term)},
        Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(ev.strip(ref), ev.strip(body)), Some{ev.restrip(body, term)}, None{}))))

# Records -----------------------------------------------------------------------

type EvKv is Data:
  EvKv{k: List<&2, U32>, v: List<&2, U32>}

def ev.kv.k(+x: EvKv) -> List<&2, U32>:
  match x:
    case EvKv{k, v}:
      k

def ev.kv.is(+xs: List<&2, EvKv>, +id: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case EvKv{k, v} <> more:
      S.eq(k, id)

# the value of the first pair with key id
def ev.kv.get.go(xs: List<&2, EvKv>, +id: List<&2, U32>, at: Bool) -> Maybe<&2, List<&2, U32>>:
  match xs at:
    case EvKv{k, v} <> more True{}:
      Some{v}
    case x <> +more False{}:
      ev.kv.get.go(more, id, ev.kv.is(more, id))
    case Nil{} _:
      None{}

def ev.kv.get(+xs: List<&2, EvKv>, +id: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  ev.kv.get.go(xs, id, ev.kv.is(xs, id))

def ev.kv.bytes(xs: List<&2, EvKv>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case EvKv{k, v} <> more:
      L.v2.concat([k, [0], v, [0], ev.kv.bytes(more)])

def ev.pairs(fs: List<&2, List<&2, U32>>) -> List<&2, EvKv>:
  match fs:
    case k <> v <> more:
      EvKv{k, v} <> ev.pairs(more)
    case _:
      Nil{}

# a NUL file's pairs, read whole (none when it cannot be opened)
def ev.nul(+path: String) -> IO(List<&2, EvKv>):
  do IO<List<&2, EvKv>>:
    xs : List<&2, U32> <- S.read(path)
    return ev.pairs(ev.split(xs, 0))

# A NUL file streamed a pair at a time, keeping the pairs whose id is in keep
# (every pair when all).
type EvSc is Type:
  EvSc{r: S.Rd, acc: List<&2, EvKv>, more: Bool}

def ev.sc.put(hit: Bool, x: EvKv, acc: List<&2, EvKv>) -> List<&2, EvKv>:
  match hit:
    case True{}:
      x <> acc
    case False{}:
      acc

def ev.sc.text(+keep: Set(), +all: Bool, +id: List<&2, U32>, acc: List<&2, EvKv>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(EvSc):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(EvSc, EvSc{r, acc, False{}})
    case Some{t}:
      IO.pure(EvSc, EvSc{r, ev.sc.put(Bool.or(all, L.v2.in(keep, S.str(id))), EvKv{id, t}, acc), True{}})

def ev.sc.id(+keep: Set(), +all: Bool, acc: List<&2, EvKv>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(EvSc):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(EvSc, EvSc{r, acc, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, EvSc, S.Rd.next(r), ev.sc.text(keep, all, id, acc))

def ev.sc.go(fuel: Nat, +keep: Set(), +all: Bool, s: EvSc) -> IO(EvSc):
  match fuel s:
    case 1n+f EvSc{r, acc, True{}}:
      IO.bind(EvSc, EvSc, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, EvSc, S.Rd.next(r), ev.sc.id(keep, all, acc)), ev.sc.go(f, keep, all))
    case _ EvSc{r, acc, m}:
      IO.pure(EvSc, EvSc{r, acc, m})

def ev.sc.fin(s: EvSc) -> IO(List<&2, EvKv>):
  match s:
    case EvSc{r, acc, m}:
      do IO<List<&2, EvKv>>:
        S.Rd.close(r)
        return List.reverse(&2, EvKv, acc)

def ev.scan(+path: String, +keep: Set(), +all: Bool) -> IO(List<&2, EvKv>):
  do IO<List<&2, EvKv>>:
    r : S.Rd <- S.Rd.open(path)
    s : EvSc <- ev.sc.go(C.cb.big(), keep, all, EvSc{r, Nil{}, True{}})
    ev.sc.fin(s)

def ev.dir.of(+p: String) -> String:
  +d = L.v2.parent(S.b(p), 47)
  Bool.pick(String, Nat.is_eq(S.len(d), 0n), ".", S.str(d))

def ev.langs() -> List<&2, String>:
  ["haskell", "agda", "lean", "nix", "bend"]

def ev.shape(+rep: Bool) -> List<&2, U32>:
  S.b(Bool.pick(String, rep, "repair", "direct"))

# evalset: the units ---------------------------------------------------------------

type EvE is Data:
  EvE{h: String, i: Nat, unit: List<&2, U32>, rep: Bool, text: List<&2, U32>}

# a transcript id's unit: UNIT/SHAPE, UNIT less a `+N` after its last `#`
def ev.unit(+tid: List<&2, U32>) -> List<&2, U32>:
  +base = L.v2.parent(tid, 47)
  Bool.pick(List<&2, U32>, L.v2.has(ev.last(base, 35), 43), L.v2.parent(base, 43), base)

def ev.hash(+u: List<&2, U32>) -> String:
  H.sha256(L.v2.concat([S.b("corpus-v2 evalset"), [0], u]))

def ev.e.put(hit: Bool, e: EvE, rest: List<&2, EvE>) -> List<&2, EvE>:
  match hit:
    case True{}:
      e <> rest
    case False{}:
      rest

# the direct and repair transcripts, numbered in file order
def ev.entries(kvs: List<&2, EvKv>, +i: Nat) -> List<&2, EvE>:
  match kvs:
    case Nil{}:
      Nil{}
    case EvKv{+tid, t} <> more:
      +shape = ev.last(tid, 47)
      +u = ev.unit(tid)
      +rep = S.eq(shape, S.b("repair"))
      ev.e.put(Bool.or(S.eq(shape, S.b("direct")), rep), EvE{ev.hash(u), i, u, rep, t}, ev.entries(more, 1n+i))

def ev.cmp.le(c: Cmp, +a: Nat, +b: Nat) -> Bool:
  match c:
    case LT{}:
      True{}
    case GT{}:
      False{}
    case EQ{}:
      Nat.is_le(a, b)

def ev.e.le(x: EvE, y: EvE) -> Bool:
  match x y:
    case EvE{h1, i1, u1, r1, t1} EvE{h2, i2, u2, r2, t2}:
      ev.cmp.le(String.order(h1, h2), i1, i2)

type EvU is Data:
  EvU{unit: List<&2, U32>, d: Maybe<&2, List<&2, U32>>, r: Maybe<&2, List<&2, U32>>}

def ev.first(m: Maybe<&2, List<&2, U32>>, t: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      Some{t}
    case Some{x}:
      Some{x}

def ev.u.set(rep: Bool, t: List<&2, U32>, n: List<&2, U32>, d: Maybe<&2, List<&2, U32>>, r: Maybe<&2, List<&2, U32>>) -> EvU:
  match rep:
    case True{}:
      EvU{n, d, ev.first(r, t)}
    case False{}:
      EvU{n, ev.first(d, t), r}

def ev.u.add(rep: Bool, t: List<&2, U32>, u: EvU) -> EvU:
  match u:
    case EvU{n, d, r}:
      ev.u.set(rep, t, n, d, r)

def ev.same(+es: List<&2, EvE>, +h: String) -> Bool:
  match es:
    case Nil{}:
      False{}
    case EvE{eh, i, u, r, t} <> more:
      String.eq(eh, h)

def ev.grp(es: List<&2, EvE>, same: Bool, +h: String, cur: EvU, acc: List<&2, EvU>) -> List<&2, EvU>:
  match es same:
    case Nil{} _:
      List.reverse(&2, EvU, cur <> acc)
    case EvE{eh, i, u, rep, t} <> +more True{}:
      ev.grp(more, ev.same(more, h), h, ev.u.add(rep, t, cur), acc)
    case EvE{+eh, i, u, rep, t} <> +more False{}:
      ev.grp(more, ev.same(more, eh), eh, ev.u.add(rep, t, EvU{u, None{}, None{}}), cur <> acc)

# the units in hash order, each with its first direct and first repair transcript
def ev.units(+kvs: List<&2, EvKv>) -> List<&2, EvU>:
  +es = List.sort(~EvE, ~ev.e.le, ev.entries(kvs, 0n))
  List.drop(&2, EvU, ev.grp(es, ev.same(es, ""), "", EvU{Nil{}, None{}, None{}}, Nil{}), 1n)

def ev.u.name(+u: EvU) -> String:
  match u:
    case EvU{n, d, r}:
      S.str(n)

def ev.u.keep(hit: Bool, u: EvU, rest: List<&2, EvU>) -> List<&2, EvU>:
  match hit:
    case True{}:
      u <> rest
    case False{}:
      rest

def ev.u.filter(+both: Bool, +v1: Set(), us: List<&2, EvU>) -> List<&2, EvU>:
  match us:
    case Nil{}:
      Nil{}
    case +u <> more:
      ev.u.keep(Bool.or(Bool.not(both), L.v2.in(v1, ev.u.name(u))), u, ev.u.filter(both, v1, more))

# evalset: the prompts --------------------------------------------------------------

type EvP is Data:
  EvP{lang: String, unit: List<&2, U32>, rep: Bool, prompt: List<&2, U32>, prompt1: List<&2, U32>, ref: List<&2, U32>}

def ev.fix() -> List<&2, U32>:
  S.b("\n\nThis attempt fails. Fix it.")

def ev.fence(+l: String) -> List<&2, U32>:
  S.b("## Term\n\n```" ++ l ++ "\n")

def ev.cut.at(+l: String, +rep: Bool, +unit: List<&2, U32>, +t: List<&2, U32>, +fl: Nat, m: Maybe<&2, Nat>) -> Maybe<&2, EvP>:
  match m:
    case None{}:
      None{}
    case Some{+k}:
      +prompt = List.take(&2, U32, t, Nat.add(k, fl))
      +ref = S.append(ev.upto(List.drop(&2, U32, t, Nat.add(k, fl)), S.b("\n```")), [10])
      +p1 = S.replace.first(S.replace.first(prompt, ev.fix(), Nil{}), S.b("## Attempt\n\n"), S.b("## Term\n\n"))
      Some{EvP{l, unit, rep, prompt, Bool.pick(List<&2, U32>, rep, p1, Nil{}), ref}}

def ev.cut(+l: String, +rep: Bool, +unit: List<&2, U32>, +t: List<&2, U32>) -> Maybe<&2, EvP>:
  +f = ev.fence(l)
  ev.cut.at(l, rep, unit, t, S.len(f), ev.rfind(t, f))

def ev.text.of(rep: Bool, d: Maybe<&2, List<&2, U32>>, r: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match rep:
    case True{}:
      r
    case False{}:
      d

def ev.try.t(+l: String, +rep: Bool, +unit: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, EvP>:
  match m:
    case None{}:
      None{}
    case Some{+t}:
      ev.cut(l, rep, unit, t)

def ev.try(ok: Bool, +l: String, +rep: Bool, u: EvU) -> Maybe<&2, EvP>:
  match ok u:
    case True{} EvU{+n, d, r}:
      ev.try.t(l, rep, n, ev.text.of(rep, d, r))
    case _ _:
      None{}

# the head unit's prompt, when it gets one: under the count (go), not asked yet
# (unless both), the shape there, its fence found
def ev.next(+us: List<&2, EvU>, +used: List<&2, Bool>, +go: Bool, +both: Bool, +l: String, +rep: Bool) -> Maybe<&2, EvP>:
  match us used:
    case u <> ut f <> ft:
      ev.try(Bool.and(go, Bool.or(both, Bool.not(f))), l, rep, u)
    case _ _:
      None{}

type EvPs is Data:
  EvPs{ps: List<&2, EvP>, used: List<&2, Bool>, got: Nat}

# one shape over the units: m is the head unit's prompt (ev.next)
def ev.pass(us: List<&2, EvU>, used: List<&2, Bool>, m: Maybe<&2, EvP>, +want: Nat, +got: Nat, +both: Bool, +l: String, +rep: Bool, ps: List<&2, EvP>, fl: List<&2, Bool>) -> EvPs:
  match us used m:
    case u <> +ut f <> +ft Some{p}:
      ev.pass(ut, ft, ev.next(ut, ft, Nat.is_lt(1n+got, want), both, l, rep), want, 1n+got, both, l, rep, p <> ps, True{} <> fl)
    case u <> +ut f <> +ft None{}:
      ev.pass(ut, ft, ev.next(ut, ft, Nat.is_lt(got, want), both, l, rep), want, got, both, l, rep, ps, f <> fl)
    case _ _ _:
      EvPs{List.reverse(&2, EvP, ps), List.reverse(&2, Bool, fl), got}

type EvLr is Data:
  EvLr{lang: String, ps: List<&2, EvP>, d: Nat, r: Nat}

def ev.lang.fin(+l: String, ps: List<&2, EvP>, +gd: Nat, p2: EvPs) -> EvLr:
  match p2:
    case EvPs{ps2, fl, gr}:
      EvLr{l, List.append(&2, EvP, ps, ps2), gd, gr}

def ev.lang.rep(+l: String, +wr: Nat, +both: Bool, +us: List<&2, EvU>, p1: EvPs) -> EvLr:
  match p1:
    case EvPs{ps, +fl, gd}:
      ev.lang.fin(l, ps, gd, ev.pass(us, fl, ev.next(us, fl, Nat.is_lt(0n, wr), both, l, True{}), wr, 0n, both, l, True{}, Nil{}, Nil{}))

def ev.lang(+l: String, +nd: Nat, +nr: Nat, +both: Bool, +us: List<&2, EvU>) -> EvLr:
  +nix = String.eq(l, "nix")
  +wd = Bool.pick(Nat, nix, 0n, nd)
  +wr = Bool.pick(Nat, nix, Nat.mul(2n, nr), nr)
  +no = List.replicate(Bool, List.length(&2, EvU, us), False{})
  ev.lang.rep(l, wr, both, us, ev.pass(us, no, ev.next(us, no, Nat.is_lt(0n, wd), both, l, False{}), wd, 0n, both, l, False{}, Nil{}, Nil{}))

type EvLu is Data:
  EvLu{lang: String, us: List<&2, EvU>}

def ev.load.units(ls: List<&2, String>, acc: List<&2, EvLu>) -> IO(List<&2, EvLu>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, EvLu>, List.reverse(&2, EvLu, acc))
    case +l <> more:
      do IO<List<&2, EvLu>>:
        kvs : List<&2, EvKv> <- ev.scan("run/v2/transcripts/" ++ l ++ "/transcripts.holdout.nul", Set.new(), True{})
        ev.load.units(more, EvLu{l, ev.units(kvs)} <> acc)

def ev.names.u(us: List<&2, EvU>) -> List<&2, String>:
  match us:
    case Nil{}:
      Nil{}
    case +u <> more:
      ev.u.name(u) <> ev.names.u(more)

def ev.names(lus: List<&2, EvLu>) -> List<&2, String>:
  match lus:
    case Nil{}:
      Nil{}
    case EvLu{l, us} <> more:
      List.append(&2, String, ev.names.u(us), ev.names(more))

def ev.kv.ids(xs: List<&2, EvKv>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case EvKv{k, v} <> more:
      S.str(k) <> ev.kv.ids(more)

# run 1's held-out results files (glob run/transcripts*/*/results.holdout.nul)
def ev.v1.files() -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +o : S.Out <- S.run.quiet(".", Nil{}, 600, "find", ["-L", "run", "-mindepth", "3", "-maxdepth", "3", "-path", "run/transcripts*/*/results.holdout.nul", "!", "-path", "run/*/.*"], Nil{})
    return ev.lines.str(S.split.lines(S.Out.text(o)))

def ev.v1.load(fs: List<&2, String>, +keep: Set(), acc: List<&2, String>) -> IO(List<&2, String>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, String>, acc)
    case f <> more:
      do IO<List<&2, String>>:
        kvs : List<&2, EvKv> <- ev.scan(f, keep, False{})
        ev.v1.load(more, keep, List.append(&2, String, ev.kv.ids(kvs), acc))

# the ids run 1 held out among keep (the v2 units: the only ones asked about)
def ev.v1(both: Bool, +keep: Set()) -> IO(Set()):
  match both:
    case False{}:
      IO.pure(Set(), Set.new())
    case True{}:
      do IO<Set()>:
        fs : List<&2, String> <- ev.v1.files()
        ids : List<&2, String> <- ev.v1.load(fs, keep, Nil{})
        return Set.from_list(ids)

def ev.select(lus: List<&2, EvLu>, +both: Bool, +nd: Nat, +nr: Nat, +v1: Set()) -> List<&2, EvLr>:
  match lus:
    case Nil{}:
      Nil{}
    case EvLu{+l, us} <> more:
      ev.lang(l, nd, nr, both, ev.u.filter(both, v1, us)) <> ev.select(more, both, nd, nr, v1)

# Python's dict(Counter) of the counts
def ev.counts(+d: Nat, +r: Nat) -> String:
  +hd = Nat.is_lt(0n, d)
  +hr = Nat.is_lt(0n, r)
  "{" ++ Bool.pick(String, hd, "'direct': " ++ Nat.show(d), "") ++ Bool.pick(String, Bool.and(hd, hr), ", ", "")
    ++ Bool.pick(String, hr, "'repair': " ++ Nat.show(r), "") ++ "}"

def ev.say.counts(ls: List<&2, EvLr>) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case EvLr{l, ps, +d, +r} <> more:
      do IO<Unit>:
        IO.print(l ++ " " ++ ev.counts(d, r))
        ev.say.counts(more)

def ev.all.ps(ls: List<&2, EvLr>) -> List<&2, EvP>:
  match ls:
    case Nil{}:
      Nil{}
    case EvLr{l, ps, d, r} <> more:
      List.append(&2, EvP, ps, ev.all.ps(more))

def ev.p.key(+p: EvP) -> String:
  match p:
    case EvP{l, u, rep, pr, p1, r}:
      S.str(L.v2.concat([u, [9], ev.shape(rep)]))

def ev.p.keep(hit: Bool, p: EvP, rest: List<&2, EvP>) -> List<&2, EvP>:
  match hit:
    case True{}:
      p <> rest
    case False{}:
      rest

def ev.p.drop(+drop: Set(), ps: List<&2, EvP>) -> List<&2, EvP>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      ev.p.keep(Bool.not(L.v2.in(drop, ev.p.key(p))), p, ev.p.drop(drop, more))

def ev.p.bytes(ps: List<&2, EvP>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case EvP{l, +u, +rep, pr, p1, r} <> more:
      L.v2.concat([u, [47], ev.shape(rep), [0], S.join([S.b(l), u, ev.shape(rep), pr, p1, r], 30), [0], ev.p.bytes(more)])

# a field that holds RS (or NUL) would not read back
def ev.p.bad(ps: List<&2, EvP>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case EvP{l, +u, rep, +pr, p1, +r} <> more:
      Bool.or(Bool.or(Bool.or(L.v2.has(u, 30), L.v2.has(pr, 30)), Bool.or(L.v2.has(r, 30), L.v2.has(S.append(u, S.append(pr, r)), 0))), ev.p.bad(more))

def ev.guard(bad: Bool) -> IO(Unit):
  match bad:
    case True{}:
      IO.die(Unit, 1, "evalset: a unit, prompt or reference holds a 0x1E or NUL byte")
    case False{}:
      IO.pure(Unit, Unit{})

def ev.drop.load(none: Bool, +path: String) -> IO(Set()):
  match none:
    case True{}:
      IO.pure(Set(), Set.new())
    case False{}:
      do IO<Set()>:
        xs : List<&2, U32> <- S.read(path)
        return Set.from_list(ev.lines.str(S.split.lines(xs)))

def ev.evalset.run(+both: Bool, +nd: Nat, +nr: Nat, +drop: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +lus : List<&2, EvLu> <- ev.load.units(ev.langs(), Nil{})
    +v1 : Set() <- ev.v1(both, Set.from_list(ev.names(lus)))
    +sel : List<&2, EvLr> = ev.select(lus, both, nd, nr, v1)
    ev.say.counts(sel)
    +ps : List<&2, EvP> = ev.all.ps(sel)
    +dr : Set() <- ev.drop.load(String.eq(drop, ""), drop)
    +kept : List<&2, EvP> = ev.p.drop(dr, ps)
    ev.guard(ev.p.bad(kept))
    S.mkdir(ev.dir.of(out))
    S.write(out, ev.p.bytes(kept))
    IO.print(Bool.pick(String, String.eq(drop, ""), "", "dropped " ++ Nat.show(Nat.sub(List.length(&2, EvP, ps), List.length(&2, EvP, kept))) ++ " (" ++ drop ++ "), ")
      ++ Nat.show(List.length(&2, EvP, kept)) ++ " prompts")

type EvFl is Data:
  EvFlBoth{}
  EvFlDrop{}
  EvFlOut{}
  EvFlNone{}

def ev.flag(+xs: List<&2, String>) -> EvFl:
  match xs:
    case Nil{}:
      EvFlNone{}
    case +x <> more:
      Bool.pick(EvFl, String.eq(x, "--both"), EvFlBoth{}, Bool.pick(EvFl, String.eq(x, "--drop"), EvFlDrop{}, Bool.pick(EvFl, String.eq(x, "--out"), EvFlOut{}, EvFlNone{})))

type EvA is Data:
  EvA{both: Bool, drop: String, out: String, pos: List<&2, String>}

def ev.a.go(xs: List<&2, String>, fl: EvFl, +both: Bool, +drop: String, +out: String, pos: List<&2, String>) -> EvA:
  match xs fl:
    case x <> +more EvFlBoth{}:
      ev.a.go(more, ev.flag(more), True{}, drop, out, pos)
    case x <> y <> +more EvFlDrop{}:
      ev.a.go(more, ev.flag(more), both, y, out, pos)
    case x <> y <> +more EvFlOut{}:
      ev.a.go(more, ev.flag(more), both, drop, y, pos)
    case x <> +more EvFlNone{}:
      ev.a.go(more, ev.flag(more), both, drop, out, x <> pos)
    case _ _:
      EvA{both, drop, out, List.reverse(&2, String, pos)}

def ev.str.nth(xs: List<&2, String>, +i: Nat) -> String:
  match xs i:
    case x <> more 0n:
      x
    case x <> more 1n+k:
      ev.str.nth(more, k)
    case _ _:
      ""

def ev.pos.nat(+pos: List<&2, String>, +i: Nat, +d: Nat) -> Nat:
  C.cb.nat.or(Bool.pick(Maybe<&2, Nat>, Nat.is_lt(i, List.length(&2, String, pos)), Nat.read(ev.str.nth(pos, i)), Some{d}))

def ev.evalset.a(a: EvA) -> IO(Unit):
  match a:
    case EvA{+both, drop, +out, +pos}:
      +big = {1000000n : Nat}
      ev.evalset.run(both, Bool.pick(Nat, both, big, ev.pos.nat(pos, 0n, 40n)), Bool.pick(Nat, both, big, ev.pos.nat(pos, 1n, 20n)), drop,
        Bool.pick(String, String.eq(out, ""), Bool.pick(String, both, "run/v2/evalset/prompts-both.nul", "run/v2/evalset/prompts.nul"), out))

# xs: the arguments after `evalset`
def ev.evalset(xs: List<String>) -> IO(Unit):
  +ys = C.cb.strs.d(xs)
  ev.evalset.a(ev.a.go(ys, ev.flag(ys), False{}, "", "", Nil{}))

# gen and control ---------------------------------------------------------------------

type EvQ is Data:
  EvQ{id: List<&2, U32>, lang: List<&2, U32>, unit: List<&2, U32>, shape: List<&2, U32>, prompt: List<&2, U32>, prompt1: List<&2, U32>, ref: List<&2, U32>}

def ev.q.of(kv: EvKv) -> EvQ:
  match kv:
    case EvKv{id, +t}:
      +fs = ev.split(t, 30)
      EvQ{id, ev.nth(fs, 0n), ev.nth(fs, 1n), ev.nth(fs, 2n), ev.nth(fs, 3n), ev.nth(fs, 4n), ev.rest(fs, 5n)}

def ev.qs.of(kvs: List<&2, EvKv>) -> List<&2, EvQ>:
  match kvs:
    case Nil{}:
      Nil{}
    case kv <> more:
      ev.q.of(kv) <> ev.qs.of(more)

def ev.q.key(+q: EvQ) -> List<&2, U32>:
  match q:
    case EvQ{id, l, u, s, p, p1, r}:
      L.v2.concat([l, [9], s])

type EvCt is Data:
  EvCt{k: List<&2, U32>, n: Nat}

def ev.ct.is(+cs: List<&2, EvCt>, +k: List<&2, U32>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case EvCt{ck, n} <> more:
      S.eq(ck, k)

def ev.ct.get.go(cs: List<&2, EvCt>, +k: List<&2, U32>, at: Bool) -> Nat:
  match cs at:
    case EvCt{ck, n} <> more True{}:
      n
    case c <> +more False{}:
      ev.ct.get.go(more, k, ev.ct.is(more, k))
    case Nil{} _:
      0n

def ev.ct.inc.go(cs: List<&2, EvCt>, +k: List<&2, U32>, at: Bool) -> List<&2, EvCt>:
  match cs at:
    case EvCt{ck, n} <> more True{}:
      EvCt{ck, 1n+n} <> more
    case c <> +more False{}:
      c <> ev.ct.inc.go(more, k, ev.ct.is(more, k))
    case Nil{} _:
      [EvCt{k, 1n}]

def ev.ct.inc(hit: Bool, +cs: List<&2, EvCt>, +k: List<&2, U32>) -> List<&2, EvCt>:
  match hit:
    case True{}:
      ev.ct.inc.go(cs, k, ev.ct.is(cs, k))
    case False{}:
      cs

def ev.q.keep(hit: Bool, q: EvQ, rest: List<&2, EvQ>) -> List<&2, EvQ>:
  match hit:
    case True{}:
      q <> rest
    case False{}:
      rest

# the first k prompts of each language and shape
def ev.firstk(qs: List<&2, EvQ>, +k: Nat, +cs: List<&2, EvCt>) -> List<&2, EvQ>:
  match qs:
    case Nil{}:
      Nil{}
    case +q <> more:
      +key = ev.q.key(q)
      +hit = Nat.is_lt(ev.ct.get.go(cs, key, ev.ct.is(cs, key)), k)
      ev.q.keep(hit, q, ev.firstk(more, k, ev.ct.inc(hit, cs, key)))

def ev.cut.k(+k: Nat, +qs: List<&2, EvQ>) -> List<&2, EvQ>:
  Bool.pick(List<&2, EvQ>, Nat.is_eq(k, 0n), qs, ev.firstk(qs, k, Nil{}))

def ev.asked(+fmt1: Bool, +q: EvQ) -> List<&2, U32>:
  match q:
    case EvQ{id, l, u, s, p, p1, r}:
      Bool.pick(List<&2, U32>, Bool.and(fmt1, Nat.is_lt(0n, S.len(p1))), p1, p)

def ev.q.nth(qs: List<&2, EvQ>, +i: Nat) -> EvQ:
  match qs i:
    case q <> more 0n:
      q
    case q <> more 1n+k:
      ev.q.nth(more, k)
    case _ _:
      EvQ{Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}}

def ev.gen.bin() -> String:
  "run/gcroot-bend-generate/bin/bend-generate"

def ev.jobs(qs: List<&2, EvQ>, +i: Nat, +fmt1: Bool, +ckpt: String, +tokens: String, +threads: String) -> List<&2, C.CbJob>:
  match qs:
    case Nil{}:
      Nil{}
    case +q <> more:
      +env = {["CKPT=" ++ ckpt, "PROMPT=" ++ S.str(ev.asked(fmt1, q)), "TOKENS=" ++ tokens, "TEMPERATURE=0", "TOKENIZER_FILE=weights/code32k.bpe"] : List<&2, String>}
      C.CbJob{i, env, ev.gen.bin(), {["--threads", threads] : List<&2, String>}} <> ev.jobs(more, 1n+i, fmt1, ckpt, tokens, threads)

# tenths of a second, rounded
def ev.secs(+ms: Nat) -> String:
  +t = Nat.div(Nat.add(ms, 50n), 100n)
  Nat.show(Nat.div(t, 10n)) ++ "." ++ Nat.show(Nat.mod(t, 10n))

# a results.nul record
def ev.r.bytes(+n: Nat, +q: EvQ, +closed: Bool, +secs: String, +asked: List<&2, U32>, +term: List<&2, U32>) -> List<&2, U32>:
  match q:
    case EvQ{id, l, u, s, p, p1, r}:
      L.v2.concat([id, [0], S.join([ev.show(n), l, u, s, S.b(Bool.pick(String, closed, "1", "0")), S.b(secs), asked, r, term], 30), [0]])

type EvNb is Data:
  EvNb{n: Nat, res: List<&2, U32>, raw: List<&2, U32>}

def ev.nb.le(a: EvNb, b: EvNb) -> Bool:
  match a b:
    case EvNb{i, x, y} EvNb{j, z, w}:
      Nat.is_le(i, j)

def ev.nb.res(xs: List<&2, EvNb>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case EvNb{n, r, w} <> more:
      S.append(r, ev.nb.res(more))

def ev.nb.raw(xs: List<&2, EvNb>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case EvNb{n, r, w} <> more:
      S.append(w, ev.nb.raw(more))

def ev.q.lang(+q: EvQ) -> String:
  match q:
    case EvQ{id, l, u, s, p, p1, r}:
      S.str(l) ++ " " ++ S.str(s)

# one answer: its records added to DIR's files as it finishes
def ev.gen.one(+count: Nat, +fmt1: Bool, +dir: String, +q: EvQ, r: C.CbRes) -> IO(EvNb):
  match r:
    case C.CbRes{+i, o, +ms}:
      +raw = S.no.nul(S.Out.text(o))
      +asked = ev.asked(fmt1, q)
      +g = ev.past(raw, asked)
      +j = S.find(g, S.b("```"), 0n)
      +secs = ev.secs(ms)
      +res = ev.r.bytes(i, q, ev.is.some(j), secs, asked, ev.upto.at(g, j))
      +rw = L.v2.concat([ev.show(i), [0], raw, [0]])
      do IO<EvNb>:
        S.add(dir ++ "/results.nul", res)
        S.add(dir ++ "/raw.nul", rw)
        Ck.log(Nat.show(count) ++ " " ++ ev.q.lang(q) ++ " " ++ secs ++ " s")
        return EvNb{i, res, rw}

def ev.gen.loop(n: Nat, +done: Nat, +res: Chan(C.CbRes), +qs: List<&2, EvQ>, +fmt1: Bool, +dir: String, acc: List<&2, EvNb>) -> IO(List<&2, EvNb>):
  match n:
    case 0n:
      IO.pure(List<&2, EvNb>, acc)
    case 1n+k:
      do IO<List<&2, EvNb>>:
        +r : C.CbRes <- C.cb.pool.next(res)
        x : EvNb <- ev.gen.one(1n+done, fmt1, dir, ev.q.nth(qs, C.cb.res.i(r)), r)
        ev.gen.loop(k, 1n+done, res, qs, fmt1, dir, x <> acc)

def ev.gen.fin(+n: Nat, +qs: List<&2, EvQ>, +fmt1: Bool, +dir: String, x: Chan(C.CbRes) & C.CbPool) -> IO(Unit):
  (res, p) = x
  do IO<Unit>:
    +xs : List<&2, EvNb> <- ev.gen.loop(n, 0n, res, qs, fmt1, dir, Nil{})
    C.cb.pool.close(p)
    +ys : List<&2, EvNb> = List.sort(~EvNb, ~ev.nb.le, xs)
    S.write(dir ++ "/results.nul", ev.nb.res(ys))
    S.write(dir ++ "/raw.nul", ev.nb.raw(ys))
    Ck.log("gen: " ++ Nat.show(n) ++ " answers in " ++ dir ++ "/results.nul")

def ev.evalset.path() -> IO(String):
  S.env("EVALSET", "run/v2/evalset/prompts.nul")

def ev.gen.run(+ckpt: String, +dir: String, +fmt1: Bool, +k: Nat) -> IO(Unit):
  do IO<Unit>:
    +es : String <- ev.evalset.path()
    kvs : List<&2, EvKv> <- ev.nul(es)
    +qs : List<&2, EvQ> = ev.cut.k(k, ev.qs.of(kvs))
    +tokens : String <- S.env("TOKENS", "100")
    +threads : String <- S.env("THREADS", "5")
    +procs : Nat <- S.env.nat("PROCS", 3n)
    S.mkdir(dir)
    S.write(dir ++ "/results.nul", Nil{})
    S.write(dir ++ "/raw.nul", Nil{})
    Ck.log("gen: " ++ Nat.show(List.length(&2, EvQ, qs)) ++ " prompts of " ++ es ++ ", " ++ Nat.show(procs) ++ " at a time")
    p : C.CbPool <- C.cb.pool.open(procs, ev.jobs(qs, 0n, fmt1, ckpt, tokens, threads))
    ev.gen.fin(List.length(&2, EvQ, qs), qs, fmt1, dir, C.cb.pool.res(p))

def ev.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: gen CKPT DIR FORMAT [K] | control DIR | check DIR | evalset [--both] [--drop FILE] [--out FILE] [N_DIRECT [N_REPAIR]]")

# xs: the arguments after `gen`
def ev.gen(xs: List<String>) -> IO(Unit):
  match xs:
    case c <> d <> +f <> Nil{}:
      ev.gen.run(c, d, String.eq(f, "1"), 0n)
    case c <> d <> +f <> +k <> Nil{}:
      ev.gen.run(c, d, String.eq(f, "1"), C.cb.nat(S.b(k)))
    case _:
      ev.usage()

def ev.control.ref(+q: EvQ) -> List<&2, U32>:
  match q:
    case EvQ{id, l, u, s, p, p1, r}:
      r

def ev.control.rs(qs: List<&2, EvQ>, +i: Nat) -> List<&2, U32>:
  match qs:
    case Nil{}:
      Nil{}
    case +q <> more:
      S.append(ev.r.bytes(i, q, True{}, "0", ev.asked(False{}, q), ev.control.ref(q)), ev.control.rs(more, 1n+i))

# xs: the arguments after `control`
def ev.control(xs: List<String>) -> IO(Unit):
  match xs:
    case +d <> Nil{}:
      do IO<Unit>:
        +es : String <- ev.evalset.path()
        kvs : List<&2, EvKv> <- ev.nul(es)
        +qs : List<&2, EvQ> = ev.qs.of(kvs)
        S.mkdir(d)
        S.write(d ++ "/results.nul", ev.control.rs(qs, 0n))
        IO.print(Nat.show(List.length(&2, EvQ, qs)) ++ " references of " ++ es ++ " in " ++ d ++ "/results.nul")
    case _:
      ev.usage()

# check -----------------------------------------------------------------------------

type EvR is Data:
  EvR{n: Nat, lang: List<&2, U32>, unit: List<&2, U32>, shape: List<&2, U32>, closed: Bool, ref: List<&2, U32>, term: List<&2, U32>}

def ev.r.of(kv: EvKv) -> EvR:
  match kv:
    case EvKv{id, +t}:
      +fs = ev.split(t, 30)
      EvR{C.cb.nat(ev.nth(fs, 0n)), ev.nth(fs, 1n), ev.nth(fs, 2n), ev.nth(fs, 3n), S.eq(ev.nth(fs, 4n), [49]), ev.nth(fs, 7n), ev.rest(fs, 8n)}

def ev.rs.of(kvs: List<&2, EvKv>) -> List<&2, EvR>:
  match kvs:
    case Nil{}:
      Nil{}
    case kv <> more:
      ev.r.of(kv) <> ev.rs.of(more)

def ev.r.le(a: EvR, b: EvR) -> Bool:
  match a b:
    case EvR{i, l1, u1, s1, c1, r1, t1} EvR{j, l2, u2, s2, c2, r2, t2}:
      Nat.is_le(i, j)

def ev.r.units(rs: List<&2, EvR>) -> List<&2, String>:
  match rs:
    case Nil{}:
      Nil{}
    case EvR{n, l, u, s, c, r, t} <> more:
      S.str(u) <> ev.r.units(more)

def ev.holdout(ls: List<&2, String>, +keep: Set(), acc: List<&2, EvKv>) -> IO(List<&2, EvKv>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, EvKv>, acc)
    case l <> more:
      do IO<List<&2, EvKv>>:
        kvs : List<&2, EvKv> <- ev.scan("run/v2/results/" ++ l ++ ".holdout.nul", keep, False{})
        ev.holdout(more, keep, List.append(&2, EvKv, acc, kvs))

def ev.slash(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      (x ++ "/") <> ev.slash(more)

# Bend's source tree: the class trees (run/code-sources*/, by name with the
# slash, as Python's sorted glob) then ~/src
def ev.roots() -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +o : S.Out <- S.run.quiet(".", Nil{}, 600, "find", ["-L", "run", "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-name", "code-sources*"], Nil{})
    return List.sort(~String, ~String.is_le, ev.slash(ev.lines.str(S.split.lines(S.Out.text(o)))))

def ev.cands(rs: List<&2, String>, +cls: String) -> List<&2, String>:
  match rs:
    case Nil{}:
      Nil{}
    case r <> more:
      C.cb.path(r, cls) <> ev.cands(more, cls)

def ev.paths(rs: List<&2, String>, +path: String) -> List<&2, String>:
  match rs:
    case Nil{}:
      Nil{}
    case r <> more:
      C.cb.path(r, path) <> ev.paths(more, path)

def ev.s.keep(hit: Bool, x: String, rest: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      x <> rest
    case False{}:
      rest

# the trees whose copy of path is a file (find's answer: those paths)
def ev.have(rs: List<&2, String>, +path: String, +files: Set()) -> List<&2, String>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      ev.s.keep(L.v2.in(files, C.cb.path(r, path)), r, ev.have(more, path, files))

def ev.reads(rs: List<&2, String>, +path: String, acc: List<&2, EvKv>) -> IO(List<&2, EvKv>):
  match rs:
    case Nil{}:
      IO.pure(List<&2, EvKv>, List.reverse(&2, EvKv, acc))
    case +r <> more:
      do IO<List<&2, EvKv>>:
        xs : List<&2, U32> <- S.read(C.cb.path(r, path))
        ev.reads(more, path, EvKv{S.b(r), xs} <> acc)

def ev.holds(+cs: List<&2, EvKv>, +bs: List<&2, U32>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case EvKv{r, c} <> more:
      S.infix(c, bs)

def ev.holder(cs: List<&2, EvKv>, +bs: List<&2, U32>, at: Bool) -> Maybe<&2, List<&2, U32>>:
  match cs at:
    case EvKv{r, c} <> more True{}:
      Some{r}
    case x <> +more False{}:
      ev.holder(more, bs, ev.holds(more, bs))
    case Nil{} _:
      None{}

def ev.pick.or(m: Maybe<&2, List<&2, U32>>, +d: String) -> String:
  match m:
    case Some{r}:
      S.str(r)
    case None{}:
      d

def ev.pick(+cs: List<&2, EvKv>, +bs: List<&2, U32>, +have: List<&2, String>, +home: String) -> String:
  +d = ev.pick.or(Bool.pick(Maybe<&2, List<&2, U32>>, Nat.is_eq(List.length(&2, String, have), 0n), None{}, Some{S.b(ev.str.nth(have, 0n))}), home)
  ev.pick.or(Bool.pick(Maybe<&2, List<&2, U32>>, Nat.is_eq(S.len(bs), 0n), None{}, ev.holder(cs, bs, ev.holds(cs, bs))), d)

def ev.bend.src(+roots: List<&2, String>, +home: String, +uid: List<&2, U32>, +body: List<&2, U32>) -> IO(String):
  +path = S.str(L.v2.before(L.v2.after(uid, 58), 35))
  +cands = List.append(&2, String, ev.cands(roots, S.str(L.v2.before(uid, 58))), [home])
  do IO<String>:
    +o : S.Out <- S.run.quiet(".", Nil{}, 600, "find", List.append(&1, String, ["-L"], List.append(&1, String, ev.strs(ev.paths(cands, path)), ["-maxdepth", "0", "-type", "f"])), Nil{})
    +have : List<&2, String> = ev.have(cands, path, Set.from_list(ev.lines.str(S.split.lines(S.Out.text(o)))))
    +cs : List<&2, EvKv> <- ev.reads(have, path, Nil{})
    +rp : String <- S.realpath(C.cb.path(ev.pick(cs, ev.strip(body), have, home), S.str(L.v2.before(S.b(path), 47))))
    return S.parent(rp)

def ev.src.if(go: Bool, +roots: List<&2, String>, +home: String, +uid: List<&2, U32>, +body: List<&2, U32>) -> IO(String):
  match go:
    case True{}:
      ev.bend.src(roots, home, uid, body)
    case False{}:
      IO.pure(String, "")

type EvG is Data:
  EvG{key: String, lang: String, src: String, its: List<&2, EvKv>}

def ev.g.is(+gs: List<&2, EvG>, +key: String) -> Bool:
  match gs:
    case Nil{}:
      False{}
    case EvG{k, l, s, i} <> more:
      String.eq(k, key)

def ev.g.add(gs: List<&2, EvG>, at: Bool, +key: String, +lang: String, +src: String, it: EvKv) -> List<&2, EvG>:
  match gs at:
    case EvG{k, l, s, its} <> more True{}:
      EvG{k, l, s, List.append(&2, EvKv, its, [it])} <> more
    case g <> +more False{}:
      g <> ev.g.add(more, ev.g.is(more, key), key, lang, src, it)
    case Nil{} _:
      [EvG{key, lang, src, [it]}]

# the unit record with the term in place of the body: fields 0-6, the term,
# fields 8 and 9, and an empty last field
def ev.ans.rec(+fs: List<&2, List<&2, U32>>, +t: List<&2, U32>) -> List<&2, U32>:
  S.join(List.append(&2, List<&2, U32>, List.take(&2, List<&2, U32>, fs, 7n), t <> List.append(&2, List<&2, U32>, List.take(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, fs, 8n), 2n), [Nil{}])), 30)

def ev.g.put(m: Maybe<&2, List<&2, U32>>, +key: String, +lang: String, +src: String, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, gs: List<&2, EvG>) -> List<&2, EvG>:
  match m:
    case None{}:
      gs
    case Some{t}:
      +g = gs
      ev.g.add(g, ev.g.is(g, key), key, lang, src, EvKv{id, ev.ans.rec(fs, t)})

type EvIt is Data:
  EvIt{id: List<&2, U32>, lang: List<&2, U32>, unit: List<&2, U32>, shape: List<&2, U32>, closed: Bool, lifted: Bool}

type EvB is Data:
  EvB{gs: List<&2, EvG>, its: List<&2, EvIt>}

def ev.rec.must(m: Maybe<&2, List<&2, U32>>, +u: List<&2, U32>) -> IO(List<&2, U32>):
  match m:
    case Some{x}:
      IO.pure(List<&2, U32>, x)
    case None{}:
      IO.die(List<&2, U32>, 1, "check: no held-out record for " ++ S.str(u))

def ev.lifted(+m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{x}:
      True{}
    case None{}:
      False{}

# every answer: its unit's record, the lift, its group
def ev.build(rs: List<&2, EvR>, +recs: List<&2, EvKv>, +roots: List<&2, String>, +home: String, gs: List<&2, EvG>, its: List<&2, EvIt>) -> IO(EvB):
  match rs:
    case Nil{}:
      IO.pure(EvB, EvB{gs, List.reverse(&2, EvIt, its)})
    case EvR{+n, +l, +u, +s, c, ref, term} <> more:
      do IO<EvB>:
        +rec : List<&2, U32> <- ev.rec.must(ev.kv.get(recs, u), u)
        +fs : List<&2, List<&2, U32>> = ev.split(rec, 30)
        +m : Maybe<&2, List<&2, U32>> = ev.lift(ref, ev.nth(fs, 7n), term)
        +bend : Bool = S.eq(l, S.b("bend"))
        +src : String <- ev.src.if(Bool.and(bend, ev.lifted(m)), roots, home, u, ev.nth(fs, 7n))
        +id : List<&2, U32> = L.v2.concat([u, [126], ev.show(n)])
        ev.build(more, recs, roots, home, ev.g.put(m, Bool.pick(String, bend, "bend=" ++ src, S.str(l)), S.str(l), src, id, fs, gs), EvIt{id, l, u, s, c, ev.lifted(m)} <> its)

def ev.g.name(+lang: String, +src: String) -> String:
  Bool.pick(String, String.eq(src, ""), lang, "bend-" ++ String.take(H.sha256(S.b(src)), 8n))

def ev.g.env(+src: String) -> List<String>:
  Bool.pick(List<String>, String.eq(src, ""), ["KEEP_WORK="], ["BEND_SRC=" ++ src, "KEEP_WORK="])

# a verdict a checked unit: the decision field's code (0: passed)
def ev.verdicts(kvs: List<&2, EvKv>) -> List<&2, EvKv>:
  match kvs:
    case Nil{}:
      Nil{}
    case EvKv{k, +v} <> more:
      EvKv{k, L.v2.before(ev.nth(ev.split(v, 30), 11n), 31)} <> ev.verdicts(more)

def ev.g.run(+dir: String, +jobs: String, g: EvG) -> IO(List<&2, EvKv>):
  match g:
    case EvG{k, +lang, +src, +its}:
      +name = ev.g.name(lang, src)
      +ans = dir ++ "/ans." ++ name ++ ".nul"
      +out = dir ++ "/r." ++ name ++ ".nul"
      do IO<List<&2, EvKv>>:
        S.write(ans, ev.kv.bytes(its))
        S.rm(out)
        Ck.log("check " ++ name ++ ": " ++ Nat.show(List.length(&2, EvKv, its)) ++ " answers" ++ Bool.pick(String, String.eq(src, ""), "", " (BEND_SRC " ++ src ++ ")"))
        st : U32 <- S.run.log(".", ev.g.env(src), 3600, "nix", ["run", ".#deploy", "--", "check", lang, ans, out, jobs], dir ++ "/log." ++ name)
        kvs : List<&2, EvKv> <- ev.nul(out)
        return ev.verdicts(kvs)

def ev.g.all(gs: List<&2, EvG>, +dir: String, +jobs: String, acc: List<&2, EvKv>) -> IO(List<&2, EvKv>):
  match gs:
    case Nil{}:
      IO.pure(List<&2, EvKv>, acc)
    case g <> more:
      do IO<List<&2, EvKv>>:
        vs : List<&2, EvKv> <- ev.g.run(dir, jobs, g)
        ev.g.all(more, dir, jobs, List.append(&2, EvKv, acc, vs))

# The report ---------------------------------------------------------------------

type EvT is Data:
  EvT{key: String, lang: List<&2, U32>, shape: List<&2, U32>, n: Nat, pass: Nat, closed: Nat, lifted: Nat}

def ev.t.is(+ts: List<&2, EvT>, +key: String) -> Bool:
  match ts:
    case Nil{}:
      False{}
    case EvT{k, l, s, n, p, c, f} <> more:
      String.eq(k, key)

def ev.b1(+b: Bool) -> Nat:
  Bool.pick(Nat, b, 1n, 0n)

def ev.t.add(ts: List<&2, EvT>, at: Bool, +key: String, +l: List<&2, U32>, +s: List<&2, U32>, +p: Bool, +c: Bool, +f: Bool) -> List<&2, EvT>:
  match ts at:
    case EvT{k, tl, ts2, n, tp, tc, tf} <> more True{}:
      EvT{k, tl, ts2, 1n+n, Nat.add(tp, ev.b1(p)), Nat.add(tc, ev.b1(c)), Nat.add(tf, ev.b1(f))} <> more
    case t <> +more False{}:
      t <> ev.t.add(more, ev.t.is(more, key), key, l, s, p, c, f)
    case Nil{} _:
      [EvT{key, l, s, 1n, ev.b1(p), ev.b1(c), ev.b1(f)}]

def ev.t.le(a: EvT, b: EvT) -> Bool:
  match a b:
    case EvT{k1, l1, s1, n1, p1, c1, f1} EvT{k2, l2, s2, n2, p2, c2, f2}:
      String.is_le(k1, k2)

def ev.pass.of(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{v}:
      S.eq(v, [48])
    case None{}:
      False{}

type EvRp is Data:
  EvRp{ts: List<&2, EvT>, lines: List<&2, List<&2, U32>>}

def ev.tab(its: List<&2, EvIt>, +vs: List<&2, EvKv>, +ts: List<&2, EvT>, lines: List<&2, List<&2, U32>>) -> EvRp:
  match its:
    case Nil{}:
      EvRp{ts, List.reverse(&2, List<&2, U32>, lines)}
    case EvIt{id, +l, +u, +s, +c, +f} <> more:
      +p = ev.pass.of(ev.kv.get(vs, id))
      +key = S.str(L.v2.concat([l, [0], s]))
      +line = L.v2.concat([S.b(Bool.pick(String, p, "PASS", "fail")), [32], ev.padr(l, 7n), [32], ev.padr(s, 6n), [32], ev.chars(u, 100n)])
      ev.tab(more, vs, ev.t.add(ts, ev.t.is(ts, key), key, l, s, p, c, f), line <> lines)

def ev.head(ts: List<&2, EvT>) -> List<&2, List<&2, U32>>:
  match ts:
    case Nil{}:
      Nil{}
    case EvT{k, l, s, n, p, c, f} <> more:
      L.v2.concat([ev.padr(l, 7n), [32], ev.padr(s, 6n), S.b(" pass "), ev.padl(p, 3n), [47], ev.padl(n, 3n), S.b("   closed "), ev.padl(c, 3n), S.b("   lifted "), ev.padl(f, 3n)]) <> ev.head(more)

def ev.sum.p(ts: List<&2, EvT>) -> Nat:
  match ts:
    case Nil{}:
      0n
    case EvT{k, l, s, n, p, c, f} <> more:
      Nat.add(p, ev.sum.p(more))

def ev.sum.n(ts: List<&2, EvT>) -> Nat:
  match ts:
    case Nil{}:
      0n
    case EvT{k, l, s, n, p, c, f} <> more:
      Nat.add(n, ev.sum.n(more))

def ev.report(+dir: String, r: EvRp) -> IO(Unit):
  match r:
    case EvRp{ts, lines}:
      +st = List.sort(~EvT, ~ev.t.le, ts)
      +top = List.append(&2, List<&2, U32>, ev.head(st), [L.v2.concat([S.b("all pass "), ev.show(ev.sum.p(st)), [47], ev.show(ev.sum.n(st))])])
      do IO<Unit>:
        S.write(dir ++ "/report.txt", S.append(S.join(List.append(&2, List<&2, U32>, top, Nil{} <> lines), 10), [10]))
        IO.print(S.str(S.join(top, 10)))

def ev.check.b(+dir: String, +jobs: String, b: EvB) -> IO(Unit):
  match b:
    case EvB{gs, its}:
      do IO<Unit>:
        vs : List<&2, EvKv> <- ev.g.all(gs, dir, jobs, Nil{})
        ev.report(dir, ev.tab(its, vs, Nil{}, Nil{}))

def ev.check.run(+dir: String) -> IO(Unit):
  do IO<Unit>:
    kvs : List<&2, EvKv> <- ev.nul(dir ++ "/results.nul")
    +rs : List<&2, EvR> = List.sort(~EvR, ~ev.r.le, ev.rs.of(kvs))
    recs : List<&2, EvKv> <- ev.holdout(ev.langs(), Set.from_list(ev.r.units(rs)), Nil{})
    +roots : List<&2, String> <- ev.roots()
    +home : String <- S.env("HOME", "")
    +jobs : String <- S.env("CHECK_JOBS", "4")
    b : EvB <- ev.build(rs, List.reverse(&2, EvKv, recs), roots, C.cb.path(home, "src"), Nil{}, Nil{})
    ev.check.b(dir, jobs, b)

# xs: the arguments after `check`
def ev.check(xs: List<String>) -> IO(Unit):
  match xs:
    case +d <> Nil{}:
      ev.check.run(d)
    case _:
      ev.usage()
