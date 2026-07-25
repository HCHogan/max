#!/usr/bin/env bash
# Extract intent-classifier rounds from max's journald logs into a
# JSONL fixture for max-intent-eval.
#
# Usage:
#   scripts/extract-intent-fixture.sh ['--since' value, default '1 week ago'] > eval/fixtures/intent.jsonl
#
# Every "intent: verdict" log line (added in v0.2.3) carries the full
# classifier input (context + new messages) alongside the model's
# verdict.  The recorded verdict is copied into expect_trigger /
# expect_kind as a STARTING POINT — hand-check the labels before
# treating the file as ground truth: the point of the eval is to catch
# the model being wrong, and unreviewed model output can't do that.
# The original verdict+reason is kept in "note" for reference.
#
# Targets log-base's stdout format ("<time> <level> <component>:
# <message> <json>"); the sed grabs the JSON tail of the line.
set -euo pipefail

since="${1:-1 week ago}"

journalctl -u max -o cat --since "$since" \
  | grep -F 'intent: verdict {' \
  | sed 's/^[^{]*//' \
  | jq -c '{
      context,
      new,
      expect_trigger: .trigger,
      expect_kind: .kind,
      note: ("recorded: trigger=\(.trigger) kind=\(.kind) reason=\(.reason // "-")")
    }'
