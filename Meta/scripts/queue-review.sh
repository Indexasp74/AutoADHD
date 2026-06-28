#!/bin/bash
# queue-review.sh — Add an item to the review queue
# Usage: ./queue-review.sh "Canon/People/Alex Chen.md" "born" "1992" "Extracted from voice memo — verify birthyear"
#
# Writes one file per item to Meta/review-queue/ — the directory HOME.md,
# daily-briefing.sh, and the retro's stale-review check all scan. vault-bot.py
# picks up files with status: pending from there and pushes them to Telegram
# with approve/reject/skip buttons.

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
QUEUE_DIR="$VAULT_DIR/Meta/review-queue"
mkdir -p "$QUEUE_DIR"

FILE="${1:?Usage: queue-review.sh FILE FIELD VALUE REASON}"
FIELD="${2:?Usage: queue-review.sh FILE FIELD VALUE REASON}"
VALUE="${3:?Usage: queue-review.sh FILE FIELD VALUE REASON}"
REASON="${4:-AI-extracted, needs verification}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CREATED=$(date +%Y-%m-%dT%H:%M)
BASE="$(basename "$FILE" .md)"
SLUG="$(echo "${BASE}-${FIELD}" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
OUT="$QUEUE_DIR/${TIMESTAMP}-${SLUG}.md"

cat > "$OUT" << EOF
---
type: review-item
name: Confirm $FIELD on $BASE
created: $CREATED
source: extractor
urgency: low
status: pending
file: $FILE
field: $FIELD
value: $VALUE
---

# 🟡 Confirm: $FIELD on $BASE

## What needs to happen

$REASON

Proposed value: \`$FIELD: $VALUE\`

## Source

Flagged by the Extractor via \`queue-review.sh\` on $CREATED.
EOF

echo "Queued: $OUT"
