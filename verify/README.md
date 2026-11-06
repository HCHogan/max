# verify

Proofs about max-core's chunker, `crates/max-core/src/segment/chunk.rs`,
in Lean.

- `MaxCore/` is the chunker as Aeneas translates it. `./extract` writes
  it; run it after changing `chunk.rs` and commit what it writes. It needs
  Nix and builds Charon and Aeneas at the revision `lakefile.toml` pins.
- `MaxVerify/Core/` proves things of `MaxCore`: so far that streaming is
  invisible.
- `MaxVerify/Chunker/` is a model of the chunker written by hand, over
  characters, with its own proof of streaming and the counterexamples
  that show fences split. `diff/` checks it against the Rust on random
  texts: `lake build`, then `cargo run --release` in `diff/`.

`lake build` builds it all. The first build fetches Mathlib, about 7 GB;
`lake exe cache get` downloads it built.
