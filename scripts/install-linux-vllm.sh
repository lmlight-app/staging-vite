#!/bin/bash
set -e
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || true)"
if [ -f "$0" ] && [ -n "$HERE" ] && [ -f "$HERE/install-linux.sh" ] && [ "$HERE/install-linux.sh" != "$HERE/$(basename "$0")" ]; then
    exec bash "$HERE/install-linux.sh" --engine vllm "$@"
fi
SCRIPTS_URL="${DB_SCRIPTS_URL:-https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/}"
curl -fsSL "${SCRIPTS_URL%/}/install-linux.sh" | bash -s -- --engine vllm "$@"
