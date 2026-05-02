---
description: Save session context for next session (worktree-aware)
user_invocable: true
---

# /handoff

Interactive handoff command. Saves session context before ending a session or running `/clear`.

**Worktree-aware**: in a multi-worktree layout, per-worktree state is written into the current worktree's `.claude/`, while a shared "project overview" lives at the outer root. Single-checkout repos behave as before.

---

## Step 0 — Resolve worktree layout (run this first, every invocation)

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

- `CURRENT_WORKTREE` — `.claude/` location for **per-worktree** files (`current-task.md`, `current-bug.md`, `task-history.md`, `mode`, `session-state.md`, **and** the worktree-local `context.md`).
- `OUTER_ROOT` — if non-empty, also write/update `$OUTER_ROOT/.claude/context.md` (project overview).
- If `OUTER_ROOT` is empty (no multi-worktree layout), skip all outer-root steps; behave as a normal single-checkout handoff with `context.md` in `CURRENT_WORKTREE/.claude/`.

**File routing summary**:

| File | Always per-worktree (`$CURRENT_WORKTREE/.claude/`) | Outer (`$OUTER_ROOT/.claude/`) only when outer exists |
|------|---------------------------------------------------|-------------------------------------------------------|
| `context.md` | ✓ branch-specific resume notes | ✓ project overview (cross-cutting + per-worktree index) |
| `current-task.md` | ✓ | — |
| `current-bug.md` | ✓ | — |
| `task-history.md` | ✓ | — |
| `mode` | ✓ | — |
| `session-state.md` | ✓ (managed by hooks, not handoff) | — |

Never write `current-task.md`, `current-bug.md`, `task-history.md`, or `mode` to the outer root.

---

## Step 1 — Ask handoff type

Use AskUserQuestion:

**Question:** "What type of handoff?"
**Header:** "Handoff"
**Options:**
1. **Context** (default) — "General context, clears task/bug state. Use when work is complete or switching focus."
2. **Task** — "Multi-session task. Preserves detailed task tracking files."
3. **Bug** — "Bug investigation. Creates bug-specific context (can layer on top of task)."
4. **Recovery** — "Re-generate handoff from full transcript. Use after autocompact degraded context."

**Clean** is also available via "Other"; see the Clean section below.

---

## Step 2 — Execute

For every option below, "Write `.claude/context.md` (worktree)" means write to `$CURRENT_WORKTREE/.claude/context.md`. The outer-root `context.md` (when applicable) follows a different template — see "Outer-root context.md" at the end.

---

## Option: Context (Normal)

**Mode transition (worktree-local):**
1. Set `$CURRENT_WORKTREE/.claude/mode` to `normal`
2. Delete: `$CURRENT_WORKTREE/.claude/current-task.md`, `task-history.md`, `current-bug.md`

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

## Mode: Task

**Task:** [One-line description]
**Progress:** [X]% — [Current phase]
**Blocked:** [Yes/No - if yes, what's blocking]

See `.claude/current-task.md` for full details.

## Current Step
[What's being worked on RIGHT NOW - 2-3 lines]

## Key Files This Session
| File | Change |
|------|--------|
| file.c:123 | What changed |

## Build
\`\`\`bash
[Build command]
\`\`\`

## If Resuming Cold
[What someone needs to know to pick this up with NO other context - 5 lines max]
```

**Write `$CURRENT_WORKTREE/.claude/current-task.md` (max 100 lines):**

```markdown
# Task: [Title]

**Goal:** [One sentence]
**Acceptance:** [How we know it's done]

## Progress
[X]% complete. Phases: [list with checkmarks]

## Architecture Decisions
| Decision | Choice | Why |
|----------|--------|-----|

## Completed This Session
| Item | Key Files |
|------|-----------|

## Remaining
1. [Item]

## Key Code Locations
| File | Line | Description |
|------|------|-------------|

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
4. Create/update `$CURRENT_WORKTREE/.claude/current-bug.md`

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

## Build
\`\`\`bash
[Build command]
\`\`\`
```

**Write `$CURRENT_WORKTREE/.claude/current-bug.md` (max 40 lines):**

```markdown
# Bug: [Title]

## Symptom
[What user sees - 2 lines max]

## Reproduce
1. [Step]

## Root Cause
[If known - 3 lines max. If unknown, write "Investigating"]

## Investigation
| What I tried | Result |
|--------------|--------|

## Hypothesis
[Current theory - 2 lines]

## Key Locations
| File:Line | What |
|-----------|------|

## Next Step
[Single action to take next]
```

**Then update outer `context.md`** (when applicable).

---

## Option: Recovery

Re-generate handoff files from the conversation transcript after autocompact.

### Step R1: Locate and extract transcript

```bash
PROJECT_DIR="$HOME/.claude/projects/$(pwd | sed 's|/|-|g; s|^-||')"
TRANSCRIPT=$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -1)
```

If a project-specific extract script exists at `$PRIMARY_REPO/claude-code-handoff/extract-transcript.py`, run it:

```bash
python3 "$PRIMARY_REPO/claude-code-handoff/extract-transcript.py" "$TRANSCRIPT"
```

Otherwise read the `.jsonl` directly.

### Step R2: Read the extracted output (no subagent — using context space is the point).

### Step R3: Ask target handoff type (Task default, also Context or Bug).

### Step R4: Generate handoff files following the appropriate template above (worktree-routed). Line limits may be exceeded by up to 50% for recovery.

### Step R5: Report source transcript, generated files, type. Tell the user they may `/clear`.

---

## Option: Clean

Reset to a clean state between unrelated work sessions.

**Per-worktree (always):**
- Delete `$CURRENT_WORKTREE/.claude/{context,current-task,task-history,current-bug,session-state}.md`
- Set `$CURRENT_WORKTREE/.claude/mode` to `normal`
- Clean `$CURRENT_WORKTREE/.claude/tasks.md` — remove completed entries; delete file if empty.

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

## Cleanup rules (apply to all handoff types except Clean)

1. **Filter `/tmp/*` paths** — don't include temp paths in "Recent Changes" or "Key Files".
2. **Dedupe tasks** — merge duplicate entries in `tasks.md`.
3. **Compress history** — if `task-history.md` exceeds 30 entries, compress old ones.
4. **Remove stale references** — don't reference files that no longer exist.
5. **Outer file is shared** — never overwrite the outer `context.md` wholesale; always merge by section.
