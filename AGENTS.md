# Repository instructions

## Before every commit

- From the repository root, run `cabal run max-prompt-flow` before creating
  any Git commit.
- Include the regenerated `docs/prompt-flow.md` in the commit when it changes.
- Then run `cabal run max-prompt-flow -- --check`; do not commit if the check
  fails.
