# tools/a2b: agda2bend's dev tools

Run them from anywhere; each finds the repo from its own path. Scratch (logs, stub
projects) goes to `$A2B_TMP` (/tmp/claude-1000/a2b), and heavy Bend compiles queue on
`$A2B_LOCK` (see env.sh).

- `build.sh`: the dev binary run/a2b/bin/agda2bend-O0 (Bend to C, clang -O0, about 2 min).
- `test.sh`: bend/tests/agda2bend.bend compiled and run (52 oks as of 2026-10-22).
- `chk.sh FILE [LINES]`: one Bend file checked by the locked bend.
- `probe.sh OUT MODPATH AGDANAME...`: a gated module (OUT/src) plus the named items from
  its pre-gate copy (OUT/raw), checked together.
- `export-each.sh < LIST`, `export-chunks.sh`: agda-export into run/a2b/export2, one
  module (or one chunk) per capped process.
- `erasure-each.sh N LIST`, `erasure-tally.sh`: the erasure sidecars and their tallies.
- `show.pl` (condense an export line for reading), `mvdef.pl FILE MOVED BEFORE` (move a
  def's paragraph): Perl one-offs.

The loop: `run/a2b/bin/agda2bend-O0 emit run/a2b/export2 run/a2b/yonedaN Categories.Yoneda`
(about 40 min), then `run/a2b/bin/agda2bend-O0 report run/a2b/yonedaN run/a2b/yonedaM`.
