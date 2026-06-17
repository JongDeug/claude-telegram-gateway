#!/bin/bash
# claude-telegram-gateway 기동 — 사용자별 윈도우 + 봇별 pane (한 화면 3분할)
# config.json 의 users 별로 tmux 윈도우 1개를 만들고, 그 안에 bots 를 pane 으로 나란히 띄운다.
#   윈도우 = <user.name>          (예: jongdeug / 0deug)
#   pane   = 봇별, pane title = <bot_key>  → dispatcher 가 title 로 그 pane 을 찾아 메시지를 주입한다.
#   각 pane cwd = sessions/<user>_<bot>/   (.mcp.json + settings.json 자동 생성, 봇별 reply-mcp 토큰)
# 봇 대화는 각 pane(claude 세션)이 그대로 이어간다. 한 화면에서 헐크/캡틴/토르를 다 본다.
# 멱등: 이미 떠 있는 사용자 윈도우는 건드리지 않는다.

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

# 봇 키 목록(순서 보존) / 사용자 이름 목록
BOT_KEYS=$(python3 -c "import json;print(' '.join(k for k in json.load(open('$CONFIG'))['bots'] if not k.startswith('_')))")
USER_NAMES=$(python3 -c "import json;print(' '.join(v['name'] for k,v in json.load(open('$CONFIG'))['users'].items() if not k.startswith('_')))")

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux new-session -d -s "$TMUX_SESSION" -n placeholder
fi
win_exists() { tmux list-windows -t "$TMUX_SESSION" -F '#W' 2>/dev/null | grep -qx "$1"; }

BUN=$(command -v bun || echo "$HOME/.bun/bin/bun")
SERVER="$ROOT/src/reply-mcp/server.js"

# 봇 세션 설정(.mcp.json + settings.json) 생성 — 봇별 reply-mcp 토큰(BOT_KEY). 경로를 stdout 으로 돌려준다.
make_sdir() {
  local uname="$1" bkey="$2" sdir="$ROOT/sessions/${uname}_${bkey}"
  mkdir -p "$sdir/.claude"
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
  echo "$sdir"
}

echo "[gateway] 세션 기동 (사용자별 윈도우 + 봇 pane)"
for uname in $USER_NAMES; do
  if win_exists "$uname"; then
    echo "  $uname 윈도우 이미 존재 → skip"
    continue
  fi
  first=1
  for bkey in $BOT_KEYS; do
    sdir="$(make_sdir "$uname" "$bkey")"
    if [ "$first" -eq 1 ]; then
      tmux new-window -d -t "$TMUX_SESSION" -n "$uname" -c "$sdir"
      first=0
    else
      tmux split-window -h -t "$TMUX_SESSION:$uname" -c "$sdir"
      tmux select-layout -t "$TMUX_SESSION:$uname" even-horizontal
    fi
    # 방금 만든(활성) pane 에 표시 title + 식별용 @bot 옵션 부여 + claude 기동.
    # dispatcher 는 @bot(claude TUI 가 못 건드리는 pane 옵션)으로 그 pane 을 찾는다.
    tmux select-pane -t "$TMUX_SESSION:$uname" -T "$bkey"
    tmux set-option -p -t "$TMUX_SESSION:$uname" @bot "$bkey"
    tmux send-keys -t "$TMUX_SESSION:$uname" "$CLAUDE_BIN $CLAUDE_ARGS --strict-mcp-config --mcp-config $sdir/.mcp.json" Enter
    echo "  $uname / $bkey pane"
  done
  tmux select-layout -t "$TMUX_SESSION:$uname" even-horizontal
  # pane 경계 상단에 봇 이름표 — attach 시 어느 pane 이 누군지 한눈에 (@bot 값 표시)
  tmux set-option -w -t "$TMUX_SESSION:$uname" pane-border-status top
  tmux set-option -w -t "$TMUX_SESSION:$uname" pane-border-format " #[fg=green,bold]#{@bot}#[default] "
done

echo "[gateway] claude 부팅 대기 (10s)"
sleep 10
# 최초 기동 trust 다이얼로그 자동 수락 (각 pane 에 빈 Enter — 이미 trust 면 무해)
for uname in $USER_NAMES; do
  for pid in $(tmux list-panes -t "$TMUX_SESSION:$uname" -F '#{pane_id}' 2>/dev/null); do
    tmux send-keys -t "$pid" Enter 2>/dev/null || true
  done
done
sleep 2

# 디스패처
if win_exists "gw-dispatch"; then
  tmux kill-window -t "$TMUX_SESSION:gw-dispatch" || true
fi
tmux new-window -d -t "$TMUX_SESSION" -n "gw-dispatch" -c "$ROOT"
tmux send-keys -t "$TMUX_SESSION:gw-dispatch" "python3 $ROOT/src/dispatcher.py" Enter

echo "[gateway] 기동 완료. tmux attach -t $TMUX_SESSION"
echo "  사용자 윈도우(jongdeug/0deug) 안에 봇 pane(헐크/캡틴/토르)이 나란히 떠요."
echo "  로그: tail -f $ROOT/logs/dispatcher.log"
