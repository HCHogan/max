import MaxVerify.Fences

open Aeneas Aeneas.Std Result ControlFlow
open max_core segment.chunk

/-!
# Chunks of UTF-8 are UTF-8

`chunk.rs` says: "Every position it cuts at is next to an ASCII marker or a
whole whitespace character, so the pieces of UTF-8 it cuts are UTF-8", and
`segment.rs` makes a `String` of each chunk, lossily if it isn't UTF-8.
`utf8_chunks` proves it of the chunker as `segment.rs` drives it: however a
UTF-8 text is streamed, even in pieces that split its characters, every
chunk is UTF-8, so nothing is lost.

The proof follows what the chunker holds, the text after the last newline
and the lines of the chunk being built, which stay UTF-8: every cut is
where a character starts, `Bd`, as it is at an ASCII byte, just after one,
or after a whole whitespace character. Like `Fences.lean`, it is of what
the chunker returns, if it returns. `ostep` steps through the code by the
partial specs of what it calls.
-/

namespace MaxVerify

/-! ## UTF-8

Valid UTF-8 as Lean's core has it, `ByteArray.IsValidUTF8`: the bytes of
some characters. Over the chunker's `U8`s, as numbers. -/

/-- The bytes of a character in UTF-8, as numbers. -/
def enc (c : Char) : List Nat := (String.utf8EncodeChar c).map UInt8.toNat

/-- `l` is valid UTF-8. -/
def Utf8 (l : List Std.U8) : Prop := ∃ cs : List Char, l.map (·.val) = cs.flatMap enc

/-- A continuation byte, `10xxxxxx`: never the first byte of a character. -/
def Cont (b : Nat) : Prop := 0x80 ≤ b ∧ b < 0xC0

theorem enc_cases (c : Char) :
    (∃ b, enc c = [b] ∧ b < 0x80) ∨
    (∃ b x, enc c = [b, x] ∧ 0xC0 ≤ b ∧ b < 0xE0 ∧ Cont x) ∨
    (∃ b x y, enc c = [b, x, y] ∧ 0xE0 ≤ b ∧ b < 0xF0 ∧ Cont x ∧ Cont y) ∨
    (∃ b x y z, enc c = [b, x, y, z] ∧ 0xF0 ≤ b ∧ Cont x ∧ Cont y ∧ Cont z) := by
  simp only [enc, String.utf8EncodeChar, Cont]
  split
  · left; rename_i h; simp only [List.map_cons, List.map_nil, List.cons.injEq, and_true, exists_eq_left', UInt8.toNat_ofNat']; omega
  · split
    · right; left; simp; omega
    · split
      · right; right; left; simp; omega
      · right; right; right; simp; omega

theorem enc_tail_cont (c : Char) : ∀ b ∈ (enc c).tail, Cont b := by
  rcases enc_cases c with ⟨b, h, -⟩ | ⟨b, x, h, -, -, hx⟩ | ⟨b, x, y, h, -, -, hx, hy⟩ |
      ⟨b, x, y, z, h, -, hx, hy, hz⟩ <;> rw [h] <;> simp_all

theorem utf8_nil : Utf8 [] := ⟨[], rfl⟩

theorem utf8_append {x y : List Std.U8} (hx : Utf8 x) (hy : Utf8 y) : Utf8 (x ++ y) := by
  obtain ⟨cs, hcs⟩ := hx
  obtain ⟨ds, hds⟩ := hy
  exact ⟨cs ++ ds, by simp [hcs, hds]⟩

/-- Cut where the next byte isn't a continuation byte, UTF-8 gives UTF-8. -/
theorem split_nat : ∀ (cs : List Char) (x y : List Nat), x ++ y = cs.flatMap enc →
    (∀ b ∈ y.head?, ¬Cont b) →
      (∃ cs₁ : List Char, x = cs₁.flatMap enc) ∧ (∃ cs₂ : List Char, y = cs₂.flatMap enc)
  | [], x, y, h, _ => by
    simp only [List.flatMap_nil, List.append_eq_nil_iff] at h
    exact ⟨⟨[], by simp [h.1]⟩, ⟨[], by simp [h.2]⟩⟩
  | c :: cs, x, y, h, hy => by
    rw [List.flatMap_cons] at h
    rcases List.append_eq_append_iff.mp h with ⟨a', hc, hy'⟩ | ⟨c', hx, hrest⟩
    · cases a' with
      | nil =>
        simp only [List.append_nil] at hc
        exact ⟨⟨[c], by simp [hc]⟩, ⟨cs, by simpa using hy'⟩⟩
      | cons a rest =>
        cases x with
        | nil => exact ⟨⟨[], rfl⟩, ⟨c :: cs, by simpa using h⟩⟩
        | cons x0 xs =>
          exfalso
          have ha : a ∈ (enc c).tail := by rw [hc]; simp
          exact hy a (by simp [hy']) (enc_tail_cont c a ha)
    · obtain ⟨⟨cs₁, h₁⟩, h₂⟩ := split_nat cs c' y hrest.symm hy
      exact ⟨⟨c :: cs₁, by simp [hx, h₁]⟩, h₂⟩

theorem utf8_split {x y : List Std.U8} (h : Utf8 (x ++ y)) (hy : ∀ b ∈ y.head?, ¬Cont b.val) :
    Utf8 x ∧ Utf8 y := by
  obtain ⟨cs, hcs⟩ := h
  rw [List.map_append] at hcs
  have := split_nat cs _ _ hcs (by simpa using hy)
  exact this

/-- UTF-8 that starts with the first byte of a character. -/
theorem utf8_cons {b : Std.U8} {l : List Std.U8} (h : Utf8 (b :: l)) :
    ∃ (c : Char) (cs : List Char), b.val :: l.map (·.val) = enc c ++ cs.flatMap enc := by
  obtain ⟨cs, hcs⟩ := h
  cases cs with
  | nil => simp at hcs
  | cons c cs => exact ⟨c, cs, by simpa using hcs⟩

theorem head_not_cont {b : Std.U8} {l : List Std.U8} (h : Utf8 (b :: l)) : ¬Cont b.val := by
  obtain ⟨c, cs, h⟩ := utf8_cons h
  rcases enc_cases c with ⟨b', he, hb⟩ | ⟨b', x, he, hb, -⟩ | ⟨b', x, y, he, hb, -⟩ |
      ⟨b', x, y, z, he, hb, -⟩ <;> simp only [he, List.cons_append, List.cons.injEq] at h <;>
    simp only [Cont] <;> omega

theorem utf8_drop_ascii {b : Std.U8} {l : List Std.U8} (h : Utf8 (b :: l)) (hb : b.val < 0x80) :
    Utf8 l := by
  obtain ⟨c, cs, h⟩ := utf8_cons h
  rcases enc_cases c with ⟨b', he, -⟩ | ⟨b', x, he, hb', -⟩ | ⟨b', x, y, he, hb', -⟩ |
      ⟨b', x, y, z, he, hb', -⟩ <;> simp only [he, List.cons_append, List.cons.injEq] at h
  · exact ⟨cs, by simpa using h.2⟩
  · omega
  · omega
  · omega

theorem utf8_drop_two {b x : Std.U8} {l : List Std.U8} (h : Utf8 (b :: x :: l))
    (hb : 0xC0 ≤ b.val) (hb' : b.val < 0xE0) : Utf8 l := by
  obtain ⟨c, cs, h⟩ := utf8_cons h
  rcases enc_cases c with ⟨b', he, hb''⟩ | ⟨b', x', he, -⟩ | ⟨b', x', y, he, hb'', -⟩ |
      ⟨b', x', y, z, he, hb'', -⟩ <;> simp only [he, List.cons_append, List.cons.injEq,
        List.map_cons] at h
  · omega
  · exact ⟨cs, by simpa using h.2.2⟩
  · omega
  · omega

theorem utf8_drop_three {b x y : Std.U8} {l : List Std.U8} (h : Utf8 (b :: x :: y :: l))
    (hb : 0xE0 ≤ b.val) (hb' : b.val < 0xF0) : Utf8 l := by
  obtain ⟨c, cs, h⟩ := utf8_cons h
  rcases enc_cases c with ⟨b', he, hb''⟩ | ⟨b', x', he, -, hb'', -⟩ | ⟨b', x', y', he, -⟩ |
      ⟨b', x', y', z, he, hb'', -⟩ <;> simp only [he, List.cons_append, List.cons.injEq,
        List.map_cons] at h
  · omega
  · omega
  · exact ⟨cs, by simpa using h.2.2.2⟩
  · omega

/-! ## Where characters start -/

/-- A character starts at `k` in `l`, or `l` ends there: in UTF-8, where it
can be cut. -/
def Bd (l : List Std.U8) (k : Nat) : Prop := k ≤ l.length ∧ ∀ h : k < l.length, ¬Cont l[k].val

theorem utf8_take_drop {l : List Std.U8} {k : Nat} (hl : Utf8 l) (hk : Bd l k) :
    Utf8 (l.take k) ∧ Utf8 (l.drop k) := by
  refine utf8_split (by rw [List.take_append_drop]; exact hl) fun b hb => ?_
  rw [List.head?_drop, Option.mem_def, List.getElem?_eq_some_iff] at hb
  obtain ⟨hlt, rfl⟩ := hb
  exact hk.2 hlt

theorem bd_of_drop {l : List Std.U8} {k : Nat} (hk : k ≤ l.length) (h : Utf8 (l.drop k)) :
    Bd l k := by
  refine ⟨hk, fun hlt => ?_⟩
  rw [List.drop_eq_getElem_cons hlt] at h
  exact head_not_cont h

theorem bd_zero {l : List Std.U8} (hl : Utf8 l) : Bd l 0 := bd_of_drop (by simp) (by simpa using hl)

theorem bd_length (l : List Std.U8) : Bd l l.length := ⟨le_rfl, fun h => absurd h (lt_irrefl _)⟩

theorem bd_not_cont {l : List Std.U8} {k : Nat} (hk : k < l.length) (h : ¬Cont l[k].val) :
    Bd l k := ⟨hk.le, fun _ => h⟩

theorem not_cont_ascii {b : Nat} (h : b < 0x80) : ¬Cont b := by simp only [Cont]; omega

/-- The first byte of an `n`-byte character. -/
def Lead (b : Nat) (n : Nat) : Prop :=
  (n = 1 ∧ b < 0x80) ∨ (n = 2 ∧ 0xC0 ≤ b ∧ b < 0xE0) ∨ (n = 3 ∧ 0xE0 ≤ b ∧ b < 0xF0)

theorem bd_lead {l : List Std.U8} {k n : Nat} (hl : Utf8 l) (hk : Bd l k) (hlt : k < l.length)
    (hn : k + n ≤ l.length) (h : Lead l[k].val n) : Bd l (k + n) := by
  have hd := (utf8_take_drop hl hk).2
  refine bd_of_drop hn ?_
  rcases h with ⟨rfl, h⟩ | ⟨rfl, h, h'⟩ | ⟨rfl, h, h'⟩
  · rw [List.drop_eq_getElem_cons hlt] at hd
    exact utf8_drop_ascii hd h
  · rw [List.drop_eq_getElem_cons hlt, List.drop_eq_getElem_cons (by omega)] at hd
    exact utf8_drop_two hd h h'
  · rw [List.drop_eq_getElem_cons hlt, List.drop_eq_getElem_cons (by omega),
      List.drop_eq_getElem_cons (by omega)] at hd
    exact utf8_drop_three hd h h'

/-- After an ASCII byte, a character starts. -/
theorem bd_ascii {l : List Std.U8} {k : Nat} (hl : Utf8 l) (hk : k < l.length)
    (ha : l[k].val < 0x80) : Bd l (k + 1) :=
  bd_lead hl (bd_not_cont hk (not_cont_ascii ha)) hk hk (Or.inl ⟨rfl, ha⟩)

theorem bd_drop {l : List Std.U8} {a e : Nat} (ha : a ≤ l.length) (h : Bd (l.drop a) e) :
    Bd l (a + e) := by
  obtain ⟨h1, h2⟩ := h
  simp only [List.length_drop] at h1
  refine ⟨by omega, fun hlt => ?_⟩
  have := h2 (by simp; omega)
  simpa [List.getElem_drop] using this

theorem bd_take {l : List Std.U8} {a b : Nat} (hab : a ≤ b) (h : Bd l a) : Bd (l.take b) a := by
  obtain ⟨h1, h2⟩ := h
  refine ⟨by simp; omega, fun hlt => ?_⟩
  simp only [List.getElem_take]
  exact h2 _

theorem utf8_slice {l : List Std.U8} {a b : Nat} (hl : Utf8 l) (ha : Bd l a) (hb : Bd l b)
    (hab : a ≤ b) : Utf8 (l.slice a b) := by
  have ht := (utf8_take_drop hl hb).1
  have := (utf8_take_drop ht (bd_take hab ha)).2
  rwa [List.drop_take] at this

/-! ## The scanners -/

unseal Result in
theorem Ok.of_spec {α : Type} {m : Result α} {p : α → Prop} (h : m ⦃ x => p x ⦄) : Ok m p := by
  cases m with
  | ret a => exact Ok.ret ((WP.spec_ok a).mp h)
  | vis e k => exact ((WP.spec_vis e k).mp h).elim
  | div => exact (WP.spec_div.mp h).elim

@[step]
theorem is_ascii_space_spec (b : Std.U8) :
    is_ascii_space b ⦃ r => r = true → b.val < 0x80 ⦄ := by
  unfold is_ascii_space
  step*

@[step]
theorem is_wide_space_spec (b c d : Std.U8) :
    is_wide_space b c d ⦃ r => r = true → 0xE0 ≤ b.val ∧ b.val < 0xF0 ⦄ := by
  unfold is_wide_space
  step*

/-- What `space_at` finds: nothing, or a character's first byte and its
length. -/
@[step]
theorem space_at_spec (s : Slice Std.U8) (i : Std.Usize) :
    space_at s i ⦃ n => n.val = 0 ∨ (i.val + n.val ≤ s.length ∧
      ∃ h : i.val < s.length, Lead s.val[i.val].val n.val) ⦄ := by
  unfold space_at
  step*
  all_goals first
    | (left; scalar_tac)
    | (right; refine ⟨by scalar_tac, by scalar_tac, ?_⟩; simp only [Lead]; agrind)

/-- What `space_before` finds: nothing, or something that starts a
character. -/
@[step]
theorem space_before_spec (s : Slice Std.U8) (j : Std.Usize) :
    space_before s j ⦃ n => n.val = 0 ∨ (n.val ≤ j.val ∧ j.val ≤ s.length ∧
      ∃ h : j.val - n.val < s.length, ¬Cont s.val[j.val - n.val].val) ⦄ := by
  unfold space_before
  step*
  all_goals first
    | (left; scalar_tac)
    | (right; refine ⟨by scalar_tac, by scalar_tac, by scalar_tac, ?_⟩; simp only [Cont]; agrind)

/-! ## Primitives, if they return -/

/-- `split`, through the `have`s Aeneas puts before an `if`. -/
macro "osplit" : tactic => `(tactic| ((try dsimp only); split))

theorem Ok.of_eq {α : Type} {m : Result α} {p : α → Prop} (h : ∀ x, m = ok x → p x) : Ok m p :=
  Ok.mono (Ok.self m) h

theorem add_ok (x y : Usize) : Ok (x + y) (fun z => z.val = x.val + y.val) := by
  refine Ok.of_eq fun z hz => ?_
  have h' := @UScalar.add_equiv .Usize x y
  rw [hz] at h'
  exact h'.2.1

theorem sub_ok (x y : Usize) : Ok (x - y) (fun z => z.val + y.val = x.val) := by
  refine Ok.of_eq fun z hz => ?_
  have h' := @UScalar.sub_equiv .Usize x y
  rw [hz] at h'
  exact h'.2.1.symm

theorem index_ok {α : Type} (s : Slice α) (i : Usize) :
    Ok (Slice.index_usize s i) (fun x => ∃ h : i.val < s.length, s.val[i.val] = x) := by
  refine Ok.of_eq fun x hx => ?_
  unfold Slice.index_usize at hx
  rw [Slice.getElem?_Usize_eq] at hx
  split at hx
  · simp [Result.fail_eq_vis, vis_not_ok] at hx
  · rename_i y hy
    simp only [ok_inj] at hx
    subst hx
    rw [List.getElem?_eq_some_iff] at hy
    obtain ⟨h, rfl⟩ := hy
    exact ⟨h, rfl⟩

theorem range_ok {α : Type} (s : Slice α) (a b : Usize) :
    Ok (core.slice.index.Slice.index (core.slice.index.SliceIndexRangeUsizeSlice α) s
      { start := a, «end» := b })
      (fun t => t.val = s.val.slice a.val b.val ∧ a.val ≤ b.val ∧ b.val ≤ s.length) := by
  refine Ok.of_eq fun t ht => ?_
  simp only [core.slice.index.Slice.index,
    core.slice.index.SliceIndexRangeUsizeSlice.index] at ht
  split at ht
  · rename_i h
    simp only [ok_inj] at ht
    subst ht
    exact ⟨by simp, by scalar_tac, by scalar_tac⟩
  · simp [Result.fail_eq_vis, vis_not_ok] at ht

theorem range_to_ok {α : Type} (s : Slice α) (b : Usize) :
    Ok (core.slice.index.Slice.index (core.slice.index.SliceIndexRangeToUsizeSlice α) s
      { «end» := b })
      (fun t => t.val = s.val.take b.val ∧ b.val ≤ s.length) := by
  refine Ok.of_eq fun t ht => ?_
  simp only [core.slice.index.Slice.index,
    core.slice.index.SliceIndexRangeToUsizeSlice.index] at ht
  split at ht
  · rename_i h
    simp only [ok_inj] at ht
    subst ht
    exact ⟨by simp [List.slice], by scalar_tac⟩
  · simp [Result.fail_eq_vis, vis_not_ok] at ht

theorem range_from_ok {α : Type} (s : Slice α) (a : Usize) :
    Ok (core.slice.index.Slice.index (core.slice.index.SliceIndexRangeFromUsizeSlice α) s
      { start := a })
      (fun t => t.val = s.val.drop a.val ∧ a.val ≤ s.length) := by
  refine Ok.of_eq fun t ht => ?_
  simp only [core.slice.index.Slice.index,
    core.slice.index.SliceIndexRangeFromUsizeSlice.index] at ht
  split at ht
  · rename_i h
    simp only [ok_inj] at ht
    subst ht
    exact ⟨by simp, by scalar_tac⟩
  · simp [Result.fail_eq_vis, vis_not_ok] at ht

theorem bytes_push_ok (v : alloc.vec.Vec Std.U8) (x : Std.U8) :
    Ok (alloc.vec.Vec.push v x) (fun v' => v'.val = v.val ++ [x]) := by
  refine Ok.of_eq fun v' h => ?_
  unfold alloc.vec.Vec.push at h
  dsimp only at h
  split at h
  · simp only [ok_inj] at h; subst h; simp
  · simp [Result.fail_eq_vis, vis_not_ok] at h

theorem bytes_extend_ok (v : alloc.vec.Vec Std.U8) (t : Slice Std.U8) :
    Ok (alloc.vec.Vec.extend_from_slice core.clone.CloneU8 v t)
      (fun v' => v'.val = v.val ++ t.val) := by
  refine Ok.of_eq fun v' h => ?_
  unfold alloc.vec.Vec.extend_from_slice at h
  split at h
  · rw [list_clone_ok _ (fun _ => rfl)] at h
    simp only [bind_tc_ok, ok_inj] at h
    subst h
    simp
  · simp [Result.fail_eq_vis, vis_not_ok] at h

/-! ## Finding -/

theorem starts_at_ok (s : Slice Std.U8) (p : Usize) (pat : Slice Std.U8) :
    Ok (starts_at s p pat) (fun r => r = true → pat.val <+: s.val.drop p.val) := by
  unfold starts_at
  dsimp only
  osplit
  · exact Ok.ret (by simp)
  · refine Ok.bind (sub_ok _ _) fun d hd => ?_
    osplit
    · exact Ok.ret (by simp)
    · rename_i h1 h2
      unfold starts_at_loop
      refine Ok.loop _ (fun x => x.2 = true → x.1.val ≤ pat.length ∧
        ∀ k (h : k < x.1.val) (h' : k < pat.length), s.val[p.val + k]? = some pat.val[k]) _
        ?_ _ (fun _ => ⟨by simp, fun k h => absurd h (by simp)⟩)
      rintro ⟨i, same⟩ hinv
      dsimp only at hinv ⊢
      unfold starts_at_loop.body
      osplit
      · rename_i hsame
        subst hsame
        obtain ⟨hi, hk⟩ := hinv rfl
        osplit
        · rename_i hlt
          refine Ok.bind (add_ok _ _) fun i2 hi2 => ?_
          refine Ok.bind (index_ok _ _) fun i3 ⟨_, hi3⟩ => ?_
          refine Ok.bind (index_ok _ _) fun i4 ⟨_, hi4⟩ => ?_
          refine Ok.bind (add_ok _ _) fun i5 hi5 => Ok.ret fun heq => ?_
          simp only [decide_eq_true_eq] at heq
          refine ⟨by scalar_tac, fun k hk5 hk' => ?_⟩
          by_cases hki : k < i.val
          · exact hk k hki hk'
          · have : k = i.val := by scalar_tac
            subst this
            rw [List.getElem?_eq_getElem (by scalar_tac)]
            simp only [Option.some.injEq]
            rw [hi4, ← heq, ← hi3]
            simp [hi2]
        · rename_i hge
          refine Ok.ret fun _ => ?_
          rw [List.prefix_iff_getElem?]
          intro k hk'
          rw [List.getElem?_drop]
          exact hk k (by scalar_tac) hk'
      · exact Ok.ret (by simp_all)

/-- What `find` finds is there. -/
theorem find_ok (s : Slice Std.U8) (from' : Usize) (pat : Slice Std.U8) :
    Ok (find s from' pat) (fun r => ∀ i ∈ r, from'.val ≤ i.val ∧ pat.val <+: s.val.drop i.val) := by
  unfold find
  refine Ok.bind (q := fun r : Usize × Bool => from'.val ≤ r.1.val ∧
    (r.2 = true → pat.val <+: s.val.drop r.1.val)) ?_ fun r hr => ?_
  · unfold find_loop
    refine Ok.loop _ (fun x : Usize × Bool => from'.val ≤ x.1.val ∧
      (x.2 = true → pat.val <+: s.val.drop x.1.val)) _ ?_ _ ⟨le_rfl, by simp⟩
    rintro ⟨i, found⟩ ⟨hfrom, hfound⟩
    try dsimp only at hfrom hfound ⊢
    unfold find_loop.body
    osplit
    · exact Ok.ret (by exact ⟨hfrom, hfound⟩)
    · osplit
      · refine Ok.bind (starts_at_ok _ _ _) fun b hb => ?_
        osplit
        · rename_i hb'
          exact Ok.ret (by exact ⟨hfrom, fun _ => hb hb'⟩)
        · refine Ok.bind (add_ok _ _) fun i2 hi2 => Ok.ret ?_
          dsimp only
          exact ⟨by scalar_tac, by simp_all⟩
      · exact Ok.ret (by exact ⟨hfrom, hfound⟩)
  · obtain ⟨i, found⟩ := r
    simp only [uncurry_eq]
    osplit
    · rename_i h
      exact Ok.ret fun j hj => by
        simp only [Option.mem_def, Option.some.injEq] at hj
        subst hj
        exact ⟨hr.1, hr.2 h⟩
    · exact Ok.ret (by simp)

theorem lift_ok {α : Type} (x : α) : Ok (lift x) (fun y => y = x) :=
  Ok.of_eq fun y hy => by simpa [lift, ok_inj, eq_comm] using hy

theorem lit_ok (n : Usize) (l : List Std.U8) (h : l.length = n.val) :
    Ok (lift (Array.to_slice (Array.make n l h))) (fun t => t.val = l) :=
  Ok.of_eq fun t ht => by
    simp only [lift, ok_inj] at ht
    subst ht
    simp [Array.to_slice, Array.make]

/-- `e` is just after an ASCII byte of `s`: where a character starts, in
UTF-8. -/
def AfterAscii (s : List Std.U8) (e : Nat) : Prop :=
  ∃ k, ∃ h : k < s.length, e = k + 1 ∧ s[k].val < 0x80

theorem bd_afterAscii {l : List Std.U8} {e : Nat} (hl : Utf8 l) (h : AfterAscii l e) : Bd l e := by
  obtain ⟨k, hk, rfl, ha⟩ := h
  exact bd_ascii hl hk ha

theorem afterAscii_found {s t : List Std.U8} {i : Nat} {b : Std.U8} (h : t <+: s.drop i)
    (ht : t = [b]) (hb : b.val < 0x80) : AfterAscii s (i + 1) := by
  subst ht
  have hlen := h.length_le
  simp only [List.length_singleton, List.length_drop] at hlen
  refine ⟨i, by omega, rfl, ?_⟩
  have := h.getElem (i := 0) (by simp)
  simp only [List.getElem_singleton, List.getElem_drop, Nat.add_zero] at this
  rw [← this]; exact hb

theorem Ok.ite {α : Type} {c : Prop} [Decidable c] {t e : Result α} {p : α → Prop}
    (ht : c → Ok t p) (he : ¬c → Ok e p) : Ok (if c then t else e) p := by
  by_cases h : c
  · rw [ite_eq_left_of_eq_true _ _ (eq_true h)]; exact ht h
  · rw [ite_eq_right_of_eq_false _ _ (eq_false h)]; exact he h

theorem Ok.uncurry {α β γ : Type} {k : α → β → Result γ} {x : α × β} {p : γ → Prop}
    (h : ∀ a b, x = (a, b) → Ok (k a b) p) : Ok (uncurry k x) p := by
  obtain ⟨a, b⟩ := x
  exact h a b rfl

open Lean Meta Elab Tactic in
/-- `split` for a `match` on a variable that a program in an `Ok` goal
starts with. It reduces only that `match`, where `split` simplifies the
whole goal, which runs out of steps on the larger functions. -/
elab "ok_cases" : tactic => do
  let g ← getMainGoal
  g.withContext do
    let ty ← instantiateMVars (← g.getType)
    let some (_, m, _) := ty.app3? ``MaxVerify.Ok | throwError "ok_cases: not an `Ok` goal"
    let m := m.consumeMData
    let some app ← matchMatcherApp? m |
      throwError "ok_cases: no match in {m.getAppFn} {m.getAppNumArgs} {m.ctorName}"
    let #[d] := app.discrs | throwError "ok_cases: more than one discriminant"
    unless d.isFVar do throwError "ok_cases: the discriminant isn't a variable"
    let subgoals ← g.cases d.fvarId!
    let gs ← subgoals.toList.mapM fun sg => sg.mvarId.withContext do
      let ty ← instantiateMVars (← sg.mvarId.getType)
      let some (α, m, p) := ty.app3? ``MaxVerify.Ok | throwError "ok_cases: lost the goal"
      match ← reduceMatcher? m.consumeMData with
      | ReduceMatcherResult.reduced m' =>
        sg.mvarId.replaceTargetDefEq (mkApp3 (mkConst ``MaxVerify.Ok) α m'.headBeta p)
      | _ => throwError "ok_cases: the match didn't reduce"
    replaceMainGoal gs

/-- One step through code in an `Ok` goal: by the partial spec of what it
calls, or past what it calls, keeping only that it returned. Rules added
later are tried first. -/
syntax "ostep1" : tactic

macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.then_; intro _ _))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| ok_cases)
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible refine Ok.uncurry fun _ _ h => ?_; subst h))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.ite <;> intro _))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (lift_ok _); intro _ _))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (lit_ok _ _ _); intro _ _))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (add_ok _ _); intro _ _))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (sub_ok _ _); intro _ _))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (index_ok _ _); intro _ _))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (find_ok _ _ _); intro _ _))
macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (starts_at_ok _ _ _); intro _ _))

macro "ostep" : tactic => `(tactic| repeat' ostep1)

/-- After a byte that `find` found. -/
theorem afterAscii_find {s t : Slice Std.U8} {q e f : Usize} {b : Std.U8}
    (he : e.val = q.val + (1#usize).val)
    (hf : ∀ i ∈ some q, f.val ≤ i.val ∧ t.val <+: s.val.drop i.val) (ht : t.val = [b])
    (hb : b.val < 0x80 := by decide) : AfterAscii s.val e.val := by
  rw [he]
  exact afterAscii_found (hf q rfl).2 ht hb

/-- After a `]` that `closer` looked at. -/
theorem afterAscii_index {s : Slice Std.U8} {q e : Usize} {b : Std.U8}
    (he : e.val = q.val + (1#usize).val) (hi : ∃ h : q.val < s.length, s.val[q.val] = b)
    (hb : ¬(b != 93#u8) = true) : AfterAscii s.val e.val := by
  obtain ⟨h, rfl⟩ := hi
  simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hb
  refine ⟨q.val, h, by simpa using he, ?_⟩
  rw [hb]; decide

/-- `closer` ends after an ASCII byte. -/
theorem closer_ok (s : Slice Std.U8) (p : Usize) :
    Ok (closer s p) (fun r => ∀ x ∈ r, AfterAscii s.val x.2.val) := by
  unfold closer
  ostep
  all_goals refine Ok.ret fun x hx => ?_
  all_goals first
    | (simp at hx; done)
    | (simp only [Option.mem_def, Option.some.injEq] at hx
       subst hx
       first
         | exact afterAscii_find ‹_› ‹_› ‹_›
         | exact afterAscii_index ‹_› ‹_› ‹_›)

theorem afterAscii_len {s : Slice Std.U8} {a i c e : Usize} (hi : i.val + a.val = e.val)
    (hc : ∀ x ∈ some (c, e), AfterAscii s.val x.2.val) : AfterAscii s.val (a.val + i.val) := by
  rw [Nat.add_comm, hi]
  exact hc _ rfl

macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (closer_ok _ _); intro _ _))

/-- A placeholder ends after an ASCII byte. -/
theorem placeholder_ok (s : Slice Std.U8) (p : Usize) :
    Ok (placeholder s p) (fun r => ∀ P ∈ r, AfterAscii s.val (p.val + P.len.val)) := by
  unfold placeholder
  ostep
  all_goals (apply Ok.ret; intro P hP)
  all_goals first
    | (simp at hP; done)
    | (simp only [Option.mem_def, Option.some.injEq] at hP
       subst hP
       exact afterAscii_len ‹_› ‹_›)

macro_rules
  | `(tactic| ostep1) =>
    `(tactic| (with_reducible apply Ok.bind (placeholder_ok _ _); intro _ _))

/-- A picture's handle ends after an ASCII byte. -/
theorem picture_ok (s : Slice Std.U8) (p : Usize) :
    Ok (picture s p) (fun r => ∀ len ∈ r, AfterAscii s.val (p.val + len.val)) := by
  unfold picture
  refine Ok.bind (placeholder_ok _ _) fun o ho => ?_
  ok_cases
  · exact Ok.ret (by simp)
  · rename_i P
    split <;> refine Ok.ret fun len hlen => ?_ <;> simp only [Option.mem_def,
      reduceCtorEq, Option.some.injEq] at hlen
    subst hlen
    exact ho P rfl

/-! ## Where a line is cut -/

/-- A cut at `a`, of `len` bytes: from an ASCII byte to just after one. -/
def Cut (l : List Std.U8) (a len : Nat) : Prop :=
  (∃ h : a < l.length, l[a].val < 0x80) ∧ AfterAscii l (a + len)

theorem cut_of_prefix {l t : List Std.U8} {i : Nat} (h : t <+: l.drop i) (ht : t ≠ [])
    (ha : ∀ b ∈ t, b.val < 0x80) : Cut l i t.length := by
  have hlen := h.length_le
  simp only [List.length_drop] at hlen
  have hpos : 0 < t.length := List.length_pos_iff.mpr ht
  have get : ∀ k (hk : k < t.length), ∃ h' : i + k < l.length, l[i + k] = t[k] := by
    intro k hk
    have := h.getElem hk
    simp only [List.getElem_drop] at this
    exact ⟨by omega, this.symm⟩
  obtain ⟨h0, e0⟩ := get 0 hpos
  obtain ⟨h1, e1⟩ := get (t.length - 1) (by omega)
  refine ⟨⟨by omega, ?_⟩, ⟨i + (t.length - 1), h1, by omega, ?_⟩⟩
  · simp only [Nat.add_zero] at e0
    rw [e0]; exact ha _ (List.getElem_mem _)
  · rw [e1]; exact ha _ (List.getElem_mem _)

abbrev SPLIT : List Std.U8 := [91#u8, 115#u8, 112#u8, 108#u8, 105#u8, 116#u8, 93#u8]

theorem next_cut_loop0_ok (line : Slice Std.U8) (spans : alloc.vec.Vec (Usize × Usize))
    (split : Usize) (has : Bool) (h : has = true → SPLIT <+: line.val.drop split.val) :
    Ok (next_cut_loop0 line spans split has)
      (fun r => r.2 = true → SPLIT <+: line.val.drop r.1.val) := by
  unfold next_cut_loop0
  refine Ok.loop _ (fun x : Usize × Bool => x.2 = true → SPLIT <+: line.val.drop x.1.val) _ ?_ _ h
  rintro ⟨split, has⟩ hinv
  try dsimp only at hinv ⊢
  unfold next_cut_loop0.body
  ostep
  all_goals refine Ok.ret ?_
  all_goals simp_all

theorem next_cut_loop1_ok (line : Slice Std.U8) (spans : alloc.vec.Vec (Usize × Usize))
    (pic len : Usize) (has : Bool) (h : has = true → Cut line.val pic.val len.val) :
    Ok (next_cut_loop1 line spans pic len has)
      (fun r => r.2.2 = true → Cut line.val r.1.val r.2.1.val) := by
  unfold next_cut_loop1
  refine Ok.loop _ (fun x : Usize × Usize × Bool => x.2.2 = true → Cut line.val x.1.val x.2.1.val)
    _ ?_ _ h
  rintro ⟨pic, len, has⟩ hinv
  try dsimp only at hinv ⊢
  unfold next_cut_loop1.body
  refine Ok.ite (fun _ => Ok.ret ?_) (fun hhas => ?_)
  · exact hinv
  refine Ok.ite (fun hlt => ?_) (fun _ => Ok.ret hinv)
  refine Ok.bind (index_ok _ _) fun i1 ⟨hi1, hi1'⟩ => ?_
  refine Ok.bind (q := fun found : Option Usize => ∀ l ∈ found, i1 = 91#u8 ∧
    AfterAscii line.val (pic.val + l.val)) ?_ fun found hf => ?_
  · refine Ok.ite (fun h91 => ?_) (fun _ => Ok.ret (by simp))
    refine Ok.then_ fun _ _ => Ok.ite (fun _ => ?_) (fun _ => Ok.ret (by simp))
    exact Ok.mono (picture_ok _ _) fun r hr l hl => ⟨h91, hr l hl⟩
  · ok_cases
    · exact Ok.bind (add_ok _ _) fun _ _ => Ok.ret (by simp_all)
    · rename_i l
      obtain ⟨h91, ha⟩ := hf l rfl
      refine Ok.ret fun _ => ⟨⟨hi1, ?_⟩, ha⟩
      rw [hi1', h91]; decide

theorem next_cut_ok (line : Slice Std.U8) :
    Ok (next_cut line) (fun r => ∀ x ∈ r, Cut line.val x.1.val x.2.1.val) := by
  unfold next_cut
  refine Ok.then_ fun spans _ => ?_
  refine Ok.bind (next_cut_loop0_ok _ _ _ _ (by simp)) fun r0 h0 => ?_
  obtain ⟨split, has_split⟩ := r0
  refine Ok.bind (next_cut_loop1_ok _ _ _ _ _ (by simp)) fun r1 h1 => ?_
  obtain ⟨pic, len, has_pic⟩ := r1
  simp only [uncurry_eq] at h0 h1 ⊢
  have hs : has_split = true → Cut line.val split.val (7#usize).val := fun h =>
    cut_of_prefix (h0 h) (by simp) (by decide)
  repeat' first
    | (refine Ok.ite (fun _ => ?_) (fun _ => ?_))
  all_goals refine Ok.ret fun x hx => ?_
  all_goals first
    | (simp at hx; done)
    | (simp only [Option.mem_def, Option.some.injEq] at hx
       subst hx
       first | exact h1 ‹_› | exact hs ‹_›)

/-! ## Chunks -/

theorem bd_lead_of_eq {t : Slice Std.U8} {l : List Std.U8} {k n : Nat} (htv : t.val = l)
    (hl : Utf8 l) (hk : Bd l k) (hlt : k < t.length) (hn : k + n ≤ t.length)
    (h : Lead (t.val[k]'hlt).val n) : Bd l (k + n) := by
  subst htv; exact bd_lead hl hk hlt hn h

theorem trim_loop0_ok (s : Slice Std.U8) (to' : Usize) (a : Usize) (moving : Bool)
    (ht : Utf8 (s.val.take to'.val)) (ha : a.val ≤ to'.val)
    (hb : Bd (s.val.take to'.val) a.val) :
    Ok (trim_loop0 s to' a moving)
      (fun r => a.val ≤ r.val ∧ r.val ≤ to'.val ∧ Bd (s.val.take to'.val) r.val) := by
  unfold trim_loop0
  refine Ok.loop _ (fun x : Usize × Bool => a.val ≤ x.1.val ∧ x.1.val ≤ to'.val ∧
    Bd (s.val.take to'.val) x.1.val) _ ?_ _ ⟨le_rfl, ha, hb⟩
  rintro ⟨a', moving⟩ ⟨h1, h2, h3⟩
  try dsimp only at h1 h2 h3 ⊢
  unfold trim_loop0.body
  refine Ok.ite (fun _ => Ok.ite (fun hlt => ?_) (fun _ => Ok.ret ⟨h1, h2, h3⟩))
    (fun _ => Ok.ret ⟨h1, h2, h3⟩)
  refine Ok.bind (range_to_ok _ _) fun t ⟨htv, _⟩ => ?_
  refine Ok.bind (Ok.of_spec (space_at_spec _ _)) fun n hn => ?_
  refine Ok.ite (fun _ => Ok.ret ⟨h1, h2, h3⟩) (fun hn0 => ?_)
  refine Ok.bind (add_ok _ _) fun a1 ha1 => Ok.ret ?_
  rcases hn with hn | ⟨hle, hlt', hlead⟩
  · exact absurd (by scalar_tac) hn0
  have hlen : t.length = to'.val := by simp [Slice.length, htv]; omega
  dsimp only
  refine ⟨by scalar_tac, by scalar_tac, ?_⟩
  rw [ha1]
  exact bd_lead_of_eq htv ht h3 hlt' hle hlead

theorem trim_loop1_ok (s : Slice Std.U8) (a to' : Usize) (moving : Bool) (b : Usize)
    (hab : a.val ≤ b.val) (hbt : b.val ≤ to'.val) (hto : to'.val ≤ s.length)
    (hb : Bd (s.val.take to'.val) b.val) :
    Ok (trim_loop1 s a moving b)
      (fun r => a.val ≤ r.val ∧ r.val ≤ to'.val ∧ Bd (s.val.take to'.val) r.val) := by
  unfold trim_loop1
  refine Ok.loop _ (fun x : Bool × Usize => a.val ≤ x.2.val ∧ x.2.val ≤ to'.val ∧
    Bd (s.val.take to'.val) x.2.val) _ ?_ _ ⟨hab, hbt, hb⟩
  rintro ⟨moving, b'⟩ ⟨h1, h2, h3⟩
  try dsimp only at h1 h2 h3 ⊢
  unfold trim_loop1.body
  refine Ok.ite (fun _ => Ok.ite (fun hlt => ?_) (fun _ => Ok.ret ⟨h1, h2, h3⟩))
    (fun _ => Ok.ret ⟨h1, h2, h3⟩)
  refine Ok.bind (range_from_ok _ _) fun t ⟨htv, _⟩ => ?_
  refine Ok.bind (sub_ok _ _) fun i hi => ?_
  refine Ok.bind (Ok.of_spec (space_before_spec _ _)) fun n hn => ?_
  refine Ok.ite (fun _ => Ok.ret ⟨h1, h2, h3⟩) (fun hn0 => ?_)
  refine Ok.bind (sub_ok _ _) fun b1 hb1 => Ok.ret ?_
  rcases hn with hn | ⟨hni, hit, hlt', hnc⟩
  · exact absurd (by scalar_tac) hn0
  have hlen : b1.val < (s.val.take to'.val).length := by simp; scalar_tac
  dsimp only
  refine ⟨by scalar_tac, by scalar_tac, bd_not_cont hlen ?_⟩
  have : t.val[i.val - n.val]'hlt' = (s.val.take to'.val)[b1.val] := by
    simp only [htv, List.getElem_drop, List.getElem_take]
    congr 1; scalar_tac
  rw [← this]; exact hnc

theorem trim_ok (s : Slice Std.U8) (from' to' : Usize) (hto : to'.val ≤ s.length)
    (ht : Utf8 (s.val.take to'.val)) (hf : from'.val ≤ to'.val)
    (hb : Bd (s.val.take to'.val) from'.val) :
    Ok (trim s from' to') (fun r => r.1.val ≤ r.2.val ∧ r.2.val ≤ to'.val ∧
      Bd (s.val.take to'.val) r.1.val ∧ Bd (s.val.take to'.val) r.2.val) := by
  unfold trim
  refine Ok.bind (trim_loop0_ok _ _ _ _ ht hf hb) fun a ⟨_, ha, hba⟩ => ?_
  refine Ok.bind (trim_loop1_ok _ _ _ _ _ ha le_rfl hto
    (by simpa [Nat.min_eq_left hto] using bd_length (s.val.take to'.val))) fun b ⟨hab, hb', hbb⟩ => ?_
  exact Ok.ret ⟨hab, hb', hba, hbb⟩

theorem utf8_newline : Utf8 [10#u8] := ⟨['\n'], rfl⟩

theorem vec_range_ok {α : Type} (v : alloc.vec.Vec α) (a b : Usize) :
    Ok (alloc.vec.Vec.index (core.slice.index.SliceIndexRangeUsizeSlice α) v
      { start := a, «end» := b })
      (fun t => t.val = v.val.slice a.val b.val ∧ a.val ≤ b.val ∧ b.val ≤ v.length) :=
  range_ok v.slice a b

theorem chunk_text_loop_ok (lines : Slice (alloc.vec.Vec Std.U8)) (text : alloc.vec.Vec Std.U8)
    (i : Usize) (hl : ∀ l ∈ lines.val, Utf8 l.val) (ht : Utf8 text.val) :
    Ok (chunk_text_loop lines text i) (fun r => Utf8 r.val) := by
  unfold chunk_text_loop
  refine Ok.loop _ (fun x : alloc.vec.Vec Std.U8 × Usize => Utf8 x.1.val) _ ?_ _ ht
  rintro ⟨text, i⟩ ht
  try dsimp only at ht ⊢
  unfold chunk_text_loop.body
  refine Ok.ite (fun _ => ?_) (fun _ => Ok.ret ht)
  refine Ok.bind (q := fun t : alloc.vec.Vec Std.U8 => Utf8 t.val)
    (Ok.ite (fun _ => Ok.mono (bytes_push_ok _ _) fun t h => by
      rw [h]; exact utf8_append ht utf8_newline) (fun _ => Ok.ret ht)) fun t1 ht1 => ?_
  refine Ok.bind (index_ok _ _) fun v ⟨_, hv⟩ => ?_
  refine Ok.bind (bytes_extend_ok _ _) fun t2 ht2 => ?_
  refine Ok.bind (add_ok _ _) fun _ _ => Ok.ret ?_
  dsimp only
  rw [ht2]
  refine utf8_append ht1 ?_
  have := hl v (by rw [← hv]; exact List.getElem_mem _)
  simpa [alloc.vec.Vec.deref] using this

/-- A chunk of UTF-8 lines is UTF-8. -/
theorem chunk_text_ok (lines : Slice (alloc.vec.Vec Std.U8)) (hl : ∀ l ∈ lines.val, Utf8 l.val) :
    Ok (chunk_text lines) (fun c => Utf8 c.val) := by
  unfold chunk_text
  refine Ok.bind (chunk_text_loop_ok _ _ _ hl utf8_nil) fun text ht => ?_
  have hd : (alloc.vec.Vec.deref text).val = text.val := by simp [alloc.vec.Vec.deref]
  have hlen : (alloc.vec.Vec.len text).val = text.val.length := alloc.vec.Vec.len_val text
  have ht' : Utf8 ((alloc.vec.Vec.deref text).val.take (alloc.vec.Vec.len text).val) := by
    rw [hd, hlen, List.take_length]; exact ht
  refine Ok.bind (trim_ok _ _ _ (by simp [Slice.length, hd, hlen]) ht' (by simp)
    (bd_zero ht')) fun r ⟨hab, hb, ha', hb'⟩ => ?_
  obtain ⟨a, b⟩ := r
  refine Ok.uncurry fun a' b' hr => ?_
  simp only [Prod.mk.injEq] at hr
  obtain ⟨rfl, rfl⟩ := hr
  rw [hd, hlen, List.take_length] at ha' hb'
  refine Ok.bind (vec_range_ok _ _ _) fun t ⟨htv, _⟩ => ?_
  refine Ok.mono (bytes_extend_ok _ _) fun c hc => ?_
  rw [hc, htv]
  simpa using utf8_slice ht ha' hb' hab

/-! ## The chunker -/

/-- What the chunker holds is UTF-8: the text after the last newline, and
the lines of the chunk being built. -/
def Held (c : Chunker) : Prop := Utf8 c.partial.val ∧ ∀ l ∈ c.lines.val, Utf8 l.val

/-- The chunks sent are UTF-8. -/
def AllUtf8 (out : Out) : Prop := ∀ x ∈ out.val, Utf8 x.val

theorem push_line_utf8 (c : Chunker) (line : Slice Std.U8) (hc : Held c)
    (hl : Utf8 line.val) : Ok (Chunker.push_line c line) Held := by
  unfold Chunker.push_line
  refine Ok.then_ fun _ _ => Ok.then_ fun _ _ => Ok.then_ fun _ _ => ?_
  refine Ok.bind (bytes_extend_ok _ _) fun copy hcopy => ?_
  refine Ok.then_ fun v hv => Ok.ret ⟨hc.1, fun l hl' => ?_⟩
  rw [push_ok hv, List.mem_append, List.mem_singleton] at hl'
  rcases hl' with hl' | rfl
  · exact hc.2 l hl'
  · rw [hcopy]; simpa using hl

theorem end_utf8 (c : Chunker) (chunk : alloc.vec.Vec Std.U8) (out : Out) (hc : Held c)
    (hch : Utf8 chunk.val) (hout : AllUtf8 out) :
    Ok (Chunker.end c chunk out) (fun r => Held r.1 ∧ AllUtf8 r.2) := by
  unfold Chunker.end
  refine Ok.then_ fun _ _ => ?_
  split
  · exact Ok.ret ⟨⟨hc.1, fun l hl => by simp at hl⟩, hout⟩
  · refine Ok.then_ fun out' h => Ok.ret ⟨⟨hc.1, fun l hl => by simp at hl⟩, fun x hx => ?_⟩
    rw [push_ok h, List.mem_append, List.mem_singleton] at hx
    rcases hx with hx | rfl
    · exact hout x hx
    · exact hch

theorem cut_utf8 (c : Chunker) (out : Out) (hc : Held c) (hout : AllUtf8 out) :
    Ok (Chunker.cut c out) (fun r => Held r.1 ∧ AllUtf8 r.2) := by
  unfold Chunker.cut
  refine Ok.bind (chunk_text_ok _ (by simpa [alloc.vec.Vec.deref] using hc.2)) fun chunk hch => ?_
  refine Ok.then_ fun _ _ => ?_
  split
  · exact end_utf8 _ _ _ hc hch hout
  · exact Ok.ret ⟨hc, hout⟩

theorem Ok.uncurry_mk {α β γ : Type} {k : α → β → Result γ} {a : α} {b : β} {p : γ → Prop}
    (h : Ok (k a b) p) : Ok (Std.uncurry k (a, b)) p := h

/-- What `message_line` pushes is UTF-8, and it returns where a character
starts. -/
theorem message_line_utf8 (c : Chunker) (line : Slice Std.U8) (out : Out) (hc : Held c)
    (hout : AllUtf8 out) (hl : Utf8 line.val) :
    Ok (Chunker.message_line c line out)
      (fun r => (∀ e ∈ r.1, Bd line.val e.val) ∧ Held r.2.1 ∧ AllUtf8 r.2.2) := by
  unfold Chunker.message_line
  refine Ok.then_ fun _ _ => Ok.then_ fun o _ => ?_
  refine Ok.bind (q := fun r : Chunker × Out × Usize => Held r.1 ∧ AllUtf8 r.2.1) ?_
    fun ⟨c1, out1, shown⟩ ⟨hc1, hout1⟩ => ?_
  · ok_cases
    · exact Ok.ret ⟨hc, hout⟩
    · refine Ok.bind (cut_utf8 c out hc hout) fun ⟨c2, out2⟩ ⟨hc2, hout2⟩ => ?_
      refine Ok.uncurry_mk ?_
      exact Ok.then_ fun _ _ => Ok.then_ fun _ _ => Ok.ret ⟨hc2, hout2⟩
  refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
  refine Ok.then_ fun text _ => Ok.then_ fun b _ => Ok.ite (fun _ => ?_) (fun _ => ?_)
  · exact Ok.bind (push_line_utf8 _ _ hc1 hl) fun c2 hc2 => Ok.ret (by exact ⟨by simp, hc2, hout1⟩)
  refine Ok.then_ fun b1 _ => Ok.ite (fun _ => ?_) (fun _ => ?_)
  · exact Ok.bind (cut_utf8 _ _ hc1 hout1) fun ⟨c2, out2⟩ ⟨hc2, hout2⟩ =>
      Ok.uncurry_mk (Ok.ret (by exact ⟨by simp, hc2, hout2⟩))
  refine Ok.then_ fun b2 _ => Ok.ite (fun _ => ?_) (fun _ => ?_)
  · refine Ok.ite (fun _ => ?_) (fun _ => ?_)
    · refine Ok.then_ fun b3 _ => Ok.ite (fun _ => ?_)
        (fun _ => Ok.ret (by exact ⟨by simp, hc1, hout1⟩))
      exact Ok.bind (push_line_utf8 _ _ hc1 (by simpa [alloc.vec.Vec.deref] using utf8_nil))
        fun c2 hc2 => Ok.ret (by exact ⟨by simp, hc2, hout1⟩)
    · exact Ok.bind (cut_utf8 _ _ hc1 hout1) fun ⟨c2, out2⟩ ⟨hc2, hout2⟩ =>
        Ok.uncurry_mk (Ok.ret (by exact ⟨by simp, hc2, hout2⟩))
  refine Ok.then_ fun b3 _ => ?_
  refine Ok.bind (q := fun r : Chunker × Out => Held r.1 ∧ AllUtf8 r.2) ?_
    fun ⟨c2, out2⟩ ⟨hc2, hout2⟩ => ?_
  · refine Ok.ite (fun _ => ?_) (fun _ => Ok.ret ⟨hc1, hout1⟩)
    exact Ok.bind (cut_utf8 _ _ hc1 hout1) fun ⟨c3, out3⟩ ⟨hc3, hout3⟩ =>
      Ok.uncurry_mk (Ok.ret ⟨hc3, hout3⟩)
  refine Ok.uncurry_mk ?_
  refine Ok.bind (next_cut_ok _) fun o1 ho1 => ?_
  ok_cases
  · exact Ok.bind (push_line_utf8 _ _ hc2 hl) fun c3 hc3 => Ok.ret (by exact ⟨by simp, hc3, hout2⟩)
  rename_i t
  obtain ⟨at1, len, pic⟩ := t
  obtain ⟨⟨hat, hat'⟩, hend⟩ := ho1 _ rfl
  have hbat : Bd line.val at1.val := bd_not_cont hat (not_cont_ascii hat')
  have hbend : Bd line.val (at1.val + len.val) := bd_afterAscii hl hend
  refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
  refine Ok.bind (range_to_ok _ _) fun s ⟨hs, _⟩ => ?_
  refine Ok.bind (push_line_utf8 _ _ hc2 (by rw [hs]; exact (utf8_take_drop hl hbat).1))
    fun c3 hc3 => ?_
  refine Ok.bind (cut_utf8 _ _ hc3 hout2) fun ⟨c4, out3⟩ ⟨hc4, hout3⟩ => ?_
  refine Ok.uncurry_mk ?_
  refine Ok.bind (q := fun r : Chunker × Out => Held r.1 ∧ AllUtf8 r.2) ?_
    fun ⟨c5, out4⟩ ⟨hc5, hout4⟩ => ?_
  · refine Ok.ite (fun _ => ?_) (fun _ => Ok.ret ⟨hc4, hout3⟩)
    refine Ok.bind (add_ok _ _) fun i1 hi1 => ?_
    refine Ok.bind (range_ok _ _ _) fun s1 ⟨hs1, _⟩ => ?_
    refine Ok.bind (push_line_utf8 _ _ hc4 ?_) fun c6 hc6 => cut_utf8 _ _ hc6 hout3
    rw [hs1, hi1]
    exact utf8_slice hl hbat hbend (by omega)
  refine Ok.uncurry_mk ?_
  refine Ok.bind (add_ok _ _) fun i1 hi1 => Ok.ret ?_
  refine ⟨?_, hc5, hout4⟩
  intro e he
  simp only [Option.mem_def, Option.some.injEq] at he
  subst he
  rw [hi1]; exact hbend

theorem classify_loop_utf8 (c : Chunker) (line : Slice Std.U8) (out : Out) (start : Usize)
    (done : Bool) (hc : Held c) (hout : AllUtf8 out) (hl : Utf8 line.val)
    (hs : Bd line.val start.val) :
    Ok (Chunker.classify_loop c line out start done) (fun r => Held r.1 ∧ AllUtf8 r.2) := by
  unfold Chunker.classify_loop
  refine Ok.loop _ (fun x : Chunker × Out × Usize × Bool => Held x.1 ∧ AllUtf8 x.2.1 ∧
    Bd line.val x.2.2.1.val) _ ?_ _ ⟨hc, hout, hs⟩
  rintro ⟨c, out, start, done⟩ ⟨hc, hout, hs⟩
  try dsimp only at hc hout hs ⊢
  unfold Chunker.classify_loop.body
  refine Ok.ite (fun _ => Ok.ret ⟨hc, hout⟩) (fun _ => ?_)
  refine Ok.bind (range_from_ok _ _) fun t ⟨ht, hle⟩ => ?_
  have htu : Utf8 t.val := by rw [ht]; exact (utf8_take_drop hl hs).2
  refine Ok.bind (message_line_utf8 _ _ _ hc hout htu) fun ⟨o, c1, out1⟩ ⟨ho, hc1, hout1⟩ => ?_
  refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
  ok_cases
  · exact Ok.ret ⟨hc1, hout1, hs⟩
  · refine Ok.bind (add_ok _ _) fun s1 hs1 => Ok.ret ⟨hc1, hout1, ?_⟩
    have := ho _ rfl
    rw [ht] at this
    dsimp only
    rw [hs1]
    exact bd_drop hle this

theorem classify_utf8 (c : Chunker) (line : Slice Std.U8) (out : Out) (hc : Held c)
    (hout : AllUtf8 out) (hl : Utf8 line.val) :
    Ok (Chunker.classify c line out) (fun r => Held r.1 ∧ AllUtf8 r.2) := by
  unfold Chunker.classify
  split
  · exact Ok.bind (push_line_utf8 _ _ hc hl) fun c1 hc1 => Ok.ret ⟨hc1, hout⟩
  · exact classify_loop_utf8 _ _ _ _ _ hc hout hl (bd_zero hl)

abbrev THINK : List Std.U8 := [60#u8, 116#u8, 104#u8, 105#u8, 110#u8, 107#u8, 62#u8]
abbrev THINK_END : List Std.U8 := [60#u8, 47#u8, 116#u8, 104#u8, 105#u8, 110#u8, 107#u8, 62#u8]

/-- Where `find` finds a tag, a character starts, and another after it. -/
theorem bd_tag {line : Slice Std.U8} {t : Slice Std.U8} {tag : List Std.U8} {a p : Usize}
    (hl : Utf8 line.val) (ht : t.val = tag) (hne : tag ≠ []) (ha : ∀ b ∈ tag, b.val < 0x80)
    (hf : ∀ i ∈ some p, a.val ≤ i.val ∧ t.val <+: line.val.drop i.val) :
    a.val ≤ p.val ∧ Bd line.val p.val ∧ Bd line.val (p.val + tag.length) := by
  obtain ⟨hap, hpre⟩ := hf p rfl
  rw [ht] at hpre
  obtain ⟨⟨hp, hp'⟩, hend⟩ := cut_of_prefix hpre hne ha
  exact ⟨hap, bd_not_cont hp (not_cont_ascii hp'), bd_afterAscii hl hend⟩

/-- The two loops of `unthink`, which are the same. -/
theorem unthink_body_utf8 (line : Slice Std.U8) (hl : Utf8 line.val) (b : Bool)
    (visible : alloc.vec.Vec Std.U8) (tagged : Bool) (a : Usize) (done : Bool)
    (hv : Utf8 visible.val) (ha : Bd line.val a.val) :
    Ok (Chunker.unthink_loop0.body line b visible tagged a done)
      (fun r => match r with
        | .cont x => Bd line.val x.2.2.2.1.val ∧ Utf8 x.2.1.val
        | .done y => Utf8 y.2.1.val) := by
  unfold Chunker.unthink_loop0.body
  refine Ok.ite (fun _ => Ok.ret hv) (fun _ => ?_)
  refine Ok.bind (q := fun found : Option Usize => ∀ p ∈ found, a.val ≤ p.val ∧
    Bd line.val p.val ∧ Bd line.val (p.val + if b then 8 else 7)) ?_ fun found hf => ?_
  · refine Ok.ite (fun hb => ?_) (fun hb => ?_)
    · refine Ok.bind (lit_ok _ _ _) fun t ht => Ok.mono (find_ok _ _ _) fun r hr p hp => ?_
      subst hp
      simpa [hb] using bd_tag (tag := THINK_END) hl ht (by simp) (by decide) hr
    · refine Ok.bind (lit_ok _ _ _) fun t ht => Ok.mono (find_ok _ _ _) fun r hr p hp => ?_
      subst hp
      simpa [hb] using bd_tag (tag := THINK) hl ht (by simp) (by decide) hr
  ok_cases
  · refine Ok.ite (fun _ => Ok.ret ⟨ha, hv⟩) (fun _ => ?_)
    refine Ok.bind (range_from_ok _ _) fun t ⟨ht, _⟩ => ?_
    refine Ok.bind (bytes_extend_ok _ _) fun v1 hv1 => Ok.ret ⟨ha, ?_⟩
    dsimp only
    rw [hv1, ht]; exact utf8_append hv (utf8_take_drop hl ha).2
  · rename_i p
    obtain ⟨hap, hp, hp'⟩ := hf p rfl
    refine Ok.bind (q := fun v : alloc.vec.Vec Std.U8 => Utf8 v.val) ?_ fun v1 hv1 => ?_
    · refine Ok.ite (fun _ => Ok.ret hv) (fun _ => ?_)
      refine Ok.bind (range_ok _ _ _) fun t ⟨ht, _⟩ => Ok.mono (bytes_extend_ok _ _) fun v2 hv2 => ?_
      rw [hv2, ht]; exact utf8_append hv (utf8_slice hl ha hp hap)
    refine Ok.bind (q := fun i : Usize => i.val = if b then 8 else 7) ?_ fun i hi => ?_
    · refine Ok.ite (fun hb => Ok.ret (by simp [hb])) (fun hb => Ok.ret (by simp [hb]))
    refine Ok.bind (add_ok _ _) fun a1 ha1 => Ok.ret ⟨?_, hv1⟩
    dsimp only
    rw [ha1, hi]; exact hp'

theorem unthink_loop0_utf8 (b : Bool) (line : Slice Std.U8) (hl : Utf8 line.val)
    (visible : alloc.vec.Vec Std.U8) (tagged : Bool) (a : Usize) (done : Bool)
    (hv : Utf8 visible.val) (ha : Bd line.val a.val) :
    Ok (Chunker.unthink_loop0 b line visible tagged a done) (fun r => Utf8 r.2.1.val) := by
  unfold Chunker.unthink_loop0
  refine Ok.loop _ (fun x : Bool × alloc.vec.Vec Std.U8 × Bool × Usize × Bool =>
    Bd line.val x.2.2.2.1.val ∧ Utf8 x.2.1.val) _ ?_ _ ⟨ha, hv⟩
  rintro ⟨b, visible, tagged, a, done⟩ ⟨ha, hv⟩
  dsimp only
  refine Ok.mono (unthink_body_utf8 line hl b visible tagged a done hv ha) fun r hr => ?_
  cases r <;> exact hr

theorem unthink_loop1_utf8 (b : Bool) (line : Slice Std.U8) (hl : Utf8 line.val)
    (visible : alloc.vec.Vec Std.U8) (tagged : Bool) (a : Usize) (done : Bool)
    (hv : Utf8 visible.val) (ha : Bd line.val a.val) :
    Ok (Chunker.unthink_loop1 b line visible tagged a done) (fun r => Utf8 r.2.1.val) := by
  unfold Chunker.unthink_loop1
  refine Ok.loop _ (fun x : Bool × alloc.vec.Vec Std.U8 × Bool × Usize × Bool =>
    Bd line.val x.2.2.2.1.val ∧ Utf8 x.2.1.val) _ ?_ _ ⟨ha, hv⟩
  rintro ⟨b, visible, tagged, a, done⟩ ⟨ha, hv⟩
  dsimp only
  refine Ok.mono (unthink_body_utf8 line hl b visible tagged a done hv ha) fun r hr => ?_
  cases r <;> exact hr

theorem unthink_utf8 (c : Chunker) (line : Slice Std.U8) (hc : Held c) (hl : Utf8 line.val) :
    Ok (Chunker.unthink c line) (fun r => (∀ v ∈ r.1, Utf8 v.val) ∧ Held r.2) := by
  unfold Chunker.unthink
  have hv0 : Utf8 (alloc.vec.Vec.new Std.U8).val := by simpa using utf8_nil
  refine Ok.ite (fun _ => ?_) (fun _ => ?_)
  · refine Ok.bind (unthink_loop0_utf8 _ _ hl _ _ _ _ hv0 (bd_zero hl)) fun ⟨b, v, t⟩ hv => ?_
    refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
    repeat' (refine Ok.ite (fun _ => ?_) (fun _ => ?_))
    all_goals refine Ok.ret ⟨fun x hx => ?_, hc⟩
    all_goals first
      | (simp at hx; done)
      | (simp only [Option.mem_def, Option.some.injEq] at hx; subst hx; exact hv)
  · refine Ok.bind (lit_ok _ _ _) fun _ _ => Ok.then_ fun o _ => ?_
    refine Ok.ite (fun _ => ?_) (fun _ => ?_)
    · refine Ok.bind (bytes_extend_ok _ _) fun v hv => Ok.ret ⟨fun x hx => ?_, hc⟩
      simp only [Option.mem_def, Option.some.injEq] at hx
      subst hx
      simpa [hv] using hl
    · refine Ok.bind (unthink_loop1_utf8 _ _ hl _ _ _ _ hv0 (bd_zero hl)) fun ⟨b, v, t⟩ hv => ?_
      refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
      repeat' (refine Ok.ite (fun _ => ?_) (fun _ => ?_))
      all_goals refine Ok.ret ⟨fun x hx => ?_, hc⟩
      all_goals first
        | (simp at hx; done)
        | (simp only [Option.mem_def, Option.some.injEq] at hx; subst hx; exact hv)

/-- The chunks a UTF-8 line completes are UTF-8. -/
theorem line_utf8 (c : Chunker) (raw : Slice Std.U8) (hc : Held c) (hr : Utf8 raw.val) :
    Ok (Chunker.line c raw) (fun r => AllUtf8 r.1 ∧ Held r.2) := by
  unfold Chunker.line
  refine Ok.bind (unthink_utf8 _ _ hc hr) fun ⟨o, c1⟩ ⟨ho, hc1⟩ => ?_
  refine Ok.uncurry_mk ?_
  ok_cases
  · exact Ok.ret ⟨fun x hx => by simp at hx, hc1⟩
  · have hv := ho _ rfl
    refine Ok.bind (classify_utf8 _ _ _ hc1 (fun x hx => by simp at hx)
      (by simpa [alloc.vec.Vec.deref] using hv)) fun ⟨c2, out⟩ ⟨hc2, hout⟩ => ?_
    exact Ok.uncurry_mk (Ok.ret ⟨hout, hc2⟩)

theorem vec_index_ok {α : Type} (v : alloc.vec.Vec α) (i : Usize) :
    Ok (alloc.vec.Vec.index (core.slice.index.SliceIndexUsizeSlice α) v i)
      (fun x => ∃ h : i.val < v.length, v.val[i.val] = x) :=
  index_ok v.slice i

theorem vec_range_to_ok {α : Type} (v : alloc.vec.Vec α) (b : Usize) :
    Ok (alloc.vec.Vec.index (core.slice.index.SliceIndexRangeToUsizeSlice α) v { «end» := b })
      (fun t => t.val = v.val.take b.val ∧ b.val ≤ v.length) :=
  range_to_ok v.slice b

theorem take_line_loop_ok (v : alloc.vec.Vec Std.U8) (e : Usize) (he : e.val ≤ v.length)
    (hr : ∀ h : e.val < v.length, v.val[e.val] = 13#u8) :
    Ok (Chunker.take_line_loop v e)
      (fun r => r.val ≤ v.length ∧ ∀ h : r.val < v.length, v.val[r.val] = 13#u8) := by
  unfold Chunker.take_line_loop
  refine Ok.loop _ (fun e : Usize => e.val ≤ v.length ∧ ∀ h : e.val < v.length,
    v.val[e.val] = 13#u8) _ ?_ _ ⟨he, hr⟩
  intro e ⟨he, hr⟩
  unfold Chunker.take_line_loop.body
  refine Ok.ite (fun _ => ?_) (fun _ => Ok.ret ⟨he, hr⟩)
  refine Ok.bind (sub_ok _ _) fun i hi => ?_
  refine Ok.bind (vec_index_ok _ _) fun b ⟨hb, hb'⟩ => ?_
  refine Ok.ite (fun h13 => Ok.ret ⟨by scalar_tac, fun _ => by rw [hb', h13]⟩)
    (fun _ => Ok.ret ⟨he, hr⟩)

/-- The line before a newline is UTF-8, if the text after the last newline
is. -/
theorem take_line_utf8 (c : Chunker) (hp : Utf8 c.partial.val)
    (hl : ∀ l ∈ c.lines.val, Utf8 l.val) :
    Ok (Chunker.take_line c) (fun r => Utf8 r.1.val ∧ Held r.2) := by
  unfold Chunker.take_line
  refine Ok.bind (take_line_loop_ok _ _ (by simp) (fun h => absurd h (by simp))) fun e ⟨he, hr⟩ => ?_
  refine Ok.bind (vec_range_to_ok _ _) fun t ⟨ht, _⟩ => ?_
  refine Ok.bind (bytes_extend_ok _ _) fun line hline => Ok.ret ⟨?_, ⟨by simpa using utf8_nil, hl⟩⟩
  have hb : Bd c.partial.val e.val := ⟨he, fun h => by rw [hr h]; exact not_cont_ascii (by decide)⟩
  rw [hline, ht]
  simpa using (utf8_take_drop hp hb).1

theorem allUtf8_extend {out chunks out' : Out} (hout : AllUtf8 out) (hc : AllUtf8 chunks)
    (h : extend out chunks = ok out') : AllUtf8 out' := by
  intro x hx
  rw [(extend_eq_ok out chunks out').mp h, List.mem_append] at hx
  exact hx.elim (hout x) (hc x)

/-- A byte: what the chunker holds and the text to come stay UTF-8. -/
theorem step_utf8 (c : Chunker) (out : Out) (b : Std.U8) (rest : List Std.U8)
    (hl : ∀ l ∈ c.lines.val, Utf8 l.val) (hout : AllUtf8 out)
    (hp : Utf8 (c.partial.val ++ b :: rest)) :
    Ok (step c out b) (fun r => (∀ l ∈ r.1.lines.val, Utf8 l.val) ∧ AllUtf8 r.2 ∧
      Utf8 (r.1.partial.val ++ rest)) := by
  unfold step
  split
  · rename_i h10
    subst h10
    obtain ⟨hpart, hnl⟩ := utf8_split hp (by simp [Cont])
    have hrest := utf8_drop_ascii hnl (by decide)
    refine Ok.bind (take_line_utf8 _ hpart hl) fun ⟨line, c1⟩ ⟨hline, hc1⟩ => ?_
    refine Ok.uncurry_mk ?_
    refine Ok.bind (line_utf8 _ _ hc1 (by simpa [alloc.vec.Vec.deref] using hline))
      fun ⟨chunks, c2⟩ ⟨hch, hc2⟩ => ?_
    refine Ok.uncurry_mk ?_
    refine Ok.then_ fun out' h => Ok.ret ⟨hc2.2, allUtf8_extend hout hch h, ?_⟩
    exact utf8_append hc2.1 hrest
  · refine Ok.bind (bytes_push_ok _ _) fun v hv => Ok.ret ⟨hl, hout, ?_⟩
    dsimp only
    rw [hv, List.append_assoc]
    exact hp

theorem steps_utf8 (c : Chunker) (out : Out) (bs rest : List Std.U8)
    (hl : ∀ l ∈ c.lines.val, Utf8 l.val) (hout : AllUtf8 out)
    (hp : Utf8 (c.partial.val ++ bs ++ rest)) :
    Ok (steps c out bs) (fun r => (∀ l ∈ r.1.lines.val, Utf8 l.val) ∧ AllUtf8 r.2 ∧
      Utf8 (r.1.partial.val ++ rest)) := by
  induction bs generalizing c out with
  | nil => exact Ok.ret ⟨hl, hout, by simpa using hp⟩
  | cons b bs ih =>
    simp only [steps]
    refine Ok.bind (step_utf8 c out b (bs ++ rest) hl hout (by simpa using hp))
      fun ⟨c1, out1⟩ ⟨hl1, hout1, hp1⟩ => ?_
    exact ih c1 out1 hl1 hout1 (by simpa using hp1)

theorem push_utf8 (c : Chunker) (d : Slice Std.U8) (out : Out) (rest : List Std.U8)
    (hl : ∀ l ∈ c.lines.val, Utf8 l.val) (hout : AllUtf8 out)
    (hp : Utf8 (c.partial.val ++ d.val ++ rest)) :
    Ok (Chunker.push c d out) (fun r => (∀ l ∈ r.1.lines.val, Utf8 l.val) ∧ AllUtf8 r.2 ∧
      Utf8 (r.1.partial.val ++ rest)) := by
  rw [push_eq]
  exact steps_utf8 c out d.val rest hl hout hp

/-- At the end, if the text after the last newline is UTF-8, so are the
chunks. -/
theorem finish_utf8 (c : Chunker) (out : Out) (hc : Held c) (hout : AllUtf8 out) :
    Ok (Chunker.finish c out) (fun r => AllUtf8 r.2) := by
  unfold Chunker.finish
  have hnew : AllUtf8 (alloc.vec.Vec.new (alloc.vec.Vec Std.U8)) := fun x hx => by simp at hx
  refine Ok.then_ fun _ _ => ?_
  refine Ok.bind (q := fun r : Chunker × Out => Held r.1 ∧ AllUtf8 r.2) ?_
    fun ⟨c1, chunks⟩ ⟨hc1, hch⟩ => ?_
  · refine Ok.ite (fun _ => Ok.ret ⟨hc, hnew⟩) (fun _ => ?_)
    refine Ok.bind (bytes_extend_ok _ _) fun r hr => ?_
    refine Ok.bind (line_utf8 _ _ ⟨by simpa using utf8_nil, hc.2⟩
      (by simpa [alloc.vec.Vec.deref, hr] using hc.1)) fun ⟨chunks1, c2⟩ ⟨hch1, hc2⟩ => ?_
    exact Ok.uncurry_mk (Ok.ret ⟨hc2, hch1⟩)
  refine Ok.uncurry_mk ?_
  refine Ok.bind (chunk_text_ok _ (by simpa [alloc.vec.Vec.deref] using hc1.2)) fun last hlast => ?_
  refine Ok.bind (end_utf8 _ _ _ hc1 hlast hch) fun ⟨c2, chunks1⟩ ⟨_, hch1⟩ => ?_
  refine Ok.uncurry_mk ?_
  exact Ok.then_ fun out' h => Ok.ret (allUtf8_extend hout hch1 h)

/-- The chunks as `segment.rs` gets them are UTF-8, if the text is. -/
theorem wrapper_utf8 (c : Chunker) (pieces : List (Slice Std.U8))
    (hl : ∀ l ∈ c.lines.val, Utf8 l.val)
    (hp : Utf8 (c.partial.val ++ (pieces.map Slice.val).flatten)) :
    Ok (wrapper c pieces) (fun L => ∀ x ∈ L, Utf8 x.val) := by
  induction pieces generalizing c with
  | nil =>
    simp only [wrapper]
    refine Ok.bind (finish_utf8 c empty ⟨by simpa using hp, hl⟩ (fun x hx => by simp at hx))
      fun ⟨_, o⟩ ho => ?_
    exact Ok.uncurry_mk (Ok.ret ho)
  | cons d ds ih =>
    simp only [wrapper]
    refine Ok.bind (push_utf8 c d empty (ds.map Slice.val).flatten hl (fun x hx => by simp at hx)
      (by simpa using hp)) fun ⟨c1, o⟩ ⟨hl1, ho, hp1⟩ => ?_
    refine Ok.uncurry_mk ?_
    refine Ok.bind (ih c1 hl1 hp1) fun L hL => Ok.ret fun x hx => ?_
    rcases List.mem_append.mp hx with hx | hx
    · exact ho x hx
    · exact hL x hx

/-! ## Chunks of UTF-8 are UTF-8 -/

/-- Chunks of UTF-8 are UTF-8: however a UTF-8 text is streamed, even in
pieces that split its characters, every chunk that `segment.rs`'s `Chunker`
sends is UTF-8. -/
theorem utf8_chunks (pieces : List (Slice Std.U8)) (h : Utf8 (pieces.map Slice.val).flatten)
    (L : List (alloc.vec.Vec Std.U8))
    (hw : (do let c ← Chunker.Insts.CoreDefaultDefault.default; wrapper c pieces) = ok L) :
    ∀ x ∈ L, Utf8 x.val := by
  simp only [Chunker.Insts.CoreDefaultDefault.default, bind_ok] at hw
  exact (wrapper_utf8 _ pieces (fun l hl => by simp at hl) (by simpa using h)).result hw

theorem utf8_flatten (pieces : List (Slice Std.U8)) (h : ∀ d ∈ pieces, Utf8 d.val) :
    Utf8 (pieces.map Slice.val).flatten := by
  induction pieces with
  | nil => exact utf8_nil
  | cons d ds ih =>
    simp only [List.map_cons, List.flatten_cons]
    exact utf8_append (h d (by simp)) (ih fun d' hd' => h d' (by simp [hd']))

/-- As `segment.rs` streams it: in `&str`s. -/
theorem utf8_chunks_of_strs (pieces : List (Slice Std.U8)) (h : ∀ d ∈ pieces, Utf8 d.val)
    (L : List (alloc.vec.Vec Std.U8))
    (hw : (do let c ← Chunker.Insts.CoreDefaultDefault.default; wrapper c pieces) = ok L) :
    ∀ x ∈ L, Utf8 x.val :=
  utf8_chunks pieces (utf8_flatten pieces h) L hw

end MaxVerify
