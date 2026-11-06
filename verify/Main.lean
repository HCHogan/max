import MaxVerify.Chunker.Model

/-!
Reads one text per line, its UTF-8 as hex, and prints the model's chunks of
it on one line: each chunk as hex, separated by spaces. `diff/` feeds it and
compares with the Rust.
-/

open MaxVerify.Chunker

def hexDigit (c : Char) : Nat :=
  if c.isDigit then c.toNat - '0'.toNat else c.toNat - 'a'.toNat + 10

def unhex : List Char → List UInt8
  | a :: b :: rest => UInt8.ofNat (hexDigit a * 16 + hexDigit b) :: unhex rest
  | _ => []

def hex (s : String) : String :=
  String.join (s.toUTF8.toList.map fun b =>
    let d := Nat.toDigits 16 b.toNat
    String.ofList (if d.length < 2 then '0' :: d else d))

partial def loop (stdin : IO.FS.Stream) (stdout : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return
  let bytes := ByteArray.mk (unhex (line.toList.filter (· != '\n'))).toArray
  match String.fromUTF8? bytes with
  | none => throw (IO.userError s!"not UTF-8: {line}")
  | some text =>
    let out := (chunks [text.toList]).map fun c => hex (String.ofList c)
    stdout.putStrLn (" ".intercalate out)
  loop stdin stdout

def main : IO Unit := do
  let stdout ← IO.getStdout
  loop (← IO.getStdin) stdout
  stdout.flush
