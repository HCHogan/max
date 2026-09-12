#!/usr/bin/env bash
set -euo pipefail
package=${1:?usage: test-browser-surface.sh PACKAGE [MEASURE_FILE]}
source_script=$(cd -- "$(dirname -- "$0")" && pwd)/test-browser-surface.mjs
runtime=$(mktemp -d)
pid=
cleanup() {
  status=$?
  if [[ -n "$pid" ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  if [[ "$status" != 0 ]]; then tail -100 "$runtime/browser.log" >&2; fi
  rm -rf "$runtime"
}
trap cleanup EXIT
mkdir "$runtime/home" "$runtime/cache"
cp "$source_script" "$runtime/test.mjs"
ln -s "$package/lib/max-browser/node_modules" "$runtime/node_modules"
env HOME="$runtime/home" XDG_CACHE_HOME="$runtime/cache" \
  MAX_BROWSER_ENDPOINT_FILE="$runtime/endpoint.json" \
  NODE_ENV=test CAMOUFOX_MCP_TEST_ALLOW_LOCALHOST=1 CAMOUFOX_MCP_TEST_ALLOWED_LOCALHOST_PORTS=18765 \
  CAMOUFOX_MCP_ALLOW_UNSAFE_OPTIONS=1 CAMOUFOX_MCP_ALLOW_EVALUATE=1 \
  setsid "$package/bin/max-browser" >"$runtime/browser.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [[ -s "$runtime/endpoint.json" ]] && break
  kill -0 "$pid"
  sleep 0.1
done
port=$(jq -er '.port | select(. >= 1024 and . <= 65535)' "$runtime/endpoint.json")
MAX_BROWSER_ENDPOINT="http://127.0.0.1:$port/mcp" \
  MAX_BROWSER_MEASURE_FILE="${2:-/tmp/max-browser-measure.json}" node "$runtime/test.mjs"
