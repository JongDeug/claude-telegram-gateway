#!/bin/bash
# PreToolUse hook: reply 툴 포맷 가드 (현재는 pass-through).
#
# 과거엔 plain text 모드라 **bold**/코드블록을 차단했었다. 이제 reply-mcp 가
# 기본으로 마크다운 → 텔레그램 HTML(md2tg, parse_mode:HTML)로 자동 변환하고,
# 변환 HTML 이 거부되면 plain 으로 폴백까지 한다(server.js doReply). 따라서
# 마크다운 강조/코드블록은 그대로 보내도 예쁘게 렌더되므로 차단할 이유가 없다.
#
# 잘못된 포맷은 서버의 plain 폴백이 받아내므로 여기선 막지 않고 통과시킨다.
# (훅 배선은 start.sh 에 남아있으니 파일은 유지하되 동작만 비운다.)
exit 0
