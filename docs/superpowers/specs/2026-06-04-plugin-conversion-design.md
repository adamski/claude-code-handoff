# claude-code-handoff → Claude Code Plugin — Design

**Date:** 2026-06-04

## Goal

Distribute the `/handoff` command + session hooks as a native Claude Code plugin, so any project installs with `/plugin` instead of `install.sh` + symlinks + a vendored submodule. The plugin system natively provides: global command availability, per-project hook opt-in, self-locating hook scripts (`${CLAUDE_PLUGIN_ROOT}`), and versioned updates — all of which the old approach hand-rolled.

## Decisions (agreed)

- **Plugin name:** `handoff` → `/plugin install handoff`.
- **Ship handoff as a COMMAND** (`commands/handoff.md`), not a skill. Plugin commands invoke bare (`/handoff`); plugin skills are forced to `plugin:name`. Verified against the installed `commit-commands` plugin (bare `/commit`).
- **Repo hosts itself** as a single-plugin marketplace (`.claude-plugin/marketplace.json`).
- **Per-project opt-in** via `enabledPlugins` in a project's `.claude/settings.json` (or `.settings.local.json`); hooks stay dormant in every non-opted project.
- **Delete** `install.sh` and `settings-snippet.json`.
- **Accept** structural divergence from `Sonovore/claude-code-handoff` upstream (future upstream merges get harder). Not pushing upstream.

## Target structure (in-place conversion)

```
claude-code-handoff/
├── .claude-plugin/
│   ├── plugin.json          # name: handoff, version, description
│   └── marketplace.json     # lists the handoff plugin, source = this repo
├── commands/
│   └── handoff.md           # moved from ./handoff.md; frontmatter cleaned to command form
├── hooks/
│   ├── hooks.json           # NEW — declares hook events
│   ├── session-start.sh     # unchanged
│   ├── live-handoff.sh      # unchanged
│   ├── post-edit-hook.sh    # unchanged
│   ├── pre-compact.sh       # unchanged
│   ├── proactive-handoff.sh # unchanged
│   └── pre-compact-handoff.sh # unchanged
├── README.md                # rewritten: plugin install, not install.sh
└── LICENSE
```

## hooks/hooks.json

Maps the existing scripts to events, paths via `${CLAUDE_PLUGIN_ROOT}/hooks/<script>`:

- `SessionStart` → `session-start.sh`
- `UserPromptSubmit` → `live-handoff.sh`
- `PostToolUse` (matcher `Edit|Write|NotebookEdit`) → `post-edit-hook.sh`
- `PreCompact` → `pre-compact.sh`, `proactive-handoff.sh save`, `pre-compact-handoff.sh`

Scripts already `cd "$(git rev-parse --show-toplevel)"` and compute `SCRIPT_DIR` from `$0`, so they operate on the right project regardless of where they live. No symlinks.

## Install UX (the payoff)

```
/plugin marketplace add adamski/claude-code-handoff
/plugin install handoff
```
Then enable per-project. Updates: `/plugin marketplace update` or a `plugin.json` version bump.

## Worktree activation (resolves the "does it respect worktrees?" question)

Two layers:

1. **Command routing** — unaffected. Step 0 in `handoff.md` runs `git worktree list` / `git rev-parse --show-toplevel`; identical as a plugin command. Hooks `cd` to the worktree's git toplevel, so they write to the correct worktree's `.claude/`.
2. **Hook activation** — Claude Code resolves `enabledPlugins` from the *launch directory's* settings (`.claude/settings.json` + `.local` + user scope). Sibling-layout worktrees (`entonal-studio-worktrees/<branch>/`) are independent dirs and do NOT inherit enablement from the primary checkout. User-scope enable = fires everywhere (rejected).

**Decision:** activate via a **minimal committed `.claude/settings.json`**:
```json
{ "enabledPlugins": { "handoff": true } }
```
This rides `git checkout` into every worktree (and every newly-added one) automatically — restoring the auto-propagation the old committed-symlink approach had, without vendoring any tooling. Requires un-ignoring just this one file in the consuming repo (entonal-studio currently gitignores all of `.claude`). The hook scripts stay in the plugin. A one-line note in the project `CLAUDE.md` documents that the repo uses the plugin.

Enablement is only readable from `settings.json` / `settings.local.json` (fixed schema) — a separate dedicated file is not supported.

## Rollout cleanup (this session's stopgaps, now obsolete)

- Remove global `~/.claude/commands/handoff.md` symlink (plugin provides the command).
- Remove the absolute hook symlinks added this session in `entonal-studio/entonal-studio/.claude/hooks` and the outer `entonal-studio/.claude/hooks`.
- Keep entonal-studio commit `2c30f0e3` (no-submodule is still correct).
- Enable the `handoff` plugin per-dev where wanted (entonal-studio gitignores `.claude`, so enablement is local/per-dev — consistent with "each dev installs themselves").

## Out of scope

- Pushing the restructure upstream.
- Converting handoff to a model-invocable skill (kept as a user command).

## Risks to verify during build

1. Hook scripts run correctly when launched as `${CLAUDE_PLUGIN_ROOT}/hooks/*.sh` (they `cd` to git toplevel; confirm none rely on living inside the project tree).
2. Exact `enabledPlugins` / per-project enable keys (confirm against current Claude Code).
3. Marketplace `source` form for a self-hosting repo (github `adamski/claude-code-handoff`).
