#!/usr/bin/env bash
set -euo pipefail

directory=$(cd -- "$(dirname -- "$0")" && pwd)
container="max-browser-acceptance-$$"
image=${1:-max-browser:latest}
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT

docker run -d --init --network none --memory=4g --cpus=2 --pids-limit=512 --name "$container" \
  -e NODE_ENV=test -e CAMOUFOX_MCP_TEST_ALLOW_LOCALHOST=1 \
  -e CAMOUFOX_MCP_TEST_ALLOWED_LOCALHOST_PORTS=18765 \
  -e CAMOUFOX_MCP_MAX_SESSIONS=4 -e CAMOUFOX_MCP_SESSION_TTL_MS=900000 \
  --mount "type=bind,source=$directory/test-browser-workspaces.mjs,target=/home/camoufox/app/max-acceptance.mjs,readonly" \
  "$image"

for attempt in $(seq 1 30); do
  if docker exec "$container" node -e 'fetch("http://127.0.0.1:8931/mcp").catch(() => process.exit(1))'; then
    break
  fi
  sleep 1
done

docker exec "$container" node /home/camoufox/app/max-acceptance.mjs
logs=$(docker logs "$container" 2>&1)
if [[ "$logs" == *fixture_auth* || "$logs" == *fixture_identity* || "$logs" == *workspace-one* ]]; then
  printf 'FAIL browser logs exposed authentication fixture state\n' >&2
  exit 1
fi
printf 'PASS authentication state is absent from container logs\n'
for attempt in $(seq 1 30); do
  if docker top "$container" -eo pid,comm,args | awk '/\.cache\/camoufox\/|Xvfb/ {count++} $2 == "node" && /app\/dist\/index.js/ && !/supergateway/ {count++} END {exit(count > 0)}'; then
    break
  fi
  sleep 1
done
docker top "$container" -eo pid,comm,args | awk '/\.cache\/camoufox\/|Xvfb/ {count++} $2 == "node" && /app\/dist\/index.js/ && !/supergateway/ {count++} END {printf "remaining-browser-processes=%d\n",count; if(count) exit 1}'
