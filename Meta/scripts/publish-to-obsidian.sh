#!/bin/bash
# publish-to-obsidian.sh — one-way mirror of AutoADHD's human-facing content
# into a DEDICATED subfolder of your Obsidian vault.
#
# The WSL vault stays the source of truth (agents read/write there, fast,
# git-tracked). This publishes a read view — Canon, Thinking, Articles, the
# HOME dashboard, and the Meta folders the dashboard queries — into
# $OBSIDIAN_VAULT/$OBSIDIAN_SUBDIR so you can browse/search/link it in Obsidian
# (and sync via Google Drive). Engine files, working dirs, audio, and logs are
# never published.
#
# Config (set in .env):
#   OBSIDIAN_VAULT    Obsidian vault root (REQUIRED). e.g. /mnt/e/.../rich-personal
#   OBSIDIAN_SUBDIR   Dedicated subfolder to publish into (default: AutoADHD)
#   OBSIDIAN_PUBLISH  1 to enable (default), 0 to disable
#
# SAFETY: this uses rsync --delete, so it is scoped to the dedicated subfolder
# ONLY. It refuses to run against the vault root, so it can never touch your
# other notes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

[ "${OBSIDIAN_PUBLISH:-1}" = "1" ] || { echo "OBSIDIAN_PUBLISH=0 — publishing disabled"; exit 0; }
: "${OBSIDIAN_VAULT:?OBSIDIAN_VAULT not set — point it at your Obsidian vault root}"
OBSIDIAN_SUBDIR="${OBSIDIAN_SUBDIR:-AutoADHD}"

# --- Safety guards: never --delete against the vault root or a bad target ---
case "$OBSIDIAN_SUBDIR" in
    ""|"."|"./"|"/"|".."|"../"*|*"/..") echo "refusing: OBSIDIAN_SUBDIR must be a plain dedicated subfolder" >&2; exit 1;;
esac
[ -d "$OBSIDIAN_VAULT" ] || { echo "OBSIDIAN_VAULT not found: $OBSIDIAN_VAULT" >&2; exit 1; }

DEST="$OBSIDIAN_VAULT/$OBSIDIAN_SUBDIR"
mkdir -p "$DEST"

command -v rsync >/dev/null 2>&1 || { echo "rsync not installed" >&2; exit 1; }

# Excludes applied to every subtree: audio, telemetry logs, locks, vcs/venv.
EXCLUDES=(
    --exclude='*.ogg' --exclude='*.m4a' --exclude='*.mp3' --exclude='*.wav'
    --exclude='*.mp4' --exclude='*.webm'
    --exclude='*.jsonl' --exclude='*.log' --exclude='*.lock'
    --exclude='*-log.md'           # implementer-log / retro-log / review-log telemetry
    --exclude='.git/' --exclude='.obsidian/' --exclude='.gitkeep'
    --exclude='_drop/' --exclude='_processing/' --exclude='_processed/' --exclude='_extracted/'
)

# rsync options for a Windows/Google-Drive mount (DrvFs): the mount rejects
# chgrp/chmod AND setting mtimes, so don't preserve perms/owner/group/times.
# Without mtimes, detect changes by content checksum (-c) so unchanged notes
# aren't needlessly re-copied (which would re-trigger Google Drive sync every
# run). --inplace avoids the temp-file create that also trips on the mount.
RSYNC_OPTS=(-r --checksum --no-perms --no-owner --no-group --inplace --delete)

# Human-facing subtrees to publish (skipped silently if absent in a fresh vault).
SUBTREES=(
    Canon
    Thinking
    Articles
    Meta/AI-Reflections
    Meta/operations
    Meta/review-queue
    Meta/sprint
    Inbox/Voice          # transcripts only — audio/working dirs excluded above
)

published=()
for sub in "${SUBTREES[@]}"; do
    if [ -d "$VAULT_ROOT/$sub" ]; then
        mkdir -p "$DEST/$sub"
        rsync "${RSYNC_OPTS[@]}" "${EXCLUDES[@]}" "$VAULT_ROOT/$sub/" "$DEST/$sub/"
        published+=("$sub")
    fi
done

# --- HOME dashboard: copy, then rewrite Dataview FROM paths for the subfolder ---
# Dataview FROM "Canon" is vault-root-relative; in a subfolder it must read
# "AutoADHD/Canon". Rewrite the published copy only (the WSL HOME.md stays
# root-relative for when the WSL vault is opened directly).
if [ -f "$VAULT_ROOT/HOME.md" ]; then
    # Transform straight from source to dest (no in-place temp on the mount).
    sed -E "s#\"(Canon|Thinking|Articles|Meta|Inbox)#\"${OBSIDIAN_SUBDIR}/\1#g" \
        "$VAULT_ROOT/HOME.md" > "$DEST/HOME.md"
    published+=("HOME.md")
fi

echo "Published to $DEST: ${published[*]}"
