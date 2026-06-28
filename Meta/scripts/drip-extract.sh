#!/bin/bash
# drip-extract.sh — budget-paced, session-limit-aware extraction of the backlog.
#
# WHY THIS EXISTS
# A typical Extractor run costs ~$1 / ~25 turns / ~3 min, but entity-rich memos
# can spiral and a Claude Pro ~5-hour session window only holds a handful of runs
# before it trips ("You've hit your session limit · resets H:MMam"). Firing the
# whole backlog at once trips that limit, which used to fail notes and re-queue
# them forever. This script drains the backlog one note at a time, PACED TO STAY
# SHY of the limit rather than bouncing off it.
#
# PACING MODEL (proactive budget, not reactive backoff)
# Pro resets on a rolling ~5h window. We process at most DRIP_NOTES_PER_WINDOW
# notes per window, spread EVENLY across the window so consumption is a slow
# drip, never a burst. When the window's budget is spent we proactively rest
# until the window rolls over, then continue. The session-limit 429 is kept ONLY
# as a self-correcting backstop: if our estimate is too generous and we trip it
# anyway, we parse the real reset time, sleep to it, and re-anchor the window.
#
# It is ONE long-running process (not many cron fires): cron kicks it off at the
# start of the low-usage window (1 AM ET) and the script carries itself across
# the hours via internal sleeps, stopping at DRIP_MAX_RUNTIME (~8:30 AM) so the
# remainder drains on following nights ("drain across nights").
#
# SAFETY
# - flock in the cron line prevents overlapping runs.
# - Reuses run-extractor.sh (the same extraction the voice pipeline runs).
# - VAULT_AGENT_ALLOW_DIRTY=1: matches the voice pipeline; a dirty derived file
#   can never deadlock the drip (see lib-agent.sh guard whitelist).
# - A note that completed extraction but tripped a tail-end 429 is detected as
#   success (status: extracted + ## Extracted section), never re-failed.
#
# TUNABLES (env, with defaults):
#   DRIP_MAX_RUNTIME      27000  total seconds before stopping (7.5h: 1AM->8:30AM)
#   DRIP_WINDOW_SECONDS   18000  Pro session window length (~5h), for pacing math
#   DRIP_NOTES_PER_WINDOW 4      notes to process per window before resting (shy
#                                of the limit; ~4 typical ~$1 notes leaves headroom)
#   DRIP_MIN_NOTE_GAP     90     floor on spacing between notes (seconds)
#   DRIP_RESET_BUFFER     300    seconds to wait PAST a reset before resuming
#   DRIP_DEFAULT_WAIT     3600   fallback wait when a reset time can't be parsed
#   DRIP_MAX_CONSEC_FAIL  3      consecutive GENUINE failures before aborting
#   DRIP_MAX_NOTE_RETRIES 4      max session-limit waits for a single note

set -uo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"

export VAULT_AGENT_ALLOW_DIRTY=1
export VAULT_AGENT_CONTEXT=drip-extract

MAX_RUNTIME="${DRIP_MAX_RUNTIME:-27000}"
WINDOW_SECONDS="${DRIP_WINDOW_SECONDS:-18000}"
NOTES_PER_WINDOW="${DRIP_NOTES_PER_WINDOW:-4}"
MIN_NOTE_GAP="${DRIP_MIN_NOTE_GAP:-90}"
RESET_BUFFER="${DRIP_RESET_BUFFER:-300}"
DEFAULT_WAIT="${DRIP_DEFAULT_WAIT:-3600}"
MAX_CONSEC_FAIL="${DRIP_MAX_CONSEC_FAIL:-3}"
MAX_NOTE_RETRIES="${DRIP_MAX_NOTE_RETRIES:-4}"

START_TS=$(date +%s)
WINDOW_START=0          # epoch of the current Pro window's first extraction (0 = not yet opened)
NOTES_THIS_WINDOW=0
EXTRACTED=0
FAILED=0
SKIPPED=0
WAITS=0
CONSEC_FAIL=0
STOP=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

notify() {
    [ -x "$SCRIPT_DIR/send-telegram.sh" ] || return 0
    "$SCRIPT_DIR/send-telegram.sh" "$1" >/dev/null 2>&1 || true
}

# Seconds left in this night's overall runtime. <=0 means stop for the night.
budget_left() { echo $(( MAX_RUNTIME - ( $(date +%s) - START_TS ) )); }

# Seconds until the current Pro window is expected to roll over (+buffer).
seconds_until_window_rollover() {
    local now end
    now=$(date +%s)
    end=$(( WINDOW_START + WINDOW_SECONDS + RESET_BUFFER ))
    [ "$end" -gt "$now" ] && echo $(( end - now )) || echo 0
}

# Even spacing so the window's note budget is a slow drip, not a burst:
# spread the notes still allowed this window across the time left in the window,
# floored at MIN_NOTE_GAP.
note_gap() {
    local left_in_window notes_left now gap
    now=$(date +%s)
    left_in_window=$(( WINDOW_START + WINDOW_SECONDS - now ))
    notes_left=$(( NOTES_PER_WINDOW - NOTES_THIS_WINDOW ))
    [ "$notes_left" -lt 1 ] && notes_left=1
    [ "$left_in_window" -lt 0 ] && left_in_window=0
    gap=$(( left_in_window / notes_left ))
    [ "$gap" -lt "$MIN_NOTE_GAP" ] && gap="$MIN_NOTE_GAP"
    echo "$gap"
}

# True if the note landed: status: extracted AND an ## Extracted section.
note_is_extracted() {
    grep -q '^status: extracted$' "$1" 2>/dev/null \
        && grep -q '^## Extracted' "$1" 2>/dev/null
}

# Parse "resets 4:50am" out of extractor output and return seconds to sleep
# until that moment (+buffer). The reset clock is Pro's, in America/New_York.
# Falls back to DEFAULT_WAIT when it can't be parsed.
seconds_until_reset() {
    local out="$1" clock target now
    clock=$(printf '%s' "$out" | grep -oiE 'resets[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]*[ap]m' \
            | head -1 | sed -E 's/^resets[[:space:]]+//I' | tr -d '[:space:]')
    if [ -n "$clock" ]; then
        now=$(date +%s)
        target=$(TZ=America/New_York date -d "$clock" +%s 2>/dev/null || true)
        if [ -n "${target:-}" ]; then
            [ "$target" -le "$now" ] && target=$(TZ=America/New_York date -d "tomorrow $clock" +%s 2>/dev/null || true)
            if [ -n "${target:-}" ] && [ "$target" -gt "$now" ]; then
                echo $(( target - now + RESET_BUFFER )); return 0
            fi
        fi
    fi
    echo "$DEFAULT_WAIT"
}

# Sleep in <=60s slices so the runtime cap and SIGTERM are honored promptly.
# Returns non-zero if the night's runtime cap is hit mid-sleep.
nap() {
    local remaining="$1" slice
    while [ "$remaining" -gt 0 ]; do
        [ "$STOP" = "1" ] && return 1
        [ "$(budget_left)" -gt 0 ] || return 1
        slice=60; [ "$remaining" -lt 60 ] && slice="$remaining"
        sleep "$slice"
        remaining=$(( remaining - slice ))
    done
    return 0
}

build_queue() {
    # Failed + unprocessed inbox notes, oldest first (filenames are date-prefixed).
    # Exclude duplicate copies (-N.md) and the pipeline's _-prefixed subfolders.
    grep -rlE '^status: (failed|inbox|transcribed)$' Inbox/ 2>/dev/null \
        | grep -vE '/_[a-z]+/' \
        | grep -vE '\-[0-9]\.md$' \
        | LC_ALL=C sort
}

# Open a fresh Pro window anchored at `now`, resetting the per-window counter.
open_window() { WINDOW_START=$(date +%s); NOTES_THIS_WINDOW=0; }

# Proactively rest until the current window rolls over, then re-anchor. Returns
# non-zero if the night's runtime cap is reached during the rest.
rest_until_rollover() {
    local wait_s; wait_s=$(seconds_until_window_rollover)
    if [ "$wait_s" -gt 0 ]; then
        log "Window budget spent ($NOTES_THIS_WINDOW/$NOTES_PER_WINDOW). Resting ${wait_s}s for the window to roll over."
        nap "$wait_s" || return 1
    fi
    open_window
    return 0
}

trap 'log "Received signal — stopping after current note."; STOP=1' TERM INT

log "drip-extract starting. runtime=${MAX_RUNTIME}s window=${WINDOW_SECONDS}s notes/window=${NOTES_PER_WINDOW}"
agent_write_heartbeat "drip-extract"

mapfile -t QUEUE < <(build_queue)
TOTAL=${#QUEUE[@]}
log "Queue: $TOTAL note(s)."

if [ "$TOTAL" -eq 0 ]; then
    log "Nothing to extract. Exiting."
    exit 0
fi

for note in "${QUEUE[@]}"; do
    [ "$STOP" = "1" ] && { log "Stop requested."; break; }
    [ "$(budget_left)" -gt 0 ] || { log "Nightly runtime cap reached — remaining notes carry to next night."; break; }
    [ "$CONSEC_FAIL" -lt "$MAX_CONSEC_FAIL" ] || { log "Too many consecutive failures ($CONSEC_FAIL) — aborting night."; break; }
    [ -f "$note" ] || { log "Vanished, skipping: $note"; continue; }

    # Already done (e.g. picked up by the live pipeline since the queue was built)?
    if note_is_extracted "$note"; then
        log "Already extracted, skipping: $(basename "$note")"
        SKIPPED=$((SKIPPED+1)); continue
    fi

    # Proactive budget gate: open the first window, or rest if this window's
    # note budget is already spent. This is what keeps us SHY of the limit.
    if [ "$WINDOW_START" -eq 0 ]; then
        open_window
    elif [ "$NOTES_THIS_WINDOW" -ge "$NOTES_PER_WINDOW" ]; then
        rest_until_rollover || { log "Runtime cap reached while resting — carrying to next night."; break; }
    fi

    attempt=0
    note_done=0
    while [ "$note_done" -eq 0 ]; do
        attempt=$((attempt+1))
        log "Extracting (attempt $attempt, note ${NOTES_THIS_WINDOW}/${NOTES_PER_WINDOW} this window): $(basename "$note")"
        agent_note_set_status "$note" "extracting" 2>/dev/null || true

        out_file=$(mktemp "/tmp/drip-extract.XXXXXX")
        /bin/bash "$SCRIPT_DIR/run-extractor.sh" "$note" >"$out_file" 2>&1
        rc=$?
        out="$(cat "$out_file" 2>/dev/null)"; rm -f "$out_file"

        # Success is the note's end state, not the exit code: the extractor can
        # finish and only then trip a tail-end 429.
        if note_is_extracted "$note"; then
            log "  -> extracted ✓ (rc=$rc)"
            EXTRACTED=$((EXTRACTED+1)); CONSEC_FAIL=0
            NOTES_THIS_WINDOW=$((NOTES_THIS_WINDOW+1))
            agent_write_heartbeat "drip-extract"

            # QA pass — mirrors process-voice-memo.sh's Extractor->Reviewer chain,
            # which this script previously skipped (every drip-extracted note got
            # zero QA). VAULT_AGENT_CONTEXT=drip-extract (exported above) makes
            # run-reviewer.sh fast-path to just this note and skip its own commit;
            # the 5-min alarm keeps a hung Reviewer call from stalling the pacing
            # budget. Non-fatal: QA failures don't undo the extraction.
            log "  -> running Reviewer QA pass..."
            rev_out=$(perl -e 'alarm 300; exec @ARGV' /bin/bash "$SCRIPT_DIR/run-reviewer.sh" "$note" 2>&1)
            rev_rc=$?
            if [ "$rev_rc" -ne 0 ]; then
                log "  -> Reviewer failed/timed out (rc=$rev_rc, non-fatal): $(printf '%s' "$rev_out" | tail -2 | tr '\n' ' ')"
            fi
            if ! agent_assert_no_forbidden_worktree_paths "drip-extract" \
                    Meta/Agents Meta/scripts Meta/research Thinking/Research \
                    CLAUDE.md HOME.md AGENTS.md Meta/Architecture.md Meta/agent-runtimes.conf; then
                log "  -> Reviewer left forbidden worktree paths — not auto-committing, left for human review."
                notify "⚠️ drip-extract: Reviewer touched forbidden paths reviewing $(basename "$note") — left uncommitted."
            else
                agent_stage_and_commit "[Pipeline] review: drip-extract QA pass for $(basename "$note")" \
                    Canon/ Thinking/ Meta/AI-Reflections/ Meta/review-queue/ Meta/changelog.md
            fi

            note_done=1
            break
        fi

        if printf '%s' "$out" | grep -qiE 'session limit|hit your.*limit|resets[[:space:]]+[0-9]{1,2}:[0-9]{2}|too many (api )?calls|rate.?limit|status.?429'; then
            # Backstop: our budget estimate was too generous. Honor the real
            # reset time, re-anchor the window to it, and retry the same note.
            if [ "$attempt" -gt "$MAX_NOTE_RETRIES" ]; then
                log "  -> still rate-limited after $MAX_NOTE_RETRIES waits; leaving failed for next night."
                agent_note_set_status "$note" "failed" 2>/dev/null || true
                note_done=1; break
            fi
            wait_s=$(seconds_until_reset "$out")
            WAITS=$((WAITS+1))
            log "  -> session limit hit early. Sleeping ${wait_s}s to the real reset, then retrying. (tightening pace)"
            agent_note_set_status "$note" "failed" 2>/dev/null || true   # safe state while waiting
            if ! nap "$wait_s"; then
                log "  -> runtime cap reached during wait — note carries to next night."
                STOP=1; note_done=1; break
            fi
            open_window   # the reset opened a fresh window
            continue      # retry the same note
        fi

        # Genuine failure (not rate-limited, not extracted).
        log "  -> failed (rc=$rc, not rate-limited)."
        agent_note_set_status "$note" "failed" 2>/dev/null || true
        FAILED=$((FAILED+1)); CONSEC_FAIL=$((CONSEC_FAIL+1))
        note_done=1
        break
    done

    # Even-paced gap before the next note (slow drip across the window).
    [ "$STOP" = "1" ] && break
    gap=$(note_gap)
    [ "$(budget_left)" -gt "$gap" ] || { log "Not enough runtime left for another paced note."; break; }
    log "Pacing ${gap}s before next note."
    nap "$gap" || break
done

REMAINING=$(build_queue | wc -l | tr -d ' ')
ELAPSED=$(( ( $(date +%s) - START_TS ) / 60 ))
log "Done. extracted=$EXTRACTED failed=$FAILED skipped=$SKIPPED waits=$WAITS remaining=$REMAINING (${ELAPSED}min)"
agent_write_heartbeat "drip-extract"
if [ "$EXTRACTED" -gt 0 ] || [ "$FAILED" -gt 0 ] || [ "$WAITS" -gt 0 ]; then
    notify "🩸 *Drip extraction* — ${ELAPSED}min
Extracted: $EXTRACTED · Failed: $FAILED · Skipped: $SKIPPED
Limit waits: $WAITS · Still queued: $REMAINING"
fi
exit 0
