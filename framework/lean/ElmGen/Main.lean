import ElmGen
/-!
`elmgen`: generate the Swift app from the proven Lean definitions.

  lake exe elmgen --app Todo.app --name TodoApp --out <Generated.swift> --screen <Screen.swift>
                  [--screen-name TodoScreen] [--import <Module>]...

Run from the app's own Lake package (which requires `elmlean`). Imports `ElmLean` plus every
`--import` (default: the app constant's root module, `Todo` for `Todo.app`), translates everything reachable from `--app` in `MetaM`,
writes BOTH files only when both translations succeeded, prints the judgment log to stderr, and exits
1 naming the construct on anything unsupported (writing nothing).
-/
open Lean

structure Args where
  app : Option String := none
  name : Option String := none
  out : Option String := none
  screen : Option String := none
  screenName : Option String := none
  imports : List String := []

def usage : String :=
  "usage: elmgen --app <Lean constant> --name <SwiftApp> --out <Generated.swift> --screen <Screen.swift> [--screen-name <Name>] [--import <Module>]..."

def parseArgs : List String → Args → Except String Args
  | [], a => .ok a
  | "--app" :: v :: rest, a => parseArgs rest { a with app := v }
  | "--name" :: v :: rest, a => parseArgs rest { a with name := v }
  | "--out" :: v :: rest, a => parseArgs rest { a with out := v }
  | "--screen" :: v :: rest, a => parseArgs rest { a with screen := v }
  | "--screen-name" :: v :: rest, a => parseArgs rest { a with screenName := v }
  | "--import" :: v :: rest, a => parseArgs rest { a with imports := a.imports ++ [v] }
  | other :: _, _ => .error s!"unknown or incomplete argument `{other}`"

unsafe def main (argv : List String) : IO UInt32 := do
  let a ← match parseArgs argv {} with
    | .ok a => pure a
    | .error e => IO.eprintln s!"elmgen: {e}\n{usage}"; return 2
  let (some app, some name, some out, some screen) := (a.app, a.name, a.out, a.screen)
    | IO.eprintln s!"elmgen: --app, --name, --out and --screen are required\n{usage}"; return 2
  let screenName := a.screenName.getD (ElmGen.defaultScreenName name)
  let appConst := app.toName
  let mods := if a.imports.isEmpty then [appConst.getRoot] else a.imports.map String.toName
  let imports : Array Import := (#[`ElmLean] ++ mods.toArray).map fun m => { module := m }
  try
    enableInitializersExecution
    initSearchPath (← findSysroot)
    let env ← importModules imports {} (trustLevel := 1024) (loadExts := true)
    let ctx : Core.Context := { fileName := "<elmgen>", fileMap := default, maxHeartbeats := 0 }
    let (o, _, _) ← (ElmGen.generateAll appConst name screenName).toIO ctx { env }
    for j in o.judgments do IO.eprintln s!"elmgen: judgment: {j}"
    IO.FS.writeFile out o.generated
    IO.FS.writeFile screen o.screen
    IO.eprintln s!"elmgen: wrote {out} and {screen} ({o.summary}; {o.judgments.size} judgments)"
    return 0
  catch e =>
    IO.eprintln s!"elmgen: error: {e}"
    return 1
