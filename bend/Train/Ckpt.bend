import Base
import ../Num.bend as N
import ../Tensor.bend as T
import ../Config.bend as C
import ../Model.bend as Md
# The Bend-native checkpoint (BTC1).  Bend2 writes Strings only, and a
# String cannot carry raw bytes, so this format is text: a header, then the
# parameters in namedLayout order as eight hex digits per f32 (the IEEE
# bits, exact).  Master's FTC2 checkpoints stay readable through
# Checkpoint.bend; BTC1 is what the Bend trainer writes and Generate reads
# back.
#
#   BTC1
#   <vocab> <ctx> <d> <ff> <layers> <heads> <rglru> <qk> <sinks> <tied>
#   <tokenizer identity>
#   <step>
#   <parameter count>
#   <hex words, 16 per line>
def bit.s(x: Bool) -> String:
  match x:
    case True{}:
      "1"
    case False{}:
      "0"

def Config.line(+c: C.Config) -> String:
  Nat.show(C.Config.vocab(c)) ++ " " ++ Nat.show(C.Config.ctx(c)) ++ " " ++ Nat.show(C.Config.d(c)) ++ " "
    ++ Nat.show(C.Config.f(c)) ++ " " ++ Nat.show(C.Config.layers(c)) ++ " " ++ Nat.show(C.Config.heads(c)) ++ " "
    ++ bit.s(C.Config.rglru(c)) ++ " " ++ bit.s(C.Config.qk(c)) ++ " " ++ bit.s(C.Config.sinks(c)) ++ " " ++ bit.s(C.Config.tied(c))

# Flattening, in layout order -----------------------------------------------

def V.flat(+v: T.V, acc: List<&2, F32>) -> List<&2, F32>:
  T.V.to_list.go(v, acc)

def M.flat(+m: T.M, acc: List<&2, F32>) -> List<&2, F32>:
  match m:
    case T.ML{r}:
      V.flat(r, acc)
    case T.MN{l, r}:
      M.flat(l, M.flat(r, acc))
    case T.MZ{}:
      acc

def Block.flat(+b: Md.Block, acc: List<&2, F32>) -> List<&2, F32>:
  match b:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      V.flat(ra, M.flat(wq, M.flat(wk, M.flat(wv, M.flat(wo, M.flat(wa, V.flat(lam, V.flat(rf, M.flat(wg, M.flat(wu, M.flat(wd, acc)))))))))))
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sk, rf, wg, wu, wd}:
      V.flat(ra, M.flat(wq, M.flat(wk, M.flat(wv, M.flat(wo, V.flat(gq, V.flat(gk, V.flat(sk, V.flat(rf, M.flat(wg, M.flat(wu, M.flat(wd, acc))))))))))))

def Blocks.flat(bs: List<&2, Md.Block>, acc: List<&2, F32>) -> List<&2, F32>:
  match bs:
    case Nil{}:
      acc
    case b <> t:
      Block.flat(b, Blocks.flat(t, acc))

def Weights.flat(+w: Md.Weights) -> List<&2, F32>:
  match w:
    case Md.Weights{e, bs, f, u}:
      M.flat(e, Blocks.flat(bs, V.flat(f, M.flat(u, Nil{}))))

# hex lines, 16 words each (a right fold: linear in the parameter count)
def hex.lines(xs: List<&2, F32>, +k: Nat) -> String:
  match xs k:
    case Nil{} _:
      "\n"
    case h <> t 0n:
      "\n" ++ N.U32.hex(F32.bits(h)) ++ hex.lines(t, 15n)
    case h <> t 1n+p:
      N.U32.hex(F32.bits(h)) ++ hex.lines(t, p)

def render(+c: C.Config, +tok: String, +step: Nat, +w: Md.Weights) -> String:
  +xs = Weights.flat(w)
  "BTC1\n" ++ Config.line(c) ++ "\n" ++ tok ++ "\n" ++ Nat.show(step) ++ "\n" ++ Nat.show(List.length(&2, F32, xs))
    ++ hex.lines(xs, 0n)

def save.fin(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, x) = r
  do IO<Unit>:
    u : Unit <- IO.pass(Unit, x)
    File.close(f)

def save(+path: String, +c: C.Config, +tok: String, +step: Nat, +w: Md.Weights) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "w"))
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, render(c, tok, step, w))
    save.fin(r)

# Reading -------------------------------------------------------------------

type Take is Data:
  Take{xs: List<&2, F32>, rest: List<&2, F32>}

def Take.put(h: F32, t: Take) -> Take:
  match t:
    case Take{a, b}:
      Take{h <> a, b}

def take(+n: Nat, xs: List<&2, F32>) -> Take:
  match n xs:
    case 0n _:
      Take{Nil{}, xs}
    case 1n+p h <> t:
      Take.put(h, take(p, t))
    case 1n+p Nil{}:
      Take{Nil{}, Nil{}}

def Take.xs(+t: Take) -> List<&2, F32>:
  match t:
    case Take{a, b}:
      a

def Take.rest(+t: Take) -> List<&2, F32>:
  match t:
    case Take{a, b}:
      b

type VT is Data:
  VT{v: T.V, rest: List<&2, F32>}

type MT is Data:
  MT{m: T.M, rest: List<&2, F32>}

type RT is Data:
  RT{rows: List<&2, T.V>, rest: List<&2, F32>}

def VT.v(+t: VT) -> T.V:
  match t:
    case VT{v, r}:
      v

def VT.rest(+t: VT) -> List<&2, F32>:
  match t:
    case VT{v, r}:
      r

def MT.m(+t: MT) -> T.M:
  match t:
    case MT{m, r}:
      m

def MT.rest(+t: MT) -> List<&2, F32>:
  match t:
    case MT{m, r}:
      r

def RT.cons(+v: T.V, r: RT) -> RT:
  match r:
    case RT{rs, rest}:
      RT{v <> rs, rest}

def vt(+n: Nat, +xs: List<&2, F32>) -> VT:
  +t = take(n, xs)
  VT{T.V.build(T.depth(n), Take.xs(t)), Take.rest(t)}

def vt.maybe(on: Bool, +n: Nat, +xs: List<&2, F32>) -> VT:
  match on:
    case True{}:
      vt(n, xs)
    case False{}:
      VT{T.VZ{}, xs}

def rows.take(r: Nat, +cols: Nat, +xs: List<&2, F32>) -> RT:
  match r:
    case 0n:
      RT{Nil{}, xs}
    case 1n+p:
      +t = vt(cols, xs)
      RT.cons(VT.v(t), rows.take(p, cols, VT.rest(t)))

def mt.fin(+r: Nat, t: RT) -> MT:
  match t:
    case RT{rs, rest}:
      MT{T.M.build(T.depth(r), rs), rest}

def mt(+r: Nat, +c: Nat, +xs: List<&2, F32>) -> MT:
  mt.fin(r, rows.take(r, c, xs))

type BT is Data:
  BT{b: Md.Block, rest: List<&2, F32>}

def BT.b(+t: BT) -> Md.Block:
  match t:
    case BT{b, r}:
      b

def BT.rest(+t: BT) -> List<&2, F32>:
  match t:
    case BT{b, r}:
      r

def block.gla.t(+c: C.Config, +xs: List<&2, F32>) -> BT:
  +d = C.Config.d(c)
  +f = C.Config.f(c)
  +ra = vt(d, xs)
  +wq = mt(d, d, VT.rest(ra))
  +wk = mt(d, d, MT.rest(wq))
  +wv = mt(d, d, MT.rest(wk))
  +wo = mt(d, d, MT.rest(wv))
  +wa = mt(d, d, MT.rest(wo))
  +lam = vt.maybe(C.Config.rglru(c), d, MT.rest(wa))
  +rf = vt(d, VT.rest(lam))
  +wg = mt(f, d, VT.rest(rf))
  +wu = mt(f, d, MT.rest(wg))
  +wd = mt(d, f, MT.rest(wu))
  BT{Md.GlaB{VT.v(ra), MT.m(wq), MT.m(wk), MT.m(wv), MT.m(wo), MT.m(wa), VT.v(lam), VT.v(rf), MT.m(wg), MT.m(wu), MT.m(wd)}, MT.rest(wd)}

def block.sm.t(+c: C.Config, +xs: List<&2, F32>) -> BT:
  +d = C.Config.d(c)
  +f = C.Config.f(c)
  +hd = C.Config.hd(c)
  +ra = vt(d, xs)
  +wq = mt(d, d, VT.rest(ra))
  +wk = mt(d, d, MT.rest(wq))
  +wv = mt(d, d, MT.rest(wk))
  +wo = mt(d, d, MT.rest(wv))
  +gq = vt.maybe(C.Config.qk(c), hd, MT.rest(wo))
  +gk = vt.maybe(C.Config.qk(c), hd, VT.rest(gq))
  +sk = vt.maybe(C.Config.sinks(c), C.Config.heads(c), VT.rest(gk))
  +rf = vt(d, VT.rest(sk))
  +wg = mt(f, d, VT.rest(rf))
  +wu = mt(f, d, MT.rest(wg))
  +wd = mt(d, f, MT.rest(wu))
  BT{Md.SmB{VT.v(ra), MT.m(wq), MT.m(wk), MT.m(wv), MT.m(wo), VT.v(gq), VT.v(gk), VT.v(sk), VT.v(rf), MT.m(wg), MT.m(wu), MT.m(wd)}, MT.rest(wd)}

def block.t(k: C.LayerKind, +c: C.Config, +xs: List<&2, F32>) -> BT:
  match k:
    case C.Gla{}:
      block.gla.t(c, xs)
    case C.Softmax{}:
      block.sm.t(c, xs)

type BsT is Data:
  BsT{bs: List<&2, Md.Block>, rest: List<&2, F32>}

def BsT.cons(+b: Md.Block, r: BsT) -> BsT:
  match r:
    case BsT{bs, rest}:
      BsT{b <> bs, rest}

def blocks.t(n: Nat, +c: C.Config, +i: Nat, +xs: List<&2, F32>) -> BsT:
  match n:
    case 0n:
      BsT{Nil{}, xs}
    case 1n+p:
      +t = block.t(C.kind_of(i), c, xs)
      BsT.cons(BT.b(t), blocks.t(p, c, 1n+i, BT.rest(t)))

def BsT.bs(+t: BsT) -> List<&2, Md.Block>:
  match t:
    case BsT{b, r}:
      b

def BsT.rest(+t: BsT) -> List<&2, F32>:
  match t:
    case BsT{b, r}:
      r

def untied.t(on: Bool, +c: C.Config, +xs: List<&2, F32>) -> T.M:
  match on:
    case True{}:
      MT.m(mt(C.Config.vocab(c), C.Config.d(c), xs))
    case False{}:
      T.MZ{}

# the weights from their flat layout-order values
def Weights.of(+c: C.Config, +xs: List<&2, F32>) -> Md.Weights:
  +e = mt(C.Config.vocab(c), C.Config.d(c), xs)
  +bs = blocks.t(C.Config.layers(c), c, 0n, MT.rest(e))
  +fin = vt(C.Config.d(c), BsT.rest(bs))
  Md.Weights{MT.m(e), BsT.bs(bs), VT.v(fin), untied.t(Bool.not(C.Config.tied(c)), c, VT.rest(fin))}

# Text parsing --------------------------------------------------------------

type Line is Data:
  Line{text: List<&2, U32>, rest: List<&2, U32>}

def Line.put(h: U32, l: Line) -> Line:
  match l:
    case Line{a, b}:
      Line{h <> a, b}

def line.nl(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 10)
    case Nil{}:
      False{}

def line.go(xs: List<&2, U32>, stop: Bool) -> Line:
  match xs stop:
    case +h <> +t False{}:
      Line.put(h, line.go(t, line.nl(t)))
    case h <> t True{}:
      Line{Nil{}, t}
    case Nil{} _:
      Line{Nil{}, Nil{}}

def line(+xs: List<&2, U32>) -> Line:
  line.go(xs, line.nl(xs))

def Line.text(+l: Line) -> List<&2, U32>:
  match l:
    case Line{a, b}:
      a

def Line.rest(+l: Line) -> List<&2, U32>:
  match l:
    case Line{a, b}:
      b

def hexv.if(digit: Bool, +c: U32) -> U32:
  match digit:
    case True{}:
      U32.sub(c, 48)
    case False{}:
      U32.sub(c, 87)

def hexv(+c: U32) -> U32:
  hexv.if(U32.is_lt(c, 58), c)

def no.nl.if(nl: Bool, +h: U32, rest: List<&2, U32>) -> List<&2, U32>:
  match nl:
    case True{}:
      rest
    case False{}:
      h <> rest

def no.nl(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      no.nl.if(U32.is_eq(h, 10), h, no.nl(t))

def hexword(+a: U32, +b: U32, +c: U32, +d: U32, +e: U32, +f: U32, +g: U32, +h: U32) -> F32:
  +hi = U32.or(U32.or(U32.shln(hexv(a), 28n), U32.shln(hexv(b), 24n)), U32.or(U32.shln(hexv(c), 20n), U32.shln(hexv(d), 16n)))
  +lo = U32.or(U32.or(U32.shln(hexv(e), 12n), U32.shln(hexv(f), 8n)), U32.or(U32.shln(hexv(g), 4n), hexv(h)))
  N.F32.from_bits(U32.or(hi, lo))

# eight hex digits per word
def words(xs: List<&2, U32>) -> List<&2, F32>:
  match xs:
    case a <> b <> c <> d <> e <> f <> g <> h <> t:
      hexword(a, b, c, d, e, f, g, h) <> words(t)
    case _:
      Nil{}

def sp.at(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 32)
    case Nil{}:
      False{}

# space-separated decimals (the flag: a space starts here)
def nums(xs: List<&2, U32>, +acc: Nat, +out: List<&2, Nat>, sp: Bool) -> List<&2, Nat>:
  match xs sp:
    case Nil{} _:
      List.reverse(&2, Nat, acc <> out)
    case h <> +t True{}:
      nums(t, 0n, acc <> out, sp.at(t))
    case +h <> +t False{}:
      nums(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48))), out, sp.at(t))

def nth(+xs: List<&2, Nat>, +i: Nat) -> Nat:
  Maybe.default(&2, Nat, List.get(&2, Nat, xs, i), 0n)

def one(+n: Nat) -> Bool:
  Nat.is_eq(n, 1n)

def Config.of(+ns: List<&2, Nat>) -> C.Config:
  C.Config{nth(ns, 0n), nth(ns, 1n), nth(ns, 2n), nth(ns, 3n), nth(ns, 4n), nth(ns, 5n),
           one(nth(ns, 6n)), one(nth(ns, 7n)), one(nth(ns, 8n)), one(nth(ns, 9n))}

type Loaded is Data:
  Loaded{cfg: C.Config, tok: String, step: Nat, w: Md.Weights}

def bytes.str(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case h <> t:
      SCon{Chr{h}, bytes.str(t)}

def parse(+xs: List<&2, U32>) -> Loaded:
  +l0 = line(xs)
  +l1 = line(Line.rest(l0))
  +l2 = line(Line.rest(l1))
  +l3 = line(Line.rest(l2))
  +l4 = line(Line.rest(l3))
  +c = Config.of(nums(Line.text(l1), 0n, Nil{}, sp.at(Line.text(l1))))
  Loaded{c, bytes.str(Line.text(l2)), nth(nums(Line.text(l3), 0n, Nil{}, False{}), 0n), Weights.of(c, words(no.nl(Line.rest(l4))))}
