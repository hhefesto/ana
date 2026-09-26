import Base
import ./Tokenizer.bend as Tk
import ./Nul.bend as Ns
import ./Bytes.bend as B

# pack: master's `formal-transformer pack-stdin` (Main.hs packStdin,
# FormalTransformer/Pack.hs), with the streams in files:
#
#   bend-pack INPUT.nul OUTPUT.nul [--target N] [--group] [--prefix P]
#                                  [--separator S] [--stats]
#
# Meaning.  The trainer cuts each document into whole windows and drops
# the remainder, so a document shorter than one window teaches nothing.
# Packing joins consecutive documents, `separator` ("\n\n") between them,
# until the joined text reaches `target` bytes (131072); a document is
# never split, so one larger than the target is a pack of its own.  With
# --group, a pack holds documents of one group only (an id's text before
# its first '/'): a group change closes the held pack, so a window never
# straddles two repositories.  Empty documents are dropped.  Packs are
# named prefix-00000000, prefix-00000001, ... ("pack" by default).
#
# Every decision here is master's packStep / packFlush, one for one; the
# stats line (on stderr, with --stats) is master's, which bend-plan-corpus
# parses.

type Cfg is Data:
  Cfg{target: Nat, prefix: List<&2, U32>, sep: List<&2, U32>, grouped: Bool, stats: Bool, problem: String}

# The state: the held texts (newest first), their joined length, the held
# group, and the packs emitted so far.
type St is Data:
  St{held: List<&2, List<&2, U32>>, bytes: Nat, group: List<&2, U32>, emitted: Nat}

# The packs emitted so far, newest first, beside the state.
type Out is Data:
  Out{st: St, out: List<&2, Ns.Doc>}

def Cfg.default() -> Cfg:
  Cfg{131072n, Tk.str.bytes("pack"), [10, 10], False{}, False{}, ""}

def St.fresh() -> St:
  St{Nil{}, 0n, Nil{}, 0n}

def head.slash(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 47)
    case Nil{}:
      False{}

def group.go(+xs: List<&2, U32>, slash: Bool) -> List<&2, U32>:
  match xs slash:
    case h <> +t False{}:
      h <> group.go(t, head.slash(t))
    case _ _:
      Nil{}

# a group: the id up to its first '/'
def group.of(+xs: List<&2, U32>) -> List<&2, U32>:
  group.go(xs, head.slash(xs))

def has.slash(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(U32.is_eq(h, 47), has.slash(t))

def list.eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case a <> s b <> t:
      Bool.and(U32.is_eq(a, b), list.eq(s, t))
    case _ _:
      False{}

# printf "%s-%08d"
def digits(n: Nat) -> List<&2, U32>:
  Tk.str.bytes(Nat.show(n))

def pad8(+ds: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, List.replicate(U32, Nat.sub(8n, List.length(&2, U32, ds)), 48), ds)

def pack.id(+prefix: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  List.append(&2, U32, prefix, 45 <> pad8(digits(n)))

def join(+sep: List<&2, U32>, ts: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ts:
    case Nil{}:
      Nil{}
    case t <> Nil{}:
      t
    case t <> more:
      List.append(&2, U32, t, List.append(&2, U32, sep, join(sep, more)))

def flush.emit(c: Cfg, held: List<&2, List<&2, U32>>, +n: Nat, out: List<&2, Ns.Doc>) -> Out:
  match c:
    case Cfg{target, prefix, sep, g, s, p}:
      Out{St{Nil{}, 0n, Nil{}, 1n+n}, Ns.Doc{pack.id(prefix, n), join(sep, List.reverse(&2, List<&2, U32>, held))} <> out}

def flush.if(+c: Cfg, held: List<&2, List<&2, U32>>, +n: Nat, out: List<&2, Ns.Doc>, bytes: Nat, group: List<&2, U32>) -> Out:
  match held:
    case Nil{}:
      Out{St{Nil{}, bytes, group, n}, out}
    case h <> t:
      flush.emit(c, h <> t, n, out)

# packFlush: emit what is held, if anything
def flush(+c: Cfg, o: Out) -> Out:
  match o:
    case Out{St{held, bytes, group, +n}, out}:
      flush.if(c, held, n, out, bytes, group)

def add.if(held: List<&2, List<&2, U32>>, +bytes: Nat, group: List<&2, U32>, n: Nat, out: List<&2, Ns.Doc>, +grp: List<&2, U32>, +text: List<&2, U32>, +seplen: Nat) -> Out:
  match held:
    case Nil{}:
      Out{St{[text], Nat.add(bytes, List.length(&2, U32, text)), grp, n}, out}
    case h <> t:
      Out{St{text <> h <> t, Nat.add(bytes, Nat.add(List.length(&2, U32, text), seplen)), group, n}, out}

# the document added to what is held (the separator counts only between
# pieces: the first piece of a pack pays none)
def add(+c: Cfg, o: Out, +grp: List<&2, U32>, +text: List<&2, U32>) -> Out:
  match c o:
    case Cfg{target, prefix, +sep, g, s, p} Out{St{held, +bytes, group, n}, out}:
      add.if(held, bytes, group, n, out, grp, text, List.length(&2, U32, sep))

def Out.bytes(+o: Out) -> Nat:
  match o:
    case Out{St{held, bytes, group, n}, out}:
      bytes

def Out.started(+o: Out) -> Bool:
  match o:
    case Out{St{held, bytes, group, n}, out}:
      Bool.not(Nat.is_eq(List.length(&2, List<&2, U32>, held), 0n))

def Out.group(+o: Out) -> List<&2, U32>:
  match o:
    case Out{St{held, bytes, group, n}, out}:
      group

def full.if(+c: Cfg, +o: Out, full: Bool) -> Out:
  match full:
    case True{}:
      flush(c, o)
    case False{}:
      o

def Cfg.target(+c: Cfg) -> Nat:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      t

def Cfg.grouped(+c: Cfg) -> Bool:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      g

def Cfg.stats(+c: Cfg) -> Bool:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      st

def Cfg.problem(+c: Cfg) -> String:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      pr

def boundary.if(+c: Cfg, +o: Out, boundary: Bool) -> Out:
  match boundary:
    case True{}:
      flush(c, o)
    case False{}:
      o

# packStep: a group change closes the held pack; then the document joins
# what is held; a pack that reaches the target is emitted
def step.text(+c: Cfg, +o: Out, +grp: List<&2, U32>, +text: List<&2, U32>) -> Out:
  +o1 = boundary.if(c, o, Bool.and(Cfg.grouped(c), Bool.and(Out.started(o), Bool.not(list.eq(Out.group(o), grp)))))
  +o2 = add(c, o1, grp, text)
  full.if(c, o2, Nat.is_ge(Out.bytes(o2), Cfg.target(c)))

def step.empty(+c: Cfg, +o: Out, +grp: List<&2, U32>, +text: List<&2, U32>, empty: Bool) -> Out:
  match empty:
    case True{}:
      o
    case False{}:
      step.text(c, o, grp, text)

def step(+c: Cfg, +o: Out, d: Ns.Doc) -> Out:
  match d:
    case Ns.Doc{i, +t}:
      step.empty(c, o, group.of(i), t, Nat.is_eq(List.length(&2, U32, t), 0n))

def pack.go(ds: List<&2, Ns.Doc>, +c: Cfg, +o: Out) -> Out:
  match ds:
    case Nil{}:
      flush(c, o)
    case d <> more:
      pack.go(more, c, step(c, o, d))

def Out.out(o: Out) -> List<&2, Ns.Doc>:
  match o:
    case Out{st, out}:
      List.reverse(&2, Ns.Doc, out)

# the packs, in order
def pack(+c: Cfg, ds: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  Out.out(pack.go(ds, c, Out{St.fresh(), Nil{}}))

# Options -------------------------------------------------------------------

def Cfg.fail(c: Cfg, why: String) -> Cfg:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      Cfg{t, p, s, g, st, why}

def opt.target.if(c: Cfg, zero: Bool) -> Cfg:
  match zero:
    case True{}:
      Cfg.fail(c, "pack: --target must be a positive integer")
    case False{}:
      c

def opt.target(c: Cfg, m: Maybe<&2, Nat>) -> Cfg:
  match c m:
    case Cfg{t, p, s, g, st, pr} Some{+n}:
      opt.target.if(Cfg{n, p, s, g, st, pr}, Nat.is_eq(n, 0n))
    case Cfg{t, p, s, g, st, pr} None{}:
      Cfg{t, p, s, g, st, "pack: --target must be a positive integer"}

def opt.prefix.if(c: Cfg, empty: Bool, slash: Bool) -> Cfg:
  match empty slash:
    case True{} _:
      Cfg.fail(c, "pack: --prefix must not be empty")
    case False{} True{}:
      Cfg.fail(c, "pack: --prefix must not contain '/' (it delimits the group)")
    case False{} False{}:
      c

def opt.prefix(c: Cfg, +v: List<&2, U32>) -> Cfg:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      opt.prefix.if(Cfg{t, v, s, g, st, pr}, Nat.is_eq(List.length(&2, U32, v), 0n), has.slash(v))

def opt.sep(c: Cfg, v: List<&2, U32>) -> Cfg:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      Cfg{t, p, v, g, st, pr}

def opt.group(c: Cfg) -> Cfg:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      Cfg{t, p, s, True{}, st, pr}

def opt.stats(c: Cfg) -> Cfg:
  match c:
    case Cfg{t, p, s, g, st, pr}:
      Cfg{t, p, s, g, True{}, pr}

# The options after the two paths, one at a time.  An option that takes a
# value consumes it too; anything unrecognised (a value option missing its
# value included, as master's parser had it) fails the whole parse.
def opt.kind(+x: String) -> Nat:
  Bool.pick(Nat, String.eq(x, "--stats"), 1n,
    Bool.pick(Nat, String.eq(x, "--group"), 2n,
      Bool.pick(Nat, String.eq(x, "--target"), 3n,
        Bool.pick(Nat, String.eq(x, "--prefix"), 4n,
          Bool.pick(Nat, String.eq(x, "--separator"), 5n, 6n)))))

def head.kind(+xs: List<&2, String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case x <> t:
      opt.kind(x)

def opts(xs: List<&2, String>, c: Cfg, k: Nat) -> Cfg:
  match xs k:
    case Nil{} _:
      c
    case x <> +more 1n:
      opts(more, opt.stats(c), head.kind(more))
    case x <> +more 2n:
      opts(more, opt.group(c), head.kind(more))
    case x <> v <> +more 3n:
      opts(more, opt.target(c, Nat.read(v)), head.kind(more))
    case x <> v <> +more 4n:
      opts(more, opt.prefix(c, Tk.str.bytes(v)), head.kind(more))
    case x <> v <> +more 5n:
      opts(more, opt.sep(c, Tk.str.bytes(v)), head.kind(more))
    case x <> more _:
      Cfg.fail(c, "pack: unrecognized option " ++ x)

def relist(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> relist(t)

# Main ------------------------------------------------------------------------

def slashless.pick(ok: Bool, i: List<&2, U32>, rest: String) -> String:
  match ok:
    case False{}:
      "pack: --group requires ids of the form group/path, got " ++ B.Bytes.to_string(i) ++ " -- grouping a slash-free stream disables packing entirely"
    case True{}:
      rest

# the first id without a '/', as a refusal ("" when every id has one)
def slashless.go(ds: List<&2, Ns.Doc>) -> String:
  match ds:
    case Nil{}:
      ""
    case Ns.Doc{+i, t} <> more:
      slashless.pick(has.slash(i), i, slashless.go(more))

def slashless(grouped: Bool, ds: List<&2, Ns.Doc>) -> String:
  match grouped:
    case True{}:
      slashless.go(ds)
    case False{}:
      ""

def empties(ds: List<&2, Ns.Doc>) -> Nat:
  match ds:
    case Nil{}:
      0n
    case Ns.Doc{i, +t} <> more:
      Nat.add(Bool.pick(Nat, Nat.is_eq(List.length(&2, U32, t), 0n), 1n, 0n), empties(more))

def report(+c: Cfg, +ins: Nat, +outs: Nat, +dropped: Nat, on: Bool) -> IO(Unit):
  match on:
    case True{}:
      IO.print_err("pack-stdin: " ++ Nat.show(ins) ++ " documents in, " ++ Nat.show(outs) ++ " packed documents out, " ++ Nat.show(dropped) ++ " empty documents dropped")
    case False{}:
      IO.pure(Unit, Unit{})

def emit(+c: Cfg, +out: String, +ds: List<&2, Ns.Doc>, problem: String, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, problem)
    case True{}:
      +ps = pack(c, ds)
      do IO<Unit>:
        Ns.write(out, Ns.put(ps, Nil{}))
        report(c, List.length(&2, Ns.Doc, ds), List.length(&2, Ns.Doc, ps), empties(ds), Cfg.stats(c))

def stream(+c: Cfg, +out: String, +d: Ns.Docs, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "pack-stdin: " ++ Ns.Docs.problem(d))
    case True{}:
      +ds = Ns.Docs.docs(d)
      +bad = slashless(Cfg.grouped(c), ds)
      emit(c, out, ds, bad, String.is_empty(bad))

def run(+c: Cfg, inp: String, +out: String, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 2, Cfg.problem(c))
    case True{}:
      do IO<Unit>:
        +xs : List<&2, U32> <- Ns.read(inp)
        +d : Ns.Docs <- IO.pure(Ns.Docs, Ns.docs(xs))
        stream(c, out, d, String.is_empty(Ns.Docs.problem(d)))

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case inp <> out <> more:
      +rest = relist(more)
      +c = opts(rest, Cfg.default(), head.kind(rest))
      run(c, inp, out, String.is_empty(Cfg.problem(c)))
    case _:
      IO.die(Unit, 2, "usage: bend-pack INPUT.nul OUTPUT.nul [--target N] [--group] [--prefix P] [--separator S] [--stats]")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args(xs)
