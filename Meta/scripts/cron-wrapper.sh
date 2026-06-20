#!/bin/bash
# cron-wrapper.sh — loads the vault environment, then execs its arguments.
#
# cron runs with an empty environment, so vault scripts that rely on .env
# (TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY, WHISPER_DEVICE, VAULT_DIR, etc.)
# would otherwise see nothing. Every cron entry routes through this wrapper.
#
# Usage:  cron-wrapper.sh <command> [args...]

set -euo pipefail

# Resolve the vault dir from this script's own location (Meta/scripts/..).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load .env if present (export everything it defines).
if [ -f "$VAULT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$VAULT_ROOT/.env"
    set +a
fi

# Ensure VAULT_DIR is always set, defaulting to the repo we live in.
export VAULT_DIR="${VAULT_DIR:-$VAULT_ROOT}"

# Make sure common tool locations are on PATH (cron's PATH is minimal).
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Activate the project venv LAST so .venv/bin takes priority over system
# Python (externally-managed under PEP 668; deps live in .venv).
if [ -f "$VAULT_ROOT/.venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    . "$VAULT_ROOT/.venv/bin/activate"
fi

cd "$VAULT_DIR"
exec "$@"
