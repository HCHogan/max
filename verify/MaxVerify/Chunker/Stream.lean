import MaxVerify.Chunker.Model

/-!
# Streaming is invisible

`segment.rs` says: "The cuts depend only on the text, not on how it
arrived: streamed in any pieces, it gives the same chunks as all at once."
`streaming` proves it for the model, for every text and every way of
cutting it into pieces.

The proof doesn't look inside `State.line`: `Chunker.push` hands it whole
lines only, and the same lines whichever way the text arrives. So it holds
for any rules about what a line does, and goes on holding as they change.
It is the same as feeding the text one character at a time (`step`), and
`drain_eq` is the heart of it.
-/

namespace MaxVerify.Chunker

/-- One character: a newline completes the line. -/
def step (acc : Chunker × List Text) (ch : Char) : Chunker × List Text :=
  if ch = '\n' then
    let (st, o) := acc.1.st.line (trimNewline (acc.1.rest ++ ['\n']))
    ({ rest := [], st }, acc.2 ++ o)
  else ({ acc.1 with rest := acc.1.rest ++ [ch] }, acc.2)

/-- Chunks already out stay in front. -/
theorem foldl_step_out (d : Text) (c : Chunker) (out : List Text) :
    d.foldl step (c, out) = ((d.foldl step (c, [])).1, out ++ (d.foldl step (c, [])).2) := by
  induction d generalizing c out with
  | nil => simp
  | cons ch d ih =>
    simp only [List.foldl_cons]
    by_cases h : ch = '\n'
    · simp only [step, h, ite_true]
      rw [ih _ (out ++ _), ih _ ([] ++ _)]
      simp
    · simp only [step, h, ite_false]
      rw [ih _ out, ih _ []]

theorem splitLine_none {p : Text} (h : '\n' ∉ p) : splitLine p = none := by
  induction p with
  | nil => rfl
  | cons c t ih =>
    simp only [List.mem_cons, not_or] at h
    simp [splitLine, Ne.symm h.1, ih h.2]

theorem splitLine_newline {p : Text} (r : Text) (h : '\n' ∉ p) :
    splitLine (p ++ '\n' :: r) = some (p, r) := by
  induction p with
  | nil => simp [splitLine]
  | cons c t ih =>
    simp only [List.mem_cons, not_or] at h
    simp [splitLine, Ne.symm h.1, ih h.2]

/-- `drain` on what was left plus a new piece is that piece fed a character
at a time. -/
theorem drain_eq (d : Text) (st : State) (p : Text) (h : '\n' ∉ p) :
    drain st (p ++ d) =
      ((d.foldl step ({ rest := p, st }, [])).1.st,
        (d.foldl step ({ rest := p, st }, [])).2,
        (d.foldl step ({ rest := p, st }, [])).1.rest) := by
  induction d generalizing st p with
  | nil =>
    simp only [List.append_nil, List.foldl_nil]
    rw [drain, splitLine_none h]
  | cons ch d ih =>
    by_cases hc : ch = '\n'
    · subst hc
      rw [drain, splitLine_newline d h]
      simp only [List.foldl_cons, step, ite_true]
      have := ih (st.line (trimNewline (p ++ ['\n']))).1 [] (by simp)
      simp only [List.nil_append] at this
      rw [this, foldl_step_out d _ (([] : List Text) ++ _)]
      simp
    · have h' : '\n' ∉ p ++ [ch] := by simp [h, Ne.symm hc]
      have := ih st (p ++ [ch]) h'
      simp only [List.append_assoc, List.cons_append, List.nil_append] at this
      rw [this]
      simp [step, hc]

/-- Text after the last newline has no newline. -/
def Settled (acc : Chunker × List Text) : Prop := '\n' ∉ acc.1.rest

theorem step_settled (acc : Chunker × List Text) (ch : Char) (h : Settled acc) :
    Settled (step acc ch) := by
  unfold Settled at *
  by_cases hc : ch = '\n'
  · simp [step, hc]
  · simp [step, hc, h, Ne.symm hc]

theorem foldl_settled (d : Text) (acc : Chunker × List Text) (h : Settled acc) :
    Settled (d.foldl step acc) := by
  induction d generalizing acc with
  | nil => simpa
  | cons ch d ih => exact ih _ (step_settled acc ch h)

theorem pushAll_eq (acc : Chunker × List Text) (d : Text) (h : Settled acc) :
    pushAll acc d = d.foldl step acc := by
  obtain ⟨c, out⟩ := acc
  rw [foldl_step_out d c out]
  simp only [pushAll, Chunker.push]
  rw [drain_eq d c.st c.rest h]

theorem foldl_pushAll (pieces : List Text) (acc : Chunker × List Text) (h : Settled acc) :
    pieces.foldl pushAll acc = pieces.flatten.foldl step acc := by
  induction pieces generalizing acc with
  | nil => simp
  | cons d ds ih =>
    simp only [List.foldl_cons, List.flatten_cons, List.foldl_append]
    rw [pushAll_eq acc d h]
    exact ih _ (foldl_settled d acc h)

/-- Streamed in any pieces, a text gives the same chunks as all at once. -/
theorem streaming (pieces : List Text) : chunks pieces = chunks [pieces.flatten] := by
  have h : Settled (({} : Chunker), ([] : List Text)) := by simp [Settled]
  simp only [chunks]
  rw [foldl_pushAll pieces _ h, foldl_pushAll [pieces.flatten] _ h]
  simp

end MaxVerify.Chunker
