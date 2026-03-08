#!/usr/bin/env bash
# setup-agent.sh — 한 줄로 agent-daemon 설치 + 시작
#
# 사용법:
#   PHOENIX=ws://100.x.x.x:4000 ROLE=builder bash scripts/setup-agent.sh
#   PHOENIX=ws://100.x.x.x:4000 ROLE=builder WK=LN-20260308-001 bash scripts/setup-agent.sh
#
# 환경변수:
#   PHOENIX   Phoenix 서버 주소 (필수)  예: ws://100.64.0.1:4000
#   ROLE      에이전트 역할 (기본: builder)  orchestrator|builder|verifier|reviewer
#   WK        Work Key (선택 — 생략 시 자동 감지)
#   DIR       프로젝트 경로 (기본: 현재 디렉토리)
#   NAME      에이전트 이름 (기본: role@hostname)
#   REPO      git 저장소 URL (daemon 코드 없을 때만 사용)

set -euo pipefail

PHOENIX="${PHOENIX:?'PHOENIX 환경변수가 필요합니다. 예: PHOENIX=ws://100.x.x.x:4000'}"
ROLE="${ROLE:-builder}"
DIR="${DIR:-$(pwd)}"
NAME="${NAME:-${ROLE}@$(hostname -s)}"
REPO="${REPO:-}"

HTTP_BASE="${PHOENIX/ws:/http:}"
HTTP_BASE="${HTTP_BASE/wss:/https:}"

# 레포 내에서 실행 중인지 먼저 확인 (scripts/../packages/agent-daemon/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DAEMON="$SCRIPT_DIR/../packages/agent-daemon/src/index.ts"
if [[ -f "$REPO_DAEMON" ]]; then
  DAEMON_ENTRY="$(cd "$SCRIPT_DIR/.." && pwd)/packages/agent-daemon/src/index.ts"
else
  DAEMON_DIR="${OPEN_AGENT_DIR:-$HOME/.open-agent-harness}"
  DAEMON_ENTRY="$DAEMON_DIR/packages/agent-daemon/src/index.ts"
fi

print_banner() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " open-agent-harness — agent setup"
  echo " Role  : $ROLE"
  echo " Name  : $NAME"
  echo " Server: $PHOENIX"
  echo " Dir   : $DIR"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── 1. Bun 설치 ──────────────────────────────────────────────────────────────

install_bun() {
  echo "→ Bun 설치 중..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  echo "✅ Bun $(bun --version)"
}

if ! command -v bun &>/dev/null; then
  install_bun
else
  # bun이 있어도 PATH에 없을 수 있음
  export PATH="$HOME/.bun/bin:$PATH"
  echo "✅ Bun $(bun --version) (기존)"
fi

# ─── 2. OpenCode 설치 ─────────────────────────────────────────────────────────

install_opencode() {
  echo "→ OpenCode 설치 중..."
  curl -fsSL https://opencode.ai/install | bash
  export PATH="$HOME/.opencode/bin:$PATH"
  echo "✅ OpenCode $(opencode --version)"
}

if ! command -v opencode &>/dev/null; then
  install_opencode
else
  export PATH="$HOME/.opencode/bin:$PATH"
  echo "✅ OpenCode $(opencode --version) (기존)"
fi

# ─── 3. agent-daemon 코드 확보 ────────────────────────────────────────────────

if [[ -f "$DAEMON_ENTRY" ]]; then
  echo "✅ agent-daemon 코드 확인"
elif [[ -n "$REPO" ]]; then
  DAEMON_DIR="${OPEN_AGENT_DIR:-$HOME/.open-agent-harness}"
  DAEMON_ENTRY="$DAEMON_DIR/packages/agent-daemon/src/index.ts"
  echo "→ 저장소 클론 중: $REPO → $DAEMON_DIR"
  git clone --depth=1 "$REPO" "$DAEMON_DIR"
  echo "✅ 클론 완료"
else
  echo ""
  echo "❌ agent-daemon 코드를 찾을 수 없습니다."
  echo ""
  echo "REPO 변수로 저장소를 지정하세요:"
  echo "  REPO=https://github.com/.../open-agent-harness.git \\"
  echo "  PHOENIX=$PHOENIX ROLE=$ROLE bash <(curl -fsSL <SCRIPT_URL>)"
  exit 1
fi

# ─── 4. Phoenix 서버 연결 확인 ────────────────────────────────────────────────

echo "→ Phoenix 서버 연결 확인: $HTTP_BASE/api/health"
for i in 1 2 3 4 5; do
  if curl -sf "$HTTP_BASE/api/health" > /dev/null 2>&1; then
    echo "✅ Phoenix 서버 응답 확인"
    break
  fi
  if [[ $i -eq 5 ]]; then
    echo "❌ Phoenix 서버에 연결할 수 없습니다: $HTTP_BASE"
    echo "   서버가 실행 중인지, Tailscale이 연결됐는지 확인하세요."
    exit 1
  fi
  echo "  재시도 $i/5..."
  sleep 2
done

# ─── 5. Work Key 처리 ─────────────────────────────────────────────────────────

# WK 미설정 + orchestrator 역할: 새로 생성
# WK 미설정 + 다른 역할: 자동 감지 (daemon이 처리)
if [[ -z "${WK:-}" ]] && [[ "$ROLE" == "orchestrator" ]]; then
  WK=$(curl -sf -X POST "$HTTP_BASE/api/work-keys" | python3 -c "import sys,json; print(json.load(sys.stdin)['work_key'])")
  echo "✅ Work Key 생성: $WK"
  echo ""
  echo "  👉 다른 머신에서 이 WK를 사용하려면:"
  echo "     PHOENIX=$PHOENIX ROLE=builder WK=$WK DIR=$DIR bash scripts/setup-agent.sh"
  echo ""
fi

# ─── 6. 시작 ──────────────────────────────────────────────────────────────────

print_banner

exec env \
  STATE_SERVER="$PHOENIX" \
  AGENT_NAME="$NAME" \
  AGENT_ROLE="$ROLE" \
  WORK_KEY="${WK:-}" \
  PROJECT_DIR="$DIR" \
  bun run "$DAEMON_ENTRY"
