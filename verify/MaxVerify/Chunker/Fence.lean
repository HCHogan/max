import MaxVerify.Chunker.Model

/-!
# Fences

While a code fence is open, the chunker doesn't cut: blank lines, `[split]`
and headings inside it are code. So every chunk but the last should have as
many fence lines as it closes; the last may hold an unclosed one, which runs
to the end. `FencesWhole` says that.

It doesn't hold today. The chunker sees a fence only at the start of a line,
but a message can start in the middle of one: after `[split]`, after a
picture's handle, and after a quote that starts a line, which QQ shows as a
reply rather than as text. A fence there opens a code block in QQ, and the
chunker takes it for text. Then the code's blank lines cut it, a `# comment`
in it is a heading, and its closing fence is taken for an opening one, so
that everything after it goes out as one message.

The counterexamples are checked by evaluation (`native_decide`), which
trusts Lean's compiler as well as its kernel.
-/

namespace MaxVerify.Chunker

/-- The lines of a chunk. -/
def linesOf : Text → List Text
  | [] => [[]]
  | c :: r =>
    if c = '\n' then [] :: linesOf r
    else
      match linesOf r with
      | l :: ls => (c :: l) :: ls
      | [] => [[c]]

/-- A line as QQ shows it: without the quote it starts with, if any. -/
def unquoted (line : Text) : Text :=
  match placeholder (trimStart line) with
  | some (.reply, len) => (trimStart line).drop len
  | _ => line

/-- How many fence lines a chunk has. A quote can only start a chunk's first
line: one at the start of a later line starts a chunk of its own. -/
def fences (chunk : Text) : Nat :=
  match linesOf chunk with
  | [] => 0
  | first :: rest => (if isFence (unquoted first) then 1 else 0) + rest.countP isFence

/-- Every chunk but the last closes the fences it opens. -/
def FencesWhole (cs : List Text) : Prop := ∀ c ∈ cs.dropLast, fences c % 2 = 0

instance (cs : List Text) : Decidable (FencesWhole cs) := by
  unfold FencesWhole; infer_instance

def afterSplit : Text :=
  "看代码：[split]```bash\n# 安装\nnix build\n\nnix run\n```\n\n好了\n\n还有一条".toList

def afterPicture : Text := "[sticker#4.0]```py\nx = 1\n\ny = 2\n```\n\n好了\n\n还有一条".toList

def afterQuote : Text := "[reply#3] ```py\nx = 1\n\ny = 2\n```\n\n好了\n\n还有一条".toList

theorem afterSplit_chunks :
    (chunks [afterSplit]).map String.ofList =
      ["看代码：", "```bash", "# 安装\nnix build\n\nnix run\n```\n\n好了\n\n还有一条"] := by
  native_decide

theorem afterPicture_chunks :
    (chunks [afterPicture]).map String.ofList =
      ["[sticker#4.0]", "```py\nx = 1", "y = 2\n```\n\n好了\n\n还有一条"] := by
  native_decide

theorem afterQuote_chunks :
    (chunks [afterQuote]).map String.ofList =
      ["[reply#3] ```py\nx = 1", "y = 2\n```\n\n好了\n\n还有一条"] := by
  native_decide

theorem fences_split :
    ¬ FencesWhole (chunks [afterSplit]) ∧ ¬ FencesWhole (chunks [afterPicture])
      ∧ ¬ FencesWhole (chunks [afterQuote]) := by
  native_decide

end MaxVerify.Chunker
