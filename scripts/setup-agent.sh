#!/usr/bin/env bash
# oah-agent — open-agent-harness agent daemon launcher
#
# 사용법 (포지셔널):
#   oah-agent <phoenix-url> [role] [work-key] [project-dir]
#
# 사용법 (환경변수):
#   PHOENIX=ws://... ROLE=builder [WK=...] [DIR=...] oah-agent
#
# 예시:
#   oah-agent ws://100.64.0.1:4000 builder
#   oah-agent ws://100.64.0.1:4000 orchestrator .
#   oah-agent ws://100.64.0.1:4000 builder LN-20260308-001 /path/to/project

set -euo pipefail

OAH_REPO="https://github.com/baryonlabs/open-agent-harness.git"
OAH_DIR="${OPEN_AGENT_DIR:-$HOME/.open-agent-harness}"

# ─── 인수 파싱 (포지셔널 우선, 환경변수 fallback) ─────────────────────────────

ROLE="${2:-${ROLE:-builder}}"
WK="${3:-${WK:-}}"
DIR="${4:-${DIR:-$(pwd)}}"
NAME="${NAME:-${ROLE}@$(hostname -s 2>/dev/null || hostname)}"

# ─── Tailscale 피어 TUI ────────────────────────────────────────────────────────

_ts_online_peers() {
  local ts
  ts=$(command -v tailscale 2>/dev/null) || return
  "$ts" status --json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for v in (data.get('Peer') or {}).values():
    if v.get('Online'):
        ips = v.get('TailscaleIPs', [])
        ip = ips[0] if ips else ''
        print(v.get('HostName','?') + '  [' + ip + ']|ws://' + ip + ':4000')
" 2>/dev/null
}

_ts_tui() {
  local IFS=$'\n'
  local lines=()
  while read -r line; do lines+=("$line"); done < <(_ts_online_peers)
  [[ ${#lines[@]} -eq 0 ]] && return 1

  local idx=0
  tput civis 2>/dev/null
  trap 'tput cnorm 2>/dev/null' EXIT INT

  while true; do
    tput clear 2>/dev/null || clear
    echo ""
    echo "  OAH  Connect to Server"
    echo "  ──────────────────────────────────────"
    echo ""
    for i in "${!lines[@]}"; do
      local label="${lines[$i]%%|*}"
      if [[ $i -eq $idx ]]; then
        printf "  \033[1;32m> %s\033[0m\n" "$label"
      else
        printf "    %s\n" "$label"
      fi
    done
    echo ""
    echo "  [↑/↓] select   [Enter] connect   [q] quit"

    local key
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        IFS= read -rsn2 -t 0.1 key
        case "$key" in
          '[A') [[ $idx -gt 0 ]] && ((idx--)) ;;
          '[B') [[ $idx -lt $((${#lines[@]}-1)) ]] && ((idx++)) ;;
        esac ;;
      '') # Enter
        tput cnorm 2>/dev/null
        PHOENIX="${lines[$idx]#*|}"
        return 0 ;;
      q|Q)
        tput cnorm 2>/dev/null
        return 2 ;;
    esac
  done
}

# ─── 서버 자동 탐색 ───────────────────────────────────────────────────────────

PHOENIX="${1:-${PHOENIX:-}}"

if [[ -z "$PHOENIX" ]]; then
  # 1) oah.local 시도
  if curl -sf --max-time 3 "http://oah.local:4000/api/health" > /dev/null 2>&1; then
    PHOENIX="ws://oah.local:4000"
    echo "→ oah.local 연결됨"
  else
    # 2) Tailscale TUI
    if command -v tailscale &>/dev/null; then
      if ! _ts_tui; then
        echo ""
        echo "서버를 찾을 수 없습니다. 직접 지정:"
        echo "  PHOENIX=ws://<서버IP>:4000 bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)"
        exit 1
      fi
    else
      echo "FAILED: oah.local 연결 실패, Tailscale 도 없습니다."
      echo ""
      echo "서버 IP 를 직접 지정하세요:"
      echo "  PHOENIX=ws://<서버IP>:4000 bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)"
      exit 1
    fi
  fi
fi

HTTP_BASE="${PHOENIX/ws:/http:}"
HTTP_BASE="${HTTP_BASE/wss:/https:}"

# ─── 레포 경로 결정 (설치된 경로 → 로컬 레포 → 클론) ─────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../packages/agent-daemon/src/index.ts" ]]; then
  # 레포 안에서 직접 실행
  DAEMON_ENTRY="$(cd "$SCRIPT_DIR/.." && pwd)/packages/agent-daemon/src/index.ts"
elif [[ -f "$OAH_DIR/packages/agent-daemon/src/index.ts" ]]; then
  # 전역 설치 경로
  DAEMON_ENTRY="$OAH_DIR/packages/agent-daemon/src/index.ts"
else
  echo "→ open-agent-harness 다운로드 중..."
  git clone --depth=1 "$OAH_REPO" "$OAH_DIR"
  DAEMON_ENTRY="$OAH_DIR/packages/agent-daemon/src/index.ts"
fi

# ─── 1. Bun ───────────────────────────────────────────────────────────────────

export PATH="$HOME/.bun/bin:$PATH"
if ! command -v bun &>/dev/null; then
  echo "→ Bun 설치 중..."
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi

# ─── 2. OpenCode ──────────────────────────────────────────────────────────────

export PATH="$HOME/.opencode/bin:$PATH"
if ! command -v opencode &>/dev/null; then
  echo "→ OpenCode 설치 중..."
  curl -fsSL https://opencode.ai/install | bash
  export PATH="$HOME/.opencode/bin:$PATH"
fi

# ─── 3. Phoenix 서버 연결 확인 ────────────────────────────────────────────────

for i in 1 2 3 4 5; do
  if curl -sf "$HTTP_BASE/api/health" > /dev/null 2>&1; then break; fi
  if [[ $i -eq 5 ]]; then
    echo "FAILED: Phoenix server unreachable: $HTTP_BASE"
    exit 1
  fi
  echo "→ Phoenix 서버 대기 중... ($i/5)"
  sleep 2
done

# ─── 4. Work Key (orchestrator는 생성, 나머지는 daemon이 auto-discover) ────────

if [[ -z "$WK" ]] && [[ "$ROLE" == "orchestrator" ]]; then
  WK=$(curl -sf -X POST "$HTTP_BASE/api/work-keys" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['work_key'])")
  echo ""
  echo "┌─────────────────────────────────────────────────┐"
  echo "│  Work Key: $WK"
  echo "│"
  echo "│  다른 머신에서 연결:                            │"
  echo "│  oah-agent $PHOENIX builder $WK"
  echo "└─────────────────────────────────────────────────┘"
  echo ""
fi

# ─── 5. 실행 ──────────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " oah-agent  ${ROLE}@$(hostname -s 2>/dev/null || hostname)"
echo " server  →  $PHOENIX"
echo " dir     →  $DIR"
[[ -n "$WK" ]] && echo " work-key→  $WK"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exec env \
  STATE_SERVER="$PHOENIX" \
  AGENT_NAME="$NAME" \
  AGENT_ROLE="$ROLE" \
  WORK_KEY="${WK:-}" \
  PROJECT_DIR="$DIR" \
  bun run "$DAEMON_ENTRY" "$PHOENIX"
