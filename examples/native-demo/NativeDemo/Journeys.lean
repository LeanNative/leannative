import LeanNative.Journey
import LeanNative.Journey.Wire
import NativeDemo.App

/-! # native-demo's journeys: the test kit's driver from Lean on the host

The same app as ios/UITests/NativeDemoUITests.m (the kit's own tests, in Objective-C), driven instead by
`LeanNative.Journey`: each step a command to LNDriver, each check here, against the app's own `update`.

    APP_DIR=examples/native-demo APP_ROOT=NativeDemo SCHEME=NativeDemo \
      UI_JOURNEY="$PWD/examples/native-demo/.lake/build/bin/journeys" framework/native/ci/ui-tests

or, with no simulator, against the app itself (LeanNative.Journey.Wire):

    LEANNATIVE_DRIVER=wire examples/native-demo/.lake/build/bin/journeys <evidence directory> -/

namespace NativeDemo.Journeys
open LeanNative LeanNative.Journey

/-- Two taps of +1, and the count the app's own `update` gives for them. -/
def counting : Journey := ⟨"counting", do
  launch
  let start := app.init
  expectEq "the count at launch" (← text "count") s!"Count: {start.count}"
  tap "inc"; tap "inc"
  let after := [Msg.inc, .inc].foldl (fun m msg => update msg m) start
  waitUntil 5 s!"the count reaches {after.count}" do return (← text "count") == s!"Count: {after.count}"⟩

/-- Typing replaces the field's text, and an empty replacement clears it. -/
def typing : Journey := ⟨"typing", do
  launch
  for (name, greeting) in [("Ada", "Hello, Ada"), ("Grace Hopper", "Hello, Grace Hopper"), ("", "Nobody yet")] do
    type "name" name
    waitUntil 5 s!"the greeting {greeting}" do return (← text "greeting") == greeting⟩

/-- A step that cannot be done fails with the driver's reason, and nothing is tapped: a missing control, and
`Start` once the ticker runs (the view gives it no action, the shell disables it). -/
def refusals : Journey := ⟨"refusals", do
  launch
  let refused (step : UI Unit) : UI (Option String) := do
    try step; return none catch e => return some (toString e)
  let some why ← refused (tap "noSuchControl") | failure "tapping a missing control succeeded"
  log s!"missing control: {why}"
  expectGone "noSuchControl"
  tap "startTicks"
  waitUntil 5 "Start is disabled while ticking" do return !(← state "startTicks").enabled
  let some why ← refused (tap "startTicks") | failure "tapping the disabled Start succeeded"
  log s!"disabled control: {why}"
  expectEq "the count" (← text "count") "Count: 0"⟩

/-- The last probe is below the fold on a phone: `scrollTo` brings it into view, `tap` taps it; its answer is
logged. -/
def scrolling : Journey := ⟨"scrolling", do
  launch
  tap (.tab "Probes")
  expect (← scrollTo "probe-12") "the last probe cannot be scrolled into view"
  tap "probe-12"
  waitFor (.text "^(asking: )?HTTP bad proxy") 10⟩

/-- Text patterns as journeys write them: a class with a count (`\d{2,3}`), an escaped metacharacter (`\.`), and
`Find.beginning`, which escapes its text: a probe's label has parentheses, which unescaped are a group. -/
def patterns : Journey := ⟨"patterns", do
  launch
  let twoOrThreeDigits := Find.text "^Count: \\d{2,3}$"
  waitFor "count"
  expect (!(← exists? twoOrThreeDigits)) "Count: 0 matched two or three digits"
  tap "inc" (times := 12)
  waitFor twoOrThreeDigits 5
  expectEq "the count, found by its pattern" (← text twoOrThreeDigits) "Count: 12"
  expectEq "the caption ending in a full stop" (← text (.text "inside the iOS app\\.$")) "This screen is Lean compiled to C, running inside the iOS app."
  expect (!(← exists? (.text "compiled to C\\."))) "an escaped full stop matched the comma after C"
  tap (.tab "Probes")
  expectEq "the probe its label begins" (← text (Find.beginning "Complete (none pending)")) "Complete (none pending)"
  expect (!(← exists? (.text "^Complete (none pending)"))) "the label matched with its parentheses read as a group"⟩

/-- Screenshots, written to the evidence directory's screenshots/ and attached to the test. -/
def screenshots : Journey := ⟨"screenshots", do
  launch
  waitFor "count"
  shot "journey-demo"
  tap (.tab "Widgets")
  shot "journey-widgets"⟩

end NativeDemo.Journeys

open NativeDemo.Journeys in
def main (args : List String) : IO UInt32 :=
  LeanNative.Journey.main [counting, typing, refusals, scrolling, patterns, screenshots] args
    (wire := some (LeanNative.Journey.Wire.app NativeDemo.app))
