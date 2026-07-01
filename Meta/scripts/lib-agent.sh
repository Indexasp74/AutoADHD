#!/bin/bash
# Shared safety helpers for vault agent runners.

agent_vault_dir="${VAULT_DIR:-${VAULT_DIR:-$HOME/VaultSandbox}}"
agent_lib_dir="$agent_vault_dir/Meta/scripts"

agent_git() {
    # Where agent commits go. Two-repo mode (VAULT_GIT_DIR set): vault CONTENT
    # commits land in the PRIVATE vault repo (engine files are ignored there, so
    # engine self-heals stay uncommitted in the public repo for human review).
    # Single-repo mode (unset): the one repo at $agent_vault_dir, as before.
    if [ -n "${VAULT_GIT_DIR:-}" ]; then
        git --git-dir="$VAULT_GIT_DIR" --work-tree="$agent_vault_dir" "$@"
    else
        git -C "$agent_vault_dir" "$@"
    fi
}

# Guard against the silent-commit-loss class of bug. Two known ways to trigger it:
#   (a) VAULT_DIR unset -> agent_vault_dir falls back to $HOME/VaultSandbox, a
#       work-tree with no vault content at all.
#   (b) VAULT_GIT_DIR unset in a LONG-RUNNING daemon's environment (watch-voice-
#       drop.sh, vault-bot.py — started once, env fixed at start time, unlike
#       cron agents which re-source .env fresh via cron-wrapper.sh every run).
#       agent_git then silently falls back to single-repo mode against the
#       ENGINE repo's own .git, where Canon/ Thinking/ etc. are gitignored
#       (they're meant to be tracked by the separate vault-content repo). Every
#       commit call sees "nothing to stage" and returns 0 — no error anywhere.
# Confirmed live 2026-07-01: watch-voice-drop.sh (PID 257857) had been running
# since 2026-06-19 — 11 days before VAULT_GIT_DIR was added to .env — silently
# discarding every voice-triggered extraction commit that whole time with zero
# visible error (extraction "succeeded", HEAD never moved, Reviewer's own
# HEAD~1..HEAD diff check saw nothing and skipped too, masking the gap further).
# Both failure modes converge on the same real invariant: whatever repo
# agent_git resolves to must NOT ignore Canon/. Check that directly rather than
# just checking VAULT_GIT_DIR's presence, so a wrong-but-set path is caught too.
agent_assert_vault_worktree() {
    if [ ! -d "$agent_vault_dir/Canon" ] || [ ! -d "$agent_vault_dir/Meta/scripts" ]; then
        echo "FATAL: agent work-tree does not look like the vault: '$agent_vault_dir'" >&2
        echo "  VAULT_DIR='${VAULT_DIR:-<unset>}' VAULT_GIT_DIR='${VAULT_GIT_DIR:-<unset>}'" >&2
        echo "  Commits would silently no-op against the wrong tree. Refusing to continue." >&2
        "$agent_lib_dir/send-telegram.sh" "🔴 Agent misconfig: work-tree '$agent_vault_dir' is not the vault (VAULT_DIR unset?). Commits would silently vanish — run aborted." 2>/dev/null || true
        return 1
    fi
    if [ -n "${VAULT_GIT_DIR:-}" ] && [ ! -d "$VAULT_GIT_DIR" ]; then
        echo "FATAL: VAULT_GIT_DIR set but not found: '$VAULT_GIT_DIR'" >&2
        return 1
    fi
    if agent_git check-ignore -q "$agent_vault_dir/Canon/People" 2>/dev/null; then
        local resolved="single-repo mode (VAULT_GIT_DIR unset) at $agent_vault_dir/.git"
        [ -n "${VAULT_GIT_DIR:-}" ] && resolved="VAULT_GIT_DIR=$VAULT_GIT_DIR"
        echo "FATAL: Canon/ is git-ignored by the resolved repo ($resolved)." >&2
        echo "  Every commit would silently vanish (git sees nothing to stage). Refusing to continue." >&2
        "$agent_lib_dir/send-telegram.sh" "🔴 Agent misconfig: Canon/ is gitignored by the resolved repo ($resolved). Commits would silently vanish — run aborted. Likely a stale long-running daemon with an outdated env; restart it." 2>/dev/null || true
        return 1
    fi
    return 0
}

agent_require_commands() {
    local missing=0
    local cmd

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Missing required command: $cmd" >&2
            missing=1
        fi
    done

    return "$missing"
}

# Clean-worktree guard. Reports only uncommitted modifications to TRACKED
# files (its real purpose: stop an agent from clobbering work-in-progress).
# Untracked files are excluded (--untracked-files=no): agents legitimately
# generate new notes every run (daily briefing, research articles, AI
# reflections) and committing each one's pathspec is their own job — a
# generated untracked note must never block the next agent. The grep still
# drops tracked-file churn that is expected (obsidian workspace, changelog,
# MANIFEST). changelog.md and MANIFEST.md are both auto-generated bookkeeping
# (build-manifest.sh rewrites MANIFEST.md wholesale every run and never commits
# it); they must never block the next agent or extractions deadlock in a
# failure-retry-failure loop on a dirty derived file.
agent_filtered_worktree_status() {
    agent_git status --porcelain --untracked-files=no | grep -vE '^[ MARCUD?!]{2} (\.obsidian/workspace\.json|\.obsidian/graph\.json|Meta/changelog\.md|Meta/MANIFEST\.md|Inbox/Voice/_drop/.*|Inbox/Voice/_processed/.*|Inbox/Voice/_processing/.*|Inbox/Voice/_extracted/.*|Inbox/Voice/_duplicate/.*|\.agent-locks/.*)$' || true
}

# Record an agent heartbeat: machine-local $HOME/.vault/heartbeats/<name>
# containing "<epoch> <status>". For runners (e.g. the briefing) that don't go
# through invoke-agent.sh. Kept out of the vault so it never causes git churn.
agent_write_heartbeat() {
    local name status dir
    name=$(printf '%s' "${1:?heartbeat name required}" | tr '[:upper:]' '[:lower:]')
    status="${2:-ok}"
    dir="$HOME/.vault/heartbeats"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s %s\n' "$(date +%s)" "$status" > "$dir/$name" 2>/dev/null || true
}

agent_clear_stale_git_locks() {
    local git_dir
    local removed=0
    local lock_file

    git_dir="$(agent_git rev-parse --git-dir 2>/dev/null)" || return 0

    for lock_file in "$git_dir/index.lock" "$git_dir/HEAD.lock"; do
        [ -e "$lock_file" ] || continue
        if pgrep -x git >/dev/null 2>&1; then
            echo "Git lock present but a live git process exists; leaving lock in place: $lock_file" >&2
            return 0
        fi
        rm -f "$lock_file"
        echo "Removed stale git lock: $lock_file" >&2
        removed=1
    done

    return "$removed"
}

agent_assert_clean_worktree() {
    local agent_name="${1:-Agent}"
    local filtered_status

    if [ "${VAULT_AGENT_ALLOW_DIRTY:-0}" = "1" ]; then
        return 0
    fi

    agent_clear_stale_git_locks >/dev/null 2>&1 || true
    filtered_status="$(agent_filtered_worktree_status)"

    if [ -n "$filtered_status" ]; then
        echo "$agent_name refused to run because the git worktree is not clean." >&2
        echo "Commit, stash, or set VAULT_AGENT_ALLOW_DIRTY=1 if you really want to override this." >&2
        return 1
    fi
}

agent_release_lock() {
    if [ -n "${VAULT_AGENT_LOCK_DIR:-}" ] && [ -d "${VAULT_AGENT_LOCK_DIR}" ]; then
        rm -f "${VAULT_AGENT_LOCK_DIR}/pid" "${VAULT_AGENT_LOCK_DIR}/started_at"
        rmdir "${VAULT_AGENT_LOCK_DIR}" 2>/dev/null || true
    fi
}

agent_acquire_lock() {
    local lock_name="${1:-vault-agent}"
    local max_age_seconds="${2:-900}"  # Default: 15 min timeout
    local lock_root="$agent_vault_dir/.agent-locks"
    local retry_max=0
    local retry_delay=30

    # Opt-in retry: set AGENT_LOCK_RETRY=true before calling
    if [ "${AGENT_LOCK_RETRY:-}" = "true" ]; then
        retry_max="${AGENT_LOCK_RETRY_MAX:-3}"
        retry_delay="${AGENT_LOCK_RETRY_DELAY:-30}"
    fi

    if [ "${VAULT_AGENT_LOCK_HELD:-0}" = "1" ]; then
        return 0
    fi

    mkdir -p "$lock_root"
    VAULT_AGENT_LOCK_DIR="$lock_root/${lock_name}.lock"

    local attempt=0
    while true; do

    local lock_acquired=0
    if mkdir "$VAULT_AGENT_LOCK_DIR" 2>/dev/null; then
        lock_acquired=1
    else
        # Lock exists — check if it's stale
        local should_break=0

        # Check 1: Is the owning process dead?
        if [ -f "$VAULT_AGENT_LOCK_DIR/pid" ]; then
            local existing_pid
            existing_pid="$(cat "$VAULT_AGENT_LOCK_DIR/pid" 2>/dev/null || true)"
            if [ -n "$existing_pid" ] && ! kill -0 "$existing_pid" 2>/dev/null; then
                echo "Breaking stale lock $lock_name: PID $existing_pid is dead" >&2
                should_break=1
            fi
        else
            # No PID file = orphaned lock dir
            echo "Breaking orphaned lock $lock_name: no PID file" >&2
            should_break=1
        fi

        # Check 2: Is the lock older than max_age_seconds?
        if [ "$should_break" -eq 0 ] && [ -f "$VAULT_AGENT_LOCK_DIR/started_at" ]; then
            local started_at lock_age
            started_at=$(stat -c %Y "$VAULT_AGENT_LOCK_DIR/started_at" 2>/dev/null \
                      || stat -f %m "$VAULT_AGENT_LOCK_DIR/started_at" 2>/dev/null \
                      || echo 0)
            lock_age=$(( $(date +%s) - started_at ))
            if [ "$lock_age" -gt "$max_age_seconds" ]; then
                local mins_old=$(( lock_age / 60 ))
                echo "Breaking stale lock $lock_name: ${mins_old}m old (max ${max_age_seconds}s)" >&2
                should_break=1
            fi
        fi

        if [ "$should_break" -eq 1 ]; then
            rm -f "$VAULT_AGENT_LOCK_DIR/pid" "$VAULT_AGENT_LOCK_DIR/started_at"
            rmdir "$VAULT_AGENT_LOCK_DIR" 2>/dev/null || true
            if mkdir "$VAULT_AGENT_LOCK_DIR" 2>/dev/null; then
                lock_acquired=1
            fi
        fi
    fi

    if [ "$lock_acquired" -eq 0 ]; then
        # Lock not acquired — retry or fail
        if [ "$attempt" -lt "$retry_max" ]; then
            attempt=$((attempt + 1))
            local holder_pid=""
            [ -f "$VAULT_AGENT_LOCK_DIR/pid" ] && holder_pid=$(cat "$VAULT_AGENT_LOCK_DIR/pid" 2>/dev/null || true)
            echo "Lock $lock_name held (PID ${holder_pid:-?}), retry $attempt/$retry_max in ${retry_delay}s..." >&2
            sleep "$retry_delay"
            continue
        fi

        echo "Another vault agent run is already active: $lock_name" >&2
        if [ -f "$VAULT_AGENT_LOCK_DIR/pid" ]; then
            echo "Active PID: $(cat "$VAULT_AGENT_LOCK_DIR/pid")" >&2
        fi
        if [ -f "$VAULT_AGENT_LOCK_DIR/started_at" ]; then
            echo "Started: $(cat "$VAULT_AGENT_LOCK_DIR/started_at")" >&2
        fi

        # Telegram alert on final failure (if retry was enabled)
        if [ "$retry_max" -gt 0 ] && [ -x "$agent_lib_dir/send-telegram.sh" ]; then
            local holder_info=""
            [ -f "$VAULT_AGENT_LOCK_DIR/pid" ] && holder_info="PID $(cat "$VAULT_AGENT_LOCK_DIR/pid" 2>/dev/null)"
            "$agent_lib_dir/send-telegram.sh" "⚠️ Lock contention: could not acquire $lock_name after $retry_max retries. Holder: ${holder_info:-unknown}" 2>/dev/null || true
        fi
        return 1
    fi

    break
    done  # end retry loop

    printf '%s\n' "$$" > "$VAULT_AGENT_LOCK_DIR/pid"
    date '+%Y-%m-%d %H:%M:%S' > "$VAULT_AGENT_LOCK_DIR/started_at"
    export VAULT_AGENT_LOCK_DIR
    export VAULT_AGENT_LOCK_HELD=1
    trap agent_release_lock EXIT INT TERM
}

agent_stage_and_commit() {
    local message="${1:?commit message required}"
    shift

    if [ "$#" -eq 0 ]; then
        echo "agent_stage_and_commit requires at least one pathspec." >&2
        return 1
    fi

    # Validate the work-tree before trusting "nothing to stage" — a wrong tree
    # makes that check lie and the commit vanish silently. See 2026-07-01 incident.
    agent_assert_vault_worktree || return 1

    if [ -z "$(agent_git status --porcelain -- "$@")" ]; then
        return 0
    fi

    agent_clear_stale_git_locks >/dev/null 2>&1 || true
    agent_git add -- "$@"

    if agent_git diff --cached --quiet; then
        return 0
    fi

    agent_clear_stale_git_locks >/dev/null 2>&1 || true
    agent_git commit -m "$message"
}

agent_commit_changelog_if_needed() {
    local message="${1:?commit message required}"
    agent_stage_and_commit "$message" Meta/changelog.md
}

agent_note_get_status() {
    local note_path="${1:?note path required}"
    python3 - "$note_path" <<'PYEOF'
import sys

path = sys.argv[1]
status = ""
in_frontmatter = False

with open(path, "r") as fh:
    for i, line in enumerate(fh):
        if i == 0 and line.strip() == "---":
            in_frontmatter = True
            continue
        if in_frontmatter and line.strip() == "---":
            break
        if in_frontmatter and line.startswith("status:"):
            status = line.split(":", 1)[1].strip()
            break

print(status)
PYEOF
}

agent_note_set_status() {
    local note_path="${1:?note path required}"
    local new_status="${2:?new status required}"
    python3 - "$note_path" "$new_status" <<'PYEOF'
import sys

path, new_status = sys.argv[1], sys.argv[2]

with open(path, "r") as fh:
    lines = fh.readlines()

if not lines or lines[0].strip() != "---":
    raise SystemExit(f"Note has no frontmatter: {path}")

for idx in range(1, len(lines)):
    if lines[idx].strip() == "---":
        lines.insert(idx, f"status: {new_status}\n")
        break
    if lines[idx].startswith("status:"):
        lines[idx] = f"status: {new_status}\n"
        break

with open(path, "w") as fh:
    fh.writelines(lines)
PYEOF
}

agent_path_is_forbidden() {
    local path="$1"
    shift
    local forbidden_prefix

    for forbidden_prefix in "$@"; do
        case "$path" in
            "$forbidden_prefix"|"$forbidden_prefix"/*)
                return 0
                ;;
        esac
    done

    return 1
}

agent_assert_no_forbidden_commits() {
    local agent_name="${1:?agent name required}"
    local before_head="${2:?before head required}"
    shift 2

    if [ "$#" -eq 0 ]; then
        return 0
    fi

    if [ "$(agent_git rev-parse HEAD)" = "$before_head" ]; then
        return 0
    fi

    local committed_paths
    local path
    local offending=()

    committed_paths="$(agent_git diff --name-only "$before_head"..HEAD)"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if agent_path_is_forbidden "$path" "$@"; then
            offending+=("$path")
        fi
    done <<< "$committed_paths"

    if [ "${#offending[@]}" -gt 0 ]; then
        echo "$agent_name committed forbidden paths:" >&2
        printf ' - %s\n' "${offending[@]}" >&2
        return 1
    fi
}

agent_extract_after_marker() {
    local marker="${1:?marker required}"
    local input="${2:-}"

    printf '%s\n' "$input" | awk -v marker="$marker" '
        found { print }
        $0 == marker && !found { found=1; print }
    '
}

agent_assert_no_forbidden_worktree_paths() {
    local agent_name="${1:?agent name required}"
    shift

    if [ "$#" -eq 0 ]; then
        return 0
    fi

    local status_output
    local path
    local offending=()

    status_output="$(agent_git status --porcelain --untracked-files=normal)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path="${line#?? }"
        path="${path#??}"
        path="${path# }"
        for forbidden_prefix in "$@"; do
            case "$path" in
                "$forbidden_prefix"|"$forbidden_prefix"/*)
                    offending+=("$path")
                    break
                    ;;
            esac
        done
    done <<< "$status_output"

    if [ "${#offending[@]}" -gt 0 ]; then
        echo "$agent_name left forbidden worktree paths:" >&2
        printf ' - %s\n' "${offending[@]}" >&2
        return 1
    fi
}
