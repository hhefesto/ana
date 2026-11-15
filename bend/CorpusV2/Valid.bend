import Base
import ../Sys.bend as S
import ./ValidText.bend as V

# bend-corpus-v2 valid: R7's fixed validation set (change 8; CorpusV2/ValidText.bend says which files are
# held out, and why).
#
#   valid split IN TRAIN VALID     IN's (id, text) pairs: a held-out file's into VALID, the rest into TRAIN, in
#                                  order; the counts on stdout
#   valid held ID...               each ID's key and whether it is held out (a look)
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
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 valid split IN TRAIN VALID | valid held ID...")
