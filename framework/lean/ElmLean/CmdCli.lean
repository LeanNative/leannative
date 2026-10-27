import ElmLean.Cli
import ElmLean.Cmd

/-! # TRUSTED SHELL: the stdin/stdout loop of an app with commands (see PROTOCOL.md, "Commands")

An app with commands has a one-line executable too:

    def main (args : List String) : IO UInt32 := ElmLean.CmdCli.main MyApp.app args MyApp.options

`Cmd` must have a `ToJson` instance and `Host` both `FromJson` and `ToJson` (derive them). The loop
is `Session.step`: user events exactly as for a pure app, `{"host":…}` lines run `update (app.host h)`
with no `seq` check, and every view reply carries the step's commands as `"cmds"`. -/

namespace ElmLean.CmdCli
open Lean

variable {M Msg Cmd Host : Type} [ToJson Cmd] [FromJson Host] [ToJson Host]

structure Options (M Host : Type) where
  /-- The pure app's options: the invariant's runtime mirror, field inputs, step bound, script. -/
  cli : Cli.Options M := {}
  /-- Plausible host answers in a model, for the self-test and the lockstep driver (`{"samples":true}`). -/
  samples : M → List Host := fun _ => []

/-- A view reply with the step's commands. -/
def viewReply (seq : Nat) (w : Wire) (cs : List Cmd) : Json :=
  Json.mkObj [("seq", toJson seq), ("view", w.toJson), ("cmds", Json.arr (cs.map toJson).toArray)]

def replyJson (reply : Reply) (cs : List Cmd) : Json :=
  match reply with
  | .view seq w => viewReply seq w cs
  | other => other.toJson

inductive Command (Host : Type) where
  | reset
  | samples
  | input (i : Input Host)

def parseCommand (line : String) : Except String (Command Host) := do
  let j ← Json.parse line
  match j.getObjVal? "reset" with
  | .ok (Json.bool true) => return .reset
  | _ =>
  match j.getObjVal? "samples" with
  | .ok (Json.bool true) => return .samples
  | _ =>
  match j.getObjVal? "host" with
  | .ok h => return .input (.host (← fromJson? h))
  | .error _ => return .input (.event (← Request.ofJson? j))

partial def loop (app : CmdApp M Msg Cmd Host) (opts : Options M Host) (stdin : IO.FS.Stream)
    (s : Session M Msg) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return
  match parseCommand (Host := Host) line with
  | .error e =>
    Cli.emit (Reply.error s.seq (.badJson e) none).toJson
    loop app opts stdin s
  | .ok .reset =>
    let s' := s.reset app.toApp
    Cli.emit (viewReply s'.seq s'.lastView.toWire ([] : List Cmd))
    loop app opts stdin s'
  | .ok .samples =>
    Cli.emit (Json.mkObj [("seq", toJson s.seq), ("samples", Json.arr ((opts.samples s.model).map toJson).toArray)])
    loop app opts stdin s
  | .ok (.input i) =>
    let (s', reply, cs) := s.step app i
    Cli.emit (replyJson reply cs)
    loop app opts stdin s'

def serve (app : CmdApp M Msg Cmd Host) (opts : Options M Host) : IO UInt32 := do
  let s := Session.start app.toApp
  Cli.emit (viewReply s.seq s.lastView.toWire ([] : List Cmd))
  loop app opts (← IO.getStdin) s
  return 0

/-- The command JSON re-parses and re-compresses to the same string. -/
def roundTrip (what : String) (j : Json) : Except String Unit := do
  let str := j.compress
  match Json.parse str with
  | .error err => throw s!"{what}: reply JSON does not re-parse: {err}"
  | .ok j' => unless j'.compress == str do throw s!"{what}: reply JSON round trip differs"

/-- The self-test: the generic exploration of the user's half (`Selftest.explore` on `app.toApp`,
which fires every advertised control), then a breadth-first exploration that also feeds every
sample host answer in every reached model, re-checking coherence, `seq + 1`, the app's invariant
check and the JSON round trip of every reply (commands and host answers included). -/
def explore (app : CmdApp M Msg Cmd Host) (opts : Options M Host) : Except String (Nat × Nat) := do
  let s0 := Session.start app.toApp
  let mut frontier : List (Session M Msg) := [s0]
  let mut steps := 0
  let mut depth := 0
  while steps < opts.cli.maxSteps && !frontier.isEmpty do
    let mut next : Array (Session M Msg) := #[]
    for s in frontier do
      let w := s.lastView.toWire
      let mut inputs : Array (Input Host) := #[]
      for p in w.paths do
        for e in Selftest.probeEvents opts.cli.inputs do
          if w.advertises p e then inputs := inputs.push (.event ⟨s.seq, p, e⟩)
      for h in opts.samples s.model do
        inputs := inputs.push (.host h)
        let hj := toJson h
        match (fromJson? hj : Except String Host) with
        | .error e => throw s!"a sample host answer does not decode: {e}"
        | .ok h' => unless (toJson h').compress == hj.compress do throw "a sample host answer does not round-trip"
      for i in inputs do
        if steps < opts.cli.maxSteps then
          let what := s!"step {steps + 1} (depth {depth + 1})"
          let (s', reply, cs) := s.step app i
          match reply with
          | .view seq w' =>
            unless seq == s.seq + 1 && s'.seq == seq do throw s!"{what}: seq did not advance by one"
            unless Selftest.sameWire w' s'.lastView.toWire do throw s!"{what}: the reply's view is not lastView"
          | .error _ code _ => throw s!"{what}: an advertised input was rejected with '{code.str}'"
          roundTrip what (replyJson reply cs)
          unless opts.cli.check s'.model do throw s!"{what}: the app's invariant check failed"
          unless Selftest.sameWire s'.lastView.toWire (app.view s'.model).toWire do
            throw s!"{what}: lastView is not the view of the model"
          next := next.push s'
          steps := steps + 1
    frontier := next.toList
    depth := depth + 1
  pure (steps, depth)

def selftest (app : CmdApp M Msg Cmd Host) (opts : Options M Host) : IO UInt32 := do
  match Selftest.explore app.toApp opts.cli.toOptions, explore app opts with
  | .error e, _ | _, .error e =>
    IO.eprintln s!"selftest: FAIL (exploration) — {e}"
    return 1
  | .ok (steps, depth), .ok (csteps, cdepth) =>
    match opts.cli.script with
    | .error e =>
      IO.eprintln s!"selftest: FAIL (app script) — {e}"
      return 1
    | .ok summary =>
      let extra := if summary.isEmpty then "" else s!"; app script: {summary}"
      IO.eprintln s!"selftest: OK (explored {steps} advertised steps to depth {depth}; with host answers {csteps} steps to depth {cdepth}{extra})"
      return 0

/-- The whole command line of an app's executable. -/
def main (app : CmdApp M Msg Cmd Host) (args : List String) (opts : Options M Host := {}) : IO UInt32 := do
  match args with
  | [] | ["serve"] => serve app opts
  | ["view"] =>
    Cli.emit (viewReply 0 (app.view app.init).toWire ([] : List Cmd))
    return 0
  | ["selftest"] | ["--selftest"] => selftest app opts
  | _ =>
    IO.eprintln "usage: <app> [serve|view|selftest]"
    return 2

end ElmLean.CmdCli
