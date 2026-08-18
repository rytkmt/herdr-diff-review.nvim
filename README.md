# herdr-diff-review.nvim

A plugin that lets you review, approve, or deny AI agent file changes in Neovim diff mode before they are applied.

When Claude Code or Kiro CLI (any PreToolUse hook-compatible agent) attempts to edit a file, the diff is displayed in Herdr. Approve or deny with a single command, and focus automatically returns to the agent's tab.

[日本語版 README](README.ja.md)

## How it works

```
Agent attempts Edit/Write
        │
        ▼
PreToolUse hook intercepts
        │
        ├─ Creates before/after temp files
        ├─ Creates a tab or pane based on display mode
        ├─ Launches Neovim with diff view
        ├─ Waits for user action
        │
        ▼
User runs :HerdrDiffReviewAccept or :HerdrDiffReviewDeny
        │
        ▼
Hook returns allow/deny to the agent, closes tab/pane
```

## Requirements

- [Herdr](https://herdr.dev) >= 0.7.4
- Neovim >= 0.10
- jq
- Claude Code (or any PreToolUse hook-compatible agent)

## Installation

### 1. Clone the repository

Clone to any location:

```sh
git clone https://github.com/rytkmt/herdr-diff-review.nvim.git ~/path/to/herdr-diff-review.nvim
```

### 2. Register as a Herdr plugin

```sh
herdr plugin link ~/path/to/herdr-diff-review.nvim
```

### 3. Add the Neovim plugin

lazy.nvim:

```lua
{
  "rytkmt/herdr-diff-review.nvim",
  lazy = false,
  opts = {},
}
```

### 4. Configure agent hooks

This plugin supports both Claude Code and Kiro CLI. It auto-detects the agent from the input JSON format, so the same script works for both.

#### Claude Code

Add to `hooks.PreToolUse` in `~/.claude/settings.json`:

```json
{
  "matcher": "Edit|Write",
  "hooks": [
    {
      "type": "command",
      "command": "bash ~/path/to/herdr-diff-review.nvim/hooks/diff-review.sh",
      "timeout": 1900
    }
  ]
}
```

`timeout` is the maximum wait time in seconds for the hook. Set it higher than `DIFF_REVIEW_TIMEOUT` (default: 1800s). The script-side timeout fires first and handles cleanup — if the hook timeout kills the process first, panes may be left behind.

#### Kiro CLI

Create `~/.kiro/agents/kiro_default.json` (applies to all workspaces):

```json
{
  "name": "kiro_default",
  "allowedTools": ["write"],
  "hooks": {
    "preToolUse": [
      {
        "matcher": "write",
        "command": "bash ~/path/to/herdr-diff-review.nvim/hooks/diff-review.sh",
        "timeout_ms": 1900000
      }
    ]
  }
}
```

`timeout_ms` is in milliseconds. Set it higher than `DIFF_REVIEW_TIMEOUT` (default: 1800s = 1800000ms).

> **Important**: `allowedTools` must include `write`. Without it, Kiro CLI's own permission prompt appears after the preToolUse hook returns allow, which does not work correctly in the Herdr environment. Including `write` in `allowedTools` is still safe because the preToolUse diff review hook acts as the approval gate.

> To apply only to a specific agent, add the same hook configuration to `.kiro/agents/<agent-name>.json` (local) or `~/.kiro/agents/<agent-name>.json` (global) under `hooks.preToolUse`.

## Usage

When a diff is displayed:

| Command | Action |
|---------|--------|
| `:HerdrDiffReviewAccept` | Approve the change |
| `:HerdrDiffReviewDeny` | Reject the change |

The modified-side buffer is editable. If you make changes before accepting, the edited content is what gets written to the file. Running `:w` on the modified-side buffer also counts as Accept.

Keymaps can be configured in setup (applied only to diff review buffers):

```lua
{
  "rytkmt/herdr-diff-review.nvim",
  lazy = false,
  opts = {
    keymaps = {
      accept = "<leader>da",
      deny = "<leader>dd",
      accept_with_message = "<leader>dA",
      deny_with_message = "<leader>dD",
    },
  },
}
```

## Configuration

Environment variables (optional):

| Variable | Default | Description |
|----------|---------|-------------|
| `DIFF_REVIEW_MODE` | tab | Display mode: `tab` / `vertical_split` / `horizontal_split` |
| `DIFF_REVIEW_TIMEOUT` | 1800 | Maximum wait time in seconds. Must be shorter than the agent's hook timeout |
| `DIFF_REVIEW_POLL_INTERVAL` | 0.5 | Polling interval in seconds |

### Display modes

- **tab** (default): Creates a new Herdr tab for the diff. Uses the full screen, best for large diffs
- **vertical_split**: Splits the current pane horizontally to show the diff
- **horizontal_split**: Splits the current pane vertically to show the diff

## Behavior details

- **Neovim per review**: Each review launches a fresh Neovim instance with the diff, and closes the tab/pane when done
- **Workspace-aware**: If in the same workspace, the diff tab is focused immediately. If in a different workspace, focus is not stolen — the diff tab is focused when you switch to that workspace
- **Outside Herdr** (`HERDR_ENV` not set): The hook passes through without action. The agent operates normally
- **Sub-agents**: For Claude Code, sub-agents are detected by `agent_id` and auto-approved without review (Kiro CLI skips sub-agent detection)
- **Timeout**: Treated as deny

## Per-tool limitations

| Feature | Claude Code | Kiro CLI |
|---------|:-----------:|:--------:|
| Accept | ✓ | ✓ |
| Deny | ✓ | ✓ |
| Accept with message | ✓ | ✗ |
| Deny with message | ✓ | ✓ |
| Accept edited | ✓ | ✓ |

In Kiro CLI, stdout from a PreToolUse hook returning `exit 0` (allow) is not added to the LLM context, so messages attached to Accept are not seen by the agent. Deny messages (via stderr) are returned to the agent normally.

## Project structure

```
herdr-diff-review.nvim/
├── herdr-plugin.toml          Herdr plugin manifest
├── hooks/
│   └── diff-review.sh         PreToolUse hook (main logic)
└── lua/
    └── herdr-diff-review/
        └── init.lua           Neovim plugin (diff display + commands)
```
