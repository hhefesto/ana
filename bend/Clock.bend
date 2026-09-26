import Base

# Every log line is stamped in the user's local time, Mexico City: UTC-6
# with no daylight saving (since 2022). IO.time is the wall clock in ms.

def pad2(+x: U32) -> String:
  Bool.pick(String, U32.is_lt(x, 10), "0", "") ++ U32.show(x)

# days since 1970-01-01 as y-m-d (Hinnant's civil_from_days; every
# intermediate is nonnegative, so U32 subtraction is exact)
def civil(+z0: U32) -> String:
  +z = U32.add(z0, 719468)
  +era = U32.div(z, 146097)
  +doe = U32.sub(z, U32.mul(era, 146097))
  +yoe = U32.div(U32.sub(U32.add(doe, U32.div(doe, 36524)), U32.add(U32.div(doe, 1460), U32.div(doe, 146096))), 365)
  +doy = U32.sub(doe, U32.sub(U32.add(U32.mul(365, yoe), U32.div(yoe, 4)), U32.div(yoe, 100)))
  +mp = U32.div(U32.add(U32.mul(5, doy), 2), 153)
  +d = U32.add(U32.sub(doy, U32.div(U32.add(U32.mul(153, mp), 2), 5)), 1)
  +m = Bool.pick(U32, U32.is_lt(mp, 10), U32.add(mp, 3), U32.sub(mp, 9))
  +y = U32.add(U32.add(yoe, U32.mul(era, 400)), Bool.pick(U32, U32.is_le(m, 2), 1, 0))
  U32.show(y) ++ "-" ++ pad2(m) ++ "-" ++ pad2(d)

# "[YYYY-MM-DD HH:MM:SS UTC-6]" for a wall-clock reading in ms
def stamp(+ms: Nat) -> String:
  +t = U32.sub(U32.from_nat(Nat.div(ms, U32.to_nat(1000))), 21600)
  +s = U32.mod(t, 86400)
  "[" ++ civil(U32.div(t, 86400)) ++ " " ++ pad2(U32.div(s, 3600)) ++ ":" ++ pad2(U32.div(U32.mod(s, 3600), 60))
    ++ ":" ++ pad2(U32.mod(s, 60)) ++ " UTC-6]"

# a log line behind its timestamp, on stdout (the trainers: run them under
# `stdbuf -oL`, IO.print does not flush)
def say(+line: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- IO.time()
    IO.print(stamp(t) ++ " " ++ line)

# the same on stderr, which is flushed line by line (the corpus tools)
def log(+line: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- IO.time()
    IO.print_err(stamp(t) ++ " " ++ line)
