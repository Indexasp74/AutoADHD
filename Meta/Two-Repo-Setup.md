---
type: meta
name: Two-Repo Setup
created: 2026-06-20
updated: 2026-06-20
---

# 🔀 Two-Repo Split (public system + private vault)

Keep the **system** in a public repo (shareable) and your **vault content** in a
separate **private** repo — both living in the same working tree, so the agents
keep operating exactly as before. Opt-in and config-driven; unset to fall back to
single-repo mode.

## How it works

Two git repos share one working directory (`$VAULT_DIR`), tracking disjoint file
sets (the "bare repo + shared work-tree" pattern):

| | Engine repo (public) | Vault repo (private) |
|---|---|---|
| Git dir | `$VAULT_DIR/.git` | `$VAULT_GIT_DIR` (bare, e.g. `~/.autoadhd/vault.git`) |
| Tracks | scripts, agent specs, docs, `Canon/README.md` | Canon, Inbox, Thinking, Articles, Meta runtime (AI-Reflections, sprint, operations, review-queue, changelog, MANIFEST) |
| Ignores the other via | `.git/info/exclude` (local) | `$VAULT_GIT_DIR/info/exclude` (local) |
| Remote | public GitHub | **private** GitHub |
| Committed by | you (review engine changes before they go public) | the agents, auto-pushed |

**Why `info/exclude`, not `.gitignore`:** a committed `.gitignore` is read by
*both* repos (shared work-tree), so it can't ignore content for one repo and not
the other. Each repo ignores the *other's* files via its own local
`info/exclude`; the committed `.gitignore` stays neutral on content.

## The routing

`agent_git` (in `lib-agent.sh`) is the single chokepoint. With `VAULT_GIT_DIR`
set, it targets the vault repo, so all `agent_stage_and_commit` calls land
content in the **private** repo. Engine self-heals (Implementer editing scripts)
are ignored by the vault repo → they stay **uncommitted in the public repo** for
your review before you push them.

`push-vault.sh` (cron, every 10 min) pushes the private vault repo to its remote.

## Setup (what was done here)

```bash
# 1. private remote
gh repo create <you>/AutoADHD-vault --private

# 2. bare vault repo, work-tree = your AutoADHD dir
git init --bare ~/.autoadhd/vault.git
#    + write ~/.autoadhd/vault.git/info/exclude to ignore engine files

# 3. engine repo ignores content locally (NOT in the shared .gitignore)
#    append content paths to $VAULT_DIR/.git/info/exclude

# 4. seed + push the vault repo
VG=~/.autoadhd/vault.git
git --git-dir=$VG --work-tree=~/AutoADHD add -A
git --git-dir=$VG --work-tree=~/AutoADHD commit -m "Initial vault content"
git --git-dir=$VG --work-tree=~/AutoADHD remote add origin <private-url>
git --git-dir=$VG --work-tree=~/AutoADHD push -u origin main

# 5. enable the split
echo 'VAULT_GIT_DIR="$HOME/.autoadhd/vault.git"' >> .env
```

## Day-to-day

- **Vault content** (your notes) → auto-committed to the private repo, auto-pushed.
- **Engine changes** (scripts/docs, incl. Implementer self-heals) → show up as
  uncommitted in the public repo; you review, commit, and push them when ready.
- **To revert to single-repo:** unset `VAULT_GIT_DIR`; agents commit everything
  to the one repo again.

## Caveats

- The Implementer *inspects* via plain `git` (engine repo) but commits via
  `agent_git` (vault repo); its "files changed" count reflects engine changes —
  cosmetic only.
- Cloning the public repo alone gives you the system; you create your own vault
  repo (or run single-repo) for content.
