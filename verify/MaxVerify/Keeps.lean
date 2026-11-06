import MaxVerify.Returns

open Aeneas Aeneas.Std Result ControlFlow
open max_core segment.chunk

/-!
# Nothing is dropped

`keeps` proves that the chunker, as `segment.rs` drives it, drops nothing of
a text but `<think>` spans, then whitespace, `[split]`s and breaks: however
the text is streamed, the chunks hold, newlines aside, its lines outside
`<think>` spans, each cut at its `[split]`s and around its pictures'
handles, with breaks gone and whitespace taken out of the rest, in order.
A quote before a break stays, and goes out with the next message.
`Keeps` says it, and is all that a reader needs to read.

`Keeps` allows a little more than the chunker does, so that it reads simply:

* Newlines are left out on both sides: the chunker joins a chunk's lines
  with them, and drops the ones it cuts at.
* A `[split]` may go wherever it is; the chunker cuts only at one outside
  code.
* A `<think>` may open a span wherever it is, or stay; the chunker opens one
  only outside code.
-/

namespace MaxVerify

/-! ## What may go -/

/-- One whitespace character, as `space_at` and `space_before` read one:
Unicode's `White_Space`, which a test in `chunk.rs` checks. -/
def IsSpace (w : List Std.U8) : Prop :=
  (∃ b, w = [b] ∧ is_ascii_space b = ok true) ∨
  w = [194#u8, 133#u8] ∨ w = [194#u8, 160#u8] ∨
  (∃ b c d, w = [b, c, d] ∧ is_wide_space b c d = ok true)

/-- Whitespace characters, one after another. -/
inductive Spaces : List Std.U8 → Prop
  | nil : Spaces []
  | cons {w s : List Std.U8} : IsSpace w → Spaces s → Spaces (w ++ s)

/-- `t` is `s` with some of its whitespace characters taken out. -/
inductive Dels : List Std.U8 → List Std.U8 → Prop
  | nil : Dels [] []
  | keep (b : Std.U8) {s t : List Std.U8} : Dels s t → Dels (b :: s) (b :: t)
  | drop {w s t : List Std.U8} : IsSpace w → Dels s t → Dels (w ++ s) t

/-- `t` is what is left of `s` outside `<think>` spans, `th` saying whether
`s` starts in one, and `th'` whether it ends in one. A span runs from a
`<think>` to the first `</think>` after it, or to the end; a `<think>` need
not open one, as one in code doesn't. A newline in one
may stay, as one does where a span crosses lines: the line it starts on
stays a line. The `\r`s that end a line may go. -/
inductive Unthink : Bool → List Std.U8 → List Std.U8 → Bool → Prop
  | nil (th : Bool) : Unthink th [] [] th
  | keep {b : Std.U8} {s t : List Std.U8} {th : Bool} :
      Unthink false s t th → Unthink false (b :: s) (b :: t) th
  | crs {rs s t : List Std.U8} {th : Bool} : (∀ r ∈ rs, r = 13#u8) →
      Unthink false s t th → Unthink false (rs ++ 10#u8 :: s) (10#u8 :: t) th
  | enter {s t : List Std.U8} {th : Bool} :
      Unthink true s t th → Unthink false (THINK ++ s) t th
  | leave {s t : List Std.U8} {th : Bool} :
      Unthink false s t th → Unthink true (THINK_END ++ s) t th
  | skip {b : Std.U8} {s t : List Std.U8} {th : Bool} :
      ¬THINK_END <+: b :: s → Unthink true s t th → Unthink true (b :: s) t th
  | newline {s t : List Std.U8} {th : Bool} :
      Unthink true s t th → Unthink true (10#u8 :: s) (10#u8 :: t) th

/-- A picture's handle, as `picture` finds one in `l`: `n` bytes at `a`. -/
def Picture (l : List Std.U8) (a n : Nat) : Prop :=
  ∃ (s : Slice Std.U8) (a' n' : Usize), s.val = l ∧ a'.val = a ∧ n'.val = n ∧
    picture s a' = ok (some n')

/-- A break: `---`, `***` or `___`, spaces allowed between, as `is_break`
judges it. -/
def Break (b : List Std.U8) : Prop := ∃ t : Slice Std.U8, t.val = b ∧ is_break t = ok true

/-- A line, or what follows a cut in one, and the pieces kept of it: it is
cut at its `[split]`s, which go, and around its pictures' handles, which
are messages of their own; a break goes, with the whitespace before it, but
not what comes before that, as a quote. -/
inductive Msg : List Std.U8 → List (List Std.U8) → Prop
  | whole (m : List Std.U8) : Msg m [m]
  | brk (p : List Std.U8) {w b : List Std.U8} : Spaces w → Break b → Msg (p ++ w ++ b) [p]
  | split {p m : List Std.U8} {ps : List (List Std.U8)} :
      Msg m ps → Msg (p ++ SPLIT ++ m) (p :: ps)
  | pic {p q m : List Std.U8} {ps : List (List Std.U8)} :
      Picture (p ++ q ++ m) p.length q.length → Msg m ps → Msg (p ++ q ++ m) (p :: q :: ps)

/-- Nothing of `text` is dropped in `chunks` but `<think>` spans, then
whitespace, `[split]`s and break lines: newlines aside, the chunks hold the
lines of the text outside `<think>` spans, `vs`, cut into pieces, with
whitespace taken out of each piece. -/
def Keeps (text : List Std.U8) (chunks : List (List Std.U8)) : Prop :=
  ∃ (vs : List (List Std.U8)) (th : Bool), (∀ v ∈ vs, 10#u8 ∉ v) ∧
    Unthink false text ([10#u8].intercalate vs) th ∧
    ∃ pss, List.Forall₂ Msg vs pss ∧ ∃ cs, List.Forall₂ Dels pss.flatten cs ∧
      chunks.flatten.filter (· ≠ 10#u8) = cs.flatten

/-! ## Whitespace -/

theorem spec_eq {α : Type} {m : Result α} {p : α → Prop} {x : α} (h : m ⦃ y => p y ⦄)
    (hm : m = ok x) : p x :=
  (Ok.of_spec h).result hm

theorem is_wide_space_bytes (b c d : Std.U8) :
    is_wide_space b c d ⦃ r => r = true → 0xE0 ≤ b.val ∧ 0x80 ≤ c.val ∧ 0x80 ≤ d.val ⦄ := by
  unfold is_wide_space
  step*

/-- A whitespace character with a newline in it is a newline. -/
theorem IsSpace.nl {w : List Std.U8} (h : IsSpace w) (hw : 10#u8 ∈ w) : w = [10#u8] := by
  rcases h with ⟨b, rfl, _⟩ | rfl | rfl | ⟨b, c, d, rfl, hw'⟩
  · simp only [List.mem_singleton] at hw; rw [hw]
  · simp at hw
  · simp at hw
  · have := spec_eq (is_wide_space_bytes b c d) hw' rfl
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hw
    rcases hw with rfl | rfl | rfl <;> simp at this

theorem IsSpace.ne_nil {w : List Std.U8} (h : IsSpace w) : w ≠ [] := by
  rcases h with ⟨b, rfl, _⟩ | rfl | rfl | ⟨b, c, d, rfl, _⟩ <;> simp

theorem Spaces.append {s t : List Std.U8} (hs : Spaces s) (ht : Spaces t) : Spaces (s ++ t) := by
  induction hs with
  | nil => exact ht
  | cons hw _ ih => rw [List.append_assoc]; exact Spaces.cons hw ih

theorem Spaces.one {w : List Std.U8} (h : IsSpace w) : Spaces w := by
  simpa using Spaces.cons h Spaces.nil

theorem Dels.refl : ∀ s : List Std.U8, Dels s s
  | [] => Dels.nil
  | b :: s => Dels.keep b (Dels.refl s)

theorem Dels.append {a b c d : List Std.U8} (h₁ : Dels a b) (h₂ : Dels c d) :
    Dels (a ++ c) (b ++ d) := by
  induction h₁ with
  | nil => exact h₂
  | keep x _ ih => exact Dels.keep x ih
  | drop hw _ ih => rw [List.append_assoc]; exact Dels.drop hw ih

theorem Dels.spaces_left {p s t : List Std.U8} (hp : Spaces p) (h : Dels s t) : Dels (p ++ s) t := by
  induction hp with
  | nil => exact h
  | cons hw _ ih => rw [List.append_assoc]; exact Dels.drop hw ih

theorem Spaces.dels {s : List Std.U8} (h : Spaces s) : Dels s [] := by
  simpa using Dels.spaces_left h Dels.nil

theorem Dels.spaces_right {s t q : List Std.U8} (h : Dels s t) (hq : Spaces q) : Dels (s ++ q) t := by
  simpa using Dels.append h hq.dels

/-- Trimmed at both ends. -/
theorem Dels.trim {p m q : List Std.U8} (hp : Spaces p) (hq : Spaces q) : Dels (p ++ m ++ q) m :=
  (Dels.spaces_left hp (Dels.refl m)).spaces_right hq

theorem Dels.sublist {s t : List Std.U8} (h : Dels s t) : t.Sublist s := by
  induction h with
  | nil => exact List.Sublist.slnil
  | keep x _ ih => exact ih.cons_cons x
  | drop _ _ ih => exact ih.trans (List.sublist_append_right _ _)

theorem Dels.nil_left {t : List Std.U8} (h : Dels [] t) : t = [] :=
  List.eq_nil_of_sublist_nil h.sublist

/-- A newline in what loses whitespace stays, or goes as whitespace, but as
a character of its own. -/
theorem Dels.split_nl {x y z : List Std.U8} (h : Dels (x ++ 10#u8 :: y) z) (hx : 10#u8 ∉ x) :
    ∃ z₁ z₂, Dels x z₁ ∧ Dels y z₂ ∧ (z = z₁ ++ 10#u8 :: z₂ ∨ z = z₁ ++ z₂) := by
  generalize hs : x ++ 10#u8 :: y = s at h
  induction h generalizing x with
  | nil => simp at hs
  | keep b hd ih =>
    rename_i s t
    cases x with
    | nil =>
      simp only [List.nil_append, List.cons.injEq] at hs
      obtain ⟨rfl, rfl⟩ := hs
      exact ⟨[], t, Dels.nil, hd, Or.inl rfl⟩
    | cons a x =>
      simp only [List.cons_append, List.cons.injEq] at hs
      obtain ⟨rfl, hs⟩ := hs
      obtain ⟨z₁, z₂, h₁, h₂, h₃⟩ := ih (fun h => hx (List.mem_cons_of_mem _ h)) hs
      refine ⟨a :: z₁, z₂, Dels.keep a h₁, h₂, ?_⟩
      rcases h₃ with rfl | rfl <;> simp
  | drop hw hd ih =>
    rename_i w s t
    rcases List.append_eq_append_iff.mp hs with ⟨a', rfl, ha⟩ | ⟨c', rfl, rfl⟩
    · cases a' with
      | nil =>
        simp only [List.nil_append] at ha
        obtain ⟨z₁, z₂, h₁, h₂, h₃⟩ := ih (x := []) (by simp) (by simpa using ha)
        exact ⟨z₁, z₂, by simpa using Dels.drop hw h₁, h₂, h₃⟩
      | cons e a'' =>
        simp only [List.cons_append, List.cons.injEq] at ha
        obtain ⟨rfl, rfl⟩ := ha
        have hn := hw.nl (by simp)
        cases x with
        | nil =>
          cases a'' with
          | nil => exact ⟨[], t, Dels.nil, hd, Or.inr rfl⟩
          | cons _ _ => simp at hn
        | cons _ _ => simp at hn
    · obtain ⟨z₁, z₂, h₁, h₂, h₃⟩ := ih (fun h => hx (List.mem_append_right _ h)) rfl
      exact ⟨z₁, z₂, Dels.drop hw h₁, h₂, h₃⟩

theorem filter_nl_eq {l : List Std.U8} (h : 10#u8 ∉ l) : l.filter (· ≠ 10#u8) = l :=
  List.filter_eq_self.mpr fun _ hb => decide_eq_true fun e => h (e ▸ hb)

/-- What whitespace is taken out of lines joined by newlines is taken out of
each line, but for the newlines. -/
theorem dels_intercalate : ∀ (ls : List (List Std.U8)) {C : List Std.U8},
    (∀ l ∈ ls, 10#u8 ∉ l) → Dels ([10#u8].intercalate ls) C →
    ∃ cs, List.Forall₂ Dels ls cs ∧ C.filter (· ≠ 10#u8) = cs.flatten
  | [], C, _, h => by
    simp only [List.intercalate_nil] at h
    rw [h.nil_left]
    exact ⟨[], .nil, rfl⟩
  | [l], C, hl, h => by
    simp only [List.intercalate_singleton] at h
    refine ⟨[C], .cons h .nil, ?_⟩
    rw [filter_nl_eq fun hC => hl l (by simp) (h.sublist.subset hC)]
    simp
  | l :: l' :: ls, C, hl, h => by
    rw [List.intercalate_cons_cons, List.append_assoc, List.singleton_append] at h
    have hl0 : 10#u8 ∉ l := hl l (by simp)
    obtain ⟨z₁, z₂, h₁, h₂, h₃⟩ := h.split_nl hl0
    obtain ⟨cs, hcs, hf⟩ := dels_intercalate (l' :: ls)
      (fun x hx => hl x (List.mem_cons_of_mem _ hx)) h₂
    have hz : 10#u8 ∉ z₁ := fun hz => hl0 (h₁.sublist.subset hz)
    refine ⟨z₁ :: cs, .cons h₁ hcs, ?_⟩
    rcases h₃ with rfl | rfl
    · rw [List.filter_append, filter_nl_eq hz, List.filter_cons_of_neg (by decide), hf]
      simp
    · rw [List.filter_append, filter_nl_eq hz, hf]
      simp

/-! ## What the chunker holds -/

/-- The lines held for pieces: a piece's own, or for a blank one an empty
line or none. -/
inductive HeldL : List (List Std.U8) → List (List Std.U8) → Prop
  | nil : HeldL [] []
  | own (p : List Std.U8) {ps ls : List (List Std.U8)} : HeldL ps ls → HeldL (p :: ps) (p :: ls)
  | empty {p : List Std.U8} {ps ls : List (List Std.U8)} :
      Spaces p → HeldL ps ls → HeldL (p :: ps) ([] :: ls)
  | none {p : List Std.U8} {ps ls : List (List Std.U8)} :
      Spaces p → HeldL ps ls → HeldL (p :: ps) ls

theorem HeldL.append {ps ls qs ms : List (List Std.U8)} (h₁ : HeldL ps ls) (h₂ : HeldL qs ms) :
    HeldL (ps ++ qs) (ls ++ ms) := by
  induction h₁ with
  | nil => exact h₂
  | own p _ ih => exact HeldL.own p ih
  | empty hp _ ih => exact HeldL.empty hp ih
  | none hp _ ih => exact HeldL.none hp ih

/-- What whitespace is taken out of the lines held is taken out of their
pieces. -/
theorem HeldL.dels {ps ls : List (List Std.U8)} (h : HeldL ps ls) :
    ∀ {cl : List (List Std.U8)}, List.Forall₂ Dels ls cl →
      ∃ cs, List.Forall₂ Dels ps cs ∧ cs.flatten = cl.flatten := by
  induction h with
  | nil => intro cl hcl; cases hcl; exact ⟨[], .nil, rfl⟩
  | own p _ ih =>
    intro cl hcl
    cases hcl with
    | cons hc hcl =>
      obtain ⟨cs, hcs, hf⟩ := ih hcl
      exact ⟨_, .cons hc hcs, by simp [hf]⟩
  | empty hp _ ih =>
    intro cl hcl
    cases hcl with
    | cons hc hcl =>
      obtain ⟨cs, hcs, hf⟩ := ih hcl
      rw [hc.nil_left]
      exact ⟨[] :: cs, .cons hp.dels hcs, by simp [hf]⟩
  | none hp _ ih =>
    intro cl hcl
    obtain ⟨cs, hcs, hf⟩ := ih hcl
    exact ⟨[] :: cs, .cons hp.dels hcs, by simp [hf]⟩

/-- The chunks sent, `sent`, hold the pieces `ps`, with whitespace taken out,
newlines aside. -/
def Sent (sent ps : List (List Std.U8)) : Prop :=
  ∃ cs, List.Forall₂ Dels ps cs ∧ sent.flatten.filter (· ≠ 10#u8) = cs.flatten

abbrev vals (v : alloc.vec.Vec (alloc.vec.Vec Std.U8)) : List (List Std.U8) := v.val.map (·.val)

/-- What the chunker has sent, `sent`, and the lines it holds are the pieces
`ps`. -/
def Inv (c : Chunker) (sent ps : List (List Std.U8)) : Prop :=
  (∀ l ∈ vals c.lines, 10#u8 ∉ l) ∧
    ∃ ps₁ ps₂, ps = ps₁ ++ ps₂ ∧ Sent sent ps₁ ∧ HeldL ps₂ (vals c.lines)

/-- What only `unthink` and `step` change. -/
def Same (c c' : Chunker) : Prop := c'.thinking = c.thinking ∧ c'.partial = c.partial

theorem Same.rfl' (c : Chunker) : Same c c := ⟨rfl, rfl⟩

theorem Same.trans {c₁ c₂ c₃ : Chunker} (h₁ : Same c₁ c₂) (h₂ : Same c₂ c₃) : Same c₁ c₃ :=
  ⟨h₂.1.trans h₁.1, h₂.2.trans h₁.2⟩

@[simp] theorem vals_new : vals (alloc.vec.Vec.new (alloc.vec.Vec Std.U8)) = [] := rfl

/-- A blank piece, which the chunker holds no line for. -/
theorem Inv.blank {c : Chunker} {sent ps : List (List Std.U8)} {p : List Std.U8}
    (h : Inv c sent ps) (hp : Spaces p) : Inv c sent (ps ++ [p]) := by
  obtain ⟨hl, ps₁, ps₂, rfl, hs, hh⟩ := h
  exact ⟨hl, ps₁, ps₂ ++ [p], by simp, hs, by simpa using hh.append (HeldL.none hp HeldL.nil)⟩

/-! ## Whitespace, as the scanners find it -/

theorem slice_one {l : List Std.U8} {i : Nat} (h : i < l.length) : l.slice i (i + 1) = [l[i]] := by
  rw [List.slice, List.drop_eq_getElem_cons h]
  simp only [Nat.add_sub_cancel_left, List.take_succ_cons, List.take_zero]

theorem slice_two {l : List Std.U8} {i : Nat} (h : i + 1 < l.length) :
    l.slice i (i + 2) = [l[i], l[i + 1]] := by
  rw [List.slice, List.drop_eq_getElem_cons (show i < l.length by omega),
    List.drop_eq_getElem_cons h]
  simp only [Nat.add_sub_cancel_left, List.take_succ_cons, List.take_zero]

theorem slice_three {l : List Std.U8} {i : Nat} (h : i + 2 < l.length) :
    l.slice i (i + 3) = [l[i], l[i + 1], l[i + 2]] := by
  rw [List.slice, List.drop_eq_getElem_cons (show i < l.length by omega),
    List.drop_eq_getElem_cons (show i + 1 < l.length by omega), List.drop_eq_getElem_cons h]
  simp only [Nat.add_sub_cancel_left, List.take_succ_cons, List.take_zero]

theorem sp1 {l : List Std.U8} {i : Nat} {b : Std.U8} (ha : is_ascii_space b = ok true)
    {h : i < l.length} (hb : l[i]'h = b) : IsSpace (l.slice i (i + (1#usize).val)) := by
  subst hb
  rw [show (1#usize).val = 1 from rfl, slice_one h]
  exact Or.inl ⟨_, rfl, ha⟩

theorem sp2a {l : List Std.U8} {i j : Nat} {hj' : j < l.length} (hc : l[j]'hj' = 133#u8)
    (hj : j = i + (1#usize).val) {h : i < l.length} (hb : l[i]'h = 194#u8) :
    IsSpace (l.slice i (i + (2#usize).val)) := by
  rw [show (1#usize).val = 1 from rfl] at hj
  subst hj
  rw [show (2#usize).val = 2 from rfl, slice_two hj', hb, hc]
  simp [IsSpace]

theorem sp2b {l : List Std.U8} {i j : Nat} {hj' : j < l.length} (hc : l[j]'hj' = 160#u8)
    (hj : j = i + (1#usize).val) {h : i < l.length} (hb : l[i]'h = 194#u8) :
    IsSpace (l.slice i (i + (2#usize).val)) := by
  rw [show (1#usize).val = 1 from rfl] at hj
  subst hj
  rw [show (2#usize).val = 2 from rfl, slice_two hj', hb, hc]
  simp [IsSpace]

theorem sp3 {l : List Std.U8} {i j k : Nat} {b c d : Std.U8} (hw : is_wide_space b c d = ok true)
    {h : i < l.length} (hb : l[i]'h = b) {hj' : j < l.length} (hc : l[j]'hj' = c)
    {hk' : k < l.length} (hd : l[k]'hk' = d) (hj : j = i + (1#usize).val)
    (hk : k = i + (2#usize).val) : IsSpace (l.slice i (i + (3#usize).val)) := by
  subst hj hk hb hc hd
  rw [show (3#usize).val = 3 from rfl, slice_three hk']
  exact Or.inr (Or.inr (Or.inr ⟨_, _, _, rfl, hw⟩))

theorem space_at_is (s : Slice Std.U8) (i : Usize) :
    Ok (space_at s i) (fun n => n.val = 0 ∨
      (i.val + n.val ≤ s.length ∧ IsSpace (s.val.slice i.val (i.val + n.val)))) := by
  unfold space_at
  ostep
  all_goals refine Ok.ret ?_
  all_goals first | (left; rfl) | right
  all_goals subst_vars
  all_goals casesm* ∃ _, _
  all_goals refine ⟨by scalar_tac, ?_⟩
  all_goals first
    | (apply sp1 <;> assumption)
    | (apply sp2a <;> assumption)
    | (apply sp2b <;> assumption)
    | (apply sp3 <;> assumption)

theorem bsp1 {l : List Std.U8} {i j : Nat} {b : Std.U8} (ha : is_ascii_space b = ok true)
    {h : i < l.length} (hb : l[i]'h = b) (hi : i + (1#usize).val = j) :
    IsSpace (l.slice (j - (1#usize).val) j) := by
  subst hi
  simpa using sp1 ha hb

theorem bsp2a {l : List Std.U8} {i j k : Nat} {hi' : i < l.length} (hc : l[i]'hi' = 133#u8)
    (hi : i + (1#usize).val = k) {hj' : j < l.length} (hb : l[j]'hj' = 194#u8)
    (hj : j + (2#usize).val = k) : IsSpace (l.slice (k - (2#usize).val) k) := by
  have := sp2a (i := j) hc (by simp at hi hj ⊢; omega) hb
  subst hj
  simpa using this

theorem bsp2b {l : List Std.U8} {i j k : Nat} {hi' : i < l.length} (hc : l[i]'hi' = 160#u8)
    (hi : i + (1#usize).val = k) {hj' : j < l.length} (hb : l[j]'hj' = 194#u8)
    (hj : j + (2#usize).val = k) : IsSpace (l.slice (k - (2#usize).val) k) := by
  have := sp2b (i := j) hc (by simp at hi hj ⊢; omega) hb
  subst hj
  simpa using this

theorem bsp3 {l : List Std.U8} {i j k e : Nat} {b c d : Std.U8}
    (hw : is_wide_space b c d = ok true)
    {hi' : i < l.length} (hb : l[i]'hi' = b) {hj' : j < l.length} (hc : l[j]'hj' = c)
    {hk' : k < l.length} (hd : l[k]'hk' = d) (hi : i + (3#usize).val = e)
    (hj : j + (2#usize).val = e) (hk : k + (1#usize).val = e) :
    IsSpace (l.slice (e - (3#usize).val) e) := by
  have := sp3 (i := i) hw hb hc hd (by simp at hi hj ⊢; omega) (by simp at hi hk ⊢; omega)
  subst hi
  simpa using this

theorem space_before_is (s : Slice Std.U8) (j : Usize) :
    Ok (space_before s j) (fun n => n.val = 0 ∨
      (n.val ≤ j.val ∧ j.val ≤ s.length ∧ IsSpace (s.val.slice (j.val - n.val) j.val))) := by
  unfold space_before
  ostep
  all_goals refine Ok.ret ?_
  all_goals first | (left; rfl) | right
  all_goals subst_vars
  all_goals casesm* ∃ _, _
  all_goals refine ⟨by scalar_tac, by scalar_tac, ?_⟩
  all_goals first
    | (apply bsp1 <;> assumption)
    | (apply bsp2a <;> assumption)
    | (apply bsp2b <;> assumption)
    | (apply bsp3 <;> assumption)

theorem slice_self (l : List Std.U8) (a : Nat) : l.slice a a = [] := by simp [List.slice]

theorem slice_append {l : List Std.U8} {a b c : Nat} (hab : a ≤ b) (hbc : b ≤ c) :
    l.slice a b ++ l.slice b c = l.slice a c := by
  simp only [List.slice]
  have : c - a = (b - a) + (c - b) := by omega
  rw [this, List.take_add, List.drop_drop]
  congr 3
  omega

theorem slice_take {l : List Std.U8} {a b k : Nat} (h : b ≤ k) : (l.take k).slice a b = l.slice a b := by
  simp only [List.slice, List.drop_take, List.take_take]
  congr 1
  omega

theorem slice_drop {l : List Std.U8} {a i j : Nat} : (l.drop a).slice i j = l.slice (a + i) (a + j) := by
  simp only [List.slice, List.drop_drop]
  congr 1
  omega

theorem skip_space_keeps (s : Slice Std.U8) (from' : Usize) :
    Ok (skip_space s from') (fun r => from'.val ≤ r.val ∧ Spaces (s.val.slice from'.val r.val)) := by
  unfold skip_space skip_space_loop
  refine Ok.loop _ (fun x : Usize × Bool => from'.val ≤ x.1.val ∧
    Spaces (s.val.slice from'.val x.1.val)) _ ?_ _ ⟨le_rfl, by rw [slice_self]; exact Spaces.nil⟩
  rintro ⟨a, moving⟩ ⟨h1, h2⟩
  try dsimp only at h1 h2 ⊢
  unfold skip_space_loop.body
  refine Ok.ite (fun _ => Ok.ite (fun _ => ?_) (fun _ => Ok.ret ⟨h1, h2⟩)) (fun _ => Ok.ret ⟨h1, h2⟩)
  refine Ok.bind (space_at_is _ _) fun n hn => ?_
  refine Ok.ite (fun _ => Ok.ret ⟨h1, h2⟩) (fun hn0 => ?_)
  refine Ok.bind (add_ok _ _) fun a1 ha1 => Ok.ret ?_
  rcases hn with hn | ⟨hle, hsp⟩
  · exact absurd (by scalar_tac) hn0
  dsimp only
  refine ⟨by scalar_tac, ?_⟩
  rw [ha1, ← slice_append h1 (by omega)]
  exact h2.append (Spaces.one hsp)

theorem trim_keeps (s : Slice Std.U8) (from' to' : Usize) (hf : from'.val ≤ to'.val) :
    Ok (trim s from' to') (fun r => from'.val ≤ r.1.val ∧ r.1.val ≤ r.2.val ∧ r.2.val ≤ to'.val ∧
      Spaces (s.val.slice from'.val r.1.val) ∧ Spaces (s.val.slice r.2.val to'.val)) := by
  unfold trim
  refine Ok.bind (q := fun a : Usize => from'.val ≤ a.val ∧ a.val ≤ to'.val ∧
    Spaces (s.val.slice from'.val a.val)) ?_ fun a ⟨ha1, ha2, ha3⟩ => ?_
  · unfold trim_loop0
    refine Ok.loop _ (fun x : Usize × Bool => from'.val ≤ x.1.val ∧ x.1.val ≤ to'.val ∧
      Spaces (s.val.slice from'.val x.1.val)) _ ?_ _ ⟨le_rfl, hf, by rw [slice_self]; exact Spaces.nil⟩
    rintro ⟨a, moving⟩ ⟨h1, h2, h3⟩
    try dsimp only at h1 h2 h3 ⊢
    unfold trim_loop0.body
    refine Ok.ite (fun _ => Ok.ite (fun _ => ?_) (fun _ => Ok.ret ⟨h1, h2, h3⟩))
      (fun _ => Ok.ret ⟨h1, h2, h3⟩)
    refine Ok.bind (range_to_ok _ _) fun t ⟨htv, _⟩ => ?_
    refine Ok.bind (space_at_is _ _) fun n hn => ?_
    refine Ok.ite (fun _ => Ok.ret ⟨h1, h2, h3⟩) (fun hn0 => ?_)
    refine Ok.bind (add_ok _ _) fun a1 ha1 => Ok.ret ?_
    rcases hn with hn | ⟨hle, hsp⟩
    · exact absurd (by scalar_tac) hn0
    have hlen : t.length = to'.val := by simp [Slice.length, htv]; omega
    dsimp only
    refine ⟨by scalar_tac, by scalar_tac, ?_⟩
    rw [ha1, ← slice_append h1 (by omega)]
    rw [htv, slice_take (by scalar_tac)] at hsp
    exact h3.append (Spaces.one hsp)
  · refine Ok.bind (q := fun b : Usize => a.val ≤ b.val ∧ b.val ≤ to'.val ∧
      Spaces (s.val.slice b.val to'.val)) ?_ fun b ⟨hb1, hb2, hb3⟩ => Ok.ret ⟨ha1, hb1, hb2, ha3, hb3⟩
    unfold trim_loop1
    refine Ok.loop _ (fun x : Bool × Usize => a.val ≤ x.2.val ∧ x.2.val ≤ to'.val ∧
      Spaces (s.val.slice x.2.val to'.val)) _ ?_ _ ⟨ha2, le_rfl, by rw [slice_self]; exact Spaces.nil⟩
    rintro ⟨moving, b⟩ ⟨h1, h2, h3⟩
    try dsimp only at h1 h2 h3 ⊢
    unfold trim_loop1.body
    refine Ok.ite (fun _ => Ok.ite (fun _ => ?_) (fun _ => Ok.ret ⟨h1, h2, h3⟩))
      (fun _ => Ok.ret ⟨h1, h2, h3⟩)
    refine Ok.bind (range_from_ok _ _) fun t ⟨htv, _⟩ => ?_
    refine Ok.bind (sub_ok _ _) fun i hi => ?_
    refine Ok.bind (space_before_is _ _) fun n hn => ?_
    refine Ok.ite (fun _ => Ok.ret ⟨h1, h2, h3⟩) (fun hn0 => ?_)
    refine Ok.bind (sub_ok _ _) fun b1 hb1 => Ok.ret ?_
    rcases hn with hn | ⟨hni, hit, hsp⟩
    · exact absurd (by scalar_tac) hn0
    dsimp only
    refine ⟨by scalar_tac, by scalar_tac, ?_⟩
    rw [htv, slice_drop] at hsp
    rw [show a.val + (i.val - n.val) = b1.val by scalar_tac,
      show a.val + i.val = b.val by scalar_tac] at hsp
    rw [← slice_append (b := b.val) (by scalar_tac) h2]
    exact Spaces.cons hsp h3

theorem is_blank_keeps (s : Slice Std.U8) (from' to' : Usize) (hf : from'.val ≤ to'.val) :
    Ok (is_blank s from' to') (fun r => r = true → Spaces (s.val.slice from'.val to'.val)) := by
  unfold is_blank
  refine Ok.bind (trim_keeps _ _ _ hf) fun ⟨a, b⟩ ⟨h1, h2, h3, h4, h5⟩ => ?_
  refine Ok.uncurry_mk (Ok.ret fun hab => ?_)
  simp only [decide_eq_true_eq] at hab
  subst hab
  rw [← slice_append h1 h3]
  exact h4.append h5

/-! ## Chunks -/

theorem intercalate_snoc (xs : List (List Std.U8)) (y : List Std.U8) :
    [10#u8].intercalate (xs ++ [y]) = if xs = [] then y else [10#u8].intercalate xs ++ 10#u8 :: y := by
  induction xs with
  | nil => simp
  | cons x xs ih =>
    cases xs with
    | nil => simp
    | cons x' xs' =>
      rw [List.cons_append, List.cons_append, List.intercalate_cons_cons, ← List.cons_append, ih]
      simp

/-- A chunk is its lines joined, with whitespace taken out. -/
theorem chunk_text_keeps (lines : Slice (alloc.vec.Vec Std.U8)) :
    Ok (chunk_text lines) (fun c => Dels ([10#u8].intercalate (lines.val.map (·.val))) c.val) := by
  unfold chunk_text
  refine Ok.bind (q := fun t : alloc.vec.Vec Std.U8 =>
    t.val = [10#u8].intercalate (lines.val.map (·.val))) ?_ fun text ht => ?_
  · unfold chunk_text_loop
    refine Ok.loop _ (fun x : alloc.vec.Vec Std.U8 × Usize =>
      x.1.val = [10#u8].intercalate ((lines.val.take x.2.val).map (·.val))) _ ?_ _ (by simp)
    rintro ⟨text, i⟩ ht
    try dsimp only at ht ⊢
    unfold chunk_text_loop.body
    refine Ok.ite (fun hi => ?_) (fun hi => Ok.ret ?_)
    · refine Ok.bind (q := fun t : alloc.vec.Vec Std.U8 =>
        t.val = text.val ++ if i.val = 0 then [] else [10#u8]) ?_ fun t1 ht1 => ?_
      · refine Ok.ite (fun h0 => Ok.mono (bytes_push_ok _ _) fun t h => ?_)
          (fun h0 => Ok.ret ?_)
        · rw [h]; simp only [show ¬i.val = 0 by scalar_tac, ↓reduceIte]
        · simp only [show i.val = 0 by scalar_tac, ↓reduceIte, List.append_nil]
      refine Ok.bind (index_ok _ _) fun v ⟨hv, hv'⟩ => ?_
      refine Ok.bind (bytes_extend_ok _ _) fun t2 ht2 => ?_
      refine Ok.bind (add_ok _ _) fun i2 hi2 => Ok.ret ?_
      dsimp only
      have hil : i.val < lines.val.length := by scalar_tac
      have hi2' : i2.val = i.val + 1 := by scalar_tac
      rw [ht2, ht1, ht, hi2', List.take_succ_eq_append_getElem hil, List.map_append,
        List.map_singleton, intercalate_snoc, hv']
      by_cases h0 : i.val = 0
      · simp [h0, alloc.vec.Vec.deref]
      · have h0' : ¬List.map (fun x => x.val) (List.take i.val lines.val) = [] := by
          intro h
          rw [List.map_eq_nil_iff, List.take_eq_nil_iff] at h
          rcases h with h | h
          · exact h0 h
          · simp [h] at hil
        simp only [h0, h0', ↓reduceIte]
        simp [alloc.vec.Vec.deref]
    · dsimp only
      rw [ht, List.take_of_length_le (by scalar_tac)]
  have hd : (alloc.vec.Vec.deref text).val = text.val := by simp [alloc.vec.Vec.deref]
  have hlen : (alloc.vec.Vec.len text).val = text.val.length := alloc.vec.Vec.len_val text
  refine Ok.bind (trim_keeps _ _ _ (by simp))
    fun r ⟨_, hab, hb, ha', hb'⟩ => ?_
  obtain ⟨a, b⟩ := r
  refine Ok.uncurry fun a' b' hr => ?_
  simp only [Prod.mk.injEq] at hr
  obtain ⟨rfl, rfl⟩ := hr
  refine Ok.bind (vec_range_ok _ _ _) fun t ⟨htv, _⟩ => ?_
  refine Ok.mono (bytes_extend_ok _ _) fun c hc => ?_
  simp only [hd, hlen] at ha' hb' hab hb
  rw [hc, htv, ← ht]
  simp only [alloc.vec.Vec.new]
  have : text.val = text.val.slice 0 a.val ++ text.val.slice a.val b.val ++
      text.val.slice b.val text.val.length := by
    rw [slice_append (by omega) hab, slice_append (by omega) (by omega)]
    simp [List.slice]
  conv => lhs; rw [this]
  exact Dels.trim ha' hb'

theorem vec_is_empty_ok {α : Type} {v : alloc.vec.Vec α} {b : Bool}
    (h : alloc.vec.Vec.is_empty v = ok b) : b = true ↔ v.val = [] := by
  simp only [alloc.vec.Vec.is_empty, ok_inj] at h
  subst h
  simp [alloc.vec.Vec.length]

theorem end_keeps (c : Chunker) (chunk : alloc.vec.Vec Std.U8) (out : Out)
    (pre ps : List (List Std.U8)) (h : Inv c (pre ++ vals out) ps)
    (hch : Dels ([10#u8].intercalate (vals c.lines)) chunk.val) :
    Ok (Chunker.end c chunk out) (fun r => Inv r.1 (pre ++ vals r.2) ps ∧ Same c r.1) := by
  unfold Chunker.end
  obtain ⟨hl, ps₁, ps₂, rfl, ⟨cs₁, hcs₁, hs⟩, hh⟩ := h
  obtain ⟨cl, hcl, hf⟩ := dels_intercalate _ hl hch
  obtain ⟨cs₂, hcs₂, he⟩ := hh.dels hcl
  refine Ok.then_ fun b hb => ?_
  split
  · rename_i hb'
    have h0 : chunk.val = [] := (vec_is_empty_ok hb).mp hb'
    refine Ok.ret ⟨⟨by simp, ps₁ ++ ps₂, [], by simp,
      ⟨cs₁ ++ cs₂, List.rel_append hcs₁ hcs₂, ?_⟩, by simpa using HeldL.nil⟩,
      ⟨rfl, rfl⟩⟩
    rw [h0] at hf
    simp only [List.filter_nil] at hf
    dsimp only
    rw [hs, List.flatten_append, he, ← hf, List.append_nil]
  · refine Ok.then_ fun out' hout => Ok.ret ⟨⟨by simp, ps₁ ++ ps₂, [],
      by simp, ⟨cs₁ ++ cs₂, List.rel_append hcs₁ hcs₂, ?_⟩,
      by simpa using HeldL.nil⟩, ⟨rfl, rfl⟩⟩
    have : (pre ++ vals out').flatten = (pre ++ vals out).flatten ++ chunk.val := by
      rw [vals, vals, push_ok hout]; simp
    dsimp only
    rw [this, List.filter_append, hs, hf, ← he, List.flatten_append]

theorem cut_keeps (c : Chunker) (out : Out) (pre ps : List (List Std.U8))
    (h : Inv c (pre ++ vals out) ps) :
    Ok (Chunker.cut c out) (fun r => Inv r.1 (pre ++ vals r.2) ps ∧ Same c r.1) := by
  unfold Chunker.cut
  refine Ok.bind (chunk_text_keeps _) fun chunk hch => ?_
  refine Ok.then_ fun _ _ => ?_
  split
  · refine Ok.then_ fun _ _ => ?_
    split
    · exact Ok.ret ⟨h, Same.rfl' c⟩
    · exact end_keeps _ _ _ _ _ h (by simpa [alloc.vec.Vec.deref] using hch)
  · exact Ok.ret ⟨h, Same.rfl' c⟩

theorem cut_for_quote_keeps (c : Chunker) (out : Out) (pre ps : List (List Std.U8))
    (h : Inv c (pre ++ vals out) ps) :
    Ok (Chunker.cut_for_quote c out) (fun r => Inv r.1 (pre ++ vals r.2) ps ∧ Same c r.1) := by
  unfold Chunker.cut_for_quote
  refine Ok.bind (chunk_text_keeps _) fun chunk hch => ?_
  refine Ok.then_ fun _ _ => ?_
  split
  · exact end_keeps _ _ _ _ _ h (by simpa [alloc.vec.Vec.deref] using hch)
  · exact Ok.ret ⟨h, Same.rfl' c⟩

theorem push_line_keeps (c : Chunker) (line : Slice Std.U8) (pre ps : List (List Std.U8))
    (q : List Std.U8) (h : Inv c pre ps) (hl : 10#u8 ∉ line.val) (hq : HeldL [q] [line.val]) :
    Ok (Chunker.push_line c line) (fun c' => Inv c' pre (ps ++ [q]) ∧ Same c c') := by
  unfold Chunker.push_line
  refine Ok.then_ fun _ _ => Ok.then_ fun _ _ => Ok.then_ fun _ _ => ?_
  refine Ok.bind (bytes_extend_ok _ _) fun copy hcopy => ?_
  refine Ok.then_ fun v hv => Ok.ret ⟨?_, rfl, rfl⟩
  obtain ⟨hl', ps₁, ps₂, rfl, hs, hh⟩ := h
  have hvals : vals v = vals c.lines ++ [line.val] := by
    rw [vals, push_ok hv]; simp [hcopy, alloc.vec.Vec.new]
  refine ⟨?_, ps₁, ps₂ ++ [q], by simp, hs, ?_⟩
  · simp only [hvals, List.mem_append, List.mem_singleton]
    rintro l (hl'' | rfl)
    · exact hl' l hl''
    · exact hl
  · simp only [hvals]
    exact hh.append hq

/-! ## Where a line is cut -/

theorem next_cut_loop1_keeps (line : Slice Std.U8) (spans : alloc.vec.Vec (Usize × Usize))
    (pic len : Usize) (has : Bool) (h : has = true → picture line pic = ok (some len)) :
    Ok (next_cut_loop1 line spans pic len has)
      (fun r => r.2.2 = true → picture line r.1 = ok (some r.2.1)) := by
  unfold next_cut_loop1
  refine Ok.loop _ (fun x : Usize × Usize × Bool => x.2.2 = true → picture line x.1 = ok (some x.2.1))
    _ ?_ _ h
  rintro ⟨pic, len, has⟩ hinv
  try dsimp only at hinv ⊢
  unfold next_cut_loop1.body
  refine Ok.ite (fun _ => Ok.ret hinv) (fun _ => ?_)
  refine Ok.ite (fun _ => ?_) (fun _ => Ok.ret hinv)
  refine Ok.bind (index_ok _ _) fun _ _ => ?_
  refine Ok.bind (q := fun found : Option Usize => ∀ l ∈ found, picture line pic = ok (some l))
    ?_ fun found hf => ?_
  · refine Ok.ite (fun _ => ?_) (fun _ => Ok.ret (by simp))
    refine Ok.then_ fun _ _ => Ok.ite (fun _ => ?_) (fun _ => Ok.ret (by simp))
    exact Ok.of_eq fun r hr l hl => by
      simp only [Option.mem_def] at hl; rw [hr, hl]
  · ok_cases
    · exact Ok.bind (add_ok _ _) fun _ _ => Ok.ret (by dsimp only; intro h; contradiction)
    · exact Ok.ret fun _ => hf _ rfl

/-- Where `next_cut` cuts: at a `[split]`, or at a picture's handle. -/
theorem next_cut_keeps (line : Slice Std.U8) :
    Ok (next_cut line) (fun r => ∀ x ∈ r,
      (x.2.2 = false → x.2.1.val = 7 ∧ SPLIT <+: line.val.drop x.1.val) ∧
      (x.2.2 = true → picture line x.1 = ok (some x.2.1))) := by
  unfold next_cut
  refine Ok.then_ fun spans _ => ?_
  refine Ok.bind (next_cut_loop0_ok _ _ _ _ (by simp)) fun r0 h0 => ?_
  obtain ⟨split, has_split⟩ := r0
  refine Ok.bind (next_cut_loop1_keeps _ _ _ _ _ (by simp)) fun r1 h1 => ?_
  obtain ⟨pic, len, has_pic⟩ := r1
  simp only [uncurry_eq] at h0 h1 ⊢
  repeat' first
    | (refine Ok.ite (fun _ => ?_) (fun _ => ?_))
  all_goals refine Ok.ret fun x hx => ?_
  all_goals first
    | (simp at hx; done)
    | (simp only [Option.mem_def, Option.some.injEq] at hx
       subst hx
       dsimp only
       first
         | exact ⟨fun h => by simp at h, fun _ => h1 ‹_›⟩
         | exact ⟨fun _ => ⟨rfl, h0 ‹_›⟩, fun h => by simp at h⟩)

theorem prefix_split {t l : List Std.U8} {a : Nat} (h : t <+: l.drop a) :
    l = l.take a ++ t ++ l.drop (a + t.length) := by
  obtain ⟨u, hu⟩ := h
  have hu' : u = l.drop (a + t.length) := by
    rw [← List.drop_drop, ← hu, List.drop_left]
  rw [← hu', List.append_assoc, hu, List.take_append_drop]

theorem take_slice_drop {l : List Std.U8} {a b : Nat} (h : a ≤ b) :
    l.take a ++ l.slice a b ++ l.drop b = l := by
  rw [List.append_assoc, List.slice,
    show l.drop b = (l.drop a).drop (b - a) by rw [List.drop_drop]; congr 1; omega,
    List.take_append_drop, List.take_append_drop]

theorem mem_of_mem_slice {l : List Std.U8} {a b : Nat} {x : Std.U8} (h : x ∈ l.slice a b) : x ∈ l :=
  List.mem_of_mem_drop (List.mem_of_mem_take h)

theorem msg_pic {l : List Std.U8} {a n : Nat} (s : Slice Std.U8) (hs : s.val = l) (a' n' : Usize)
    (ha : a'.val = a) (hn : n'.val = n) (hpic : picture s a' = ok (some n'))
    (hb : a + n ≤ l.length) {qs : List (List Std.U8)} (h : Msg (l.drop (a + n)) qs) :
    Msg l (l.take a :: l.slice a (a + n) :: qs) := by
  have e : l = l.take a ++ l.slice a (a + n) ++ l.drop (a + n) := by
    simp only [List.slice, Nat.add_sub_cancel_left, List.append_assoc]
    rw [← List.drop_drop, List.take_append_drop, List.take_append_drop]
  have hp := Msg.pic (p := l.take a) (q := l.slice a (a + n)) (m := l.drop (a + n)) ?_ h
  · rwa [← e] at hp
  · rw [← e, List.length_take, List.slice_length, Nat.min_eq_left (by omega),
      Nat.min_eq_right (by omega), Nat.add_sub_cancel_left]
    exact ⟨s, a', n', hs, ha, hn, hpic⟩

theorem msg_split {l : List Std.U8} {a : Nat} (hpre : SPLIT <+: l.drop a)
    {qs : List (List Std.U8)} (h : Msg (l.drop (a + 7)) qs) : Msg l (l.take a :: qs) := by
  have e := prefix_split hpre
  have hp := Msg.split (p := l.take a) (m := l.drop (a + 7)) h
  rwa [← show SPLIT.length = 7 from rfl, ← e] at hp

/-- What `message_line` keeps of a line, `k`: the pieces of the line, or if
it cuts it, of what comes before the rest. -/
theorem message_line_keeps (c : Chunker) (line : Slice Std.U8) (out : Out)
    (pre ps : List (List Std.U8)) (h : Inv c (pre ++ vals out) ps) (hl : 10#u8 ∉ line.val) :
    Ok (Chunker.message_line c line out) (fun r => Same c r.2.1 ∧ ∃ k,
      Inv r.2.1 (pre ++ vals r.2.2) (ps ++ k) ∧
      match r.1 with
      | none => Msg line.val k
      | some e => ∀ qs, Msg (line.val.drop e.val) qs → Msg line.val (k ++ qs)) := by
  unfold Chunker.message_line
  refine Ok.then_ fun at0 _ => Ok.then_ fun o _ => ?_
  -- Where the quote ends, and whitespace from there to what QQ shows.
  refine Ok.bind (q := fun r : Chunker × Out × Usize × Usize => Same c r.1 ∧
      Inv r.1 (pre ++ vals r.2.1) ps ∧ r.2.2.1.val ≤ r.2.2.2.val ∧
      Spaces (line.val.slice r.2.2.1.val r.2.2.2.val))
    ?_ fun ⟨c1, out1, quoted, shown⟩ ⟨hs1, hc1, hqs, hshown⟩ => ?_
  · ok_cases
    · exact Ok.ret ⟨Same.rfl' c, h, le_rfl, by rw [slice_self]; exact Spaces.nil⟩
    · refine Ok.bind (cut_for_quote_keeps c out pre ps h) fun ⟨c2, out2⟩ ⟨hc2, hs2⟩ => ?_
      refine Ok.uncurry_mk ?_
      refine Ok.bind (add_ok _ _) fun i _ => ?_
      exact Ok.bind (skip_space_keeps _ _) fun shown1 ⟨hsh1, hsh2⟩ =>
        Ok.ret ⟨hs2, hc2, hsh1, hsh2⟩
  refine Ok.uncurry_mk (Ok.uncurry_mk (Ok.uncurry_mk ?_))
  refine Ok.bind (range_from_ok _ _) fun text ⟨htext, _⟩ => ?_
  refine Ok.then_ fun b _ => Ok.ite (fun _ => ?_) (fun _ => ?_)
  · -- a fence: the whole line
    exact Ok.bind (push_line_keeps _ _ _ _ line.val hc1 hl (HeldL.own _ HeldL.nil))
      fun c2 ⟨hc2, hs2⟩ => Ok.ret ⟨hs1.trans hs2, [line.val], hc2, Msg.whole _⟩
  refine Ok.then_ fun b1 hb1 => Ok.ite (fun hb1' => ?_) (fun _ => ?_)
  · -- a break, which goes, but not a quote before it
    have hbrk : Break (line.val.drop shown.val) := ⟨text, htext, by rw [hb1, hb1']⟩
    have hmsg := Msg.brk (line.val.take quoted.val) hshown hbrk
    rw [take_slice_drop hqs] at hmsg
    refine Ok.ite (fun hq => ?_) (fun hq => ?_)
    · refine Ok.bind (range_to_ok _ _) fun s ⟨hs, _⟩ => ?_
      refine Ok.bind (push_line_keeps _ _ _ _ s.val hc1 ?_ (HeldL.own _ HeldL.nil))
        fun c2 ⟨hc2, hs2⟩ => Ok.ret ⟨hs1.trans hs2, [s.val], hc2, by rw [hs]; exact hmsg⟩
      rw [hs]; exact fun h => hl (List.mem_of_mem_take h)
    · have h0 : quoted.val = 0 := by scalar_tac
      rw [h0, List.take_zero] at hmsg
      exact Ok.bind (cut_keeps _ _ _ _ hc1) fun ⟨c2, out2⟩ ⟨hc2, hs2⟩ =>
        Ok.uncurry_mk (Ok.ret ⟨hs1.trans hs2, [[]], hc2.blank Spaces.nil, hmsg⟩)
  refine Ok.bind (is_blank_keeps _ _ _ (by simp)) fun b2 hb2 =>
    Ok.ite (fun hb2' => ?_) (fun _ => ?_)
  · -- blank: whitespace, which goes
    have hsp : Spaces line.val := by
      have := hb2 hb2'
      simpa [Slice.length, List.slice] using this
    refine Ok.ite (fun _ => ?_) (fun _ => ?_)
    · refine Ok.then_ fun b3 _ => Ok.ite (fun _ => ?_)
        (fun _ => Ok.ret ⟨hs1, [line.val], hc1.blank hsp, Msg.whole _⟩)
      exact Ok.bind (push_line_keeps _ _ _ _ line.val hc1
        (by simp [alloc.vec.Vec.deref, alloc.vec.Vec.new])
        (by simpa [alloc.vec.Vec.deref, alloc.vec.Vec.new] using HeldL.empty hsp HeldL.nil))
        fun c2 ⟨hc2, hs2⟩ => Ok.ret ⟨hs1.trans hs2, [line.val], hc2, Msg.whole _⟩
    · exact Ok.bind (cut_keeps _ _ _ _ hc1) fun ⟨c2, out2⟩ ⟨hc2, hs2⟩ =>
        Ok.uncurry_mk (Ok.ret ⟨hs1.trans hs2, [line.val], hc2.blank hsp, Msg.whole _⟩)
  refine Ok.then_ fun b3 _ => ?_
  refine Ok.bind (q := fun r : Chunker × Out => Same c r.1 ∧ Inv r.1 (pre ++ vals r.2) ps) ?_
    fun ⟨c2, out2⟩ ⟨hs2, hc2⟩ => ?_
  · refine Ok.ite (fun _ => ?_) (fun _ => Ok.ret ⟨hs1, hc1⟩)
    exact Ok.bind (cut_keeps _ _ _ _ hc1) fun ⟨c3, out3⟩ ⟨hc3, hs3⟩ =>
      Ok.uncurry_mk (Ok.ret ⟨hs1.trans hs3, hc3⟩)
  refine Ok.uncurry_mk ?_
  refine Ok.bind (next_cut_keeps _) fun o1 ho1 => ?_
  ok_cases
  · -- no cut: the whole line
    exact Ok.bind (push_line_keeps _ _ _ _ line.val hc2 hl (HeldL.own _ HeldL.nil))
      fun c3 ⟨hc3, hs3⟩ => Ok.ret ⟨hs2.trans hs3, [line.val], hc3, Msg.whole _⟩
  rename_i t
  obtain ⟨at1, len, pic⟩ := t
  obtain ⟨hsplit, hpic⟩ := ho1 _ rfl
  refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
  refine Ok.bind (range_to_ok _ _) fun s ⟨hs, hat1⟩ => ?_
  refine Ok.bind (push_line_keeps _ _ _ _ s.val hc2 ?_ (HeldL.own _ HeldL.nil))
    fun c3 ⟨hc3, hs3⟩ => ?_
  · rw [hs]; exact fun h => hl (List.mem_of_mem_take h)
  refine Ok.bind (cut_keeps _ _ _ _ hc3) fun ⟨c4, out3⟩ ⟨hc4, hs4⟩ => ?_
  refine Ok.uncurry_mk ?_
  refine Ok.bind (q := fun r : Chunker × Out => Same c r.1 ∧ ∃ k₂,
      Inv r.1 (pre ++ vals r.2) (ps ++ [s.val] ++ k₂) ∧
      (pic = true → at1.val + len.val ≤ line.length ∧
        k₂ = [line.val.slice at1.val (at1.val + len.val)]) ∧ (pic = false → k₂ = []))
    ?_ fun ⟨c5, out4⟩ ⟨hs5, k₂, hc5, hk1, hk2⟩ => ?_
  · refine Ok.ite (fun hp => ?_) (fun hp => Ok.ret ⟨(hs2.trans hs3).trans hs4, [],
      by simpa using hc4, fun h => absurd h hp, fun _ => rfl⟩)
    refine Ok.bind (add_ok _ _) fun i1 hi1 => ?_
    refine Ok.bind (range_ok _ _ _) fun s1 ⟨hs1v, _, hs1l⟩ => ?_
    refine Ok.bind (push_line_keeps _ _ _ _ s1.val hc4 ?_ (HeldL.own _ HeldL.nil))
      fun c6 ⟨hc6, hs6⟩ => ?_
    · rw [hs1v]; exact fun h => hl (mem_of_mem_slice h)
    refine Ok.mono (cut_keeps _ _ _ _ hc6) fun ⟨c7, out5⟩ ⟨hc7, hs7⟩ =>
      ⟨(((hs2.trans hs3).trans hs4).trans hs6).trans hs7, [s1.val], hc7, fun _ => ⟨?_, ?_⟩,
        fun h => absurd hp (by simp [h])⟩
    · scalar_tac
    · rw [hs1v, hi1]
  refine Ok.bind (add_ok _ _) fun i2 hi2 => Ok.ret ⟨hs5, [s.val] ++ k₂,
    by simpa [List.append_assoc] using hc5, ?_⟩
  dsimp only
  intro qs hqs
  rw [hs, List.append_assoc]
  cases pic with
  | true =>
    obtain ⟨hb, rfl⟩ := hk1 rfl
    rw [hi2] at hqs
    exact msg_pic line rfl at1 len rfl rfl (hpic rfl) hb hqs
  | false =>
    obtain ⟨h7, hpre⟩ := hsplit rfl
    rw [hi2, h7] at hqs
    rw [hk2 rfl]
    exact msg_split hpre hqs

theorem classify_loop_keeps (c : Chunker) (line : Slice Std.U8) (out : Out) (start : Usize)
    (done : Bool) (pre ps K : List (List Std.U8)) (h : Inv c (pre ++ vals out) (ps ++ K))
    (hl : 10#u8 ∉ line.val)
    (hK : done = false → ∀ qs, Msg (line.val.drop start.val) qs → Msg line.val (K ++ qs))
    (hK' : done = true → Msg line.val K) :
    Ok (Chunker.classify_loop c line out start done) (fun r => Same c r.1 ∧
      ∃ K, Inv r.1 (pre ++ vals r.2) (ps ++ K) ∧ Msg line.val K) := by
  unfold Chunker.classify_loop
  refine Ok.loop _ (fun x : Chunker × Out × Usize × Bool => Same c x.1 ∧ ∃ K,
    Inv x.1 (pre ++ vals x.2.1) (ps ++ K) ∧
    (x.2.2.2 = false → ∀ qs, Msg (line.val.drop x.2.2.1.val) qs → Msg line.val (K ++ qs)) ∧
    (x.2.2.2 = true → Msg line.val K)) _ ?_ _ ⟨Same.rfl' c, K, h, hK, hK'⟩
  rintro ⟨c, out, start, done⟩ ⟨hs, K, hc, hK, hK'⟩
  try dsimp only at hs hc hK hK' ⊢
  unfold Chunker.classify_loop.body
  refine Ok.ite (fun hd => Ok.ret ⟨hs, K, hc, hK' hd⟩) (fun hd => ?_)
  simp only [Bool.not_eq_true] at hd
  refine Ok.bind (range_from_ok _ _) fun t ⟨ht, _⟩ => ?_
  refine Ok.bind (message_line_keeps _ _ _ _ _ hc (by rw [ht]; exact fun h => hl (List.mem_of_mem_drop h)))
    fun ⟨o, c1, out1⟩ ⟨hs1, k, hc1, hk⟩ => ?_
  refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
  ok_cases
  · refine Ok.ret ⟨hs.trans hs1, K ++ k, by simpa using hc1, fun h => by simp at h, fun _ => ?_⟩
    exact hK hd k (by rw [← ht]; exact hk)
  · rename_i e
    refine Ok.bind (add_ok _ _) fun s1 hs1' => Ok.ret ⟨hs.trans hs1, K ++ k, by simpa using hc1,
      fun _ qs hqs => ?_, fun h => by simp [hd] at h⟩
    rw [List.append_assoc]
    refine hK hd (k ++ qs) ?_
    rw [← ht]
    refine hk qs ?_
    rw [ht, List.drop_drop]
    dsimp only at hs1' hqs
    rwa [hs1'] at hqs

/-- What `classify` keeps of a line: its pieces. -/
theorem classify_keeps (c : Chunker) (line : Slice Std.U8) (out : Out)
    (pre ps : List (List Std.U8)) (h : Inv c (pre ++ vals out) ps) (hl : 10#u8 ∉ line.val) :
    Ok (Chunker.classify c line out) (fun r => Same c r.1 ∧
      ∃ K, Inv r.1 (pre ++ vals r.2) (ps ++ K) ∧ Msg line.val K) := by
  unfold Chunker.classify
  split
  · exact Ok.bind (push_line_keeps _ _ _ _ line.val h hl (HeldL.own _ HeldL.nil))
      fun c1 ⟨hc1, hs1⟩ => Ok.ret ⟨hs1, [line.val], hc1, Msg.whole _⟩
  · exact classify_loop_keeps _ _ _ _ _ _ _ [] (by simpa using h) hl
      (fun _ qs hqs => by simpa using hqs) (fun h => by simp at h)

/-! ## `<think>` spans -/

theorem Ok.and {α : Type} {m : Result α} {p q : α → Prop} (hp : Ok m p) (hq : Ok m q) :
    Ok m (fun x => p x ∧ q x) :=
  Ok.of_eq fun _ hx => ⟨hp.result hx, hq.result hx⟩

theorem not_prefix_of_ne {s pat : List Std.U8} {p k : Nat} (hk : k < pat.length)
    (h : p + k < s.length) (hne : s[p + k] ≠ pat[k]) : ¬pat <+: s.drop p := by
  intro hpre
  have := hpre.getElem hk
  simp only [List.getElem_drop] at this
  exact hne this.symm

theorem starts_at_false (s : Slice Std.U8) (p : Usize) (pat : Slice Std.U8) (hp : pat.val ≠ []) :
    Ok (starts_at s p pat) (fun r => r = false → ¬pat.val <+: s.val.drop p.val) := by
  unfold starts_at
  dsimp only
  osplit
  · refine Ok.ret fun _ hpre => hp ?_
    have := hpre.length_le
    simp only [List.length_drop] at this
    exact List.eq_nil_of_length_eq_zero (by scalar_tac)
  · refine Ok.bind (sub_ok _ _) fun d hd => ?_
    osplit
    · refine Ok.ret fun _ hpre => ?_
      have := hpre.length_le
      simp only [List.length_drop] at this
      scalar_tac
    · unfold starts_at_loop
      refine Ok.loop _ (fun x : Usize × Bool => x.2 = false → ¬pat.val <+: s.val.drop p.val) _ ?_ _
        (by simp)
      rintro ⟨i, same⟩ hinv
      try dsimp only at hinv ⊢
      unfold starts_at_loop.body
      osplit
      · osplit
        · refine Ok.bind (add_ok _ _) fun i2 hi2 => ?_
          refine Ok.bind (index_ok _ _) fun i3 ⟨h3, hi3⟩ => ?_
          refine Ok.bind (index_ok _ _) fun i4 ⟨h4, hi4⟩ => ?_
          refine Ok.bind (add_ok _ _) fun i5 hi5 => Ok.ret fun hne => ?_
          dsimp only at hne
          simp only [decide_eq_false_iff_not] at hne
          refine not_prefix_of_ne (k := i.val) h4 (by scalar_tac) ?_
          have : s.val[p.val + i.val]'(by scalar_tac) = s.val[i2.val] := by
            congr 1; scalar_tac
          rw [this, hi3, hi4]
          exact hne
        · exact Ok.ret (by simp_all)
      · exact Ok.ret hinv

/-- What `find` finds is the first of what it looks for. -/
theorem find_first (s : Slice Std.U8) (from' : Usize) (pat : Slice Std.U8) (hp : pat.val ≠ []) :
    Ok (find s from' pat) (fun r =>
      (∀ i ∈ r, from'.val ≤ i.val ∧ pat.val <+: s.val.drop i.val ∧
        ∀ j, from'.val ≤ j → j < i.val → ¬pat.val <+: s.val.drop j) ∧
      (r = none → ∀ j, from'.val ≤ j → ¬pat.val <+: s.val.drop j)) := by
  unfold find
  refine Ok.bind (q := fun r : Usize × Bool => from'.val ≤ r.1.val ∧
    (r.2 = true → pat.val <+: s.val.drop r.1.val) ∧
    (∀ j, from'.val ≤ j → j < r.1.val → ¬pat.val <+: s.val.drop j) ∧
    (r.2 = false → s.length ≤ r.1.val)) ?_ fun r hr => ?_
  · unfold find_loop
    refine Ok.loop _ (fun x : Usize × Bool => from'.val ≤ x.1.val ∧
      (x.2 = true → pat.val <+: s.val.drop x.1.val) ∧
      (∀ j, from'.val ≤ j → j < x.1.val → ¬pat.val <+: s.val.drop j)) _ ?_ _
      ⟨le_rfl, by simp, fun j h1 h2 => absurd h2 (by dsimp only at h2; omega)⟩
    rintro ⟨i, found⟩ ⟨h1, h2, h3⟩
    try dsimp only at h1 h2 h3 ⊢
    unfold find_loop.body
    refine Ok.ite (fun hf => Ok.ret ⟨h1, h2, h3, fun h => by simp [hf] at h⟩) (fun hf => ?_)
    refine Ok.ite (fun hi => ?_) (fun hi => Ok.ret ⟨h1, h2, h3, fun _ => by scalar_tac⟩)
    refine Ok.bind (Ok.and (starts_at_ok s i pat) (starts_at_false s i pat hp)) fun b hb => ?_
    refine Ok.ite (fun hb' => Ok.ret ⟨h1, fun _ => hb.1 hb', h3⟩) (fun hb' => ?_)
    refine Ok.bind (add_ok _ _) fun i2 hi2 => Ok.ret ⟨by scalar_tac, fun h => by simp [hf] at h,
      fun j hj1 hj2 => ?_⟩
    by_cases hji : j < i.val
    · exact h3 j hj1 hji
    · have : j = i.val := by scalar_tac
      subst this
      exact hb.2 (by simpa using hb')
  · obtain ⟨i, found⟩ := r
    obtain ⟨h1, h2, h3, h4⟩ := hr
    simp only [uncurry_eq]
    osplit
    · rename_i hf
      exact Ok.ret ⟨fun j hj => by
        simp only [Option.mem_def, Option.some.injEq] at hj
        subst hj
        exact ⟨h1, h2 hf, h3⟩, fun h => by simp at h⟩
    · rename_i hf
      refine Ok.ret ⟨by simp, fun _ j hj => ?_⟩
      by_cases hji : j < i.val
      · exact h3 j hj hji
      · intro hpre
        have := hpre.length_le
        have := h4 (by simpa using hf)
        simp only [List.length_drop] at *
        have : pat.val.length = 0 := by scalar_tac
        exact hp (List.eq_nil_of_length_eq_zero this)

/-- A tail that starts a line, or is empty, makes no tag with what comes before it. -/
def EndsLine (tail : List Std.U8) : Prop := ∀ b ∈ tail.head?, b = 10#u8 ∨ b = 13#u8

theorem tag_local {pat l tail : List Std.U8} (hpat : ∀ b ∈ pat, b ≠ 10#u8 ∧ b ≠ 13#u8)
    (ht : EndsLine tail) (h : ¬pat <+: l) : ¬pat <+: l ++ tail := by
  intro hp
  by_cases hlen : pat.length ≤ l.length
  · apply h
    rw [List.prefix_iff_eq_take] at hp ⊢
    rwa [List.take_append_of_le_length hlen] at hp
  · have hlt : l.length < pat.length := by omega
    have e := hp.getElem hlt
    rw [List.getElem_append_right (by omega)] at e
    simp only [Nat.sub_self] at e
    have hmem := hpat _ (List.getElem_mem hlt)
    have htl : 0 < tail.length := by
      have := hp.length_le; simp at this; omega
    have := ht tail[0] (by cases tail with | nil => simp at htl | cons x xs => simp)
    rw [← e] at this
    rcases this with h1 | h1
    · exact hmem.1 h1
    · exact hmem.2 h1

theorem think_end_ok : ∀ b ∈ THINK_END, b ≠ 10#u8 ∧ b ≠ 13#u8 := by decide

theorem keeps_all {seg rest t : List Std.U8} {th₂ : Bool} (hr : Unthink false rest t th₂) :
    Unthink false (seg ++ rest) (seg ++ t) th₂ := by
  induction seg with
  | nil => exact hr
  | cons b seg ih => exact Unthink.keep ih

theorem skips_all {seg rest t : List Std.U8} {th₂ : Bool}
    (h : ∀ k < seg.length, ¬THINK_END <+: (seg ++ rest).drop k) (hr : Unthink true rest t th₂) :
    Unthink true (seg ++ rest) t th₂ := by
  induction seg with
  | nil => exact hr
  | cons b seg ih =>
    refine Unthink.skip (h 0 (by simp)) (ih fun k hk => ?_)
    simpa using h (k + 1) (by simp; omega)

theorem slice_drop_eq {l : List Std.U8} {a p : Nat} (hap : a ≤ p) :
    l.slice a p ++ l.drop p = l.drop a := by
  rw [List.slice, show l.drop p = (l.drop a).drop (p - a) by rw [List.drop_drop]; congr 1; omega,
    List.take_append_drop]

theorem prefix_drop {t l : List Std.U8} {p : Nat} (h : t <+: l.drop p) :
    l.drop p = t ++ l.drop (p + t.length) := by
  obtain ⟨u, hu⟩ := h
  have hu' : u = l.drop (p + t.length) := by
    rw [← List.drop_drop, ← hu, List.drop_left]
  rw [← hu', hu]

theorem drop_seg {l tail rest : List Std.U8} {a p k : Nat} (hap : a ≤ p) (hk : k < p - a)
    (hp : p ≤ l.length) (hrest : l.drop p ++ tail = rest) :
    (l.slice a p ++ rest).drop k = l.drop (a + k) ++ tail := by
  rw [← hrest, ← List.append_assoc, slice_drop_eq hap,
    List.drop_append_of_le_length (by simp; omega), List.drop_drop]

/-- Kept, up to a `<think>`. -/
theorem step_keep {l tail t : List Std.U8} {th₂ : Bool} {a p : Nat} (hap : a ≤ p)
    (hpre : THINK <+: l.drop p) (h : Unthink true (l.drop (p + 7) ++ tail) t th₂) :
    Unthink false (l.drop a ++ tail) (l.slice a p ++ t) th₂ := by
  have e : l.drop a ++ tail = l.slice a p ++ (THINK ++ (l.drop (p + 7) ++ tail)) := by
    rw [← slice_drop_eq hap, prefix_drop hpre, List.append_assoc]; rfl
  rw [e]
  exact keeps_all (Unthink.enter h)

/-- Skipped, up to a `</think>`: the first from `a`. -/
theorem step_skip {l tail t : List Std.U8} {th₂ : Bool} {a p : Nat} (hap : a ≤ p)
    (hpre : THINK_END <+: l.drop p) (hfirst : ∀ j, a ≤ j → j < p → ¬THINK_END <+: l.drop j)
    (htail : EndsLine tail) (h : Unthink false (l.drop (p + 8) ++ tail) t th₂) :
    Unthink true (l.drop a ++ tail) t th₂ := by
  have hlen := hpre.length_le
  simp only [List.length_drop] at hlen
  have hd := prefix_drop hpre
  have e : l.drop a ++ tail = l.slice a p ++ (THINK_END ++ (l.drop (p + 8) ++ tail)) := by
    rw [← slice_drop_eq hap, hd, List.append_assoc]; rfl
  rw [e]
  refine skips_all (fun k hk => ?_) (Unthink.leave h)
  have hk' : k < p - a := by rw [List.slice_length] at hk; omega
  rw [drop_seg hap hk' (by have : THINK_END.length = 8 := rfl; omega)
    (by rw [hd, List.append_assoc]; rfl)]
  exact tag_local think_end_ok htail (hfirst (a + k) (by omega) (by omega))

/-- Kept, to the end of the line. -/
theorem rest_keep {l tail t : List Std.U8} {th₂ : Bool} {a : Nat}
    (h : Unthink false tail t th₂) : Unthink false (l.drop a ++ tail) (l.drop a ++ t) th₂ :=
  keeps_all h

/-- Skipped, to the end of the line: no `</think>` from `a`. -/
theorem rest_skip {l tail t : List Std.U8} {th₂ : Bool} {a : Nat}
    (hnone : ∀ j, a ≤ j → ¬THINK_END <+: l.drop j) (htail : EndsLine tail)
    (h : Unthink true tail t th₂) : Unthink true (l.drop a ++ tail) t th₂ := by
  refine skips_all (fun k hk => ?_) h
  rw [List.drop_append_of_le_length (by omega), List.drop_drop]
  exact tag_local think_end_ok htail (hnone (a + k) (by omega))

/-- How far `unthink` has read a line `l`: where it is, and what it has kept;
the rest of the line, unless it is done, read from a span if it is in one,
and a tail, give what the line and the tail give. -/
def UInv (l : List Std.U8) (th₀ : Bool) (x : Bool × alloc.vec.Vec Std.U8 × Bool × Usize × Bool) :
    Prop :=
  x.2.2.2.1.val ≤ l.length ∧ 10#u8 ∉ x.2.1.val ∧
  (x.2.2.1 = false → x.1 = th₀ ∧ (th₀ = true → x.2.1.val = [])) ∧
  ∀ tail t th₂, EndsLine tail →
    Unthink x.1 ((if x.2.2.2.2 then [] else l.drop x.2.2.2.1.val) ++ tail) t th₂ →
    Unthink th₀ (l ++ tail) (x.2.1.val ++ t) th₂

/-- What `unthink`'s loop gives: what it kept of a line, and whether it ends
in a span. -/
def UPost (l : List Std.U8) (th₀ : Bool) (y : Bool × alloc.vec.Vec Std.U8 × Bool) : Prop :=
  10#u8 ∉ y.2.1.val ∧ (y.2.2 = false → y.1 = th₀ ∧ (th₀ = true → y.2.1.val = [])) ∧
  ∀ tail t th₂, EndsLine tail → Unthink y.1 tail t th₂ → Unthink th₀ (l ++ tail) (y.2.1.val ++ t) th₂

/-- The two loops of `unthink`, which are the same. -/
theorem unthink_body_keeps (f : Bool) (line : Slice Std.U8) (hl : 10#u8 ∉ line.val)
    (th₀ b : Bool) (visible : alloc.vec.Vec Std.U8) (tagged : Bool) (a : Usize) (done : Bool)
    (h : UInv line.val th₀ (b, visible, tagged, a, done)) :
    Ok (Chunker.unthink_loop0.body f line b visible tagged a done) (fun r => match r with
      | .cont x => UInv line.val th₀ x
      | .done y => UPost line.val th₀ y) := by
  obtain ⟨ha, hv, ht, hk⟩ := h
  dsimp only at ha hv ht hk
  unfold Chunker.unthink_loop0.body
  refine Ok.ite (fun hd => Ok.ret ⟨hv, ht, fun tail t th₂ htl h =>
    hk tail t th₂ htl (by simpa [hd] using h)⟩) (fun hd => ?_)
  simp only [Bool.not_eq_true] at hd
  subst hd
  simp only [Bool.false_eq_true, ↓reduceIte] at hk
  cases b with
  | true =>
    refine Ok.bind (q := fun found : Option Usize =>
      (∀ p ∈ found, a.val ≤ p.val ∧ THINK_END <+: line.val.drop p.val ∧
        ∀ j, a.val ≤ j → j < p.val → ¬THINK_END <+: line.val.drop j) ∧
      (found = none → ∀ j, a.val ≤ j → ¬THINK_END <+: line.val.drop j)) ?_ fun found hf => ?_
    · refine Ok.ite (fun _ => ?_) (fun hb => absurd rfl hb)
      refine Ok.bind (lit_ok _ _ _) fun t ht' => ?_
      refine Ok.mono (find_first _ _ _ (by rw [ht']; simp)) fun r hr => ?_
      rwa [ht'] at hr
    ok_cases
    · refine Ok.ite (fun _ => Ok.ret ⟨ha, hv, ht, fun tail t th₂ htl h =>
        hk tail t th₂ htl (rest_skip (hf.2 rfl) htl (by simpa using h))⟩) (fun hb => absurd rfl hb)
    · rename_i p
      obtain ⟨hap, hpre, hfirst⟩ := hf.1 p rfl
      have hlen := hpre.length_le
      simp only [List.length_drop] at hlen
      have h8 : THINK_END.length = 8 := rfl
      refine Ok.bind (q := fun v : alloc.vec.Vec Std.U8 => v = visible)
        (Ok.ite (fun _ => Ok.ret rfl) (fun hb => absurd rfl hb)) fun v1 hv1 => ?_
      subst hv1
      refine Ok.bind (q := fun i : Usize => i.val = 8)
        (Ok.ite (fun _ => Ok.ret rfl) (fun hb => absurd rfl hb)) fun i hi => ?_
      refine Ok.bind (add_ok _ _) fun a1 ha1 => Ok.ret ⟨by scalar_tac, hv, fun h => by simp at h,
        fun tail t th₂ htl h => hk tail t th₂ htl (step_skip hap hpre hfirst htl ?_)⟩
      simp only [decide_not, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
      rwa [ha1, hi] at h
  | false =>
    refine Ok.bind (q := fun found : Option Usize =>
      ∀ p ∈ found, a.val ≤ p.val ∧ THINK <+: line.val.drop p.val) ?_ fun found hf => ?_
    · refine Ok.ite (fun hb => absurd hb (by simp)) (fun _ => ?_)
      exact Ok.ite (fun _ => Ok.ret (by simp)) (fun _ => think_tag_ok _ _)
    ok_cases
    · refine Ok.ite (fun hb => absurd hb (by simp)) (fun _ => ?_)
      refine Ok.bind (range_from_ok _ _) fun s ⟨hs, _⟩ => ?_
      refine Ok.bind (bytes_extend_ok _ _) fun v1 hv1 => Ok.ret ⟨ha, ?_, ?_, ?_⟩
      · rw [hv1, hs]
        simp only [List.mem_append, not_or]
        exact ⟨hv, fun h => hl (List.mem_of_mem_drop h)⟩
      · intro htg
        obtain ⟨rfl, _⟩ := ht htg
        exact ⟨rfl, fun h => by simp at h⟩
      · intro tail t th₂ htl h
        rw [hv1, hs, List.append_assoc]
        exact hk tail _ th₂ htl (rest_keep (by simpa using h))
    · rename_i p
      obtain ⟨hap, hpre⟩ := hf p rfl
      have hlen := hpre.length_le
      simp only [List.length_drop] at hlen
      have h7 : THINK.length = 7 := rfl
      refine Ok.bind (q := fun v : alloc.vec.Vec Std.U8 => v.val = visible.val ++ line.val.slice a.val p.val)
        ?_ fun v1 hv1 => ?_
      · refine Ok.ite (fun hb => absurd hb (by simp)) (fun _ => ?_)
        refine Ok.bind (range_ok _ _ _) fun s ⟨hs, _⟩ => Ok.mono (bytes_extend_ok _ _) fun v h => ?_
        rw [h, hs]
      refine Ok.bind (q := fun i : Usize => i.val = 7)
        (Ok.ite (fun hb => absurd hb (by simp)) (fun _ => Ok.ret rfl)) fun i hi => ?_
      refine Ok.bind (add_ok _ _) fun a1 ha1 => Ok.ret ⟨by scalar_tac, ?_, fun h => by simp at h,
        fun tail t th₂ htl h => ?_⟩
      · rw [hv1]
        simp only [List.mem_append, not_or]
        exact ⟨hv, fun h => hl (mem_of_mem_slice h)⟩
      · simp only [decide_not, decide_false, Bool.not_false, Bool.false_eq_true, ↓reduceIte] at h
        rw [ha1, hi] at h
        rw [hv1, List.append_assoc]
        exact hk tail _ th₂ htl (step_keep hap hpre h)

theorem unthink_loop0_keeps (f : Bool) (line : Slice Std.U8) (hl : 10#u8 ∉ line.val)
    (th₀ b : Bool) (visible : alloc.vec.Vec Std.U8) (tagged : Bool) (a : Usize) (done : Bool)
    (h : UInv line.val th₀ (b, visible, tagged, a, done)) :
    Ok (Chunker.unthink_loop0 f b line visible tagged a done) (UPost line.val th₀) := by
  unfold Chunker.unthink_loop0
  refine Ok.loop _ (UInv line.val th₀) _ ?_ _ h
  rintro ⟨b, visible, tagged, a, done⟩ h
  dsimp only
  refine Ok.mono (unthink_body_keeps f line hl th₀ b visible tagged a done h) fun r hr => ?_
  cases r <;> exact hr

theorem unthink_loop1_keeps (f : Bool) (line : Slice Std.U8) (hl : 10#u8 ∉ line.val)
    (th₀ b : Bool) (visible : alloc.vec.Vec Std.U8) (tagged : Bool) (a : Usize) (done : Bool)
    (h : UInv line.val th₀ (b, visible, tagged, a, done)) :
    Ok (Chunker.unthink_loop1 f b line visible tagged a done) (UPost line.val th₀) := by
  unfold Chunker.unthink_loop1
  refine Ok.loop _ (UInv line.val th₀) _ ?_ _ h
  rintro ⟨b, visible, tagged, a, done⟩ h
  dsimp only
  refine Ok.mono (unthink_body_keeps f line hl th₀ b visible tagged a done h) fun r hr => ?_
  cases r <;> exact hr

/-- What `unthink` leaves of a line `l`, `o`: none if the line is wholly in a
span; read from a span if `th`, it ends in one if `th'`. -/
def UL (th : Bool) (l : List Std.U8) (o : Option (List Std.U8)) (th' : Bool) : Prop :=
  (o = none → th' = true) ∧ (∀ v ∈ o, 10#u8 ∉ v) ∧
  ∀ tail t th₂, EndsLine tail → Unthink th' tail t th₂ → Unthink th (l ++ tail) (o.getD [] ++ t) th₂

theorem uinv_start (l : List Std.U8) (th₀ : Bool) :
    UInv l th₀ (th₀, alloc.vec.Vec.new Std.U8, false, 0#usize, false) :=
  ⟨by simp, by simp [alloc.vec.Vec.new], fun _ => ⟨rfl, fun _ => rfl⟩,
    fun tail t th₂ _ h => by simpa [alloc.vec.Vec.new] using h⟩

theorem unthink_keeps (c : Chunker) (line : Slice Std.U8) (hl : 10#u8 ∉ line.val) :
    Ok (Chunker.unthink c line) (fun r => r.2.lines = c.lines ∧ r.2.partial = c.partial ∧
      UL c.thinking line.val (r.1.map (·.val)) r.2.thinking) := by
  unfold Chunker.unthink
  refine Ok.ite (fun hth => ?_) (fun hth => ?_)
  · refine Ok.bind (unthink_loop0_keeps _ _ hl c.thinking _ _ _ _ _ (uinv_start _ _))
      fun ⟨b, v, t⟩ ⟨hv, ht, hk⟩ => ?_
    refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
    refine Ok.ite (fun _ => Ok.ret ⟨rfl, rfl, fun h => by simp at h, by simpa using hv,
      fun tail t th₂ htl h => hk tail t th₂ htl h⟩) (fun htg => ?_)
    obtain ⟨hb, hv0⟩ := ht (by simpa using htg)
    refine Ok.ite (fun hb' => Ok.ret ⟨rfl, rfl, fun _ => hth, by simp,
      fun tail t th₂ htl h => ?_⟩) (fun hb' => Ok.ret ⟨rfl, rfl, fun h => by simp at h, by simpa using hv,
      fun tail t th₂ htl h => hk tail t th₂ htl h⟩)
    have := hk tail t th₂ htl (by rw [hb]; exact h)
    rwa [hv0 hth] at this
  · simp only [Bool.not_eq_true] at hth
    refine Ok.ite (fun _ => ?whole) (fun _ => Ok.then_ fun o _ =>
      Ok.ite (fun _ => ?whole') (fun _ => ?loop))
    case loop =>
      refine Ok.bind (unthink_loop1_keeps _ _ hl c.thinking _ _ _ _ _ (uinv_start _ _))
        fun ⟨b, v, t⟩ ⟨hv, ht, hk⟩ => ?_
      refine Ok.uncurry_mk (Ok.uncurry_mk ?_)
      refine Ok.ite (fun _ => Ok.ret ⟨rfl, rfl, fun h => by simp at h, by simpa using hv,
        fun tail t th₂ htl h => hk tail t th₂ htl h⟩) (fun htg => ?_)
      obtain ⟨hb, hv0⟩ := ht (by simpa using htg)
      refine Ok.ite (fun hb' => Ok.ret ⟨rfl, rfl, fun _ => hb', by simp,
        fun tail t th₂ htl h => ?_⟩) (fun hb' => Ok.ret ⟨rfl, rfl, fun h => by simp at h,
          by simpa using hv, fun tail t th₂ htl h => hk tail t th₂ htl (by rw [hb]; exact h)⟩)
      · have hb2 : b = c.thinking := hb
        exact absurd (hb2.symm.trans hb') (by simp [hth])
    all_goals
      refine Ok.bind (bytes_extend_ok _ _) fun v hv => Ok.ret ⟨rfl, rfl, fun h => by simp at h,
        ?_, fun tail t th₂ htl h => ?_⟩
      · simp only [Option.map_some, Option.mem_def, Option.some.injEq, forall_eq']
        simpa [hv, alloc.vec.Vec.new] using hl
      · have hv' : v.val = line.val := by simpa [alloc.vec.Vec.new] using hv
        have := rest_keep (l := line.val) (a := 0) (by rw [← hth]; exact h)
        rw [hth]
        simpa [hv'] using this

/-! ## The stream -/

theorem Inv.of_lines {c c' : Chunker} {sent ps : List (List Std.U8)} (h : Inv c sent ps)
    (e : c'.lines = c.lines) : Inv c' sent ps := by
  unfold Inv at *; rw [e]; exact h

/-- Once the chunker holds no lines, what it has sent holds all the pieces. -/
theorem Inv.sent {c : Chunker} {sent ps : List (List Std.U8)} (h : Inv c sent ps)
    (hl : c.lines.val = []) : Sent sent ps := by
  obtain ⟨_, ps₁, ps₂, rfl, ⟨cs₁, hcs₁, hs⟩, hh⟩ := h
  rw [vals, hl, List.map_nil] at hh
  obtain ⟨cs₂, hcs₂, he⟩ := hh.dels .nil
  exact ⟨cs₁ ++ cs₂, List.rel_append hcs₁ hcs₂, by rw [hs, List.flatten_append, he]; simp⟩

theorem end_clears (c : Chunker) (chunk : alloc.vec.Vec Std.U8) (out : Out) :
    Ok (Chunker.end c chunk out) (fun r => r.1.lines.val = []) := by
  unfold Chunker.end
  refine Ok.then_ fun _ _ => ?_
  split
  · exact Ok.ret rfl
  · exact Ok.then_ fun _ _ => Ok.ret rfl

/-- What a line, `raw`, leaves after `<think>` spans, and the pieces of that. -/
theorem line_keeps (c : Chunker) (raw : Slice Std.U8) (pre ps : List (List Std.U8))
    (h : Inv c pre ps) (hr : 10#u8 ∉ raw.val) :
    Ok (Chunker.line c raw) (fun r => r.2.partial = c.partial ∧ ∃ o K,
      UL c.thinking raw.val o r.2.thinking ∧ Msg (o.getD []) K ∧
      Inv r.2 (pre ++ vals r.1) (ps ++ K)) := by
  unfold Chunker.line
  refine Ok.bind (unthink_keeps _ _ hr) fun ⟨o, c1⟩ ⟨hl1, hp1, hu⟩ => ?_
  have hc1 : Inv c1 pre ps := h.of_lines hl1
  refine Ok.uncurry_mk ?_
  ok_cases
  · exact Ok.ret ⟨hp1, none, [[]], by simpa using hu, Msg.whole _,
      by simpa using hc1.blank Spaces.nil⟩
  · rename_i line _
    have hv := hu.2.1 line.val (by simp)
    refine Ok.bind (classify_keeps _ _ _ pre ps (by simpa using hc1)
      (by simpa [alloc.vec.Vec.deref] using hv)) fun ⟨c2, out⟩ ⟨hs2, K, hc2, hK⟩ => ?_
    refine Ok.uncurry_mk (Ok.ret ⟨hs2.2.trans hp1, some line.val, K, ?_,
      by simpa [alloc.vec.Vec.deref] using hK, hc2⟩)
    dsimp only
    rw [hs2.1]
    simpa using hu

theorem take_line_loop_crs (v : alloc.vec.Vec Std.U8) (e : Usize) (he : e.val ≤ v.length)
    (hr : ∀ j (h : j < v.length), e.val ≤ j → v.val[j] = 13#u8) :
    Ok (Chunker.take_line_loop v e)
      (fun r => r.val ≤ v.length ∧ ∀ j (h : j < v.length), r.val ≤ j → v.val[j] = 13#u8) := by
  unfold Chunker.take_line_loop
  refine Ok.loop _ (fun e : Usize => e.val ≤ v.length ∧
    ∀ j (h : j < v.length), e.val ≤ j → v.val[j] = 13#u8) _ ?_ _ ⟨he, hr⟩
  intro e ⟨he, hr⟩
  unfold Chunker.take_line_loop.body
  refine Ok.ite (fun _ => ?_) (fun _ => Ok.ret ⟨he, hr⟩)
  refine Ok.bind (sub_ok _ _) fun i hi => ?_
  refine Ok.bind (vec_index_ok _ _) fun b ⟨hb, hb'⟩ => ?_
  refine Ok.ite (fun h13 => Ok.ret ⟨by scalar_tac, fun j hj hij => ?_⟩) (fun _ => Ok.ret ⟨he, hr⟩)
  by_cases hji : j = i.val
  · subst hji; rw [hb', h13]
  · exact hr j hj (by scalar_tac)

/-- The line before a newline, and the carriage returns after it. -/
theorem take_line_keeps (c : Chunker) :
    Ok (Chunker.take_line c) (fun r => r.2.lines = c.lines ∧ r.2.thinking = c.thinking ∧
      r.2.partial.val = [] ∧ ∃ crs, (∀ x ∈ crs, x = 13#u8) ∧ c.partial.val = r.1.val ++ crs) := by
  unfold Chunker.take_line
  refine Ok.bind (take_line_loop_crs _ _ (by simp) (fun j hj hle => by
      have : c.partial.length = c.partial.val.length := rfl
      simp at hle; omega))
    fun e ⟨he, hr⟩ => ?_
  refine Ok.bind (vec_range_to_ok _ _) fun t ⟨ht, _⟩ => ?_
  refine Ok.bind (bytes_extend_ok _ _) fun line hline =>
    Ok.ret ⟨rfl, rfl, rfl, c.partial.val.drop e.val, ?_, ?_⟩
  · intro x hx
    obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hx
    rw [List.getElem_drop]
    simp only [List.length_drop] at hk
    exact hr _ (by simp; omega) (by omega)
  · dsimp only
    rw [hline, ht]
    simp [alloc.vec.Vec.new]

theorem crs_newline {rs s t : List Std.U8} {th th₂ : Bool} (hr : ∀ r ∈ rs, r = 13#u8)
    (h : Unthink th s t th₂) : Unthink th (rs ++ 10#u8 :: s) (10#u8 :: t) th₂ := by
  cases th with
  | false => exact Unthink.crs hr h
  | true =>
    induction rs with
    | nil => exact Unthink.newline h
    | cons r rs ih =>
      obtain rfl := hr r (by simp)
      refine Unthink.skip (fun ⟨u, hu⟩ => by simp at hu) (ih fun x hx => hr x (by simp [hx]))

theorem map_snoc_nl (vs : List (List Std.U8)) (x : List Std.U8) :
    ((vs ++ [x]).map (· ++ [10#u8])).flatten = (vs.map (· ++ [10#u8])).flatten ++ x ++ [10#u8] := by
  simp

theorem intercalate_snoc' : ∀ (vs : List (List Std.U8)) (x : List Std.U8),
    [10#u8].intercalate (vs ++ [x]) = (vs.map (· ++ [10#u8])).flatten ++ x
  | [], x => by simp
  | [v], x => by simp [List.intercalate_cons_cons]
  | v :: v' :: vs, x => by
    rw [List.cons_append, List.cons_append, List.intercalate_cons_cons, ← List.cons_append,
      intercalate_snoc' (v' :: vs) x]
    simp

/-- How far the chunker has read a text: the lines so far, which leave the
visible lines `vs`, of the pieces `pss`; the pieces the chunker has sent or
holds; and the text after the last newline, in `partial`. -/
def SInv (text : List Std.U8) (c : Chunker) (sent : List (List Std.U8)) : Prop :=
  10#u8 ∉ c.partial.val ∧ ∃ (done : List Std.U8) (vs : List (List Std.U8))
    (pss : List (List (List Std.U8))), text = done ++ c.partial.val ∧ (∀ v ∈ vs, 10#u8 ∉ v) ∧
    (∀ s t th₂, Unthink c.thinking s t th₂ →
      Unthink false (done ++ s) ((vs.map (· ++ [10#u8])).flatten ++ t) th₂) ∧
    List.Forall₂ Msg vs pss ∧ Inv c sent pss.flatten

theorem step_keeps (c : Chunker) (out : Out) (b : Std.U8) (text : List Std.U8)
    (pre : List (List Std.U8)) (h : SInv text c (pre ++ vals out)) :
    Ok (step c out b) (fun r => SInv (text ++ [b]) r.1 (pre ++ vals r.2)) := by
  obtain ⟨hp, done, vs, pss, rfl, hvs, hk, hm, hc⟩ := h
  unfold step
  split
  · rename_i h10
    subst h10
    refine Ok.bind (take_line_keeps c) fun ⟨line, c1⟩ ⟨hl1, ht1, hp1, crs, hcrs, hpart⟩ => ?_
    refine Ok.uncurry_mk ?_
    refine Ok.bind (line_keeps c1 _ _ _ (hc.of_lines hl1) ?_)
      fun ⟨chunks, c2⟩ ⟨hp2, o, K, hu, hK, hc2⟩ => ?_
    · intro h
      apply hp
      rw [hpart]
      exact List.mem_append_left _ (by simpa [alloc.vec.Vec.deref] using h)
    refine Ok.uncurry_mk (Ok.then_ fun out' hout => Ok.ret ⟨?_, done ++ c.partial.val ++ [10#u8],
      vs ++ [o.getD []], pss ++ [K], ?_, ?_, ?_, List.rel_append hm (.cons hK .nil), ?_⟩)
    · dsimp only; rw [hp2, hp1]; simp
    · dsimp only; rw [hp2, hp1]; simp
    · intro v hv
      rcases List.mem_append.mp hv with hv | hv
      · exact hvs v hv
      · simp only [List.mem_singleton] at hv
        subst hv
        cases o with
        | none => simp
        | some x => exact hu.2.1 x rfl
    · intro s t th₂ hst
      have hend : EndsLine (crs ++ 10#u8 :: s) := by
        intro x hx
        cases crs with
        | nil =>
          simp only [List.nil_append, List.head?_cons, Option.mem_def, Option.some.injEq] at hx
          exact Or.inl hx.symm
        | cons r rs =>
          simp only [List.cons_append, List.head?_cons, Option.mem_def, Option.some.injEq] at hx
          exact Or.inr (by subst hx; exact hcrs _ (by simp))
      have hd : (alloc.vec.Vec.deref line).val = line.val := by simp [alloc.vec.Vec.deref]
      dsimp only at hu hst hpart ht1
      rw [hd] at hu
      have hin : Unthink c.thinking (c.partial.val ++ 10#u8 :: s) (o.getD [] ++ 10#u8 :: t) th₂ := by
        rw [← ht1, hpart, List.append_assoc]
        exact hu.2.2 _ _ _ hend (crs_newline hcrs hst)
      simpa [map_snoc_nl] using hk _ _ _ hin
    · have : vals out' = vals out ++ vals chunks := by
        simp [vals, (extend_eq_ok _ _ _).mp hout]
      rw [this, List.flatten_append, List.flatten_singleton, ← List.append_assoc]
      exact hc2
  · refine Ok.bind (bytes_push_ok _ _) fun v hv => Ok.ret ⟨?_, done, vs, pss, ?_, hvs, hk, hm, hc⟩
    · rename_i hb
      dsimp only
      rw [hv]
      simp only [List.mem_append, List.mem_singleton, not_or]
      exact ⟨hp, fun e => hb e.symm⟩
    · dsimp only; rw [hv, List.append_assoc]

theorem steps_keeps (c : Chunker) (out : Out) (bs text : List Std.U8) (pre : List (List Std.U8))
    (h : SInv text c (pre ++ vals out)) :
    Ok (steps c out bs) (fun r => SInv (text ++ bs) r.1 (pre ++ vals r.2)) := by
  induction bs generalizing c out text with
  | nil => exact Ok.ret (by simpa using h)
  | cons b bs ih =>
    simp only [steps]
    refine Ok.bind (step_keeps c out b text pre h) fun ⟨c1, out1⟩ h1 => ?_
    simpa using ih c1 out1 (text ++ [b]) h1

theorem push_keeps (c : Chunker) (d : Slice Std.U8) (out : Out) (text : List Std.U8)
    (pre : List (List Std.U8)) (h : SInv text c (pre ++ vals out)) :
    Ok (Chunker.push c d out) (fun r => SInv (text ++ d.val) r.1 (pre ++ vals r.2)) := by
  rw [push_eq]
  exact steps_keeps c out d.val text pre h

/-- At the end, the last line, and what the chunker holds, sent. -/
theorem finish_keeps (c : Chunker) (out : Out) (text : List Std.U8) (pre : List (List Std.U8))
    (h : SInv text c (pre ++ vals out)) :
    Ok (Chunker.finish c out) (fun r => Keeps text (pre ++ vals r.2)) := by
  obtain ⟨hp, done, vs, pss, rfl, hvs, hk, hm, hc⟩ := h
  unfold Chunker.finish
  refine Ok.then_ fun b hb => ?_
  refine Ok.bind (q := fun r : Chunker × Out => ∃ (vs' : List (List Std.U8))
      (pss' : List (List (List Std.U8))), (∀ v ∈ vs', 10#u8 ∉ v) ∧
      (∃ th, Unthink false (done ++ c.partial.val) ([10#u8].intercalate vs') th) ∧
      List.Forall₂ Msg vs' pss' ∧ Inv r.1 (pre ++ vals out ++ vals r.2) pss'.flatten) ?_
    fun ⟨c1, chunks⟩ ⟨vs', pss', hvs', ⟨th, hu⟩, hm', hc1⟩ => ?_
  · refine Ok.ite (fun hb' => ?_) (fun hb' => ?_)
    · have h0 : c.partial.val = [] := (vec_is_empty_ok hb).mp hb'
      refine Ok.ret ⟨vs ++ [[]], pss ++ [[[]]], ?_, ⟨c.thinking, ?_⟩,
        List.rel_append hm (.cons (Msg.whole _) .nil), ?_⟩
      · intro v hv
        rcases List.mem_append.mp hv with hv | hv
        · exact hvs v hv
        · simp at hv; simp [hv]
      · rw [intercalate_snoc', h0, List.append_nil]
        simpa using hk [] [] c.thinking (Unthink.nil _)
      · simpa using hc.blank Spaces.nil
    · refine Ok.bind (bytes_extend_ok _ _) fun rest hrest => ?_
      refine Ok.bind (line_keeps { c with «partial» := alloc.vec.Vec.new Std.U8 } _ _ _ hc ?_)
        fun ⟨chunks1, c2⟩ ⟨_, o, K, hu, hK, hc2⟩ => ?_
      · simpa [alloc.vec.Vec.deref, hrest, alloc.vec.Vec.new] using hp
      refine Ok.uncurry_mk (Ok.ret ⟨vs ++ [o.getD []], pss ++ [K], ?_, ⟨c2.thinking, ?_⟩,
        List.rel_append hm (.cons hK .nil), by simpa using hc2⟩)
      · intro v hv
        rcases List.mem_append.mp hv with hv | hv
        · exact hvs v hv
        · simp only [List.mem_singleton] at hv
          subst hv
          cases o with
          | none => simp
          | some x => exact hu.2.1 x rfl
      · rw [intercalate_snoc']
        have hr : (alloc.vec.Vec.deref rest).val = c.partial.val := by
          simp [alloc.vec.Vec.deref, hrest, alloc.vec.Vec.new]
        have := hu.2.2 [] [] c2.thinking (fun x hx => by simp at hx) (Unthink.nil _)
        rw [hr] at this
        simpa using hk _ _ _ (by simpa using this)
  refine Ok.uncurry_mk ?_
  refine Ok.bind (chunk_text_keeps _) fun last hlast => ?_
  refine Ok.bind (Ok.and (end_keeps _ _ _ _ _ hc1 (by simpa [alloc.vec.Vec.deref] using hlast))
    (end_clears _ _ _)) fun ⟨c2, chunks2⟩ ⟨⟨hc2, _⟩, hl2⟩ => ?_
  refine Ok.uncurry_mk (Ok.then_ fun out' hout => Ok.ret ⟨vs', th, hvs', hu, pss', hm', ?_⟩)
  have hs := hc2.sent hl2
  have : vals out' = vals out ++ vals chunks2 := by
    simp [vals, (extend_eq_ok _ _ _).mp hout]
  rw [this, ← List.append_assoc]
  exact hs

/-- The chunks as `segment.rs` gets them keep what the text gives. -/
theorem wrapper_keeps (c : Chunker) (pieces : List (Slice Std.U8)) (text : List Std.U8)
    (pre : List (List Std.U8)) (h : SInv text c pre) :
    Ok (wrapper c pieces) (fun L => Keeps (text ++ (pieces.map Slice.val).flatten)
      (pre ++ L.map (·.val))) := by
  induction pieces generalizing c text pre with
  | nil =>
    simp only [wrapper]
    refine Ok.bind (finish_keeps c empty text pre (by simpa using h)) fun ⟨_, o⟩ ho => ?_
    exact Ok.uncurry_mk (Ok.ret (by simpa using ho))
  | cons d ds ih =>
    simp only [wrapper]
    refine Ok.bind (push_keeps c d empty text pre (by simpa using h)) fun ⟨c1, o⟩ h1 => ?_
    refine Ok.uncurry_mk ?_
    refine Ok.bind (ih c1 (text ++ d.val) (pre ++ vals o) h1) fun L hL => Ok.ret ?_
    simpa [List.append_assoc] using hL

theorem sinv_default :
    SInv [] (⟨alloc.vec.Vec.new _, alloc.vec.Vec.new _, false, false, false⟩ : Chunker) [] := by
  refine ⟨by simp [alloc.vec.Vec.new], [], [], [], by simp [alloc.vec.Vec.new], by simp,
    fun s t th₂ h => by simpa using h, .nil, ?_⟩
  exact ⟨by simp, [], [], rfl, ⟨[], .nil, rfl⟩, by simpa using HeldL.nil⟩

/-! ## Nothing is dropped -/

/-- Nothing is dropped: however a text is streamed, if the chunker returns,
its chunks keep all of the text but whitespace, `[split]`, `<think>` spans
and break lines. -/
theorem keeps_of_ok (pieces : List (Slice Std.U8)) (L : List (alloc.vec.Vec Std.U8))
    (hw : (do let c ← Chunker.Insts.CoreDefaultDefault.default; wrapper c pieces) = ok L) :
    Keeps (pieces.map Slice.val).flatten (L.map (·.val)) := by
  simp only [Chunker.Insts.CoreDefaultDefault.default, bind_ok] at hw
  simpa using (wrapper_keeps _ pieces [] [] sinv_default).result hw

/-- And it returns. -/
theorem keeps (pieces : List (Slice Std.U8)) (h : 2 * textLength pieces + 2 ≤ Usize.max) :
    ∃ L, (do let c ← Chunker.Insts.CoreDefaultDefault.default; wrapper c pieces) = ok L ∧
      Keeps (pieces.map Slice.val).flatten (L.map (·.val)) :=
  let ⟨L, hL⟩ := returns pieces h
  ⟨L, hL, keeps_of_ok pieces L hL⟩

end MaxVerify
