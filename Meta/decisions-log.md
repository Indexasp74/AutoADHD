---
type: meta
name: Decisions Log
purpose: Operational and architectural decisions logged by agents
---

## 2026-06-23 21:12 — Subscription (OAuth) over metered API in invoke-agent.sh Strategy 1
- **Decided:** Unset ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN before invoke-agent.sh's Strategy 1 CLI call so it uses the Pro/Max OAuth login instead of metered billing; opt out per-call with PREFER_API_BILLING=1
- **Why:** cron-wrapper.sh exports ANTHROPIC_API_KEY from .env for the Advisor SDK's benefit, but the Claude CLI silently honored that key under the 'subscription' strategy too, billing metered API. The metered balance hit zero ('Credit balance is too low'), failing every cron-invoked agent for ~2-3 days (2026-06-20 to 2026-06-22) and producing a 12-note extraction backlog
- **Rejected:** Removing ANTHROPIC_API_KEY from .env entirely — rejected because the Advisor SDK streaming path needs it (reads via the Python SDK, not this CLI path)
- **Check later:** Owner is on Claude Pro, not Max — Pro has tighter usage caps. If agents start failing again with session/usage-limit errors (not 'credit balance') instead of metered-billing errors, the fix didn't address the real ceiling and Pro's limits need direct planning, not just a routing fix
- **Source:** commit dafe8fa, 2026-06-23
- **Status:** active

## 2026-06-23 21:12 — Two-repo split: route vault content to a private repo
- **Decided:** Vault content (Canon/Inbox/Thinking/Meta runtime) commits route to a separate private repo ($VAULT_GIT_DIR, e.g. ~/.autoadhd/vault.git) via lib-agent.sh's agent_git wrapper; this engine repo (AutoADHD) stays public-shareable, tracking only system code
- **Why:** Keeps personal content (family, health, finances, relationships) out of a repo that ships as an open system; lets the engine be shared/forked without exposing the owner's life
- **Rejected:** Single-repo mode with a content .gitignore (the original approach) — rejected because it couldn't cleanly separate 'system' history from 'content' history once both had commits
- **Check later:** If two-repo mode causes confusion in retros/audits (git log in the engine repo shows no vault-content activity), make sure SETUP.md and agent specs explicitly say to check $VAULT_GIT_DIR for content history. First confirmed gap: 2026-06-23 retro's seed stats had an empty 'GIT ACTIVITY TODAY' section because it didn't check the private repo
- **Source:** commit 60ad57d, 2026-06-20
- **Status:** active

## 2026-06-24 21:25 — Revised: two-repo tripwire recurred, but root cause was a different bug
- **Revises:** the "Check later" tripwire on the 2026-06-23 21:12 two-repo split decision above
- **What happened:** Today's retro seed stats again showed an empty "GIT ACTIVITY TODAY" section, which looks like the tripwire firing. It isn't the same bug. The 2026-06-23 fix (VAULT_GIT_DIR-awareness in run-retro.sh lines 158-169) is present and correct. The actual cause: `git log --since="$DATE"` with a bare ISO date that equals today's actual date resolves to "right now" rather than midnight in this git version (2.53.0), so it excludes every commit made earlier today — verified directly: `--since="2026-06-24"` → empty; `--since="2026-06-24 00:00:00"` → all 5 of today's commits. This affects the engine-repo line too, independent of VAULT_GIT_DIR.
- **Action:** Queued for Implementer — `Meta/review-queue/20260624-212100-retro-since-date-bug.md` (Tier 1, two one-line fixes in run-retro.sh).
- **Check later:** If "GIT ACTIVITY TODAY" is blank again after that fix lands, the cause is neither of these two bugs and needs fresh investigation rather than re-assuming one of the above.
- **Source:** Retro 2026-06-24
- **Status:** active (original two-repo decision unaffected; only the tripwire diagnosis is revised)

## 2026-06-24 21:25 — Tripwire check: Pro-tier usage ceiling (2026-06-23 OAuth decision) — not triggered
- **Checked:** `Meta/agent-feedback.jsonl` entries dated 2026-06-24 (12 total: 7 Extractor, 4 VoicePipeline, 1 Briefing) — zero failures, zero session/usage-limit or credit-balance errors. `drip-extract.sh` (shipped today) adds a further proactive mitigation by pacing extraction to stay shy of the Pro session window rather than reacting to 429s.
- **Status:** active, tripwire not triggered. No action needed this cycle.

## 2026-06-28 21:10 — Tripwire check: Pro-tier usage ceiling — still not triggered
- **Checked:** All 89 `Meta/agent-feedback.jsonl` entries from the past week — zero failure/error/rate-limit/credit entries found. Holding.
- **Status:** active, tripwire not triggered.

## 2026-06-28 21:10 — Tripwire check: two-repo / since-date bug — confirmed fixed
- **Checked:** Today's retro seed stats correctly showed real git activity ("2 commit(s) since last retro") for the first time since the bug was diagnosed, and `/tmp/vault-retro.log` shows no recurrence of the blank-section symptom on 2026-06-28. The 2026-06-24 Implementer fix (`--since="$DATE 00:00:00"`) holds.
- **Status:** resolved, closing this tripwire.

## 2026-06-28 21:10 — Tripwire check: review-queue status vocabulary — confirmed fixed
- **Checked:** All 14 current `Meta/review-queue/*.md` items use only `pending`, `resolved`, or (legacy) values already covered by the broadened matchers — no `status: open` items found in this scan.
- **Status:** resolved, closing this tripwire.

## 2026-06-28 21:10 — REVISED: Reviewer-pipeline-coverage tripwire — the 2026-06-24 fix does not actually work
- **Revises:** the "NEW — Reviewer pipeline coverage" tripwire opened by the 2026-06-24 retro and marked `status: resolved` by that day's Implementer pass.
- **What happened:** The code-level wiring (drip-extract.sh calling run-reviewer.sh per note, with the VAULT_AGENT_CONTEXT=drip-extract fast path) is present exactly as described. In production it has failed on every single observed invocation — 3 for 3 on the one night (2026-06-27) drip-extract had a real backlog to process. `Meta/AI-Reflections/review-log.md` still has zero new entries; Reviewer's heartbeat was 125h stale (older than the fix itself) at the start of this retro. The failure log is truncated (`tail -2`) and hides the real error — I could reproduce a plausible cause (vault-agent-pipeline lock contention with a concurrently running agent) manually, but could not confirm it's what happened in production from the available logs.
- **Action:** Queued `Meta/review-queue/20260628-210600-drip-extract-reviewer-still-failing.md` (HIGH) — fix the log truncation first so the real error is visible, then fix the actual cause, then verify a real review-log.md entry lands before re-marking resolved.
- **Status:** active, NOT resolved — the 2026-06-24 "fixed" classification was wrong. Lesson: code-reading a fix is not the same as verifying its output landed (review-log.md, in this case) — same lesson the 2026-01-25 review-log silence already taught once.

## 2026-06-28 21:10 — New: refuse-if-dirty guard in run-retro.sh deadlocks against Implementer's by-design uncommitted engine self-heals
- **Decided:** Flagged, not yet fixed (outside retro's edit boundary — `Meta/scripts/run-retro.sh`).
- **Why this matters:** Implementer intentionally leaves engine-repo self-heals (`Meta/Agents/`, `Meta/scripts/`) uncommitted in two-repo mode, for human review. `run-retro.sh` refuses to run at all if the engine worktree is dirty. The two designs are in direct conflict: any day Implementer does its job correctly, the next day's retro (and Implementer, gated behind it) silently no-ops, every day, until a human manually commits. This produced a 3-day total outage of Retrospective + Implementer (2026-06-25 through 2026-06-27), broken only when the human committed `f9bc63e` on 2026-06-28.
- **Action:** Queued `Meta/review-queue/20260628-210500-retro-implementer-3day-outage.md` (HIGH) with two candidate fixes (scope the dirty-check to ignore the paths Implementer intentionally leaves dirty; and/or escalate in daily-briefing once Retrospective's heartbeat is 2+ days stale).
- **Check later:** If this recurs after a fix lands, check whether the fix only addressed one of the two designs (the ignore-list change) and not the visibility gap (the briefing escalation), or vice versa.
- **Status:** active, unresolved.

## 2026-06-29 21:00 — Tripwire check: Pro-tier usage ceiling — still not triggered
- **Checked:** All 91 `Meta/agent-feedback.jsonl` entries from this week — zero failure, error, rate-limit, or credit entries found. Holding.
- **Status:** active, tripwire not triggered.

## 2026-06-29 21:00 — Tripwire check: Reviewer pipeline coverage — still open, cannot confirm without output evidence
- **Checked:** `Meta/AI-Reflections/review-log.md` — still 0 entries past 2026-01-25. The 2026-06-28 Implementer applied lock-retry + full-output logging fixes, but no drip-extract backlog run has occurred since (the queue has been empty on both 2026-06-28 and 2026-06-29). Cannot confirm whether the fix works without a real backlog note being processed and a new review-log.md entry appearing.
- **Status:** active, still unconfirmed. Do NOT mark resolved without a new review-log.md entry as proof.

## 2026-06-29 21:00 — Tripwire check: retro/Implementer 3-day outage (structural conflict) — CONFIRMED FIXED
- **Checked:** `Meta/review-queue/20260628-210500-retro-implementer-3day-outage.md` — already marked `status: resolved` by Implementer (2026-06-28 same night). Implementer correctly identified the actual bug: the two-repo skip check was counting only engine-repo commits, so on any day with 0 engine commits (but vault-content commits), the retro silently skipped. Fix: sum commits from both repos. Confirmed working — today's retro ran successfully, and yesterday's (2026-06-28) also ran. Both days had zero engine-repo commits; vault-content commits kept the count non-zero.
- **Check later:** If this recurs, both the ignore-list fix (scope dirty-worktree check to exclude Implementer's paths) AND the briefing escalation fix (name Retrospective specifically when it hasn't run in 2+ days) are still improvements that would reduce blast radius in a future recurrence — the 2026-06-28 Implementer only applied the root-cause fix, not the defensive visibility upgrade. But the structural conflict itself is now resolved.
- **Status:** resolved. Closing this tripwire.

# Decisions Log

<!-- Agents append decisions here using log-decision.sh -->
