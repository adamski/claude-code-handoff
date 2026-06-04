# Claude Code Handoff

Session context preservation for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), packaged as a plugin. Keeps Claude aware of what it's working on across autocompaction and session boundaries.

## Two Systems

### 1. Automated Live Handoff (recommended)

Claude continuously maintains a `.claude/session-state.md` file as you work. No manual intervention needed.

| Hook | Event | What It Does |
|------|-------|--------------|
| `live-handoff.sh` | **UserPromptSubmit** | Injects a directive on every message telling Claude to update `session-state.md` |
| `post-edit-hook.sh` | **PostToolUse** (Edit/Write/NotebookEdit) | Tracks which files were modified |
| `proactive-handoff.sh` | (utility) | State file management — init, file tracking, save/load |
| `session-start.sh` | **SessionStart** | Loads previous context + session state on startup/resume |
| `pre-compact.sh` + `pre-compact-handoff.sh` | **PreCompact** | Re-injects context and forces a complete state dump before autocompaction |

**How it works:**
- Every time you send a message, Claude sees a `<live-handoff>` directive telling it to check if anything important happened and update `session-state.md`
- When `session-state.md` grows too large, the directive switches to "rewrite" mode, keeping only critical information
- Before autocompaction, a `<pre-compact-handoff>` directive forces a complete state dump
- On session start, the previous `session-state.md` is loaded into context

### 2. Manual `/handoff` Command

Run `/handoff` before ending a session to write structured context files. `/handoff` is written for what the **next context window** needs in order to act — it prioritizes the forward-looking conversation (decisions and direction) over a record of finished work, which is recoverable from git.

| Mode | Use When | Output |
|------|----------|--------|
| **Context** | General work, switching focus | `.claude/context.md` (50 lines) |
| **Task** | Multi-session project work (a moving process) | `.claude/context.md` + `current-task.md` + `task-history.md` + `recent-prompts.md` |
| **Bug** | Debugging investigation | `.claude/current-bug.md` (status, confirmed facts, ruled-out dead ends) + `bug-test-log.md` (append-only ledger of every test's exact command + result) + `recent-prompts.md` |
| **Clean** | Starting fresh | Deletes all session files |

The `/handoff` command is **worktree-aware**: in a layout where the primary checkout has sibling worktrees (detected via `git worktree list`), it routes per-worktree state into each worktree's `.claude/` and merges a per-branch summary into the outer-root `.claude/context.md`. Single-checkout repos behave normally — context lands in `<repo>/.claude/`.

## Install

This repo is both a Claude Code **plugin** and its own single-plugin **marketplace**.

```
/plugin marketplace add adamski/claude-code-handoff
/plugin install handoff
```

The `/handoff` command is then available everywhere. The **hooks** only fire in projects that opt in (see below) — they stay dormant in every other repo.

### Enable the hooks in a project

Plugin hooks activate per-project via `enabledPlugins` in that project's settings. Add a minimal `.claude/settings.json` at the repo root:

```json
{
  "enabledPlugins": { "handoff": true }
}
```

Commit it and every checkout — including each git worktree — activates the hooks automatically. To enable it only for yourself (not the team), put the same block in `.claude/settings.local.json` instead.

### Updating

```
/plugin marketplace update claude-code-handoff
```

### gitignore the generated session files

The hooks and `/handoff` write session-specific files you don't want in version control:

```gitignore
.claude/context.md
.claude/current-task.md
.claude/task-history.md
.claude/current-bug.md
.claude/bug-test-log.md
.claude/recent-prompts.md
.claude/session-state.md
.claude/session-state.md.bak
.claude/mode
```

(Keep `.claude/settings.json` tracked — that's the enable file above.)

## Files

```
claude-code-handoff/
├── .claude-plugin/
│   ├── plugin.json                   # plugin manifest
│   └── marketplace.json              # self-hosting marketplace manifest
├── commands/
│   └── handoff.md                    # /handoff slash command (worktree-aware)
├── hooks/
│   ├── hooks.json                    # hook event wiring (${CLAUDE_PLUGIN_ROOT})
│   ├── session-start.sh              # SessionStart: loads context + session state
│   ├── live-handoff.sh               # UserPromptSubmit: continuous state maintenance
│   ├── post-edit-hook.sh             # PostToolUse: tracks file modifications
│   ├── proactive-handoff.sh          # Utility: state file management
│   ├── pre-compact.sh                # PreCompact: re-injects handoff context
│   └── pre-compact-handoff.sh        # PreCompact: emergency state dump
├── README.md
└── LICENSE                           # MIT
```

## Usage

**Starting a session:** if the plugin is enabled, previous context loads automatically into the session.

**During a session:** Claude maintains `.claude/session-state.md` continuously — nothing to do. Context survives autocompaction automatically.

**Ending a session:** just stop (state is already saved), or run `/handoff` and pick a mode for a deliberate structured checkpoint.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- `bash` (for hooks)
- `jq` (for file tracking via `post-edit-hook.sh`)

## Credits

Originally created by [Sonovore](https://github.com/Sonovore/claude-code-handoff). This fork adds worktree-aware routing and plugin packaging.

## License

MIT — see [LICENSE](LICENSE)
