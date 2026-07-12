#!/usr/bin/env sh
# Build the sandbox base image the bot expects (see
# Max.Sandbox.Registry.defaultCreateOpts).
set -eu
cd "$(dirname "$0")"
exec docker build -t max-sandbox:latest .
