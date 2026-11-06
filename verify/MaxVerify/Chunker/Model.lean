/-!
# The chunker

A model of `max_core::segment::Chunker` (`crates/max-core/src/segment.rs`)
and of the two functions of `segment/parse.rs` it calls, `quote` and
`picture`. It follows the Rust function by function, so that a difference
between the two is easy to find; `diff/` runs both on the same random texts
and compares.

Text is a `List Char` here, not a `&str`, and positions count characters
rather than bytes. Every position the Rust cuts at or compares is at a
character boundary, and the markers it looks for are ASCII, so the pieces
are the same and positions compare the same way.

Where the Rust loop needs a step of at least one to end, and its step is
always at least one, the model writes `max _ 1` so that Lean sees it end.
-/

namespace MaxVerify.Chunker

abbrev Text := List Char

/-! ## `str` methods -/

/-- `char::is_whitespace`: the Unicode `White_Space` property. Lean's
`Char.isWhitespace` is ASCII only; Max's text has U+3000 and U+00A0. -/
def isWs (c : Char) : Bool :=
  let n := c.toNat
  (0x09 ≤ n && n ≤ 0x0D) || n == 0x20 || n == 0x85 || n == 0xA0 || n == 0x1680
    || (0x2000 ≤ n && n ≤ 0x200A) || n == 0x2028 || n == 0x2029 || n == 0x202F
    || n == 0x205F || n == 0x3000

def trimStart (s : Text) : Text := s.dropWhile isWs
def trimEnd (s : Text) : Text := (s.reverse.dropWhile isWs).reverse
def trim (s : Text) : Text := trimEnd (trimStart s)

/-- `s.find(pat)`: where `pat` first starts. -/
def find (pat : Text) : Text → Option Nat
  | [] => if pat.isEmpty then some 0 else none
  | s@(_ :: t) => if pat.isPrefixOf s then some 0 else (find pat t).map (· + 1)

theorem find_le {pat s : Text} {p : Nat} (h : find pat s = some p) :
    p + pat.length ≤ s.length := by
  induction s generalizing p with
  | nil =>
    simp only [find] at h
    split at h
    · rename_i hp
      simp only [Option.some.injEq] at h
      subst h
      simp [List.isEmpty_iff.mp hp]
    · simp at h
  | cons x t ih =>
    simp only [find] at h
    split at h
    · rename_i hp
      simp only [Option.some.injEq] at h
      subst h
      have := (List.isPrefixOf_iff_prefix.mp hp).length_le
      simpa using this
    · cases ht : find pat t with
      | none => simp [ht] at h
      | some q =>
        simp only [ht, Option.map_some, Option.some.injEq] at h
        have := ih ht
        simp only [List.length_cons]
        omega

/-- Where `pat` starts, every place, in order. `match_indices` gives only
the ones that don't overlap, but `[split]` can't overlap itself, and `[` is
one character. -/
def positions (pat s : Text) : List Nat :=
  (List.range s.length).filter fun i => pat.isPrefixOf (s.drop i)

/-! ## `parse::quote` and `parse::picture` -/

/-- `digits`: a run of ASCII digits, as an `i64`, and its length. -/
def digits (s : Text) : Option (Nat × Nat) :=
  let ds := s.takeWhile Char.isDigit
  let n := ds.foldl (fun acc c => acc * 10 + (c.toNat - '0'.toNat)) 0
  if ds.isEmpty || n > 9223372036854775807 then none else some (n, ds.length)

/-- `closer`: `]` or `: description]`, then an optional `(attributes)`
group; its length. The description doesn't matter here. -/
def closer (s : Text) : Option Nat := do
  let len ← match s with
    | ']' :: _ => some 1
    | ':' :: rest => (find [']'] rest).map fun e => 1 + e + 1
    | _ => none
  let after := s.drop len
  match after with
  | '(' :: _ =>
    match find [')'] after with
    | some e => some (len + e + 1)
    | none => some len
  | _ => some len

inductive Token where
  | reply
  | mention
  | picture
  | display
  deriving DecidableEq

def media : List Text := ["image", "sticker", "video", "audio", "file"].map String.toList

/-- `placeholder`: the token `s` starts with, and its length. -/
def placeholder (s : Text) : Option (Token × Nat) := do
  let body ← match s with
    | '[' :: b => some b
    | _ => none
  let hash ← find ['#'] body
  let verb := body.take hash
  let rest := body.drop (hash + 1)
  let (_, n) ← digits rest
  let medium := media.contains verb
  -- `u16::try_from(n).ok()`: whether there is an ordinal.
  let (ordinal, pos) ←
    if medium && (rest.drop n).head? == some '.' then
      (digits (rest.drop (n + 1))).map fun (k, len) => (decide (k ≤ 65535), n + 1 + len)
    else some (false, n)
  let len ← closer (rest.drop pos)
  let token ←
    if verb == "reply".toList then some Token.reply
    else if verb == "mention".toList then some Token.mention
    else if (verb == "image".toList || verb == "sticker".toList) && ordinal then
      some Token.picture
    else if verb == "face".toList then some Token.display
    else if medium then some Token.display
    else none
  pure (token, 1 + hash + 1 + pos + len)

def quote (s : Text) : Bool :=
  match placeholder s with
  | some (.reply, _) => true
  | _ => false

def picture (s : Text) : Option Nat :=
  match placeholder s with
  | some (.picture, len) => some len
  | _ => none

/-! ## Lines -/

def isFence (line : Text) : Bool := "```".toList.isPrefixOf (trimStart line)

def isHeading (line : Text) : Bool :=
  let marks := (line.takeWhile (· == '#')).length
  let rest := line.drop marks
  1 ≤ marks && marks ≤ 6 && (rest.head? == some ' ' || rest.head? == some '\t')
    && !(trim rest).isEmpty

def isBreak (line : Text) : Bool :=
  match line.filter (fun c => !isWs c) with
  | m :: ms => ms.length ≥ 2 && (m == '-' || m == '*' || m == '_') && ms.all (· == m)
  | [] => false

/-- The length of the run of backticks at `i`. -/
def run (s : Text) (i : Nat) : Nat := ((s.drop i).takeWhile (· == '`')).length

/-- Where a run of `ticks` backticks closes, looking from `j`: the end of the
next run of exactly as many. -/
def closing (s : Text) (ticks j : Nat) : Option Nat :=
  if _h : j < s.length then
    if s[j]? != some '`' then closing s ticks (j + 1)
    else
      let n := run s j
      if n == ticks then some (j + n) else closing s ticks (j + max n 1)
  else none
termination_by s.length - j

/-- `code_spans`: the inline code spans of a line, as `(start, end)`. -/
def codeSpansFrom (s : Text) (i : Nat) : List (Nat × Nat) :=
  if _h : i < s.length then
    if s[i]? != some '`' then codeSpansFrom s (i + 1)
    else
      let ticks := max (run s i) 1
      match closing s ticks (i + ticks) with
      | some e => (i, e) :: codeSpansFrom s (max e (i + 1))
      | none => codeSpansFrom s (i + ticks)
  else []
termination_by s.length - i

def codeSpans (s : Text) : List (Nat × Nat) := codeSpansFrom s 0

def outside (spans : List (Nat × Nat)) (pos : Nat) : Bool :=
  !spans.any fun (a, b) => a ≤ pos && pos < b

def split : Text := "[split]".toList

/-- `(usize, usize, bool)` in Rust's order. -/
def Cut.lt (a b : Nat × Nat × Bool) : Bool :=
  a.1 < b.1 || (a.1 == b.1 && (a.2.1 < b.2.1 || (a.2.1 == b.2.1 && !a.2.2 && b.2.2)))

def Cut.min : Option (Nat × Nat × Bool) → Option (Nat × Nat × Bool) → Option (Nat × Nat × Bool)
  | none, b => b
  | a, none => a
  | some a, some b => some (if Cut.lt b a then b else a)

/-- `next_cut`: the first `[split]` or picture handle outside the line's
code spans: where, how long, and whether it is a picture. -/
def nextCut (line : Text) : Option (Nat × Nat × Bool) :=
  let spans := codeSpans line
  let atSplit := ((positions split line).find? (outside spans)).map fun p => (p, split.length, false)
  let atPicture := ((positions ['['] line).filter (outside spans)).findSome? fun p =>
    (picture (line.drop p)).map fun len => (p, len, true)
  Cut.min atSplit atPicture

/-- `<think>`. -/
def opening : Text := ['<', 't', 'h', 'i', 'n', 'k', '>']
/-- `</think>`. -/
def closingTag : Text := ['<', '/', 't', 'h', 'i', 'n', 'k', '>']

def tagFor (thinking : Bool) : Text := if thinking then closingTag else opening

theorem tagFor_length (thinking : Bool) : 0 < (tagFor thinking).length := by
  cases thinking <;> simp [tagFor, closingTag, opening]

/-- The loop in `unthink`. -/
def unthinkLoop (thinking : Bool) (rest visible : Text) (tagged : Bool) : Text × Bool × Bool :=
  match _h : find (tagFor thinking) rest with
  | none => (if thinking then visible else visible ++ rest, thinking, tagged)
  | some p =>
    let visible := if thinking then visible else visible ++ rest.take p
    unthinkLoop (!thinking) (rest.drop (p + (tagFor thinking).length)) visible true
termination_by rest.length
decreasing_by
  have := find_le _h
  have := tagFor_length thinking
  simp only [List.length_drop]
  omega

/-- `unthink`: the part of a line outside `<think>` spans, none for a line
wholly inside one; and whether a span is open after it. -/
def unthink (thinking : Bool) (line : Text) : Option Text × Bool :=
  if !thinking && (find opening line).isNone then (some line, thinking)
  else
    let (visible, thinking', tagged) := unthinkLoop thinking line [] false
    (if tagged || !thinking' then some visible else none, thinking')

/-! ## The chunker -/

/-- What `Chunker` keeps besides the text after the last newline. -/
structure State where
  /-- The complete lines of the chunk being built. -/
  lines : List Text := []
  inFence : Bool := false
  thinking : Bool := false
  /-- A heading came: cut at headings, not at blank lines. -/
  sections : Bool := false

def State.push (st : State) (line : Text) : State := { st with lines := st.lines ++ [line] }

/-- `cut`: the chunk built so far, unless it is blank. -/
def State.cut (st : State) : State × List Text :=
  let text := trim (List.intercalate ['\n'] st.lines)
  ({ st with lines := [] }, if text.isEmpty then [] else [text])

/-- The `while let Some(..) = next_cut(rest)` loop at the end of `line`. -/
def State.pieces (st : State) (rest : Text) : State × List Text :=
  if rest = [] then (st.push rest, [])  -- `next_cut("")` is `None`.
  else
    match nextCut rest with
    | none => (st.push rest, [])
    | some (p, len, pic) =>
      let (st, o1) := (st.push (rest.take p)).cut
      let (st, o2) := if pic then (st.push ((rest.drop p).take len)).cut else (st, [])
      let (st, o3) := st.pieces (rest.drop (max (p + len) 1))
      (st, o1 ++ o2 ++ o3)
termination_by rest.length
decreasing_by
  simp only [List.length_drop]
  have : rest.length ≠ 0 := by simpa using ‹¬rest = []›
  omega

/-- `line`, after `unthink`. -/
def State.classify (st : State) (line : Text) : State × List Text :=
  if isFence line then ({ st.push line with inFence := !st.inFence }, [])
  else if st.inFence then (st.push line, [])
  else if isBreak line then st.cut
  else if (trim line).isEmpty then
    if !st.sections then st.cut
    else if st.lines.getLast?.any (fun l => !l.isEmpty) then (st.push [], [])
    else (st, [])
  else
    let (st, o1) :=
      if isHeading line then
        let (st, o) := st.cut
        ({ st with sections := true }, o)
      else if quote (trimStart line) then
        let (st, o) := st.cut
        ({ st with sections := false }, o)
      else (st, [])
    let (st, o2) := st.pieces line
    (st, o1 ++ o2)

/-- `line`: one complete line. -/
def State.line (st : State) (raw : Text) : State × List Text :=
  let (visible, thinking) := unthink st.thinking raw
  let st := { st with thinking }
  match visible with
  | none => (st, [])
  | some line => st.classify line

/-- `partial.find('\n')` and `drain(..=end)`: the first line and the rest. -/
def splitLine : Text → Option (Text × Text)
  | [] => none
  | c :: r => if c = '\n' then some ([], r) else (splitLine r).map fun (l, r') => (c :: l, r')

theorem splitLine_length {p l r : Text} (h : splitLine p = some (l, r)) :
    r.length < p.length := by
  induction p generalizing l r with
  | nil => simp [splitLine] at h
  | cons c t ih =>
    simp only [splitLine] at h
    split at h
    · simp only [Option.some.injEq, Prod.mk.injEq] at h
      simp [← h.2]
    · cases ht : splitLine t with
      | none => simp [ht] at h
      | some lr =>
        simp only [ht, Option.map_some, Option.some.injEq, Prod.mk.injEq] at h
        have := ih (l := lr.1) (r := lr.2) (by simp [ht])
        simp only [List.length_cons, ← h.2]
        omega

/-- `trim_end_matches(['\n', '\r'])`. -/
def trimNewline (s : Text) : Text :=
  (s.reverse.dropWhile (fun c => c == '\n' || c == '\r')).reverse

/-- The `while let` loop in `push`: every complete line, and what is left. -/
def drain (st : State) (p : Text) : State × List Text × Text :=
  match _h : splitLine p with
  | none => (st, [], p)
  | some (line, rest) =>
    let (st, o1) := st.line (trimNewline (line ++ ['\n']))
    let (st, o2, p) := drain st rest
    (st, o1 ++ o2, p)
termination_by p.length
decreasing_by exact splitLine_length _h

structure Chunker where
  /-- Text after the last newline: `partial` in the Rust. -/
  rest : Text := []
  st : State := {}

/-- Feeds more text; the chunks it completed. -/
def Chunker.push (c : Chunker) (delta : Text) : Chunker × List Text :=
  let (st, out, rest) := drain c.st (c.rest ++ delta)
  ({ rest, st }, out)

/-- The end of the text; the remaining chunks. -/
def Chunker.finish (c : Chunker) : List Text :=
  let (st, o1) := if c.rest.isEmpty then (c.st, []) else c.st.line c.rest
  o1 ++ st.cut.2

def pushAll (acc : Chunker × List Text) (delta : Text) : Chunker × List Text :=
  let (c, o) := acc.1.push delta
  (c, acc.2 ++ o)

/-- The chunks of a text that arrives in `pieces`. -/
def chunks (pieces : List Text) : List Text :=
  let (c, out) := pieces.foldl pushAll ({}, [])
  out ++ c.finish

end MaxVerify.Chunker
