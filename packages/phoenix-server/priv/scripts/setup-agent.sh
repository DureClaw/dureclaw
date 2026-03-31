#!/usr/bin/env bash
# oah-agent — open-agent-harness agent daemon launcher
#
# 사용법:
#   bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)
#   PHOENIX=ws://... ROLE=builder bash <(curl -fsSL ...)

set -euo pipefail

OAH_BASE="https://open-agent-harness.baryon.ai"
EXE="$HOME/.oah-agent"
OAH_DIR="$HOME/.oah"
OAH_CONFIG="$OAH_DIR/config"

mkdir -p "$OAH_DIR"

# ─── 인수 파싱 ────────────────────────────────────────────────────────────────

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
  if curl -sf --max-time 3 "http://oah.local:4000/api/health" > /dev/null 2>&1; then
    PHOENIX="ws://oah.local:4000"
    echo "→ oah.local 연결됨"
  elif command -v tailscale &>/dev/null; then
    if ! _ts_tui; then
      echo "서버를 찾을 수 없습니다. 직접 지정:"
      echo "  PHOENIX=ws://<서버IP>:4000 bash <(curl -fsSL $OAH_BASE/setup-agent.sh)"
      exit 1
    fi
  else
    echo "FAILED: oah.local 연결 실패, Tailscale 도 없습니다."
    echo "  PHOENIX=ws://<서버IP>:4000 bash <(curl -fsSL $OAH_BASE/setup-agent.sh)"
    exit 1
  fi
fi

HTTP_BASE="${PHOENIX/ws:/http:}"
HTTP_BASE="${HTTP_BASE/wss:/https:}"

# ─── 1. 서버 연결 확인 ────────────────────────────────────────────────────────

for i in 1 2 3 4 5; do
  if curl -sf "$HTTP_BASE/api/health" > /dev/null 2>&1; then break; fi
  if [[ $i -eq 5 ]]; then
    echo "FAILED: Phoenix server unreachable: $HTTP_BASE"
    exit 1
  fi
  echo "→ 서버 대기 중... ($i/5)"
  sleep 2
done

# ─── 2. 바이너리 다운로드 ─────────────────────────────────────────────────────

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
USE_NODE=false

case "$ARCH" in
  x86_64)        ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l|armv6l) USE_NODE=true ;;
  *)
    echo "ERROR: 지원하지 않는 아키텍처: $ARCH"
    exit 1 ;;
esac

if [[ "$USE_NODE" == "true" ]]; then
  # 32비트 ARM — Node.js + JS 번들 사용
  JS_BUNDLE="$HOME/.oah-agent.js"
  JS_URL="$OAH_BASE/oah-agent.js"
  # ?nc=날짜 쿼리로 CDN 캐시 우회하여 실제 R2 크기 확인
  NC_DATE=$(date +%Y%m%d)
  JS_NOCACHE_URL="$JS_URL?nc=$NC_DATE"
  if [[ ! -f "$JS_BUNDLE" ]]; then
    echo "→ 에이전트(JS) 다운로드 중..."
    curl -fsSL "$JS_NOCACHE_URL" -o "$JS_BUNDLE"
  else
    REMOTE_SIZE=$(curl -sfI --max-time 5 "$JS_NOCACHE_URL" | grep -i content-length | awk '{print $2}' | tr -d '\r')
    LOCAL_SIZE=$(wc -c < "$JS_BUNDLE" | tr -d ' ')
    if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" != "$LOCAL_SIZE" ]]; then
      echo "→ 에이전트(JS) 업데이트 중..."
      curl -fsSL "$JS_NOCACHE_URL" -o "$JS_BUNDLE"
    fi
  fi


  # Node.js 설치 확인 (armhf는 Debian repo 직접 사용)
  if ! command -v node &>/dev/null; then
    echo "→ Node.js 설치 중..."
    if command -v apt-get &>/dev/null; then
      sudo apt-get install -y nodejs
    elif command -v yum &>/dev/null; then
      sudo yum install -y nodejs
    else
      echo "ERROR: Node.js 자동 설치 실패. 수동으로 설치하세요: sudo apt install nodejs"
      exit 1
    fi
  fi

  # ─── OpenCode (선택) ───────────────────────────────────────────────────────
  export PATH="$HOME/.opencode/bin:$PATH"
  if ! command -v opencode &>/dev/null; then
    echo "→ OpenCode 설치 시도 중..."
    if curl -fsSL https://opencode.ai/install | bash 2>/dev/null; then
      export PATH="$HOME/.opencode/bin:$PATH"
    else
      echo "⚠ OpenCode 설치 실패 (미지원 아키텍처). [SHELL] 태스크만 사용 가능."
    fi
  fi

  # ZeroClaw 감지 — 설치되어 있으면 AGENT_BACKEND=zeroclaw 자동 설정
  BACKEND="opencode"
  if command -v zeroclaw &>/dev/null; then
    BACKEND="zeroclaw"
    echo "→ ZeroClaw 감지됨 — AI 백엔드로 사용"
  fi

  # ─── oah CLI 설치 ──────────────────────────────────────────────────────────
  _install_oah_cli

  # ─── ~/.oah/config 저장 ────────────────────────────────────────────────────
  cat > "$OAH_CONFIG" <<CFG
PHOENIX=$PHOENIX
ROLE=$ROLE
BACKEND=$BACKEND
DIR=$DIR
WK=${WK:-}
NAME=$NAME
CFG

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " oah-agent  ${ROLE}@$(hostname -s 2>/dev/null || hostname)  [Node.js/32-bit]"
  echo " server  →  $PHOENIX"
  echo " backend →  $BACKEND"
  echo " dir     →  $DIR"
  [[ -n "$WK" ]] && echo " work-key→  $WK"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 명령어:  oah status | oah start | oah service install"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  exec env \
    STATE_SERVER="$PHOENIX" \
    AGENT_NAME="$NAME" \
    AGENT_ROLE="$ROLE" \
    AGENT_BACKEND="$BACKEND" \
    WORK_KEY="${WK:-}" \
    PROJECT_DIR="$DIR" \
    node "$JS_BUNDLE"
fi

# ─── oah CLI 설치 함수 ────────────────────────────────────────────────────────

_install_oah_cli() {
  local cli_dir="$HOME/.local/bin"
  mkdir -p "$cli_dir"
  # oah CLI 스크립트 다운로드
  curl -fsSL "$OAH_BASE/oah" -o "$cli_dir/oah" 2>/dev/null \
    || curl -fsSL "$OAH_BASE/scripts/oah" -o "$cli_dir/oah" 2>/dev/null \
    || true
  chmod +x "$cli_dir/oah" 2>/dev/null || true
  # PATH에 없으면 안내
  if ! command -v oah &>/dev/null 2>&1; then
    # .bashrc/.zshrc 에 PATH 추가
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
      if [[ -f "$rc" ]] && ! grep -q ".local/bin" "$rc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
      fi
    done
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

BINARY_NAME="oah-agent-${OS}-${ARCH}"
BINARY_URL="$OAH_BASE/$BINARY_NAME"

if [[ ! -f "$EXE" ]]; then
  echo "→ 에이전트 다운로드 중... ($BINARY_NAME)"
  curl -fsSL "$BINARY_URL" -o "$EXE"
  chmod +x "$EXE"
elif curl -sf --max-time 5 -I "$BINARY_URL" | grep -q "200"; then
  REMOTE_SIZE=$(curl -sfI "$BINARY_URL" | grep -i content-length | awk '{print $2}' | tr -d '\r')
  LOCAL_SIZE=$(wc -c < "$EXE" | tr -d ' ')
  if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" != "$LOCAL_SIZE" ]]; then
    echo "→ 에이전트 업데이트 중..."
    curl -fsSL "$BINARY_URL" -o "$EXE"
    chmod +x "$EXE"
  fi
fi

# ─── 3. OpenCode ──────────────────────────────────────────────────────────────

export PATH="$HOME/.opencode/bin:$PATH"
if ! command -v opencode &>/dev/null; then
  echo "→ OpenCode 설치 중..."
  curl -fsSL https://opencode.ai/install | bash
  export PATH="$HOME/.opencode/bin:$PATH"
fi

# ─── 4. Work Key ──────────────────────────────────────────────────────────────

if [[ -z "$WK" ]] && [[ "$ROLE" == "orchestrator" ]]; then
  WK=$(curl -sf -X POST "$HTTP_BASE/api/work-keys" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['work_key'])")
  echo ""
  echo "┌─────────────────────────────────────────────────┐"
  echo "│  Work Key: $WK"
  echo "│  다른 머신: PHOENIX=$PHOENIX bash <(curl -fsSL $OAH_BASE/setup-agent.sh)"
  echo "└─────────────────────────────────────────────────┘"
  echo ""
fi

# ─── 5. 실행 ──────────────────────────────────────────────────────────────────

# ─── oah CLI 설치 + config 저장 ───────────────────────────────────────────────

_install_oah_cli

cat > "$OAH_CONFIG" <<CFG
PHOENIX=$PHOENIX
ROLE=$ROLE
BACKEND=${AGENT_BACKEND:-auto}
DIR=$DIR
WK=${WK:-}
NAME=$NAME
CFG

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " oah-agent  ${ROLE}@$(hostname -s 2>/dev/null || hostname)"
echo " server  →  $PHOENIX"
echo " dir     →  $DIR"
[[ -n "$WK" ]] && echo " work-key→  $WK"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 명령어:  oah status | oah start | oah service install"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exec env \
  STATE_SERVER="$PHOENIX" \
  AGENT_NAME="$NAME" \
  AGENT_ROLE="$ROLE" \
  WORK_KEY="${WK:-}" \
  PROJECT_DIR="$DIR" \
  "$EXE"
