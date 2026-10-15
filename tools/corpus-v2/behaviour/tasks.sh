#!/usr/bin/env bash
# UNWIRED 2026-10-14: ported to Bend (shell→Bend port, phase 5): `bend-corpus-v2 behaviour tasks` (bend/CorpusV2/Behaviour.bend), byte-identical on every tracked result; kept for reference
exit 2
# tasks.sh [LANG...]: turn spec/LANG.tasks into tasks/LANG/NAME/{prompt,sig,pre,tests,kind}
# and refs/LANG/NAME (the reference answer followed by the closing fence), for
# haskell, lean and agda by default.  The prompt is the training layout
# (format 2): the User turn, an optional Context block, the Type turn (its kind
# word, then the statement in a fenced block) and the open Term fence.
# Every file is rewritten; a task that left the spec leaves its directory
# behind until it is removed by hand.  Format of a spec: README.txt.
set -eu
Q=$(cd "$(dirname "$0")" && pwd)
langs=("$@"); [ ${#langs[@]} = 0 ] && langs=(haskell lean agda)
for lang in "${langs[@]}"; do
  spec="$Q/spec/$lang.tasks"
  [ -f "$spec" ] || { echo "tasks.sh: no $spec" >&2; exit 2; }
  mkdir -p "$Q/tasks/$lang" "$Q/refs/$lang"
  LC_ALL=C awk -v Q="$Q" -v lang="$lang" '
    function trim(s) { sub(/\n+$/, "", s); return s }
    function put(f, s) { printf "%s", s > f; close(f) }
    function emit(   d, u, c, t, k) {
      if (name == "") return
      if (sec["type"] == "" || sec["user"] == "") { print "tasks.sh: " lang "/" name ": no user or type" > "/dev/stderr"; bad = 1 }
      d = Q "/tasks/" lang "/" name
      system("mkdir -p \"" d "\"")
      u = trim(sec["user"]); c = trim(sec["context"]); t = trim(sec["type"])
      put(d "/sig", t "\n")
      put(d "/pre", trim(sec["pre"]))
      put(d "/tests", trim(sec["tests"]) "\n")
      put(d "/kind", kind "\n")
      p = "## User\n\n" u "\n\n"
      if (c != "") p = p "## Context\n\n```" lang "\n" c "\n```\n\n"
      p = p "## Type\n\n" kind "\n```" lang "\n" t "\n```\n\n## Term\n\n```" lang "\n"
      put(d "/prompt", p)
      put(Q "/refs/" lang "/" name, trim(sec["ref"]) "\n```\n")
      n++
      name = ""; delete sec
    }
    /^@@#/ { next }
    /^@@ task / { emit(); name = $3; kind = $4; cur = ""
                  if (kind != "type" && kind != "proposition") { print "tasks.sh: " name ": kind " kind > "/dev/stderr"; bad = 1 }
                  if (name in seen) { print "tasks.sh: " name " twice" > "/dev/stderr"; bad = 1 }
                  seen[name] = 1; next }
    /^@@ (user|context|type|pre|tests|ref)$/ { cur = $2; next }
    /^@@/ { print "tasks.sh: " FILENAME ":" FNR ": unknown directive " $0 > "/dev/stderr"; bad = 1; next }
    { if (name == "") next; sec[cur] = sec[cur] $0 "\n" }
    END { emit(); print lang ": " n " tasks"; exit bad }
  ' "$spec"
done
