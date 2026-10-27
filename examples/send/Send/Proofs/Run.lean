import Send.Proofs.Model
import Std.Data.String.ToNat

/-! # What you approve is what gets signed, over every run

The theorems quantify over every input trace `is`: any interleaving of user events (in sync or
stale, advertised or not) and arbitrary host answers, including answers about other drafts, repeated
answers and answers that lie. `app.traceFrom is` lists the steps; position `k` is the session the
first `k` inputs reached, the `k`-th input, and the commands that step asked the host to run. -/

namespace Send
open ElmLean

/-- The review screen of `d` shows the draft: where the money goes, the amount, the fee and the
total, each as its own text node. -/
theorem reviewView_shows (d : Draft) :
    (reviewView d).at? [1, 1] = some (.text d.destination .body) ∧
    (reviewView d).at? [1, 2, 2] = some (.text (sats d.amount) .body) ∧
    (reviewView d).at? [1, 3, 2] = some (.text (sats d.fee) .body) ∧
    (reviewView d).at? [1, 4, 2] = some (.text (sats (d.amount + d.fee)) .body) := by
  simp [reviewView, summary, line, Html.at?, Html.children]

/-- The amount text determines the amount: two different numbers of sats never look the same. -/
theorem sats_inj {a b : Nat} (h : sats a = sats b) : a = b := by
  unfold sats at h
  have h' : toString a = toString b := by
    have := congrArg String.toList h
    simp only [String.toList_append] at this
    exact String.toList_inj.1 (List.append_cancel_right this)
  exact Nat.repr_inj.1 h'

/-- The "Send payment" button of the review screen is the one control that approves. -/
theorem reviewView_approve (d : Draft) : (reviewView d).dispatch [3] .click = some .approve := by
  simp [reviewView, Html.dispatch, Html.at?, Html.children, Html.handle]

/-- EVERY SIGNING REQUEST IS AN APPROVAL OF WHAT WAS ON SCREEN. If any step of any run asks the host
to sign draft `d`, that step is the user's in-sync event on the review screen of exactly `d`
(`reviewView d`, the view the client was shown), the event is the "Send payment" control, and `d`
matches the form: the amount and address on screen are the ones the user typed. -/
theorem sign_approved (is : List (Input HostMsg)) (k : Nat) (st : Step Model Msg Cmd HostMsg)
    (hk : (app.traceFrom is)[k]? = some st) (d : Draft) (hs : Cmd.sign d ∈ st.cmds) :
    st.before = app.reach (is.take k) ∧
    ∃ r, st.input = .event r ∧ r.seq = st.before.seq ∧
      st.before.lastView = reviewView d ∧
      st.before.lastView.dispatch r.path r.event = some .approve ∧
      st.before.model.screen = .review d ∧
      matchesForm st.before.model.form d = true := by
  obtain ⟨hb, hc, hinv, hcm⟩ := spec.trace_origin is k st hk
  refine ⟨hb, ?_⟩
  rcases hcm with he | ⟨msg, hcmds, horig⟩
  · rw [he] at hs; cases hs
  rw [hcmds] at hs
  obtain ⟨rfl, hscr⟩ := (sign_mem _ _ _).1 hs
  rcases horig with ⟨r, hin, ha, _⟩ | ⟨h, _, hm⟩
  · refine ⟨r, hin, ?_, ?_, ?_, hscr, hinv d (by simp [hscr, Screen.draft?])⟩
    · unfold Session.accept at ha; split at ha
      · assumption
      · cases ha
    · rw [hc]; show view st.before.model = _; simp [view, hscr]
    · unfold Session.accept at ha; split at ha
      · exact ha
      · cases ha
  · cases hm

/-- The signing screen of `d` is reached only through a step that asked to sign `d`. -/
theorem signing_has_sign (is : List (Input HostMsg)) :
    ∀ k d, (app.reach (is.take k)).model.screen = .signing d →
      ∃ k' < k, ∃ st, (app.traceFrom is)[k']? = some st ∧ Cmd.sign d ∈ st.cmds := by
  intro k
  induction k with
  | zero => intro d h; simp [CmdApp.reach, Session.runC, Session.start, app, Model.init] at h
  | succ k ih =>
    intro d h
    cases hi : is[k]? with
    | none =>
      have : is.take (k + 1) = is.take k := by
        rw [List.take_add_one, hi]; simp
      rw [this] at h
      obtain ⟨k', hk', rest⟩ := ih d h
      exact ⟨k', by omega, rest⟩
    | some i =>
      have hstep := Session.runC_take_succ app (Session.start app.toApp) is k i hi
      unfold CmdApp.reach at h
      rw [hstep] at h
      have htr : (app.traceFrom is)[k]? = some ⟨app.reach (is.take k), i,
          ((app.reach (is.take k)).step app i).2.2⟩ := by
        unfold CmdApp.traceFrom; rw [Session.trace_getElem?, hi]; rfl
      rcases Session.step_origin app (app.reach (is.take k)) i with ⟨e, _⟩ | ⟨msg, e, ec, _⟩
      · unfold CmdApp.reach at e; rw [e] at h
        obtain ⟨k', hk', rest⟩ := ih d h
        exact ⟨k', by omega, rest⟩
      · unfold CmdApp.reach at e; rw [e] at h
        rcases signing_from msg _ d h with h' | ⟨rfl, hr⟩
        · obtain ⟨k', hk', rest⟩ := ih d h'
          exact ⟨k', by omega, rest⟩
        · refine ⟨k, by omega, _, htr, ?_⟩
          show Cmd.sign d ∈ ((app.reach (is.take k)).step app i).2.2
          rw [ec]; exact (sign_mem _ _ _).2 ⟨rfl, hr⟩

/-- EVERY BROADCAST IS OF A TRANSACTION THAT MATCHES AN APPROVED REVIEW. If any step of any run asks
the host to broadcast `raw`, then that step is the host's report `signed s` of exactly `raw`, `s`
`authorizes` a draft `d` (same fee, change, coins, and exactly `d`'s outputs: see
`authorizes_iff`), and an EARLIER step of the same run was the user's "Send payment" on the review
screen of that very `d`, a review whose amount and address are the ones the user typed. -/
theorem broadcast_approved (is : List (Input HostMsg)) (k : Nat) (st : Step Model Msg Cmd HostMsg)
    (hk : (app.traceFrom is)[k]? = some st) (id : Nat) (raw : String)
    (hb : Cmd.broadcast id raw ∈ st.cmds) :
    ∃ s d, st.input = .host (.signed s) ∧ raw = s.raw ∧ authorizes d s = true ∧ id = d.id ∧
      ∃ k' < k, ∃ st', (app.traceFrom is)[k']? = some st' ∧
        ∃ r, st'.input = .event r ∧ r.seq = st'.before.seq ∧
          st'.before.lastView = reviewView d ∧
          st'.before.lastView.dispatch r.path r.event = some .approve ∧
          matchesForm st'.before.model.form d = true := by
  obtain ⟨hbefore, _, _, hcm⟩ := spec.trace_origin is k st hk
  rcases hcm with he | ⟨msg, hcmds, horig⟩
  · rw [he] at hb; cases hb
  rw [hcmds] at hb
  obtain ⟨s, d, rfl, hscr, ha, rfl, rfl⟩ := (broadcast_mem _ _ _ _).1 hb
  have hin : st.input = .host (.signed s) := by
    rcases horig with ⟨r, _, _, ht⟩ | ⟨h, hi, hm⟩
    · simp [spec] at ht
    · cases hm; exact hi
  rw [hbefore] at hscr
  obtain ⟨k', hk', st', hst', hsign⟩ := signing_has_sign is k d hscr
  obtain ⟨_, r, hr, hseq, hview, hdisp, _, hmatch⟩ := sign_approved is k' st' hst' d hsign
  exact ⟨s, d, hin, rfl, ha, rfl, k', hk', st', hst', r, hr, hseq, hview, hdisp, hmatch⟩

end Send
