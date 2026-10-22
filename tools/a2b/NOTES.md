# agda2bend: the "expected Data observed Kind(a)" blocker (2026-10-22)

Progress notes, so a successor can resume. Newest last. Times UTC-6.

## State as found (12:05), from StormyLlama's chat (died 10:33)

- 843742a committed tools/a2b. Uncommitted since: env.sh's `A2B_BEND`, the flake's bend
  with record eta, GC-rooted at run/a2b/gcroot-bend (wcxxdny9). run/gcroot-bend is
  OLDER, has no eta, and fails gated modules (yoneda19's Relation/Unary.bend). build,
  chk, probe and test use A2B_BEND. emit.sh (untracked) runs a capped full emit.
- The roots (yoneda19 ledger, "expected : Data observed : Kind(a)", all in
  Algebra.Structures): IsSuccessorSet, IsInvertibleMagma, IsGroup, IsNearring. The same
  cause gives "Kind(b)" at Function.Bundles._.RightInverse (18 blocked).
- Why: each has a field `-1-cong : Congruent₁ _⁻¹`, which opens to
  `x ≈ y → (_≈_ on _⁻¹) x y`, i.e. `Function_Base.on(~a, ~A, …)`. `_on_` is
  `_-⟨_⟩-_`, which is `_-⟪_⟫-_` (`λ x y → f x y * g x y`), which uses x and y twice,
  so they are `+` and their types Data; the gate's Data repair passes that up the
  chain, and yoneda19's `on` has `~A: Data`. A record over a carrier `A: Kind(a)`
  then has no Data to pass. Not a Bend limit: Agda's `_*_ on f` is `λ x y → f x * f y`,
  which uses x and y once.
- Hand check: `on` rewritten as `x(x_13(x_14), x_13(x_15))` with
  `~A: Kind(A_u002e_a)` and `~x_13` makes Function/Base.bend and its 5 dependents'
  modules check, and the 5 roots probe ALL PROOFS CHECK.
- The fix in progress (uncommitted):
  1. Cata.bend "Combinators": a one-leaf, non-recursive, non-type-valued function
     whose leaf is headed by a variable or by an earlier combinator is a combinator
     (unfoldings key "cmb:"); inside a combinator's own body ("cmb!" in the env),
     saturated combinator calls are unfolded and beta-reduced. Agda2Bend.bend adds
     them in a2b.syms.one. Built (10:39, run/a2b/bin/agda2bend-O0). Function.Base:
     31/33 check; `on`, `on₂` drop (expected Data observed Type): the body is now
     `x(x_13(x_14), x_13(x_15))`, but x_13's two uses sit at a variable's arguments,
     which Cata marks BtDead(BtDead) (mode unknown), so Copy does not count them and
     x_13 is not made a template.
  2. Copy.bend tcp.vres (for counting only): a parameter applied whose type is a Pi
     has its arguments at live Pis counted as live uses. Did NOT build: Bend's
     termination check refuses `tcp.vres(ps, tcp.vargs(args, …))`.
- run/a2b/bin/agda2bend-O0-y19 is the yoneda19 binary (saved).

## 12:05-12:20 (successor)

- tcp.vres rewritten as one function `tcp.vres(ps, t, ty)` (ty: the Pi an argument
  spine is applied at), which Bend's termination check takes. Built 12:08.
- Function.Base (emit of export2, /tmp/claude-1000/a2b/fb3): 33 of 33 check in 3 gate
  checks (yoneda19: 24). `on` is `~A: Kind(A_u002e_a), ~x_13: A -> B`, body
  `x(x_13(x_14), x_13(x_15))`. Copy now decides most of the Data/+ the gate used to
  repair (the raw file says `+x_23`, `A: Data` where the gate did).
- Goldens remade: Function.Base.bend, Function.Base.checked.bend, A2bFix.bend (its
  `twice` now `-A: Data, +x_3` before the gate, as the gate made it; A2bFix's checked
  file is unchanged).
- Tests: 2 new laws (Copy: a function-typed parameter passes its arguments live, f
  used twice there a template; the Function.Base translation's `_on_`). test.sh: 54 ok.
- yoneda20 emit started 12:13 (tools/a2b/emit.sh yoneda20; binary saved as
  run/a2b/bin/agda2bend-O0-y20; log run/a2b/yoneda20.log).
- 12:13-12:21 first yoneda20 try (kept as run/a2b/yoneda20a, partial to Function.Bundles,
  binary agda2bend-O0-y20a): the 4 roots and RightInverse check; Algebra.Structures
  175 -> 244, Algebra.Bundles 270 -> 366, Function.Bundles 84 -> 95. But a combinator
  was any one-leaf def headed by a variable or a combinator call, so reasoning-chain
  lemmas (headed by `begin_`) had their bodies normalised: Algebra.Consequences.Setoid
  9 -> 6 (`_.assoc∧distribˡ∧idʳ∧invʳ⇒zeʳ`, `…ʳ…⇒zeˡ`: x_22 used twice).
- Fix: act.cmb.pure: a combinator's leaf is made of variables, constructors and
  earlier combinators only (a type, sort or level in it dead). Built 12:20; Function.Base
  unchanged by it. yoneda20 restarted 12:21 with it (agda2bend-O0-y20).
- 12:21-12:30 second try (run/a2b/yoneda20b, partial, agda2bend-O0-y20b, pure
  combinators): Algebra.Consequences.Setoid still 9 -> 5. Its lemma bodies are as in
  yoneda19; the cause is a callee: `∙-congˡ`'s x is now erased (Copy sees its uses are
  dead: cong's and refl's hidden Pis; before, `+x` and A: Data), so the lemma's x_22
  lost its one counted live use and stayed erased, but `star(x_22, n0_hash)` uses it
  live (star: Op₂ A, a type-valued def, not a Pi Copy sees) twice; the gate's "+"
  repair only raised a live binder, so it dropped the lemma.
- Fix: Copy's tcp.p.raise: an erased parameter consumed more than once goes to + at
  once. Built 12:30. yoneda20 restarted 12:31 (third try; agda2bend-O0-y20).
- 12:38 third try so far: Algebra.Consequences.Setoid 9 -> 22, Algebra.Structures 175 ->
  244, Relation.Binary.Consequences 41 -> 47. New law for the erased -> + repair;
  test.sh 55 ok.

## PAUSED by the user, 12:50. Nothing committed. How to resume

- Running, left to finish on its own: the third yoneda20 emit (started 12:31, pid of
  `run/a2b/bin/agda2bend-O0 emit … run/a2b/yoneda20`; capped 10G, CPUWeight 30, its
  own `timeout 7200`, so it ends by 14:31 at the latest; yoneda19 took 1 h 48 min).
  71 of 121 modules were done at 12:41. Done when run/a2b/yoneda20.log ends in
  `exit 0` (`exit 124` = hit the 2 h cap: the ledger is then partial, rerun with
  `tools/a2b/emit.sh yoneda20c`). To stop it: `kill $(pgrep -f '[a]gda2bend-O0 emit')`
  (the brackets keep pgrep from matching its own shell).
- Then: `run/a2b/bin/agda2bend-O0 report run/a2b/yoneda20 run/a2b/yoneda19`, and per
  item: join the two ledger.tsv on module/Agda name (`LC_ALL=C`, sort with -t TAB -k1,1)
  and list `checked` in yoneda19 but not in yoneda20.
- The tree (uncommitted, all built into run/a2b/bin/agda2bend-O0 = agda2bend-O0-y20,
  test.sh 55 ok):
  - bend/Agda2Bend/Cata.bend: Combinators (act.cmb.*: key, mark, env, when, at, pick,
    try near "Copattern reductions"; head, pure, leaf, d, of after act.unf.of);
    act.inline.go's AgDef case calls act.cmb.try; act.fun.with uses act.cmb.env.
  - bend/Agda2Bend.bend: a2b.syms.one registers act.cmb.of under act.cmb.key.
  - bend/ToBend/Copy.bend: tcp.vty, tcp.vres (counting only, in tcp.decide);
    tcp.p.raise's erased -> + case.
  - bend/tests/agda2bend.bend: laws gt.on (vres), gt.contra.e (erased -> +), gold.fb
    (Function.Base golden + `_on_` normalised). Goldens remade: golden/Function.Base.bend,
    golden/Function.Base.checked.bend, golden/A2bFix.bend.
  - tools/a2b: env.sh A2B_BEND (+ build/chk/probe/test use it), emit.sh (new), NOTES.md.
- Results so far (yoneda20 vs yoneda19, modules done by 12:41): Algebra.Structures 175 ->
  244 (the 4 roots), Algebra.Bundles 270 -> 366, Function.Bundles 84 -> 95 (RightInverse),
  Algebra.Consequences.Setoid 9 -> 22, Relation.Binary.Consequences 41 -> 47.
  Regressions: 4, all Algebra.Consequences.Setoid: `_.assoc∧distribˡ∧idʳ∧invʳ⇒zeʳ`,
  `_.assoc∧distribʳ∧idʳ∧invʳ⇒zeˡ` (dropped, expected Data observed Type) and their 2
  dependents `assoc+distrib…⇒ze…`.
- Why those 2 fall (probed by hand, 12:45): with +x_22 and a := &2 (what the gate does)
  Bend next says `star` consumed more than once; the gate raises it to +, and then
  "+star … its type must be Data" (star: Op₂ A, a function type behind a type-valued
  def). yoneda19 had `~star` (a template) from Copy, because `∙-congˡ`'s x was then a
  live +x and counted star's uses; now `∙-congˡ`'s x is (rightly) erased, and Copy does
  not see star's uses at x_20/x_21's arguments (their types are type-valued defs,
  RightIdentity/RightInverse, whose Pis Copy cannot see).
- Next, options for those 2 (not started):
  (a) Copy's tcp.vty opens type-valued defs to their Pis (Qfix's tqf.whnf/tqf.ty with
      its TqEnv opens Bend-level ones; Copy would need that env), so x_20(star(…))
      counts star live and star becomes a template as before. Cleanest.
  (b) The gate: a + binder Bend says is no Data ("Note: +v can be used many times")
      becomes a template. Risky: a template reorders the header (templates first) and
      the gate does not re-translate callers, nor update the symbol table.
  (c) Accept: -2 items (4 with dependents) against the gains.
- Then commit (explicit paths only: the files above; not HANDOFF.md, not the
  coordinator's rename files, not CorpusV2*). Message draft: "agda2bend: combinators'
  bodies normalised (_on_ is λ x y → f x * f y, its A of any kind), a parameter of a
  function type counts its arguments, the gate's + repair takes an erased binder;
  yoneda20 N of 2527".
