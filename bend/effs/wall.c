// Clock
// =====

// ck.wall (bend/Clock.bend): the wall clock, milliseconds since the Unix
// epoch (CLOCK_REALTIME). The Bend2 fork's IO.time until 2026-10-15, the
// same code under our own name.
Term ck_wall_run(Env e, Term* f, IoWork* w) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (Term)((u64)ts.tv_sec * 1000ull + (u64)ts.tv_nsec / 1000000ull);
}

static void __attribute__((constructor)) ck_wall_use(void) {
  io_eff(CID(ck.wall), ck_wall_run);
}
