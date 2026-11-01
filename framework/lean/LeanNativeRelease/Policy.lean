import LeanNativeRelease.Run

/-! # What a release may be

A release is a stable `vMAJOR.MINOR.PATCH` tag, and its TestFlight What to Test text is present and at most
4,000 characters: App Store Connect refuses a longer one only after the build is uploaded (Winnow's 0.8.16
and 0.8.17 releases failed there). The text is the file without trailing whitespace, as it is sent. -/

namespace LeanNativeRelease

/-- `v(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){2}`. -/
def isStableTag (tag : String) : Bool :=
  match tag.toList with
  | 'v' :: rest =>
    let parts := (String.ofList rest).splitOn "."
    parts.length == 3 && parts.all fun p =>
      !p.isEmpty && p.all Char.isDigit && (p == "0" || !p.startsWith "0")
  | _ => false

def notesLimit : Nat := 4000

/-- The What to Test text as App Store Connect gets it, or why it cannot be sent. -/
def notesText (path : System.FilePath) : IO String := do
  unless ← path.pathExists do fail s!"{path} is missing or empty"
  let text := (← IO.FS.readFile path).trimAsciiEnd.toString
  if text.isEmpty then fail s!"{path} is missing or empty"
  if text.length > notesLimit then
    fail s!"{path} is {text.length} characters; App Store Connect takes at most {notesLimit}"
  return text

/-- The tag (when there is one) and the notes. -/
def policy (notes : System.FilePath) (tag : Option String) : IO Unit := do
  if let some t := tag then
    unless isStableTag t do fail s!"{t}: expected a stable vMAJOR.MINOR.PATCH tag"
  let text ← notesText notes
  say s!"policy: {tag.getD "no tag"}; {notes}: {text.length} of {notesLimit} characters"

/-- Adds `line` to the notes as its last paragraph (the release adds what the build bundles, on the runner
only), then checks the result again. -/
def appendNotes (notes : System.FilePath) (line : String) : IO Unit := do
  let text := (← IO.FS.readFile notes).trimAsciiEnd.toString
  IO.FS.writeFile notes (text ++ "\n\n" ++ trim line ++ "\n")
  discard <| notesText notes
  say s!"notes: added \"{trim line}\""

end LeanNativeRelease
