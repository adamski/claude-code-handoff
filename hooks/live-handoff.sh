#!/bin/bash
# Live Handoff — UserPromptSubmit hook
# Injects a directive on EVERY user message telling Claude to maintain session-state.md
# This is the primary mechanism for continuous context preservation.
#
# How it works:
#   - Fires before Claude processes each user message
#   - Outputs a <live-handoff> directive into Claude's system context
#   - Claude sees this directive and updates .claude/session-state.md as needed
#   - When session-state.md grows too large, the directive switches to "rewrite" mode
#
# Install: place in .claude/hooks/ and add UserPromptSubmit to .claude/settings.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/handoff-lib.sh"

# Per-project consent gate. This is the only hook that prompts: on first
# encounter (no marker) it asks the user; otherwise it honors the saved answer.
CONSENT_STATE="$(handoff_consent_state)"
if [ "$CONSENT_STATE" = false ]; then
    exit 0
elif [ "$CONSENT_STATE" = unset ]; then
    CONSENT_FILE="$(handoff_consent_file)"
    cat << SETUP
<handoff-setup>
This project has not been set up for session handoff tracking (claude-code-handoff plugin).
Before responding to the user's message, ask them — using AskUserQuestion — whether to enable
automatic session-state tracking and the /handoff command for THIS project.

Record their choice as a single word in this exact file (create it):
  ${CONSENT_FILE}
  - enable -> write: true
  - skip   -> write: false

This is a one-time setup; the saved answer prevents asking again. After writing the file,
continue with the user's request normally.
</handoff-setup>
SETUP
    exit 0
fi
# CONSENT_STATE == true below — normal live-handoff behavior.

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$REPO_ROOT/.claude/session-state.md"

# Ensure .claude directory exists
mkdir -p "$REPO_ROOT/.claude"

# Check for active task/bug files
HAS_TASK=false
HAS_BUG=false
[ -f "$REPO_ROOT/.claude/current-task.md" ] && HAS_TASK=true
[ -f "$REPO_ROOT/.claude/current-bug.md" ] && HAS_BUG=true

# Line limits vary by mode:
#   General: 60-80 lines
#   Task: 80-100 lines
#   Bug (or task+bug): 100-120 lines
if [ "$HAS_BUG" = true ]; then
    MAX_LINES=120
    TARGET_LINES=100
elif [ "$HAS_TASK" = true ]; then
    MAX_LINES=100
    TARGET_LINES=80
else
    MAX_LINES=80
    TARGET_LINES=60
fi

# Create state file if it doesn't exist
if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" << 'INIT'
# Session State

Auto-maintained during conversation. Do not delete.

## Decisions & Architecture

## Key Context

## Modified Files

## Current Focus

## Next Steps
INIT
fi

# Count current lines
LINE_COUNT=$(wc -l < "$STATE_FILE" | tr -d ' ')

# Build the task/bug completion check directive
TASK_BUG_DIRECTIVE=""
if [ "$HAS_TASK" = true ] || [ "$HAS_BUG" = true ]; then
    TASK_BUG_DIRECTIVE="
Also evaluate: has the current task or bug been completed?
- If a TASK is done: remove task-specific details from session-state.md, delete .claude/current-task.md, and note completion in session-state.md
- If a BUG is fixed: remove bug investigation details from session-state.md, delete .claude/current-bug.md, and note the fix in session-state.md
- If still in progress: keep task/bug context current in session-state.md"
fi

# Always output the directive — Claude sees this every turn
if [ "$LINE_COUNT" -gt "$MAX_LINES" ]; then
    cat << DIRECTIVE
<live-handoff>
REQUIRED: Before responding, update .claude/session-state.md:
1. Read the current file
2. It has grown too large. Rewrite it keeping ONLY the most critical information:
   - Active decisions and their rationale
   - Key context that would be lost if early conversation is compressed
   - Current focus and immediate next steps
   - Important file locations and what changed
3. Remove anything that is: obvious from code, already committed, no longer relevant, or low-importance
4. Target: under ${TARGET_LINES} lines. Be ruthless — only keep what you'd need to continue this work cold.
${TASK_BUG_DIRECTIVE}
</live-handoff>
DIRECTIVE
else
    cat << DIRECTIVE
<live-handoff>
REQUIRED: Before responding, check if anything important happened since session-state.md was last updated.
If yes — append to the appropriate section in .claude/session-state.md:
- Decisions made and why
- Architecture or approach changes
- Key discoveries or gotchas
- Important file:line references
- Changes to current focus or next steps
If nothing noteworthy happened (e.g. simple question, no new info), skip the update.
Do NOT rewrite the whole file — just append new items to existing sections.
${TASK_BUG_DIRECTIVE}
</live-handoff>
DIRECTIVE
fi

exit 0
