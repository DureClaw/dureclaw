#!/usr/bin/env bash
#
# install-agent-service.sh — register the DureClaw agent daemon as a long-lived
# service so it survives logout and auto-restarts on crash/disconnect.
#
# On Linux this uses a systemd --user unit with linger enabled. Without this,
# a daemon launched over SSH dies when the session ends (systemd-logind's
# KillUserProcesses) and a remote node's presence silently vanishes.
#
# Usage:
#   STATE_SERVER=ws://100.x.y.z:4000 OAH_SECRET=... AGENT_ROLE=builder \
#     bash scripts/install-agent-service.sh
#
# Optional env:
#   AGENT_NAME (default: <role>@<hostname>)   WORK_KEY (auto-discovered if unset)
#   AGENT_BACKEND (e.g. ollama)               OLLAMA_MODEL
#   REPO_DIR (default: ~/dureclaw)            BUN (default: ~/.bun/bin/bun)
#   SERVICE_NAME (default: dureclaw-agent)

set -euo pipefail

: "${STATE_SERVER:?set STATE_SERVER, e.g. ws://100.x.y.z:4000}"
: "${OAH_SECRET:?set OAH_SECRET (server prints it on first start)}"

AGENT_ROLE="${AGENT_ROLE:-builder}"
AGENT_MACHINE="${AGENT_MACHINE:-$(hostname -s 2>/dev/null || hostname)}"
AGENT_NAME="${AGENT_NAME:-${AGENT_ROLE}@${AGENT_MACHINE}}"
REPO_DIR="${REPO_DIR:-$HOME/dureclaw}"
BUN="${BUN:-$HOME/.bun/bin/bun}"
SERVICE_NAME="${SERVICE_NAME:-dureclaw-agent}"
ENTRY="$REPO_DIR/packages/agent-daemon/src/index.ts"

[ -x "$BUN" ] || { echo "bun not found at $BUN (set BUN=...)"; exit 1; }
[ -f "$ENTRY" ] || { echo "daemon entry not found at $ENTRY (set REPO_DIR=...)"; exit 1; }

if [ "$(uname -s)" != "Linux" ]; then
  echo "This helper targets Linux systemd. On macOS, run the daemon under launchd"
  echo "or a process supervisor; the daemon command is:"
  echo "  OAH_SECRET=… STATE_SERVER=$STATE_SERVER AGENT_ROLE=$AGENT_ROLE $BUN run $ENTRY"
  exit 0
fi

# Survive logout.
loginctl enable-linger "$USER" >/dev/null 2>&1 || true

UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

{
  echo "[Unit]"
  echo "Description=DureClaw agent daemon (${AGENT_NAME})"
  echo "After=network-online.target"
  echo ""
  echo "[Service]"
  echo "ExecStart=$BUN run $ENTRY"
  echo "WorkingDirectory=$REPO_DIR/packages/agent-daemon"
  echo "Environment=STATE_SERVER=$STATE_SERVER"
  echo "Environment=OAH_SECRET=$OAH_SECRET"
  echo "Environment=AGENT_ROLE=$AGENT_ROLE"
  echo "Environment=AGENT_NAME=$AGENT_NAME"
  echo "Environment=AGENT_MACHINE=$AGENT_MACHINE"
  [ -n "${WORK_KEY:-}" ]      && echo "Environment=WORK_KEY=$WORK_KEY"
  [ -n "${AGENT_BACKEND:-}" ] && echo "Environment=AGENT_BACKEND=$AGENT_BACKEND"
  [ -n "${OLLAMA_MODEL:-}" ]  && echo "Environment=OLLAMA_MODEL=$OLLAMA_MODEL"
  echo "Restart=always"
  echo "RestartSec=5"
  echo ""
  echo "[Install]"
  echo "WantedBy=default.target"
} > "$UNIT_DIR/${SERVICE_NAME}.service"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user daemon-reload
# enable + restart separately: a combined `enable --now` can hang a
# non-interactive SSH session; restart is idempotent (start or replace).
systemctl --user enable "${SERVICE_NAME}.service" 2>/dev/null || true
systemctl --user restart "${SERVICE_NAME}.service"

echo "✅ ${SERVICE_NAME} installed and started (auto-restart, survives logout)."
echo "   logs:    journalctl --user -u ${SERVICE_NAME} -f"
echo "   status:  systemctl --user status ${SERVICE_NAME}"
echo "   stop:    systemctl --user disable --now ${SERVICE_NAME}"
