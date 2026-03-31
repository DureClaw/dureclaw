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

CYAN="\033[1;36m"; GREEN="\033[1;32m"
YELLOW="\033[1;33m"; GRAY="\033[0;90m"; RESET="\033[0m"

echo ""
echo -e "${CYAN}  OAH — open-agent-harness${RESET}"
echo -e "${GRAY}  v0.3.0${RESET}"
echo ""

# oah CLI 다운로드
echo -e "${CYAN}→${RESET} oah CLI 설치 중..."
mkdir -p "$CLI_DIR"
curl -fsSL "$OAH_BASE/oah?nc=$(date +%s)" -o "$CLI_PATH"
chmod +x "$CLI_PATH"
echo -e "${GREEN}✅ $CLI_PATH${RESET}"

# PATH 등록 (없으면 추가)
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
PATH_ADDED=false
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  if [[ -f "$rc" ]] && ! grep -q ".local/bin" "$rc" 2>/dev/null; then
    { echo ""; echo "# oah (open-agent-harness)"; echo "$PATH_LINE"; } >> "$rc"
    PATH_ADDED=true
  fi
done
export PATH="$HOME/.local/bin:$PATH"

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
