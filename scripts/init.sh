#!/usr/bin/env bash
# init.sh — Install open-agent-harness into an existing project
# Usage: bash scripts/init.sh [target-directory]
# Default target: current directory

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$(pwd)}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " open-agent-harness installer"
echo " Source: $HARNESS_DIR"
echo " Target: $TARGET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Safety checks ──────────────────────────────────────────────────────

if [[ ! -d "$TARGET" ]]; then
  echo "Error: Target directory does not exist: $TARGET"
  exit 1
fi

if [[ "$TARGET" == "$HARNESS_DIR" ]]; then
  echo "Error: Cannot install into the harness directory itself."
  exit 1
fi

# ─── Check for existing .opencode ───────────────────────────────────────

if [[ -d "$TARGET/.opencode" ]]; then
  echo ""
  echo "Warning: $TARGET/.opencode already exists."
  read -r -p "Overwrite? [y/N] " answer
  case "$answer" in
    [Yy]*) echo "Overwriting..." ;;
    *)     echo "Aborted."; exit 0 ;;
  esac
fi

# ─── Copy structure ──────────────────────────────────────────────────────

echo ""
echo "Copying .opencode/ structure..."
mkdir -p "$TARGET/.opencode"

# Copy agents
echo "  → agents/"
cp -r "$HARNESS_DIR/.opencode/agents" "$TARGET/.opencode/"

# Copy plugin
echo "  → plugin/"
cp -r "$HARNESS_DIR/.opencode/plugin" "$TARGET/.opencode/"

# Copy hooks
echo "  → hooks/"
cp -r "$HARNESS_DIR/.opencode/hooks" "$TARGET/.opencode/"
chmod +x "$TARGET/.opencode/hooks/"*.sh "$TARGET/.opencode/hooks/"*.py

# Copy commands
echo "  → commands/"
cp -r "$HARNESS_DIR/.opencode/commands" "$TARGET/.opencode/"

# Initialize state (fresh)
echo "  → state/"
mkdir -p "$TARGET/.opencode/state/mailbox"
mkdir -p "$TARGET/.opencode/reports"

cat > "$TARGET/.opencode/state/state.json" << 'EOF'
{
  "run_id": null,
  "goal": null,
  "status": "idle",
  "loop_count": 0,
  "tasks": [],
  "current_task": null,
  "last_failure": null,
  "started_at": null,
  "updated_at": null
}
EOF

cp "$HARNESS_DIR/.opencode/state/mailbox/README.md" "$TARGET/.opencode/state/mailbox/"

# ─── Copy opencode.json (if not exists) ─────────────────────────────────

if [[ ! -f "$TARGET/opencode.json" ]]; then
  echo "  → opencode.json"
  cp "$HARNESS_DIR/opencode.json" "$TARGET/opencode.json"
else
  echo "  ⚠️  opencode.json already exists — skipping (merge manually)"
fi

# ─── .gitignore additions ────────────────────────────────────────────────

GITIGNORE="$TARGET/.gitignore"
HARNESS_IGNORES=".opencode/reports/
.opencode/state/mailbox/*.json
!.opencode/state/mailbox/README.md"

if [[ -f "$GITIGNORE" ]]; then
  if ! grep -q ".opencode/reports" "$GITIGNORE"; then
    echo "" >> "$GITIGNORE"
    echo "# open-agent-harness" >> "$GITIGNORE"
    echo "$HARNESS_IGNORES" >> "$GITIGNORE"
    echo "  → Updated .gitignore"
  else
    echo "  → .gitignore already has harness entries"
  fi
else
  echo "# open-agent-harness" > "$GITIGNORE"
  echo "$HARNESS_IGNORES" >> "$GITIGNORE"
  echo "  → Created .gitignore"
fi

# ─── Done ────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ open-agent-harness installed!"
echo ""
echo " Next steps:"
echo "   1. cd $TARGET"
echo "   2. opencode (start OpenCode)"
echo "   3. /workloop <your goal>"
echo ""
echo " Verify hooks work:"
echo "   bash .opencode/hooks/00_preflight.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
