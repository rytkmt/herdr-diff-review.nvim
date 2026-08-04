#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT="${DIFF_REVIEW_TIMEOUT:-1800}"
POLL_INTERVAL="${DIFF_REVIEW_POLL_INTERVAL:-0.5}"
MODE="${DIFF_REVIEW_MODE:-tab}"

# --- Early exits ---

if [ -z "${HERDR_ENV:-}" ]; then
  exit 0
fi

if [ -z "${HERDR_PANE_ID:-}" ]; then
  exit 0
fi

INPUT=$(cat)

# --- Agent detection: Kiro vs Claude Code ---
# Kiro includes "hook_event_name" in its hook event JSON; Claude Code does not.

HOOK_EVENT_NAME=$(echo "$INPUT" | jq -r '.hook_event_name // empty')

if [ -n "$HOOK_EVENT_NAME" ]; then
  AGENT_TYPE="kiro"
else
  AGENT_TYPE="claude_code"
fi

# --- Parse tool name and check applicability ---

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$AGENT_TYPE" = "kiro" ]; then
  # Kiro uses "write" (or "fs_write") for all file modifications.
  # The command field distinguishes operations: strReplace, create, insert
  TOOL_COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

  if [ "$TOOL_NAME" != "write" ] && [ "$TOOL_NAME" != "fs_write" ] && [ "$TOOL_NAME" != "fsWrite" ]; then
    exit 0
  fi

  # Only review strReplace, create, and insert commands
  if [ "$TOOL_COMMAND" != "strReplace" ] && [ "$TOOL_COMMAND" != "create" ] && [ "$TOOL_COMMAND" != "insert" ]; then
    exit 0
  fi
else
  # Claude Code uses "Edit" and "Write" as tool names
  if [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; then
    exit 0
  fi

  # Sub-agent detection: skip review for sub-agents (Claude Code only)
  AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
  if [ -n "$AGENT_ID" ]; then
    exit 0
  fi
fi

# --- tempファイル作成 ---

WORK_DIR=$(mktemp -d "/tmp/diff-review-XXXXXX")
ORIGINAL="$WORK_DIR/original"
MODIFIED="$WORK_DIR/modified"
RESULT_FILE="$WORK_DIR/result"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# --- Parse file path and generate diff content ---

if [ "$AGENT_TYPE" = "kiro" ]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty')

  case "$TOOL_COMMAND" in
    strReplace)
      if [ -f "$FILE_PATH" ]; then
        cp "$FILE_PATH" "$ORIGINAL"
      else
        touch "$ORIGINAL"
      fi

      _HOOK_INPUT="$INPUT" _ORIGINAL_PATH="$ORIGINAL" python3 << 'PYEOF' > "$MODIFIED"
import json, os, sys

input_data = json.loads(os.environ['_HOOK_INPUT'])
old_string = input_data['tool_input'].get('oldStr', '')
new_string = input_data['tool_input'].get('newStr', '')
replace_all = input_data['tool_input'].get('replaceAll', False)

with open(os.environ['_ORIGINAL_PATH'], 'r') as f:
    content = f.read()

if not old_string:
    sys.stdout.write(content)
    sys.exit(0)

if replace_all:
    result = content.replace(old_string, new_string)
else:
    result = content.replace(old_string, new_string, 1)

sys.stdout.write(result)
PYEOF
      ;;
    create)
      if [ -f "$FILE_PATH" ]; then
        cp "$FILE_PATH" "$ORIGINAL"
      else
        touch "$ORIGINAL"
      fi

      echo "$INPUT" | jq -r '.tool_input.content // empty' > "$MODIFIED"
      ;;
    insert)
      if [ -f "$FILE_PATH" ]; then
        cp "$FILE_PATH" "$ORIGINAL"
      else
        touch "$ORIGINAL"
      fi

      _HOOK_INPUT="$INPUT" _ORIGINAL_PATH="$ORIGINAL" python3 << 'PYEOF' > "$MODIFIED"
import json, os, sys

input_data = json.loads(os.environ['_HOOK_INPUT'])
content_to_insert = input_data['tool_input'].get('content', '')
insert_line = input_data['tool_input'].get('insertLine', None)

with open(os.environ['_ORIGINAL_PATH'], 'r') as f:
    original_content = f.read()

lines = original_content.split('\n')
# Preserve trailing newline info
had_trailing_newline = original_content.endswith('\n')

if insert_line is not None:
    # Insert at specific line (0-indexed)
    insert_lines = content_to_insert.split('\n')
    lines = lines[:insert_line] + insert_lines + lines[insert_line:]
else:
    # Append to end
    if had_trailing_newline and lines and lines[-1] == '':
        lines = lines[:-1]
    lines.append(content_to_insert)

result = '\n'.join(lines)
if not result.endswith('\n'):
    result += '\n'

sys.stdout.write(result)
PYEOF
      ;;
  esac
else
  # Claude Code
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

  if [ "$TOOL_NAME" = "Edit" ]; then
    if [ -f "$FILE_PATH" ]; then
      cp "$FILE_PATH" "$ORIGINAL"
    else
      touch "$ORIGINAL"
    fi

    _HOOK_INPUT="$INPUT" _ORIGINAL_PATH="$ORIGINAL" python3 << 'PYEOF' > "$MODIFIED"
import json, os, sys

input_data = json.loads(os.environ['_HOOK_INPUT'])
old_string = input_data['tool_input'].get('old_string', '')
new_string = input_data['tool_input'].get('new_string', '')
replace_all = input_data['tool_input'].get('replace_all', False)

with open(os.environ['_ORIGINAL_PATH'], 'r') as f:
    content = f.read()

if not old_string:
    sys.stdout.write(content)
    sys.exit(0)

if replace_all:
    result = content.replace(old_string, new_string)
else:
    result = content.replace(old_string, new_string, 1)

sys.stdout.write(result)
PYEOF

  elif [ "$TOOL_NAME" = "Write" ]; then
    if [ -f "$FILE_PATH" ]; then
      cp "$FILE_PATH" "$ORIGINAL"
    else
      touch "$ORIGINAL"
    fi

    echo "$INPUT" | jq -r '.tool_input.content // empty' > "$MODIFIED"
  fi
fi

# --- ペイン作成 ---

# HERDR_PANE_IDを検証し、有効ならそのworkspaceを使う。
# process-info --currentは複数セッション稼働時に別paneを返すことがあるためフォールバックのみ。
PANE_ID=""
PANE_ID_SOURCE=""
if [ -n "${HERDR_PANE_ID:-}" ]; then
  PANE_GET_RESULT=$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null || true)
  if [ -n "$PANE_GET_RESULT" ] && echo "$PANE_GET_RESULT" | jq -e '.result.pane.workspace_id' >/dev/null 2>&1; then
    PANE_ID="$HERDR_PANE_ID"
    PANE_ID_SOURCE="HERDR_PANE_ID"
  fi
fi
if [ -z "$PANE_ID" ]; then
  PANE_ID=$(herdr pane process-info --current 2>/dev/null | jq -r '.result.process_info.pane_id // empty')
  PANE_ID_SOURCE="process-info"
fi
WORKSPACE_ID=$(herdr pane get "$PANE_ID" 2>/dev/null | jq -r '.result.pane.workspace_id // empty' || true)
CURRENT_TAB_ID=$(herdr pane current 2>/dev/null | jq -r '.result.pane.tab_id // empty' 2>/dev/null || true)
FOCUSED_WORKSPACE_ID=$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[] | select(.focused == true) | .workspace_id // empty' 2>/dev/null || true)

# デバッグログ
DEBUG_LOG="/tmp/diff-review-debug.log"
{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "AGENT_TYPE=$AGENT_TYPE"
  echo "TOOL_NAME=$TOOL_NAME"
  if [ "$AGENT_TYPE" = "kiro" ]; then
    echo "TOOL_COMMAND=$TOOL_COMMAND"
  else
    echo "AGENT_ID=${AGENT_ID:-}"
  fi
  echo "PANE_ID=$PANE_ID (source=$PANE_ID_SOURCE)"
  echo "WORKSPACE_ID=$WORKSPACE_ID"
  echo "FOCUSED_WORKSPACE_ID=$FOCUSED_WORKSPACE_ID"
  echo "CURRENT_TAB_ID=$CURRENT_TAB_ID"
  echo "HERDR_PANE_ID=${HERDR_PANE_ID:-}"
} >> "$DEBUG_LOG"

DIFF_PANE_ID=""
DIFF_TAB_ID=""

case "$MODE" in
  tab)
    TAB_CREATE_ARGS=(--label "diff-review" --no-focus)
    if [ -n "$WORKSPACE_ID" ]; then
      TAB_CREATE_ARGS+=(--workspace "$WORKSPACE_ID")
    fi
    TAB_RESULT=$(herdr tab create "${TAB_CREATE_ARGS[@]}" 2>/dev/null)
    DIFF_TAB_ID=$(echo "$TAB_RESULT" | jq -r '.result.tab.tab_id // empty')
    DIFF_PANE_ID=$(echo "$TAB_RESULT" | jq -r '.result.root_pane.pane_id // empty')
    echo "TAB_CREATE_ARGS=${TAB_CREATE_ARGS[*]}" >> "$DEBUG_LOG"
    echo "TAB_RESULT=$TAB_RESULT" >> "$DEBUG_LOG"
    ;;
  vertical_split)
    SPLIT_RESULT=$(herdr pane split --current --direction right --no-focus 2>/dev/null)
    DIFF_PANE_ID=$(echo "$SPLIT_RESULT" | jq -r '.result.pane.pane_id // empty')
    ;;
  horizontal_split)
    SPLIT_RESULT=$(herdr pane split --current --direction down --no-focus 2>/dev/null)
    DIFF_PANE_ID=$(echo "$SPLIT_RESULT" | jq -r '.result.pane.pane_id // empty')
    ;;
  *)
    echo "herdr-diff-review: unknown DIFF_REVIEW_MODE: $MODE" >&2
    exit 0
    ;;
esac

if [ -z "$DIFF_PANE_ID" ]; then
  echo "herdr-diff-review: failed to create pane, allowing tool execution" >&2
  exit 0
fi

# --- nvim起動 ---

escape_lua_str() {
  printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/'/\\\\'/g" -e ':a' -e 'N' -e '$!ba' -e "s/\n/\\\\n/g" | tr -d '\000\r'
}

ORIG_ESC=$(escape_lua_str "$ORIGINAL")
MOD_ESC=$(escape_lua_str "$MODIFIED")
RESULT_ESC=$(escape_lua_str "$RESULT_FILE")
FPATH_ESC=$(escape_lua_str "$FILE_PATH")

NVIM_CMD="nvim --cmd \"lua package.path = '${PLUGIN_DIR}/lua/?.lua;${PLUGIN_DIR}/lua/?/init.lua;' .. package.path\" -c \"lua require('herdr-diff-review').open_diff('${ORIG_ESC}', '${MOD_ESC}', '${RESULT_ESC}', '${FPATH_ESC}')\""

herdr pane run "$DIFF_PANE_ID" "$NVIM_CMD" >/dev/null 2>&1

# tabモードで同じワークスペースの場合のみ即座にフォーカス（別WSはポーリング内で検知）
if [ "$MODE" = "tab" ] && [ -n "$DIFF_TAB_ID" ] && [ "$WORKSPACE_ID" = "$FOCUSED_WORKSPACE_ID" ]; then
  herdr tab focus "$DIFF_TAB_ID" >/dev/null 2>&1 || true
fi

# --- result_file をpoll ---

DIFF_TAB_FOCUSED=false
if [ "$WORKSPACE_ID" = "$FOCUSED_WORKSPACE_ID" ]; then
  DIFF_TAB_FOCUSED=true
fi

ELAPSED=0
while [ ! -f "$RESULT_FILE" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$(awk "BEGIN {print $ELAPSED + $POLL_INTERVAL}")

  # 別ワークスペースの場合、そのWSにフォーカスが来たらdiffタブにフォーカス
  if [ "$MODE" = "tab" ] && [ "$DIFF_TAB_FOCUSED" = "false" ] && [ -n "$DIFF_TAB_ID" ]; then
    CURRENT_FOCUSED_WS=$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[] | select(.focused == true) | .workspace_id // empty' 2>/dev/null || true)
    if [ "$CURRENT_FOCUSED_WS" = "$WORKSPACE_ID" ]; then
      herdr tab focus "$DIFF_TAB_ID" >/dev/null 2>&1 || true
      DIFF_TAB_FOCUSED=true
    fi
  fi

  if [ "$(awk "BEGIN {print ($ELAPSED >= $TIMEOUT) ? 1 : 0}")" -eq 1 ]; then
    # タイムアウト: ペイン/タブを閉じてdeny
    if [ "$MODE" = "tab" ] && [ -n "$DIFF_TAB_ID" ]; then
      herdr tab close "$DIFF_TAB_ID" >/dev/null 2>&1 || true
    else
      herdr pane close "$DIFF_PANE_ID" >/dev/null 2>&1 || true
    fi
    if [ "$MODE" = "tab" ] && [ "$WORKSPACE_ID" = "$FOCUSED_WORKSPACE_ID" ]; then
      herdr tab focus "$CURRENT_TAB_ID" >/dev/null 2>&1 || true
    fi

    # --- タイムアウト時の出力 ---
    if [ "$AGENT_TYPE" = "kiro" ]; then
      echo "Diff review timed out. Do not retry or suggest alternatives. Stop and wait for user instructions." >&2
      exit 2
    else
      echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Diff review timed out. Do not retry or suggest alternatives. Stop and wait for user instructions."}}'
      exit 0
    fi
  fi
done

DECISION=$(head -n 1 "$RESULT_FILE")
MESSAGE=$(tail -n +2 "$RESULT_FILE")

# --- ペイン/タブ閉じる ---

if [ "$MODE" = "tab" ] && [ -n "$DIFF_TAB_ID" ]; then
  herdr tab close "$DIFF_TAB_ID" >/dev/null 2>&1 || true
  if [ "$WORKSPACE_ID" = "$FOCUSED_WORKSPACE_ID" ]; then
    herdr tab focus "$CURRENT_TAB_ID" >/dev/null 2>&1 || true
  fi
else
  herdr pane close "$DIFF_PANE_ID" >/dev/null 2>&1 || true
fi

# --- 結果出力 ---

if [ "$AGENT_TYPE" = "kiro" ]; then
  # Kiro: exit 0 = allow, exit 2 = deny (reason on stderr)
  if [ "$DECISION" = "accept" ]; then
    if [ -n "$MESSAGE" ]; then
      echo "$MESSAGE"
    fi
    exit 0
  elif [ "$DECISION" = "accept_edited" ]; then
    cp "$MODIFIED" "$FILE_PATH"
    REASON="User applied a modified version of the change directly. The file has been updated. Continue without retrying this edit."
    if [ -n "$MESSAGE" ]; then
      REASON="$REASON (User note: $MESSAGE)"
    fi
    echo "$REASON" >&2
    exit 2
  else
    # deny
    if [ -n "$MESSAGE" ]; then
      echo "User rejected the proposed change in diff review. Reason: $MESSAGE Do not retry or suggest alternatives. Stop and wait for user instructions." >&2
    else
      echo "User rejected the proposed change in diff review. Do not retry or suggest alternatives. Stop and wait for user instructions." >&2
    fi
    exit 2
  fi
else
  # Claude Code: stdout JSON
  if [ "$DECISION" = "accept" ]; then
    if [ -n "$MESSAGE" ]; then
      jq -n --arg msg "$MESSAGE" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","additionalContext":$msg}}'
    else
      echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    fi
  elif [ "$DECISION" = "accept_edited" ]; then
    cp "$MODIFIED" "$FILE_PATH"
    REASON="User applied a modified version of the change directly. The file has been updated. Continue without retrying this edit."
    if [ -n "$MESSAGE" ]; then
      REASON="$REASON (User note: $MESSAGE)"
    fi
    jq -n --arg msg "$REASON" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$msg}}'
  else
    if [ -n "$MESSAGE" ]; then
      jq -n --arg msg "$MESSAGE" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("User rejected the proposed change in diff review. Reason: " + $msg + " Do not retry or suggest alternatives. Stop and wait for user instructions.")}}'
    else
      echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"User rejected the proposed change in diff review. Do not retry or suggest alternatives. Stop and wait for user instructions."}}'
    fi
  fi
fi
