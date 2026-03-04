#!/usr/bin/env bash
# 00_preflight.sh — Verify environment prerequisites
# Exit 0: all good | Exit 1: missing requirements

source "$(dirname "$0")/_lib.sh"
hook_header "00_preflight"

cd "$PROJECT_ROOT"
ERRORS=()
WARNINGS=()

# ─── Check required tools ──────────────────────────────────────────────────

check_tool() {
  local tool="$1"
  local version_flag="${2:---version}"
  if command -v "$tool" &>/dev/null; then
    log_info "$tool: $(command -v "$tool") ($($tool $version_flag 2>&1 | head -1))"
  else
    ERRORS+=("Missing required tool: $tool")
  fi
}

# Universal requirements
check_tool "git" "--version"
check_tool "bash" "--version"

STACK="$(detect_stack)"
log_info "Detected stack: $STACK"

# Stack-specific requirements
case "$STACK" in
  bun)
    check_tool "bun" "--version"
    ;;
  node)
    check_tool "node" "--version"
    check_tool "npm" "--version"
    ;;
  python)
    check_tool "python3" "--version"
    ;;
  go)
    check_tool "go" "version"
    ;;
  rust)
    check_tool "cargo" "--version"
    ;;
  *)
    WARNINGS+=("Unknown stack. Skipping stack-specific tool checks.")
    ;;
esac

# ─── Check project structure ─────────────────────────────────────────────

[[ -d "$PROJECT_ROOT/.opencode" ]] || ERRORS+=("Missing .opencode/ directory")
[[ -f "$PROJECT_ROOT/.opencode/state/state.json" ]] || WARNINGS+=("state.json not yet initialized")

# ─── Check git state ─────────────────────────────────────────────────────

if git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null; then
  log_info "Git repo: $(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'detached')"
  STAGED=$(git -C "$PROJECT_ROOT" diff --cached --name-only | wc -l | tr -d ' ')
  UNSTAGED=$(git -C "$PROJECT_ROOT" diff --name-only | wc -l | tr -d ' ')
  log_info "Staged: $STAGED files | Unstaged: $UNSTAGED files"
else
  WARNINGS+=("Not a git repository")
fi

# ─── Install dependencies if needed ─────────────────────────────────────

PM="$(node_pm)"
case "$STACK" in
  bun|node)
    if [[ -f "$PROJECT_ROOT/package.json" ]] && [[ ! -d "$PROJECT_ROOT/node_modules" ]]; then
      log_info "Installing dependencies with $PM..."
      $PM install --frozen-lockfile 2>&1 || $PM install
    fi
    ;;
  python)
    if [[ -f "$PROJECT_ROOT/pyproject.toml" ]] && ! python3 -c "import tomllib" 2>/dev/null; then
      WARNINGS+=("Python deps may not be installed. Run: pip install -e .")
    fi
    ;;
esac

# ─── Report ──────────────────────────────────────────────────────────────

CONTENT="Stack: $STACK
Errors: ${#ERRORS[@]}
Warnings: ${#WARNINGS[@]}"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  for e in "${ERRORS[@]}"; do
    CONTENT+=$'\n'"ERROR: $e"
  done
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  for w in "${WARNINGS[@]}"; do
    CONTENT+=$'\n'"WARN:  $w"
  done
fi

EXIT_CODE=0
[[ ${#ERRORS[@]} -gt 0 ]] && EXIT_CODE=1

write_report "preflight.md" "Preflight Check" "$EXIT_CODE" "$CONTENT"
echo "$CONTENT"

exit $EXIT_CODE
