#!/bin/bash
# push-vault.sh — push the PRIVATE vault repo to its remote (two-repo mode only).
# No-op in single-repo mode (VAULT_GIT_DIR unset). Run from cron.

set -uo pipefail

[ -n "${VAULT_GIT_DIR:-}" ] || { echo "single-repo mode — nothing to push"; exit 0; }
[ -d "$VAULT_GIT_DIR" ] || { echo "VAULT_GIT_DIR not found: $VAULT_GIT_DIR" >&2; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

git --git-dir="$VAULT_GIT_DIR" --work-tree="$VAULT_ROOT" push -q origin main 2>&1 | tail -3 || true
