# webread: a page's text, for the groups' VMs; see webread.py. Its tests
# run the script with the dev shell's Python.
{ pkgs }:
pkgs.writers.writePython3Bin "webread" {
  libraries = [ pkgs.python3Packages.trafilatura ];
  # Long lines are the Chinese messages; black's slices.
  flakeIgnore = [
    "E501"
    "E203"
  ];
} (builtins.readFile ./webread.py)
