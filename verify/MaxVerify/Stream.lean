import MaxCore.Funs

/-!
# Streaming is invisible

`segment.rs` says: "The cuts depend only on the text, not on how it
arrived: streamed in any pieces, it gives the same chunks as all at once."
`streaming` proves it of max-core's chunker as Aeneas translates it: a text
pushed in pieces is the same computation as the whole text pushed at once,
down to how it fails, if it does.

The proof doesn't look inside `Chunker.line`: `push` is a loop over the
bytes that hands each line to it as its newline comes, so the pieces don't
matter. The theorem is about one `out` that every push appends to; the
`&str` wrapper in `segment.rs` gives each push a new one, which
`Appends.lean` proves comes to the same.
-/

open Aeneas Aeneas.Std Result ControlFlow
open max_core segment.chunk

namespace MaxVerify

abbrev Out := alloc.vec.Vec (alloc.vec.Vec Std.U8)

/-- `out.extend_from_slice(&chunks)`. -/
abbrev extend (out chunks : Out) : Result Out :=
  alloc.vec.Vec.extend_from_slice (core.clone.CloneallocvecVec core.clone.CloneU8) out
    (alloc.vec.Vec.deref chunks)

/-- One byte: a newline completes the line. -/
def step (c : Chunker) (out : Out) (b : Std.U8) : Result (Chunker × Out) :=
  if b = 10#u8 then do
    let (line, c) ← Chunker.take_line c
    let (chunks, c) ← Chunker.line c (alloc.vec.Vec.deref line)
    let out ← extend out chunks
    ok (c, out)
  else do
    let v ← alloc.vec.Vec.push c.partial b
    ok ({ c with «partial» := v }, out)

/-- Bytes one at a time. -/
def steps (c : Chunker) (out : Out) : List Std.U8 → Result (Chunker × Out)
  | [] => ok (c, out)
  | b :: bs => do
    let (c, out) ← step c out b
    steps c out bs

theorem steps_append (c : Chunker) (out : Out) (l₁ l₂ : List Std.U8) :
    steps c out (l₁ ++ l₂) = (do let (c, out) ← steps c out l₁; steps c out l₂) := by
  induction l₁ generalizing c out with
  | nil => simp [steps]
  | cons b bs ih =>
    simp only [steps, Std.bind_assoc]
    refine congrArg (Bind.bind (step c out b)) (funext fun x => ?_)
    obtain ⟨c, out⟩ := x
    exact ih c out

theorem succ_ok (i : Std.Usize) (h : i.val < Std.Usize.max) :
    ∃ j : Std.Usize, i + 1#usize = ok j ∧ j.val = i.val + 1 := by
  have h' := @UScalar.add_equiv .Usize i (1#usize)
  split at h'
  next j heq =>
    obtain ⟨_, hval, _⟩ := h'
    exact ⟨j, by simpa using heq, by scalar_tac⟩
  next heq =>
    exfalso; scalar_tac
  next => simp at h'

theorem push_loop_unfold (c : Chunker) (d : Slice Std.U8) (out : Out) (i : Std.Usize) :
    Chunker.push_loop c d out i = (do
      let r ← Chunker.push_loop.body d c out i
      match r with
      | .cont (c, out, i) => Chunker.push_loop c d out i
      | .done x => ok x) := by
  unfold Chunker.push_loop
  rw [loop]
  refine congrArg (Bind.bind (m := Result) _) (funext fun r => ?_)
  rcases r with ⟨c, out, i⟩ | x
  · rfl
  · rfl

/-- `push`'s loop from byte `i` on. -/
theorem push_loop_eq (c : Chunker) (d : Slice Std.U8) (out : Out) (i : Std.Usize) :
    Chunker.push_loop c d out i = steps c out (d.val.drop i.val) := by
  rw [push_loop_unfold]
  unfold Chunker.push_loop.body
  by_cases hi : i < Slice.len d
  · have hlt : i.val < d.val.length := by scalar_tac
    obtain ⟨j, hj, hjv⟩ := succ_ok i (by scalar_tac)
    have hidx : Slice.index_usize d i = ok d.val[i.val] := by
      simp [Slice.index_usize, Slice.getElem?_Usize_eq, hlt]
    rw [List.drop_eq_getElem_cons hlt]
    simp only [hi, ite_true, hidx, hj, bind_ok, Std.bind_assoc, steps, step]
    refine congrArg (Bind.bind (m := Result) _) (funext fun x => ?_)
    obtain ⟨c', out'⟩ := x
    simp only [uncurry_apply_pair, bind_ok]
    rw [push_loop_eq c' d out' j, hjv]
  · have hge : d.val.length ≤ i.val := by scalar_tac
    simp [hi, List.drop_eq_nil_of_le hge, steps]
termination_by d.val.length - i.val
decreasing_by scalar_tac

theorem push_eq (c : Chunker) (d : Slice Std.U8) (out : Out) :
    Chunker.push c d out = steps c out d.val := by
  simp [Chunker.push, push_loop_eq]

/-- The pieces of a text, pushed one after another. -/
def pushAll (c : Chunker) (out : Out) : List (Slice Std.U8) → Result (Chunker × Out)
  | [] => ok (c, out)
  | d :: ds => do
    let (c, out) ← Chunker.push c d out
    pushAll c out ds

theorem pushAll_eq (c : Chunker) (out : Out) (pieces : List (Slice Std.U8)) :
    pushAll c out pieces = steps c out (pieces.map Slice.val).flatten := by
  induction pieces generalizing c out with
  | nil => simp [pushAll, steps]
  | cons d ds ih =>
    simp only [pushAll, push_eq, List.map_cons, List.flatten_cons, steps_append]
    refine congrArg (Bind.bind (steps c out d.val)) (funext fun x => ?_)
    obtain ⟨c, out⟩ := x
    exact ih c out

/-- The chunks of a text that arrives in `pieces`. -/
def chunks (pieces : List (Slice Std.U8)) : Result Out := do
  let c ← Chunker.Insts.CoreDefaultDefault.default
  let (c, out) ← pushAll c (alloc.vec.Vec.new _) pieces
  let (_, out) ← Chunker.finish c out
  ok out

/-- A text pushed in pieces is the same computation as the whole text
pushed at once, from any state of the chunker. -/
theorem streaming (pieces : List (Slice Std.U8)) (text : Slice Std.U8)
    (h : text.val = (pieces.map Slice.val).flatten) (c : Chunker) (out : Out) :
    pushAll c out pieces = Chunker.push c text out := by
  rw [pushAll_eq, push_eq, h]

theorem chunks_streaming (pieces : List (Slice Std.U8)) (text : Slice Std.U8)
    (h : text.val = (pieces.map Slice.val).flatten) :
    chunks pieces = chunks [text] := by
  have one : ∀ c out, pushAll c out [text] = Chunker.push c text out := by
    intro c out
    simp only [pushAll]
    refine (congrArg (Bind.bind (m := Result) _) (funext fun x => ?_)).trans (Std.bind_pure _)
    obtain ⟨c, out⟩ := x
    rfl
  simp only [chunks, streaming pieces text h, one]

end MaxVerify
