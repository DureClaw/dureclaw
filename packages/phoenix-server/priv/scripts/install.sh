#!/usr/bin/env bash
# oah 설치 스크립트
#
#   curl -fsSL https://open-agent-harness.baryon.ai/install | bash
#
# oah CLI를 ~/.local/bin/oah 에 설치하고 PATH에 추가합니다.

set -euo pipefail

OAH_BASE="https://open-agent-harness.baryon.ai"
CLI_DIR="$HOME/.local/bin"
CLI_PATH="$CLI_DIR/oah"
OAH_DIR="$HOME/.oah"
OAH_CONFIG="$OAH_DIR/config"
OAH_LOG="$OAH_DIR/oah.log"
OAH_PID="$OAH_DIR/oah.pid"

CYAN="\033[1;36m"; GREEN="\033[1;32m"
YELLOW="\033[1;33m"; RED="\033[1;31m"; GRAY="\033[0;90m"; RESET="\033[0m"

echo ""
echo -e "${CYAN}  OAH — open-agent-harness${RESET}"
echo -e "${GRAY}  v0.3.0${RESET}"
echo ""

# ─── 이미 설치된 경우 선택 메뉴 ─────────────────────────────────────────────

INSTALL_MODE="fresh"  # fresh | upgrade | cancel

if [[ -f "$CLI_PATH" ]] || [[ -f "$OAH_DIR/config" ]] || [[ -f "$HOME/.oah-agent" ]]; then
  echo -e "  ${YELLOW}이미 설치된 oah 가 발견되었습니다.${RESET}"
  echo ""

  # 현재 버전 표시
  if [[ -f "$OAH_CONFIG" ]]; then
    echo -e "  ${GRAY}설정 파일: $OAH_CONFIG${RESET}"
    while IFS= read -r line; do
      [[ "$line" =~ ^(PHOENIX|ROLE|WK|NAME)= ]] && echo -e "  ${GRAY}  $line${RESET}"
    done < "$OAH_CONFIG" 2>/dev/null || true
    echo ""
  fi

  echo -e "  설치 방식을 선택하세요:"
  echo ""
  echo -e "    ${GREEN}1)${RESET} 업그레이드만   — 데이터/설정 유지, oah CLI+바이너리만 최신화"
  echo -e "    ${YELLOW}2)${RESET} 완전 재설치    — 데이터/설정 삭제 후 새로 설치 (초기화)"
  echo -e "    ${GRAY}3)${RESET} 취소"
  echo ""
  printf "  선택 [1]: "

  # curl | bash 환경에서는 stdin이 파이프라 /dev/tty에서 읽어야 함
  read -r choice </dev/tty || choice="1"

  case "${choice:-1}" in
    2)
      INSTALL_MODE="clean"
      echo ""
      echo -e "  ${RED}⚠  데이터/설정을 삭제합니다.${RESET}"
      printf "  정말 삭제하시겠습니까? [y/N]: "
      read -r confirm </dev/tty || confirm="n"
      if [[ ! "${confirm,,}" =~ ^y ]]; then
        echo "  취소됨."
        exit 0
      fi
      ;;
    3)
      echo "  취소됨."
      exit 0
      ;;
    *)
      INSTALL_MODE="upgrade"
      ;;
  esac
  echo ""
fi

# ─── 데이터 삭제 (완전 재설치) ───────────────────────────────────────────────

if [[ "$INSTALL_MODE" == "clean" ]]; then
  echo -e "${CYAN}→${RESET} 기존 데이터 삭제 중..."

  # 실행 중인 프로세스 종료
  if [[ -f "$OAH_PID" ]]; then
    local_pid=$(cat "$OAH_PID" 2>/dev/null || true)
    if [[ -n "$local_pid" ]] && kill -0 "$local_pid" 2>/dev/null; then
      kill "$local_pid" 2>/dev/null || true
      echo -e "  → 실행 중인 oah-agent 종료 (PID $local_pid)"
    fi
  fi

  # systemd 서비스 제거
  if command -v systemctl &>/dev/null; then
    systemctl --user stop oah-agent 2>/dev/null || true
    systemctl --user disable oah-agent 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/oah-agent.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi

  # launchd 서비스 제거
  if [[ "$(uname)" == "Darwin" ]]; then
    launchctl unload "$HOME/Library/LaunchAgents/ai.baryon.oah-agent.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/ai.baryon.oah-agent.plist"
  fi

  # 데이터 파일 삭제
  rm -rf "$OAH_DIR"
  rm -f "$HOME/.oah-agent" "$HOME/.oah-agent.js"
  echo -e "  ${GREEN}✅ 삭제 완료${RESET}"
  echo ""
fi

# ─── oah CLI 설치/업데이트 ──────────────────────────────────────────────────

echo -e "${CYAN}→${RESET} oah CLI 설치 중..."
mkdir -p "$CLI_DIR"
curl -fsSL "$OAH_BASE/oah?nc=$(date +%s)" -o "$CLI_PATH"
chmod +x "$CLI_PATH"
echo -e "  ${GREEN}✅ $CLI_PATH${RESET}"

# ─── oah-agent 바이너리 업데이트 (이미 있는 경우) ──────────────────────────

if [[ "$INSTALL_MODE" == "upgrade" ]] && [[ -f "$HOME/.oah-agent" || -f "$HOME/.oah-agent.js" ]]; then
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)        ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv6l)
      echo -e "${CYAN}→${RESET} oah-agent JS 번들 업데이트 중..."
      curl -fsSL "$OAH_BASE/oah-agent.js?nc=$(date +%s)" -o "$HOME/.oah-agent.js"
      echo -e "  ${GREEN}✅ ~/.oah-agent.js${RESET}"
      ARCH=""
      ;;
  esac
  if [[ -n "$ARCH" ]]; then
    echo -e "${CYAN}→${RESET} oah-agent 바이너리 업데이트 중..."
    curl -fsSL "$OAH_BASE/oah-agent-${OS}-${ARCH}?nc=$(date +%s)" -o "$HOME/.oah-agent"
    chmod +x "$HOME/.oah-agent"
    echo -e "  ${GREEN}✅ ~/.oah-agent${RESET}"
  fi
fi

# ─── PATH 등록 ───────────────────────────────────────────────────────────────

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
PATH_ADDED=false
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  if [[ -f "$rc" ]] && ! grep -q ".local/bin" "$rc" 2>/dev/null; then
    { echo ""; echo "# oah (open-agent-harness)"; echo "$PATH_LINE"; } >> "$rc"
    PATH_ADDED=true
  fi
done
export PATH="$HOME/.local/bin:$PATH"

# ─── 완료 메시지 ─────────────────────────────────────────────────────────────

echo ""
if [[ "$INSTALL_MODE" == "upgrade" ]]; then
  echo -e "  ${GREEN}✅ 업그레이드 완료${RESET} — 설정/데이터가 유지되었습니다."
elif [[ "$INSTALL_MODE" == "clean" ]]; then
  echo -e "  ${GREEN}✅ 재설치 완료${RESET} — 초기화 상태입니다."
else
  echo -e "  ${GREEN}✅ 설치 완료${RESET}"
fi

echo ""
echo -e "  ${CYAN}다음 단계:${RESET}"
echo ""

# oah.local 서버 자동 탐색
if curl -sf --max-time 2 "http://oah.local:4000/api/health" > /dev/null 2>&1; then
  echo -e "  oah.local 서버 발견!"
  echo ""
  echo -e "  에이전트 시작:        ${GREEN}oah${RESET}"
  echo -e "  서비스로 등록:        ${GREEN}oah service install${RESET}"
  echo -e "  상태 확인:            ${GREEN}oah status${RESET}"
else
  echo -e "  서버 주소를 지정하여 실행:"
  echo ""
  echo -e "  ${GREEN}  PHOENIX=ws://<서버IP>:4000 oah${RESET}"
  echo ""
  echo -e "  또는 Tailscale 자동 탐색:"
  echo -e "  ${GREEN}  oah${RESET}"
fi

echo ""
echo -e "  ${GRAY}도움말: oah help${RESET}"
echo ""
$PATH_ADDED && echo -e "  ${YELLOW}⚠  새 터미널을 열거나 source ~/.bashrc 를 실행하세요.${RESET}" && echo "" || true
