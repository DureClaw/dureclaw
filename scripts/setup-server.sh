#!/usr/bin/env bash
# setup-server.sh — 한 줄로 Phoenix 서버 설치 + 시작
#
# 사용법 (Linux/Mac):
#   bash scripts/setup-server.sh
#   PORT=4000 bash scripts/setup-server.sh
#
# 환경변수:
#   PORT   리슨 포트 (기본: 4000)
#   HOST   리슨 주소 (기본: 0.0.0.0)

set -euo pipefail

PORT="${PORT:-4000}"
HOST="${HOST:-0.0.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/../packages/phoenix-server" && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " open-agent-harness — Phoenix 서버 설정"
echo " Dir  : $SERVER_DIR"
echo " Port : $PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Elixir 확인 ──────────────────────────────────────────────────────────────

check_elixir() {
  command -v elixir &>/dev/null && elixir --version | grep -q "Elixir 1\." && return 0
  return 1
}

install_elixir_mac() {
  echo "→ Homebrew로 Elixir 설치 중..."
  if ! command -v brew &>/dev/null; then
    echo "❌ Homebrew가 없습니다: https://brew.sh 에서 설치 후 재시도"
    exit 1
  fi
  brew install elixir
}

install_elixir_linux() {
  echo "→ apt로 Elixir 설치 중..."
  # Erlang Solutions 저장소 사용 (최신 Elixir)
  wget -q https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb -O /tmp/erlang-solutions.deb
  sudo dpkg -i /tmp/erlang-solutions.deb
  sudo apt-get update -q
  sudo apt-get install -y esl-erlang elixir
}

install_elixir_asdf() {
  echo "→ asdf로 Elixir 설치 중..."
  if ! command -v asdf &>/dev/null; then
    git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
    echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
    source ~/.bashrc 2>/dev/null || source ~/.asdf/asdf.sh
  fi
  asdf plugin add erlang 2>/dev/null || true
  asdf plugin add elixir 2>/dev/null || true
  asdf install erlang 26.2.5
  asdf install elixir 1.16.3-otp-26
  asdf global erlang 26.2.5
  asdf global elixir 1.16.3-otp-26
}

if check_elixir; then
  echo "✅ $(elixir --version | head -1) (기존)"
else
  OS="$(uname -s)"
  case "$OS" in
    Darwin) install_elixir_mac ;;
    Linux)
      if command -v apt-get &>/dev/null; then
        install_elixir_linux
      else
        install_elixir_asdf
      fi
      ;;
    *)
      echo "❌ 지원되지 않는 OS: $OS"
      echo "   https://elixir-lang.org/install.html 에서 수동 설치 후 재시도"
      exit 1
      ;;
  esac
  echo "✅ $(elixir --version | head -1)"
fi

# ─── Mix 의존성 설치 ──────────────────────────────────────────────────────────

cd "$SERVER_DIR"
echo "→ mix deps.get..."
mix local.hex --force --quiet
mix local.rebar --force --quiet
mix deps.get --quiet
echo "✅ 의존성 설치 완료"

# ─── Tailscale IP 안내 ────────────────────────────────────────────────────────

TAILSCALE_IP=""
if command -v tailscale &>/dev/null; then
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
fi

LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0 2>/dev/null || echo "")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 서버 시작! 다른 머신에서 사용할 주소:"
if [[ -n "$TAILSCALE_IP" ]]; then
  echo ""
  echo "  [Tailscale — 외부 네트워크]"
  echo "  PHOENIX=ws://$TAILSCALE_IP:$PORT"
fi
if [[ -n "$LAN_IP" ]]; then
  echo ""
  echo "  [LAN — 같은 네트워크]"
  echo "  PHOENIX=ws://$LAN_IP:$PORT"
fi
echo ""
echo "  agent 시작 명령 예시:"
echo "  PHOENIX=ws://<위 IP>:$PORT ROLE=builder bash scripts/setup-agent.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── 서버 시작 ────────────────────────────────────────────────────────────────

exec env PORT="$PORT" HOST="$HOST" mix phx.server
