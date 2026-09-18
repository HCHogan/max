#!/usr/bin/env python3
"""Count non-ignored source with tokei and the reviewed Haskell responsibility map."""

import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True)


def measure(paths):
    if not paths:
        return {}, {}
    result = json.loads(command("tokei", "--output", "json", "--", *sorted(paths)))
    files = {}
    for language, data in result.items():
        if language == "Total":
            continue
        for report in data["reports"]:
            files[report["name"]] = {
                "language": language,
                **{key: report["stats"][key] for key in ("code", "comments", "blanks")},
            }
    missing = set(paths) - files.keys()
    if missing:
        raise SystemExit("tokei did not count: " + ", ".join(sorted(missing)))
    totals = {key: sum(row[key] for row in files.values()) for key in ("code", "comments", "blanks")}
    return totals, files


def main():
    manifest = json.loads((ROOT / "docs/code-scope.json").read_text())
    tracked = {
        path
        for path in command("git", "ls-files", "--cached", "--others", "--exclude-standard").splitlines()
        if (ROOT / path).is_file()
    }
    production_haskell = {path for path in tracked if path.endswith(".hs") and path.startswith(("src/", "app/"))}
    owners = {}
    for group, paths in manifest["groups"].items():
        for path in paths:
            if path in owners:
                raise SystemExit(f"duplicate classification: {path}")
            owners[path] = group
    if production_haskell != owners.keys():
        raise SystemExit(
            "Update docs/code-scope.json after reviewing responsibility changes.\n"
            f"Unclassified: {sorted(production_haskell - owners.keys())}\n"
            f"Missing: {sorted(owners.keys() - production_haskell)}"
        )

    groups = {}
    files = {}
    for group, paths in manifest["groups"].items():
        groups[group], rows = measure(paths)
        files.update({path: {"group": group, **row} for path, row in rows.items()})

    # Additional owned code stays visible even when it is outside the kernel.
    suffixes = {".hs", ".c", ".h", ".m", ".go", ".js", ".mjs", ".ts", ".py", ".sh", ".nix", ".sql", ".html", ".css"}
    extra = {path for path in tracked if Path(path).suffix in suffixes} - production_haskell
    for path in sorted(extra):
        if path.startswith("static/vendor/"):
            group = "vendored"
        elif path.startswith("migrations/"):
            group = "migration_history"
        elif path.startswith(("test/", "test-db/", "test-support/", "nix/tests/")) or ".test." in path or "_test." in path:
            group = "tests"
        elif path.startswith(("scripts/", "prompt-flow/", "eval/")) or "-eval/" in path:
            group = "development_tools"
        else:
            group = "additional_production"
        groups.setdefault(group, [])
        groups[group].append(path)
    for group in ("vendored", "migration_history", "tests", "development_tools", "additional_production"):
        groups[group], rows = measure(groups.get(group, []))
        files.update({path: {"group": group, **row} for path, row in rows.items()})

    production_groups = [*manifest["groups"], "additional_production"]
    report = {
        "count_method": command("tokei", "--version").strip(),
        "base_revision": command("git", "rev-parse", "HEAD").strip(),
        "working_tree_changes": bool(command("git", "status", "--porcelain").strip()),
        "limits": "Core is the Haskell component only. Active SQL schema must be counted separately before final acceptance. Patch files, prompts, data and configuration text are not source LOC.",
        "groups": groups,
        "owned_production_code": sum(groups[group]["code"] for group in production_groups),
        "files": files,
    }
    json.dump(report, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
