import Lean
open Lean Elab

/-!
The Lean side of run.sh's behaviour check:

  LEAN_PATH=… lean --run Check.lean FILE CUT

elaborates FILE's first CUT lines (its imports, the task's pre, the Type
joined to the answer, and the `section` line that closes the answer), prints
their messages as `lean` does, and exits 1 when one is an error.  Only an
answer without errors goes on: the marker line `-- behaviour: tests`, then
the rest of FILE (the tests) is elaborated from the state the answer left,
its messages printed, exit 2 when one is an error, else 0.

The tests must never run against an answer with errors: Lean still compiles
a definition whose termination proof failed (`def f (n : ℕ) : ℕ := f n`), so
a `#guard` on it would evaluate code that never stops.
-/

def render (log : MessageLog) : IO Unit := do
  for m in log.toList do
    let t ← m.toString
    IO.print (if t.endsWith "\n" then t else t ++ "\n")

unsafe def main (args : List String) : IO UInt32 := do
  let [file, cut] := args | IO.eprintln "usage: Check.lean FILE CUT"; return 3
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let input ← IO.FS.readFile file
  let head := "\n".intercalate ((input.splitOn "\n").take cut.toNat!) ++ "\n"
  let inputCtx := Parser.mkInputContext head file
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  let (env, messages) ← processHeader header {} messages inputCtx (trustLevel := 1024)
  if messages.hasErrors then
    render messages
    return 1
  let fs ← IO.processCommands inputCtx parserState (Command.mkState env messages {})
  render fs.commandState.messages
  if fs.commandState.messages.hasErrors then return 1
  IO.println "-- behaviour: tests"
  let rest := Parser.mkInputContext input file
  let ts ← IO.processCommands rest { pos := ⟨head.utf8ByteSize⟩ } { fs.commandState with messages := {} }
  render ts.commandState.messages
  return if ts.commandState.messages.hasErrors then 2 else 0
