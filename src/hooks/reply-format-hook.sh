#!/bin/bash
# PreToolUse hook: reply 툴 텍스트 포맷 가드.
#
# 규칙:
#   1) 코드블록(```) 가 있는데 format 이 markdownv2 가 아니면 차단
#   2) bold 마크다운(**…**) 가 있으면 차단 — plain text 모드에선 그대로 별표
#      두 개로 보여 종환님이 *별표가 그대로 보인다* 라고 매번 지적. 새 세션에서
#      컨텍스트 잃어도 이 훅이 자비스에게 즉시 룰을 학습시키도록 차단으로 처리.
#
# 입력: stdin JSON {"session_id", "tool_name", "tool_input": {...}}
# 출력: {"decision": "block", "reason": "..."} 또는 빈 출력 (허용)

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_name', ''))" 2>/dev/null)
if [ "$TOOL_NAME" != "mcp__plugin_telegram_telegram__reply" ]; then
  exit 0
fi

INPUT="$INPUT" python3 <<'PYEOF'
import json
import os
import re

data = json.loads(os.environ.get('INPUT', '') or '{}')
tool_input = data.get('tool_input', {})
text = tool_input.get('text', '')
fmt = tool_input.get('format', '')

# 1) 코드블록 가드
if '```' in text and fmt != 'markdownv2':
    print(json.dumps({
        'decision': 'block',
        'reason': (
            'Code block detected but format is not markdownv2. Re-call reply '
            'with format: "markdownv2". Code blocks require MarkdownV2 to '
            'render properly. Outside code blocks, escape special chars '
            '(. ! - ( ) + = { } | ~ > # _) with backslash.'
        ),
    }))
    raise SystemExit(0)

# 2) bold 마크다운 (**…**) 가드 — plain text 모드에선 별표가 그대로 보인다.
#    내부에 별표가 없는 *짝지어진* 두 개 별표만 매칭 (이모지/수식 흔한 단일
#    별표는 무시). format 이 markdownv2 라면 *single asterisk* 가 bold 라
#    별 두 개 사용은 어차피 의미 없으므로 이 케이스에도 가드.
if re.search(r'\*\*[^*\n]+?\*\*', text):
    print(json.dumps({
        'decision': 'block',
        'reason': (
            '텔레그램 reply 본문에 **bold** 마크다운이 있다. plain text 모드에선 '
            '별표 두 개가 그대로 화면에 보여 종환님이 매번 지적하던 그 케이스. '
            '강조는 plain 으로 — 줄 분리, 콜론 prefix, 한 단어 들여쓰기, 또는 '
            '간단히 굵게 안 쓰기. 만약 진짜 강조가 필요하면 format=markdownv2 + '
            'MarkdownV2 의 *single asterisk* bold + reserved char escape 까지 '
            '한 세트로 보낼 것.'
        ),
    }))
    raise SystemExit(0)
PYEOF
