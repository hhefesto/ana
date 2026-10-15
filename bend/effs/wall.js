// Clock
// =====

// ck.wall (bend/Clock.bend): the wall clock, milliseconds since the Unix
// epoch. A Nat crosses to the JS host as a plain number.
function ck_wall() {
  return Date.now();
}

io_eff(CID(ck.wall), ck_wall);
