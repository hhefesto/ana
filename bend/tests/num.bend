import Base
import ../Num.bend as N

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(N.U64.hex(N.U64.mul(N.U64{305419896, 2596069104}, N.U64{4275878552, 1985229328})))
    IO.print(N.U64.hex(N.U64.rotl(N.U64{305419896, 2596069104}, 45n)))
    IO.print(N.U64.hex(N.U64.shr(N.U64{305419896, 2596069104}, 30n)))
    IO.print(N.U64.hex(N.U64.add(N.U64{4294967295, 4294967295}, N.U64{0, 2})))
    IO.print(N.U64.hex(Maybe.default(&2, N.U64, N.U64.read("18446744073709551615"), N.U64.zero())))
    IO.print(F32.show(N.F32.from_bits(N.be32(63, 192, 0, 0))))
