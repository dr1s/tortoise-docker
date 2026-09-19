#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-apache2}"
shift || true

case "${ROLE}" in
  apache2)
    /usr/local/bin/render-config.sh
    exec apache2-foreground
    ;;
  bash)
    exec bash "$@"
    ;;
  sh)
    exec sh "$@"
    ;;
  *)
    echo "Unknown role: ${ROLE}" >&2
    echo "Usage: entrypoint.sh {apache2|bash|sh}" >&2
    exit 1
    ;;
esac
