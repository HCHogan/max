import MaxVerify.Stream

/-!
# The chunker only appends to `out`

`push` and `finish` copy the chunks each line completes into the caller's
`out`, and touch it in no other way. So `Appends`: given any `out`, they
do what they do given an empty one, and `out` ends up with what it had and
then what the empty one got.

With it, `wrapper_streaming` proves streaming for the chunker as the `&str`
`Chunker` in `segment.rs` drives it: each push with a new `out`, `finish`
with another, the chunks of all of them one after another.
-/

open Aeneas Aeneas.Std Result ControlFlow
open max_core segment.chunk

namespace MaxVerify

abbrev empty : Out := alloc.vec.Vec.new _

theorem ok_inj {α : Type} {a b : α} : (ok a : Result α) = ok b ↔ a = b :=
  ⟨fun h => Result.ok_injective h, fun h => h ▸ rfl⟩

theorem bind_eq_ok {α β : Type} {m : Result α} {k : α → Result β} {b : β} :
    Std.bind m k = ok b ↔ ∃ a, m = ok a ∧ k a = ok b := by
  cases m with
  | ret a => simp
  | vis i k' => simp
  | div => simp

theorem uncurry_eq {α β γ : Type} (f : α → β → γ) (p : α × β) : uncurry f p = f p.1 p.2 := by
  cases p; rfl

/-! ## Copying chunks -/

theorem list_clone_ok {α : Type} (clone : α → Result α) (h : ∀ x, clone x = ok x) (l : List α) :
    List.clone clone l = ok ⟨l, rfl⟩ := by
  induction l with
  | nil => rfl
  | cons a rest ih =>
    simp only [List.clone] at ih ⊢
    rw [List.mapM_with_length, ih]
    simp [h, pure]

theorem clone_vec_ok (v : alloc.vec.Vec Std.U8) :
    (core.clone.CloneallocvecVec core.clone.CloneU8).clone v = ok v := by
  simp only [alloc.vec.CloneVec.clone, Slice.clone]
  rw [list_clone_ok _ (fun _ => rfl)]
  simp

theorem extend_eq_ok (out chunks out' : Out) :
    extend out chunks = ok out' ↔ out'.val = out.val ++ chunks.val := by
  simp only [extend, alloc.vec.Vec.extend_from_slice]
  split
  · rw [list_clone_ok _ clone_vec_ok]
    simp [alloc.vec.Vec.eq_iff, alloc.vec.Vec.deref, eq_comm]
  · rename_i h
    simp only [Result.fail_eq_vis, vis_not_ok, false_iff]
    intro h'
    apply h
    have := out'.property
    rw [h'] at this
    simpa [alloc.vec.Vec.deref] using this

/-! ## Appending -/

/-- `f` only appends to the `out` it is given. -/
def Appends {α : Type} (f : Out → Result (α × Out)) : Prop :=
  ∀ (out : Out) (a : α) (out' : Out),
    f out = ok (a, out') ↔ ∃ o : Out, f empty = ok (a, o) ∧ out'.val = out.val ++ o.val

theorem appends_pure {α : Type} (a : α) : Appends (fun out => ok (a, out)) := by
  intro out a' out'
  simp only [ok_inj, Prod.mk.injEq]
  constructor
  · rintro ⟨rfl, rfl⟩
    exact ⟨empty, ⟨rfl, rfl⟩, by simp⟩
  · rintro ⟨o, ⟨rfl, rfl⟩, h⟩
    exact ⟨rfl, alloc.vec.Vec.ext _ _ (by simpa using h.symm)⟩

theorem appends_extend {α : Type} (a : α) (chunks : Out) :
    Appends (fun out => do let out ← extend out chunks; ok (a, out)) := by
  intro out a' out'
  simp only [bind_eq_ok, extend_eq_ok, ok_inj, Prod.mk.injEq]
  constructor
  · rintro ⟨o, ho, rfl, rfl⟩
    exact ⟨chunks, ⟨chunks, by simp, rfl, rfl⟩, ho⟩
  · rintro ⟨o, ⟨o', ho', rfl, rfl⟩, h⟩
    exact ⟨out', by simp_all, rfl, rfl⟩

/-- What comes before `out` is touched doesn't matter. -/
theorem appends_prefix {α γ : Type} (m : Result γ) {f : γ → Out → Result (α × Out)}
    (hf : ∀ x, Appends (f x)) : Appends (fun out => do let x ← m; f x out) := by
  intro out a out'
  simp only [bind_eq_ok]
  constructor
  · rintro ⟨x, hm, hx⟩
    obtain ⟨o, ho, h⟩ := (hf x out a out').mp hx
    exact ⟨o, ⟨x, hm, ho⟩, h⟩
  · rintro ⟨o, ⟨x, hm, ho⟩, h⟩
    exact ⟨x, hm, (hf x out a out').mpr ⟨o, ho, h⟩⟩

theorem appends_bind {α β : Type} {g : Out → Result (α × Out)} {h : α → Out → Result (β × Out)}
    (hg : Appends g) (hh : ∀ a, Appends (h a)) :
    Appends (fun out => do let (a, out) ← g out; h a out) := by
  intro out b out''
  simp only [bind_eq_ok, uncurry_eq]
  constructor
  · rintro ⟨⟨a, out₁⟩, hg₁, hh₁⟩
    obtain ⟨o₁, hg₀, h₁⟩ := (hg out a out₁).mp hg₁
    obtain ⟨o₂, hh₀, h₂⟩ := (hh a out₁ b out'').mp hh₁
    have hb : (o₁.val ++ o₂.val).length ≤ Usize.max := by
      have := out''.property
      simp only [h₂, h₁, List.length_append] at this ⊢
      omega
    refine ⟨alloc.vec.Vec.from (o₁.val ++ o₂.val) hb, ⟨(a, o₁), hg₀, ?_⟩, ?_⟩
    · exact (hh a o₁ b _).mpr ⟨o₂, hh₀, by simp⟩
    · simp [h₂, h₁]
  · rintro ⟨O, ⟨⟨a, o₁⟩, hg₀, hh₁⟩, h⟩
    obtain ⟨o₂, hh₀, hO⟩ := (hh a o₁ b O).mp hh₁
    have hb : (out.val ++ o₁.val).length ≤ Usize.max := by
      have := out''.property
      simp only [h, hO, List.length_append] at this ⊢
      omega
    refine ⟨(a, alloc.vec.Vec.from (out.val ++ o₁.val) hb),
      (hg out a _).mpr ⟨o₁, hg₀, by simp⟩, ?_⟩
    exact (hh a _ b out'').mpr ⟨o₂, hh₀, by simp [h, hO]⟩

/-! ## The chunker -/

theorem step_appends (c : Chunker) (b : Std.U8) : Appends (fun out => step c out b) := by
  unfold step
  by_cases hb : b = 10#u8
  · simp only [hb, ite_true]
    apply appends_prefix
    intro ⟨line, c₁⟩
    simp only [uncurry_apply_pair]
    apply appends_prefix
    intro ⟨chunks, c₂⟩
    simp only [uncurry_apply_pair]
    exact appends_extend c₂ chunks
  · simp only [hb, ite_false]
    apply appends_prefix
    intro v
    exact appends_pure _

theorem steps_appends (c : Chunker) (l : List Std.U8) : Appends (fun out => steps c out l) := by
  induction l generalizing c with
  | nil => exact appends_pure c
  | cons b bs ih => exact appends_bind (step_appends c b) ih

theorem push_appends (c : Chunker) (d : Slice Std.U8) :
    Appends (fun out => Chunker.push c d out) := by
  simp only [push_eq]
  exact steps_appends c d.val

theorem finish_appends (c : Chunker) : Appends (fun out => Chunker.finish c out) := by
  unfold Chunker.finish
  apply appends_prefix
  intro b
  apply appends_prefix
  intro ⟨c₁, chunks⟩
  simp only [uncurry_apply_pair]
  apply appends_prefix
  intro last
  apply appends_prefix
  intro ⟨c₂, chunks₁⟩
  simp only [uncurry_apply_pair]
  exact appends_extend c₂ chunks₁

/-! ## The wrapper -/

/-- The chunks as `segment.rs`'s `Chunker` gets them: each push with a new
`out`, then `finish` with another, one after another. -/
def wrapper (c : Chunker) : List (Slice Std.U8) → Result (List (alloc.vec.Vec Std.U8))
  | [] => do
    let (_, o) ← Chunker.finish c empty
    ok o.val
  | d :: ds => do
    let (c, o) ← Chunker.push c d empty
    let rest ← wrapper c ds
    ok (o.val ++ rest)

/-- The chunks with one `out` for all of it, after what `out` had. -/
def whole (c : Chunker) (out : Out) (pieces : List (Slice Std.U8)) : Result Out := do
  let (c, out) ← pushAll c out pieces
  let (_, out) ← Chunker.finish c out
  ok out

theorem whole_wrapper (c : Chunker) (out O : Out) (pieces : List (Slice Std.U8)) :
    whole c out pieces = ok O ↔ ∃ L, wrapper c pieces = ok L ∧ O.val = out.val ++ L := by
  induction pieces generalizing c out with
  | nil =>
    simp only [whole, pushAll, wrapper, bind_ok, bind_eq_ok, uncurry_eq, ok_inj]
    constructor
    · rintro ⟨⟨c', O'⟩, hf, rfl⟩
      obtain ⟨o, hf₀, h⟩ := (finish_appends c out c' O').mp hf
      exact ⟨o.val, ⟨(c', o), hf₀, rfl⟩, h⟩
    · rintro ⟨L, ⟨⟨c', o⟩, hf₀, rfl⟩, h⟩
      exact ⟨(c', O), (finish_appends c out c' O).mpr ⟨o, hf₀, h⟩, rfl⟩
  | cons d ds ih =>
    have hw : ∀ c out, whole c out (d :: ds) =
        (do let (c, out) ← Chunker.push c d out; whole c out ds) := by
      intro c out
      simp only [whole, pushAll, Std.bind_assoc]
      refine congrArg (Std.bind _) (funext fun p => ?_)
      obtain ⟨c₁, out₁⟩ := p
      rfl
    rw [hw]
    simp only [wrapper, bind_eq_ok, uncurry_eq, ok_inj]
    constructor
    · rintro ⟨⟨c₁, out₁⟩, hp, hw₁⟩
      obtain ⟨o, hp₀, h₁⟩ := (push_appends c d out c₁ out₁).mp hp
      obtain ⟨L, hL, hO⟩ := (ih c₁ out₁).mp hw₁
      exact ⟨o.val ++ L, ⟨(c₁, o), hp₀, L, hL, rfl⟩, by simp [hO, h₁]⟩
    · rintro ⟨L, ⟨⟨c₁, o⟩, hp₀, L', hL', rfl⟩, h⟩
      have hb : (out.val ++ o.val).length ≤ Usize.max := by
        have := O.property
        simp only [h, List.length_append] at this ⊢
        omega
      refine ⟨(c₁, alloc.vec.Vec.from (out.val ++ o.val) hb),
        (push_appends c d out c₁ _).mpr ⟨o, hp₀, by simp⟩, ?_⟩
      exact (ih c₁ _).mpr ⟨L', hL', by simp [h]⟩

/-- Streaming, as `segment.rs` drives the chunker: for any list of chunks,
the pushes of the pieces and `finish` give it if and only if the whole text
pushed at once and `finish` give it. -/
theorem wrapper_streaming (pieces : List (Slice Std.U8)) (text : Slice Std.U8)
    (h : text.val = (pieces.map Slice.val).flatten) (O : Out) :
    (do let c ← Chunker.Insts.CoreDefaultDefault.default; wrapper c pieces) = ok O.val ↔
      chunks [text] = ok O := by
  rw [← chunks_streaming pieces text h]
  have hc : chunks pieces =
      (do let c ← Chunker.Insts.CoreDefaultDefault.default; whole c empty pieces) := rfl
  rw [hc]
  simp only [Chunker.Insts.CoreDefaultDefault.default, bind_ok]
  rw [whole_wrapper]
  simp

end MaxVerify

