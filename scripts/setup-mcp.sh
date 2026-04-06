#!/usr/bin/env bash
# setup-mcp.sh — DureClaw MCP를 Claude Code에 한 번에 등록
#
# 사용법:
#   # 원클릭 (저장소 클론 없이)
#   curl -fsSL https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-mcp.sh \
#     | PHOENIX_URL=ws://host:4000 bash
#
#   # 로컬 클론 후
#   bash scripts/setup-mcp.sh
#   bash scripts/setup-mcp.sh --phoenix ws://192.168.0.10:4000 --name orchestrator@mymac

set -euo pipefail

OAH_DIR="$HOME/.oah"
MCP_DIR="$OAH_DIR/mcp"
MCP_REPO="https://raw.githubusercontent.com/DureClaw/dureclaw/main"

# ─── 인자 파싱 ────────────────────────────────────────────────────────────────

PHOENIX_URL="${PHOENIX_URL:-}"
AGENT_NAME="${AGENT_NAME:-}"
AGENT_ROLE="${AGENT_ROLE:-orchestrator}"
SCOPE="${SCOPE:-user}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phoenix|-p) PHOENIX_URL="$2"; shift 2 ;;
    --name|-n)    AGENT_NAME="$2";  shift 2 ;;
    --role|-r)    AGENT_ROLE="$2";  shift 2 ;;
    --scope|-s)   SCOPE="$2";       shift 2 ;;
    *) echo "알 수 없는 옵션: $1"; exit 1 ;;
  esac
done

echo "━━━ DureClaw MCP 설치 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── 사전 확인 ────────────────────────────────────────────────────────────────

check() {
  if ! command -v "$1" &>/dev/null; then
    echo "❌ '$1'을 찾을 수 없습니다. $2"
    exit 1
  fi
}

check claude "Claude Code 설치: https://claude.ai/code"
check bun    "Bun 설치: curl -fsSL https://bun.sh/install | bash"

echo "✅ 사전 요구사항 확인 완료"

# ─── MCP 소스 준비 ────────────────────────────────────────────────────────────

# 로컬 클론 내부에서 실행된 경우
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
LOCAL_MCP="${SCRIPT_DIR}/../packages/oah-mcp/src/index.ts"

if [[ -f "$LOCAL_MCP" ]]; then
  MCP_PATH="$(cd "$(dirname "$LOCAL_MCP")" && pwd)/index.ts"
  echo "✅ 로컬 소스 사용: $MCP_PATH"
else
  # 원격 다운로드
  echo "📥 oah-mcp 다운로드 중..."
  mkdir -p "$MCP_DIR"
  curl -fsSL "$MCP_REPO/packages/oah-mcp/src/index.ts" -o "$MCP_DIR/index.ts"
  # package.json + 의존성
  cat > "$MCP_DIR/package.json" <<'JSON'
{
  "name": "@dureclaw/mcp",
  "type": "module",
  "dependencies": { "@modelcontextprotocol/sdk": "^1.10.2" }
}
JSON
  (cd "$MCP_DIR" && bun install --silent)
  MCP_PATH="$MCP_DIR/index.ts"
  echo "✅ 설치 완료: $MCP_PATH"
fi

# ─── Phoenix URL 결정 ─────────────────────────────────────────────────────────

if [[ -z "$PHOENIX_URL" ]]; then
  # ~/.oah/config 에서 로드
  [[ -f "$OAH_DIR/config" ]] && source "$OAH_DIR/config" && PHOENIX_URL="${PHOENIX:-}"

  # Tailscale IP 자동 감지
  if [[ -z "$PHOENIX_URL" ]]; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    DEFAULT_URL="${TS_IP:+ws://$TS_IP:4000}"
    DEFAULT_URL="${DEFAULT_URL:-ws://localhost:4000}"
  else
    DEFAULT_URL="$PHOENIX_URL"
  fi

  if [[ -t 0 ]]; then
    read -r -p "  Phoenix URL [$DEFAULT_URL]: " PHOENIX_URL
  fi
  PHOENIX_URL="${PHOENIX_URL:-$DEFAULT_URL}"
fi

echo "  Phoenix URL : $PHOENIX_URL"

# ─── Agent Name 결정 ──────────────────────────────────────────────────────────

if [[ -z "$AGENT_NAME" ]]; then
  MACHINE=$(hostname -s 2>/dev/null || hostname)
  DEFAULT_NAME="${AGENT_ROLE}@${MACHINE}"
  if [[ -t 0 ]]; then
    read -r -p "  Agent Name  [$DEFAULT_NAME]: " AGENT_NAME
  fi
  AGENT_NAME="${AGENT_NAME:-$DEFAULT_NAME}"
fi

echo "  Agent Name  : $AGENT_NAME"
echo "  Agent Role  : $AGENT_ROLE"
echo "  MCP Scope   : $SCOPE"
echo ""

# ─── claude mcp add 실행 ─────────────────────────────────────────────────────

echo "▶ Claude Code에 oah MCP 등록 중..."

# 기존 항목 제거 (있을 경우)
claude mcp remove oah 2>/dev/null || true

claude mcp add oah \
  --scope "$SCOPE" \
  -e "PHOENIX_URL=$PHOENIX_URL" \
  -e "AGENT_NAME=$AGENT_NAME" \
  -e "AGENT_ROLE=$AGENT_ROLE" \
  -- bun run "$MCP_PATH"

# ─── 완료 ─────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ DureClaw MCP 등록 완료!"
echo ""
echo "  Claude Code를 재시작하면 다음 도구를 사용할 수 있습니다:"
echo ""
echo "    mcp__oah__get_presence   연결된 에이전트 목록"
echo "    mcp__oah__send_task      에이전트에게 태스크 전송"
echo "    mcp__oah__receive_task   태스크 수신 대기 (30초)"
echo "    mcp__oah__complete_task  태스크 완료 보고"
echo "    mcp__oah__read_state     Work Key 상태 조회"
echo "    mcp__oah__write_state    Work Key 상태 업데이트"
echo "    mcp__oah__read_mailbox   mailbox 읽기"
echo "    mcp__oah__post_message   mailbox 메시지 전송"
echo ""
echo "  등록 확인:  claude mcp list"
echo "  제거:       claude mcp remove oah"
echo "  재등록:     bash scripts/setup-mcp.sh"
