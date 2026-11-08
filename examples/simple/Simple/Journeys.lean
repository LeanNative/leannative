import LeanNative.Journey
import LeanNative.Journey.Wire
import Simple.App

/-! # Simple's journey: what a person does with it, from Lean on the host

    APP_DIR=examples/simple APP_ROOT=Simple SCHEME=Simple \
      UI_JOURNEY="$PWD/examples/simple/.lake/build/bin/journeys" framework/native/ci/ui-tests

or, with no simulator, against the app itself (LeanNative.Journey.Wire):

    LEANNATIVE_DRIVER=wire examples/simple/.lake/build/bin/journeys <evidence directory>

Each check is against the app's own `update`, and the screenshots are the website's (CI publishes them). -/

namespace Simple.Journeys
open LeanNative LeanNative.Journey

/-- Count, greet, take two notes and clear them; then the link, the app's one capability: `open` goes to the
shell (on a simulator Safari comes to the front, so the app is brought back), and the status shows its answer. -/
def tour : Journey := ⟨"tour", do
  launch
  waitFor "count"
  shot "simple-launch"
  tap "inc" (times := 3); tap "dec"
  let counted := [Msg.inc, .inc, .inc, .dec].foldl (fun m msg => update msg m) app.init
  waitUntil 5 s!"the count reaches {counted.count}" do return (← text "count") == s!"Count: {counted.count}"
  type "name" "Ada"
  waitUntil 5 "the greeting" do return (← text "greeting") == "Hello, Ada"
  shot "simple-counter"
  for note in ["Buy milk", "Prove it in Lean"] do
    type "draft" note
    tap "addNote"
  waitFor "note-1"
  expectEq "the first note" (← text "note-0") "Buy milk"
  shot "simple-notes"
  tap "clearNotes"
  expectGone "note-0"
  tap "openSite"
  activate
  let opened := update (.host (.opened true)) (update .openSite app.init)
  try waitUntil 10 s!"the status \"{opened.status}\"" do return (← text "status") == opened.status
  catch e => failure s!"{e}; it says \"{← text "status"}\""⟩

end Simple.Journeys

open Simple.Journeys in
def main (args : List String) : IO UInt32 :=
  LeanNative.Journey.main [tour] args (wire := some (LeanNative.Journey.Wire.app Simple.app))
