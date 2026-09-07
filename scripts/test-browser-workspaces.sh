#!/usr/bin/env bash
set -euo pipefail

# Run the native package as an ordinary Linux user with disposable state.
package=${1:?usage: test-browser-workspaces.sh /nix/store/...-max-browser}
runtime=$(mktemp -d)
pid=
cleanup() {
  if [[ -n "$pid" ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  rm -rf "$runtime"
}
trap cleanup EXIT
mkdir "$runtime/home" "$runtime/cache"
export HOME="$runtime/home" XDG_CACHE_HOME="$runtime/cache"
export MAX_BROWSER_ENDPOINT_FILE="$runtime/endpoint.json"
export NODE_ENV=test CAMOUFOX_MCP_TEST_ALLOW_LOCALHOST=1
export CAMOUFOX_MCP_TEST_ALLOWED_LOCALHOST_PORTS=18765
export CAMOUFOX_MCP_MAX_SESSIONS=4 CAMOUFOX_MCP_SESSION_TTL_MS=900000
setsid "$package/bin/max-browser" >"$runtime/browser.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [[ -s "$MAX_BROWSER_ENDPOINT_FILE" ]] && break
  kill -0 "$pid"
  sleep 0.1
done
port=$(jq -er '.port | select(. >= 1024 and . <= 65535)' "$MAX_BROWSER_ENDPOINT_FILE")
export MAX_BROWSER_ENDPOINT="http://127.0.0.1:$port/mcp"
"$package/bin/max-browser-workspace-test"
if grep -Eq 'fixture_auth|fixture_identity|workspace-one' "$runtime/browser.log"; then
  printf 'FAIL browser logs exposed authentication fixture state\n' >&2
  exit 1
fi
printf 'PASS authentication state is absent from browser logs\n'
# Workspace closure must reap MCP children, Firefox and Xvfb while the gateway
# itself remains available. Restrict process inspection to our own process group.
for _ in $(seq 1 100); do
  if ! ps -eo pgid=,args= | awk -v group="$pid" '$1 == group && /camoufox-bin|Xvfb|\/dist\/index.js/ && !/supergateway/ {found=1} END {exit !found}'; then
    break
  fi
  sleep 0.1
done
if ps -eo pgid=,args= | awk -v group="$pid" '$1 == group && /camoufox-bin|Xvfb|\/dist\/index.js/ && !/supergateway/ {found=1} END {exit !found}'; then
  printf 'FAIL browser child remained after closing all workspaces\n' >&2
  exit 1
fi
printf 'PASS native browser child processes were reaped\n'
