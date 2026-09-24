import Base
import ../Config.bend as C

# Where everything lives in the store. One Array<F32> holds, in order: the
# parameters (namedLayout order, so a checkpoint's parameter vector is the
# region verbatim), the token ids of a micro-batch, the residual stream
# before every layer and after the last, one layer's workspace (every
# layer reuses it: the backward recomputes a layer's intermediates), the
# head's, and the scalars the host reads. The tangents mirror all of it at
# +g; after that, the optimizer's moments (Adam's m and v; Muon's momentum
# in m). Regions the host writes or reads start on 2 MB boundaries, apart
# from the data the GPU works on.

type Dm is Data:
  Dm{n: U32, t: U32, d: U32, f: U32, h: U32, hd: U32, v: U32, l: U32, cc: U32, j: U32, b: U32, nc: U32, r: U32, rglru: Bool, qk: Bool, sinks: Bool}

def Dm.n(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f0

def Dm.t(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f1

def Dm.d(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f2

def Dm.f(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f3

def Dm.h(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f4

def Dm.hd(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f5

def Dm.v(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f6

def Dm.l(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f7

def Dm.cc(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f8

def Dm.j(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f9

def Dm.b(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f10

def Dm.nc(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f11

def Dm.r(+r: Dm) -> U32:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f12

def Dm.rglru(+r: Dm) -> Bool:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f13

def Dm.qk(+r: Dm) -> Bool:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f14

def Dm.sinks(+r: Dm) -> Bool:
  match r:
    case Dm{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f15

type BP is Data:
  BP{gla: Bool, ra: U32, wq: U32, wk: U32, wv: U32, wo: U32, wa: U32, lam: U32, gq: U32, gk: U32, sink: U32, rf: U32, wg: U32, wu: U32, wd: U32}

def BP.gla(+r: BP) -> Bool:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f0

def BP.ra(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f1

def BP.wq(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f2

def BP.wk(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f3

def BP.wv(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f4

def BP.wo(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f5

def BP.wa(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f6

def BP.lam(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f7

def BP.gq(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f8

def BP.gk(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f9

def BP.sink(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f10

def BP.rf(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f11

def BP.wg(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f12

def BP.wu(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f13

def BP.wd(+r: BP) -> U32:
  match r:
    case BP{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14}:
      f14

# Dimensions ---------------------------------------------------------------

def u(n: Nat) -> U32:
  U32.from_nat(n)

type Wg is Data:
  Wg{ss: U32, nrm: U32, qkv: U32, z: U32, sq: U32, qh: U32, sk: U32, kh0: U32, la: U32, kh: U32, bc: U32, a: U32, oi: U32, u: U32, sin: U32, oe: U32, o: U32, y1: U32, xa: U32, ss2: U32, nrm2: U32, gu: U32, hh: U32, y2: U32, end: U32}

def Wg.ss(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f0

def Wg.nrm(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f1

def Wg.qkv(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f2

def Wg.z(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f3

def Wg.sq(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f4

def Wg.qh(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f5

def Wg.sk(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f6

def Wg.kh0(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f7

def Wg.la(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f8

def Wg.kh(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f9

def Wg.bc(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f10

def Wg.a(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f11

def Wg.oi(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f12

def Wg.u(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f13

def Wg.sin(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f14

def Wg.oe(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f15

def Wg.o(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f16

def Wg.y1(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f17

def Wg.xa(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f18

def Wg.ss2(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f19

def Wg.nrm2(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f20

def Wg.gu(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f21

def Wg.hh(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f22

def Wg.y2(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f23

def Wg.end(+r: Wg) -> U32:
  match r:
    case Wg{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24}:
      f24

type Ws is Data:
  Ws{ss: U32, nrm: U32, qkv: U32, sq: U32, qa: U32, sk: U32, ka: U32, s: U32, m1: U32, m: U32, e: U32, se: U32, den: U32, mix: U32, att: U32, y1: U32, xa: U32, ss2: U32, nrm2: U32, gu: U32, hh: U32, y2: U32, end: U32}

def Ws.ss(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f0

def Ws.nrm(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f1

def Ws.qkv(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f2

def Ws.sq(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f3

def Ws.qa(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f4

def Ws.sk(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f5

def Ws.ka(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f6

def Ws.s(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f7

def Ws.m1(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f8

def Ws.m(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f9

def Ws.e(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f10

def Ws.se(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f11

def Ws.den(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f12

def Ws.mix(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f13

def Ws.att(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f14

def Ws.y1(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f15

def Ws.xa(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f16

def Ws.ss2(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f17

def Ws.nrm2(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f18

def Ws.gu(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f19

def Ws.hh(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f20

def Ws.y2(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f21

def Ws.end(+r: Ws) -> U32:
  match r:
    case Ws{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22}:
      f22

type Hd is Data:
  Hd{ssf: U32, fin: U32, lg: U32, hm: U32, hse: U32, loss: U32, ltot: U32, wl: U32, end: U32}

def Hd.ssf(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f0

def Hd.fin(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f1

def Hd.lg(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f2

def Hd.hm(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f3

def Hd.hse(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f4

def Hd.loss(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f5

def Hd.ltot(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f6

def Hd.wl(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f7

def Hd.end(+r: Hd) -> U32:
  match r:
    case Hd{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f8

type Lay is Data:
  Lay{tin: U32, ttg: U32, x0: U32, ws: U32, hd: U32, sc: U32, g: U32, m: U32, v: U32, total: U32, blocks: List<&2,BP>, fin: U32, params: U32}

def Lay.tin(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f0

def Lay.ttg(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f1

def Lay.x0(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f2

def Lay.ws(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f3

def Lay.hd(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f4

def Lay.sc(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f5

def Lay.g(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f6

def Lay.m(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f7

def Lay.v(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f8

def Lay.total(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f9

def Lay.blocks(+r: Lay) -> List<&2,BP>:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f10

def Lay.fin(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f11

def Lay.params(+r: Lay) -> U32:
  match r:
    case Lay{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12}:
      f12



# halve r while its logits pass 2^25 cells and it stays even (the head's
# logits go r rows at a time)
def rows.big(+r: U32, +v: U32) -> Bool:
  Bool.and(U32.is_lt(33554432, U32.mul(r, v)), U32.is_eq(U32.and(r, 1), 0))

def rows.fit(fuel: Nat, z: Bool, +r: U32, +v: U32) -> U32:
  match fuel z:
    case 1n+p True{}:
      rows.fit(p, rows.big(U32.shr(r), v), U32.shr(r), v)
    case _ _:
      r

# the least depth d with n <= 2^d
def depth(fuel: Nat, z: Bool, +n: U32, +d: Nat, +cap: U32) -> Nat:
  match fuel z:
    case 1n+p True{}:
      depth(p, U32.is_lt(U32.mul(cap, 2), n), n, 1n+d, U32.mul(cap, 2))
    case _ _:
      Nat.add(d, Bool.pick(Nat, U32.is_lt(cap, n), 1n, 0n))

# a micro-batch of mb windows of the config's context, GLA chunks of cc0
# positions (at most the context)
def Dm.of.cc(+c: C.Config, +mb: Nat, +cc0: U32) -> Dm:
  +t = u(C.Config.ctx(c))
  +d = u(C.Config.d(c))
  +h = u(C.Config.heads(c))
  +v = u(C.Config.vocab(c))
  +cc = U32.min(cc0, t)
  +b = u(mb)
  +n = U32.mul(b, t)
  Dm{n, t, d, u(C.Config.f(c)), h, U32.div(d, h), v, u(C.Config.layers(c)), cc,
     U32.div(t, cc), b, U32.div(n, cc), rows.fit(32n, rows.big(n, v), n, v),
     C.Config.rglru(c), C.Config.qk(c), C.Config.sinks(c)}

def Dm.of(+c: C.Config, +mb: Nat) -> Dm:
  +t = u(C.Config.ctx(c))
  +d = u(C.Config.d(c))
  +h = u(C.Config.heads(c))
  +v = u(C.Config.vocab(c))
  +cc = U32.min(64, t)
  +b = u(mb)
  +n = U32.mul(b, t)
  Dm{n, t, d, u(C.Config.f(c)), h, U32.div(d, h), v, u(C.Config.layers(c)), cc,
     U32.div(t, cc), b, U32.div(n, cc), rows.fit(32n, rows.big(n, v), n, v),
     C.Config.rglru(c), C.Config.qk(c), C.Config.sinks(c)}

def when(b: Bool, +n: U32) -> U32:
  Bool.pick(U32, b, n, 0)

# Parameters (namedLayout) ---------------------------------------------------

def BP.gla.at(+c: C.Config, +o: U32) -> BP:
  +d = u(C.Config.d(c))
  +f = u(C.Config.f(c))
  +dd = U32.mul(d, d)
  +q = U32.add(o, d)
  +lam = U32.add(q, U32.mul(5, dd))
  +rf = U32.add(lam, when(C.Config.rglru(c), d))
  +wg = U32.add(rf, d)
  BP{True{}, o, q, U32.add(q, dd), U32.add(q, U32.mul(2, dd)), U32.add(q, U32.mul(3, dd)),
     U32.add(q, U32.mul(4, dd)), lam, 0, 0, 0, rf, wg, U32.add(wg, U32.mul(f, d)),
     U32.add(wg, U32.mul(2, U32.mul(f, d)))}

def BP.sm.at(+c: C.Config, +o: U32) -> BP:
  +d = u(C.Config.d(c))
  +f = u(C.Config.f(c))
  +hd = u(C.Config.hd(c))
  +dd = U32.mul(d, d)
  +q = U32.add(o, d)
  +gq = U32.add(q, U32.mul(4, dd))
  +gk = U32.add(gq, when(C.Config.qk(c), hd))
  +sink = U32.add(gk, when(C.Config.qk(c), hd))
  +rf = U32.add(sink, when(C.Config.sinks(c), u(C.Config.heads(c))))
  +wg = U32.add(rf, d)
  BP{False{}, o, q, U32.add(q, dd), U32.add(q, U32.mul(2, dd)), U32.add(q, U32.mul(3, dd)),
     0, 0, gq, gk, sink, rf, wg, U32.add(wg, U32.mul(f, d)), U32.add(wg, U32.mul(2, U32.mul(f, d)))}

def BP.at(k: C.LayerKind, +c: C.Config, +o: U32) -> BP:
  match k:
    case C.Gla{}:
      BP.gla.at(c, o)
    case C.Softmax{}:
      BP.sm.at(c, o)

def BP.size.k(k: C.LayerKind, +c: C.Config, +common: U32, +d: U32) -> U32:
  match k:
    case C.Gla{}:
      U32.add(common, U32.add(U32.mul(d, d), when(C.Config.rglru(c), d)))
    case C.Softmax{}:
      U32.add(common, U32.add(when(C.Config.qk(c), U32.mul(2, u(C.Config.hd(c)))),
        when(C.Config.sinks(c), u(C.Config.heads(c)))))

def BP.size(k: C.LayerKind, +c: C.Config) -> U32:
  +d = u(C.Config.d(c))
  +f = u(C.Config.f(c))
  +common = U32.add(U32.mul(2, d), U32.add(U32.mul(4, U32.mul(d, d)), U32.mul(3, U32.mul(f, d))))
  BP.size.k(k, c, common, d)

def BP.list(n: Nat, +c: C.Config, +i: Nat, +o: U32) -> List<&2, BP>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      BP.at(C.kind_of(i), c, o) <> BP.list(p, c, 1n+i, U32.add(o, BP.size(C.kind_of(i), c)))

def blocks.end(n: Nat, +c: C.Config, +i: Nat, +o: U32) -> U32:
  match n:
    case 0n:
      o
    case 1n+p:
      blocks.end(p, c, 1n+i, U32.add(o, BP.size(C.kind_of(i), c)))

# Workspaces ---------------------------------------------------------------

def Wg.at(+m: Dm, +o: U32) -> Wg:
  +n = Dm.n(m)
  +d = Dm.d(m)
  +nd = U32.mul(n, d)
  +nh = U32.mul(n, Dm.h(m))
  +st = U32.mul(U32.mul(Dm.nc(m), Dm.h(m)), U32.mul(Dm.hd(m), Dm.hd(m)))
  +ss = o
  +nrm = U32.add(ss, n)
  +qkv = U32.add(nrm, nd)
  +z = U32.add(qkv, U32.mul(3, nd))
  +sq = U32.add(z, nd)
  +qh = U32.add(sq, nh)
  +sk = U32.add(qh, nd)
  +kh0 = U32.add(sk, nh)
  +la = U32.add(kh0, nd)
  +kh = U32.add(la, nd)
  +bc = U32.add(kh, nd)
  +a = U32.add(bc, nd)
  +oi = U32.add(a, U32.mul(nh, Dm.cc(m)))
  +uu = U32.add(oi, nd)
  +sin = U32.add(uu, st)
  +oe = U32.add(sin, st)
  +oo = U32.add(oe, nd)
  +y1 = U32.add(oo, nd)
  +xa = U32.add(y1, nd)
  +ss2 = U32.add(xa, nd)
  +nrm2 = U32.add(ss2, n)
  +gu = U32.add(nrm2, nd)
  +hh = U32.add(gu, U32.mul(2, U32.mul(n, Dm.f(m))))
  +y2 = U32.add(hh, U32.mul(n, Dm.f(m)))
  Wg{ss, nrm, qkv, z, sq, qh, sk, kh0, la, kh, bc, a, oi, uu, sin, oe, oo, y1, xa, ss2, nrm2, gu, hh, y2, U32.add(y2, nd)}

def Ws.at(+m: Dm, +o: U32) -> Ws:
  +n = Dm.n(m)
  +d = Dm.d(m)
  +nd = U32.mul(n, d)
  +nh = U32.mul(n, Dm.h(m))
  +bht = U32.mul(U32.mul(Dm.b(m), Dm.h(m)), Dm.t(m))
  +bhtt = U32.mul(bht, Dm.t(m))
  +ss = o
  +nrm = U32.add(ss, n)
  +qkv = U32.add(nrm, nd)
  +sq = U32.add(qkv, U32.mul(3, nd))
  +qa = U32.add(sq, nh)
  +sk = U32.add(qa, nd)
  +ka = U32.add(sk, nh)
  +s = U32.add(ka, nd)
  +m1 = U32.add(s, bhtt)
  +mm = U32.add(m1, bht)
  +e = U32.add(mm, bht)
  +se = U32.add(e, bhtt)
  +den = U32.add(se, bht)
  +mix = U32.add(den, bht)
  +att = U32.add(mix, nd)
  +y1 = U32.add(att, nd)
  +xa = U32.add(y1, nd)
  +ss2 = U32.add(xa, nd)
  +nrm2 = U32.add(ss2, n)
  +gu = U32.add(nrm2, nd)
  +hh = U32.add(gu, U32.mul(2, U32.mul(n, Dm.f(m))))
  +y2 = U32.add(hh, U32.mul(n, Dm.f(m)))
  Ws{ss, nrm, qkv, sq, qa, sk, ka, s, m1, mm, e, se, den, mix, att, y1, xa, ss2, nrm2, gu, hh, y2, U32.add(y2, nd)}

def Hd.at(+m: Dm, +o: U32) -> Hd:
  +n = Dm.n(m)
  +ssf = o
  +fin = U32.add(ssf, n)
  +lg = U32.add(fin, U32.mul(n, Dm.d(m)))
  +hm = U32.add(lg, U32.mul(Dm.r(m), Dm.v(m)))
  +hse = U32.add(hm, Dm.r(m))
  +loss = U32.add(hse, Dm.r(m))
  +ltot = U32.add(loss, n)
  +wl = U32.add(ltot, 1)
  Hd{ssf, fin, lg, hm, hse, loss, ltot, wl, U32.add(wl, Dm.b(m))}

# The store ----------------------------------------------------------------

# up to a 2 MB boundary
def align(+x: U32) -> U32:
  U32.and(U32.add(x, 524287), U32.not(524287))

def Lay.of(+c: C.Config, +m: Dm) -> Lay:
  +bs = BP.list(C.Config.layers(c), c, 0n, U32.mul(Dm.v(m), Dm.d(m)))
  +fin = blocks.end(C.Config.layers(c), c, 0n, U32.mul(Dm.v(m), Dm.d(m)))
  +params = U32.add(fin, Dm.d(m))
  +tin = align(params)
  +ttg = U32.add(tin, Dm.n(m))
  +x0 = align(U32.add(ttg, Dm.n(m)))
  +ws = U32.add(x0, U32.mul(U32.add(Dm.l(m), 1), U32.mul(Dm.n(m), Dm.d(m))))
  +hd = U32.add(ws, U32.max(Wg.end(Wg.at(m, ws)), Ws.end(Ws.at(m, ws))))
  +sc = align(U32.sub(Hd.end(Hd.at(m, hd)), 0))
  +g = align(U32.add(sc, 16))
  +mo = U32.add(g, g)
  +vo = U32.add(mo, align(params))
  Lay{tin, ttg, x0, ws, hd, sc, g, mo, vo, U32.add(vo, align(params)), bs, fin, params}

# x_i, the residual stream before layer i (x_L after the last)
def Lay.x(+ly: Lay, +m: Dm, +i: U32) -> U32:
  U32.add(Lay.x0(ly), U32.mul(i, U32.mul(Dm.n(m), Dm.d(m))))

# the scalars the host reads: the mean loss, the gradient norm
def Lay.lmean(+ly: Lay) -> U32:
  Lay.sc(ly)

def Lay.gnorm(+ly: Lay) -> U32:
  U32.add(Lay.sc(ly), 1)



def Lay.depth(+ly: Lay) -> Nat:
  depth(31n, U32.is_lt(2, Lay.total(ly)), Lay.total(ly), 0n, 1)
