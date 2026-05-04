#!/usr/bin/env bash
# DureClaw — 올인원 설치 스크립트
#
# 한 줄로 서버 + MCP + Tailscale 안내까지:
#   bash <(curl -fsSL https://dureclaw.baryon.ai/install)
#
# 순서:
#   1. Phoenix 서버 백그라운드 데몬으로 시작
#   2. OAH_SECRET 자동 획득
#   3. Claude Code MCP 등록 (claude mcp add oah)
#   4. Tailscale 보안 안내/설치 (옵션, 권장)
#   5. 원격 에이전트 연결 명령어 출력
#
# 환경변수:
#   PORT=4000          서버 포트 (기본 4000)
#   SKIP_TAILSCALE=1   Tailscale 설정 건너뜀
#   SKIP_MCP=1         Claude Code MCP 등록 건너뜀

set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/DureClaw/dureclaw/main"
PORT="${PORT:-4000}"
INSTALL_DIR="${OAH_INSTALL_DIR:-$HOME/.oah-server}"
DATA_DIR="${OAH_DATA_DIR:-$INSTALL_DIR/data}"
SECRET_FILE="$DATA_DIR/server.secret"
SKIP_TAILSCALE="${SKIP_TAILSCALE:-0}"
SKIP_MCP="${SKIP_MCP:-0}"

_bold()  { printf "\033[1m%s\033[0m" "$*"; }
_cyan()  { printf "\033[36m%s\033[0m" "$*"; }
_green() { printf "\033[32m%s\033[0m" "$*"; }
_yellow(){ printf "\033[33m%s\033[0m" "$*"; }
_dim()   { printf "\033[2m%s\033[0m" "$*"; }

echo ""
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
_bold " DureClaw — AI 에이전트 팀 설치"
echo ""
echo "  Claude Code를 오케스트레이터로,"
echo "  내 모든 머신을 하나의 팀으로."
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
echo ""

# ─── 헬퍼 ────────────────────────────────────────────────────────────────────

_server_healthy() {
  curl -sf "http://localhost:$PORT/api/health" > /dev/null 2>&1
}

_ts_ip() {
  tailscale ip -4 2>/dev/null || echo ""
}

# ─── Step 1: Phoenix 서버 ─────────────────────────────────────────────────────

echo "$(_bold '[1/4]') Phoenix 서버"

if _server_healthy; then
  echo "  $(_green '✅') 이미 실행 중 (http://localhost:$PORT)"
else
  echo "  → 서버를 백그라운드로 시작합니다..."
  # DAEMON=1: setup-server.sh 에서 exec start 대신 daemon 모드로 실행
  curl -fsSL "$GITHUB_RAW/scripts/setup-server.sh" \
    | DAEMON=1 PORT="$PORT" SKIP_TAILSCALE=1 bash &
  SERVER_SETUP_PID=$!

  # 서버 준비 대기 (최대 30초)
  echo -n "  → 준비 대기 중 "
  READY=0
  for i in $(seq 1 30); do
    if _server_healthy; then
      READY=1; break
    fi
    printf "."
    sleep 1
  done
  echo ""

  # setup 프로세스 정리
  wait "$SERVER_SETUP_PID" 2>/dev/null || true

  if [[ $READY -eq 0 ]]; then
    echo "  $(_yellow '⚠') 30초 내에 서버가 응답하지 않습니다."
    echo "     수동으로 서버를 시작하고 다시 실행하세요:"
    echo "     bash <(curl -fsSL https://dureclaw.baryon.ai/server)"
    exit 1
  fi
  echo "  $(_green '✅') 서버 시작 완료 (http://localhost:$PORT)"
fi
echo ""

# ─── Step 2: OAH_SECRET ──────────────────────────────────────────────────────

echo "$(_bold '[2/4]') 보안 키"

OAH_SECRET=""
if [[ -f "$SECRET_FILE" ]]; then
  OAH_SECRET=$(tr -d '[:space:]' < "$SECRET_FILE")
  echo "  $(_green '✅') OAH_SECRET 로드 $(_dim "($(basename "$SECRET_FILE")")")"
else
  echo "  $(_yellow '⚠') 시크릿 파일 없음: $SECRET_FILE"
  echo "     서버 실행 후 자동 생성됩니다. 수동 지정:"
  echo "     OAH_SECRET=<값> bash <(curl -fsSL https://dureclaw.baryon.ai/install)"
fi
echo ""

# ─── Step 3: Claude Code MCP 등록 ────────────────────────────────────────────

echo "$(_bold '[3/4]') Claude Code MCP 등록"

if [[ "$SKIP_MCP" == "1" ]]; then
  echo "  $(_dim '(건너뜀 — SKIP_MCP=1)')"
elif ! command -v claude &>/dev/null; then
  echo "  $(_yellow '⚠') Claude Code가 설치되어 있지 않습니다."
  echo "     설치 후 별도 실행: bash <(curl -fsSL https://dureclaw.baryon.ai/mcp)"
else
  # Phoenix URL: Tailscale IP > localhost
  TS=$(tailscale ip -4 2>/dev/null || echo "")
  PHOENIX_URL="${TS:+ws://$TS:$PORT}"
  PHOENIX_URL="${PHOENIX_URL:-ws://localhost:$PORT}"
  MACHINE=$(hostname -s 2>/dev/null || hostname)
  AGENT_NAME="orchestrator@${MACHINE}"

  ENV_VARS="PHOENIX_URL=$PHOENIX_URL AGENT_NAME=$AGENT_NAME SKIP_TAILSCALE=1"
  [[ -n "$OAH_SECRET" ]] && ENV_VARS="$ENV_VARS OAH_SECRET=$OAH_SECRET"

  if env $ENV_VARS bash <(curl -fsSL "$GITHUB_RAW/scripts/setup-mcp.sh"); then
    echo "  $(_green '✅') MCP 등록 완료"
  else
    echo "  $(_yellow '⚠') MCP 등록 실패. 수동: bash <(curl -fsSL https://dureclaw.baryon.ai/mcp)"
  fi
fi
echo ""

# ─── Step 4: Tailscale ────────────────────────────────────────────────────────

echo "$(_bold '[4/4]') Tailscale 보안 설정"

TS_IP=$(_ts_ip)
if [[ -n "$TS_IP" ]]; then
  echo "  $(_green '✅') Tailscale 연결됨: $TS_IP"
elif [[ "$SKIP_TAILSCALE" == "1" ]]; then
  echo "  $(_dim '(건너뜀 — SKIP_TAILSCALE=1)')"
else
  printf "  %s\n" "$(cat <<'MSG'
  ┌──────────────────────────────────────────────────────────┐
  │  Tailscale — 원격 머신 연결을 위한 보안 사설망            │
  │  무료 · 최대 100대 · WireGuard 기반 암호화               │
  │  https://tailscale.com/download                          │
  │                                                          │
  │  ℹ  같은 LAN 내에서만 사용하면 없어도 됩니다.             │
  └──────────────────────────────────────────────────────────┘
MSG
)"

  if [[ -t 0 ]]; then
    read -rp "  지금 Tailscale을 설치하시겠습니까? [Y/n] " yn
    if [[ ! "${yn:-Y}" =~ ^[Nn] ]]; then
      if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
        brew install --cask tailscale
        open -a Tailscale 2>/dev/null || true
        echo "  → 메뉴바 Tailscale 아이콘으로 로그인 후 Enter를 누르세요..."
        read -r _
      else
        curl -fsSL https://tailscale.com/install.sh | sh
        tailscale up
      fi
      TS_IP=$(_ts_ip)
    fi
  fi
fi
echo ""

# ─── 완료 안내 ────────────────────────────────────────────────────────────────

CONNECT_IP="${TS_IP:-localhost}"
AGENT_URL="https://dureclaw.baryon.ai/agent"
SECRET_PART=""
[[ -n "$OAH_SECRET" ]] && SECRET_PART=" OAH_SECRET='$OAH_SECRET'"

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
_green "✅ DureClaw 설치 완료!"
echo ""
echo "  대시보드:  http://localhost:$PORT"
echo ""
echo "  에이전트 연결 — 다른 머신에서 실행:"
echo ""
_cyan "  PHOENIX=ws://$CONNECT_IP:$PORT$SECRET_PART \\"
echo ""
_cyan "    bash <(curl -fsSL $AGENT_URL)"
echo ""
if [[ -n "$OAH_SECRET" ]]; then
  _dim "  ※ OAH_SECRET은 위 에이전트 명령에 포함되었습니다."
  echo ""
fi
echo "  Claude Code에서 팀 실행:"
_cyan "  /dureclaw"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
echo ""
