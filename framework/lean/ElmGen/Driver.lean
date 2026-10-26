import ElmGen.Emit
import ElmGen.Screen
/-!
# ElmGen.Driver

The pure entry point shared by the `elmgen` executable and the tests: translate, print both files,
collect the judgment log.  Nothing here touches the file system.
-/

namespace ElmGen
open Lean Meta

structure Output where
  generated : String
  screen : String
  /-- translation judgments followed by the screen printer's -/
  judgments : Array String
  summary : String

/-- Translate the app and print both files; throws (naming the construct) on anything unsupported. -/
def generateAll (appConst : Name) (appName screenName : String) : MetaM Output := do
  let r ← translateApp appConst appName screenName
  let generated := renderGenerated r
  match Screen.render r with
  | .error e => throwError e
  | .ok (screen, sjs) =>
    pure { generated, screen, judgments := r.judgments ++ sjs,
           summary := s!"{r.types.size} types, {r.defs.size + r.members.size} definitions, {r.shims.size} shims" }

/-- The default screen name: `TodoApp` → `TodoScreen`, otherwise `<name>Screen`. -/
def defaultScreenName (appName : String) : String :=
  if appName.endsWith "App" && appName.length > 3 then String.ofList (appName.toList.take (appName.length - 3)) ++ "Screen" else appName ++ "Screen"

end ElmGen
