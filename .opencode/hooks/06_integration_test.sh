#!/usr/bin/env bash
# 06_integration_test.sh — Run integration tests (if available)
# Exit 0: pass | Exit 1: fail | Exit 2: skipped (no integration tests)

source "$(dirname "$0")/_lib.sh"
hook_header "06_integration_test"

cd "$PROJECT_ROOT"

STACK="$(detect_stack)"
PM="$(node_pm)"
OUTPUT=""
EXIT_CODE=0

# ─── Look for integration test markers ──────────────────────────────────

has_integration_tests() {
  # Check for common integration test patterns
  [[ -d "$PROJECT_ROOT/tests/integration" ]] && return 0
  [[ -d "$PROJECT_ROOT/test/integration" ]] && return 0
  [[ -d "$PROJECT_ROOT/e2e" ]] && return 0
  find "$PROJECT_ROOT" -maxdepth 3 -name "*.integration.test.*" 2>/dev/null | grep -q . && return 0
  find "$PROJECT_ROOT" -maxdepth 3 -name "*.e2e.test.*" 2>/dev/null | grep -q . && return 0

  # Check package.json for test:integration script
  if [[ -f "$PROJECT_ROOT/package.json" ]]; then
    python3 -c "import json; d=json.load(open('package.json')); exit(0 if 'test:integration' in d.get('scripts',{}) else 1)" 2>/dev/null && return 0
    python3 -c "import json; d=json.load(open('package.json')); exit(0 if 'test:e2e' in d.get('scripts',{}) else 1)" 2>/dev/null && return 0
  fi

  return 1
}

if ! has_integration_tests; then
  OUTPUT="No integration tests found. Skipping."
  log_info "$OUTPUT"
  write_report "integration_test.md" "Integration Tests" "0" "$OUTPUT"
  echo "$OUTPUT"
  exit 0
fi

case "$STACK" in
  bun|node)
    if python3 -c "import json; d=json.load(open('package.json')); exit(0 if 'test:integration' in d.get('scripts',{}) else 1)" 2>/dev/null; then
      OUTPUT=$($PM run test:integration 2>&1) || EXIT_CODE=$?
    elif python3 -c "import json; d=json.load(open('package.json')); exit(0 if 'test:e2e' in d.get('scripts',{}) else 1)" 2>/dev/null; then
      OUTPUT=$($PM run test:e2e 2>&1) || EXIT_CODE=$?
    elif [[ -d "$PROJECT_ROOT/tests/integration" ]]; then
      OUTPUT=$($PM exec vitest run tests/integration 2>&1 || $PM exec jest tests/integration 2>&1) || EXIT_CODE=$?
    fi
    ;;
  python)
    if [[ -d "$PROJECT_ROOT/tests/integration" ]]; then
      OUTPUT=$(pytest tests/integration -v 2>&1) || EXIT_CODE=$?
    else
      OUTPUT=$(pytest -m integration -v 2>&1) || EXIT_CODE=$?
    fi
    ;;
  go)
    OUTPUT=$(go test ./... -tags integration -v 2>&1) || EXIT_CODE=$?
    ;;
  rust)
    OUTPUT=$(cargo test --test '*' 2>&1) || EXIT_CODE=$?
    ;;
  *)
    OUTPUT="Unknown stack. Skipping integration tests."
    EXIT_CODE=2
    ;;
esac

write_report "integration_test.md" "Integration Tests" "$EXIT_CODE" "$OUTPUT"
echo "$OUTPUT"
echo "---"
echo "Exit: $EXIT_CODE"
exit $EXIT_CODE
