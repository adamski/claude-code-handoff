#!/usr/bin/env bash
# Install claude-code-handoff slash command + hooks.
#
# Usage:
#   ./install.sh                       # default: project-local (legacy behavior)
#   ./install.sh --scope project       # explicit project-local
#   ./install.sh --scope global        # global slash command, hooks NOT installed
#   ./install.sh --scope both          # global slash command + project-local hooks
#
# Notes:
# - The slash command (handoff.md) auto-detects multi-worktree layouts via
#   `git worktree list`; it works correctly whether installed globally or per-project.
# - Hooks are always project-local: they auto-fire on every prompt / session-start /
#   compact, and per-project opt-in is the only way to keep them off in repos that
#   don't want auto-tracking.
# - Symlinks are relative so the install travels with the repo when cloned.

set -euo pipefail

SCOPE="project"
while [ $# -gt 0 ]; do
    case "$1" in
        --scope) SCOPE="$2"; shift 2 ;;
        --scope=*) SCOPE="${1#--scope=}"; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

case "$SCOPE" in
    project|global|both) ;;
    *) echo "--scope must be one of: project, global, both" >&2; exit 2 ;;
esac

# Resolve submodule directory (where this script lives).
SUBMODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBMODULE_NAME="$(basename "$SUBMODULE_DIR")"

install_command_project() {
    # Symlink handoff.md into <repo>/.claude/commands/ relative to cwd's git toplevel.
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "Not in a git repo. Project install requires a git checkout." >&2
        exit 1
    }
    mkdir -p "$repo_root/.claude/commands"
    # Compute relative path from .claude/commands/ to the submodule's handoff.md.
    local rel
    rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" \
        "$SUBMODULE_DIR/handoff.md" "$repo_root/.claude/commands")"
    ln -sfn "$rel" "$repo_root/.claude/commands/handoff.md"
    echo "  ✓ project command: $repo_root/.claude/commands/handoff.md → $rel"
}

install_command_global() {
    mkdir -p "$HOME/.claude/commands"
    # Use absolute symlink target for global install — submodule path is stable.
    ln -sfn "$SUBMODULE_DIR/handoff.md" "$HOME/.claude/commands/handoff.md"
    echo "  ✓ global command:  $HOME/.claude/commands/handoff.md → $SUBMODULE_DIR/handoff.md"
}

install_hooks_project() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "Not in a git repo. Hooks require a project checkout." >&2
        exit 1
    }
    mkdir -p "$repo_root/.claude/hooks"
    local rel_base
    rel_base="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" \
        "$SUBMODULE_DIR/hooks" "$repo_root/.claude/hooks")"
    for hook in session-start.sh pre-compact.sh live-handoff.sh \
                post-edit-hook.sh proactive-handoff.sh pre-compact-handoff.sh; do
        if [ -f "$SUBMODULE_DIR/hooks/$hook" ]; then
            ln -sfn "$rel_base/$hook" "$repo_root/.claude/hooks/$hook"
            echo "  ✓ hook: $repo_root/.claude/hooks/$hook"
        fi
    done
    echo "  → wire up via $repo_root/.claude/settings.json (see settings-snippet.json)"
}

echo "claude-code-handoff installer (scope: $SCOPE)"
case "$SCOPE" in
    project)
        install_command_project
        install_hooks_project
        ;;
    global)
        install_command_global
        echo "  ⚠ hooks NOT installed in global mode — hooks must be project-local."
        echo "    Run with --scope both or rerun with --scope project per repo to enable hooks."
        ;;
    both)
        install_command_global
        install_hooks_project
        ;;
esac

echo "Done."
