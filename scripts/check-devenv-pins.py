#!/usr/bin/env python3
"""Keep native devenv and the CI/packaging flake on the same input graph."""

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent


def input_graph(lock, name):
    nodes = lock["nodes"]

    def resolve(reference):
        if isinstance(reference, str):
            return reference
        current = lock["root"]
        for part in reference:
            current = resolve(nodes[current]["inputs"][part])
        return current

    def visit(reference, parents):
        key = resolve(reference)
        if key in parents:
            # Flake inputs can legitimately follow an ancestor (for example
            # devenv's crate2nix input follows devenv). Compare that topology
            # without depending on lock-file-specific node names.
            return {"ancestor": parents.index(key)}
        node = nodes[key]
        return {
            "locked": node.get("locked"),
            "flake": node.get("flake", True),
            "inputs": {
                child: visit(target, parents + (key,))
                for child, target in node.get("inputs", {}).items()
            },
        }

    return visit(nodes[lock["root"]]["inputs"][name], ())


def main():
    flake = json.loads((ROOT / "flake.lock").read_text())
    native = json.loads((ROOT / "devenv.lock").read_text())
    for name in ("nixpkgs", "devenv"):
        if input_graph(flake, name) != input_graph(native, name):
            sys.exit(f"FAIL: {name} differs between flake.lock and devenv.lock; synchronize both inputs")
        print(f"PASS: {name} and its transitive inputs match")


if __name__ == "__main__":
    main()
