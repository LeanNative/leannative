import LeanNative.Native

/-! # Simple: the smallest useful LeanNative app

A counter, a greeting typed into a field, and a list of notes, all in the Lean model; one button asks the shell
for a capability (`open`, the framework's site in the browser). Nothing else reaches the shell, so the app's
manifest (`Simple/Project.lean`) lists only `open` and its shell has no Bluetooth or Face ID code. -/

namespace Simple
open LeanNative LeanNative.Native Lean

structure Model where
  count : Int := 0
  name : String := ""
  draft : String := ""
  notes : List String := []
  /-- the last answer from the shell, shown under the link -/
  status : String := ""
  deriving Inhabited

inductive Host where
  | opened (ok : Bool)

inductive Msg where
  | inc
  | dec
  | name (s : String)
  | draft (s : String)
  | addNote
  | clearNotes
  | openSite
  | host (h : Host)

inductive Cmd where
  | openURL (url : String)
  deriving ToJson

def site : String := "https://leannative.com"

def update : Msg → Model → Model
  | .inc, m => { m with count := m.count + 1 }
  | .dec, m => { m with count := m.count - 1 }
  | .name s, m => { m with name := s }
  | .draft s, m => { m with draft := s }
  | .addNote, m => if m.draft.trimAscii.isEmpty then m else { m with notes := m.notes ++ [m.draft.trimAscii.toString], draft := "" }
  | .clearNotes, m => { m with notes := [] }
  | .openSite, m => { m with status := "opening…" }
  | .host (.opened ok), m => { m with status := if ok then s!"opened {site}" else "the shell could not open it" }

def cmds : Msg → Model → List Cmd
  | .openSite, _ => [.openURL site]
  | _, _ => []

def greeting (m : Model) : String := if m.name.isEmpty then "Nobody yet" else s!"Hello, {m.name}"

def view (m : Model) : Html Msg :=
  .screen "Simple" none
    [ .list
      [ .section "Counter" "The count lives in the Lean model; the buttons send messages to `update`."
          [ .identified "count" (.text s!"Count: {m.count}" .title)
          , .row [ .identified "dec" (.button "−1" .plain (some .dec)), .spacer
                 , .identified "inc" (.button "+1" .primary (some .inc)) ] ]
      , .section "Greeting" ""
          [ .identified "name" (.input .plain "Name" "Who is here" m.name Msg.name none)
          , .identified "greeting" (.text (greeting m) .body) ]
      , .section "Notes" s!"{m.notes.length} {if m.notes.length == 1 then "note" else "notes"}"
          ([ .identified "draft" (.input .plain "Note" "Something to remember" m.draft Msg.draft none)
           , .row [ .identified "addNote" (.button "Add" .primary (if m.draft.trimAscii.isEmpty then none else some .addNote)), .spacer
                  , .identified "clearNotes" (.button "Clear" .plain (if m.notes.isEmpty then none else some .clearNotes)) ] ]
           ++ m.notes.zipIdx.map fun (n, i) => .identified s!"note-{i}" (.text n .body))
      , .section "The shell" "One capability: `open`, the only one this app's manifest lists."
          [ .identified "openSite" (.button "leannative.com" .plain (some .openSite))
          , .identified "status" (.text m.status .caption) ] ] ]

def perform (c : Cmd) (fx : Effects Host) : IO Unit :=
  match c with
  | .openURL url => fx.cap "open" (Json.mkObj [("url", Json.str url)]) fun j =>
      .opened ((j.getObjValAs? Bool "ok").toOption == some true)

def app : Native.App Model Msg Cmd Host :=
  { init := {}, update, view, cmds, host := Msg.host, perform }

initialize Native.register app

end Simple
