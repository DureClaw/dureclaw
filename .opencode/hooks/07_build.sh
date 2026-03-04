#!/usr/bin/env bash
# 07_build.sh — Run production build
# Exit 0: build success | Exit 1: build failed

source "$(dirname "$0")/_lib.sh"
hook_header "07_build"

cd "$PROJECT_ROOT"

STACK="$(detect_stack)"
PM="$(node_pm)"
OUTPUT=""
EXIT_CODE=0

case "$STACK" in
  bun|node)
    HAS_BUILD=$(python3 -c "import json,sys; d=json.load(open('package.json')); print('yes' if 'build' in d.get('scripts',{}) else 'no')" 2>/dev/null || echo "no")
    if [[ "$HAS_BUILD" == "yes" ]]; then
      OUTPUT=$($PM run build 2>&1) || EXIT_CODE=$?
    else
      OUTPUT="No build script in package.json. Skipping."
      log_warn "$OUTPUT"
    fi
    ;;
  python)
    if [[ -f "$PROJECT_ROOT/pyproject.toml" ]]; then
      OUTPUT=$(python3 -m build 2>&1) || EXIT_CODE=$?
    else
      OUTPUT="No pyproject.toml found. Skipping Python build."
    fi
    ;;
  go)
    OUTPUT=$(go build ./... 2>&1) || EXIT_CODE=$?
    ;;
  rust)
    OUTPUT=$(cargo build --release 2>&1) || EXIT_CODE=$?
    ;;
  *)
    OUTPUT="Unknown stack. Skipping build."
    ;;
esac

write_report "build.md" "Build" "$EXIT_CODE" "$OUTPUT"
echo "$OUTPUT"
echo "---"
echo "Exit: $EXIT_CODE"
exit $EXIT_CODE
