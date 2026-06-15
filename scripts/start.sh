#!/bin/bash
# claude-telegram-gateway 기동
# config.json 을 읽어 (user × bot) 세션을 tmux 윈도우로 띄우고, 디스패처를 띄운다.
#   세션 이름 = <user>_<bot>  (예: alice_hulk)
#   각 세션 cwd = sessions/<user>_<bot>/  (.claude/settings.json + .mcp.json 자동 생성)
# 멱등: 이미 떠 있는 윈도우는 건드리지 않는다.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONFIG="$ROOT/config.json"

[ -f "$CONFIG" ] || { echo "config.json 없음. config.example.json 복사해서 만드세요."; exit 1; }
[ -f "$ROOT/.env" ] || { echo ".env 없음. .env.example 복사해서 토큰 채우세요."; exit 1; }

TMUX_SESSION=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('tmuxSession','telegram'))")
CLAUDE_BIN=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('claudeBin','claude'))")
CLAUDE_ARGS=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('claudeArgs','--dangerously-skip-permissions'))")
command -v "$CLAUDE_BIN" >/dev/null || CLAUDE_BIN="$HOME/.local/bin/claude"

# (user_name, bot_key) 목록 생성
PAIRS=$(python3 - "$CONFIG" << 'PY'
import json, sys
c = json.load(open(sys.argv[1]))
bots = [k for k in c.get("bots", {}) if not k.startswith("_")]
users = [(k, v) for k, v in c.get("users", {}).items() if not k.startswith("_")]
for _, u in users:
    for b in bots:
        print(f"{u['name']}\t{b}")
PY
)

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux new-session -d -s "$TMUX_SESSION" -n placeholder
fi

win_exists() { tmux list-windows -t "$TMUX_SESSION" -F '#W' 2>/dev/null | grep -qx "$1"; }

BUN=$(command -v bun || echo "$HOME/.bun/bin/bun")
SERVER="$ROOT/src/reply-mcp/server.js"

echo "[gateway] 세션 기동"
while IFS=$'\t' read -r uname bkey; do
  [ -n "$uname" ] || continue
  win="${uname}_${bkey}"
  sdir="$ROOT/sessions/$win"
  mkdir -p "$sdir/.claude"
  # reply-mcp config (봇 키만, 토큰 X) — 서버명 plugin_telegram_telegram 으로 툴 이름 호환
  cat > "$sdir/.mcp.json" <<EOF
{
  "mcpServers": {
    "plugin_telegram_telegram": {
      "command": "$BUN",
      "args": ["run", "$SERVER"],
      "env": { "BOT_KEY": "$bkey" }
    }
  }
}
EOF
  # 훅 등록
  cat > "$sdir/.claude/settings.json" <<EOF
{
  "permissions": { "allow": [] },
  "enableAllProjectMcpServers": true,
  "hooks": {
    "UserPromptSubmit": [ { "matcher": "", "hooks": [ { "type": "command", "command": "bash $ROOT/src/hooks/prompt-hook.sh" } ] } ],
    "PreToolUse": [ { "matcher": "mcp__plugin_telegram_telegram__reply", "hooks": [ { "type": "command", "command": "bash $ROOT/src/hooks/reply-format-hook.sh" } ] }, { "matcher": "AskUserQuestion", "hooks": [ { "type": "command", "command": "bash $ROOT/src/hooks/block-askuserquestion.sh" } ] } ],
    "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "bash $ROOT/src/hooks/stop-enforce-reply.sh" } ] } ]
  }
}
EOF
  if win_exists "$win"; then
    echo "  $win 이미 존재 → skip"
  else
    echo "  $win 생성"
    tmux new-window -d -t "$TMUX_SESSION" -n "$win" -c "$sdir"
    tmux send-keys -t "$TMUX_SESSION:$win" "$CLAUDE_BIN $CLAUDE_ARGS --strict-mcp-config --mcp-config $sdir/.mcp.json" Enter
  fi
done <<< "$PAIRS"

echo "[gateway] claude 부팅 대기 (10s)"
sleep 10
# 최초 기동 trust 다이얼로그 자동 수락 (이미 trust 면 빈 Enter 라 무해)
while IFS=$'\t' read -r uname bkey; do
  [ -n "$uname" ] || continue
  tmux send-keys -t "$TMUX_SESSION:${uname}_${bkey}" Enter 2>/dev/null || true
done <<< "$PAIRS"
sleep 2

# 디스패처
if win_exists "gw-dispatch"; then
  tmux kill-window -t "$TMUX_SESSION:gw-dispatch" || true
fi
tmux new-window -d -t "$TMUX_SESSION" -n "gw-dispatch" -c "$ROOT"
tmux send-keys -t "$TMUX_SESSION:gw-dispatch" "python3 $ROOT/src/dispatcher.py" Enter

echo "[gateway] 기동 완료. tmux attach -t $TMUX_SESSION"
echo "  로그: tail -f $ROOT/logs/dispatcher.log"
