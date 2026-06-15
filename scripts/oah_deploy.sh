#!/usr/bin/env bash
# oah_deploy — 마스터가 임의 노드에 파일을 배포(생성)하고 선택적으로 실행.
# 데몬의 [WRITE:b64] (파일 생성) + [SHELL] (실행) 태스크를 사용한다.
#
# 사용:
#   STATE_SERVER=http://127.0.0.1:4000 OAH_SECRET=... WORK_KEY=WK-xxxx \
#     ./oah_deploy.sh <node> <local-file> <remote-path> [--run "<shell cmd>"]
#
# 예 (serialplot 피더를 Windows에 배포·실행):
#   ./oah_deploy.sh builder@NUCBOXG3 scripts/serialplot_feeder.ps1 \
#     'C:\Users\Public\serialplot_feeder.ps1' \
#     --run 'powershell -ExecutionPolicy Bypass -File C:\Users\Public\serialplot_feeder.ps1'
set -euo pipefail

SERVER="${STATE_SERVER:-http://127.0.0.1:4000}"
SERVER="${SERVER/ws:/http:}"; SERVER="${SERVER/wss:/https:}"
SECRET="${OAH_SECRET:?OAH_SECRET 필요}"
WK="${WORK_KEY:?WORK_KEY 필요}"

NODE="${1:?사용: oah_deploy.sh <node> <local-file> <remote-path> [--run cmd]}"
LOCAL="${2:?local-file 필요}"
REMOTE="${3:?remote-path 필요}"
RUNCMD=""
if [[ "${4:-}" == "--run" ]]; then RUNCMD="${5:?--run 뒤 명령 필요}"; fi
[[ -f "$LOCAL" ]] || { echo "로컬 파일 없음: $LOCAL" >&2; exit 1; }

post_task() {  # $1=instructions(JSON-escaped 문자열), 결과 task_id 출력
  local instr="$1" tid="dep-$(date +%s)-$RANDOM"
  curl -s -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
    -X POST "$SERVER/api/task" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1],"to":sys.argv[2],"work_key":sys.argv[3],"role":"builder","instructions":sys.argv[4]}))' "$tid" "$NODE" "$WK" "$instr")" >/dev/null
  echo "$tid"
}

# 1) 파일 배포 ([WRITE:b64])
B64=$(base64 < "$LOCAL" | tr -d '\n')
echo "→ [WRITE] $NODE : $REMOTE  ($(wc -c <"$LOCAL") bytes)"
WTID=$(post_task "[WRITE:b64] ${REMOTE}
${B64}")
sleep 3
# 결과 조회
RES=$(curl -s -H "Authorization: Bearer $SECRET" "$SERVER/api/task/$WTID" 2>/dev/null || true)
echo "  결과: $(echo "$RES" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("output") or d.get("status") or d)' 2>/dev/null || echo "$RES" | head -c 120)"

# 2) 선택적 실행 ([SHELL])
if [[ -n "$RUNCMD" ]]; then
  echo "→ [SHELL] $NODE : $RUNCMD"
  post_task "[SHELL] ${RUNCMD}" >/dev/null
  echo "  실행 요청 전송 (결과는 라이브 모니터/태스크 결과 확인)"
fi
echo "완료."
