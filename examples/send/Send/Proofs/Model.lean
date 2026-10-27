import ElmLean.Proofs.Cmd
import Send.Proofs.Checks

/-! One-step facts: which messages produce which commands, how the screen can change, the invariant
(any draft on screen matches the form), and what the user-facing view can send. -/

namespace Send
open ElmLean

/-- The draft a screen shows, if any. -/
def Screen.draft? : Screen → Option Draft
  | .review d => some d
  | .signing d => some d
  | .broadcasting d _ => some d
  | .sent d _ => some d
  | _ => none

/-- THE INVARIANT: whatever draft is on screen matches the form (same inputs, the amount and address
typed). Winnow's `SendReviewInputs` discard rule, proven. -/
def Inv (m : Model) : Prop := ∀ d, m.screen.draft? = some d → matchesForm m.form d = true

theorem init_inv : Inv Model.init := by
  intro d h; simp [Model.init, Screen.draft?] at h

/-- A step that keeps the form and shows no draft the old screen did not show keeps `Inv`. -/
theorem inv_keep {m m' : Model} (h : Inv m) (hf : m'.form = m.form)
    (hs : ∀ d, m'.screen.draft? = some d → m.screen.draft? = some d) : Inv m' := by
  intro d hd; rw [hf]; exact h d (hs d hd)

/-- A step to a screen that shows no draft keeps `Inv`, whatever it does to the form. -/
theorem inv_none {m' : Model} (hs : m'.screen.draft? = none) : Inv m' := by
  intro d hd; rw [hs] at hd; cases hd

theorem edited_inv (m : Model) (f : Entry) (h : Inv m) : Inv (edited m f) := by
  unfold edited
  cases hs : m.screen
  case signing => exact h
  case broadcasting => exact h
  case sent => exact h
  all_goals exact inv_none rfl

theorem onHost_inv (hm : HostMsg) (m : Model) (h : Inv m) : Inv (onHost hm m) := by
  have keep : ∀ m', m'.form = m.form → (∀ d, m'.screen.draft? = some d → m.screen.draft? = some d) →
      Inv m' := fun _ hf hs => inv_keep h hf hs
  cases hm with
  | balance t => exact keep _ rfl (fun _ hd => hd)
  | previewReady d =>
    unfold onHost
    cases hs : m.screen
    case previewing id =>
      simp only
      split
      · split
        · rename_i hc
          intro d' hd'; simp only [Screen.draft?, Option.some.injEq] at hd'; subst hd'; exact hc
        · exact inv_none rfl
      · exact h
    all_goals exact h
  | previewFailed id r =>
    unfold onHost; cases hs : m.screen
    case previewing id' => simp only; split <;> first | exact inv_none rfl | exact h
    all_goals exact h
  | signed sg =>
    unfold onHost; cases hs : m.screen
    case signing d =>
      simp only
      split
      · split
        · exact keep _ rfl (fun d' hd' => by simp only [Screen.draft?] at hd' ⊢; rw [hs]; simpa [Screen.draft?] using hd')
        · exact inv_none rfl
      · exact h
    all_goals exact h
  | signFailed id r =>
    unfold onHost; cases hs : m.screen
    case signing d => simp only; split <;> first | exact inv_none rfl | exact h
    all_goals exact h
  | broadcasted id t =>
    unfold onHost; cases hs : m.screen
    case broadcasting d t' =>
      simp only; split
      · exact keep _ rfl (fun d' hd' => by rw [hs]; simpa [Screen.draft?] using hd')
      · exact h
    all_goals exact h
  | broadcastFailed id r =>
    unfold onHost; cases hs : m.screen
    case broadcasting d t' => simp only; split <;> first | exact inv_none rfl | exact h
    all_goals exact h

theorem update_inv (msg : Msg) (m : Model) (h : Inv m) : Inv (update msg m) := by
  cases msg with
  | setDestination s => exact edited_inv _ _ h
  | setAmount s => exact edited_inv _ _ h
  | setPriority p => exact edited_inv _ _ h
  | host hm => exact onHost_inv hm m h
  | review =>
    simp only [update]; cases hs : m.screen
    case form => simp only; split <;> first | exact inv_none rfl | exact h
    all_goals exact h
  | approve =>
    simp only [update]; cases hs : m.screen
    case review d => exact inv_keep h rfl (fun d' hd' => by rw [hs]; simpa [Screen.draft?] using hd')
    all_goals exact h
  | edit =>
    simp only [update]; cases hs : m.screen
    case review d => exact inv_none rfl
    case failed r => exact inv_none rfl
    all_goals exact h
  | restart =>
    simp only [update]; cases hs : m.screen
    case sent d t => exact inv_none rfl
    all_goals exact h

/-! ## Commands -/

/-- `sign d` is asked for by exactly one message in exactly one situation: "Send payment" on the
review screen of `d`. -/
theorem sign_mem (msg : Msg) (m : Model) (d : Draft) :
    Cmd.sign d ∈ cmds msg m ↔ msg = .approve ∧ m.screen = .review d := by
  constructor
  · intro hm
    unfold cmds at hm
    split at hm
    · split at hm <;> (try split at hm) <;> simp at hm
    · split at hm
      · rename_i d' hd; simp at hm; subst hm; exact ⟨rfl, hd⟩
      · simp at hm
    · split at hm <;> (try split at hm) <;> simp at hm
    · simp at hm
  · rintro ⟨rfl, h⟩; simp [cmds, h]

/-- `broadcast` is asked for only when the host reports a signed transaction for the draft being
signed and that transaction `authorizes` the draft; it carries exactly that transaction. -/
theorem broadcast_mem (msg : Msg) (m : Model) (id : Nat) (raw : String) :
    Cmd.broadcast id raw ∈ cmds msg m ↔
      ∃ s d, msg = .host (.signed s) ∧ m.screen = .signing d ∧ authorizes d s = true ∧
        id = d.id ∧ raw = s.raw := by
  constructor
  · intro hm
    unfold cmds at hm
    split at hm
    · split at hm <;> (try split at hm) <;> simp at hm
    · split at hm <;> simp at hm
    · rename_i s
      split at hm
      · rename_i d hd
        split at hm
        · rename_i hc; simp at hm; obtain ⟨rfl, rfl⟩ := hm; exact ⟨s, d, rfl, hd, hc.2, rfl, rfl⟩
        · simp at hm
      · simp at hm
    · simp at hm
  · rintro ⟨s, d, rfl, hd, ha, rfl, rfl⟩
    have hid := ((authorizes_iff _ _).1 ha).1
    simp [cmds, hd, hid, ha]

/-- The only way into the signing screen of `d`: "Send payment" on the review screen of `d`. -/
theorem signing_from (msg : Msg) (m : Model) (d : Draft) (h : (update msg m).screen = .signing d) :
    m.screen = .signing d ∨ (msg = .approve ∧ m.screen = .review d) := by
  cases msg with
  | setDestination s | setAmount s | setPriority s =>
    left; simp only [update, edited] at h; split at h <;> simp_all
  | review => left; simp only [update] at h; split at h <;> (try split at h) <;> simp_all
  | approve =>
    simp only [update] at h; split at h
    · rename_i d' hd; simp at h; subst h; exact .inr ⟨rfl, hd⟩
    · exact .inl h
  | edit => left; simp only [update] at h; split at h <;> simp_all
  | restart => left; simp only [update] at h; split at h <;> simp_all
  | host hm =>
    left; simp only [update, onHost] at h
    split at h <;> (try split at h) <;> (try split at h) <;> (try split at h) <;> simp_all

/-! ## The view -/

/-- What the user-facing view can send: never a host message, and "Send payment" only while a
draft is under review. -/
@[simp] def UiTarget (m : Model) : Msg → Prop
  | .host _ => False
  | .approve => ∃ d, m.screen = .review d
  | _ => True

theorem view_sat (m : Model) : Html.Sat (UiTarget m) (view m) := by
  have line_sat : ∀ l v, Html.Sat (UiTarget m) (line l v) := fun l v =>
    .row _ (by intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
               rcases hc with rfl | rfl | rfl <;> first | exact .text _ _ | exact .spacer)
  have summary_sat : ∀ d, Html.Sat (UiTarget m) (summary d) := fun d =>
    .col _ (by intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
               rcases hc with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
               all_goals first | exact .text _ _ | exact .spacer | exact .divider | exact line_sat _ _)
  have form_sat : ∀ w, Html.Sat (UiTarget m) (formView m w) := fun w =>
    .col _ (by
      intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
      rcases hc with rfl | rfl | rfl | rfl | rfl | rfl | rfl
      · exact .text _ _
      · exact .text _ _
      · exact .field _ _ _ _ (fun _ => trivial) (fun _ h => by cases h)
      · exact .field _ _ _ _ (fun _ => trivial) (fun _ h => by cases h)
      · refine .row _ ?_; intro c hc; simp only [priorityButton, List.mem_cons, List.not_mem_nil, or_false] at hc
        rcases hc with rfl | rfl | rfl <;> exact .button _ _ _ (fun _ h => by cases h; trivial)
      · exact .button _ _ _ (fun _ h => by split at h <;> cases h; trivial)
      · constructor)
  unfold view
  split
  · exact form_sat _
  · exact form_sat _
  · rename_i d hd
    refine .col _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl | rfl | rfl
    · exact .text _ _
    · exact summary_sat d
    · exact .text _ _
    · exact .button _ _ _ (fun _ h => by cases h; exact ⟨d, hd⟩)
    · exact .button _ _ _ (fun _ h => by cases h; trivial)
  · refine .col _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl
    all_goals first | exact .text _ _ | exact .spacer | exact .divider | exact summary_sat _
  · refine .col _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl | rfl
    all_goals first | exact .text _ _ | exact .spacer | exact .divider | exact summary_sat _ | exact line_sat _ _
  · refine .col _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl | rfl | rfl
    all_goals try (first | exact .text _ _ | exact .spacer | exact .divider | exact summary_sat _ | exact line_sat _ _)
    exact .button _ _ _ (fun _ h => by cases h; trivial)
  · refine .col _ ?_; intro c hc; simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl
    all_goals try (first | exact .text _ _ | exact .spacer | exact .divider)
    exact .button _ _ _ (fun _ h => by cases h; trivial)

/-- The app's `CmdSpec`. -/
def spec : CmdSpec app where
  Inv := Inv
  Target := UiTarget
  init_inv := init_inv
  update_inv := update_inv
  view_sat := fun m _ => view_sat m

end Send
