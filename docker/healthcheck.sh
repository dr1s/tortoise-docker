#!/usr/bin/env bash
# Probe the port matching the running turtle service.
# Reads REALM_PORT / WORLD_PORT so the check stays in sync with render-config.sh.
set -euo pipefail

REALM_PORT="${REALM_PORT:-3724}"
WORLD_PORT="${WORLD_PORT:-8090}"

if pgrep -x realmd >/dev/null 2>&1; then
  exec bash -c "echo > /dev/tcp/localhost/${REALM_PORT}"
elif pgrep -x mangosd >/dev/null 2>&1; then
  exec bash -c "echo > /dev/tcp/localhost/${WORLD_PORT}"
else
  echo "No known turtle service is running" >&2
  exit 1
fi
