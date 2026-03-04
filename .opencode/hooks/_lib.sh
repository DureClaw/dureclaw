#!/usr/bin/env bash
# _lib.sh — common utilities for open-agent-harness hooks
# Source this file at the top of each hook: source "$(dirname "$0")/_lib.sh"

set -euo pipefail

# ─── Paths ──────────────────────────────────────────────────────────────────

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_DIR="$(dirname "$HOOK_DIR")"
PROJECT_ROOT="$(dirname "$OPENCODE_DIR")"
REPORTS_DIR="$OPENCODE_DIR/reports"
STATE_DIR="$OPENCODE_DIR/state"

mkdir -p "$REPORTS_DIR"

# ─── Stack Detection ─────────────────────────────────────────────────────────

detect_stack() {
  # Returns primary stack: node|bun|python|go|rust|unknown
  if [[ -f "$PROJECT_ROOT/bun.lockb" ]] || grep -q '"bun"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
    echo "bun"
  elif [[ -f "$PROJECT_ROOT/package.json" ]]; then
    echo "node"
  elif [[ -f "$PROJECT_ROOT/pyproject.toml" ]] || [[ -f "$PROJECT_ROOT/setup.py" ]]; then
    echo "python"
  elif [[ -f "$PROJECT_ROOT/go.mod" ]]; then
    echo "go"
  elif [[ -f "$PROJECT_ROOT/Cargo.toml" ]]; then
    echo "rust"
  else
    echo "unknown"
  fi
}

# ─── Node Package Manager ────────────────────────────────────────────────────

node_pm() {
  # Returns: bun|npm|yarn|pnpm
  local stack
  stack="$(detect_stack)"
  if [[ "$stack" == "bun" ]]; then
    echo "bun"
  elif [[ -f "$PROJECT_ROOT/yarn.lock" ]]; then
    echo "yarn"
  elif [[ -f "$PROJECT_ROOT/pnpm-lock.yaml" ]]; then
    echo "pnpm"
  else
    echo "npm"
  fi
}

# ─── Report Helpers ──────────────────────────────────────────────────────────

write_report() {
  # write_report <filename> <title> <exit_code> <content>
  local filename="$1"
  local title="$2"
  local exit_code="$3"
  local content="$4"
  local status
  status=$( [[ "$exit_code" -eq 0 ]] && echo "✅ PASS" || echo "❌ FAIL" )

  cat > "$REPORTS_DIR/$filename" <<EOF
# $title
- **Time**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- **Exit Code**: $exit_code
- **Status**: $status

## Output

\`\`\`
$content
\`\`\`
EOF
}

append_report() {
  # append_report <filename> <section_title> <content>
  local filename="$1"
  local section="$2"
  local content="$3"

  cat >> "$REPORTS_DIR/$filename" <<EOF

## $section

\`\`\`
$content
\`\`\`
EOF
}

# ─── Logging ─────────────────────────────────────────────────────────────────

log_info()  { echo "[INFO]  $*" >&2; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# ─── Script Header ────────────────────────────────────────────────────────────

hook_header() {
  local name="$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " open-agent-harness | hook: $name"
  echo " $(date -u +"%Y-%m-%dT%H:%M:%SZ") | stack: $(detect_stack)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
