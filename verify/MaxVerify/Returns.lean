import MaxVerify.Utf8

open Aeneas Aeneas.Std Result ControlFlow
open max_core segment.chunk

/-!
# The chunker returns

`returns` proves that the chunker, as `segment.rs` drives it, returns:
however a text is streamed, no index is out of bounds, no integer
overflows, no loop runs forever, and no `Vec` outgrows `usize::MAX`, if the
text is shorter than about half of `usize::MAX` bytes. What the chunker holds
and sends takes at most twice the text: a line takes its bytes and a
newline, and a cut, which can make a line more, is two bytes at least.

The specs are Aeneas's `⦃ ⦄`, which rule panics out, and `step*` steps
through the code by them, proving the arithmetic on the way. `pstep` takes
apart what `step*` doesn't, and every loop ends by a measure,
`loop.spec_decr_nat`.
-/

namespace MaxVerify

/-! ## Stepping -/

/-- A pair's `let`, which `step*` doesn't take apart. -/
theorem spec_uncurry {α β γ : Type} {k : α → β → Result γ} {x : α × β} {p : γ → Prop}
    (h : ∀ a b, x = (a, b) → WP.spec (k a b) p) : WP.spec (Std.uncurry k x) p := by
  obtain ⟨a, b⟩ := x
  exact h a b rfl

/-- A pair's `let` in a `let`. -/
theorem spec_bind_uncurry {α β γ δ : Type} {f : α → β → Result γ} {x : α × β}
    {k : γ → Result δ} {p : δ → Prop}
    (h : ∀ a b, x = (a, b) → WP.spec (Std.bind (f a b) k) p) :
    WP.spec (Std.bind (Std.uncurry f x) k) p := by
  obtain ⟨a, b⟩ := x
  exact h a b rfl

/-- A `let` of an `if`, which `step*` doesn't take apart either. -/
theorem spec_bind_ite {α β : Type} {c : Prop} [Decidable c] {a b : Result α} {k : α → Result β}
    {p : β → Prop} (ha : c → WP.spec (Std.bind a k) p) (hb : ¬c → WP.spec (Std.bind b k) p) :
    WP.spec (Std.bind (if c then a else b) k) p := by
  by_cases h : c
  · simp only [h, ↓reduceIte]; exact ha h
  · simp only [h, ↓reduceIte]; exact hb h

open Lean Meta Elab Tactic in
/-- `h v rfl` for every `h : ∀ x ∈ some v, P x`, as a new hypothesis: `simp`
can't rewrite `h` itself when a proof that an index is in bounds uses it. -/
elab "opt_facts" : tactic => withMainContext do
  let mut facts : Array Expr := #[]
  for d in (← getLCtx) do
    if d.isImplementationDetail then continue
    unless (← whnfR d.type).isForall do continue
    let saved ← saveState
    try
      let stx ← Term.exprToSyntax (mkFVar d.fvarId)
      let pf ← instantiateMVars (← Term.elabTermAndSynthesize (← `($stx _ rfl)) none)
      if pf.hasMVar then saved.restore else facts := facts.push pf
    catch _ => saved.restore
  let mut g ← getMainGoal
  for pf in facts do
    let ty ← instantiateMVars (← inferType pf)
    let (_, g') ← (← g.assert `fact ty pf).intro1P
    g := g'
  replaceMainGoal [g]

/-- What `pstep` leaves: what is known of the options that the specs'
`∀ x ∈ o` are of. -/
macro "leaves" : tactic => `(tactic| all_goals
  subst_vars
  opt_facts
  simp (config := { failIfUnchanged := false }) only [Option.mem_def, Option.some.injEq,
    forall_eq, forall_eq', reduceCtorEq, false_implies, implies_true] at *
  try scalar_tac)

/-- `step*`, and on through pairs' `let`s and `let`s of `if`s. -/
syntax "pstep" : tactic
macro_rules
  | `(tactic| pstep) =>
    `(tactic| (step*; all_goals (try (first
      | (refine spec_uncurry fun _ _ h => ?_; subst h; pstep)
      | (refine spec_bind_uncurry fun _ _ h => ?_; subst h; pstep)
      | (refine spec_bind_ite (fun _ => ?_) (fun _ => ?_) <;> pstep)
      | (split <;> pstep)))))

/-! ## Scanning -/

theorem starts_at_loop_spec (s : Slice Std.U8) (a : Usize) (pat : Slice Std.U8) (i : Usize)
    (same : Bool) (h : a.val + pat.length ≤ s.length) :
    starts_at_loop s a pat i same ⦃ _ => True ⦄ := by
  unfold starts_at_loop
  apply loop.spec_decr_nat (fun x : Usize × Bool => pat.length - x.1.val) (fun _ => True)
  · rintro ⟨i, same⟩ -
    unfold starts_at_loop.body
    step*
  · trivial

@[step]
theorem starts_at_spec (s : Slice Std.U8) (a : Usize) (pat : Slice Std.U8) :
    starts_at s a pat ⦃ r => r = true → a.val + pat.length ≤ s.length ⦄ := by
  unfold starts_at
  step*
  apply WP.spec_mono (starts_at_loop_spec _ _ _ _ _ (by scalar_tac))
  intro _ _ _
  scalar_tac

@[step]
theorem find_loop_spec (s pat : Slice Std.U8) (i : Usize) (found : Bool)
    (hf : found = true → i.val + pat.length ≤ s.length) :
    find_loop s pat i found ⦃ r => i.val ≤ r.1.val ∧
      (r.2 = true → r.1.val + pat.length ≤ s.length) ⦄ := by
  unfold find_loop
  apply loop.spec_decr_nat (fun x : Usize × Bool => 2 * (s.length - x.1.val) + (!x.2).toNat)
    (fun x : Usize × Bool => i.val ≤ x.1.val ∧ (x.2 = true → x.1.val + pat.length ≤ s.length))
  · rintro ⟨j, found⟩ ⟨hij, hj⟩
    unfold find_loop.body
    step*
  · exact ⟨le_refl _, hf⟩

@[step]
theorem find_spec (s : Slice Std.U8) (a : Usize) (pat : Slice Std.U8) :
    find s a pat ⦃ r => ∀ i ∈ r, a.val ≤ i.val ∧ i.val + pat.length ≤ s.length ⦄ := by
  unfold find
  step*

@[step]
theorem is_word_spec (s : Slice Std.U8) (a b : Usize) (word : Slice Std.U8) (h : a.val ≤ b.val) :
    is_word s a b word ⦃ _ => True ⦄ := by
  unfold is_word
  step*

theorem tenth_val : digits.TENTH.val = 922337203685477580 := by
  unfold digits.TENTH; rfl

@[step]
theorem digits_loop_spec (s : Slice Std.U8) (a : Usize) (n : Std.I64) (len : Usize) (fits : Bool)
    (hl : a.val + len.val ≤ s.length) (hn : 0 ≤ n.val) :
    digits_loop s a n len fits ⦃ r => len.val ≤ r.2.1.val ∧ a.val + r.2.1.val ≤ s.length ⦄ := by
  unfold digits_loop
  apply loop.spec_decr_nat (fun x : Std.I64 × Usize × Bool => s.length - x.2.1.val)
    (fun x : Std.I64 × Usize × Bool => len.val ≤ x.2.1.val ∧ a.val + x.2.1.val ≤ s.length ∧
      0 ≤ x.1.val)
  · rintro ⟨n, l, fits⟩ ⟨hl0, hl, hn⟩
    unfold digits_loop.body
    have ht := tenth_val
    step*
    have hd : d.val = i5.val := by
      have h := UScalar.hcast_inBounds_spec .I64 i5 (by scalar_tac)
      simp only [lift, WP.spec_ok] at h
      rw [d_post, h]
    apply WP.spec_bind (Pₘ := fun x : Std.I64 × Bool => 0 ≤ x.1.val)
    · split_ifs <;> step*
    · rintro ⟨n1, f1⟩ hn1
      step*
      simp only at hl0 hl hn hn1
      scalar_tac
  · exact ⟨le_refl _, hl, hn⟩

@[step]
theorem digits_spec (s : Slice Std.U8) (a : Usize) (h : a.val ≤ s.length) :
    digits s a ⦃ r => ∀ p ∈ r, 0 < p.2.val ∧ a.val + p.2.val ≤ s.length ⦄ := by
  unfold digits
  step*

@[step]
theorem closer_spec (s : Slice Std.U8) (a : Usize) :
    closer s a ⦃ r => ∀ p ∈ r, a.val < s.length ∧ a.val ≤ p.1.val ∧ p.1.val < p.2.val ∧
      p.2.val ≤ s.length ⦄ := by
  unfold closer
  step*

@[step]
theorem is_medium_spec (s : Slice Std.U8) (a b : Usize) (h : a.val ≤ b.val) :
    is_medium s a b ⦃ _ => True ⦄ := by
  unfold is_medium
  step*

set_option maxHeartbeats 4000000 in
@[step]
theorem placeholder_spec (s : Slice Std.U8) (a : Usize) :
    placeholder s a ⦃ r => ∀ P ∈ r, 2 ≤ P.len.val ∧ a.val + P.len.val ≤ s.length ⦄ := by
  unfold placeholder
  pstep
  leaves

@[step]
theorem quote_spec (s : Slice Std.U8) (a : Usize) :
    quote s a ⦃ r => ∀ n ∈ r, 2 ≤ n.val ∧ a.val + n.val ≤ s.length ⦄ := by
  unfold quote
  pstep

@[step]
theorem picture_spec (s : Slice Std.U8) (a : Usize) :
    picture s a ⦃ r => ∀ n ∈ r, 2 ≤ n.val ∧ a.val + n.val ≤ s.length ⦄ := by
  unfold picture
  pstep

@[step]
theorem space_at_len (s : Slice Std.U8) (i : Usize) :
    space_at s i ⦃ n => n.val = 0 ∨ i.val + n.val ≤ s.length ⦄ :=
  WP.spec_mono (space_at_spec s i) fun _ h => h.imp id And.left

@[step]
theorem space_before_len (s : Slice Std.U8) (j : Usize) :
    space_before s j ⦃ n => n.val = 0 ∨ n.val ≤ j.val ⦄ :=
  WP.spec_mono (space_before_spec s j) fun _ h => h.imp id And.left

/-- What a loop's `step*` leaves: its state as a pair, and its flags. -/
macro "loop_leaves" : tactic => `(tactic| all_goals
  simp (config := { failIfUnchanged := false }) only [Bool.toNat_true, Bool.toNat_false,
    Bool.not_true, Bool.not_false] at *
  scalar_tac)

@[step]
theorem skip_space_spec (s : Slice Std.U8) (a : Usize) :
    skip_space s a ⦃ r => a.val ≤ r.val ∧ (a.val ≤ s.length → r.val ≤ s.length) ⦄ := by
  unfold skip_space skip_space_loop
  apply loop.spec_decr_nat (fun x : Usize × Bool => s.length - x.1.val + x.2.toNat)
    (fun x : Usize × Bool => a.val ≤ x.1.val ∧ (a.val ≤ s.length → x.1.val ≤ s.length))
  · rintro ⟨b, moving⟩ ⟨hab, hb⟩
    unfold skip_space_loop.body
    step*
    loop_leaves
  · exact ⟨le_refl _, id⟩

@[step]
theorem trim_loop0_spec (s : Slice Std.U8) (t a : Usize) (moving : Bool) (ht : t.val ≤ s.length)
    (ha : a.val ≤ t.val) :
    trim_loop0 s t a moving ⦃ r => a.val ≤ r.val ∧ r.val ≤ t.val ⦄ := by
  unfold trim_loop0
  apply loop.spec_decr_nat (fun x : Usize × Bool => t.val - x.1.val + x.2.toNat)
    (fun x : Usize × Bool => a.val ≤ x.1.val ∧ x.1.val ≤ t.val)
  · rintro ⟨b, moving⟩ ⟨hab, hb⟩
    unfold trim_loop0.body
    step*
    loop_leaves
  · exact ⟨le_refl _, ha⟩

@[step]
theorem trim_loop1_spec (s : Slice Std.U8) (a : Usize) (moving : Bool) (b : Usize)
    (hb : b.val ≤ s.length) (ha : a.val ≤ b.val) :
    trim_loop1 s a moving b ⦃ r => a.val ≤ r.val ∧ r.val ≤ b.val ⦄ := by
  unfold trim_loop1
  apply loop.spec_decr_nat (fun x : Bool × Usize => x.2.val - a.val + x.1.toNat)
    (fun x : Bool × Usize => a.val ≤ x.2.val ∧ x.2.val ≤ b.val)
  · rintro ⟨moving, c⟩ ⟨hac, hc⟩
    unfold trim_loop1.body
    step*
    loop_leaves
  · exact ⟨ha, le_refl _⟩

@[step]
theorem trim_spec (s : Slice Std.U8) (a b : Usize) (hb : b.val ≤ s.length) (ha : a.val ≤ b.val) :
    trim s a b ⦃ r => a.val ≤ r.1.val ∧ r.1.val ≤ r.2.val ∧ r.2.val ≤ b.val ⦄ := by
  unfold trim
  step*

@[step]
theorem is_blank_spec (s : Slice Std.U8) (a b : Usize) (hb : b.val ≤ s.length)
    (ha : a.val ≤ b.val) : is_blank s a b ⦃ _ => True ⦄ := by
  unfold is_blank
  pstep

@[step]
theorem ticks_at_spec (s : Slice Std.U8) (a : Usize) (ha : a.val ≤ s.length) :
    ticks_at s a ⦃ n => a.val + n.val ≤ s.length ∧
      ∀ h : a.val < s.length, s.val[a.val] = 96#u8 → 0 < n.val ⦄ := by
  unfold ticks_at ticks_at_loop
  apply loop.spec_decr_nat (fun n : Usize => s.length - n.val)
    (fun n : Usize => a.val + n.val ≤ s.length)
  · intro n hn
    unfold ticks_at_loop.body
    step*
    scalar_tac
  · simpa using ha

@[step]
theorem is_fence_spec (line : Slice Std.U8) : is_fence line ⦃ _ => True ⦄ := by
  unfold is_fence
  step*

@[step]
theorem is_heading_loop_spec (line : Slice Std.U8) (m : Usize) (hm : m.val ≤ line.length) :
    is_heading_loop line m ⦃ r => r.val ≤ line.length ⦄ := by
  unfold is_heading_loop
  apply loop.spec_decr_nat (fun m : Usize => line.length - m.val)
    (fun m : Usize => m.val ≤ line.length)
  · intro m hm
    unfold is_heading_loop.body
    step*
  · exact hm

@[step]
theorem is_heading_spec (line : Slice Std.U8) : is_heading line ⦃ _ => True ⦄ := by
  unfold is_heading
  step*

@[step]
theorem is_break_spec (line : Slice Std.U8) : is_break line ⦃ _ => True ⦄ := by
  unfold is_break is_break_loop
  apply WP.spec_bind (loop.spec_decr_nat (fun x : Usize × Usize × Std.U8 × Bool =>
      line.length - x.1.val) (fun x : Usize × Usize × Std.U8 × Bool =>
      x.2.1.val ≤ x.1.val ∧ x.1.val ≤ line.length) (fun _ => True) _ _ ?_ (by simp))
  · intro _ _
    pstep
  · rintro ⟨i, count, first, same⟩ ⟨hc, hi⟩
    unfold is_break_loop.body
    pstep
    all_goals (simp only at *; scalar_tac)

@[step]
theorem closing_spec (s : Slice Std.U8) (ticks a : Usize) :
    closing s ticks a ⦃ r => ∀ e ∈ r, a.val < e.val ∧ e.val ≤ s.length ⦄ := by
  unfold closing closing_loop
  apply WP.spec_bind (loop.spec_decr_nat (fun x : Usize × Bool × Usize =>
      2 * (s.length - x.1.val) + (!x.2.1).toNat) (fun x : Usize × Bool × Usize =>
      a.val ≤ x.1.val ∧ (x.2.1 = true → a.val < x.2.2.val ∧ x.2.2.val ≤ s.length))
      (fun x : Bool × Usize => x.1 = true → a.val < x.2.val ∧ x.2.val ≤ s.length) _ _ ?_
      (by simp))
  · rintro ⟨found, e⟩ h
    pstep
  · rintro ⟨j, found, e⟩ ⟨hj, he⟩
    unfold closing_loop.body
    pstep
    all_goals
      subst_vars
      have := n_post1 (by scalar_tac) (by assumption)
      simp only at *
      scalar_tac

@[step]
theorem code_spans_spec (s : Slice Std.U8) : code_spans s ⦃ _ => True ⦄ := by
  unfold code_spans code_spans_loop
  apply WP.spec_mono (loop.spec_decr_nat
    (fun x : alloc.vec.Vec (Usize × Usize) × Usize => s.length - x.2.val)
    (fun x : alloc.vec.Vec (Usize × Usize) × Usize => x.1.length ≤ x.2.val ∧ x.2.val ≤ s.length)
    (fun _ => True) _ _ ?_ (by simp)) fun _ _ => trivial
  rintro ⟨spans, i⟩ ⟨hs, hi⟩
  unfold code_spans_loop.body
  pstep
  all_goals
    subst_vars
    try have := ticks_post1 (by scalar_tac) (by assumption)
    opt_facts
    simp (config := { failIfUnchanged := false }) only [alloc.vec.Vec.length] at *
    scalar_tac

@[step]
theorem outside_spec (spans : Slice (Usize × Usize)) (a : Usize) :
    outside spans a ⦃ _ => True ⦄ := by
  unfold outside outside_loop
  apply loop.spec_decr_nat (fun x : Usize × Bool => spans.length - x.1.val) (fun _ => True)
  · rintro ⟨i, o⟩ -
    unfold outside_loop.body
    pstep
  · trivial

@[step]
theorem next_cut_loop0_spec (line : Slice Std.U8) (spans : alloc.vec.Vec (Usize × Usize))
    (i : Usize) (has : Bool) (h : has = true → i.val + 7 ≤ line.length) :
    next_cut_loop0 line spans i has ⦃ r => r.2 = true → r.1.val + 7 ≤ line.length ⦄ := by
  unfold next_cut_loop0
  apply loop.spec_decr_nat (fun x : Usize × Bool => 2 * (line.length - x.1.val) + (!x.2).toNat)
    (fun x : Usize × Bool => x.2 = true → x.1.val + 7 ≤ line.length)
  · rintro ⟨i, has⟩ h
    unfold next_cut_loop0.body
    pstep
  · exact h

@[step]
theorem next_cut_loop1_spec (line : Slice Std.U8) (spans : alloc.vec.Vec (Usize × Usize))
    (i n : Usize) (has : Bool) (h : has = true → 2 ≤ n.val ∧ i.val + n.val ≤ line.length) :
    next_cut_loop1 line spans i n has ⦃ r => r.2.2 = true → 2 ≤ r.2.1.val ∧
      r.1.val + r.2.1.val ≤ line.length ⦄ := by
  unfold next_cut_loop1
  apply loop.spec_decr_nat (fun x : Usize × Usize × Bool =>
      2 * (line.length - x.1.val) + (!x.2.2).toNat)
    (fun x : Usize × Usize × Bool => x.2.2 = true → 2 ≤ x.2.1.val ∧
      x.1.val + x.2.1.val ≤ line.length)
  · rintro ⟨i, n, has⟩ h
    unfold next_cut_loop1.body
    pstep
  · exact h

@[step]
theorem next_cut_spec (line : Slice Std.U8) :
    next_cut line ⦃ r => ∀ x ∈ r, 2 ≤ x.2.1.val ∧ x.1.val + x.2.1.val ≤ line.length ⦄ := by
  unfold next_cut
  pstep

@[step]
theorem think_tag_loop_spec (rest : Slice Std.U8) (spans : alloc.vec.Vec (Usize × Usize))
    (i : Usize) (found : Bool) (h : found = true → i.val + 7 ≤ rest.length) :
    think_tag_loop rest spans i found ⦃ r => r.2 = true → r.1.val + 7 ≤ rest.length ⦄ := by
  unfold think_tag_loop
  apply loop.spec_decr_nat (fun x : Usize × Bool => 2 * (rest.length - x.1.val) + (!x.2).toNat)
    (fun x : Usize × Bool => x.2 = true → x.1.val + 7 ≤ rest.length)
  · rintro ⟨i, found⟩ h
    unfold think_tag_loop.body
    pstep
  · exact h

@[step]
theorem think_tag_spec (line : Slice Std.U8) (a : Usize) (h : a.val ≤ line.length) :
    think_tag line a ⦃ r => ∀ p ∈ r, a.val ≤ p.val ∧ p.val + 7 ≤ line.length ⦄ := by
  unfold think_tag
  pstep
  simp only [Option.mem_def, Option.some.injEq, forall_eq'] at *
  have := i_post (by assumption)
  scalar_tac

@[step]
theorem fence_line_spec (first : Bool) (line : Slice Std.U8) :
    fence_line first line ⦃ _ => True ⦄ := by
  unfold fence_line
  apply WP.spec_bind (Pₘ := fun t : Usize => t.val ≤ line.length)
  · split
    · pstep
    · step*
  · intro t ht
    step*

@[step]
theorem closes_fences_spec (chunk : Slice Std.U8) : closes_fences chunk ⦃ _ => True ⦄ := by
  unfold closes_fences closes_fences_loop
  apply WP.spec_bind (loop.spec_decr_nat (fun x : Bool × Usize × Usize =>
      chunk.length - x.2.2.val) (fun x : Bool × Usize × Usize =>
      x.2.1.val ≤ x.2.2.val ∧ x.2.2.val ≤ chunk.length) (fun x : Bool × Usize =>
      x.2.val ≤ chunk.length) _ _ ?_ (by simp))
  · rintro ⟨o, start⟩ h
    pstep
  · rintro ⟨o, start, i⟩ ⟨hs, hi⟩
    unfold closes_fences_loop.body
    pstep

/-! ## Room

A `Vec` can't outgrow `usize::MAX`, and Aeneas's `push` fails if it would:
what the chunker holds has to be bounded by the text. -/

/-- What a chunk's lines take when joined: their bytes, and a newline each. -/
def weight (ls : List (alloc.vec.Vec Std.U8)) : Nat := (ls.map fun l => l.val.length + 1).sum

@[simp]
theorem weight_nil : weight [] = 0 := rfl

@[simp]
theorem weight_append (a b : List (alloc.vec.Vec Std.U8)) :
    weight (a ++ b) = weight a + weight b := by
  simp [weight]

@[simp]
theorem weight_singleton (l : alloc.vec.Vec Std.U8) : weight [l] = l.val.length + 1 := by
  simp [weight]

theorem weight_drop (ls : List (alloc.vec.Vec Std.U8)) (i : Nat) (h : i < ls.length) :
    weight (ls.drop i) = ls[i].val.length + 1 + weight (ls.drop (i + 1)) := by
  rw [List.drop_eq_getElem_cons h]
  simp only [weight, List.map_cons, List.sum_cons]

theorem list_clone_bytes (l : List Std.U8) :
    List.clone core.clone.CloneU8.clone l = ok ⟨l, rfl⟩ :=
  list_clone_ok _ (fun _ => rfl) l

@[simp]
theorem deref_val {α : Type} (v : alloc.vec.Vec α) : (alloc.vec.Vec.deref v).val = v.val := by
  simp [alloc.vec.Vec.deref]

@[simp]
theorem deref_length {α : Type} (v : alloc.vec.Vec α) :
    (alloc.vec.Vec.deref v).length = v.length := by
  simp [alloc.vec.Vec.deref, Slice.length, alloc.vec.Vec.length]

@[step]
theorem bytes_extend_spec (v : alloc.vec.Vec Std.U8) (t : Slice Std.U8)
    (h : v.length + t.length ≤ Usize.max) :
    alloc.vec.Vec.extend_from_slice core.clone.CloneU8 v t ⦃ v' => v'.val = v.val ++ t.val ⦄ := by
  unfold alloc.vec.Vec.extend_from_slice
  split
  · rw [list_clone_bytes]
    simp [WP.spec_ok]
  · contradiction

@[step]
theorem chunk_text_loop_spec (lines : Slice (alloc.vec.Vec Std.U8)) (text : alloc.vec.Vec Std.U8)
    (i : Usize) (W : Nat) (hW : W ≤ Usize.max) (hi : i.val ≤ lines.length)
    (ht : text.length + weight (lines.val.drop i.val) + min i.val 1 ≤ W)
    (h0 : i.val = 0 → text.val = []) :
    chunk_text_loop lines text i ⦃ r => r.val.length + 1 ≤ W ∨ (lines.val = [] ∧ r.val = []) ⦄ := by
  unfold chunk_text_loop
  apply loop.spec_decr_nat (fun x : alloc.vec.Vec Std.U8 × Usize => lines.length - x.2.val)
    (fun x : alloc.vec.Vec Std.U8 × Usize => x.2.val ≤ lines.length ∧
      x.1.length + weight (lines.val.drop x.2.val) + min x.2.val 1 ≤ W ∧
      (x.2.val = 0 → x.1.val = []))
  · rintro ⟨text, i⟩ ⟨hi, ht, h0⟩
    unfold chunk_text_loop.body
    simp only at hi ht h0
    by_cases hlt : i.val < lines.length
    · have hw := weight_drop lines.val i.val hlt
      pstep
      all_goals
        subst_vars
        simp only [deref_val, deref_length, alloc.vec.Vec.length] at *
        scalar_tac
    · have hd : lines.val.drop i.val = [] := List.drop_eq_nil_of_le (by scalar_tac)
      rw [hd, weight_nil] at ht
      pstep
      by_cases hi0 : i.val = 0
      · right
        exact ⟨List.eq_nil_of_length_eq_zero (by scalar_tac), h0 hi0⟩
      · left
        simp only [alloc.vec.Vec.length] at ht
        scalar_tac
  · exact ⟨hi, ht, h0⟩

@[step]
theorem chunk_text_spec (lines : Slice (alloc.vec.Vec Std.U8)) (h : weight lines.val ≤ Usize.max) :
    chunk_text lines ⦃ r => r.val.length = 0 ∨ r.val.length + 1 ≤ weight lines.val ⦄ := by
  unfold chunk_text
  pstep
  · simp
  · simp
  · have hr : r.val.length = b.val - a.val := by simp [r_post, s1_post1]
    have hb : b.val ≤ text.val.length := by simpa using a_post2
    rcases text_post with h1 | ⟨-, h2⟩
    · scalar_tac
    · rw [h2] at hb
      scalar_tac

theorem length_le_weight (ls : List (alloc.vec.Vec Std.U8)) : ls.length ≤ weight ls := by
  induction ls with
  | nil => simp
  | cons l ls ih =>
    have : weight (l :: ls) = l.val.length + 1 + weight ls := by simp [weight]
    simp only [List.length_cons, this]
    omega

/-- The room the chunk being built and the chunks sent take. -/
abbrev room (c : Chunker) (out : Out) : Nat := weight c.lines.val + out.val.length

@[step]
theorem push_line_spec (c : Chunker) (line : Slice Std.U8)
    (h : weight c.lines.val + line.length + 1 ≤ Usize.max) :
    Chunker.push_line c line ⦃ c' => weight c'.lines.val = weight c.lines.val + line.length + 1 ∧
      c'.partial = c.partial ⦄ := by
  unfold Chunker.push_line
  have := length_le_weight c.lines.val
  pstep
  all_goals simp [v_post, copy_post, Nat.add_assoc]

@[step]
theorem end_spec (c : Chunker) (chunk : alloc.vec.Vec Std.U8) (out : Out)
    (hc : chunk.val.length = 0 ∨ chunk.val.length + 1 ≤ weight c.lines.val)
    (h : room c out ≤ Usize.max) :
    Chunker.end c chunk out ⦃ r => room r.1 r.2 ≤ room c out ∧ r.1.partial = c.partial ⦄ := by
  unfold Chunker.end
  pstep
  all_goals
    simp_all [room, alloc.vec.Vec.length]
    try omega

@[step]
theorem is_quote_spec (s : Slice Std.U8) : is_quote s ⦃ _ => True ⦄ := by
  unfold is_quote
  pstep

@[step]
theorem cut_spec (c : Chunker) (out : Out) (h : room c out ≤ Usize.max) :
    Chunker.cut c out ⦃ r => room r.1 r.2 ≤ room c out ∧ r.1.partial = c.partial ⦄ := by
  unfold Chunker.cut
  pstep
  all_goals
    simp only [room, deref_val] at *
    try omega

@[step]
theorem cut_for_quote_spec (c : Chunker) (out : Out) (h : room c out ≤ Usize.max) :
    Chunker.cut_for_quote c out ⦃ r => room r.1 r.2 ≤ room c out ∧ r.1.partial = c.partial ⦄ := by
  unfold Chunker.cut_for_quote
  pstep
  all_goals
    simp only [room, deref_val] at *
    try omega

@[step]
theorem last_nonempty_spec (c : Chunker) : Chunker.last_nonempty c ⦃ _ => True ⦄ := by
  unfold Chunker.last_nonempty
  pstep

set_option maxHeartbeats 4000000 in
/-- What `message_line` adds to the room is twice what it takes of the line,
as a cut takes two bytes at least: a line of its own and the line before it
take one more each than their bytes. -/
@[step]
theorem message_line_spec (c : Chunker) (line : Slice Std.U8) (out : Out)
    (h : room c out + 2 * line.length + 2 ≤ Usize.max) :
    Chunker.message_line c line out ⦃ r =>
      (∀ e ∈ r.1, 0 < e.val ∧ e.val ≤ line.length ∧ room r.2.1 r.2.2 ≤ room c out + 2 * e.val) ∧
      (r.1 = none → room r.2.1 r.2.2 ≤ room c out + line.length + 1) ∧
      r.2.1.partial = c.partial ⦄ := by
  unfold Chunker.message_line
  pstep
  all_goals
    subst_vars
    opt_facts
    simp (config := { failIfUnchanged := false }) only [Option.mem_def, Option.some.injEq,
      forall_eq', reduceCtorEq, false_implies, implies_true, true_and,
      room, deref_length, alloc.vec.Vec.length, alloc.vec.Vec.new, alloc.vec.Vec.from_val,
      List.length_nil, forall_const] at *
    and_intros
  all_goals scalar_tac

/-- Where `unthink`'s loops are: the text kept is no longer than what they
have looked at, or than the line when they are done. -/
def UnthinkInv (line : Slice Std.U8) (x : Bool × alloc.vec.Vec Std.U8 × Bool × Usize × Bool) :
    Prop :=
  x.2.2.2.1.val ≤ line.length ∧ x.2.1.length ≤ line.length ∧
    (x.2.2.2.2 = false → x.2.1.length ≤ x.2.2.2.1.val)

theorem unthink_body_spec (f : Bool) (line : Slice Std.U8) (b : Bool)
    (visible : alloc.vec.Vec Std.U8) (tagged : Bool) (a : Usize) (done : Bool)
    (h : UnthinkInv line (b, visible, tagged, a, done)) :
    Chunker.unthink_loop0.body f line b visible tagged a done ⦃ r => match r with
      | .done y => y.2.1.length ≤ line.length
      | .cont x => UnthinkInv line x ∧
          line.length + 1 - x.2.2.2.1.val + (!x.2.2.2.2).toNat <
            line.length + 1 - a.val + (!done).toNat ⦄ := by
  obtain ⟨ha, hv, hd⟩ := h
  simp only at ha hv hd
  unfold Chunker.unthink_loop0.body
  cases done
  · have hv' := hd rfl
    pstep
    all_goals
      subst_vars
      opt_facts
      simp (config := { failIfUnchanged := false }) only [Option.mem_def, Option.some.injEq,
        forall_eq', UnthinkInv, alloc.vec.Vec.length, Bool.not_false,
        Bool.not_true, Bool.toNat_true, Bool.toNat_false, reduceCtorEq, false_implies,
        implies_true, and_true, forall_const] at *
      try scalar_tac
  · pstep

@[step]
theorem unthink_loop0_spec (f b : Bool) (line : Slice Std.U8) (v : alloc.vec.Vec Std.U8)
    (tagged : Bool) (a : Usize) (done : Bool) (h : UnthinkInv line (b, v, tagged, a, done)) :
    Chunker.unthink_loop0 f b line v tagged a done ⦃ r => r.2.1.length ≤ line.length ⦄ := by
  unfold Chunker.unthink_loop0
  apply loop.spec_decr_nat (fun x : Bool × alloc.vec.Vec Std.U8 × Bool × Usize × Bool =>
    line.length + 1 - x.2.2.2.1.val + (!x.2.2.2.2).toNat) (UnthinkInv line) _ _ _ ?_ h
  rintro ⟨b, v, tagged, a, done⟩ h
  dsimp only
  refine WP.spec_mono (unthink_body_spec f line b v tagged a done h) fun r hr => ?_
  cases r <;> exact hr

@[step]
theorem unthink_loop1_spec (f b : Bool) (line : Slice Std.U8) (v : alloc.vec.Vec Std.U8)
    (tagged : Bool) (a : Usize) (done : Bool) (h : UnthinkInv line (b, v, tagged, a, done)) :
    Chunker.unthink_loop1 f b line v tagged a done ⦃ r => r.2.1.length ≤ line.length ⦄ := by
  unfold Chunker.unthink_loop1
  apply loop.spec_decr_nat (fun x : Bool × alloc.vec.Vec Std.U8 × Bool × Usize × Bool =>
    line.length + 1 - x.2.2.2.1.val + (!x.2.2.2.2).toNat) (UnthinkInv line) _ _ _ ?_ h
  rintro ⟨b, v, tagged, a, done⟩ h
  dsimp only
  refine WP.spec_mono (unthink_body_spec f line b v tagged a done h) fun r hr => ?_
  cases r <;> exact hr

@[step]
theorem unthink_spec (c : Chunker) (line : Slice Std.U8) :
    Chunker.unthink c line ⦃ r => (∀ v ∈ r.1, v.length ≤ line.length) ∧ r.2.lines = c.lines ∧
      r.2.partial = c.partial ⦄ := by
  unfold Chunker.unthink
  have h0 : UnthinkInv line (c.thinking, alloc.vec.Vec.new Std.U8, false, 0#usize, false) := by
    simp [UnthinkInv, alloc.vec.Vec.length]
  pstep

@[step]
theorem classify_loop_spec (c : Chunker) (line : Slice Std.U8) (out : Out) (start : Usize)
    (done : Bool) (B : Nat) (hB : B + 2 ≤ Usize.max) (hs : start.val ≤ line.length)
    (h : (done = false ∧ room c out + 2 * (line.length - start.val) ≤ B) ∨
      (done = true ∧ room c out ≤ B + 1)) :
    Chunker.classify_loop c line out start done ⦃ r => room r.1 r.2 ≤ B + 1 ∧
      r.1.partial = c.partial ⦄ := by
  unfold Chunker.classify_loop
  apply loop.spec_decr_nat (fun x : Chunker × Out × Usize × Bool =>
      2 * (line.length - x.2.2.1.val) + (!x.2.2.2).toNat)
    (fun x : Chunker × Out × Usize × Bool => x.2.2.1.val ≤ line.length ∧
      x.1.partial = c.partial ∧
      ((x.2.2.2 = false ∧ room x.1 x.2.1 + 2 * (line.length - x.2.2.1.val) ≤ B) ∨
        (x.2.2.2 = true ∧ room x.1 x.2.1 ≤ B + 1)))
  · rintro ⟨c1, out1, start, done⟩ ⟨hs, hp, h | h⟩ <;> obtain ⟨rfl, h⟩ := h <;>
      simp only at hs hp h ⊢ <;> unfold Chunker.classify_loop.body
    · pstep
      subst_vars
      opt_facts
      simp only [Bool.not_false, Bool.toNat_true] at *
      refine ⟨by scalar_tac, by rw [o_post2, hp], Or.inl (by scalar_tac), by scalar_tac⟩
    · pstep
  · exact ⟨hs, rfl, h⟩

@[step]
theorem classify_spec (c : Chunker) (line : Slice Std.U8) (out : Out)
    (h : room c out + 2 * line.length + 2 ≤ Usize.max) :
    Chunker.classify c line out ⦃ r => room r.1 r.2 ≤ room c out + 2 * line.length + 1 ∧
      r.1.partial = c.partial ⦄ := by
  unfold Chunker.classify
  split
  · step*
  · apply classify_loop_spec _ _ _ _ _ (room c out + 2 * line.length) (by scalar_tac) (by simp)
    left
    simp

@[step]
theorem line_spec (c : Chunker) (raw : Slice Std.U8)
    (h : weight c.lines.val + 2 * raw.length + 2 ≤ Usize.max) :
    Chunker.line c raw ⦃ r => room r.2 r.1 ≤ weight c.lines.val + 2 * raw.length + 1 ∧
      r.2.partial = c.partial ⦄ := by
  unfold Chunker.line
  pstep
  all_goals
    subst_vars
    opt_facts
    simp (config := { failIfUnchanged := false }) only [room, deref_length, alloc.vec.Vec.length,
      alloc.vec.Vec.new, alloc.vec.Vec.from_val, List.length_nil, add_zero, o_post1] at *
    and_intros
  all_goals scalar_tac

@[step]
theorem take_line_loop_spec (v : alloc.vec.Vec Std.U8) (e : Usize) (he : e.val ≤ v.length) :
    Chunker.take_line_loop v e ⦃ r => r.val ≤ v.length ⦄ := by
  unfold Chunker.take_line_loop
  apply loop.spec_decr_nat (fun e : Usize => e.val) (fun e : Usize => e.val ≤ v.length) _ _ _ ?_ he
  intro e he
  unfold Chunker.take_line_loop.body
  step*

@[step]
theorem take_line_spec (c : Chunker) :
    Chunker.take_line c ⦃ r => r.1.length ≤ c.partial.length ∧ r.2.partial.length = 0 ∧
      r.2.lines = c.lines ⦄ := by
  unfold Chunker.take_line
  pstep

@[step]
theorem chunks_extend_spec (out : Out) (t : Slice (alloc.vec.Vec Std.U8))
    (h : out.length + t.length ≤ Usize.max) :
    alloc.vec.Vec.extend_from_slice (core.clone.CloneallocvecVec core.clone.CloneU8) out t
      ⦃ o => o.val = out.val ++ t.val ⦄ := by
  unfold alloc.vec.Vec.extend_from_slice
  split
  · rw [list_clone_ok _ clone_vec_ok]
    simp [WP.spec_ok]
  · contradiction

/-- The room the chunker takes, counting the text after the last newline
twice: a line can grow to twice its length in chunks. -/
abbrev held (c : Chunker) (out : Out) : Nat := 2 * c.partial.val.length + room c out

@[step]
theorem step_spec (c : Chunker) (out : Out) (b : Std.U8) (B : Nat) (hB : B + 2 ≤ Usize.max)
    (h : held c out + 2 ≤ B) :
    step c out b ⦃ r => held r.1 r.2 ≤ held c out + 2 ⦄ := by
  unfold step
  pstep
  all_goals
    simp (config := { failIfUnchanged := false }) only [held, room, deref_length, deref_val,
      alloc.vec.Vec.length] at *
    try simp only [line_post2, chunks_post1] at *
    scalar_tac

theorem steps_spec (c : Chunker) (out : Out) (bs : List Std.U8) (B : Nat)
    (hB : B + 2 ≤ Usize.max) (h : held c out + 2 * bs.length ≤ B) :
    steps c out bs ⦃ r => held r.1 r.2 ≤ B ⦄ := by
  induction bs generalizing c out with
  | nil => simpa [steps, WP.spec_ok] using h
  | cons b bs ih =>
    simp only [steps]
    apply WP.spec_bind (step_spec c out b B hB (by simp at h; omega))
    rintro ⟨c1, out1⟩ h1
    exact ih c1 out1 (by simp at h h1; omega)

@[step]
theorem push_spec (c : Chunker) (d : Slice Std.U8) (out : Out) (B : Nat) (hB : B + 2 ≤ Usize.max)
    (h : held c out + 2 * d.length ≤ B) :
    Chunker.push c d out ⦃ r => held r.1 r.2 ≤ B ⦄ := by
  rw [push_eq]
  exact steps_spec c out d.val B hB h

@[step]
theorem finish_spec (c : Chunker) (out : Out) (h : held c out + 2 ≤ Usize.max) :
    Chunker.finish c out ⦃ _ => True ⦄ := by
  unfold Chunker.finish
  pstep
  all_goals
    simp (config := { failIfUnchanged := false }) only [held, room, deref_length, deref_val,
      alloc.vec.Vec.length, alloc.vec.Vec.new, alloc.vec.Vec.from_val, List.length_nil,
      add_zero] at *
  all_goals first | assumption | scalar_tac

/-- How long a text is that arrives in `pieces`. -/
def textLength (pieces : List (Slice Std.U8)) : Nat := (pieces.map Slice.length).sum

theorem wrapper_spec (c : Chunker) (pieces : List (Slice Std.U8)) (B : Nat)
    (hB : B + 2 ≤ Usize.max) (h : held c empty + 2 * textLength pieces ≤ B) :
    wrapper c pieces ⦃ _ => True ⦄ := by
  induction pieces generalizing c with
  | nil =>
    simp only [wrapper]
    apply WP.spec_bind (finish_spec c empty (by simp [textLength] at h; omega))
    rintro ⟨_, o⟩ -
    simp [WP.spec_ok]
  | cons d ds ih =>
    simp only [wrapper]
    apply WP.spec_bind (push_spec c d empty (B - 2 * textLength ds) (by omega)
      (by simp [textLength, Slice.length] at h ⊢; omega))
    rintro ⟨c1, o⟩ h1
    apply WP.spec_bind (ih c1 ?_)
    · intro _ _
      simp [WP.spec_ok]
    · simp only [held, room, textLength, List.map_cons, List.sum_cons] at h h1 ⊢
      simp only [empty, alloc.vec.Vec.new, alloc.vec.Vec.from_val, List.length_nil] at h ⊢
      simp only [Slice.length] at h
      omega

/-! ## The chunker returns -/

unseal Result in
/-- A spec that holds says that the program returns. -/
theorem spec_exists {α : Type} {m : Result α} {p : α → Prop} (h : m ⦃ x => p x ⦄) :
    ∃ x, m = ok x ∧ p x := by
  cases m with
  | ret a => exact ⟨a, rfl, (WP.spec_ok a).mp h⟩
  | vis e k => exact ((WP.spec_vis e k).mp h).elim
  | div => exact (WP.spec_div.mp h).elim

/-- The chunker returns: however a text is streamed, `segment.rs`'s
`Chunker` neither panics nor loops, if the text is shorter than half of
`usize::MAX` bytes, so that every `Vec` it makes has room. -/
theorem returns (pieces : List (Slice Std.U8)) (h : 2 * textLength pieces + 2 ≤ Usize.max) :
    ∃ L, (do let c ← Chunker.Insts.CoreDefaultDefault.default; wrapper c pieces) = ok L := by
  have hs : (do let c ← Chunker.Insts.CoreDefaultDefault.default; wrapper c pieces) ⦃ _ => True ⦄ := by
    simp only [Chunker.Insts.CoreDefaultDefault.default, bind_ok]
    exact wrapper_spec _ pieces (2 * textLength pieces) h (by simp [held, room, empty])
  obtain ⟨L, hL, -⟩ := spec_exists hs
  exact ⟨L, hL⟩

end MaxVerify
