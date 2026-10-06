#!/usr/bin/env python3
"""Generate data/bungie-shapes.json from Bungie's OpenAPI specification.

destiny_shape serves response structures from this file, so the model can
read the shape of a request it is about to make instead of probing payloads.
Shapes are TypeScript-like and compact: no descriptions, int64 ids as
strings, hashes annotated with the destiny_lookup kind that translates them,
component-dependent fields tagged with their component number, and
SingleComponentResponse / DictionaryComponentResponse folded into
Single<T> / Dict<T>.

Usage: scripts/bungie-shapes.py [openapi.json]
Without an argument the pinned specification is downloaded.
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Pinned so a regeneration is reviewable; bump deliberately.
SPEC_URL = "https://raw.githubusercontent.com/Bungie-net/api/64a68bdfb2fbf57bd2fa6f75d6899d1240f4ca27/openapi.json"
PREFIXES = ("/Destiny2/", "/User/", "/GroupV2/", "/Content/", "/GlobalAlerts/")
OUT = ROOT / "data" / "bungie-shapes.json"


def load_spec():
    if len(sys.argv) > 1:
        return json.loads(Path(sys.argv[1]).read_text())
    with urllib.request.urlopen(SPEC_URL, timeout=120) as response:
        return json.load(response)


def kind_aliases():
    source = (ROOT / "src/Max/Bungie/Definitions.hs").read_text()
    return {table: alias for alias, table in re.findall(r'\("([a-z]+)", "(Destiny[A-Za-z]+Definition)"\)', source)}


def main():
    spec = load_spec()
    schemas = spec["components"]["schemas"]
    responses = spec["components"]["responses"]
    aliases = kind_aliases()
    components = {v["identifier"]: v["numericValue"] for v in schemas["Destiny.DestinyComponentType"]["x-enum-values"]}

    short = {}
    for name in schemas:
        base = name.rsplit(".", 1)[-1]
        short.setdefault(base, []).append(name)

    def display(name):
        base = name.rsplit(".", 1)[-1]
        return base if len(short[base]) == 1 else name

    def ref_name(ref):
        return ref.split("/")[-1]

    def wrapper(name):
        """Single<T> / Dict<T> for the component response wrappers."""
        schema = schemas[name]
        data = schema.get("properties", {}).get("data", {})
        if name.startswith("SingleComponentResponseOf") and "$ref" in data:
            return "Single", ref_name(data["$ref"])
        if name.startswith("DictionaryComponentResponseOf") and "$ref" in data.get("additionalProperties", {}):
            return "Dict", ref_name(data["additionalProperties"]["$ref"])
        return None

    def expr(schema, refs):
        """TypeScript-like expression; collects referenced schema names."""
        if "$ref" in schema:
            name = ref_name(schema["$ref"])
            folded = wrapper(name)
            if folded:
                refs.add(folded[1])
                return f"{folded[0]}<{display(folded[1])}>"
            refs.add(name)
            return display(name)
        if "allOf" in schema and len(schema["allOf"]) == 1:
            return expr(schema["allOf"][0], refs)
        kind = schema.get("type")
        if kind == "integer" or kind == "number":
            if "x-enum-reference" in schema:
                name = ref_name(schema["x-enum-reference"]["$ref"])
                refs.add(name)
                return display(name) + (" /*flags*/" if schema.get("x-enum-is-bitmask") else "")
            if "x-mapped-definition" in schema:
                table = ref_name(schema["x-mapped-definition"]["$ref"]).rsplit(".", 1)[-1]
                return f"number /*→{aliases.get(table, table)}*/"
            if schema.get("format") == "int64":
                return "string"
            return "number"
        if kind == "string":
            return "string /*date*/" if schema.get("format") == "date-time" else "string"
        if kind == "boolean":
            return "boolean"
        if kind == "array":
            inner = expr(schema.get("items", {}), refs)
            return f"({inner})[]" if " " in inner else f"{inner}[]"
        if kind == "object" and "additionalProperties" in schema:
            key = schema.get("x-dictionary-key", {})
            if "x-mapped-definition" in key:
                table = ref_name(key["x-mapped-definition"]["$ref"]).rsplit(".", 1)[-1]
                label = f"hash→{aliases.get(table, table)}"
            elif key.get("x-enum-reference"):
                label = display(ref_name(key["x-enum-reference"]["$ref"]))
            elif key.get("format") == "int64":
                label = "id"
            else:
                label = "key"
            return f"{{[{label}: string]: {expr(schema['additionalProperties'], refs)}}}"
        if kind == "object" and "properties" in schema:
            return "{" + "; ".join(f"{k}: {expr(v, refs)}" for k, v in schema["properties"].items()) + "}"
        return "unknown"

    def component_of(field):
        tag = field.get("x-destiny-component-type-dependency")
        if not tag and "allOf" in field:
            tag = field["allOf"][0].get("x-destiny-component-type-dependency")
        return components.get(tag) if tag else None

    def render(name):
        schema = schemas[name]
        if "x-enum-values" in schema:
            values = ", ".join(f"{v['identifier']}={v['numericValue']}" for v in schema["x-enum-values"])
            kind = "flags" if schema.get("x-enum-is-bitmask") else "enum"
            return {"line": f"{kind} {display(name)} {{ {values} }}", "fields": [], "refs": []}
        fields, refs = [], set()
        for field_name, field in schema.get("properties", {}).items():
            field_refs = set()
            line = f"{field_name}: {expr(field, field_refs)}"
            entry = {"line": line, "refs": sorted(field_refs)}
            component = component_of(field)
            if component is not None:
                entry["component"] = component
            fields.append(entry)
            refs |= field_refs
        if not fields:
            line_refs = set()
            line = f"type {display(name)} = {expr(schema, line_refs)}"
            return {"line": line, "fields": [], "refs": sorted(line_refs)}
        return {"line": f"type {display(name)}", "fields": fields, "refs": sorted(refs)}

    endpoints, roots = [], set()
    for path, item in spec["paths"].items():
        if not path.startswith(PREFIXES):
            continue
        for method, operation in item.items():
            if method not in ("get", "post"):
                continue
            response = operation.get("responses", {}).get("200", {})
            if "$ref" not in response:
                continue
            body = responses[ref_name(response["$ref"])]["content"]["application/json"]["schema"]["properties"]["Response"]
            response_refs = set()
            response_type = expr(body, response_refs)
            request = None
            schema = operation.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema")
            request_refs = set()
            if schema:
                request = expr(schema, request_refs)
            endpoints.append(
                {
                    "method": method.upper(),
                    "path": path,
                    "summary": (operation.get("summary") or operation.get("description") or "").strip()[:200],
                    "response": response_type,
                    "response_refs": sorted(response_refs),
                    "request": request,
                    "request_refs": sorted(request_refs),
                }
            )
            roots |= response_refs | request_refs

    types, pending = {}, list(roots)
    while pending:
        name = pending.pop()
        if name in types or name not in schemas:
            continue
        types[name] = render(name)
        pending.extend(types[name]["refs"])
        for field in types[name]["fields"]:
            pending.extend(field["refs"])

    out = {
        "version": spec["info"]["version"],
        "source": SPEC_URL,
        "legend": "Single<T> = {data?: T; privacy: number; disabled?: boolean}；Dict<T> = {data?: {[id: string]: T}; privacy: number; disabled?: boolean}。64 位 id 是字符串；number /*→item*/ 是 hash，用 destiny_lookup 的对应 kind 翻译；字段后的 /*c305*/ 表示需要 components 里有 305。",
        "components": {str(number): identifier for identifier, number in components.items()},
        "names": {display(name): name for name in types},
        "endpoints": endpoints,
        "types": types,
    }
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n")
    print(f"{OUT.relative_to(ROOT)}: {len(endpoints)} endpoints, {len(types)} types, {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
