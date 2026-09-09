# Skill contract continuity and live model acceptance

## Contract continuity

Publication persists a host-minted certificate alongside the skill and its
immutable version snapshot. It binds the rendered instructions and package
content (independent of draft/publication revision numbers), the complete fixed
dependency receipt versions, required tool definitions/schema/effect contracts,
and the embedded JavaScript SDK/QuickJS runtime digest.

Loading first binds the complete dependency graph, then verifies the certificate
against that graph and the current caller's catalog. Verification grants no
permissions. A mismatch rejects the entire activation and asks for validation
and publication again. Recovery repeats the same check using persisted receipts;
it never fetches a newer workflow source. Old workflow receipts without runtime
identity require a new load. Authored heads predating certificates require
revalidation; embedded/admin-created packages retain their explicit trusted
origin. Admin edits to an authored package retain its evidence, so content drift
also fails closed.

## Live acceptance

A separate executable uses the production agent loop, skill tools, JavaScript
executor and a configured real frontend model. It owns an isolated evaluation
database and synthetic conversations, exposes only controlled read tools, and
has no outbound chat transport. The model writes its own workflow source and
fixtures, sees validation errors, publishes, and a fresh turn reuses the saved
workflow with held-out arguments. Assertions check host-observed results and
publication facts, not the model's claims. Reports include failures, calls,
token usage and elapsed time. Fixture validation and this controlled live-model
acceptance are distinct from production health and live fleet API acceptance.

Run `max-skill-eval --config-file /etc/max/config.json --db-url
postgresql:///max_skill_eval_RUN?host=/run/postgresql --migrations-dir DIR
--eval-report /tmp/skill-eval-RUN.json` with an empty, dedicated database.
The connected database name must start with `max_skill_eval_`; populated or
production databases are refused. `--eval-profile` selects a frontend profile,
otherwise the configured default is used. The three cases cover partial host
failures, ordered search URL deduplication, and repair of an existing numeric
sort draft. Each uses a fresh registry and durable turn for held-out reuse.
The harness uses a focused acceptance prompt plus real on-demand skill text;
it does not reproduce production conversation context or measure discovery
among the complete production skill index.
