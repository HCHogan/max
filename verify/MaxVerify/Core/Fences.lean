import MaxVerify.Core.Appends

open Aeneas Aeneas.Std Result ControlFlow
open Aeneas.Data.Coinductive
open max_core segment.chunk

/-!
# Fences stay whole

A chunk that leaves a code fence open is a message that QQ shows with the
rest of it as code, and the next one with its code as text. `cut` sends a
chunk only if it closes its fences, as `closes_fences` judges it, and only
`finish` sends one that may not: the last. `fences_whole` proves it of the
chunker as `segment.rs` drives it: however the text is streamed, every
chunk but the last closes its fences.

The proof follows `out` through the code, and needs nothing of the
chunker's state, as it is the check in `cut` that keeps fences whole. That
the check never holds a chunk back outside a fence is a test in `chunk.rs`.
-/

namespace MaxVerify.Core

/-! ## If it returns

`Ok m p`: if `m` returns, what it returns satisfies `p`. A panic or a loop
that never ends satisfies it too, so the proofs need no termination
measure, and don't prove that the chunker doesn't panic. Aeneas's `dspec`
is the same, but for panics, which it rules out. -/

/-- Rust's effects, read so that a panic satisfies anything. -/
@[reducible]
def panicWP : EffectWP RustEffect where
  State := Unit
  wp effect _ _ :=
    match effect with
    | .fail _ => True

instance : EffectWP.Monotonic panicWP where
  wp_monotonic := by intro effect _ _ _ _ _; cases effect; trivial

instance : EffectWP.Conjunctive panicWP where
  wp_conj := by intro effect _ _ _ _; cases effect; trivial

unseal Result in
def Ok {α : Type} (m : Result α) (p : α → Prop) : Prop :=
  DWLP panicWP m (fun v _ => p v) ()

namespace Ok

variable {α β : Type} {m : Result α} {p q : α → Prop}

unseal Result in
theorem ret {a : α} (h : p a) : Ok (ok a) p := DWLP.ret_iff.mpr h

unseal Result in
theorem result {a : α} (h : Ok m p) (hm : m = ok a) : p a := by
  subst hm; exact DWLP.ret_iff.mp h

unseal Result in
theorem bind {k : α → Result β} {r : β → Prop} (hm : Ok m q) (hk : ∀ x, q x → Ok (k x) r) :
    Ok (Std.bind m k) r :=
  DWLP.bind (k := k) hm fun v _ h => hk v h

unseal Result in
theorem self (m : Result α) : Ok m (fun x => m = ok x) := by
  cases m with
  | ret a => exact DWLP.ret_iff.mpr rfl
  | vis e k => cases e; exact DWLP.vis trivial
  | div => exact DWLP.div

/-- A step that doesn't matter, but for what it returns. -/
theorem then_ {k : α → Result β} {r : β → Prop} (hk : ∀ x, m = ok x → Ok (k x) r) :
    Ok (Std.bind m k) r :=
  bind (self m) hk

unseal Result in
theorem mono (h : Ok m p) (hpq : ∀ x, p x → q x) : Ok m q :=
  DWLP.mono h fun v _ hp => hpq v hp

unseal Result in
theorem admissible (post : β → Prop) (x : α) :
    Lean.Order.admissible (fun f : α → Result β => Ok (f x) post) :=
  Lean.Order.admissible_apply (fun _ m => Ok m post) x (DWLP.admissible panicWP _ ())

/-- A loop keeps an invariant, and its result satisfies `post`, if its body
does: by fixpoint induction, as the loop may not end. -/
theorem loop (body : α → Result (ControlFlow α β)) (inv : α → Prop) (post : β → Prop)
    (h : ∀ x, inv x → Ok (body x) (fun r => match r with
      | .cont x' => inv x'
      | .done y => post y)) :
    ∀ x, inv x → Ok (Std.loop body x) post := by
  apply loop.fixpoint_induct body (motive := fun f => ∀ x, inv x → Ok (f x) post)
  · apply Lean.Order.admissible_pi; intro x
    apply Lean.Order.admissible_pi; intro _
    exact admissible post x
  · intro f ih x hx
    refine bind (h x hx) fun r hr => ?_
    cases r with
    | cont x' => exact ih x' hr
    | done y => exact ret hr

end Ok

/-! ## Chunks that close their fences -/

/-- A chunk closes its fences, as `closes_fences` judges it. -/
def Closes (x : alloc.vec.Vec Std.U8) : Prop :=
  closes_fences (alloc.vec.Vec.deref x) = ok true

/-- Every chunk in `out` closes its fences. -/
def AllClose (out : Out) : Prop := ∀ x ∈ out.val, Closes x

theorem push_ok {v : Out} {x : alloc.vec.Vec Std.U8} {v' : Out} (h : v.push x = ok v') :
    v'.val = v.val ++ [x] := by
  unfold alloc.vec.Vec.push at h
  dsimp only at h
  split at h
  · simp only [ok_inj] at h; subst h; simp
  · simp [Result.fail_eq_vis, vis_not_ok] at h

theorem end_ok (c : Chunker) (chunk : alloc.vec.Vec Std.U8) (out : Out)
    (hout : AllClose out) (hc : Closes chunk) :
    Ok (Chunker.end c chunk out) (fun r => AllClose r.2) := by
  unfold Chunker.end
  refine Ok.then_ fun b _ => ?_
  split
  · exact Ok.ret hout
  · refine Ok.then_ fun out' h => Ok.ret ?_
    intro x hx
    rw [push_ok h, List.mem_append, List.mem_singleton] at hx
    rcases hx with hx | rfl
    · exact hout x hx
    · exact hc

theorem allClose_empty : AllClose empty := by simp [AllClose]

theorem allClose_extend {out chunks out' : Out} (hout : AllClose out) (hc : AllClose chunks)
    (h : extend out chunks = ok out') : AllClose out' := by
  intro x hx
  rw [(extend_eq_ok out chunks out').mp h, List.mem_append] at hx
  exact hx.elim (hout x) (hc x)

/-- `end` sends the chunk, or nothing. -/
theorem end_sends (c : Chunker) (chunk : alloc.vec.Vec Std.U8) (out : Out) :
    Ok (Chunker.end c chunk out) (fun r => r.2.val = out.val ∨ r.2.val = out.val ++ [chunk]) := by
  unfold Chunker.end
  refine Ok.then_ fun b _ => ?_
  split
  · exact Ok.ret (Or.inl rfl)
  · exact Ok.then_ fun out' h => Ok.ret (Or.inr (push_ok h))

theorem cut_ok (c : Chunker) (out : Out) (hout : AllClose out) :
    Ok (Chunker.cut c out) (fun r => AllClose r.2) := by
  unfold Chunker.cut
  refine Ok.then_ fun chunk _ => ?_
  refine Ok.then_ fun b hb => ?_
  split
  · rename_i h; subst h
    exact end_ok c chunk out hout hb
  · exact Ok.ret hout

set_option hygiene false in
/-- One step through code that passes `out` on only to what keeps
`AllClose`, or returns it. Without hygiene, so that it can name the lemmas
proven after it. -/
macro "keep1" : tactic => `(tactic| (first
  | ((with_reducible apply Ok.ret); assumption)
  | ((with_reducible refine cut_ok _ _ ?_); assumption)
  | ((with_reducible refine message_line_ok _ _ _ ?_); assumption)
  | ((with_reducible refine classify_loop_ok _ _ _ _ _ ?_); assumption)
  | ((with_reducible refine classify_ok _ _ _ ?_); assumption)
  | with_reducible exact line_ok _ _
  | with_reducible
      (refine Ok.bind (q := fun r : Chunker × Out => AllClose r.2) ?_ fun _ _ => ?_)
  | with_reducible
      (refine Ok.bind (q := fun r : Chunker × Out × Usize => AllClose r.2.1) ?_ fun _ _ => ?_)
  | with_reducible
      (refine Ok.bind (q := fun r : Option Usize × Chunker × Out => AllClose r.2.2) ?_
        fun _ _ => ?_)
  | with_reducible
      (refine Ok.bind (q := fun r : Out × Chunker => AllClose r.1) ?_ fun _ _ => ?_)
  | with_reducible (refine Ok.then_ fun _ _ => ?_)
  | (simp only [uncurry_eq])
  | split
  | intro _))

macro "keep" : tactic => `(tactic| repeat' keep1)

theorem message_line_ok (c : Chunker) (line : Slice Std.U8) (out : Out) (hout : AllClose out) :
    Ok (Chunker.message_line c line out) (fun r => AllClose r.2.2) := by
  unfold Chunker.message_line
  keep

theorem classify_loop_ok (c : Chunker) (line : Slice Std.U8) (out : Out) (start : Usize)
    (done : Bool) (hout : AllClose out) :
    Ok (Chunker.classify_loop c line out start done) (fun r => AllClose r.2) := by
  unfold Chunker.classify_loop
  refine Ok.loop _ (fun x => AllClose x.2.1) _ ?_ _ hout
  rintro ⟨c, out, start, done⟩ hout
  change AllClose out at hout
  unfold Chunker.classify_loop.body
  keep

theorem classify_ok (c : Chunker) (line : Slice Std.U8) (out : Out) (hout : AllClose out) :
    Ok (Chunker.classify c line out) (fun r => AllClose r.2) := by
  unfold Chunker.classify
  keep

/-- The chunks a line completes close their fences. -/
theorem line_ok (c : Chunker) (raw : Slice Std.U8) :
    Ok (Chunker.line c raw) (fun r => AllClose r.1) := by
  have := allClose_empty
  unfold Chunker.line
  keep

theorem step_ok (c : Chunker) (out : Out) (b : Std.U8) (hout : AllClose out) :
    Ok (step c out b) (fun r => AllClose r.2) := by
  unfold step
  split
  · refine Ok.then_ fun _ _ => ?_
    simp only [uncurry_eq]
    refine Ok.bind (line_ok _ _) fun r hr => ?_
    simp only [uncurry_eq]
    exact Ok.then_ fun out' h => Ok.ret (allClose_extend hout hr h)
  · exact Ok.then_ fun _ _ => Ok.ret hout

theorem push_closes (c : Chunker) (d : Slice Std.U8) (out : Out) (hout : AllClose out) :
    Ok (Chunker.push c d out) (fun r => AllClose r.2) := by
  rw [push_eq]
  induction d.val generalizing c out with
  | nil => exact Ok.ret hout
  | cons b bs ih =>
    simp only [steps]
    refine Ok.bind (step_ok c out b hout) fun r hr => ?_
    simp only [uncurry_eq]
    exact ih _ _ hr

/-- `finish`'s chunks close their fences, but the last. -/
theorem finish_closes (c : Chunker) :
    Ok (Chunker.finish c empty) (fun r => ∀ x ∈ r.2.val.dropLast, Closes x) := by
  have := allClose_empty
  unfold Chunker.finish
  refine Ok.then_ fun _ _ => ?_
  refine Ok.bind (q := fun r : Chunker × Out => AllClose r.2) ?_ fun r hr => ?_
  · keep
  simp only [uncurry_eq]
  refine Ok.then_ fun last _ => ?_
  refine Ok.bind (end_sends _ _ _) fun ⟨c', r'⟩ hr' => ?_
  refine Ok.then_ fun out' h => Ok.ret ?_
  rw [(extend_eq_ok _ _ _).mp h]
  intro x hx
  rw [show (empty : Out).val = [] from rfl, List.nil_append] at hx
  rcases hr' with hr' | hr' <;> rw [hr'] at hx
  · exact hr x (List.dropLast_subset _ hx)
  · simpa using hr x (by simpa using hx)

/-! ## Fences stay whole -/

theorem mem_dropLast_append {α : Type} {x : α} {a b : List α} (h : x ∈ (a ++ b).dropLast) :
    x ∈ a ∨ x ∈ b.dropLast := by
  by_cases hb : b = []
  · subst hb; simp only [List.append_nil] at h; exact Or.inl (List.dropLast_subset _ h)
  · rw [List.dropLast_append_of_ne_nil hb, List.mem_append] at h; exact h

theorem wrapper_closes (c : Chunker) (pieces : List (Slice Std.U8)) :
    Ok (wrapper c pieces) (fun L => ∀ x ∈ L.dropLast, Closes x) := by
  induction pieces generalizing c with
  | nil =>
    simp only [wrapper]
    refine Ok.bind (finish_closes c) fun r hr => ?_
    simp only [uncurry_eq]
    exact Ok.ret hr
  | cons d ds ih =>
    simp only [wrapper]
    refine Ok.bind (push_closes c d empty allClose_empty) fun r hr => ?_
    simp only [uncurry_eq]
    refine Ok.bind (ih r.1) fun L hL => Ok.ret fun x hx => ?_
    exact (mem_dropLast_append hx).elim (hr x) (hL x)

/-- Fences stay whole: however the text is streamed, every chunk but the
last that `segment.rs`'s `Chunker` sends closes its fences. -/
theorem fences_whole (c : Chunker) (pieces : List (Slice Std.U8))
    (L : List (alloc.vec.Vec Std.U8)) (h : wrapper c pieces = ok L) :
    ∀ x ∈ L.dropLast, Closes x :=
  (wrapper_closes c pieces).result h

end MaxVerify.Core
