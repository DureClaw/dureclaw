# Mailbox

This directory contains inter-agent messages for the open-agent-harness.

## Message Format

Each message is a JSON file named: `{to}_{type}_{timestamp}.json`

```json
{
  "from": "orchestrator",
  "to": "builder",
  "type": "build_task",
  "payload": {
    "task_id": "task_001"
  },
  "timestamp": "2024-01-01T00:00:00Z",
  "read": false
}
```

## Message Types

| Type | From → To | Description |
|------|-----------|-------------|
| `plan_request` | orchestrator → planner | Request task decomposition |
| `plan_ready` | planner → orchestrator | Plan complete, tasks in state.json |
| `build_task` | orchestrator → builder | Implement a specific task |
| `build_done` | builder → orchestrator | Build complete |
| `verify` | orchestrator → verifier | Run verification checks |
| `verify_done` | verifier → orchestrator | Verification results |
| `review` | orchestrator → reviewer | Review changes |
| `review_done` | reviewer → orchestrator | Review results with fix instructions |
| `gate_failed` | harness → orchestrator | Completion gate failed, continue loop |

## Token Budget

All message payloads must be ≤ 200 tokens. Never include file contents.
Always use report paths (`.opencode/reports/...`) instead of raw output.
