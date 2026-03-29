#!/usr/bin/env bash
# setup-server.sh — OAH Phoenix 서버 1줄 설치 + 시작
#
# 원라인 설치:
#   bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-server.sh)
#
# 환경변수:
#   PORT             리슨 포트 (기본: 4000)
#   HOST             리슨 주소 (기본: 0.0.0.0)
#   OAH_DATA_DIR     데이터 저장 경로 (기본: $HOME/.oah-server/data)
#   OAH_INSTALL_DIR  설치 경로      (기본: $HOME/.oah-server)

set -euo pipefail

OAH_BASE="https://open-agent-harness.baryon.ai"
PORT="${PORT:-4000}"
HOST="${HOST:-0.0.0.0}"
INSTALL_DIR="${OAH_INSTALL_DIR:-$HOME/.oah-server}"
DATA_DIR="${OAH_DATA_DIR:-$INSTALL_DIR/data}"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        ARCH="x86_64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "ERROR: 지원하지 않는 아키텍처: $ARCH"
    exit 1 ;;
esac

TARBALL="oah-server-${OS}-${ARCH}.tar.gz"
TARBALL_URL="$OAH_BASE/$TARBALL"
EXE="$INSTALL_DIR/bin/harness_server"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " OAH Phoenix Server"
echo " Install : $INSTALL_DIR"
echo " Data    : $DATA_DIR"
echo " Port    : $PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── 소스 빌드 (fallback) ──────────────────────────────────────────────────────

_source_build() {
  command -v elixir &>/dev/null || {
    echo "ERROR: Elixir가 없습니다."
    if [[ "$OS" == "darwin" ]]; then
      echo "  brew install elixir"
    else
      echo "  sudo apt install elixir  또는  https://elixir-lang.org/install.html"
    fi
    exit 1
  }
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local SERVER_DIR
  SERVER_DIR="$(cd "$SCRIPT_DIR/../packages/phoenix-server" && pwd)"
  cd "$SERVER_DIR"
  mix local.hex --force --quiet
  mix local.rebar --force --quiet
  MIX_ENV=prod mix deps.get --quiet
  MIX_ENV=prod mix release harness_server --overwrite --quiet
  INSTALL_DIR="$SERVER_DIR/_build/prod/rel/harness_server"
  EXE="$INSTALL_DIR/bin/harness_server"
  echo "✅ 소스 빌드 완료"
}

# ─── 1. 사전 빌드 바이너리 다운로드 ────────────────────────────────────────────

if curl -sf --max-time 5 -I "$TARBALL_URL" | grep -q "200"; then
  if [[ ! -x "$EXE" ]]; then
    echo "→ 서버 다운로드 중... ($TARBALL)"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$TARBALL_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1
    chmod +x "$EXE"
    echo "✅ 설치 완료"
  else
    # 원격 파일 크기로 업데이트 확인
    REMOTE_SIZE=$(curl -sfI --max-time 5 "$TARBALL_URL" | grep -i content-length | awk '{print $2}' | tr -d '\r' || echo "")
    LOCAL_SIZE=$(du -sk "$INSTALL_DIR" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
    if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" -gt "$((LOCAL_SIZE + 2000000))" ]]; then
      echo "→ 새 버전 업데이트 중..."
      curl -fsSL "$TARBALL_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1
      chmod +x "$EXE"
      echo "✅ 업데이트 완료"
    else
      echo "✅ 최신 버전"
    fi
  fi
else
  echo "⚠ 사전 빌드 없음 ($TARBALL) — 소스 빌드 시도..."
  _source_build
fi

# ─── 2. 데이터 디렉토리 준비 ──────────────────────────────────────────────────

mkdir -p "$DATA_DIR"

# ─── 3. 접속 주소 안내 ────────────────────────────────────────────────────────

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || \
         hostname -I 2>/dev/null | awk '{print $1}' || echo "")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 서버 시작! 에이전트 접속 명령:"
[[ -n "$TAILSCALE_IP" ]] && echo "  [Tailscale]  PHOENIX=ws://$TAILSCALE_IP:$PORT bash <(curl -fsSL $OAH_BASE/setup-agent.sh)"
[[ -n "$LAN_IP"       ]] && echo "  [LAN]        PHOENIX=ws://$LAN_IP:$PORT bash <(curl -fsSL $OAH_BASE/setup-agent.sh)"
echo "  [로컬]       PHOENIX=ws://127.0.0.1:$PORT bash <(curl -fsSL $OAH_BASE/setup-agent.sh)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── 4. 서버 실행 (foreground) ────────────────────────────────────────────────

exec env \
  PORT="$PORT" \
  HOST="$HOST" \
  OAH_DATA_DIR="$DATA_DIR" \
  "$EXE" foreground
