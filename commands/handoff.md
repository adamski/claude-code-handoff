---
description: Save session context for next session (worktree-aware)
---

# /handoff

Interactive handoff command. Saves session context before ending a session or running `/clear`.

**Worktree-aware**: in a multi-worktree layout, per-worktree state is written into the current worktree's `.claude/`, while a shared "project overview" lives at the outer root. Single-checkout repos behave as before.

## Guiding principle: write for the NEXT context window

Optimize every handoff for what the next session needs to *act*, not for a record of what happened. The next window can recover completed work from git, the code, and commit messages — so spend the budget on what it *cannot* recover:

- **The forward-looking conversation.** When one or more parts of the work just finished, the highest-value content is the discussion about what comes next — decisions made, options weighed, the direction agreed on, and the user's stated intent in their own phrasing. Capture that conversation, not a summary of finished code.
- **Just enough history as a safety net.** A few lines on what was done and why, in case a decision needs revisiting. Keep it terse.
- **Empirical results that are expensive to reproduce** — especially for bugs: exact commands and their actual outputs.

When trimming to fit a size budget, cut historical narrative first; preserve next-step reasoning and un-reproducible results last.

---

## Step 0 — Resolve layout and discover existing state (run this first, every invocation)

Two parts: first work out **where** to write (worktree routing), then read **what** state already exists across the directory tree.

### Step 0a — Resolve worktree layout

Run these commands to classify cwd:

```bash
# Must be inside a git repo
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not in a git repo"; exit 1; }

CURRENT_WORKTREE="$(git rev-parse --show-toplevel)"
PRIMARY_REPO="$(dirname "$(git rev-parse --git-common-dir)")"
[ "$PRIMARY_REPO" = "." ] && PRIMARY_REPO="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)"

# Branch name for the current worktree (or "detached" / SHA if detached)
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"

# Detect outer-root layout: there is an outer root iff at least one OTHER worktree
# shares a common grandparent with the primary repo.
PRIMARY_PARENT="$(dirname "$PRIMARY_REPO")"
OUTER_ROOT=""
while IFS= read -r wt; do
    wt_path="${wt#worktree }"
    [ "$wt_path" = "$PRIMARY_REPO" ] && continue
    wt_grandparent="$(dirname "$(dirname "$wt_path")")"
    if [ "$wt_grandparent" = "$PRIMARY_PARENT" ]; then
        OUTER_ROOT="$PRIMARY_PARENT"
        break
    fi
done < <(git worktree list --porcelain | grep '^worktree ')
```

After this:

- `CURRENT_WORKTREE` — `.claude/` location for **per-worktree** files (`current-task.md`, `current-bug.md`, `bug-test-log.md`, `task-history.md`, `mode`, `session-state.md`, **and** the worktree-local `context.md`).
- `OUTER_ROOT` — if non-empty, also write/update `$OUTER_ROOT/.claude/context.md` (project overview).
- If `OUTER_ROOT` is empty (no multi-worktree layout), skip all outer-root steps; behave as a normal single-checkout handoff with `context.md` in `CURRENT_WORKTREE/.claude/`.

**File routing summary**:

| File | Always per-worktree (`$CURRENT_WORKTREE/.claude/`) | Outer (`$OUTER_ROOT/.claude/`) only when outer exists |
|------|---------------------------------------------------|-------------------------------------------------------|
| `context.md` | ✓ branch-specific resume notes | ✓ project overview (cross-cutting + per-worktree index) |
| `current-task.md` | ✓ | — |
| `current-bug.md` | ✓ | — |
| `bug-test-log.md` | ✓ | — |
| `task-history.md` | ✓ | — |
| `recent-prompts.md` | ✓ | — |
| `mode` | ✓ | — |
| `session-state.md` | ✓ (managed by hooks, not handoff) | — |

Never write `current-task.md`, `current-bug.md`, `bug-test-log.md`, `task-history.md`, or `mode` to the outer root.

### Step 0b — Discover all relevant `.claude/` directories

**This step is non-negotiable.** Claude Code auto-loads `CLAUDE.md` from parent directories at session start, but during a handoff Claude is generating new content from memory and can miss parent-level state. Before writing anything, explicitly enumerate and read every `.claude/` in the tree.

1. **Discover all `.claude/` directories from `$CURRENT_WORKTREE` up to `$HOME`** (inclusive):
   ```bash
   d="$CURRENT_WORKTREE"
   while true; do
     [ -d "$d/.claude" ] && echo "$d/.claude"
     if [ "$d" = "$HOME" ] || [ "$d" = "/" ]; then break; fi
     d="$(dirname "$d")"
   done
   ```
   Run this and capture the list. This naturally includes `$OUTER_ROOT/.claude` when an outer root exists. Cross-project setups (e.g., a parent dir hosting multiple repos with shared instructions) may have more. Stop after checking `$HOME` — do not walk above the user's home directory.

2. **Read every relevant file at every level discovered.** For each `.claude/` directory found:
   - `CLAUDE.md` — instructions (parent levels often hold global preferences; project level holds project-specific rules)
   - `mode` — current mode (normal / task / bug / task.bug)
   - `context.md` — session context
   - `current-task.md` — active task details
   - `current-bug.md` — active bug details
   - `bug-test-log.md` — empirical test history for an active bug
   - `task-history.md` — historical task entries
   - `recent-prompts.md` — recent user prompts
   - `session-state.md` — live session state from proactive-handoff.sh
   - `tasks.md` — pending task list

   Read whatever exists; don't error on missing files. Read in **parallel** when possible (multiple `Read` tool calls in one message).

3. **Build the full picture before writing.** The new handoff content must reflect:
   - The user's intent across this session (from recent-prompts.md and conversation)
   - Active task / bug state (from current-task.md, current-bug.md at every level)
   - Session-state events (file edits, agent dispatches) from session-state.md
   - Any parent-level state that the next session must also check

   If parent-level `.claude/` directories contain task/bug/context state, **note them in the new context.md** with explicit paths so the next session knows to read them. Do not silently overwrite parent-level files unless the user explicitly asked. Cross-project state stays in parent `.claude/`; the handoff coordinates by reference, not by overwriting.

---

## Step 1 — Ask handoff type

Use AskUserQuestion:

**Question:** "What type of handoff?"
**Header:** "Handoff"
**Options:**
1. **Context** (default) — "General context, clears task/bug state. Use when work is complete or switching focus."
2. **Task** — "Multi-session task. Preserves detailed task tracking files."
3. **Bug** — "Bug investigation. Creates bug-specific context (can layer on top of task)."
4. **Clean** — "Reset to clean state. Keeps only project-specific files (CLAUDE.md, settings), clears all session context."

---

## Step 2 — Execute

For every option below, "Write `.claude/context.md` (worktree)" means write to `$CURRENT_WORKTREE/.claude/context.md`. The outer-root `context.md` (when applicable) follows a different template — see "Outer-root context.md" at the end.

---

## Option: Context (Normal)

**Mode transition (worktree-local):**
1. Set `$CURRENT_WORKTREE/.claude/mode` to `normal`
2. Delete: `$CURRENT_WORKTREE/.claude/current-task.md`, `task-history.md`, `current-bug.md`, `bug-test-log.md`

**Write `$CURRENT_WORKTREE/.claude/context.md` (max 50 lines):**

```markdown
# Session Context

**Worktree:** [branch name] — [path relative to outer root]

## Current Work
[What was being worked on - 3-5 lines]

## Recent Changes
[Bullet list of files modified this session]

## Stable Features
[Bullet list of working features to avoid re-implementing]

## Build
\`\`\`bash
[Essential build commands]
\`\`\`

## Key Patterns
[Non-obvious patterns needed to continue work - max 5 lines]

## Next Steps
[What to do next - ordered list]
```

**Then update outer `context.md`** (only if `$OUTER_ROOT` is non-empty) — see "Outer-root context.md" below.

---

## Option: Task

**Mode transition (worktree-local):**
1. Set `$CURRENT_WORKTREE/.claude/mode` to `task`
2. Delete: `$CURRENT_WORKTREE/.claude/current-bug.md`
3. Preserve/create: `$CURRENT_WORKTREE/.claude/current-task.md`, `task-history.md`

**Write `$CURRENT_WORKTREE/.claude/context.md` (max 50 lines):**

```markdown
# Session Context

**Worktree:** [branch name] — [path relative to outer root]

## Mode: Task (a moving process — capture where it's heading, not just where it's been)

**Task:** [One-line description]
**Progress:** [X]% — [Current phase]
**Blocked:** [Yes/No - if yes, what's blocking]

See `.claude/current-task.md` for full details.

## Next Up — Decided Direction & Open Threads
The forward-looking conversation. This is the most valuable part of the handoff — especially if a part just finished. Capture in priority order:
1. **What we decided to do next and why** — the conclusion of the most recent discussion, in the user's framing/phrasing.
2. **Options still open / not yet decided** — anything under debate, with the trade-offs already surfaced so they aren't re-litigated next session.
3. **Immediate next action** — the single concrete thing to start with.

## Current Step
[What's being worked on RIGHT NOW - 2-3 lines]

## Done This Session (fallback context — keep brief)
[2-4 bullets of what changed and why; recoverable from git if needed]

## Key Files This Session
| File | Change |
|------|--------|
| file.c:123 | What changed |

## Build
\`\`\`bash
[Build command]
\`\`\`

## Recent Prompts
See `.claude/recent-prompts.md` for the user's last prompts before handoff.

## If Resuming Cold
[What someone needs to know to pick this up with NO other context - 5 lines max]
```

**Write `$CURRENT_WORKTREE/.claude/current-task.md` (max 100 lines):**

```markdown
# Task: [Title]

**Goal:** [One sentence]
**Acceptance:** [How we know it's done]

## Progress
[X]% complete. Phases: [list with checkmarks]. This is a moving target — rewrite it as it evolves, don't just append.

## Next Session Starts Here
- **Direction:** [What we decided to do next and why — the live plan, from the latest discussion, in the user's framing]
- **First action:** [The single concrete next step]
- **Open questions:** [Anything still undecided, plus the trade-offs already discussed so they aren't re-opened]

## Remaining (live plan — reorder/rewrite as it changes)
1. [Item]

## Architecture Decisions
| Decision | Choice | Why |
|----------|--------|-----|

## Key Code Locations
| File | Line | Description |
|------|------|-------------|

## Done This Session (brief fallback — recoverable from git)
| Item | Key Files |
|------|-----------|

## Test Procedure
1. [Step]
```

**Append to `$CURRENT_WORKTREE/.claude/task-history.md` (2-4 lines):**

```markdown
Session N (YYYY-MM-DD): [What was accomplished]. Key: [most important file:line or decision].
```

**Then update outer `context.md`** (when applicable).

---

## Option: Bug

**Mode transition (worktree-local):**
1. Read current mode from `$CURRENT_WORKTREE/.claude/mode`
2. If current mode is `task`: set mode to `task.bug` (PRESERVE task files)
3. Otherwise: set mode to `bug` (delete task files in this worktree)
4. Create/update `$CURRENT_WORKTREE/.claude/current-bug.md` (current state) and append to `$CURRENT_WORKTREE/.claude/bug-test-log.md` (empirical history — never overwrite it)

**Write `$CURRENT_WORKTREE/.claude/context.md`:**

If standalone bug:
```markdown
# Session Context

**Worktree:** [branch name] — [path relative to outer root]

## Mode: Bug

**Bug:** [One-line description]
**Symptom:** [What user sees]
**Status:** [Investigating / Root cause found / Fix in progress]

See `.claude/current-bug.md` for investigation details.

## Reproduce
1. [Step]

## Current Hypothesis
[What you think is wrong - 2 lines]

## Recent Prompts
See `.claude/recent-prompts.md` for the user's last prompts before handoff.

## Build
\`\`\`bash
[Build command]
\`\`\`
```

If bug within task (`task.bug`):
```markdown
# Session Context

**Worktree:** [branch name] — [path relative to outer root]

## Mode: Task (blocked on bug)

**Task:** [Task name] — [X]% complete
**Blocker:** [Bug description]

### Bug Status
**Symptom:** [What's failing]
**Hypothesis:** [Current theory]

See `.claude/current-bug.md` for bug details.
See `.claude/current-task.md` for task details.

## Reproduce
1. [Step]

## Recent Prompts
See `.claude/recent-prompts.md` for the user's last prompts before handoff.

## Build
\`\`\`bash
[Build command]
\`\`\`
```

**Write `$CURRENT_WORKTREE/.claude/current-bug.md` (current state — keep lean, the long history lives in the test log):**

```markdown
# Bug: [Title]

## Symptom
[What user sees - 2 lines max]

## Reproduce
\`\`\`bash
[exact command(s) to reproduce — copy-pasteable]
\`\`\`

## Status
[Investigating / Root cause found / Fix in progress]

## Current Hypothesis
[Current theory - 2 lines]

## Confirmed Facts (established — do not re-investigate)
- [Fact] — established by [Tn] in bug-test-log.md

## Ruled Out (dead ends — do not retry)
- [Approach / hypothesis] — ruled out by [Tn], because [result]

## Key Locations
| File:Line | What |
|-----------|------|

## Next Step
[Single concrete action to take next]

## Test Log
Full command-by-command history in `.claude/bug-test-log.md`. Read it before running anything — it records what has already been tried and what it showed.
```

**Write/append `$CURRENT_WORKTREE/.claude/bug-test-log.md` (append-only — the empirical ledger):**

Purpose: so the next session never re-runs a settled test, and so there is a durable record of what went right and what went wrong. Record every meaningful test, command, build, or measurement run during the investigation.

```markdown
# Bug Test Log — [Title]

Append-only. Each entry is one test/experiment. Never delete or rewrite past entries — correct a wrong conclusion with a *later* entry that references the earlier one.

## Test History

### T1 — [what this test was checking] — [PASS / FAIL / INCONCLUSIVE]
- **Command:** \`exact command line, with flags and args\`
- **Result:** [actual output — the key lines, error text, exit code, or measured value]
- **Conclusion:** [what it established or eliminated]

### T2 — [...]
- **Command:** \`...\`
- **Result:** [...]
- **Conclusion:** [...]
```

**Test-log rules:**
- Record the **exact** command line — copy-pasteable, not paraphrased.
- Record the **actual** result (verbatim key lines / exit code / measured value), never just "it worked" or "failed".
- Tag every entry PASS / FAIL / INCONCLUSIVE so dead ends are obvious at a glance.
- When a test settles a question, also promote it to **Confirmed Facts** or **Ruled Out** in `current-bug.md`.
- Append across sessions — this log is the cumulative history of the whole investigation, not just this session.

**Then update outer `context.md`** (when applicable).

---

## Option: Clean

Reset to a clean state between unrelated work sessions.

**Per-worktree (always):**
- Delete `$CURRENT_WORKTREE/.claude/{context,current-task,task-history,current-bug,bug-test-log,recent-prompts,session-state}.md`
- Set `$CURRENT_WORKTREE/.claude/mode` to `normal`
- Clean `$CURRENT_WORKTREE/.claude/tasks.md` — remove completed entries (lines with `~~strikethrough~~` or `✓ Done`); keep pending tasks and backlog; delete file if empty.

**Outer (when `$OUTER_ROOT` is non-empty):**
- In `$OUTER_ROOT/.claude/context.md`, REMOVE only this worktree's section under `## Active Worktrees` (leave the rest of the file alone). If the section is the only one, leave the heading + an empty body — do NOT delete the outer file.

**Keep (don't touch):**
- `CLAUDE.md` (any level)
- `settings.json`, `settings.local.json`
- `.claude/docs/*`, `commands/*`, `skills/*`, `hooks/*`, `rules/*`

**Report:** what was deleted, what remains, mode.

---

## Outer-root context.md (project overview)

Only applicable when `$OUTER_ROOT` is non-empty. The outer file is **shared across worktrees** — handoffs must merge, not overwrite.

**Path:** `$OUTER_ROOT/.claude/context.md`

**Template** (full file, used only when creating fresh):

```markdown
# Project Overview

## Build & Setup
[Cross-cutting build commands, paths, env requirements that apply everywhere]

## Cross-Cutting Decisions
[Architectural anchors that span branches — protocols, conventions, SDK versions]

## Active Worktrees

<!-- One section per worktree. Handoff edits ONLY the section matching $CURRENT_BRANCH. -->

### <branch-name>

**Path:** `<path relative to outer root>`
**Focus:** [1 line]
**Status:** [In progress | Blocked on X | Awaiting review | Idle since YYYY-MM-DD]
[1–2 short paragraphs of higher-level context — what this branch is for, where it is, what's next at the project level. Detailed step-by-step state lives in the worktree's own context.md.]
```

**Update algorithm (every Context / Task / Bug handoff when outer exists):**

1. If `$OUTER_ROOT/.claude/context.md` doesn't exist, create it from the template above with no worktree sections yet.
2. Read it.
3. Look for a `### <CURRENT_BRANCH>` heading under `## Active Worktrees`.
4. If found: replace that section's body (everything until the next `### ` or `## ` heading or EOF) with a fresh summary from this session.
5. If not found: append a new `### <CURRENT_BRANCH>` section at the end of `## Active Worktrees`.
6. Do **not** edit `## Build & Setup` or `## Cross-Cutting Decisions` unless the user explicitly asked to update them — they're stable across handoffs.
7. Do **not** delete or modify other branches' sections.

**What goes in the outer per-worktree section** (≤ 8 lines, higher-level only):
- One-line focus
- Status (in-progress / blocked / idle)
- Why this branch exists (purpose, not step-by-step state)
- Pointer to the worktree's own `.claude/context.md` for detail

**What does NOT go in the outer section:**
- File:line references (those live in the worktree's `context.md`)
- Recent file changes
- Step-by-step task state

---

## User Prompt Capture (Task and Bug modes only)

When performing a **Task** or **Bug** handoff, save the last 5 user prompts to `$CURRENT_WORKTREE/.claude/recent-prompts.md`.

**Size gate:** Estimate the total size of the 5 prompts. If they exceed ~5% of the context window (~10K tokens / ~40KB of text), keep only the most recent prompts that fit within that budget. If even a single prompt exceeds the budget, truncate it to fit and note `[truncated]`.

**Write `.claude/recent-prompts.md`:**

```markdown
# Recent User Prompts

Captured at handoff for session continuity. Provides the next session with the user's recent intent and phrasing.

## Prompt 1 (most recent)
> [verbatim user prompt text]

## Prompt 2
> [verbatim user prompt text]

...
```

**Rules:**
- Include only user messages (not assistant responses, tool results, or system messages)
- Preserve the user's exact wording — do not paraphrase or summarize
- Use blockquote formatting for each prompt
- Number from most recent (1) to oldest (5)
- If fewer than 5 user prompts exist in the session, include all of them

**Clean mode:** Delete `.claude/recent-prompts.md` along with other session files.

---

## Cleanup rules (apply to all handoff types except Clean)

1. **Filter `/tmp/*` paths** — don't include temp paths in "Recent Changes" or "Key Files".
2. **Dedupe tasks** — merge duplicate entries in `tasks.md`.
3. **Compress history** — if `task-history.md` exceeds 30 entries, compress old ones.
4. **Remove stale references** — don't reference files that no longer exist.
5. **Preserve the bug test log** — `.claude/bug-test-log.md` is append-only and exempt from trimming; never drop a test entry to save space. Only if it grows very large, collapse entries already promoted to "Confirmed Facts" / "Ruled Out" into a one-line reference — but keep their exact command and result.
6. **Outer file is shared** — never overwrite the outer `context.md` wholesale; always merge by section.
