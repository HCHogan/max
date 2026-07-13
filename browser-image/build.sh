#!/usr/bin/env sh
# Build the browser image the bot expects (see
# Max.Browser.Docker.defaultBrowserImage).  Bakes playwright-mcp + its
# matching Chromium in, so per-group browser containers start instantly.
set -eu
cd "$(dirname "$0")"
exec docker build -t max-browser:latest .
