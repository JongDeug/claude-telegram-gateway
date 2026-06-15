#!/bin/bash
# claude-telegram-gateway 정지: 디스패처 + 모든 (user × bot) 세션 윈도우를 닫는다.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONFIG="$ROOT/config.json"
TMUX_SESSION=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('tmuxSession','telegram'))" 2>/dev/null || echo telegram)

kill_win() {
  if tmux list-windows -t "$TMUX_SESSION" -F '#W' 2>/dev/null | grep -qx "$1"; then
    echo "kill $1"; tmux kill-window -t "$TMUX_SESSION:$1" || true
  fi
}

kill_win "gw-dispatch"
while IFS=$'\t' read -r uname bkey; do
  [ -n "$uname" ] || continue
  kill_win "${uname}_${bkey}"
done <<< "$(python3 - "$CONFIG" << 'PY'
import json, sys
c = json.load(open(sys.argv[1]))
bots = [k for k in c.get("bots", {}) if not k.startswith("_")]
for k, u in c.get("users", {}).items():
    if k.startswith("_"): continue
    for b in bots: print(f"{u['name']}\t{b}")
PY
)"
echo "[gateway] 정지 완료"
