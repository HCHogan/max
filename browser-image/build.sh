#!/usr/bin/env sh
# Build the browser image the bot expects (see
# Max.Browser.Docker.defaultBrowserImage).  Bakes camoufox-mcp-server +
# supergateway + the camoufox browser in, so per-group browser
# containers start instantly.
set -eu
cd "$(dirname "$0")"
exec docker build -t max-browser:latest .
