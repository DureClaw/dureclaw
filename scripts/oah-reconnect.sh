#!/usr/bin/env bash
# oah-reconnect — 에이전트 자동 재연결 + WK 동기화
#
# 사용법:
#   bash oah-reconnect.sh                  # 백그라운드 watchdog 시작
#   bash oah-reconnect.sh --once           # 한 번만 실행
#   bash oah-reconnect.sh --sync-wk        # WK만 최신으로 동기화
#   bash oah-reconnect.sh --status         # 현재 연결 상태 출력

set -euo pipefail

OAH_DIR="$HOME/.oah"
OAH_CONFIG="$OAH_DIR/config"
OAH_LOG="$OAH_DIR/reconnect.log"
INTERVAL="${OAH_RECONNECT_INTERVAL:-30}"

# ─── 설정 로드 ─────────────────────────────────────────────────────────────────

PHOENIX=""
ROLE="builder"
WK=""
NAME=""
BACKEND="auto"

[[ -f "$OAH_CONFIG" ]] && source "$OAH_CONFIG"

HTTP_BASE="${PHOENIX/ws:/http:}"
HTTP_BASE="${HTTP_BASE/wss:/https:}"
HTTP_BASE="${HTTP_BASE:-http://localhost:4000}"
NAME="${NAME:-${ROLE}@$(hostname -s 2>/dev/null || hostname)}"

# ─── 헬퍼 ──────────────────────────────────────────────────────────────────────

_log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OAH_LOG"; }

_server_ok() {
  curl -sf --max-time 5 "$HTTP_BASE/api/health" > /dev/null 2>&1
}

_agent_online() {
  curl -sf "$HTTP_BASE/api/presence" 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', {})
print('yes' if '$NAME' in agents else 'no')
" 2>/dev/null || echo "no"
}

# ─── WK 동기화 ─────────────────────────────────────────────────────────────────
# 서버의 최신 WK로 자동 전환 (orchestrator가 아닌 에이전트용)

_sync_wk() {
  if [[ "$ROLE" == "orchestrator" ]]; then return; fi

  local latest_wk
  latest_wk=$(curl -sf "$HTTP_BASE/api/work-keys/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('work_key',''))" 2>/dev/null || echo "")

  if [[ -n "$latest_wk" && "$latest_wk" != "$WK" ]]; then
    _log "WK 변경 감지: $WK → $latest_wk"
    WK="$latest_wk"
    # config 업데이트
    if [[ -f "$OAH_CONFIG" ]]; then
      python3 -c "
lines = open('$OAH_CONFIG').readlines()
out = []
found = False
for l in lines:
    if l.startswith('WK='):
        out.append('WK=$latest_wk\n')
        found = True
    else:
        out.append(l)
if not found:
    out.append('WK=$latest_wk\n')
open('$OAH_CONFIG', 'w').writelines(out)
"
      _log "config 업데이트: WK=$latest_wk"
    fi
    export WK="$latest_wk"
  fi
}

# ─── 재연결 ────────────────────────────────────────────────────────────────────

_reconnect() {
  if ! _server_ok; then
    _log "⚠ Phoenix 서버 응답 없음 ($HTTP_BASE) — 대기 중..."
    return 1
  fi

  local online; online=$(_agent_online)
  if [[ "$online" == "yes" ]]; then
    _log "✅ $NAME 온라인 확인"
    _sync_wk
    return 0
  fi

  _log "🔄 $NAME 오프라인 감지 — 재연결 시도..."
  _sync_wk

  # oah 데몬이 실행 중인지 확인
  local pid_file="$OAH_DIR/oah.pid"
  if [[ -f "$pid_file" ]]; then
    local pid; pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      _log "⚙ oah 데몬 실행 중 (PID $pid) — presence만 갱신"
      return 0
    fi
  fi

  # 데몬 재시작
  _log "▶ oah 재시작..."
  if command -v oah &>/dev/null; then
    oah start >> "$OAH_LOG" 2>&1 &
    sleep 3
    if [[ "$(_agent_online)" == "yes" ]]; then
      _log "✅ 재연결 성공"
    else
      _log "❌ 재연결 실패"
    fi
  else
    _log "⚠ oah 명령어를 찾을 수 없음 (PATH: $PATH)"
  fi
}

# ─── mailbox 확인 + pending 태스크 수신 ─────────────────────────────────────────

_check_mailbox() {
  local msgs
  msgs=$(curl -sf "$HTTP_BASE/api/mailbox/$NAME" 2>/dev/null || echo "{}")
  local count
  count=$(echo "$msgs" | python3 -c "
import sys,json
print(json.load(sys.stdin).get('count',0))
" 2>/dev/null || echo "0")

  if [[ "$count" -gt 0 ]]; then
    _log "📬 mailbox: $count 개 메시지 수신"
    echo "$msgs" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('messages', []):
    print('  from:', m.get('from','?'), '|', m.get('type','?'), '|', str(m.get('content', m.get('instructions','')))[:80])
"
  fi
}

# ─── 메인 ──────────────────────────────────────────────────────────────────────

CMD="${1:---watch}"

case "$CMD" in
  --once)
    _reconnect
    _check_mailbox
    ;;

  --sync-wk)
    _sync_wk
    echo "현재 WK: $WK"
    ;;

  --status)
    echo "━━━ oah-reconnect 상태 ━━━━━━━━━━━━━━━━━━━━━"
    echo "  에이전트   : $NAME"
    echo "  Phoenix    : $HTTP_BASE"
    echo "  Work Key   : ${WK:-없음}"
    echo "  서버 상태  : $( _server_ok && echo '✅ 온라인' || echo '❌ 오프라인' )"
    echo "  Presence   : $( _agent_online )"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ;;

  --watch|-w|"")
    _log "🚀 oah-reconnect watchdog 시작 (${INTERVAL}초 간격)"
    _log "  에이전트: $NAME | 서버: $HTTP_BASE"
    while true; do
      _reconnect || true
      _check_mailbox || true
      sleep "$INTERVAL"
    done
    ;;

  *)
    echo "사용법: oah-reconnect.sh [--watch|--once|--sync-wk|--status]"
    exit 1
    ;;
esac
