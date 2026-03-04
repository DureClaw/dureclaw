---
name: workloop
description: Start the 5-agent development loop for a given goal
---

# /workloop — Agent Development Loop

Start the open-agent-harness 5-agent loop for a development goal.

## Usage

```
/workloop <goal description>
```

## What This Does

1. **Initializes state** — Creates a fresh `state.json` with your goal and a new run ID
2. **Starts the Orchestrator** — The primary agent takes control
3. **Runs the loop** — Planner → Builder → Verifier → Reviewer → Gate → repeat
4. **Exits when** — The completion gate (`09_completion_gate.sh`) exits 0, or max 5 loops reached

## Example

```
/workloop Add user authentication with JWT tokens to the Express API
```

## State Initialization

When you run `/workloop <goal>`, the following state is initialized:

```json
{
  "run_id": "<uuid>",
  "goal": "<your goal>",
  "status": "running",
  "loop_count": 0,
  "tasks": [],
  "current_task": null,
  "last_failure": null,
  "started_at": "<timestamp>",
  "updated_at": "<timestamp>"
}
```

## Orchestrator Instructions

You are the Orchestrator. A new workloop has started.

**Goal**: `$ARGUMENTS`

**Your first steps**:
1. Run `write_state({"run_id": "<generate-uuid>", "goal": "$ARGUMENTS", "status": "running", "loop_count": 0, "started_at": "<now>"})` to initialize
2. Run `run_hook("00_preflight.sh")` to verify the environment
3. If preflight passes, send `post_message` to `planner` with type `plan_request` and the goal
4. Wait for planner's response in mailbox, then begin the build loop

**Token constraint**: All inter-agent messages ≤ 200 tokens. No file contents in messages.

**Loop limit**: Maximum 5 loops. After 5, report status and exit.

## Loop End Conditions

| Condition | Action |
|-----------|--------|
| Gate exit 0 | ✅ Report success, suggest `/ship` |
| Gate exit 2 (no tests) | ❌ Ask Builder to add tests, re-loop |
| Gate exit 1 (failures) | ❌ Send failures to Builder, re-loop |
| Loop count ≥ 5 | ❌ Report blockers, request human intervention |
