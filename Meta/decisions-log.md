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

# Decisions Log

<!-- Agents append decisions here using log-decision.sh -->
