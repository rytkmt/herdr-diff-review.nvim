#!/bin/bash
set -euo pipefail

STATE_DIR="$HOME/.local/state/herdr-diff-review"
STATE_FILE="$STATE_DIR/state.json"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT="${DIFF_REVIEW_TIMEOUT:-300}"
POLL_INTERVAL="${DIFF_REVIEW_POLL_INTERVAL:-0.5}"

# --- Early exits ---

# herdr外では無効
if [ "${HERDR_ENV:-}" != "1" ]; then
  exit 0
fi

if [ -z "${HERDR_PANE_ID:-}" ]; then
  exit 0
fi

# stdin読み取り
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')

# Edit/Write以外はpass-through
if [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; then
  exit 0
fi

# subagentはスキップ
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

# --- nvim常駐管理 ---

mkdir -p "$STATE_DIR"
LOCK_FILE="$STATE_DIR/state.lock"
if [ ! -f "$STATE_FILE" ]; then
  echo '{}' > "$STATE_FILE"
fi

PANE_ID="$HERDR_PANE_ID"
SOCK_PATH="/tmp/herdr-diff-review-${PANE_ID//:/--}.sock"

# 現在のtab_idを保存（後で戻す用）
CURRENT_TAB_ID=$(herdr pane current 2>/dev/null | jq -r '.result.pane.tab_id // empty')

nvim_alive() {
  nvim --server "$SOCK_PATH" --remote-expr 'luaeval("pcall(require, \"herdr-diff-review\")")' 2>/dev/null | grep -q "true"
}

# state.jsonからdiffタブ情報取得（flock排他制御）
exec 9>"$LOCK_FILE"
flock 9

DIFF_TAB_ID=$(jq -r ".[\"$PANE_ID\"].tab_id // empty" "$STATE_FILE")
DIFF_PANE_ID=$(jq -r ".[\"$PANE_ID\"].pane_id // empty" "$STATE_FILE")

# nvim常駐確認
if [ -n "$DIFF_PANE_ID" ] && nvim_alive; then
  # nvim常駐中: リモートでdiff表示
  :
else
  # nvim未起動 or タブ消失: 新規作成
  rm -f "$SOCK_PATH"

  TAB_RESULT=$(herdr tab create --label "diff-review" --no-focus 2>/dev/null)
  DIFF_TAB_ID=$(echo "$TAB_RESULT" | jq -r '.result.tab.tab_id // empty')
  DIFF_PANE_ID=$(echo "$TAB_RESULT" | jq -r '.result.root_pane.pane_id // empty')

  # nvim起動
  herdr pane run "$DIFF_PANE_ID" "bash $PLUGIN_DIR/scripts/start-nvim.sh $SOCK_PATH" >/dev/null 2>&1

  # nvim起動待ち
  for i in $(seq 1 20); do
    if nvim_alive; then
      break
    fi
    sleep 0.5
  done

  if ! nvim_alive; then
    flock -u 9
    echo "herdr-diff-review: nvim failed to start, allowing tool execution" >&2
    exit 0
  fi

  # state.json更新
  jq --arg pane "$PANE_ID" --arg tab "$DIFF_TAB_ID" --arg dpane "$DIFF_PANE_ID" --arg sock "$SOCK_PATH" \
    '.[$pane] = {"tab_id": $tab, "pane_id": $dpane, "socket_path": $sock}' "$STATE_FILE" > "$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

flock -u 9

# --- nvimにdiff表示を指示 ---

# Luaの文字列エスケープ（\, ', 改行, CR, タブ, ヌル文字を処理）
escape_lua_str() {
  printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/'/\\\\'/g" -e ':a' -e 'N' -e '$!ba' -e "s/\n/\\\\n/g" | tr -d '\000\r'
}

ORIG_ESC=$(escape_lua_str "$ORIGINAL")
MOD_ESC=$(escape_lua_str "$MODIFIED")
RESULT_ESC=$(escape_lua_str "$RESULT_FILE")
FPATH_ESC=$(escape_lua_str "$FILE_PATH")

nvim --server "$SOCK_PATH" --remote-expr \
  "luaeval(\"require('herdr-diff-review').open_diff('${ORIG_ESC}', '${MOD_ESC}', '${RESULT_ESC}', '${FPATH_ESC}')\")" \
  >/dev/null 2>&1

# diffタブにフォーカス
herdr tab focus "$DIFF_TAB_ID" >/dev/null 2>&1

# --- result_file をpoll ---

ELAPSED=0
while [ ! -f "$RESULT_FILE" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$(awk "BEGIN {print $ELAPSED + $POLL_INTERVAL}")
  if [ "$(awk "BEGIN {print ($ELAPSED >= $TIMEOUT) ? 1 : 0}")" -eq 1 ]; then
    # タイムアウト: nvimバッファをクリーンアップしてdeny
    nvim --server "$SOCK_PATH" --remote-expr \
      'luaeval("require(\"diff-review\")._close_buffers()")' >/dev/null 2>&1
    herdr tab focus "$CURRENT_TAB_ID" >/dev/null 2>&1
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Diff review timed out. Do not retry or suggest alternatives. Stop and wait for user instructions."}}'
    exit 0
  fi
done

RESULT=$(cat "$RESULT_FILE")

# 元のタブに戻す
herdr tab focus "$CURRENT_TAB_ID" >/dev/null 2>&1

# --- 結果出力 ---

if [ "$RESULT" = "accept" ]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
else
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"User rejected the proposed change in diff review. Do not retry or suggest alternatives. Stop and wait for user instructions."}}'
fi
