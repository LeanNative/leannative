import LeanNative.Native

/-! # Native.runtime: a `perform` that throws

The runtime the shell drives (`start`, `event`, `system`, `drain`), with an app whose `perform` throws for one
command. A command's failure is its own: the commands after it in the same step still run, the reply is still
the view, and the host answers queued behind it are still applied (one exception used to end the drain, with
the answers it had taken from the inbox gone). -/

namespace LeanNativeTest.NativeRuntime
open LeanNative LeanNative.Native Lean

structure Model where
  /-- the host answers applied, in order -/
  applied : List Nat := []
  taps : Nat := 0

inductive Host where
  | answer (n : Nat)

inductive Msg where
  | host (h : Host)
  | tap

inductive Cmd where
  /-- hands the test the runtime's `Effects`, so it can queue host answers as a task would -/
  | keep
  | boom (why : String)
  | note (n : Nat)
  deriving ToJson

def update : Msg → Model → Model
  | .host (.answer n), m => { m with applied := m.applied ++ [n] }
  | .tap, m => { m with taps := m.taps + 1 }

/-- An odd answer asks for a command that throws, then one that does not. -/
def cmds : Msg → Model → List Cmd
  | .host (.answer n), _ => if n % 2 == 1 then [.boom s!"answer {n}", .note n] else [.note n]
  | .tap, _ => [.boom "tap", .note 100]

def view (m : Model) : Html Msg :=
  .col [.text s!"applied {m.applied} taps {m.taps}" .body, .button "Tap" .plain (some .tap)]

initialize failures : IO.Ref Nat ← IO.mkRef 0

def check (name : String) (ok : Bool) : IO Unit := do
  if ok then IO.println s!"ok   {name}" else IO.println s!"FAIL {name}"; failures.modify (· + 1)

def has (reply needle : String) : Bool := (reply.splitOn needle).length > 1

/-- A reply, or the exception the runtime let through (what the C shim turns into `{"error":"lean-io"}`). -/
def answered (act : IO String) : IO String := do
  try act catch e => pure s!"threw: {e}"

def run : IO Unit := do
  let fx ← IO.mkRef (none : Option (Effects Host))
  let noted ← IO.mkRef (#[] : Array Nat)
  let app : Native.App Model Msg Cmd Host :=
    { init := {}, update, view, cmds, host := Msg.host
      perform := fun c e => match c with
        | .keep => fx.set (some e)
        | .boom why => throw (IO.userError why)
        | .note n => noted.modify (·.push n)
      -- a boot command that throws, before the one the test needs
      boot := [.boom "boot", .keep]
      system := fun _ => some (.answer 7) }
  let rt ← Native.runtime app
  let started ← answered rt.start
  check "start answers the view although a boot command threw" (has started "applied [] taps 0")
  let some fx ← fx.get | check "the boot command after the one that threw ran" false
  check "the boot command after the one that threw ran" true
  -- three answers queued as tasks would queue them; the first one's command throws
  fx.post (.answer 1); fx.post (.answer 2); fx.post (.answer 4)
  let drained ← answered rt.drain
  check "drain answers the view with every queued answer applied" (has drained "applied [1, 2, 4] taps 0")
  check "the command after the one that threw ran, and the later answers' commands" ((← noted.get) == #[1, 2, 4])
  check "each answer was a step" ((← rt.current).1 == 3)
  -- nothing is left over, and nothing is applied twice
  check "a second drain applies nothing more" (has (← answered rt.drain) "applied [1, 2, 4] taps 0" && (← rt.current).1 == 3)
  -- a user event and a system event go through the same step
  let tapped ← answered (rt.event "{\"seq\":3,\"path\":[1],\"event\":{\"k\":\"click\"}}")
  check "an event whose command threw is answered with the view" (has tapped "applied [1, 2, 4] taps 1")
  let system ← answered (rt.system "{}")
  check "a system event whose command threw is answered with the view" (has system "applied [1, 2, 4, 7] taps 1")
  check "their other commands ran" ((← noted.get) == #[1, 2, 4, 100, 7])
  -- an answer in the middle of the queue, with answers on both sides of it
  fx.post (.answer 6); fx.post (.answer 9); fx.post (.answer 8)
  check "an answer queued behind a later failure is applied too" (has (← answered rt.drain) "applied [1, 2, 4, 7, 6, 9, 8] taps 1")
  check "and its command ran" ((← noted.get) == #[1, 2, 4, 100, 7, 6, 9, 8])

end LeanNativeTest.NativeRuntime

def main : IO UInt32 := do
  LeanNativeTest.NativeRuntime.run
  let n ← LeanNativeTest.NativeRuntime.failures.get
  IO.println (if n == 0 then "native-runtime: all passed" else s!"native-runtime: {n} failed")
  return if n == 0 then 0 else 1
