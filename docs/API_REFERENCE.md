# DureClaw API Reference

For contributors and advanced integrations.

---

## MCP Tools

Register MCP with: `bash <(curl -fsSL https://dureclaw.baryon.ai/mcp)`

| Tool | Description |
|------|-------------|
| `mcp__oah__get_presence` | List online agents |
| `mcp__oah__send_task` | Send a task to an agent |
| `mcp__oah__receive_task` | Wait for incoming task (30s timeout) |
| `mcp__oah__complete_task` | Report task completion |
| `mcp__oah__read_state` | Read Work Key state |
| `mcp__oah__write_state` | Update Work Key state |
| `mcp__oah__read_mailbox` | Read mailbox messages |
| `mcp__oah__post_message` | Send a mailbox message |

### Usage in Claude Code

```
mcp__oah__get_presence → online agents + roles
mcp__oah__send_task task_id=t1 role=builder instructions="[SHELL] make build"
mcp__oah__read_state → work key progress
```

---

## REST API

Base URL: `http://SERVER_IP:4000`

### Health & Presence

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Server status + work key count |
| GET | `/api/presence` | Connected agents (all work keys) |
| GET | `/api/capabilities` | Agent capability matrix |

### Work Keys

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/work-keys` | List all work keys |
| GET | `/api/work-keys/latest` | Most recent work key (404 if none) |
| POST | `/api/work-keys` | Create new work key |

### State

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/state/:wk` | Read work key state |
| PATCH | `/api/state/:wk` | Update work key state |
| GET | `/api/team/:wk` | Team configuration |

### Tasks

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/task` | Dispatch task (Phoenix broadcast + mailbox) |
| GET | `/api/task/:id` | Poll task result |
| POST | `/api/task/:id/result` | Submit task result |
| POST | `/api/task/:id/cancel` | Cancel in-flight task |

**POST `/api/task` body:**
```json
{
  "work_key": "LN-20260406-001",
  "role": "builder",
  "to": "builder@mac-mini",
  "instructions": "[SHELL] make build",
  "depends_on": []
}
```

### Mailbox (offline queue)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/mailbox/:agent` | Read queued messages |
| POST | `/api/mailbox/:agent` | Enqueue message |

---

## Phoenix Channel Protocol

WebSocket: `ws://host:4000/socket/websocket?vsn=2.0.0`
Topic: `work:{WORK_KEY}`

**5-tuple format:** `[join_ref, ref, topic, event, payload]`

| Event | Direction | Description |
|-------|-----------|-------------|
| `phx_join` | client → server | Register agent with presence payload |
| `phx_reply` | server → client | Join acknowledgement |
| `heartbeat` | client → server | Keepalive every 30s (topic: `phoenix`) |
| `task.assign` | server → client | Task dispatched to agent |
| `task.result` | client → server | Task completion report |
| `task.cancel` | server → client | Cancel running task |
| `task.progress` | client → server | Streaming progress update |
| `mailbox.delivered` | server → client | Queued messages delivered on join |

**phx_join payload:**
```json
{
  "agent_name": "builder@mac-mini",
  "role": "builder",
  "machine": "mac-mini",
  "capabilities": ["claude", "opencode", "shell"]
}
```

**task.result payload:**
```json
{
  "task_id": "http-123",
  "to": "http@controller",
  "from": "builder@mac-mini",
  "role": "builder",
  "status": "done",
  "output": "...",
  "exit_code": 0
}
```

---

## Task Instruction Prefixes

| Prefix | Handled by | Description |
|--------|-----------|-------------|
| `[SHELL] <cmd>` | All agents | Run shell command directly, no LLM |
| `[ORCHESTRATE] <goal>` | Orchestrator agent | AI decomposes goal + dispatches subtasks |
| `[ANALYZE_PIPELINE] ...` | Orchestrator only | Phase 1/2 analysis pipeline |
| *(none)* | All agents | AI backend (claude / opencode / aider) |
