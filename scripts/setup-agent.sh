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

PHOENIX="${1:-${PHOENIX:-}}"
ROLE="${2:-${ROLE:-builder}}"
WK="${3:-${WK:-}}"
DIR="${4:-${DIR:-$(pwd)}}"
NAME="${NAME:-${ROLE}@$(hostname -s 2>/dev/null || hostname)}"

if [[ -z "$PHOENIX" ]]; then
  echo "사용법: oah-agent <phoenix-url> [role] [work-key] [dir]"
  echo "  예시: oah-agent ws://100.64.0.1:4000 builder"
  echo ""
  echo "환경변수: PHOENIX=ws://... ROLE=builder [WK=LN-...] [DIR=/path] oah-agent"
  exit 1
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
    echo "❌ Phoenix 서버 연결 실패: $HTTP_BASE"
    echo "   서버가 실행 중인지, Tailscale이 연결됐는지 확인하세요."
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
  bun run "$DAEMON_ENTRY"
