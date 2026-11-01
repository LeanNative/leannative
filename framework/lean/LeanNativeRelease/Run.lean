import Lean.Data.Json

/-! # Processes, the environment and files for the release tool

The release tool (`leannative-release`, `LeanNativeRelease.Main`) drives Apple's command-line tools, curl and
openssl as child processes: these helpers run one and fail with its output, read the environment the release
workflow sets, and read a property list through `plutil` as JSON. -/

namespace LeanNativeRelease
open Lean

def fail {α} (message : String) : IO α := throw (IO.userError message)

def trim (s : String) : String := s.trimAscii.toString

def say (line : String) : IO Unit := do
  IO.println line
  (← IO.getStdout).flush

def warn (line : String) : IO Unit := do
  IO.eprintln line
  (← IO.getStderr).flush

/-- The command's output; when it exits non-zero (and `check`), the step fails with its exit status, stderr
and stdout. -/
def run (cmd : String) (args : Array String) (check : Bool := true)
    (env : Array (String × Option String) := #[]) : IO IO.Process.Output := do
  let out ← IO.Process.output { cmd, args, env }
  if check && out.exitCode != 0 then
    let shown := if out.stdout.isEmpty then "" else "\n" ++ trim out.stdout
    fail s!"{cmd} {" ".intercalate args.toList}: exit {out.exitCode}\n{trim out.stderr}{shown}"
  return out

/-- A variable's value, none when unset or empty. -/
def env? (name : String) : IO (Option String) := do
  return (← IO.getEnv name).filter (· != "")

def need (name : String) : IO String := do
  match ← env? name with
  | some v => pure v
  | none => fail s!"set {name}"

def envNat (name : String) (default : Nat) : IO Nat := do
  match ← env? name with
  | some v => match v.toNat? with
    | some n => pure n
    | none => fail s!"{name} is not a number: {v}"
  | none => pure default

/-- A new file holding `contents`; the caller removes it. -/
def tempFile (contents : ByteArray) : IO System.FilePath := do
  let (h, path) ← IO.FS.createTempFile
  h.write contents
  h.flush
  return path

def sleepSeconds (s : Nat) : IO Unit := IO.sleep (s * 1000).toUInt32

/-- A property list (XML or binary) as JSON, by `plutil -convert json`. -/
def plistJson (path : System.FilePath) : IO Json := do
  let out ← run "plutil" #["-convert", "json", "-o", "-", "--", path.toString]
  match Json.parse out.stdout with
  | .ok j => pure j
  | .error e => fail s!"{path}: plutil's JSON does not parse: {e}"

/-! ## Reading JSON -/

/-- A string, or a number as written; empty for anything else. -/
def strOf : Json → String
  | .str s => s
  | .num n => toString n
  | _ => ""

/-- The value at a path of object keys; null where a key is missing. -/
def at? (j : Json) : List String → Json
  | [] => j
  | k :: ks => at? (j.getObjValD k) ks

def arrOf (j : Json) : Array Json := j.getArr?.toOption.getD #[]

def boolOf? (j : Json) : Option Bool := j.getBool?.toOption

end LeanNativeRelease
