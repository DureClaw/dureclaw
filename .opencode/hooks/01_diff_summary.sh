#!/usr/bin/env bash
# 01_diff_summary.sh — Summarize git diff since last commit (or HEAD)
# Writes diff summary to reports/diff_summary.md

source "$(dirname "$0")/_lib.sh"
hook_header "01_diff_summary"

cd "$PROJECT_ROOT"

# ─── Collect diff ────────────────────────────────────────────────────────

if ! git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null; then
  write_report "diff_summary.md" "Diff Summary" "0" "Not a git repository — skipping diff."
  echo "Not a git repository."
  exit 0
fi

# Staged + unstaged changes
DIFF_STAT=$(git diff HEAD --stat 2>/dev/null || git diff --stat 2>/dev/null || echo "(no diff)")
DIFF_FULL=$(git diff HEAD 2>/dev/null || git diff 2>/dev/null || echo "(no diff)")

CHANGED_FILES=$(git diff HEAD --name-only 2>/dev/null | wc -l | tr -d ' ')
INSERTIONS=$(echo "$DIFF_STAT" | grep -E 'insertion' | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
DELETIONS=$(echo "$DIFF_STAT" | grep -E 'deletion' | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")

SUMMARY="Changed files: $CHANGED_FILES
Insertions: $INSERTIONS
Deletions: $DELETIONS

--- Stat ---
$DIFF_STAT"

# ─── Write full diff report ──────────────────────────────────────────────

cat > "$REPORTS_DIR/diff_summary.md" <<EOF
# Diff Summary
- **Time**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- **Changed files**: $CHANGED_FILES
- **Insertions**: $INSERTIONS
- **Deletions**: $DELETIONS

## Stat

\`\`\`
$DIFF_STAT
\`\`\`

## Full Diff

\`\`\`diff
$DIFF_FULL
\`\`\`
EOF

echo "$SUMMARY"
echo "Report: $REPORTS_DIR/diff_summary.md"
exit 0
