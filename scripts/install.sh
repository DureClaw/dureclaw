#!/usr/bin/env bash
# install.sh — open-agent-harness 전역 커맨드 설치
#
# curl 원라인:
#   curl -fsSL https://raw.githubusercontent.com/baryonlabs/open-agent-harness/main/scripts/install.sh | bash
#
# 설치 후 사용:
#   oah-server                                    # Phoenix 서버 시작
#   oah-agent ws://100.x.x.x:4000 builder        # agent 시작

set -euo pipefail

OAH_REPO="https://github.com/baryonlabs/open-agent-harness.git"
OAH_DIR="$HOME/.open-agent-harness"
BIN_DIR="$HOME/.local/bin"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " open-agent-harness 설치"
echo " 설치 경로: $OAH_DIR"
echo " 커맨드 위치: $BIN_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── 1. Git 확인 ──────────────────────────────────────────────────────────────

if ! command -v git &>/dev/null; then
  echo "❌ git이 필요합니다."
  echo "   Mac:   brew install git"
  echo "   Linux: sudo apt-get install git"
  exit 1
fi

# ─── 2. 레포 클론 또는 업데이트 ──────────────────────────────────────────────

if [[ -d "$OAH_DIR/.git" ]]; then
  echo "→ 업데이트 중: $OAH_DIR"
  git -C "$OAH_DIR" pull --ff-only --quiet
  echo "✅ 업데이트 완료 ($(git -C "$OAH_DIR" log -1 --format='%h %s'))"
else
  echo "→ 다운로드 중: $OAH_REPO"
  git clone --depth=1 "$OAH_REPO" "$OAH_DIR"
  echo "✅ 다운로드 완료"
fi

# ─── 3. ~/.local/bin 디렉토리 ─────────────────────────────────────────────────

mkdir -p "$BIN_DIR"

# ─── 4. oah-agent 커맨드 생성 ─────────────────────────────────────────────────

cat > "$BIN_DIR/oah-agent" << EOF
#!/usr/bin/env bash
exec bash "$OAH_DIR/scripts/setup-agent.sh" "\$@"
EOF
chmod +x "$BIN_DIR/oah-agent"

# ─── 5. oah-server 커맨드 생성 ────────────────────────────────────────────────

cat > "$BIN_DIR/oah-server" << EOF
#!/usr/bin/env bash
exec bash "$OAH_DIR/scripts/setup-server.sh" "\$@"
EOF
chmod +x "$BIN_DIR/oah-server"

# ─── 6. PATH 등록 ─────────────────────────────────────────────────────────────

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
  echo "   source ~/.bashrc  # (또는 ~/.zshrc)"
  echo ""
fi
echo " 업데이트:"
echo "   curl -fsSL https://raw.githubusercontent.com/baryonlabs/open-agent-harness/main/scripts/install.sh | bash"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
