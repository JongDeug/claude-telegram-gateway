#!/bin/bash
# PreToolUse 훅: AskUserQuestion 차단.
# 이 게이트웨이 세션은 텔레그램으로만 사용자와 대화한다. AskUserQuestion 은 CLI/터미널 UI 에만
# 렌더링되어 사용자가 답할 수 없으므로, 호출을 거부하고 텔레그램으로 물으라고 모델에 피드백한다.
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "이 세션은 텔레그램으로만 사용자와 대화한다. AskUserQuestion 은 CLI 터미널에만 표시되어 사용자가 답할 수 없다. 질문이 필요하면 mcp__plugin_telegram_telegram__reply 로 번호 선택지를 담은 텔레그램 메시지를 보내고 사용자의 텍스트 답장을 기다려라."
  }
}
JSON
