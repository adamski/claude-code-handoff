#!/bin/bash
# Shared helpers for claude-code-handoff hooks: per-project consent gating.
#
# The plugin is enabled globally, but the hooks only act in projects where the
# user has opted in. Consent is recorded once per project (shared across all
# git worktrees) and remembered forever.
#
# Consent marker:
#   - git repo:  <common-git-dir>/handoff-consent   (shared by every worktree)
#   - non-git:   <cwd>/.claude/handoff-consent
# Contents: the single word `true` or `false`. Absent = not yet asked.

# Absolute path to this project's consent marker.
handoff_consent_file() {
    local gitdir
    if gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$gitdir" ]; then
        printf '%s/handoff-consent' "$(cd "$gitdir" && pwd)"
    else
        printf '%s/.claude/handoff-consent' "$PWD"
    fi
}

# Echoes one of: true | false | unset
handoff_consent_state() {
    local f
    f="$(handoff_consent_file)"
    if [ -f "$f" ]; then
        case "$(tr -d '[:space:]' < "$f" 2>/dev/null)" in
            true) echo true ;;
            *)    echo false ;;
        esac
    else
        echo unset
    fi
}
