# initdb's arguments for every cluster max's data lives in: the dev
# shell's and CI's (flake.nix). The builtin
# provider's C.UTF-8 is Postgres's own, the same on Linux and macOS and
# with any glibc: lower() maps letters by Unicode, as keywords::fold
# expects, pg_trgm counts Chinese characters as a word's, and text sorts
# by code point.
[
  "--encoding=UTF8"
  "--locale=C"
  "--locale-provider=builtin"
  "--builtin-locale=C.UTF-8"
]
