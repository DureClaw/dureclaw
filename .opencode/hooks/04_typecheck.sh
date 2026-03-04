#!/usr/bin/env bash
# 04_typecheck.sh — Run type checker
# Exit 0: no type errors | Exit 1: type errors found

source "$(dirname "$0")/_lib.sh"
hook_header "04_typecheck"

cd "$PROJECT_ROOT"

STACK="$(detect_stack)"
PM="$(node_pm)"
OUTPUT=""
EXIT_CODE=0

case "$STACK" in
  bun|node)
    if [[ -f "$PROJECT_ROOT/tsconfig.json" ]]; then
      # Check for typecheck script
      HAS_TC=$(python3 -c "import json,sys; d=json.load(open('package.json')); print('yes' if 'typecheck' in d.get('scripts',{}) else 'no')" 2>/dev/null || echo "no")
      if [[ "$HAS_TC" == "yes" ]]; then
        OUTPUT=$($PM run typecheck 2>&1) || EXIT_CODE=$?
      elif command -v tsc &>/dev/null; then
        OUTPUT=$(tsc --noEmit 2>&1) || EXIT_CODE=$?
      elif [[ -f "$PROJECT_ROOT/node_modules/.bin/tsc" ]]; then
        OUTPUT=$($PM exec tsc --noEmit 2>&1) || EXIT_CODE=$?
      else
        OUTPUT="TypeScript config found but no tsc binary. Skipping."
        log_warn "$OUTPUT"
      fi
    elif [[ -f "$PROJECT_ROOT/jsconfig.json" ]]; then
      OUTPUT="jsconfig.json found (JavaScript project). Skipping type check."
    else
      OUTPUT="No tsconfig.json found. Skipping type check."
    fi
    ;;
  python)
    if command -v mypy &>/dev/null; then
      OUTPUT=$(mypy . 2>&1) || EXIT_CODE=$?
    elif command -v pyright &>/dev/null; then
      OUTPUT=$(pyright . 2>&1) || EXIT_CODE=$?
    else
      OUTPUT="No Python type checker found (mypy/pyright). Skipping."
    fi
    ;;
  go)
    # Go is statically typed — compilation is the type check
    OUTPUT=$(go build ./... 2>&1) || EXIT_CODE=$?
    ;;
  rust)
    # Rust compilation is the type check
    OUTPUT=$(cargo check 2>&1) || EXIT_CODE=$?
    ;;
  *)
    OUTPUT="Unknown stack. Skipping type check."
    ;;
esac

TYPE_ERRORS=$(echo "$OUTPUT" | grep -cE '(error TS|error\[|type error|TypeError)' || true)

write_report "typecheck.md" "Type Check" "$EXIT_CODE" "$OUTPUT"
echo "$OUTPUT"
echo "---"
echo "Exit: $EXIT_CODE | Type errors: $TYPE_ERRORS"
exit $EXIT_CODE
