import Base
import ../Sys.bend as S
import ./ValidText.bend as V

# bend-corpus-v2 valid: R7's fixed validation set (change 8; CorpusV2/ValidText.bend says which files are
# held out, and why).
#
#   valid split IN TRAIN VALID     IN's (id, text) pairs: a held-out file's into VALID, the rest into TRAIN, in
#                                  order; the counts on stdout
#   valid held ID...               each ID's key and whether it is held out (a look)
#   valid drop LIST IN OUT         IN's (id, text) pairs whose id isn't a line of LIST into OUT, in order; the
#                                  counts on stdout (2026-11-16: the held-out sessions and files with a copy in
#                                  training under another name, out of R7valid)
#
# VALID_K: K of 256 (2).  A stream at a time, a pair in memory (Sys.Rd), so a stream of any size splits.
# Every def starts with `vd.`.

def vd.fuel() -> Nat:
  U32.to_nat(4294967295)

def vd.k() -> IO(U32):
  IO.bind(Nat, U32, S.env.nat("VALID_K", 2n), k => IO.pure(U32, U32.from_nat(k)))

# The split ------------------------------------------------------------------------------------

type VdS is Type:
  VdS{rd: S.Rd, tr: File, va: File, k: U32, nt: Nat, nv: Nat, go: Bool}

def vd.emit(held: Bool, rd: S.Rd, tr: File, va: File, +k: U32, +nt: Nat, +nv: Nat, +x: List<&2, U32>) -> IO(VdS):
  match held:
    case True{}:
      IO.bind(File, VdS, S.emit(va, x), v2 => IO.pure(VdS, VdS{rd, tr, v2, k, nt, 1n+nv, True{}}))
    case False{}:
      IO.bind(File, VdS, S.emit(tr, x), t2 => IO.pure(VdS, VdS{rd, t2, va, k, 1n+nt, nv, True{}}))

def vd.text(tr: File, va: File, +k: U32, +nt: Nat, +nv: Nat, +i: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(VdS):
  (rd, m) = r
  match m:
    case None{}:
      do IO<VdS>:
        S.Rd.close(rd)
        IO.die(VdS, 1, "valid: an id without its text")
    case Some{+t}:
      vd.emit(V.vd.held(k, i), rd, tr, va, k, nt, nv, List.concat(&2, U32, [i, [0], t, [0]]))

def vd.id(tr: File, va: File, +k: U32, +nt: Nat, +nv: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(VdS):
  (rd, m) = r
  match m:
    case None{}:
      IO.pure(VdS, VdS{rd, tr, va, k, nt, nv, False{}})
    case Some{+i}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, VdS, S.Rd.next(rd), vd.text(tr, va, k, nt, nv, i))

def vd.step(s: VdS) -> IO(VdS):
  match s:
    case VdS{rd, tr, va, k, nt, nv, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, VdS, S.Rd.next(rd), vd.id(tr, va, k, nt, nv))

def vd.go(fuel: Nat, s: VdS) -> IO(VdS):
  match fuel s:
    case 1n+f VdS{rd, tr, va, k, nt, nv, True{}}:
      IO.bind(VdS, VdS, vd.step(VdS{rd, tr, va, k, nt, nv, True{}}), vd.go(f))
    case _ s2:
      IO.pure(VdS, s2)

def vd.fin(+inp: String, s: VdS) -> IO(Unit):
  match s:
    case VdS{rd, tr, va, k, nt, nv, g}:
      do IO<Unit>:
        S.Rd.close(rd)
        File.close(tr)
        File.close(va)
        IO.print("valid split " ++ inp ++ ": train " ++ Nat.show(nt) ++ ", valid " ++ Nat.show(nv) ++ " (K " ++ U32.show(k) ++ " of 256)")

def vd.split(+inp: String, +tro: String, +vao: String) -> IO(Unit):
  do IO<Unit>:
    +k : U32 <- vd.k()
    rd : S.Rd <- S.Rd.open(inp)
    tr : File <- IO.try(File, File.open(tro, "w"))
    va : File <- IO.try(File, File.open(vao, "w"))
    s : VdS <- vd.go(vd.fuel(), VdS{rd, tr, va, k, 0n, 0n, True{}})
    vd.fin(inp, s)

# The drop -------------------------------------------------------------------------------------

def vd.or(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      True{}
    case False{}:
      b

# whether the id is one of the list's (the whole list looked at: it is short)
def vd.has(xs: List<&2, List<&2, U32>>, +i: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      vd.or(S.eq(x, i), vd.has(t, i))

# a listed id, a prefix of one, and the empty list
law vd.has.known:
  {(vd.has([S.b("a#f"), S.b("b#g")], S.b("b#g")), vd.has([S.b("a#f")], S.b("a#")), vd.has(Nil{}, S.b("a#f")))
   == (True{}, False{}, False{}) : Bool & Bool & Bool}

def vd.has.known():
  {==}

type VdD is Type:
  VdD{rd: S.Rd, out: File, ids: List<&2, List<&2, U32>>, nk: Nat, nd: Nat, go: Bool}

def vd.drop.emit(hit: Bool, rd: S.Rd, out: File, +ids: List<&2, List<&2, U32>>, +nk: Nat, +nd: Nat, +x: List<&2, U32>) -> IO(VdD):
  match hit:
    case True{}:
      IO.pure(VdD, VdD{rd, out, ids, nk, 1n+nd, True{}})
    case False{}:
      IO.bind(File, VdD, S.emit(out, x), o2 => IO.pure(VdD, VdD{rd, o2, ids, 1n+nk, nd, True{}}))

def vd.drop.text(out: File, +ids: List<&2, List<&2, U32>>, +nk: Nat, +nd: Nat, +i: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(VdD):
  (rd, m) = r
  match m:
    case None{}:
      do IO<VdD>:
        S.Rd.close(rd)
        IO.die(VdD, 1, "valid: an id without its text")
    case Some{+t}:
      vd.drop.emit(vd.has(ids, i), rd, out, ids, nk, nd, List.concat(&2, U32, [i, [0], t, [0]]))

def vd.drop.id(out: File, +ids: List<&2, List<&2, U32>>, +nk: Nat, +nd: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(VdD):
  (rd, m) = r
  match m:
    case None{}:
      IO.pure(VdD, VdD{rd, out, ids, nk, nd, False{}})
    case Some{+i}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, VdD, S.Rd.next(rd), vd.drop.text(out, ids, nk, nd, i))

def vd.drop.step(s: VdD) -> IO(VdD):
  match s:
    case VdD{rd, out, ids, nk, nd, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, VdD, S.Rd.next(rd), vd.drop.id(out, ids, nk, nd))

def vd.drop.go(fuel: Nat, s: VdD) -> IO(VdD):
  match fuel s:
    case 1n+f VdD{rd, out, ids, nk, nd, True{}}:
      IO.bind(VdD, VdD, vd.drop.step(VdD{rd, out, ids, nk, nd, True{}}), vd.drop.go(f))
    case _ s2:
      IO.pure(VdD, s2)

def vd.drop.fin(+inp: String, s: VdD) -> IO(Unit):
  match s:
    case VdD{rd, out, ids, nk, nd, g}:
      do IO<Unit>:
        S.Rd.close(rd)
        File.close(out)
        IO.print("valid drop " ++ inp ++ ": kept " ++ Nat.show(nk) ++ ", dropped " ++ Nat.show(nd))

def vd.drop.list(+lst: String, m: Maybe<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match m:
    case None{}:
      IO.die(List<&2, List<&2, U32>>, 1, "valid drop: cannot read " ++ lst)
    case Some{+xs}:
      IO.pure(List<&2, List<&2, U32>>, S.split.lines(xs))

def vd.drop(+lst: String, +inp: String, +outp: String) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(lst)
    +ids : List<&2, List<&2, U32>> <- vd.drop.list(lst, m)
    rd : S.Rd <- S.Rd.open(inp)
    out : File <- IO.try(File, File.open(outp, "w"))
    s : VdD <- vd.drop.go(vd.fuel(), VdD{rd, out, ids, 0n, 0n, True{}})
    vd.drop.fin(inp, s)

# A look ---------------------------------------------------------------------------------------

def vd.yn(b: Bool) -> String:
  match b:
    case True{}:
      "held out"
    case False{}:
      "train"

def vd.look(+k: U32, ids: List<String>) -> IO(Unit):
  match ids:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +i <> rest:
      do IO<Unit>:
        IO.print(i ++ "\t" ++ S.str(V.vd.key(S.b(i))) ++ "\t" ++ vd.yn(V.vd.held(k, S.b(i))))
        vd.look(k, rest)

# Main -----------------------------------------------------------------------------------------

def vd.main(xs: List<String>) -> IO(Unit):
  match xs:
    case "split" <> +inp <> +tro <> +vao <> Nil{}:
      vd.split(inp, tro, vao)
    case "held" <> ids:
      IO.bind(U32, Unit, vd.k(), k => vd.look(k, ids))
    case "drop" <> +lst <> +inp <> +outp <> Nil{}:
      vd.drop(lst, inp, outp)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 valid split IN TRAIN VALID | valid held ID... | valid drop LIST IN OUT")
