#!/bin/bash
# install-cron.sh — WSL2 / Linux replacement for install-launchd.sh.
#
# Translates the 6 launchd jobs into a managed crontab block. Idempotent:
# re-running replaces the previous block (delimited by markers) without
# touching any other crontab entries.
#
# Scheduled jobs run on a clock; the two long-running daemons (Telegram bot,
# voice watcher) are kept alive by a */5 guard that (re)starts them if the
# process isn't found — this also covers WSL startup, since @reboot is
# unreliable under WSL's cron.
#
# Prereqs on WSL:
#   sudo service cron start          # start the cron daemon
#   sudo systemctl enable cron       # (if systemd is enabled in WSL)
# cron jobs only fire while the WSL distro is running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAP="$SCRIPT_DIR/cron-wrapper.sh"

BEGIN="# >>> AutoADHD vault agents >>>"
END="# <<< AutoADHD vault agents <<<"

chmod +x "$WRAP" "$SCRIPT_DIR"/*.sh 2>/dev/null || true

read -r -d '' BLOCK <<EOF || true
$BEGIN
# Managed by Meta/scripts/install-cron.sh — do not edit by hand.
# Vault root: $VAULT_ROOT

# Daily briefing — 7:30 AM
30 7 * * *   $WRAP "$SCRIPT_DIR/daily-briefing.sh" >> /tmp/vault-briefing.log 2>&1

# Task-Enricher — daily 8:30 AM (sub-steps for actions, nudges stale items;
# no-op when there are no actions)
30 8 * * *   $WRAP "$SCRIPT_DIR/run-task-enricher.sh" >> /tmp/vault-task-enricher.log 2>&1

# Daily retrospective — 9:00 PM
0 21 * * *   $WRAP "$SCRIPT_DIR/run-retro.sh" >> /tmp/vault-retro.log 2>&1

# Weekly maintenance / Thinker — Sunday 10:00 AM
0 10 * * 0   $WRAP "$SCRIPT_DIR/weekly-maintenance.sh" >> /tmp/vault-weekly.log 2>&1

# Sprint worker — every 30 minutes (flock prevents overlap)
*/30 * * * * $WRAP flock -n /tmp/vault-sprint.lock "$SCRIPT_DIR/run-sprint-worker.sh" "$VAULT_ROOT" >> /tmp/vault-sprint.log 2>&1

# Daemons (Telegram bot + voice watcher) — keep-alive every 5 min.
# ensure-daemons.sh starts whatever is down, fully detached (setsid).
*/5 * * * *  "$SCRIPT_DIR/ensure-daemons.sh" >> /tmp/vault-daemons.log 2>&1

# Publish human-facing vault content into the Obsidian vault — every 15 min
# (no-op when nothing changed; honors OBSIDIAN_* in .env).
*/15 * * * * $WRAP "$SCRIPT_DIR/publish-to-obsidian.sh" >> /tmp/vault-publish.log 2>&1

# Push the PRIVATE vault repo to its remote — every 10 min (two-repo mode only;
# no-op when VAULT_GIT_DIR is unset).
*/10 * * * * $WRAP "$SCRIPT_DIR/push-vault.sh" >> /tmp/vault-push.log 2>&1
$END
EOF

# Pull existing crontab (empty if none), strip any previous managed block.
current="$(crontab -l 2>/dev/null || true)"
cleaned="$(printf '%s\n' "$current" | sed "/^${BEGIN}$/,/^${END}$/d")"

# Write cleaned + new block back.
{
    printf '%s\n' "$cleaned" | sed '/^$/N;/^\n$/D'
    printf '%s\n' "$BLOCK"
} | crontab -

echo "Installed AutoADHD cron block (vault root: $VAULT_ROOT)."
echo
echo "Next steps:"
echo "  1. Start the cron daemon:   sudo service cron start"
echo "  2. Verify the schedule:     crontab -l"
echo "  3. Tail a log to confirm:   tail -f /tmp/vault-telegram-bot.log"
echo
echo "Note: cron only runs while this WSL distro is open. To keep it alive,"
echo "      enable systemd in /etc/wsl.conf and 'sudo systemctl enable cron'."
