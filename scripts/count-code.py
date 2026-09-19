#!/usr/bin/env python3
"""Count non-ignored source with tokei and the reviewed Haskell responsibility map."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

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


def measure_schema():
    """Read a migrated disposable database; never print its connection string."""
    url = os.environ.get("MAX_TEST_DB_URL")
    if not url:
        raise SystemExit("--schema requires MAX_TEST_DB_URL pointing to an isolated migrated database")
    env = {**os.environ, "PGOPTIONS": "-c default_transaction_read_only=on"}

    def postgres(*args):
        argv = list(args)
        if "--version" not in args:
            argv.append("--dbname=" + url)
        result = subprocess.run(argv, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE)
        if result.returncode:
            raise SystemExit("PostgreSQL schema measurement failed")
        return result.stdout

    catalog = json.loads(postgres("psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", """
        SELECT json_build_object(
          'relations', (SELECT json_agg(c.relname ORDER BY c.relname)
            FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m')),
          'sequences', (SELECT json_object_agg(s.relname, owner.relname)
            FROM pg_class s JOIN pg_namespace n ON n.oid=s.relnamespace
            LEFT JOIN pg_depend d ON d.classid='pg_class'::regclass AND d.objid=s.oid
              AND d.refclassid='pg_class'::regclass AND d.deptype IN ('a','i')
            LEFT JOIN pg_class owner ON owner.oid=d.refobjid
            WHERE n.nspname='public' AND s.relkind='S'),
          'migrations', (SELECT json_agg(filename ORDER BY filename) FROM schema_migrations))
        """))
    shipped = {p.name for p in (ROOT / "migrations").glob("*.sql")}
    if set(catalog["migrations"]) != shipped:
        raise SystemExit("Schema measurement requires exactly the shipped migrations")
    manifest = json.loads((ROOT / "docs/schema-scope.json").read_text())
    active, archived = set(manifest["active"]), set(manifest["archived"])
    actual = set(catalog["relations"])
    if active & archived or active | archived != actual:
        raise SystemExit(f"Update docs/schema-scope.json: unclassified={sorted(actual - active - archived)}, "
                         f"missing={sorted((active | archived) - actual)}, duplicates={sorted(active & archived)}")
    archived_sequences = {name for name, owner in catalog["sequences"].items() if owner in archived}
    options = ["pg_dump", "--schema-only", "--no-owner", "--no-acl", "--schema=public"]
    with tempfile.TemporaryDirectory(prefix="max-schema-count-") as temporary:
        full = Path(temporary) / "installed.sql"
        used = Path(temporary) / "active.sql"
        full.write_text(postgres(*options))
        used.write_text(postgres(*options, *(f"--exclude-table=public.{name}" for name in sorted(archived | archived_sequences))))
        installed, _ = measure([str(full)])
        active_sql, _ = measure([str(used)])
    return {
        "method": postgres("pg_dump", "--version").strip(),
        "scope": manifest["counting"],
        "migrations": catalog["migrations"],
        "installed": installed,
        "active_and_shared": active_sql,
        "retained_archive": {key: installed[key] - active_sql[key] for key in installed},
        "active_relations": sorted(active),
        "archived_relations": sorted(archived),
        "archived_sequences": sorted(archived_sequences),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema", action="store_true", help="also measure SQL from MAX_TEST_DB_URL")
    parser.add_argument("--prompt-stats", type=Path, help="JSON emitted by max-prompt-flow --stats")
    args = parser.parse_args()
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
        "limits": "Source groups are effective code lines. --schema adds current SQL separately; --prompt-stats adds fixture request sizes. Historical migrations are not added to active production code. Patch files, data and configuration text remain separate maintenance costs.",
        "groups": groups,
        "owned_production_code": sum(groups[group]["code"] for group in production_groups),
        "files": files,
    }
    if args.schema:
        report["schema"] = measure_schema()
        sql_code = report["schema"]["active_and_shared"]["code"]
        report["core_with_active_sql"] = groups["core"]["code"] + sql_code
        report["owned_production_with_active_sql"] = report["owned_production_code"] + sql_code
    if args.prompt_stats:
        report["prompt_statistics"] = json.loads(args.prompt_stats.read_text())
    json.dump(report, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
