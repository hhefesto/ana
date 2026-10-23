import Base
import ../Tokenizer.bend as Tk
import ../Model.bend as Md
import ../Sample.bend as Sm
import ../Tensor.bend as T
import ../Config.bend as C
import ../Decode.bend as D
import ./Spec.bend as A
import ./Episode.bend as E

# The tool loop (docs/AGENT.md): Agent/Spec.bend's `ag.unfold` refined.
# ana decodes until it ends a call line (a tool's heading, `## ghc` ...,
# opening its line after an empty one); the loop runs the tool command with
# the episode so far on standard input and the tool's name as its last
# argument; the tool's standard output is the echo, appended verbatim and
# fed to the decoder as text it did not sample; ana goes on.  ana never
# writes an echo: the decoder stops at the call's newline, and what follows
# it is the tool's.
#
# The tool answers with its exit status: 0 the check passed (the episode is
# solved and ends), 1 it failed (the echo holds the checker's words), any
# other status is the tool's own failure (the episode ends, unsolved).  An
# episode also ends when ana writes EOS, spends a stretch's token budget, or
# has made its quota of calls.
#
# The call line's newline is fed as the newline token even when ana's token
# was a newline with indentation (a tool's heading is followed by an empty
# line in every transcript), so the context reads exactly `## TOOL\n` then
# the echo.  A newline is a word of its own (code32k's pretokenizer), so the
# echo's tokens, encoded alone, are the tokens the whole text would have.

def al.str(+xs: List<&2, U32>) -> String:
  D.dc.Dec.text(Tk.utf8.decode(Nat.add(List.length(&2, U32, xs), 1n), xs, Tk.utf8.mode(xs)))

def al.starts.nl(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 10)
    case Nil{}:
      False{}

def al.tail(+xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case h <> t:
      t
    case Nil{}:
      Nil{}

def al.is.empty(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      False{}

# Where the text is: the current line so far (newest byte first), and
# whether the line before it is empty (true at the text's start)
type AlLine is Data:
  AlLine{line: List<&2, U32>, pe: Bool}

# the line state after a piece of text (a token never holds a newline but
# at its start, so pieces are scanned byte by byte only for the prompt)
def al.line.byte(+l: AlLine, +c: U32) -> AlLine:
  match l:
    case AlLine{+line, pe}:
      Bool.pick(AlLine, U32.is_eq(c, 10), AlLine{Nil{}, al.is.empty(line)}, AlLine{c <> line, pe})

def al.line.of(xs: List<&2, U32>, +l: AlLine) -> AlLine:
  match xs:
    case Nil{}:
      l
    case +c <> t:
      al.line.of(t, al.line.byte(l, c))

# the tool a newline would call here: the current line's heading class 5,
# after an empty line (empty: no call)
def al.call.at(+hs: List<&2, A.Hd>, +l: AlLine) -> List<&2, U32>:
  match l:
    case AlLine{+line, +pe}:
      +full = List.reverse(&2, U32, 10 <> line)
      Bool.pick(List<&2, U32>, Bool.and(pe, Nat.is_eq(A.ag.class(hs, full), 5n)),
        List.drop(&2, U32, List.reverse(&2, U32, line), 3n), Nil{})

def al.first(+xs: List<&2, U32>) -> U32:
  match xs:
    case h <> t:
      h
    case Nil{}:
      10

# the line state after a token (a token holds a newline only at its start)
def al.next.line(+l: AlLine, +tb: List<&2, U32>) -> AlLine:
  match l:
    case AlLine{+line, pe}:
      Bool.pick(AlLine, al.starts.nl(tb), AlLine{List.reverse(&2, U32, al.tail(tb)), al.is.empty(line)}, AlLine{List.append(&2, U32, List.reverse(&2, U32, tb), line), pe})

# The model and its settings, fixed for an episode: dims, the tokenizer,
# the sampling settings, the vocabulary, the byte headings, the newline
# token (the weights live in the engine, Decode.bend's En)
type AlM is Data:
  AlM{dm: Md.Dims, b: Tk.Bpe, st: D.Settings, vocab: Nat, hs: List<&2, A.Hd>, nlt: U32}

def AlM.dm(+m: AlM) -> Md.Dims:
  match m:
    case AlM{dm, b, st, v, hs, n}:
      dm

def AlM.b(+m: AlM) -> Tk.Bpe:
  match m:
    case AlM{dm, b, st, v, hs, n}:
      b

def AlM.st(+m: AlM) -> D.Settings:
  match m:
    case AlM{dm, b, st, v, hs, n}:
      st

def AlM.vocab(+m: AlM) -> Nat:
  match m:
    case AlM{dm, b, st, v, hs, n}:
      v

def AlM.hs(+m: AlM) -> List<&2, A.Hd>:
  match m:
    case AlM{dm, b, st, v, hs, n}:
      hs

def al.of(+md: D.Model, +st: D.Settings) -> AlM:
  match md:
    case D.Model{+c, t, s, +b}:
      AlM{Md.Dims.of(c), b, st, C.Config.vocab(c), A.ag.hds.bytes(), al.first(Tk.Bpe.encode(b, [10]))}

# whether picking token t on this line ends a call line
def al.is.call(+m: AlM, +l: AlLine, +t: U32) -> Bool:
  Bool.and(al.starts.nl(Tk.Bpe.decode(AlM.b(m), t)), Bool.not(al.is.empty(al.call.at(AlM.hs(m), l))))

# Where decoding is: the engine after the tokens fed so far, the pick drawn
# from its logits, whether the pick is EOS, and whether it ends a call line
# (a Type: the engine is one, its dense store threaded)
type AlG is Type:
  AlG{e: D.En, pk: Sm.Pick, stop: Bool, call: Bool}

def al.g.of(+m: AlM, +l: AlLine, px: D.Px) -> AlG:
  match px:
    case D.Px{e, +pk, p}:
      +t = D.dc.Pick.token(pk)
      AlG{e, pk, U32.is_eq(t, Tk.eos()), al.is.call(m, l, t)}

# Where the loop is
#   AlStop    ana ended a stretch (EOS or the budget): what it wrote, tokens
#   AlCalled  ana ended a call line: the tool, what it wrote, tokens, and the
#             decoder after the line (engine, position, RNG, pending bytes)
#   AlPass    the tool passed the check: its echo
#   AlFail    the tool failed the check: its echo, and the decoder as it was
#   AlBroke   the tool could not answer
type AlS is Type:
  AlStop{why: String, out: List<&2, U32>, n: Nat}
  AlCalled{tool: List<&2, U32>, out: List<&2, U32>, n: Nat, e: D.En, pos: Nat, rng: Sm.Rng, pending: List<&2, U32>}
  AlPass{echo: List<&2, U32>}
  AlFail{echo: List<&2, U32>, e: D.En, pos: Nat, rng: Sm.Rng, pending: List<&2, U32>}
  AlBroke{msg: String}

# the call line's newline fed (no logits: the echo comes next)
def al.called(+m: AlM, +pk: Sm.Pick, e: D.En, +pos: Nat, +pending: List<&2, U32>, +out: List<&2, U32>, +count: Nat, +tool: List<&2, U32>) -> IO(AlS):
  match m:
    case AlM{dm, +b, st, vocab, hs, +nlt}:
      +d = D.dc.emit(b, pending, nlt)
      do IO<AlS>:
        IO.write(D.dc.Dec.text(d))
        e2 : D.En <- D.dc.en.feed(e, pos, nlt)
        return AlCalled{tool, List.reverse(&2, U32, 10 <> out), 1n+count, e2, 1n+pos, D.dc.Pick.rng(pk), D.dc.Dec.pending(d)}

def al.halt(stop: Bool, +out: List<&2, U32>, +count: Nat) -> IO(AlS):
  match stop:
    case True{}:
      IO.pure(AlS, AlStop{"eos", List.reverse(&2, U32, out), count})
    case False{}:
      IO.pure(AlS, AlStop{"budget", List.reverse(&2, U32, out), count})

# decode until EOS, the budget, or a call (the pick ends a call line);
# `out` is what ana wrote, newest byte first
def al.gen(n: Nat, g: AlG, +m: AlM, +pos: Nat, +pending: List<&2, U32>, +l: AlLine, +out: List<&2, U32>, +count: Nat) -> IO(AlS):
  match n g:
    case 1n+p AlG{e, +pk, False{}, True{}}:
      al.called(m, pk, e, pos, pending, out, count, al.call.at(AlM.hs(m), l))
    case 1n+p AlG{e, +pk, False{}, False{}}:
      +b = AlM.b(m)
      +t = D.dc.Pick.token(pk)
      +tb = Tk.Bpe.decode(b, t)
      +d = D.dc.emit(b, pending, t)
      +l2 = al.next.line(l, tb)
      do IO<AlS>:
        IO.write(D.dc.Dec.text(d))
        px : D.Px <- D.dc.en.step.pick(e, pos, t, AlM.dm(m), AlM.st(m), AlM.vocab(m), False{}, D.dc.Pick.rng(pk))
        al.gen(p, al.g.of(m, l2, px), m, 1n+pos, D.dc.Dec.pending(d), l2, List.append(&2, U32, List.reverse(&2, U32, tb), out), 1n+count)
    case _ AlG{e, pk, stop, call}:
      al.halt(stop, out, count)

# The episode as written: its segments (Agent/Episode.bend), newest first,
# each with who wrote it (0 the prompt, 1 ana, 2 a tool: its name and exit
# status, 0 passed, 1 failed); the calls made, the tokens ana drew, how it
# ended (solved, eos, budget, calls, tool-error), and the tool last called
type AlEp is Data:
  AlEp{segs: List<&2, E.EpSeg>, calls: Nat, tokens: Nat, end: String, tool: List<&2, U32>}

def al.ep.add(+e: AlEp, +who: Nat, +x: List<&2, U32>, +n: Nat) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, tl}:
      AlEp{E.EpSeg{who, Nil{}, 0, x} <> ss, c, Nat.add(k, n), f, tl}

# the tool's turn: its echo, written by the tool last called, with its status
def al.ep.echo(+e: AlEp, +code: U32, +x: List<&2, U32>) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, +tl}:
      AlEp{E.EpSeg{2n, tl, code, x} <> ss, c, k, f, tl}

def al.ep.call(+e: AlEp, +tool: List<&2, U32>) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, tl}:
      AlEp{ss, 1n+c, k, f, tool}

def al.ep.fin(+e: AlEp, +why: String) -> AlEp:
  match e:
    case AlEp{ss, c, k, f, tl}:
      AlEp{ss, c, k, why, tl}

# the episode's text, in order (Episode.bend `ep.law.newest`: the newest-first
# fold is `ep.text` of the segments in order, the text the log renders)
def al.ep.text(+e: AlEp) -> List<&2, U32>:
  match e:
    case AlEp{ss, c, k, f, tl}:
      E.ep.text.newest(ss, Nil{})


def al.status(pass: Bool, fail: Bool, +st: U32, +so: String, +se: String, e: D.En, +pos: Nat, +rng: Sm.Rng, +pending: List<&2, U32>) -> AlS:
  match pass fail:
    case True{} _:
      AlPass{Tk.utf8.bytes(so)}
    case False{} True{}:
      AlFail{Tk.utf8.bytes(so), e, pos, rng, pending}
    case False{} False{}:
      AlBroke{"the tool failed (exit " ++ U32.show(st) ++ "): " ++ se}

def al.tool.of(r: Result<&1, &1, U32 & String, U32 & (String & String)>, e: D.En, +pos: Nat, +rng: Sm.Rng, +pending: List<&2, U32>) -> AlS:
  match r:
    case Done{(+st, (so, se))}:
      al.status(U32.is_eq(st, 0), U32.is_eq(st, 1), st, so, se, e, pos, rng, pending)
    case Fail{(code, msg)}:
      AlBroke{"the tool did not run: " ++ msg}

# the decoder fed the echo, then a new stretch
def al.resume(+m: AlM, +budget: Nat, +echo: List<&2, U32>, e: D.En, +pos: Nat, +rng: Sm.Rng, +pending: List<&2, U32>) -> IO(AlS):
  +ids = Tk.Bpe.encode(AlM.b(m), echo)
  +l = al.line.of(echo, AlLine{Nil{}, False{}})
  do IO<AlS>:
    px : D.Px <- D.dc.en.prefill.pick(ids, e, pos, AlM.dm(m), AlM.st(m), AlM.vocab(m), False{}, rng)
    al.gen(budget, al.g.of(m, l, px), m, Nat.add(pos, List.length(&2, U32, ids)), pending, l, Nil{}, 0n)

# The loop: `fuel` is two steps a call (the call, then resuming after a
# failed check), so at most fuel / 2 calls; `cmd` the tool command (run by
# sh, the tool's name its argument $1, the episode so far its standard input)
def al.round(+fuel: Nat, +m: AlM, +cmd: String, +budget: Nat, s: AlS, +ep: AlEp) -> IO(AlEp):
  match fuel s:
    case _ AlStop{why, +out, +n}:
      IO.pure(AlEp, al.ep.fin(al.ep.add(ep, 1n, out, n), why))
    case 0n AlCalled{tool, +out, +n, e, pos, rng, pending}:
      IO.pure(AlEp, al.ep.fin(al.ep.add(ep, 1n, out, n), "calls"))
    case 1n+p AlCalled{+tool, +out, +n, e, +pos, +rng, +pending}:
      +ep2 = al.ep.call(al.ep.add(ep, 1n, out, n), tool)
      do IO<AlEp>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run("sh", ["-c", cmd ++ " \"$1\"", "sh", al.str(tool)], al.str(al.ep.text(ep2)), 16777216, 3600000)
        al.round(p, m, cmd, budget, al.tool.of(r, e, pos, rng, pending), ep2)
    case _ AlPass{+echo}:
      do IO<AlEp>:
        IO.write(al.str(echo))
        return al.ep.fin(al.ep.echo(ep, 0, echo), "solved")
    case _ AlBroke{msg}:
      do IO<AlEp>:
        IO.print_err("agent: " ++ msg)
        return al.ep.fin(ep, "tool-error")
    case 1n+p AlFail{+echo, e, +pos, +rng, +pending}:
      do IO<AlEp>:
        IO.write(al.str(echo))
        s2 : AlS <- al.resume(m, budget, echo, e, pos, rng, pending)
        al.round(p, m, cmd, budget, s2, al.ep.echo(ep, 1, echo))
    case 0n AlFail{+echo, e, pos, rng, pending}:
      do IO<AlEp>:
        IO.write(al.str(echo))
        return al.ep.fin(al.ep.echo(ep, 1, echo), "calls")

# An episode from a prompt on an engine with empty states: BOS and the
# prompt fed, then the loop.  The prompt is written to standard output
# first, then everything ana and the tools write, as it comes: the
# transcript.
def al.episode(+md: D.Model, e: D.En, +st: D.Settings, +seed: String, +cmd: String, +calls: Nat, +budget: Nat, +prompt: List<&2, U32>) -> IO(AlEp):
  +m = al.of(md, st)
  +ids = List.append(&2, U32, [Tk.bos()], Tk.Bpe.encode(D.dc.Model.b(md), prompt))
  +l = al.line.of(prompt, AlLine{Nil{}, True{}})
  do IO<AlEp>:
    IO.write(al.str(prompt))
    px : D.Px <- D.dc.en.prefill.pick(ids, e, 0n, AlM.dm(m), AlM.st(m), AlM.vocab(m), False{}, D.dc.rng.of(seed))
    s : AlS <- al.gen(budget, al.g.of(m, l, px), m, List.length(&2, U32, ids), Nil{}, l, Nil{}, 0n)
    al.round(Nat.mul(2n, calls), m, cmd, budget, s, AlEp{[E.EpSeg{0n, Nil{}, 0, prompt}], 0n, 0n, "", Nil{}})
