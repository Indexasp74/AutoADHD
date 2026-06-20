#!/bin/bash
# ensure-daemons.sh — keep the long-running vault daemons alive.
#
# Run from cron every few minutes (NO trailing '&' on the cron line). For each
# daemon: if it isn't running, start it fully detached via setsid so it
# survives cron's process-group teardown, launched through cron-wrapper so it
# inherits .env (TELEGRAM_BOT_TOKEN etc.) and the project venv. Returns
# immediately. Replaces the old inline 'pgrep || nohup ... &' crontab guards,
# which never reliably started (trailing '&' in cron got torn down).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAP="$SCRIPT_DIR/cron-wrapper.sh"

start_if_down() {
    local pattern="$1" log="$2"; shift 2
    if pgrep -f "$pattern" >/dev/null 2>&1; then
        return 0
    fi
    echo "[$(date +%Y%m%d-%H%M%S)] starting: $pattern" >> "$log"
    if command -v setsid >/dev/null 2>&1; then
        setsid -f "$WRAP" "$@" >> "$log" 2>&1
    else
        nohup "$WRAP" "$@" >> "$log" 2>&1 &
    fi
}

start_if_down "vault-bot.py"        /tmp/vault-telegram-bot.log  python3 "$SCRIPT_DIR/vault-bot.py"
start_if_down "watch-voice-drop.sh" /tmp/vault-voice-watcher.log "$SCRIPT_DIR/watch-voice-drop.sh" "$VAULT_ROOT"
