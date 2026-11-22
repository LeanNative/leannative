import Lean.Data.Json
import Std.Data.HashMap
import LeanNative.Wire

/-! # The record of what a run did

What `Native.runtime` keeps when `LEANNATIVE_COVERAGE` names a file (`Native.Recorder`), and what the journeys add
up from it (`Journey.main`): how many times each message reached `update` and each command reached `perform`, by
tag (`LeanNative.Tag`, through `Native.App.tagging`), each capability asked of the shell and how many of its
answers were failures, and each element identifier a view showed. With the app's lists of every tag there is,
the messages and commands that never came are what its journeys never did.

Names only: a tag is constructors' names, a capability is its name, an identifier is the view's. -/

namespace LeanNative
open Lean

/-- How often each thing happened, by name. -/
structure Tally where
  msgs : Std.HashMap String Nat := {}
  cmds : Std.HashMap String Nat := {}
  /-- every answer to a capability, by its name -/
  caps : Std.HashMap String Nat := {}
  /-- the answers that were failures (`capFailed`) -/
  capFailures : Std.HashMap String Nat := {}
  ids : Std.HashMap String Nat := {}
  /-- every message and command tag the app has (`Tagging.allMsgs`, `allCmds`) -/
  allMsgs : Array String := #[]
  allCmds : Array String := #[]
  deriving Inhabited

namespace Tally

def bump (m : Std.HashMap String Nat) (k : String) (n : Nat := 1) : Std.HashMap String Nat :=
  m.insert k (m.getD k 0 + n)

private def zipWith (f : Nat → Nat → Nat) (a b : Std.HashMap String Nat) : Std.HashMap String Nat :=
  let keys := b.fold (init := a) fun acc k _ => if acc.contains k then acc else acc.insert k 0
  keys.fold (init := {}) fun acc k v => let n := f v (b.getD k 0); if n == 0 then acc else acc.insert k n

/-- Both together. -/
def add (a b : Tally) : Tally :=
  { msgs := zipWith (· + ·) a.msgs b.msgs, cmds := zipWith (· + ·) a.cmds b.cmds,
    caps := zipWith (· + ·) a.caps b.caps, capFailures := zipWith (· + ·) a.capFailures b.capFailures,
    ids := zipWith (· + ·) a.ids b.ids,
    allMsgs := if a.allMsgs.isEmpty then b.allMsgs else a.allMsgs,
    allCmds := if a.allCmds.isEmpty then b.allCmds else a.allCmds }

/-- What `a` has beyond `b`: a running process's record since it was last read. -/
def sub (a b : Tally) : Tally :=
  { msgs := zipWith (· - ·) a.msgs b.msgs, cmds := zipWith (· - ·) a.cmds b.cmds,
    caps := zipWith (· - ·) a.caps b.caps, capFailures := zipWith (· - ·) a.capFailures b.capFailures,
    ids := zipWith (· - ·) a.ids b.ids, allMsgs := a.allMsgs, allCmds := a.allCmds }

private def sorted (m : Std.HashMap String Nat) : Json :=
  Json.mkObj ((m.toArray.qsort (·.1 < ·.1)).toList.map fun (k, n) => (k, toJson n))

private def read (j : Json) (key : String) : Std.HashMap String Nat :=
  match j.getObjVal? key >>= Json.getObj? with
  | .ok kvs => kvs.foldl (init := {}) fun m k v => match v.getNat? with | .ok n => m.insert k n | .error _ => m
  | .error _ => {}

def toJson (t : Tally) : Json :=
  Json.mkObj [("msgs", sorted t.msgs), ("cmds", sorted t.cmds), ("caps", sorted t.caps),
              ("capFailures", sorted t.capFailures), ("ids", sorted t.ids),
              ("allMsgs", Lean.toJson t.allMsgs), ("allCmds", Lean.toJson t.allCmds)]

def ofJson (j : Json) : Tally :=
  { msgs := read j "msgs", cmds := read j "cmds", caps := read j "caps", capFailures := read j "capFailures",
    ids := read j "ids",
    allMsgs := ((j.getObjValAs? (Array String) "allMsgs").toOption.getD #[]),
    allCmds := ((j.getObjValAs? (Array String) "allCmds").toOption.getD #[]) }

/-- The tags among `all` that never came. -/
def never (all : Array String) (seen : Std.HashMap String Nat) : Array String :=
  all.filter (!seen.contains ·)

/-- One line: how much of each kind came. -/
def summary (t : Tally) : String :=
  let part (n total : Nat) (what : String) := if total == 0 then s!"{n} {what}" else s!"{n} of {total} {what}"
  let failed := t.capFailures.fold (init := 0) fun acc _ n => acc + n
  s!"{part t.msgs.size t.allMsgs.size "messages"}, {part t.cmds.size t.allCmds.size "commands"}, " ++
    s!"{t.caps.size} capabilities ({failed} failed answers), {t.ids.size} element identifiers"

end Tally

/-- Every element identifier in the tree (`Html.identified`), nested ones included. -/
partial def Wire.identifiers : Wire → Array String
  | .identified id w => #[id] ++ w.identifiers
  | w => w.children.foldl (fun acc c => acc ++ c.identifiers) #[]

/-- Whether a capability's answer is a failure: `{"error": …}`, `{"ok": false, …}`, or a Keychain answer whose
`status` (an `OSStatus`) is not 0. -/
def capFailed (result : Json) : Bool :=
  (result.getObjVal? "error").isOk || (result.getObjValAs? Bool "ok" matches .ok false) ||
    (match result.getObjValAs? Int "status" with | .ok n => n != 0 | .error _ => false)

end LeanNative
