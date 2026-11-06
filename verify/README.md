# verify

Proofs about max-core's chunker, `crates/max-core/src/segment/chunk.rs`,
in Lean, on the chunker itself as Aeneas translates it.

- `MaxCore/` is the translation. `./extract` writes it; run it after
  changing `chunk.rs` and commit what it writes. It needs Nix and builds
  Charon and Aeneas at the revision `lakefile.toml` pins.
- `MaxVerify/` proves things of `MaxCore`:
  - `Stream.lean`: a text streamed in pieces gives the chunks it gives
    all at once.
  - `Appends.lean`: the chunker only appends to `out`, so that holds for
    the way `segment.rs` drives it too.
  - `Fences.lean`: every chunk but the last closes its fences.
  - `Utf8.lean`: chunks of UTF-8 are UTF-8, however the text is streamed.
  - `Returns.lean`: the chunker returns, neither panicking nor looping, for
    any text shorter than about half of `usize::MAX` bytes.

The theorems are properties, not a second chunker to compare with, so
nothing here is kept in step with the Rust by hand but the proofs: a change
to `chunk.rs` that breaks one needs it fixed, or the property is gone.

CI checks both, in `.github/workflows/verify.yml`: that `MaxCore/` is what
`./extract` writes, and that `lake build` passes. It runs only when
`chunk.rs` or `verify/` changes.

`lake build` builds it all. The first build fetches Mathlib, about 7 GB;
`lake exe cache get` downloads it built.
