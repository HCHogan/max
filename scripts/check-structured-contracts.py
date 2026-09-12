#!/usr/bin/env python3
"""Verify first-response live-model certificates against the current source.

No network or private fixtures in CI. Reports are produced by max-contract-eval
against a private production export and reviewed before being checked in.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def verify(root, reports):
    inventory = json.loads((root / "contract-eval/contracts.json").read_text())
    errors = []
    for contract, sources in inventory.items():
        path = reports / f"{contract}.json"
        if not path.is_file():
            errors.append(f"{contract}: missing real-model report")
            continue
        report = json.loads(path.read_text())
        if not report.get("complete") or report.get("source_kind") != "production_llm_calls" or not report.get("first_responses_only"):
            errors.append(f"{contract}: incomplete or non-production evidence")
        for source in sources:
            expected = hashlib.sha256((root / source).read_bytes()).hexdigest()
            if report.get("source_hashes", {}).get(source) != expected:
                errors.append(f"{contract}: stale source {source}; rerun the live gate")
        rows = [r for r in report.get("samples", []) if r.get("contract") == contract]
        if len(rows) < 20 or len({r.get("source_ref") for r in rows}) < 20:
            errors.append(f"{contract}: need 20 real source calls")
        if any(r.get("outcome") != "decoded" or not r.get("model_matches") or r.get("actual_models") != [r.get("expected_model")] or r.get("model_calls") != 1 for r in rows):
            errors.append(f"{contract}: nonzero first-response failures or model drift")
        summary = [r for r in report.get("contracts", []) if r.get("contract") == contract]
        if len(summary) != 1 or summary[0].get("attempts") != len(rows) or any(summary[0].get(k) != 0 for k in ["decode_failures", "provider_failures", "decode_failure_rate"]):
            errors.append(f"{contract}: rates do not match the samples")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports", type=Path, default=ROOT / "docs/research/structured-contracts")
    args = parser.parse_args()
    errors = verify(ROOT, args.reports)
    if errors:
        raise SystemExit("\n".join(errors))
    print("All structured-output contracts have current zero-failure real-model evidence.")


if __name__ == "__main__":
    main()
