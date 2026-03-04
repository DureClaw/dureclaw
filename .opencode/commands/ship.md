---
description: Run final gate checks and propose a git commit if all pass
agent: orchestrator
---

Run the ship sequence for the current project.

**Requested commit message hint**: $ARGUMENTS

## Steps

1. Run `bash .opencode/hooks/00_preflight.sh`
   - If exit ≠ 0: Report the error from `.opencode/reports/preflight.md` and STOP. Do not commit.

2. Run `bash .opencode/hooks/07_build.sh`
   - If exit ≠ 0: Report build failure from `.opencode/reports/build.md` and STOP.

3. Run `bash .opencode/hooks/09_completion_gate.sh`
   - If exit ≠ 0: Show the gate report from `.opencode/reports/completion_gate.md` and STOP.
   - Output: "❌ Gate failed. Not committing. Run /workloop to fix."

4. If all 3 passed:
   - Read `.opencode/state/state.json` for goal and loop_count
   - Propose this commit message (adjust type based on the goal):
     ```
     <type>: $ARGUMENTS

     Co-authored-by: open-agent-harness
     Goal: <goal from state.json>
     ```
   - Ask the user to confirm before running `git add -A && git commit`

## Commit type guide
- `feat:` new feature
- `fix:` bug fix
- `refactor:` restructure without behavior change
- `test:` adding tests
- `chore:` tooling or dependencies
- `docs:` documentation only
