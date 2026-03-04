#!/usr/bin/env bash
# 05_unit_test.sh — Run unit tests
# Exit 0: all pass | Exit 1: failures | Exit 2: no tests found

source "$(dirname "$0")/_lib.sh"
hook_header "05_unit_test"

cd "$PROJECT_ROOT"

STACK="$(detect_stack)"
PM="$(node_pm)"
OUTPUT=""
EXIT_CODE=0

case "$STACK" in
  bun|node)
    HAS_TEST=$(python3 -c "import json,sys; d=json.load(open('package.json')); print('yes' if 'test' in d.get('scripts',{}) else 'no')" 2>/dev/null || echo "no")
    if [[ "$HAS_TEST" == "yes" ]]; then
      OUTPUT=$($PM test 2>&1) || EXIT_CODE=$?
    elif [[ "$STACK" == "bun" ]]; then
      # Bun native test runner
      if find . -name "*.test.ts" -o -name "*.test.js" -o -name "*.spec.ts" | grep -q .; then
        OUTPUT=$(bun test 2>&1) || EXIT_CODE=$?
      else
        OUTPUT="No test files found (*.test.ts / *.spec.ts)."
        EXIT_CODE=2
      fi
    elif [[ -f "$PROJECT_ROOT/node_modules/.bin/vitest" ]]; then
      OUTPUT=$($PM exec vitest run 2>&1) || EXIT_CODE=$?
    elif [[ -f "$PROJECT_ROOT/node_modules/.bin/jest" ]]; then
      OUTPUT=$($PM exec jest --passWithNoTests 2>&1) || EXIT_CODE=$?
    else
      OUTPUT="No test runner found. Skipping unit tests."
      EXIT_CODE=2
    fi
    ;;
  python)
    if command -v pytest &>/dev/null; then
      OUTPUT=$(pytest -v 2>&1) || EXIT_CODE=$?
    elif command -v python3 &>/dev/null; then
      OUTPUT=$(python3 -m pytest -v 2>&1) || EXIT_CODE=$?
    else
      OUTPUT="No Python test runner found. Skipping."
      EXIT_CODE=2
    fi
    ;;
  go)
    OUTPUT=$(go test ./... -v 2>&1) || EXIT_CODE=$?
    ;;
  rust)
    OUTPUT=$(cargo test 2>&1) || EXIT_CODE=$?
    ;;
  *)
    OUTPUT="Unknown stack. Skipping unit tests."
    EXIT_CODE=2
    ;;
esac

# Parse test counts from output
PASSED=$(echo "$OUTPUT" | grep -cE '(✓|passed|PASS|ok)' || true)
FAILED=$(echo "$OUTPUT" | grep -cE '(✗|failed|FAIL|FAILED)' || true)

write_report "unit_test.md" "Unit Tests" "$EXIT_CODE" "$OUTPUT"
echo "$OUTPUT"
echo "---"
echo "Exit: $EXIT_CODE | Passed: ~$PASSED | Failed: ~$FAILED"
exit $EXIT_CODE
