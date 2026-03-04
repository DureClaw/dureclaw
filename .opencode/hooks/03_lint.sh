#!/usr/bin/env bash
# 03_lint.sh — Run linter
# Exit 0: no issues | Exit 1: lint errors

source "$(dirname "$0")/_lib.sh"
hook_header "03_lint"

cd "$PROJECT_ROOT"

STACK="$(detect_stack)"
PM="$(node_pm)"
OUTPUT=""
EXIT_CODE=0

case "$STACK" in
  bun|node)
    # Check package.json for lint script
    if [[ -f "$PROJECT_ROOT/package.json" ]]; then
      HAS_LINT=$(python3 -c "import json,sys; d=json.load(open('package.json')); print('yes' if 'lint' in d.get('scripts',{}) else 'no')" 2>/dev/null || echo "no")
      if [[ "$HAS_LINT" == "yes" ]]; then
        OUTPUT=$($PM run lint 2>&1) || EXIT_CODE=$?
      elif [[ -f "$PROJECT_ROOT/node_modules/.bin/eslint" ]]; then
        OUTPUT=$($PM exec eslint . --ext .ts,.tsx,.js,.jsx 2>&1) || EXIT_CODE=$?
      elif [[ -f "$PROJECT_ROOT/node_modules/.bin/biome" ]]; then
        OUTPUT=$($PM exec biome lint . 2>&1) || EXIT_CODE=$?
      else
        OUTPUT="No lint script or linter found. Skipping."
        log_warn "$OUTPUT"
      fi
    fi
    ;;
  python)
    if command -v ruff &>/dev/null; then
      OUTPUT=$(ruff check . 2>&1) || EXIT_CODE=$?
    elif command -v flake8 &>/dev/null; then
      OUTPUT=$(flake8 . 2>&1) || EXIT_CODE=$?
    elif command -v pylint &>/dev/null; then
      OUTPUT=$(pylint . 2>&1) || EXIT_CODE=$?
    else
      OUTPUT="No Python linter found (ruff/flake8/pylint). Skipping."
    fi
    ;;
  go)
    if command -v golangci-lint &>/dev/null; then
      OUTPUT=$(golangci-lint run 2>&1) || EXIT_CODE=$?
    else
      OUTPUT=$(go vet ./... 2>&1) || EXIT_CODE=$?
    fi
    ;;
  rust)
    OUTPUT=$(cargo clippy -- -D warnings 2>&1) || EXIT_CODE=$?
    ;;
  *)
    OUTPUT="Unknown stack. Skipping lint."
    ;;
esac

# Count error lines for summary
ERROR_COUNT=$(echo "$OUTPUT" | grep -cE '(error|Error|ERROR)' || true)

write_report "lint.md" "Lint Check" "$EXIT_CODE" "$OUTPUT"
echo "$OUTPUT"
echo "---"
echo "Exit: $EXIT_CODE | Errors found: $ERROR_COUNT"
exit $EXIT_CODE
