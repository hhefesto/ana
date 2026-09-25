import Lean
open Lean Elab

/-!
The Lean side of deploy/check/lean.sh: elaborates a file's head once, then
each variant of one declaration from the state the head left, so a mathlib
file's head is paid for once per unit instead of once per variant.

  lake env lean --run Harness.lean JOB OUT

JOB is fields joined by the byte 0x1E: the head (the whole lines of the file
before the declaration, imports included), then the variants (each the text
that follows the head: the declaration with one body, or `#check` lines).
OUT gets one check per variant, joined by 0x1E: the status (0, or 1 when an
error was logged), the byte 0x1F, and the messages exactly as `lean` prints
them for the file head ++ variant, named Unit.lean (positions included). A
variant made of `#check` lines gets only the messages' text, one per line,
errors left out: these are the Context lines. A head whose imports fail
gives every variant status 2 and the import error.
-/

def sep (c : Nat) : String := String.singleton (Char.ofNat c)

def render (context : Bool) (log : MessageLog) : IO String := do
  let mut out := ""
  for m in log.toList do
    if context then
      unless m.severity == .error do
        let t ← m.data.toString
        out := out ++ t ++ (if t.endsWith "\n" then "" else "\n")
    else
      out := out ++ (← m.toString)
  return out

def variant (head v : String) (s : Command.State) : IO String := do
  let input := head ++ v
  let inputCtx := Parser.mkInputContext input "Unit.lean"
  let fs ← IO.processCommands inputCtx { pos := ⟨head.utf8ByteSize⟩ } { s with messages := {} }
  let log := fs.commandState.messages
  let status := if log.hasErrors then "1" else "0"
  return status ++ sep 0x1f ++ (← render (v.startsWith "#check") log)

unsafe def main (args : List String) : IO UInt32 := do
  let [job, out] := args | IO.eprintln "usage: Harness.lean JOB OUT"; return 2
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let fields := (← IO.FS.readFile job).splitOn (sep 0x1e)
  let head := fields.headD ""
  let variants := fields.drop 1
  let inputCtx := Parser.mkInputContext head "Unit.lean"
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  let (env, messages) ← processHeader header {} messages inputCtx (trustLevel := 1024)
  if messages.hasErrors then
    let msg ← render false messages
    IO.FS.writeFile out (sep 0x1e |>.intercalate (variants.map fun _ => "2" ++ sep 0x1f ++ msg))
    return 0
  let fs ← IO.processCommands inputCtx parserState (Command.mkState env messages {})
  let mut checks := #[]
  for v in variants do
    checks := checks.push (← variant head v fs.commandState)
  IO.FS.writeFile out (sep 0x1e |>.intercalate checks.toList)
  return 0
