#!/bin/bash
# Stop hook: 텔레그램 발 메시지엔 반드시 reply 툴로 응답하도록 강제
#
# 입력: stdin JSON {"session_id", "transcript_path", "stop_hook_active"}
# 동작:
#   1. transcript 를 뒤에서부터 훑어 마지막 '실제 user 메시지'를 찾는다
#      (tool_result 전용 user 엔트리는 건너뛴다)
#   2. 그 user 메시지에 source="plugin:telegram:telegram" 이 없으면 통과
#   3. 그 user 메시지 이후 assistant 가 reply 툴을 호출했는지 확인
#   4. 호출 안 했으면 decision=block 으로 응답해 Claude 에게 reply 툴 쓰라고 돌려보냄
#
# 안전장치: stop_hook_active=true 면 무한루프 방지 위해 통과

INPUT=$(cat)

INPUT="$INPUT" python3 <<'PYEOF'
import json
import sys
import os

data = json.loads(os.environ.get('INPUT', '') or '{}')

# 무한루프 방지: Stop hook 이 이미 block 해서 재호출된 경우 통과
if data.get('stop_hook_active'):
    sys.exit(0)

transcript_path = data.get('transcript_path', '')
if not transcript_path or not os.path.isfile(transcript_path):
    sys.exit(0)

entries = []
with open(transcript_path, 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            pass

def is_genuine_user_message(entry):
    """Tool-result 전용이나 system-reminder 전용 user 엔트리 제외."""
    if entry.get('type') != 'user':
        return False
    msg = entry.get('message', {})
    content = msg.get('content', '')
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        # text 블록이 하나라도 있으면 실제 user input 으로 간주
        for c in content:
            if isinstance(c, dict) and c.get('type') == 'text':
                if (c.get('text') or '').strip():
                    return True
        return False
    return False

def extract_user_text(entry):
    msg = entry.get('message', {})
    content = msg.get('content', '')
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict) and c.get('type') == 'text':
                parts.append(c.get('text', ''))
        return '\n'.join(parts)
    return ''

# 마지막 실제 user 메시지 인덱스 찾기
last_user_idx = -1
for i in range(len(entries) - 1, -1, -1):
    if is_genuine_user_message(entries[i]):
        last_user_idx = i
        break

if last_user_idx < 0:
    sys.exit(0)

user_text = extract_user_text(entries[last_user_idx])

# 텔레그램 발이 아니면 통과
if 'source="plugin:telegram:telegram"' not in user_text:
    sys.exit(0)

# 그 이후 assistant 가 reply 툴을 호출했는지 확인
reply_called = False
for e in entries[last_user_idx + 1:]:
    if e.get('type') != 'assistant':
        continue
    msg = e.get('message', {})
    content = msg.get('content', [])
    if not isinstance(content, list):
        continue
    for c in content:
        if isinstance(c, dict) and c.get('type') == 'tool_use':
            if c.get('name') == 'mcp__plugin_telegram_telegram__reply':
                reply_called = True
                break
    if reply_called:
        break

if reply_called:
    sys.exit(0)

# 차단 — reply 툴 호출 없이 턴을 끝내려 함
out = {
    'decision': 'block',
    'reason': (
        '텔레그램 메시지 응답인데 mcp__plugin_telegram_telegram__reply 툴을 한 번도 호출하지 않고 턴을 끝내려 하고 있어. '
        'CLI 텍스트 출력은 유저에게 전달되지 않아 — 텔레그램으로 온 모든 요청은 반드시 reply 툴로 답해야 해. '
        'chat_id 는 수신 <channel> 태그의 값을, reply_to 는 해당 message_id 를 그대로 써서 지금 즉시 reply 를 호출하고 턴을 마쳐.'
    )
}
print(json.dumps(out, ensure_ascii=False))
PYEOF
