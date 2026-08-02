#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT="${DIFF_REVIEW_TIMEOUT:-1800}"
POLL_INTERVAL="${DIFF_REVIEW_POLL_INTERVAL:-0.5}"
MODE="${DIFF_REVIEW_MODE:-tab}"

# --- Early exits ---

if [ "${HERDR_ENV:-}" != "1" ]; then
  exit 0
fi

if [ -z "${HERDR_PANE_ID:-}" ]; then
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')

if [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; then
  exit 0
fi

if [ -n "$AGENT_ID" ]; then
  exit 0
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

# --- ペイン作成 ---

# HERDR_PANE_ID環境変数はワークスペースID再割り当て後に古くなるため、process-infoで実際のpane_idを解決する
PANE_ID=$(herdr pane process-info --current 2>/dev/null | jq -r '.result.process_info.pane_id // empty')
WORKSPACE_ID=$(herdr pane get "$PANE_ID" 2>/dev/null | jq -r '.result.pane.workspace_id // empty' || true)
CURRENT_TAB_ID=$(herdr pane current 2>/dev/null | jq -r '.result.pane.tab_id // empty' 2>/dev/null || true)
FOCUSED_WORKSPACE_ID=$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[] | select(.focused == true) | .workspace_id // empty' 2>/dev/null || true)

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
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Diff review timed out. Do not retry or suggest alternatives. Stop and wait for user instructions."}}'
    exit 0
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
