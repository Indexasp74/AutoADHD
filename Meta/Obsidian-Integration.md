---
type: meta
name: Obsidian Integration
created: 2026-06-20
updated: 2026-06-20
---

# 🔗 Obsidian Integration

How the AutoADHD engine and a human Obsidian vault knit together — current
state, configuration, and the roadmap. Written for a single-user WSL setup
but with a public release in mind: **every path and toggle is config-driven,
not hardcoded.**

## Architecture

```
   WSL (~/AutoADHD)                         Obsidian vault (Google Drive, etc.)
   ─────────────────                         ───────────────────────────────────
   engine: Meta/scripts, .git, .venv         your real notes (Career, Family, …)
   source of truth: Canon, Thinking,   ──▶   <OBSIDIAN_SUBDIR>/  (published copy)
     Articles, Inbox, HOME.md                  Canon/ Thinking/ Articles/ HOME.md
   agents read/write here (fast)             <OBSIDIAN_INBOX>/  (briefings land)
                                       ◀──   capture/ (typed notes → ingest)  [future]
```

**The WSL vault is the source of truth.** Agents run there (fast, git-tracked).
The Obsidian vault is a **read view + capture surface**. We publish a one-way
copy into a *dedicated subfolder* so the engine's churn, `.git`, `.venv`, audio,
and logs never reach Google Drive, and your existing notes are never touched.

## Configuration (`.env`)

| Var | Purpose | Default |
|-----|---------|---------|
| `OBSIDIAN_VAULT` | Your Obsidian vault root | — (required to publish) |
| `OBSIDIAN_SUBDIR` | Dedicated subfolder published into | `AutoADHD` |
| `OBSIDIAN_INBOX` | Where the daily briefing is written | `$VAULT_DIR/Inbox` |
| `OBSIDIAN_PUBLISH` | Enable/disable the publish mirror | `1` |

## Surface map

### Outbound — AutoADHD → Obsidian (read in Obsidian)

| # | Surface | Status | Mechanism |
|---|---------|--------|-----------|
| 1 | Daily briefing → Inbox | ✅ done | `daily-briefing.sh` writes to `$OBSIDIAN_INBOX` |
| 2 | Canon (people/actions/events/decisions/projects/places/orgs) | ✅ done | `publish-to-obsidian.sh` → `<SUBDIR>/Canon` |
| 3 | Thinking (reflections, beliefs, concepts) | ✅ done | publish |
| 4 | Research articles (`Thinking/Research`) | ✅ done | publish |
| 5 | Articles (long-form) | ✅ done | publish |
| 6 | Weekly Mirror / Thinker reflections (`Meta/AI-Reflections`) | ✅ done | publish (telemetry `*-log.md` excluded) |
| 7 | HOME dashboard (Dataview) | ✅ done | publish + Dataview `FROM` paths rewritten to `<SUBDIR>/…` so they resolve in the subfolder |
| 8 | Dashboard data (`Meta/operations`, `review-queue`, `sprint`) | ✅ done | publish, so HOME's "Needs You" / "Sprint" sections render live |
| 9 | Voice transcripts (`Inbox/Voice/*.md`) | ✅ done | publish (audio/working dirs excluded) |

Publish runs every 15 min via cron (`publish-to-obsidian.sh`), is a no-op when
nothing changed (content-checksum diff), and is **scoped to `<SUBDIR>` with a
hard guard against ever `--delete`-ing the vault root.**

### Inbound — Obsidian → AutoADHD (capture / act in Obsidian)

| # | Surface | Status | Plan |
|---|---------|--------|------|
| 10 | Quick text capture in Obsidian → extraction | 🚧 planned | watch an `OBSIDIAN_CAPTURE_DIR`; new notes get moved into `Inbox/` and run through the Extractor (same pipeline as voice) |
| 11 | Edit/correct Canon notes in Obsidian → back to WSL | 🚧 planned | the publish is **one-way**: edits in `<SUBDIR>/` are overwritten on next publish. Options: (a) edit in the WSL vault (`\\wsl$\…\AutoADHD`); (b) a future "pull-back" sync that treats specific human edits as authoritative |
| 12 | Approve operations (🔴 Needs You) from Obsidian | 🚧 planned | today approvals go via Telegram; could watch a field/checkbox in the published `operations/pending` notes |

### Known caveat — one-way publish

The published `<SUBDIR>/` is a **read view**. If you edit a note *there*, the
next publish overwrites it. Until inbound edit-sync (#11) exists: make edits in
the WSL vault (open `\\wsl$\Ubuntu\home\<user>\AutoADHD` as an Obsidian vault),
or capture corrections as new voice/text notes and let the agents reconcile.

## Public-release TODO (configurability)

- **Platform abstraction.** `publish-to-obsidian.sh` uses DrvFs-safe rsync flags
  (`--no-perms/owner/group`, `--checksum`, `--inplace`) because the Google Drive
  mount rejects chmod/chgrp/mtime. A release needs to detect platform (native
  macOS/Linux can use plain `rsync -a`).
- **Integration mode toggle.** Today: "publish (one-way mirror)". Offer modes:
  `outputs-only` (briefing only), `publish` (current), `native` (open the WSL
  vault directly, no copy).
- **Per-output toggles + interval** as config, not the hardcoded subtree list.
- **Setup wizard** to discover the vault path and write `.env`.
- **Inbound capture + edit-sync** (#10–12) as opt-in modules.
