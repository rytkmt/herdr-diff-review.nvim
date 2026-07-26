#!/bin/bash
SOCKET_PATH="$1"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec nvim --listen "$SOCKET_PATH" \
  --cmd "lua package.path = '${PLUGIN_DIR}/lua/?.lua;${PLUGIN_DIR}/lua/?/init.lua;' .. package.path"
