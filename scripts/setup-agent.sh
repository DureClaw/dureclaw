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

# ─── Tailscale 자동 설치 ──────────────────────────────────────────────────────

_AGENT_OS=$(uname -s | tr '[:upper:]' '[:lower:]')

_install_tailscale_agent() {
  if [[ "$_AGENT_OS" == "darwin" ]]; then
    if command -v brew &>/dev/null; then
      echo "→ brew로 Tailscale 설치 중..."
      brew install --cask tailscale
      open -a Tailscale 2>/dev/null || true
      echo ""
      echo " ★ 메뉴바의 Tailscale 아이콘을 클릭해 로그인하세요."
      echo "   로그인 완료 후 Enter를 누르세요..."
      read -r
    else
      open "https://apps.apple.com/app/tailscale/id1475387142" 2>/dev/null || true
      echo " → Mac App Store에서 Tailscale 설치 후 로그인 완료 시 Enter..."
      read -r
    fi
  else
    # Linux: 공식 설치 스크립트 (Debian/Ubuntu/Fedora/CentOS/Arch 등 자동 감지)
    echo "→ Tailscale 설치 중..."
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "→ Tailscale 연결 중 (브라우저에서 인증하세요)..."
    if command -v sudo &>/dev/null; then
      sudo tailscale up
    else
      tailscale up
    fi
  fi
}

_ensure_tailscale_agent() {
  # 이미 연결됨?
  if command -v tailscale &>/dev/null; then
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    [[ -n "$ts_ip" ]] && { echo "✅ Tailscale: $ts_ip"; return 0; }
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Tailscale 미연결 — 서버에 원격 접속하려면 필요합니다"
  echo " (서버와 같은 LAN이면 PHOENIX=ws://<IP>:4000 으로 건너뛰기 가능)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  if [[ ! -t 0 ]]; then
    echo "⚠ 비대화형 환경 — Tailscale 설치를 건너뜁니다."
    return 0
  fi

  read -rp " 지금 Tailscale을 설치·연결하시겠습니까? [Y/n] " yn
  [[ "${yn:-Y}" =~ ^[Nn] ]] && { echo " → 건너뜁니다."; return 0; }

  _install_tailscale_agent

  local ts_ip
  ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
  [[ -n "$ts_ip" ]] && echo "✅ Tailscale 연결 완료: $ts_ip" \
                     || echo "⚠ IP 미할당 — 인증 후 자동 할당됩니다."
}

# ─── 서버 자동 탐색 ───────────────────────────────────────────────────────────

PHOENIX="${1:-${PHOENIX:-}}"

if [[ -z "$PHOENIX" ]]; then
  if curl -sf --max-time 3 "http://oah.local:4000/api/health" > /dev/null 2>&1; then
    PHOENIX="ws://oah.local:4000"
    echo "→ oah.local 연결됨"
  elif command -v tailscale &>/dev/null && tailscale ip -4 &>/dev/null 2>&1; then
    # Tailscale 있고 연결됨 → TUI로 서버 선택
    if ! _ts_tui; then
      echo "서버를 찾을 수 없습니다. 직접 지정:"
      echo "  PHOENIX=ws://<서버IP>:4000 bash <(curl -fsSL $OAH_BASE/setup-agent.sh)"
      exit 1
    fi
  else
    # Tailscale 없거나 미연결 → 자동 설치 유도
    _ensure_tailscale_agent

    # 설치 후 재시도
    if command -v tailscale &>/dev/null && tailscale ip -4 &>/dev/null 2>&1; then
      _ts_tui || true
    fi

    # 그래도 PHOENIX 없으면 수동 입력
    if [[ -z "$PHOENIX" ]]; then
      if [[ -t 0 ]]; then
        echo ""
        echo "서버 주소를 입력하세요 (예: ws://100.64.0.1:4000 또는 ws://192.168.1.10:4000):"
        read -rp "> " PHOENIX
      fi
      [[ -z "$PHOENIX" ]] && {
        echo "FAILED: PHOENIX 주소가 필요합니다."
        echo "  PHOENIX=ws://<서버IP>:4000 bash <(curl -fsSL $OAH_BASE/setup-agent.sh)"
        exit 1
      }
    fi
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
USE_PYTHON=false

case "$ARCH" in
  x86_64)        ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) USE_NODE=true ;;
  armv6l) USE_PYTHON=true ;;
  *)
    echo "ERROR: 지원하지 않는 아키텍처: $ARCH"
    exit 1 ;;
esac

# ─── oah CLI 설치 함수 ────────────────────────────────────────────────────────

_install_oah_cli() {
  local cli_dir="$HOME/.local/bin"
  mkdir -p "$cli_dir"
  # oah CLI 스크립트 다운로드
  curl -fsSL "$OAH_BASE/oah" -o "$cli_dir/oah" 2>/dev/null \
    || curl -fsSL "$OAH_BASE/scripts/oah" -o "$cli_dir/oah" 2>/dev/null \
    || true
  chmod +x "$cli_dir/oah" 2>/dev/null || true

  # .bashrc/.zshrc 에 PATH 추가 (없으면)
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [[ -f "$rc" ]] && ! grep -q ".local/bin" "$rc" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
    fi
  done
  export PATH="$HOME/.local/bin:$PATH"

  # bash <(curl ...) 서브셸에서는 부모 셸 PATH에 영향을 못 주므로 항상 안내 출력
  # (서브셸 안에서 command -v oah 가 성공해도 부모 셸은 여전히 미적용)
  OAH_PATH_NOTICE=true
}

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
  echo ""
  echo " ⚠  oah 명령어가 없다면 다음을 실행하세요:"
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo "    (새 터미널을 열면 자동 적용됩니다)"
  echo ""

  exec env \
    STATE_SERVER="$PHOENIX" \
    AGENT_NAME="$NAME" \
    AGENT_ROLE="$ROLE" \
    AGENT_BACKEND="$BACKEND" \
    WORK_KEY="${WK:-}" \
    PROJECT_DIR="$DIR" \
    node "$JS_BUNDLE"
fi

if [[ "$USE_PYTHON" == "true" ]]; then
  # Raspberry Pi Zero W (armv6l) — Python 에이전트 사용
  echo "→ Raspberry Pi Zero W detected (armv6l) — using Python agent"
  PY_BUNDLE="$HOME/oah-agent.py"
  AGENT_URL="$OAH_BASE"
  pip3 install --quiet websockets 2>/dev/null || pip install --quiet websockets 2>/dev/null || {
    echo "ERROR: pip3 설치 실패. sudo apt install python3-pip 를 실행하세요."
    exit 1
  }
  if [[ ! -f "$PY_BUNDLE" ]]; then
    echo "→ 에이전트(Python) 다운로드 중..."
    curl -fsSL "$AGENT_URL/agent.py" -o "$PY_BUNDLE"
  else
    REMOTE_SIZE=$(curl -sfI --max-time 5 "$AGENT_URL/agent.py" | grep -i content-length | awk '{print $2}' | tr -d '\r')
    LOCAL_SIZE=$(wc -c < "$PY_BUNDLE" | tr -d ' ')
    if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" != "$LOCAL_SIZE" ]]; then
      echo "→ 에이전트(Python) 업데이트 중..."
      curl -fsSL "$AGENT_URL/agent.py" -o "$PY_BUNDLE"
    fi
  fi

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
  echo " oah-agent  ${ROLE}@$(hostname -s 2>/dev/null || hostname)  [Python/RPi Zero W]"
  echo " server  →  $PHOENIX"
  echo " dir     →  $DIR"
  [[ -n "$WK" ]] && echo " work-key→  $WK"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  exec env \
    PHOENIX="$PHOENIX" \
    ROLE="$ROLE" \
    NAME="$NAME" \
    WK="${WK:-}" \
    PROJECT_DIR="$DIR" \
    AGENT_BACKEND="${AGENT_BACKEND:-auto}" \
    python3 "$PY_BUNDLE"
fi

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
echo ""
echo " ⚠  oah 명령어가 없다면 다음을 실행하세요:"
echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "    (새 터미널을 열면 자동 적용됩니다)"
echo ""

exec env \
  STATE_SERVER="$PHOENIX" \
  AGENT_NAME="$NAME" \
  AGENT_ROLE="$ROLE" \
  WORK_KEY="${WK:-}" \
  PROJECT_DIR="$DIR" \
  "$EXE"
