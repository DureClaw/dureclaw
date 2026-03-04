#!/usr/bin/env python3
"""
08_fail_classifier.py — Classify failures from hook reports
Reads all reports in .opencode/reports/ and produces a prioritized failure list.
Exit 0: no failures | Exit 1: failures found
"""

import json
import os
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from datetime import datetime, timezone

# ─── Config ──────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent
OPENCODE_DIR = SCRIPT_DIR.parent
PROJECT_ROOT = OPENCODE_DIR.parent
REPORTS_DIR = OPENCODE_DIR / "reports"
REPORTS_DIR.mkdir(parents=True, exist_ok=True)

# ─── Failure Categories ───────────────────────────────────────────────────────

@dataclass
class Failure:
    source: str       # which report (lint, typecheck, etc.)
    category: str     # type_error | lint_error | test_failure | build_error | other
    severity: str     # critical | high | medium | low
    message: str      # human-readable description
    file_ref: str     # file:line if available
    raw_line: str     # original line from report


CATEGORY_PATTERNS = [
    # TypeScript type errors
    (r"error TS\d+", "type_error", "high"),
    (r"Type '.*?' is not assignable", "type_error", "high"),
    (r"Cannot find name '", "type_error", "medium"),
    # Build errors
    (r"ERROR in ", "build_error", "critical"),
    (r"Build failed", "build_error", "critical"),
    (r"failed to compile", "build_error", "critical"),
    # Test failures
    (r"FAIL\s+\w", "test_failure", "high"),
    (r"× |✗ |FAILED", "test_failure", "high"),
    (r"AssertionError", "test_failure", "high"),
    (r"Error: expect", "test_failure", "medium"),
    # Lint errors
    (r"error\s+no-unused", "lint_error", "low"),
    (r"error\s+@typescript", "lint_error", "medium"),
    (r"\d+ error", "lint_error", "medium"),
    # Python
    (r"SyntaxError:", "type_error", "critical"),
    (r"ImportError:", "type_error", "high"),
    (r"FAILED tests/", "test_failure", "high"),
    # Go
    (r"undefined:", "type_error", "high"),
    (r"FAIL\t", "test_failure", "high"),
    # Generic
    (r"panic:", "build_error", "critical"),
    (r"fatal error", "build_error", "critical"),
]

FILE_REF_PATTERN = re.compile(r"([\w./\\-]+\.\w+):(\d+)(?::(\d+))?")


def classify_line(line: str, source: str) -> Failure | None:
    for pattern, category, severity in CATEGORY_PATTERNS:
        if re.search(pattern, line, re.IGNORECASE):
            file_match = FILE_REF_PATTERN.search(line)
            file_ref = f"{file_match.group(1)}:{file_match.group(2)}" if file_match else ""
            return Failure(
                source=source,
                category=category,
                severity=severity,
                message=line.strip()[:200],
                file_ref=file_ref,
                raw_line=line.rstrip(),
            )
    return None


def parse_report(report_path: Path) -> list[Failure]:
    failures = []
    source = report_path.stem  # e.g., "lint", "typecheck"
    try:
        content = report_path.read_text(encoding="utf-8")
    except Exception:
        return []

    # Only process FAIL reports (skip PASS ones)
    if "Exit Code**: 0" in content or "Status**: ✅ PASS" in content:
        return []

    for line in content.splitlines():
        failure = classify_line(line, source)
        if failure:
            failures.append(failure)

    return failures


def severity_rank(s: str) -> int:
    return {"critical": 0, "high": 1, "medium": 2, "low": 3}.get(s, 4)


def main() -> int:
    all_failures: list[Failure] = []

    # Read all report files
    report_files = sorted(REPORTS_DIR.glob("*.md"))
    scanned = 0
    for rp in report_files:
        if rp.name == "fail_classifier.md":
            continue
        failures = parse_report(rp)
        all_failures.extend(failures)
        scanned += 1

    # Sort by severity
    all_failures.sort(key=lambda f: severity_rank(f.severity))

    # Deduplicate by message
    seen: set[str] = set()
    unique: list[Failure] = []
    for f in all_failures:
        key = f"{f.category}:{f.message[:80]}"
        if key not in seen:
            seen.add(key)
            unique.append(f)

    # Build report
    exit_code = 1 if unique else 0
    status = "❌ FAIL" if unique else "✅ PASS"

    lines = [
        "# Failure Classifier Report",
        f"- **Time**: {datetime.now(timezone.utc).isoformat()}Z",
        f"- **Reports scanned**: {scanned}",
        f"- **Total failures**: {len(unique)}",
        f"- **Status**: {status}",
        "",
    ]

    if unique:
        lines.append("## Failures (sorted by severity)")
        lines.append("")
        for i, f in enumerate(unique, 1):
            lines.append(f"### {i}. [{f.severity.upper()}] {f.category} — {f.source}")
            lines.append(f"- **File**: `{f.file_ref or 'unknown'}`")
            lines.append(f"- **Message**: {f.message}")
            lines.append("")

        lines.append("## Summary by Category")
        lines.append("")
        from collections import Counter
        cat_counts = Counter(f.category for f in unique)
        for cat, count in sorted(cat_counts.items()):
            lines.append(f"- {cat}: {count}")

        # Machine-readable JSON summary
        summary = {
            "total": len(unique),
            "by_severity": dict(Counter(f.severity for f in unique)),
            "by_category": dict(cat_counts),
            "top_failures": [asdict(f) for f in unique[:5]],
        }
        lines.append("")
        lines.append("## JSON Summary")
        lines.append("")
        lines.append("```json")
        lines.append(json.dumps(summary, indent=2))
        lines.append("```")
    else:
        lines.append("No failures detected across all reports.")

    report_content = "\n".join(lines) + "\n"
    report_path = REPORTS_DIR / "fail_classifier.md"
    report_path.write_text(report_content, encoding="utf-8")

    # Print brief summary to stdout
    print(f"{status} — {len(unique)} failures found across {scanned} reports")
    if unique:
        print(f"Top issue: [{unique[0].severity}] {unique[0].category} in {unique[0].source}")
        if unique[0].file_ref:
            print(f"  → {unique[0].file_ref}: {unique[0].message[:80]}")
    print(f"Report: {report_path}")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
