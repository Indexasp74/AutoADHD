---
name: vault-extractor
description: "Full extraction rulebook for processing Inbox notes into Canon entries. MUST be used when: processing a voice memo transcript, extracting knowledge from an inbox note, running extraction on a new note, doing a manual extraction pass, or any task that involves reading an Inbox/ note and creating/updating Canon entries from it. Also use when the user says 'extract this', 'process this memo', 'what's in this transcript', or anything about pulling structured knowledge from unstructured text in the vault."
---

# Vault Extractor

You're processing an Inbox note and extracting ALL knowledge into structured Canon entries. This is the most important job in the vault — it's where raw human moments become connected, searchable knowledge.

Read the vault-writer skill too if you need note format details. This skill focuses on the extraction *process*.

---

## Before You Start

1. Read `CLAUDE.md` at vault root (if not already loaded)
2. Read the vault-writer skill for note formats (frontmatter, emoji headings, provenance)
3. Have the target Inbox note open and read every sentence of the `# Raw` section

---

## The Extraction Checklist

For every Inbox note, extract ALL of these:

### 1. People
Anyone mentioned by name. Before creating a new person:
- Search `Canon/People/` for the name
- Check ALL `aliases` arrays in existing people entries
- If found → update the existing entry (add new info, add to changelog)
- If new → create in `Canon/People/` following People Schema (`Meta/README/People Schema.md`)

### 2. Events
Anything that happened — meetings, conversations, trips, milestones. Include dates, participants, locations.
- Check `Canon/Events/` for same date + location or same subject
- If match → enrich existing entry
- If new → create in `Canon/Events/`

### 3. Actions (Tasks)
Scan for task-like language:
- "I need to...", "we should...", "I want to...", "let's..."
- "don't forget...", "reminder:...", "todo:..."
- "I have to...", "we must...", "plan to..."
- If the speaker switches languages mid-recording, scan for the equivalent task phrasing in that language too

For each action:
- Check `Canon/Actions/` for existing match
- If exists → add new mention to `mentions` array
- If new → create in `Canon/Actions/`

**"Test" framing does not cancel extraction.** If the raw transcript asks the system to send, research, create, queue, or stage something, capture the concrete requested actions — even when the memo is framed as a test, a dry run, or "just checking."

**`owner` is never `[[You]]`.** Default every action's `owner` to `"[[Richard Lee]]"` unless the transcript names a different responsible person. `owner: "[[You]]"` is ALWAYS invalid — `[[You]]` resolves to no Canon note.

**Action field rules (enforce every time):**
- `mentions`: MUST be array of actual filenames (e.g. `2026-03-16 - Voice - mercado.md`). NEVER write `"multiple memos"` or placeholders.
- `first_mentioned`: actual earliest date from the memos being processed
- `owner`: default `"[[Richard Lee]]"` unless someone else is explicitly stated
- `due`: approximate dates over blank ("by summer" → `2026-09-01`, "end of April" → `2026-04-30`)
- `output`: one-sentence "done looks like" inferred from context

### 3b. Enrichment Commands (CRITICAL — don't treat as passive actions)

The human often says things like "look up address for Lisa", "add her email", "find website for Rose von Sharon", "get phone number for Carlos". These are NOT actions to put on a todo list — they are **commands to the system**. The human expects an agent to DO the lookup, not remind them to do it manually.

**Detection patterns:**
- "look up...", "find...", "add [field] for...", "get [field] for..."
- "what's the address of...", "search for...", "enrich..."
- If spoken in another language, the same command phrasings in that language
- Implicit: "I need her phone number" (= look it up and add it)

**What to do when you detect one:**

1. Create or update the Canon entry with what you DO know
2. On the fields that need lookup, write a placeholder:
   ```yaml
   website: "ENRICH: look up official website"
   phone: "ENRICH: find public phone number"
   address: "ENRICH: look up business address"
   ```
3. Set `enrichment_status: needs-enrichment` in the note's frontmatter
4. Add an inline comment explaining the command:
   ```markdown
   <!-- enrichment-command: "look up address for Rose von Sharon", from: 2026-03-27 - Voice - tg2026-03-27194301.md, agent: Extractor, 2026-03-31T14:30 -->
   ```

The Task-Enricher scans for `enrichment_status: needs-enrichment` and `ENRICH:` placeholders, then does the actual lookup (web search, contacts, etc.) and fills in the real values.

**The key insight:** "Add address for XYZ" means the SYSTEM should find it, not the human. The human is delegating, not requesting a reminder.

### 4. Concepts
Ideas, frameworks, observations, philosophies mentioned.
- New concepts go to `Thinking/` (not `Canon/Concepts/` — that's legacy)
- Check for duplicates first

### 5. Decisions
Choices made or being considered. Include what was decided, why, what was traded off.
- Create in `Canon/Decisions/`

### 6. Places
Locations mentioned with context (cities, buildings, neighborhoods, addresses).
- Check for partial name matches (e.g. "Konservatorium" matches "HHKon Hamburger Konservatorium")
- Create in `Canon/Places/` or update existing

### 7. Organizations
Companies, institutions, teams, shops, programs, communities mentioned with enough context to matter.
- Check `Canon/Organizations/` for the name and aliases
- Create in `Canon/Organizations/` or update existing

### 8. Projects
Ongoing personal or work initiatives with their own arc (a repo, a build, a multi-step effort).
- Check `Canon/Projects/` for the name and aliases
- Create in `Canon/Projects/` or update existing — include a `## Evolution` section like other living types

### 9. Reflections (special handling — see below)

---

## Secondary Entity Pass (MANDATORY)

After completing primary extraction (the dominant theme — actions, events, reflections, thinking notes), do a SECOND pass over the transcript specifically for:
- **People mentioned in passing** — picking someone up, working with someone, meeting someone. If they exist in `Canon/People/`, update their note with the new context. If they don't exist and are named, create a stub.
- **Places mentioned as context** — neighborhoods, streets, buildings, shops, transit points. If mentioned with enough context to matter (not just "on the way"), create or update `Canon/Places/`.
- **Organizations mentioned alongside the main topic** — employers, shops, institutions, unions. Create or update `Canon/Organizations/`.

The primary pass tends to tunnel-vision on the dominant theme. This second pass catches the contextual entities that make the vault navigable from multiple angles. Without it, a memo about product strategy that also mentions picking up Mila at Spritzenplatz loses the family and location context entirely.

Named relationship context still counts: "Emil is Melisa's brother" means BOTH Emil and Melisa get extracted. Family logistics and scene-setting are not "just background" when they include named entities.

Evidence: 2026-04-18 Retro found 3.3/5 extraction quality, with the gap almost entirely in secondary entities.

---

## Whisper Transcription Artifact Matching

Voice memos are transcribed by Whisper, which frequently garbles non-English names into phonetically similar but wrong spellings. Before treating a name as "new," check for Whisper artifacts:
- **Dropped/swapped syllables**: "Nae Yano" = Nael-Jano, "Noatara" = Noa-Tara
- **Vowel/consonant drift**: "Alba" = Alber, "Vakas" = Waqas
- **Partial matches**: if the transcript name matches the first 4+ characters of an existing alias or filename, check the Canon entry before creating a new one

When you suspect a Whisper artifact:
1. Check `Canon/People/` for phonetically similar names (not just exact string match)
2. Check aliases arrays for partial matches
3. If context confirms identity (e.g. "Vakas Malik, der Vater von Nae Yano" matches Waqas Malik as father of Nael-Jano Malik), use the existing entry
4. Add the Whisper-garbled spelling to the `aliases` array so future passes match automatically

Evidence: 2026-04-19 Retro found 4 missed people matches in the Japan memo due to Whisper artifacts.

---

## Reflection Detection

Some notes are brain dumps — personal reflections, journal entries, processing moments. Detect by:
- Extended first-person monologue without clear action items
- Emotional processing ("I've been thinking about...", "what bothers me is...")
- Stream of consciousness touching multiple topics
- Mood language (frustration, excitement, confusion, calm)
- Passages where the speaker switches into another language mid-recording (often to process feelings)

**When you detect a reflection, do BOTH:**

### A. Keep the whole thing
Create a note in `Thinking/` with `type: reflection`. Clean up grammar and structure. Preserve voice. Add wikilinks. Tag mood and context. Do NOT disassemble.

### B. Extract entities as usual
Still pull out people, events, actions, concepts into their proper Canon homes. The reflection is the original painting; Canon entries are prints in different rooms.

**Notes that aren't reflections:** regular memos about specific things (people, events, tasks) get extracted normally into Canon. Only brain dumps and journal-style entries go to `Thinking/` as `type: reflection`.

---

## Thinking/ Notes (Non-Reflections)

Some ideas don't fit a Canon box yet. If you extract something that's clearly a concept, belief, or emerging idea but you're unsure of the type, put it in `Thinking/` with `type: emerging`:

```yaml
---
type: emerging
name: [name]
created: [date]
source: ai-extracted
linked: []
changelog:
  - YYYY-MM-DD: created from [source]
---
```

If a reflection/thinking filename includes a journal/date prefix (`Journal - YYYY-MM-DD - Title.md`), add an alias for the plain title or use `[[Actual Filename|Title]]` everywhere so the link never breaks.

---

## Affect Signals

Tag emotional tone when clearly present:
- Laughter, excitement → `affect: joy` or `affect: excitement`
- Frustration, repeated returns to a topic → `affect: frustration`
- Vulnerability, softness → `affect: reflection`
- Urgency, speed → `affect: anxiety`

Add as frontmatter on the inbox note. Only when obvious.

---

## Duplicate Detection (critical)

Before creating ANY new entry:
1. Search target folder for the plain-language name
2. Check ALL `aliases` arrays in existing entries
3. For Places: search partial name matches
4. For Events: check same date + location, or same subject matter
5. If match found → update existing, add new name variant to `aliases` if not there
6. NEVER create a duplicate

---

## Linking Rules

After extraction, ensure these links exist:
- Every Person → related Events, Decisions, Actions
- Every Event → People involved, Concepts discussed
- Every Action → Person responsible, related Decisions/Concepts
- Every Concept → People who discussed it, Events where it arose
- Use `[[wikilink]]` syntax. For aliases: `[[Jeremia Riedel|Jerry]]`

---

## Writing Back to the Inbox Note (MANDATORY)

After extraction, you MUST do TWO things to the inbox note:

### 1. Set frontmatter status + provenance
```yaml
status: extracted
source_agent: Extractor
source_date: [ISO timestamp]
```
Stamp `source_agent` / `source_date` on the inbox note itself too — including no-op test notes and garbled-audio notes.

### 2. Write the `## Extracted` section (exactly nine lines, in this order)
```markdown
## Extracted

- People: [[Name A]], [[Name B]] | none
- Events: [[Event Name]] | none
- Concepts: [[Concept Name]] | none
- Actions: [[Action Name]] | none
- Decisions: [[Decision Name]] | none
- Places: [[Place Name]] | none
- Organizations: [[Organization Name]] | none
- Projects: [[Project Name]] | none
- Thinking: [[Reflection or Emerging Note]] | none
```

**Both are required.** A note without the `## Extracted` section is NOT complete regardless of frontmatter status. This was violated in 10+ consecutive Reviewer passes — it is non-negotiable. If the note yields only one entity, still write all nine lines.

Rules for the block:
- Keep the schema stable and in the order above so Reviewer and automation can parse it. Use the literal word `none` (never a blank line) for empty categories.
- **It is a changed-note ledger, not a mention roll-up.** List ONLY notes created or materially updated in THIS pass. If `[[Prachi Kumar]]` is referenced inside a new action but `Canon/People/Prachi Kumar.md` itself was untouched, leave Prachi off `People:` and list only the action note that changed.
- Before listing an existing note, verify same-pass evidence on that note itself (a fresh inline provenance comment, a new mention/evolution/changelog entry, or frontmatter updated this pass). Links inside another new note do not count.
- Use the note's actual type line, never ad-hoc labels like `Updated:` or `Related:`. Never collapse into shorthand like `(Test note — no canonical content)` or `(Garbled audio)`; even those use the full nine-line schema with `none`.
- Every wikilink must resolve to a real note (use `[[Filename|Title]]` for prefixed `Thinking/` filenames).

### Self-check before saving `status: extracted`
1. Inbox note has `source_agent: Extractor` + `source_date` (even no-op/garbled notes).
2. Every new note has `source: ai-extracted`, `source_agent: Extractor`, `source_date`.
3. Every materially updated existing note has a fresh inline provenance comment with `agent: Extractor`, the timestamp, AND `from: [filename]` — the `from:` field is REQUIRED.
4. Every changed note carrying `updated:`/`status:` still has those fields aligned with the new content (`updated:` = the day you edited, not the memo date).
5. The `## Extracted` block has all nine labels in order; each line has wikilinks or `none`.
6. Listed notes are only those actually created/updated this pass, each defensible with same-pass evidence.
7. Every action `owner` is `"[[Richard Lee]]"` (or a named person) — never `[[You]]`.
8. If any item is false, extraction is NOT complete — fix it before leaving the note `status: extracted`.

---

## Review Queue (uncertain facts)

When you're not confident about something — dates, ages, spellings, relationships, garbled transcript bits:

```bash
./Meta/scripts/queue-review.sh "Canon/People/[[Name]].md" "field" "value" "reason"
```

Flag: birth dates, ages, relationship labels, ambiguous names, numbers, garbled audio.
Don't flag: obvious things, well-known facts, clearly stated info.

---

## Language

- Canon notes: English (always)
- Raw transcripts: stay in original language
- Extracted content: normalized to English
- Non-English emotional passages in reflections: translate but note the original tone

---

## Provenance

Every new entry gets full agent attribution in frontmatter:
```yaml
source: ai-extracted
source_agent: Extractor
source_date: 2026-03-31T14:30   # use current timestamp
```

Every update to an existing entry gets an inline comment with agent + timestamp:
```markdown
<!-- source: ai-extracted, agent: Extractor, 2026-03-31T14:30, from: 2026-03-16 - Voice - mercado.md -->
```

**Sign your work.** Generic "ai-generated" is not enough. The human needs to know WHO changed what and WHEN. This applies to every agent: Extractor, Task-Enricher, Researcher, Implementer, etc.

The chain matters: voice memo → inbox note (raw) → Canon entry (extracted by Extractor at timestamp) → enrichment (by Task-Enricher at timestamp) → research (by Researcher at timestamp). Every fact should be traceable to a human moment AND to the specific agent action.

---

## Output

After a complete extraction:
1. All new/updated Canon entries committed to git
2. Inbox note has `status: extracted` + `## Extracted` section
3. All wikilinks verified (targets exist or stubs created)
4. Provenance markers on everything
5. Emoji headings on all notes
6. Git commit with descriptive message listing what was extracted

---

## Common Extraction Mistakes

- Forgetting the `## Extracted` section on the inbox note (the #1 recurring violation)
- Creating duplicate people without checking aliases
- Writing `mentions: "multiple memos"` instead of actual filenames
- Not translating non-English content to English in Canon entries
- Disassembling reflections into atoms instead of keeping them whole
- Missing task-like language when the speaker switches into another language
- Not linking Actions back to the Person responsible
- Forgetting emoji in H1 headings
