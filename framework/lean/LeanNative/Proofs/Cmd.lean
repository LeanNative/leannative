import LeanNative.Cmd
import LeanNative.Spec
import LeanNative.Proofs.Program
import LeanNative.Proofs.Spec

/-! # Theorems about sessions with commands

For any `CmdApp`, whatever the interleaving of user events and host answers:

* every step either leaves the session alone and asks for nothing, or runs `update` on exactly one
  message and asks for exactly `cmds` of that message in the pre-state, and that message is either
  dispatched by an in-sync control of the view the client is looking at, or `app.host h` for the
  host's answer `h` (`Session.step_origin`);
* the session keeps showing the view of its model, and any invariant `update` preserves holds
  (`Session.runC_coherent`, `Session.runC_inv`);
* the trace of a run records, at position `k`, the session reached by the first `k` inputs
  (`Session.trace_before`), which is how an app proves a property about the history of a run. -/

namespace LeanNative

variable {Model Msg Cmd Host : Type}

theorem Session.handle_accept (app : App Model Msg) (s : Session Model Msg) (r : Request) :
    (s.handle app r).1 = match s.accept r with
      | some msg => s.apply app msg
      | none => s := by
  unfold Session.handle Session.accept Html.dispatch Session.apply
  by_cases h : r.seq = s.seq
  · simp only [h, ne_eq, not_true_eq_false, ite_false, ite_true]
    cases ha : s.lastView.at? r.path with
    | none => simp
    | some n =>
      cases hn : n.handle r.event with
      | none => simp [hn]
      | some m => simp [hn]
  · simp [h]

/-- Where every message comes from. -/
theorem Session.step_origin (app : CmdApp Model Msg Cmd Host) (s : Session Model Msg) (i : Input Host) :
    ((s.step app i).1 = s ∧ (s.step app i).2.2 = []) ∨
    ∃ msg, (s.step app i).1 = s.apply app.toApp msg ∧ (s.step app i).2.2 = app.cmds msg s.model ∧
      ((∃ r, i = .event r ∧ s.accept r = some msg) ∨ (∃ h, i = .host h ∧ msg = app.host h)) := by
  cases i with
  | event r =>
    have hh := Session.handle_accept app.toApp s r
    simp only [Session.step]
    cases ha : s.accept r with
    | none => left; simp_all
    | some msg => right; exact ⟨msg, by simp_all, rfl, .inl ⟨r, rfl, ha⟩⟩
  | host h => right; exact ⟨app.host h, rfl, rfl, .inr ⟨h, rfl, rfl⟩⟩

theorem Session.apply_coherent (app : App Model Msg) (s : Session Model Msg) (msg : Msg) :
    (s.apply app msg).Coherent app := rfl

theorem Session.step_coherent {app : CmdApp Model Msg Cmd Host} {s : Session Model Msg}
    (h : s.Coherent app.toApp) (i : Input Host) : (s.step app i).1.Coherent app.toApp := by
  rcases Session.step_origin app s i with ⟨e, _⟩ | ⟨msg, e, _⟩ <;> rw [e]
  · exact h
  · exact Session.apply_coherent _ _ _

theorem Session.runC_coherent (app : CmdApp Model Msg Cmd Host) {s : Session Model Msg}
    (h : s.Coherent app.toApp) : ∀ is, (s.runC app is).Coherent app.toApp := by
  intro is
  induction is generalizing s with
  | nil => exact h
  | cons i is ih => exact ih (Session.step_coherent h i)

theorem Session.step_inv (app : CmdApp Model Msg Cmd Host) (I : Model → Prop)
    (hI : ∀ msg m, I m → I (app.update msg m)) {s : Session Model Msg} (h : I s.model) (i : Input Host) :
    I (s.step app i).1.model := by
  rcases Session.step_origin app s i with ⟨e, _⟩ | ⟨msg, e, _⟩ <;> rw [e]
  · exact h
  · exact hI msg s.model h

theorem Session.runC_inv (app : CmdApp Model Msg Cmd Host) (I : Model → Prop)
    (hI : ∀ msg m, I m → I (app.update msg m)) {s : Session Model Msg} (h : I s.model) :
    ∀ is, I (s.runC app is).model := by
  intro is
  induction is generalizing s with
  | nil => exact h
  | cons i is ih => exact ih (Session.step_inv app I hI h i)

/-- An accepted request, on a coherent session whose view satisfies `Sat P`, yields a message
satisfying `P`. -/
theorem Session.accept_sat {app : App Model Msg} {s : Session Model Msg} {P : Msg → Prop}
    (hc : s.Coherent app) (hs : Html.Sat P (app.view s.model)) {r : Request} {msg : Msg}
    (ha : s.accept r = some msg) : P msg := by
  unfold Session.accept at ha
  split at ha
  · rw [Session.Coherent] at hc; rw [hc] at ha
    exact Html.Sat.dispatch r.path _ hs r.event msg ha
  · simp at ha

theorem Session.trace_length (app : CmdApp Model Msg Cmd Host) :
    ∀ (s : Session Model Msg) (is : List (Input Host)), (s.trace app is).length = is.length
  | _, [] => rfl
  | s, _ :: is => by simp [Session.trace, Session.trace_length app _ is]

/-- Position `k` of a trace is the `k`-th input, met by the session the first `k` inputs reached,
with the commands that step produced. -/
theorem Session.trace_get (app : CmdApp Model Msg Cmd Host) :
    ∀ (s : Session Model Msg) (is : List (Input Host)) (k : Nat) (st : Step Model Msg Cmd Host),
      (s.trace app is)[k]? = some st →
      ∃ i, is[k]? = some i ∧ st.input = i ∧ st.before = s.runC app (is.take k) ∧
        st.cmds = (st.before.step app i).2.2
  | _, [], _, _, h => by simp [Session.trace] at h
  | s, i :: is, 0, st, h => by
    simp only [Session.trace, List.getElem?_cons_zero, Option.some.injEq] at h
    subst h
    exact ⟨i, rfl, rfl, rfl, rfl⟩
  | s, i :: is, k + 1, st, h => by
    simp only [Session.trace, List.getElem?_cons_succ] at h
    obtain ⟨i', hi, h1, h2, h3⟩ := Session.trace_get app _ is k st h
    exact ⟨i', by simpa using hi, h1, by simpa [Session.runC] using h2, h3⟩

/-- The trace, position by position. -/
theorem Session.trace_getElem? (app : CmdApp Model Msg Cmd Host) :
    ∀ (s : Session Model Msg) (is : List (Input Host)) (k : Nat),
      (s.trace app is)[k]? = is[k]?.map (fun i =>
        ⟨s.runC app (is.take k), i, ((s.runC app (is.take k)).step app i).2.2⟩)
  | _, [], _ => by simp [Session.trace]
  | s, i :: is, 0 => by simp [Session.trace, Session.runC]
  | s, i :: is, k + 1 => by
    simp only [Session.trace, List.getElem?_cons_succ, List.take_succ_cons, Session.runC]
    exact Session.trace_getElem? app _ is k

/-- The session the first `k + 1` inputs reach is the step of the `k`-th input from the session the
first `k` reached. -/
theorem Session.runC_take_succ (app : CmdApp Model Msg Cmd Host) :
    ∀ (s : Session Model Msg) (is : List (Input Host)) (k : Nat) (i : Input Host), is[k]? = some i →
      s.runC app (is.take (k + 1)) = ((s.runC app (is.take k)).step app i).1
  | _, [], _, _, h => by simp at h
  | s, j :: is, 0, i, h => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h; rfl
  | s, j :: is, k + 1, i, h => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.take_succ_cons, Session.runC]
    exact Session.runC_take_succ app _ is k i h

/-! ## A `Spec` for an app with commands -/

/-- What an app author proves about a `CmdApp`, as for `Spec`: `Inv` holds initially and is
preserved by every message (user or host), and every handler of the view in a model satisfying
`Inv` yields a message satisfying `Target m`. -/
structure CmdSpec (app : CmdApp Model Msg Cmd Host) where
  Inv : Model → Prop
  Target : Model → Msg → Prop
  init_inv : Inv app.init
  update_inv : ∀ msg m, Inv m → Inv (app.update msg m)
  view_sat : ∀ m, Inv m → Html.Sat (Target m) (app.view m)

/-- The session reached by an input trace from a fresh start. -/
def CmdApp.reach (app : CmdApp Model Msg Cmd Host) (is : List (Input Host)) : Session Model Msg :=
  (Session.start app.toApp).runC app is

theorem CmdApp.reach_coherent (app : CmdApp Model Msg Cmd Host) (is : List (Input Host)) :
    (app.reach is).Coherent app.toApp :=
  Session.runC_coherent app (Session.start_coherent app.toApp) is

namespace CmdSpec

variable {app : CmdApp Model Msg Cmd Host} (S : CmdSpec app)

theorem reachable_inv (is : List (Input Host)) : S.Inv (app.reach is).model :=
  Session.runC_inv app S.Inv S.update_inv S.init_inv is

/-- THE ORIGIN OF EVERY MESSAGE, over any run: the step at position `k` of the trace either changes
nothing, or runs `update` on one message, asks for `cmds` of that message, and that message is
either `Target`-sound for the model the user was looking at (a dispatched, in-sync control of the
view shown) or the host's answer `app.host h`. -/
theorem trace_origin (is : List (Input Host)) (k : Nat) (st : Step Model Msg Cmd Host)
    (h : (app.traceFrom is)[k]? = some st) :
    st.before = app.reach (is.take k) ∧ st.before.Coherent app.toApp ∧ S.Inv st.before.model ∧
    (st.cmds = [] ∨ ∃ msg, st.cmds = app.cmds msg st.before.model ∧
      ((∃ r, st.input = .event r ∧ st.before.accept r = some msg ∧ S.Target st.before.model msg) ∨
       (∃ h, st.input = .host h ∧ msg = app.host h))) := by
  obtain ⟨i, _, hin, hb, hc⟩ := Session.trace_get app _ is k st h
  have hb' : st.before = app.reach (is.take k) := hb
  have hcoh : st.before.Coherent app.toApp := hb' ▸ app.reach_coherent _
  have hinv : S.Inv st.before.model := hb' ▸ S.reachable_inv _
  refine ⟨hb', hcoh, hinv, ?_⟩
  rcases Session.step_origin app st.before i with ⟨_, e⟩ | ⟨msg, _, e, o⟩
  · exact .inl (hc.trans e)
  · refine .inr ⟨msg, hc.trans e, ?_⟩
    rcases o with ⟨r, hr, ha⟩ | ⟨hh, hr, hm⟩
    · exact .inl ⟨r, hin.trans hr, ha, Session.accept_sat hcoh (S.view_sat _ hinv) ha⟩
    · exact .inr ⟨hh, hin.trans hr, hm⟩

end CmdSpec
end LeanNative
