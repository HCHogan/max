# Saved skill workflows

A workflow is a named JavaScript async function body stored with a skill.
The host passes its input as `args`. Each run is isolated; variables do not
survive the run. All leaf tools use the existing executor and current authority.

## Model use

Load the whole package with `use_skill({name: "batch-search"})`. The result
contains complete instructions, workflow input/output contracts and version
fingerprints. Its fixed dependencies (web and codemode) become available in the
next model round. Then submit, as the only tool call in that round:

```json
{"workflow":"batch-search/search","args":{"queries":["NixOS input methods","NixOS fcitx5"],"limit":3}}
```

These are `run_code` arguments. Inline `{ "code": "return 1;" }` remains
supported. A call cannot combine the two forms or execute an unloaded package.
The loaded version stays fixed across registry updates and task recovery.
An independent request loads the current version. Current grants still apply:
missing tools or changed host tool contracts reject a saved run before effects.

The embedded `fleet-health/check` takes `{"hosts":["h610","b650"]}` and preserves
agent/exporter observations, readable-service scope, unknown state and query
failures. An empty or unavailable observation does not mean a healthy fleet.

## Package representation

Existing admin `POST /api/skills` accepts an optional `package` property alongside
name, group_id, description, body and enabled. Omitting it creates a normal
instruction-only skill. A package looks like:

```json
{
  "dependencies": [],
  "workflows": {
    "sum": {
      "description": "Add a bounded list of numbers",
      "source": "return args.values.reduce((sum, x) => sum + x, 0);",
      "input": {
        "type": "object",
        "properties": {"values": {"type": "array", "items": {"type": "number"}, "maxItems": 100}},
        "required": ["values"],
        "additionalProperties": false
      },
      "output": {"type": "number"},
      "tools": []
    }
  }
}
```

Workflow-bearing packages implicitly depend on codemode. Other dependencies are
explicit, fixed skill names, resolved using the same group scope as the parent.
Dependencies load atomically, with shared dependencies deduplicated. Requirements
must exist in the authorized catalog after all dependencies load. Only declared
tools can run inside the saved program; declaring a tool does not grant it.

`GET /api/skills` returns `revision` and `package`. Updating a package through
`PATCH /api/skills/:id` requires `expected_revision` from that response; a stale
revision returns HTTP 409. Each successful edit appends a `skill_versions`
snapshot in the same transaction as advancing the current revision. Legacy body
edits remain supported, and the admin editor supplies an expected revision.
Snapshots are immutable through the API. Existing DELETE semantics remove a
skill and its stored revisions; already loaded execution receipts retain their
content. There is no revision-history or rollback endpoint in this batch.

Embedded packages pair `skills/<name>.md` instructions with a sibling `.json`
package. They are compiled into Max. Model creation/publishing is available
through the scoped authoring bundle below; a graphical package editor remains
future work.

## Contracts and bounds

The supported contract vocabulary is intentionally closed:

- One `type`: object, array, string, number, integer, boolean or null.
- Optional `description` and nonempty `enum`.
- Objects: properties, required, and an explicit boolean additionalProperties.
- Arrays: items and optional minItems/maxItems.
- Strings: optional minLength/maxLength.
- Numbers/integers: optional minimum/maximum.

Unknown keywords, unions, references and formats are rejected. Validation is
recursive, bounded to 16 schema nesting levels. Inputs and returned values must
satisfy their declared contracts. Output validation runs before journal
settlement; an output error does not rewind committed tools or authorize replay.

One package is at most 256 KiB, with 8 workflows and 16 direct dependencies.
Each source and invocation input is at most 64 KiB. Complete loaded receipts
are capped at 512 KiB, 120,000 instruction characters and 32 skills; dependency
depth is capped at 16. The usual codemode memory, fuel, output and tool limits
remain in force. Limits reject explicitly and do not silently truncate packages.

Results include `run_ref` (a journal reference for durable executions), workflow
reference/version/arguments and bounded leaf receipts. The existing execution
journal retains exact source and tool evidence. No whole-program retry, guest
checkpoint, nested workflow execution or background resumption is added.
`Finish`/`Yield` stops the entire program; a maxops handoff does not suspend an
`await` until deployment finishes. Steering arrives after the complete run.

## Model authoring

Load `skill-authoring` to create group-local draft packages, validate against
fixture tools and publish a checked revision. See [the authoring contract](skill-authoring.md).
Admin package editing remains a separate privileged path; model publication cannot
overwrite an admin-authored or subsequently admin-edited head.
