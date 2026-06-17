#!/bin/bash
# 기존 captain(--channels) 세션을 폐기하고 gateway 의 captain 세션으로 전환.
# nohup 독립 실행 권장 (이 스크립트가 호출 세션을 kill 하므로).
set -uo pipefail
GW="$HOME/workspace/claude-telegram-gateway"
source "$GW/.env"
LOG="$GW/logs/transition.log"
echo "[$(date)] transition start" >> "$LOG"
sleep 5
# 1) captain 봇 offset drain (밀린 메시지 재생 방지)
LAST=$(curl -s "https://api.telegram.org/bot$BOT_CAPTAIN_TOKEN/getUpdates?timeout=0" | python3 -c "import sys,json; r=json.load(sys.stdin).get('result',[]); print(max((u['update_id'] for u in r),default=-1)+1 if r else 0)")
mkdir -p "$GW/state"; echo "$LAST" > "$GW/state/offset_captain"
echo "[$(date)] captain offset drained to $LAST" >> "$LOG"
# 2) 기존 captain(--channels) 세션 폐기
tmux kill-window -t telegram:captain 2>>"$LOG" && echo "killed old captain" >> "$LOG"
sleep 2
# 3) gateway 재기동 (captain 세션 생성 + dispatch 가 captain 봇 폴링 시작)
bash "$GW/scripts/start.sh" >> "$LOG" 2>&1
echo "[$(date)] transition done" >> "$LOG"
