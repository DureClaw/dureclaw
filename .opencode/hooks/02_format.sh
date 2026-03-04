#!/usr/bin/env bash
# 02_format.sh — Auto-format code (check mode only by default)
# Set FORMAT_FIX=1 to auto-fix instead of just checking

source "$(dirname "$0")/_lib.sh"
hook_header "02_format"

cd "$PROJECT_ROOT"

STACK="$(detect_stack)"
PM="$(node_pm)"
FIX_MODE="${FORMAT_FIX:-0}"
OUTPUT=""
EXIT_CODE=0

case "$STACK" in
  bun|node)
    # Try prettier, biome, or eslint --fix
    if [[ -f "$PROJECT_ROOT/node_modules/.bin/prettier" ]] || \
       [[ -f "$PROJECT_ROOT/.prettierrc" ]] || \
       [[ -f "$PROJECT_ROOT/.prettierrc.json" ]] || \
       [[ -f "$PROJECT_ROOT/prettier.config.js" ]]; then
      if [[ "$FIX_MODE" == "1" ]]; then
        OUTPUT=$($PM run prettier --write . 2>&1) || EXIT_CODE=$?
      else
        OUTPUT=$($PM exec prettier --check . 2>&1) || EXIT_CODE=$?
      fi
    elif [[ -f "$PROJECT_ROOT/node_modules/.bin/biome" ]] || \
         [[ -f "$PROJECT_ROOT/biome.json" ]]; then
      if [[ "$FIX_MODE" == "1" ]]; then
        OUTPUT=$($PM exec biome format --write . 2>&1) || EXIT_CODE=$?
      else
        OUTPUT=$($PM exec biome format . 2>&1) || EXIT_CODE=$?
      fi
    else
      OUTPUT="No formatter found (prettier/biome). Skipping."
      log_warn "$OUTPUT"
    fi
    ;;
  python)
    if command -v black &>/dev/null; then
      if [[ "$FIX_MODE" == "1" ]]; then
        OUTPUT=$(black . 2>&1) || EXIT_CODE=$?
      else
        OUTPUT=$(black --check . 2>&1) || EXIT_CODE=$?
      fi
    elif command -v ruff &>/dev/null; then
      if [[ "$FIX_MODE" == "1" ]]; then
        OUTPUT=$(ruff format . 2>&1) || EXIT_CODE=$?
      else
        OUTPUT=$(ruff format --check . 2>&1) || EXIT_CODE=$?
      fi
    else
      OUTPUT="No formatter found (black/ruff). Skipping."
    fi
    ;;
  go)
    if [[ "$FIX_MODE" == "1" ]]; then
      OUTPUT=$(gofmt -w . 2>&1) || EXIT_CODE=$?
    else
      UNFORMATTED=$(gofmt -l . 2>&1)
      if [[ -n "$UNFORMATTED" ]]; then
        OUTPUT="Unformatted files:$'\n'$UNFORMATTED"
        EXIT_CODE=1
      else
        OUTPUT="All files formatted."
      fi
    fi
    ;;
  rust)
    if [[ "$FIX_MODE" == "1" ]]; then
      OUTPUT=$(cargo fmt 2>&1) || EXIT_CODE=$?
    else
      OUTPUT=$(cargo fmt --check 2>&1) || EXIT_CODE=$?
    fi
    ;;
  *)
    OUTPUT="Unknown stack. Skipping format check."
    ;;
esac

write_report "format.md" "Format Check" "$EXIT_CODE" "$OUTPUT"
echo "$OUTPUT"
exit $EXIT_CODE
