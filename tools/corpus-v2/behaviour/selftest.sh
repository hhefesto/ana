#!/usr/bin/env bash
# UNWIRED 2026-10-14: ported to Bend (shell→Bend port, phase 5): `bend-corpus-v2 behaviour selftest` (bend/CorpusV2/Behaviour.bend), byte-identical on every tracked result; kept for reference
exit 2
# selftest.sh [LANG...]: the checks against answers whose verdicts are known.
# Every task gets its reference answer (expected: pass) except the ones below,
# which get a deliberately broken one: well-typed but wrong (expected: wrong,
# so the tests do tell a wrong answer from a right one), ill-typed or
# unfinished (compile), giving up (refused) or never closing its fence
# (unclosed).  Results in results/selftest/LANG/; exits 1 on any mismatch.
set -u
Q=$(cd "$(dirname "$0")" && pwd)
langs=("$@"); [ ${#langs[@]} = 0 ] && langs=(haskell lean agda)
T="$Q/results/selftest"
declare -A want
for lang in "${langs[@]}"; do
  rm -rf "${T:?}/$lang"; mkdir -p "$T/$lang"
  for d in "$Q/tasks/$lang"/*/; do n=$(basename "$d"); cat "$d/prompt" "$Q/refs/$lang/$n" > "$T/$lang/$n.out"; done
done
# mut LANG NAME VERDICT < ANSWER: the task's output becomes its prompt and ANSWER
# (closed by a fence unless VERDICT is unclosed)
mut() {
  local lang="$1" n="$2" v="$3" d="$Q/tasks/$1/$2"
  [ -d "$T/$lang" ] || { cat > /dev/null; return; }
  { cat "$d/prompt"; cat; [ "$v" = unclosed ] || printf '```\n'; } > "$T/$lang/$n.out"
  want[$lang/$n]=$v
}

mut haskell merge wrong <<'EOF'
merge xs ys = xs ++ ys
EOF
mut haskell fib wrong <<'EOF'
fib 0 = 1
fib 1 = 1
fib n = fib (n - 1) + fib (n - 2)
EOF
mut haskell dedup wrong <<'EOF'
dedup = map head . group
EOF
mut haskell safeHead wrong <<'EOF'
safeHead xs = Just (head xs)
EOF
mut haskell myGcd crash <<'EOF'
myGcd a b = myGcd b (a `mod` b)
EOF
mut haskell myReverse compile <<'EOF'
myReverse = reverse 1
EOF
mut haskell quicksort unclosed <<'EOF'
quicksort [] = []
EOF

mut lean double wrong <<'EOF'
n + 2
EOF
mut lean fib wrong <<'EOF'
match n with
  | 0 => 1
  | 1 => 1
  | k + 2 => fib k + fib (k + 1)
EOF
mut lean dedup wrong <<'EOF'
l.dedup
EOF
mut lean everyOther wrong <<'EOF'
l.filter (fun x => x % 2 == 1)
EOF
mut lean isPrime wrong <<'EOF'
n % 2 == 1
EOF
mut lean maxList compile <<'EOF'
l.foldl max
EOF
mut lean fact compile <<'EOF'
match n with
  | 0 =>
EOF
mut lean two_mul_self refused <<'EOF'
by sorry
EOF
mut lean add_self_even compile <<'EOF'
by rfl
EOF
mut lean sumList compile <<'EOF'
sumList l
EOF
mut lean power unclosed <<'EOF'
b ^ e
EOF

mut agda double wrong <<'EOF'
double n = n * 3
EOF
mut agda fib wrong <<'EOF'
fib zero = 1
fib (suc zero) = 1
fib (suc (suc n)) = fib n + fib (suc n)
EOF
mut agda rev wrong <<'EOF'
rev xs = xs
EOF
mut agda maxList wrong <<'EOF'
maxList [] = 0
maxList (x ∷ xs) = x
EOF
mut agda fact compile <<'EOF'
fact zero = 1
fact (suc n) = suc (
EOF
mut agda plus-zero compile <<'EOF'
plus-zero n = refl
EOF
mut agda not-not refused <<'EOF'
postulate not-not′ : ∀ (b : Bool) → not (not b) ≡ b
not-not = not-not′
EOF
mut agda isEven refused <<'EOF'
isEven n = {! !}
EOF
mut agda copies refused <<'EOF'
copies n x = ?
EOF
mut agda sumList compile <<'EOF'
sumList xs = xs
EOF

CHECK_ONLY=1 "$Q/run.sh" - selftest "${langs[@]}" > /dev/null
bad=0
for lang in "${langs[@]}"; do
  while IFS=$'\t' read -r n v; do
    w=${want[$lang/$n]:-pass}
    if [ "$v" != "$w" ]; then echo "selftest: $lang/$n is $v, expected $w"; bad=1; fi
  done < "$T/$lang/verdicts.tsv"
  echo "selftest $lang: $(wc -l < "$T/$lang/verdicts.tsv") tasks; $(grep -c $'\tpass$' "$T/$lang/verdicts.tsv") pass; mutated: $(for k in "${!want[@]}"; do [ "${k%%/*}" = "$lang" ] && printf '%s=%s ' "${k#*/}" "${want[$k]}"; done)"
done
[ $bad = 0 ] && echo "selftest: all verdicts as expected"
exit $bad
