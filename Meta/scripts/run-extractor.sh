#!/bin/bash
# run-extractor.sh
# Deep extraction agent — processes one or all inbox notes
# Usage: ./run-extractor.sh [specific-note.md]  (or no arg for all unprocessed)

set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="${VAULT_DIR:-$HOME/VaultSandbox}"
unset PWD OLDPWD 2>/dev/null || true
cd "$VAULT_DIR"


SCRIPT_DIR="$VAULT_DIR/Meta/scripts"
source "$SCRIPT_DIR/lib-agent.sh"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

HEAD_BEFORE_RUN=$(agent_git rev-parse HEAD)

# Failure notification via Telegram
notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Extractor FAILED* at $(date '+%H:%M')
Reason: $1
Notes queued in Inbox — will retry next run." 2>/dev/null || true
}

echo "[$TIMESTAMP] Running Extractor agent..."

agent_require_commands git python3
agent_assert_clean_worktree "Extractor"
agent_acquire_lock "vault-agent-pipeline"

# Find notes to process
if [ -n "${1:-}" ]; then
    NOTES="$1"
else
    # Find all inbox notes not yet extracted (inbox = new, transcribed = voice pipeline)
    NOTES=$(grep -rlE "status: (inbox|transcribed)" Inbox/ 2>/dev/null || echo "")
fi

if [ -z "$NOTES" ]; then
    echo "No unprocessed inbox notes found."
    exit 0
fi

NOTE_PATHS=()
while IFS= read -r note_path; do
    [ -n "$note_path" ] || continue
    NOTE_PATHS+=("$note_path")
done <<< "$NOTES"

NOTE_COUNT="${#NOTE_PATHS[@]}"
echo "Found $NOTE_COUNT note(s) to process."

# Refresh the Canon index so the dedup list injected into the prompt is current.
# Token-free local scan; MANIFEST.md is whitelisted in the clean-worktree guard,
# so regenerating it here never blocks the agent.
/bin/bash "$SCRIPT_DIR/build-manifest.sh" >/dev/null 2>&1 || true
CANON_INDEX="$(cat "$VAULT_DIR/Meta/MANIFEST.md" 2>/dev/null || true)"
[ -n "$CANON_INDEX" ] || CANON_INDEX="(index unavailable — fall back to: find Canon/ -name '*.md' and grep -r 'aliases:' Canon/)"

# Build a lean prompt — the agent reads files itself at runtime
# This keeps the prompt under 2K tokens instead of 9K+
PROMPT="You are the EXTRACTOR agent for this Obsidian vault.

## STEP 1: Read these files (in this order)
1. Read .claude/skills/vault-extractor/SKILL.md — the complete extraction rulebook (entity types, Secondary Entity Pass, Whisper artifact matching, the 9-line ## Extracted schema, self-check, and known violation patterns are all here)
2. Read .claude/skills/vault-writer/SKILL.md — note format, frontmatter, emoji headings, provenance

## STEP 2: Existing Canon entries (your DEDUP source of truth)
The index below already lists EVERY existing Canon entry and its known aliases.
Use it — NOT find/grep — to decide create-vs-update. Do NOT scan Canon/ with
find or grep to discover what exists; that wastes dozens of turns. Only open a
specific Canon file when you have decided to UPDATE it and need its current
contents. (Escape hatch: if you suspect a Whisper-garbled name matches an
existing person that the index spellings don't make obvious, you may grep that
ONE folder — not the whole vault.)

<<< CANON INDEX (auto-generated, current as of this run) >>>
$CANON_INDEX
<<< END CANON INDEX >>>

## STEP 3: Process these notes
$NOTES

For EACH note:
1. Read the note contents (cat the file)
2. Extract ALL entities per your spec: people, events, concepts, decisions, actions, places, organizations, reflections
3. Before creating a new entry, check the CANON INDEX above for an existing entry or alias. If found, UPDATE it instead of creating a duplicate.
4. Create/update Canon entries with proper frontmatter, provenance, wikilinks, and emoji headings
5. Write the ## Extracted section back into the inbox note (MANDATORY)
6. Set status: extracted, source_agent: Extractor, and source_date: [ISO timestamp] in the inbox note frontmatter, even for no-op test notes
7. If you materially update an existing note that already has updated: or status: frontmatter, keep those fields aligned with the new content

## HARD BOUNDARY
You may modify ONLY:
- the listed inbox note(s) under Inbox/
- Canon/
- Thinking/ (for reflections or emerging notes only; do NOT create Thinking/Research/)
- Meta/review-queue/
- Meta/changelog.md

You must NOT create or edit:
- Meta/Agents/
- Meta/scripts/
- Meta/research/
- Thinking/Research/
- CLAUDE.md
- HOME.md
- AGENTS.md
- Meta/Architecture.md
- Meta/agent-runtimes.conf

If the memo suggests a new agent, workflow, or architectural idea, record it in the relevant extracted note or Meta/review-queue instead of editing control files.

## STEP 4: Finish cleanly
Do NOT run git add or git commit.
Leave your changes in the worktree. The runner will validate, update the changelog, and commit."

INVOKE_EXIT=0
INVOKE_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" extractor "$PROMPT" 2>&1) || INVOKE_EXIT=$?

if [ "$INVOKE_EXIT" -ne 0 ]; then
    # Build specific error message from the actual output
    ERROR_DETAIL=""
    if echo "$INVOKE_OUTPUT" | grep -qi "not logged in"; then
        ERROR_DETAIL="Auth failed — Claude CLI not logged in from this context"
    elif echo "$INVOKE_OUTPUT" | grep -qi "not a git repository"; then
        ERROR_DETAIL="TCC/git error — Claude can't access .git under launchd (exit $INVOKE_EXIT)"
    elif echo "$INVOKE_OUTPUT" | grep -qi "rate limit\|429"; then
        ERROR_DETAIL="Rate limited — too many API calls, will retry"
    elif echo "$INVOKE_OUTPUT" | grep -qi "overloaded\|529"; then
        ERROR_DETAIL="API overloaded — Anthropic servers busy, will retry"
    elif echo "$INVOKE_OUTPUT" | grep -qi "token\|context.*length\|too long"; then
        ERROR_DETAIL="Token limit exceeded — prompt too large for model"
    else
        # Include last 2 lines of output for unknown errors
        LAST_LINES=$(echo "$INVOKE_OUTPUT" | tail -2 | tr '\n' ' ')
        ERROR_DETAIL="exit $INVOKE_EXIT — $LAST_LINES"
    fi
    echo "Extractor invoke-agent.sh failed: $ERROR_DETAIL"
    echo "Full output: $INVOKE_OUTPUT"
    notify_failure "$ERROR_DETAIL"
    exit 1
fi
# Print the successful output
echo "$INVOKE_OUTPUT"

if ! agent_assert_no_forbidden_commits "Extractor" "$HEAD_BEFORE_RUN" \
    Meta/Agents \
    Meta/scripts \
    Meta/research \
    Thinking/Research \
    CLAUDE.md \
    HOME.md \
    AGENTS.md \
    Meta/Architecture.md \
    Meta/agent-runtimes.conf; then
    notify_failure "forbidden control-file edits detected"
    exit 1
fi

# Log to changelog
NEW_CANON=$(agent_git diff --name-status "$HEAD_BEFORE_RUN" -- Canon/ 2>/dev/null | awk '$1 == "A" {count++} END {print count+0}')
MODIFIED_CANON=$(agent_git diff --name-status "$HEAD_BEFORE_RUN" -- Canon/ 2>/dev/null | awk '$1 == "M" {count++} END {print count+0}')
"$SCRIPT_DIR/log-change.sh" "Extractor" "Processed $NOTE_COUNT note(s): ${NEW_CANON} created, ${MODIFIED_CANON} updated in Canon"

# Commit extractor-owned paths, including the changelog entry.
agent_stage_and_commit "[Extractor] extract: process $NOTE_COUNT note(s) [$TIMESTAMP]" \
    "${NOTE_PATHS[@]}" \
    Canon/ \
    Thinking/ \
    Meta/review-queue/ \
    Meta/changelog.md

"$SCRIPT_DIR/log-agent-feedback.sh" "Extractor" "extraction_complete" "Processed $NOTE_COUNT note(s)" "" "" "false" 2>/dev/null || true

# Trigger a Reviewer QA pass for extraction paths that don't already run one
# themselves. The voice pipeline (process-voice-memo.sh) and drip-extract both
# invoke the Reviewer explicitly after calling us and set VAULT_AGENT_CONTEXT to
# say so — skip those to avoid a double review. Every OTHER caller (Telegram
# text notes via vault-bot, Advisor EXTRACT, retry-failed, direct CLI) sets no
# context and would otherwise bypass QA entirely: that gap is why review-log.md
# had no real entries for months despite extraction running fine. Non-fatal and
# time-boxed (alarm 300, mirroring process-voice-memo.sh) so a slow or hung
# Reviewer never blocks or fails the extraction. The pipeline lock is already
# held (agent_acquire_lock exported VAULT_AGENT_LOCK_HELD=1), so the nested call
# reuses it rather than contending for it.
case "${VAULT_AGENT_CONTEXT:-}" in
    voice-pipeline|drip-extract)
        : ;;  # caller owns the Reviewer pass
    *)
        echo "[$TIMESTAMP] Triggering Reviewer QA pass..."
        if perl -e 'alarm 300; exec @ARGV' /bin/bash "$SCRIPT_DIR/run-reviewer.sh"; then
            echo "[$TIMESTAMP] Reviewer pass complete."
        else
            echo "[$TIMESTAMP] Reviewer pass failed/timed out (rc=$?, non-fatal)."
        fi
        ;;
esac

echo "[$TIMESTAMP] Extractor complete."
