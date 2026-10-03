# insert-stage.py STAGES CHAINLOG AFTER LINE...: put LINE right after the stage named
# by the first AFTER that is in STAGES, but never before the stage the chain is on
# (the chain walks the list by position: a line put behind it would be skipped)
import os, re, sys
stages, chainlog, after, line = sys.argv[1], sys.argv[2], sys.argv[3].split(","), " ".join(sys.argv[4:]) + "\n"
ls = open(stages).read().splitlines(True)
name = line.split()[0]
if any(l.split()[:1] == [name] for l in ls): sys.exit(f"{name} is already in the stages")
pos = {l.split()[0]: k for k, l in enumerate(ls) if l.strip() and not l.lstrip().startswith("#")}
i = next((pos[a] + 1 for a in after if a in pos), len(ls))
started = re.findall(r"stage (\S+): from", open(chainlog).read())
if started and started[-1] in pos: i = max(i, pos[started[-1]] + 1)
ls.insert(i, line)
open(stages + ".tmp", "w").writelines(ls); os.replace(stages + ".tmp", stages)
print(f"{name} inserted at line {i + 1} (after {ls[i - 1].split()[0]}); the chain last started {started[-1] if started else '?'}")
