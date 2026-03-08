#!/usr/bin/env bash
# open-agent-harness — standalone installer
#
# GitHub 계정 없이 설치 가능 (git 불필요)
#
# 설치:
#   curl -fsSL https://baryonlabs.github.io/open-agent-harness/install.sh | bash
#
# 설치 후:
#   oah-server                                    # Phoenix 서버 시작
#   oah-agent ws://100.x.x.x:4000 builder        # 에이전트 시작

set -euo pipefail

PAGES_BASE="https://baryonlabs.github.io/open-agent-harness"
OAH_DIR="$HOME/.open-agent-harness"
BIN_DIR="$HOME/.local/bin"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " open-agent-harness 설치"
echo " 설치 경로: $OAH_DIR"
echo " 커맨드 위치: $BIN_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── 1. 디렉토리 생성 ────────────────────────────────────────────────────────

mkdir -p "$OAH_DIR" "$BIN_DIR"

# ─── 2. agent-daemon.ts 다운로드 ─────────────────────────────────────────────

echo "→ agent-daemon.ts 다운로드 중..."
curl -fsSL "$PAGES_BASE/agent-daemon.ts" -o "$OAH_DIR/agent-daemon.ts"
echo "✅ agent-daemon.ts 완료"

# ─── 3. oah-agent 커맨드 생성 ────────────────────────────────────────────────

cat > "$BIN_DIR/oah-agent" << 'AGENT_SCRIPT'
#!/usr/bin/env bash
# oah-agent — open-agent-harness agent launcher
#
# 사용법:
#   oah-agent <phoenix-url> [role] [work-key] [project-dir]
#
# 예시:
#   oah-agent ws://100.64.0.1:4000 builder
#   oah-agent ws://100.64.0.1:4000 orchestrator .
#   oah-agent ws://100.64.0.1:4000 builder LN-20260308-001 /path/to/project

set -euo pipefail

PHOENIX="${1:-${PHOENIX:-}}"
ROLE="${2:-${ROLE:-builder}}"
WK="${3:-${WK:-}}"
DIR="${4:-${DIR:-$(pwd)}}"
NAME="${NAME:-${ROLE}@$(hostname -s 2>/dev/null || hostname)}"
OAH_DIR="$HOME/.open-agent-harness"
DAEMON="$OAH_DIR/agent-daemon.ts"

if [[ -z "$PHOENIX" ]]; then
  echo "사용법: oah-agent <phoenix-url> [role] [wk] [dir]"
  echo "  예시: oah-agent ws://100.64.0.1:4000 builder"
  echo ""
  echo "환경변수: PHOENIX=ws://... ROLE=builder [WK=LN-...] [DIR=/path] oah-agent"
  exit 1
fi

HTTP_BASE="${PHOENIX/ws:/http:}"
HTTP_BASE="${HTTP_BASE/wss:/https:}"

# ─── Bun 설치 확인 ──────────────────────────────────────────────────────────

export PATH="$HOME/.bun/bin:$PATH"
if ! command -v bun &>/dev/null; then
  echo "→ Bun 설치 중..."
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi

# ─── OpenCode 설치 확인 ─────────────────────────────────────────────────────

export PATH="$HOME/.opencode/bin:$PATH"
if ! command -v opencode &>/dev/null; then
  echo "→ OpenCode 설치 중..."
  curl -fsSL https://opencode.ai/install | bash
  export PATH="$HOME/.opencode/bin:$PATH"
fi

# ─── daemon.ts 최신 버전 확인 (자동 업데이트) ───────────────────────────────

PAGES_BASE="https://baryonlabs.github.io/open-agent-harness"
if [[ ! -f "$DAEMON" ]]; then
  echo "→ agent-daemon.ts 다운로드 중..."
  curl -fsSL "$PAGES_BASE/agent-daemon.ts" -o "$DAEMON"
fi

# ─── Phoenix 서버 연결 확인 ─────────────────────────────────────────────────

for i in 1 2 3 4 5; do
  if curl -sf "$HTTP_BASE/api/health" > /dev/null 2>&1; then break; fi
  if [[ $i -eq 5 ]]; then
    echo "❌ Phoenix 서버 연결 실패: $HTTP_BASE"
    echo "   서버가 실행 중인지, Tailscale이 연결됐는지 확인하세요."
    exit 1
  fi
  echo "→ Phoenix 서버 대기 중... ($i/5)"
  sleep 2
done

# ─── Work Key 처리 (orchestrator는 자동 생성) ────────────────────────────────

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

# ─── 실행 ───────────────────────────────────────────────────────────────────

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
  bun run "$DAEMON"
AGENT_SCRIPT

chmod +x "$BIN_DIR/oah-agent"
echo "✅ oah-agent 완료"

# ─── 4. oah-server 커맨드 생성 ───────────────────────────────────────────────

cat > "$BIN_DIR/oah-server" << 'SERVER_SCRIPT'
#!/usr/bin/env bash
# oah-server — Phoenix 서버 launcher
#
# 사용법:
#   oah-server          # 포트 4000 (기본값)
#   PORT=8080 oah-server

set -euo pipefail

PORT="${PORT:-4000}"
OAH_DIR="$HOME/.open-agent-harness"
OAH_REPO="https://github.com/baryonlabs/open-agent-harness.git"
SERVER_DIR="$OAH_DIR/phoenix-server"

# ─── 서버 소스 준비 ─────────────────────────────────────────────────────────

if [[ ! -d "$SERVER_DIR" ]]; then
  echo "→ Phoenix 서버 소스 다운로드 중..."
  if command -v git &>/dev/null; then
    REPO_DIR="$OAH_DIR/repo"
    if [[ -d "$REPO_DIR/.git" ]]; then
      git -C "$REPO_DIR" pull --ff-only --quiet
    else
      git clone --depth=1 "$OAH_REPO" "$REPO_DIR"
    fi
    cp -r "$REPO_DIR/packages/phoenix-server" "$SERVER_DIR"
    echo "✅ 서버 소스 준비 완료"
  else
    echo "❌ git이 필요합니다."
    echo "   Mac:   brew install git"
    echo "   Linux: sudo apt-get install git"
    exit 1
  fi
fi

# ─── Elixir/Mix 확인 ────────────────────────────────────────────────────────

if ! command -v mix &>/dev/null; then
  echo "→ Elixir 설치 중..."
  if command -v brew &>/dev/null; then
    brew install elixir
  elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y elixir
  elif command -v asdf &>/dev/null; then
    asdf plugin add erlang || true
    asdf plugin add elixir || true
    asdf install erlang latest
    asdf install elixir latest
    asdf global elixir latest
  else
    echo "❌ Elixir를 수동으로 설치하세요: https://elixir-lang.org/install.html"
    exit 1
  fi
fi

# ─── 의존성 설치 및 서버 시작 ───────────────────────────────────────────────

cd "$SERVER_DIR"
mix local.hex --force --if-missing --quiet
mix local.rebar --force --if-missing --quiet

if [[ ! -d deps ]]; then
  echo "→ 의존성 설치 중..."
  mix deps.get --quiet
fi

# 로컬 IP 출력
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " oah-server | Phoenix"
echo " Port  → $PORT"
[[ -n "${LOCAL_IP:-}" ]] && echo " LAN   → http://$LOCAL_IP:$PORT"
echo " API   → http://localhost:$PORT/api/health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exec env PORT="$PORT" mix phx.server
SERVER_SCRIPT

chmod +x "$BIN_DIR/oah-server"
echo "✅ oah-server 완료"

# ─── 5. PATH 등록 ─────────────────────────────────────────────────────────────

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
added_to=()

for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  if [[ -f "$rc" ]]; then
    if ! grep -qF '.local/bin' "$rc"; then
      echo "" >> "$rc"
      echo "# open-agent-harness" >> "$rc"
      echo "$PATH_LINE" >> "$rc"
      added_to+=("$rc")
    fi
  fi
done

export PATH="$BIN_DIR:$PATH"

# ─── 완료 메시지 ──────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ 설치 완료!"
echo ""
echo " 커맨드:"
echo "   oah-server                            Phoenix 서버 시작"
echo "   oah-agent <url> [role] [wk] [dir]    에이전트 시작"
echo ""
echo " 예시:"
echo "   oah-server"
echo "   oah-agent ws://100.64.0.1:4000 orchestrator ."
echo "   oah-agent ws://100.64.0.1:4000 builder"
echo ""
if [[ ${#added_to[@]} -gt 0 ]]; then
  echo " PATH 추가됨: ${added_to[*]}"
  echo " 새 터미널에서 또는 다음 명령으로 즉시 사용:"
  echo "   source ~/.zshrc   # (또는 ~/.bashrc)"
  echo ""
fi
echo " 업데이트:"
echo "   curl -fsSL https://baryonlabs.github.io/open-agent-harness/install.sh | bash"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
