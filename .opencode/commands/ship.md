---
name: ship
description: Run final gate checks and prepare a git commit if all pass
---

# /ship — Ship Command

Run all gate checks and, if they pass, prepare a git commit.

## Usage

```
/ship [commit message]
```

## What This Does

1. Runs `00_preflight.sh` — environment check
2. Runs `07_build.sh` — production build
3. Runs `09_completion_gate.sh` — all required checks
4. If gate passes → stages changed files and proposes a commit message
5. If gate fails → shows the failure report, does NOT commit

## Example

```
/ship feat: add JWT authentication
```

## Orchestrator Instructions

Run the ship sequence:

1. `run_hook("00_preflight.sh")` — if exit ≠ 0, STOP and report
2. `run_hook("07_build.sh")` — if exit ≠ 0, ask Builder to fix, then retry
3. `run_hook("09_completion_gate.sh")` — if exit ≠ 0, report failures and STOP

If all 3 pass:
- Read `state.json` for the goal description
- Propose a conventional commit message:
  ```
  <type>(<scope>): <short description>

  Co-authored by open-agent-harness
  Goal: <goal from state.json>
  Loop count: <loop_count from state.json>
  ```
- Ask user to confirm before running `git add` and `git commit`

## Commit Types

| Prefix | When to use |
|--------|-------------|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `refactor:` | Code restructure, no behavior change |
| `test:` | Adding tests |
| `chore:` | Tooling, dependencies |
| `docs:` | Documentation only |

## Gate Failure

If the gate fails, output:
```
❌ Gate failed. Not committing.
Report: .opencode/reports/completion_gate.md

Top failures:
<first 3 lines from fail_classifier.md>

Run /workloop to continue fixing.
```
