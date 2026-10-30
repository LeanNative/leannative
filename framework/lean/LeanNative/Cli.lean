import LeanNative.Selftest

/-! # TRUSTED SHELL: the stdin/stdout loop (see PROTOCOL.md)

An app's executable is one line:

    def main (args : List String) : IO UInt32 := LeanNative.Cli.main MyApp.app args

`serve` (the default) speaks the protocol on stdin/stdout, `view` prints the initial frame, and
`selftest` runs the generic exploration of `LeanNative.Selftest` plus the app's own `Options.script`. -/

namespace LeanNative.Cli
open Lean

/-- Print one protocol line. Pipes are block-buffered, so flush every time. -/
def emit (j : Json) : IO Unit := do
  IO.println j.compress
  (← IO.getStdout).flush

inductive Command where
  | reset
  | request (r : Request)

def parseCommand (line : String) : Except String Command := do
  let j ← Json.parse line
  match j.getObjVal? "reset" with
  | .ok (Json.bool true) => pure .reset
  | _ => .request <$> Request.ofJson? j

variable {M Msg : Type}

/-- Exactly one reply per input line; EOF (`getLine` returns `""`) ends the loop. -/
partial def loop (app : App M Msg) (stdin : IO.FS.Stream) (s : Session M Msg) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return
  match parseCommand line with
  | .error e =>
    emit (Reply.error s.seq (.badJson e) none).toJson
    loop app stdin s
  | .ok .reset =>
    let s' := s.reset app
    emit (Reply.view s'.seq s'.lastView.toWire).toJson
    loop app stdin s'
  | .ok (.request r) =>
    let (s', reply) := s.handle app r
    emit reply.toJson
    loop app stdin s'

def serve (app : App M Msg) : IO UInt32 := do
  let s := Session.start app
  emit (Reply.view s.seq s.lastView.toWire).toJson
  loop app (← IO.getStdin) s
  return 0

structure Options (M : Type) extends Selftest.Options M where
  /-- An app-specific scripted self-test run after the exploration; returns a one-line summary. -/
  script : Except String String := pure ""

/-- Generic exploration, then the app's script. Prints a summary on stderr, nothing on stdout. -/
def selftest (app : App M Msg) (opts : Options M) : IO UInt32 := do
  match Selftest.explore app opts.toOptions with
  | .error e =>
    IO.eprintln s!"selftest: FAIL (exploration) — {e}"
    return 1
  | .ok (steps, depth) =>
    match opts.script with
    | .error e =>
      IO.eprintln s!"selftest: FAIL (app script) — {e}"
      return 1
    | .ok summary =>
      let extra := if summary.isEmpty then "" else s!"; app script: {summary}"
      IO.eprintln s!"selftest: OK (explored {steps} advertised steps to depth {depth}{extra})"
      return 0

/-- The whole command line of an app's executable. -/
def main (app : App M Msg) (args : List String) (opts : Options M := {}) : IO UInt32 := do
  match args with
  | [] | ["serve"] => serve app
  | ["view"] =>
    emit (Reply.view 0 (app.view app.init).toWire).toJson
    return 0
  | ["selftest"] | ["--selftest"] => selftest app opts
  | _ =>
    IO.eprintln "usage: <app> [serve|view|selftest]"
    return 2

end LeanNative.Cli
