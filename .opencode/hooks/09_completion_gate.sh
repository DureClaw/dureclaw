#!/usr/bin/env bash
# 09_completion_gate.sh — Final gate: must pass ALL checks to proceed
#
# Exit 0: ALL gates passed → safe to ship
# Exit 1: hard failures (type errors, build errors, test failures)
# Exit 2: no tests found → gate cannot be confirmed
# Exit 3: gate config error

source "$(dirname "$0")/_lib.sh"
hook_header "09_completion_gate"

cd "$PROJECT_ROOT"

GATE_RESULTS=()
OVERALL_STATUS="PASS"
HARD_FAIL=0
NO_TESTS=0

# ─── Run all checks ─────────────────────────────────────────────────────

run_gate_check() {
  local name="$1"
  local script="$2"
  local required="${3:-true}"

  log_info "Running gate check: $name"
  local output exit_code=0
  output=$(bash "$HOOK_DIR/$script" 2>&1) || exit_code=$?

  local status
  if [[ $exit_code -eq 0 ]]; then
    status="PASS"
  elif [[ $exit_code -eq 2 ]]; then
    status="SKIP"
    [[ "$name" == "unit_tests" ]] && NO_TESTS=1
  else
    status="FAIL"
    [[ "$required" == "true" ]] && HARD_FAIL=1 && OVERALL_STATUS="FAIL"
  fi

  GATE_RESULTS+=("$name|$status|$exit_code")
  log_info "  → $name: $status (exit $exit_code)"
}

# Run checks in order (skipping format which is advisory)
run_gate_check "preflight"   "00_preflight.sh"       "true"
run_gate_check "lint"        "03_lint.sh"             "true"
run_gate_check "typecheck"   "04_typecheck.sh"        "true"
run_gate_check "unit_tests"  "05_unit_test.sh"        "true"
run_gate_check "build"       "07_build.sh"            "false"  # advisory only

# ─── Handle no tests ──────────────────────────────────────────────────────

if [[ $NO_TESTS -eq 1 ]]; then
  log_warn "No unit tests found. Gate requires at least some tests to pass."
  OVERALL_STATUS="NO_TESTS"
fi

# ─── Run fail classifier if any failures ─────────────────────────────────

if [[ "$OVERALL_STATUS" != "PASS" ]]; then
  log_info "Running fail classifier..."
  python3 "$HOOK_DIR/08_fail_classifier.py" 2>&1 | tail -5 || true
fi

# ─── Write gate report ────────────────────────────────────────────────────

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STATUS_ICON=$( [[ "$OVERALL_STATUS" == "PASS" ]] && echo "✅" || echo "❌" )

{
  echo "# Completion Gate Report"
  echo "- **Time**: $TIMESTAMP"
  echo "- **Overall**: $STATUS_ICON $OVERALL_STATUS"
  echo ""
  echo "## Gate Results"
  echo ""
  echo "| Check | Status | Exit |"
  echo "|-------|--------|------|"
  for result in "${GATE_RESULTS[@]}"; do
    IFS='|' read -r name status exit_code <<< "$result"
    if [[ "$status" == "PASS" ]]; then
      icon="✅"
    elif [[ "$status" == "SKIP" ]]; then
      icon="⏭️"
    else
      icon="❌"
    fi
    echo "| $name | $icon $status | $exit_code |"
  done
  echo ""
  if [[ "$OVERALL_STATUS" == "PASS" ]]; then
    echo "## ✅ All required gates passed. Ready to ship."
  elif [[ "$OVERALL_STATUS" == "NO_TESTS" ]]; then
    echo "## ⚠️ Gate blocked: No tests found."
    echo "Add unit tests and re-run the loop."
  else
    echo "## ❌ Gate failed. See individual reports in .opencode/reports/"
    echo ""
    echo "Next steps:"
    echo "1. Review .opencode/reports/fail_classifier.md"
    echo "2. Delegate fixes to Builder agent"
    echo "3. Re-run the verification loop"
  fi
} > "$REPORTS_DIR/completion_gate.md"

cat "$REPORTS_DIR/completion_gate.md"

# ─── Exit code ──────────────────────────────────────────────────────────

case "$OVERALL_STATUS" in
  PASS)     exit 0 ;;
  NO_TESTS) exit 2 ;;
  FAIL)     exit 1 ;;
  *)        exit 3 ;;
esac
