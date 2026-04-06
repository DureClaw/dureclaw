#!/usr/bin/env bash
# setup-server.sh — DureClaw Phoenix 서버 1줄 설치 + 시작
#
# 원라인 설치 (Elixir 불필요 — Docker 또는 사전빌드 바이너리 사용):
#   bash <(curl -fsSL https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-server.sh)
#
# 환경변수:
#   PORT             리슨 포트 (기본: 4000)
#   HOST             리슨 주소 (기본: 0.0.0.0)
#   OAH_DATA_DIR     데이터 저장 경로 (기본: $HOME/.oah-server/data)
#   OAH_INSTALL_DIR  설치 경로      (기본: $HOME/.oah-server)
#   USE_DOCKER       docker 강제 사용 (기본: auto)
#
# 실행 우선순위: 사전빌드 바이너리 → Docker → Elixir 소스빌드

set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/DureClaw/dureclaw/main"
GITHUB_RELEASE="https://github.com/DureClaw/dureclaw/releases/latest/download"
OAH_BASE="https://open-agent-harness.baryon.ai"   # legacy fallback
DOCKER_IMAGE="ghcr.io/dureclaw/dureclaw:latest"
PORT="${PORT:-4000}"
HOST="${HOST:-0.0.0.0}"
INSTALL_DIR="${OAH_INSTALL_DIR:-$HOME/.oah-server}"
DATA_DIR="${OAH_DATA_DIR:-$INSTALL_DIR/data}"
USE_DOCKER="${USE_DOCKER:-auto}"
CONTAINER_NAME="dureclaw-server"

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
TARBALL_URL="$GITHUB_RELEASE/$TARBALL"
TARBALL_URL_LEGACY="$OAH_BASE/$TARBALL"
EXE="$INSTALL_DIR/bin/harness_server"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " DureClaw Phoenix Server"
echo " Port    : $PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Tailscale 자동 설치 ──────────────────────────────────────────────────────

_install_tailscale() {
  if [[ "$OS" == "darwin" ]]; then
    if command -v brew &>/dev/null; then
      echo "→ brew로 Tailscale 설치 중..."
      brew install --cask tailscale
      open -a Tailscale 2>/dev/null || true
      echo ""
      echo " ★ 메뉴바의 Tailscale 아이콘을 클릭해 로그인하세요."
      echo "   로그인 완료 후 Enter를 누르세요..."
      read -r
    else
      echo " → Mac App Store에서 Tailscale을 설치하세요:"
      echo "   https://apps.apple.com/app/tailscale/id1475387142"
      open "https://apps.apple.com/app/tailscale/id1475387142" 2>/dev/null || true
      echo ""
      echo "   설치 및 로그인 완료 후 Enter를 누르세요..."
      read -r
    fi
  else
    # Linux: 공식 설치 스크립트 (Ubuntu/Debian/Fedora/CentOS/Arch 등 지원)
    echo "→ Tailscale 설치 중... (sudo 권한 필요)"
    curl -fsSL https://tailscale.com/install.sh | sh
    echo ""
    echo "→ Tailscale 연결 중 (브라우저에서 인증하세요)..."
    if command -v sudo &>/dev/null; then
      sudo tailscale up
    else
      tailscale up
    fi
  fi
}

_ensure_tailscale() {
  # 이미 연결되어 있으면 패스
  if command -v tailscale &>/dev/null; then
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    if [[ -n "$ts_ip" ]]; then
      echo "✅ Tailscale 연결됨: $ts_ip"
      return 0
    fi
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Tailscale 미연결"
  echo " 원격 머신에서 에이전트를 연결하려면 Tailscale이 필요합니다."
  echo " (같은 LAN 내에서만 사용하면 건너뛸 수 있습니다)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # 비대화형 환경(CI, pipe) 이면 자동 건너뜀
  if [[ ! -t 0 ]]; then
    echo "⚠ 비대화형 환경 — Tailscale 설치를 건너뜁니다."
    return 0
  fi

  read -rp " 지금 Tailscale을 설치·연결하시겠습니까? [Y/n] " yn
  [[ "${yn:-Y}" =~ ^[Nn] ]] && {
    echo " → Tailscale 없이 계속합니다. (LAN 주소로만 연결 가능)"
    return 0
  }

  _install_tailscale

  local ts_ip
  ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
  if [[ -n "$ts_ip" ]]; then
    echo "✅ Tailscale 연결 완료: $ts_ip"
  else
    echo "⚠ Tailscale IP를 아직 가져올 수 없습니다. 인증 후 자동으로 할당됩니다."
  fi
}

_ensure_tailscale

# ─── 주소 안내 헬퍼 ───────────────────────────────────────────────────────────

_print_connect_info() {
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
  TAILSCALE_HOST=$(tailscale status --json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
  LAN_IP=$(ipconfig getifaddr en0 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}' || echo "")
  local AGENT_URL="$GITHUB_RAW/scripts/setup-agent.sh"

  echo ""
  if [[ -n "$TAILSCALE_IP" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " ★ Tailscale 사설망 감지 — 원격 에이전트 연결 주소:"
    echo ""
    [[ -n "$TAILSCALE_HOST" ]] && \
    echo "   PHOENIX=ws://$TAILSCALE_HOST:$PORT \\"
    echo "   PHOENIX=ws://$TAILSCALE_IP:$PORT \\"
    echo "     bash <(curl -fsSL $AGENT_URL)"
    echo ""
    echo " → Tailscale 없는 머신은 먼저: https://tailscale.com/download"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " 서버 시작! 에이전트 접속 명령:"
    [[ -n "$LAN_IP" ]] && \
    echo "  [LAN]   PHOENIX=ws://$LAN_IP:$PORT bash <(curl -fsSL $AGENT_URL)"
    echo "  [로컬]  PHOENIX=ws://127.0.0.1:$PORT bash <(curl -fsSL $AGENT_URL)"
    echo ""
    echo " 원격 연결을 원하면: https://tailscale.com (무료, 100대)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
  echo ""
}

# ─── Docker 실행 ─────────────────────────────────────────────────────────────

_docker_run() {
  echo "→ Docker로 DureClaw 서버 시작..."
  mkdir -p "$DATA_DIR"

  # 기존 컨테이너 정리
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  # 이미지 pull (없으면)
  docker image inspect "$DOCKER_IMAGE" &>/dev/null || \
    docker pull "$DOCKER_IMAGE"

  _print_connect_info

  echo "→ 컨테이너 시작: $CONTAINER_NAME"
  exec docker run --rm \
    --name "$CONTAINER_NAME" \
    -p "${PORT}:4000" \
    -v "$DATA_DIR:/data" \
    -e PORT=4000 \
    -e HOST=0.0.0.0 \
    -e OAH_DATA_DIR=/data \
    "$DOCKER_IMAGE"
}

# ─── 소스 빌드 (last resort) ─────────────────────────────────────────────────

_source_build() {
  command -v elixir &>/dev/null || {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Elixir 없음 → Docker로 실행하세요 (권장):"
    echo ""
    echo "   curl -fsSL $GITHUB_RAW/scripts/setup-server.sh | USE_DOCKER=1 bash"
    echo ""
    echo " 또는 Docker 설치: https://docs.docker.com/get-docker/"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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

# ─── 1. Docker 강제 모드 ─────────────────────────────────────────────────────

if [[ "$USE_DOCKER" == "1" || "$USE_DOCKER" == "true" ]]; then
  command -v docker &>/dev/null || { echo "ERROR: Docker가 없습니다. https://docs.docker.com/get-docker/"; exit 1; }
  _docker_run
fi

# ─── 2. 사전 빌드 바이너리 다운로드 (GitHub Releases) ───────────────────────────

_download_binary() {
  local URL="$1"
  echo "→ 서버 다운로드 중... ($TARBALL)"
  mkdir -p "$INSTALL_DIR"
  curl -fsSL --location "$URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1
  chmod +x "$EXE"
  echo "✅ 설치 완료"
}

# GitHub Releases 우선, 레거시 fallback
AVAILABLE_URL=""
if curl -sf --max-time 8 -I -L "$TARBALL_URL" 2>/dev/null | grep -q "200"; then
  AVAILABLE_URL="$TARBALL_URL"
elif curl -sf --max-time 5 -I "$TARBALL_URL_LEGACY" 2>/dev/null | grep -q "200"; then
  AVAILABLE_URL="$TARBALL_URL_LEGACY"
fi

if [[ -n "$AVAILABLE_URL" ]]; then
  if [[ ! -x "$EXE" ]]; then
    _download_binary "$AVAILABLE_URL"
  else
    REMOTE_SIZE=$(curl -sfI --max-time 5 -L "$AVAILABLE_URL" | grep -i content-length | tail -1 | awk '{print $2}' | tr -d '\r' || echo "")
    LOCAL_SIZE=$(du -sk "$INSTALL_DIR" 2>/dev/null | awk '{print $1 * 1024}' || echo "0")
    if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" -gt "$((LOCAL_SIZE + 2000000))" ]]; then
      echo "→ 새 버전 업데이트 중..."
      _download_binary "$AVAILABLE_URL"
    else
      echo "✅ 최신 버전 ($EXE)"
    fi
  fi

# ─── 3. Docker fallback (Elixir 없을 때) ────────────────────────────────────

elif command -v docker &>/dev/null && [[ "$USE_DOCKER" != "0" ]]; then
  echo "⚠ 사전 빌드 없음 → Docker로 시작합니다... (Elixir 불필요)"
  _docker_run

# ─── 4. Elixir 소스빌드 (마지막 수단) ──────────────────────────────────────

else
  echo "⚠ 사전 빌드 없음 — 소스 빌드 시도..."
  _source_build
fi

# ─── 데이터 디렉토리 + 주소 안내 + 실행 (바이너리 경로) ─────────────────────

mkdir -p "$DATA_DIR"
_print_connect_info

exec env \
  PORT="$PORT" \
  HOST="$HOST" \
  OAH_DATA_DIR="$DATA_DIR" \
  "$EXE" foreground
