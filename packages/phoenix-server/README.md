# harness-server (Elixir/Phoenix)

Real-time message bus for the open-agent-harness distributed multi-agent workflow.

Replaces the Bun prototype (`packages/state-server/`) with a production-grade Elixir/Phoenix server using native Phoenix Channel protocol.

---

## Requirements

- Elixir ≥ 1.15 + Erlang/OTP 26
- `mix` (comes with Elixir)

Install Elixir on macOS:
```bash
brew install elixir
```

On NAS (Debian/Ubuntu):
```bash
# Add Erlang/Elixir repo
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt update && sudo apt install esl-erlang elixir
```

---

## Setup

```bash
cd packages/phoenix-server
mix deps.get
mix phx.server
```

Server starts at `http://0.0.0.0:4000` by default.

---

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `PORT` | `4000` | HTTP/WebSocket port |
| `HOST` | `0.0.0.0` | Bind address |
| `SECRET_KEY_BASE` | dev default | Phoenix secret (change in prod) |

---

## REST API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/health` | Server health check |
| `GET` | `/api/presence` | All online agents |
| `POST` | `/api/work-keys` | Create new Work Key |
| `GET` | `/api/state/:wk` | Get state for Work Key |
| `PATCH` | `/api/state/:wk` | Update state for Work Key |
| `GET` | `/api/mailbox/:agent` | Read agent mailbox (clears it) |
| `POST` | `/api/mailbox/:agent` | Post to offline agent mailbox |

---

## Phoenix Channel Protocol

WebSocket endpoint: `ws://host:4000/socket/websocket?vsn=2.0.0`

Message format (Phoenix 5-tuple):
```
[join_ref, ref, topic, event, payload]
```

### Join a channel

```json
["1", "1", "work:LN-20260308-001", "phx_join", {
  "agent_name": "builder@gpu",
  "role": "builder",
  "machine": "gpu"
}]
```

Server replies:
```json
["1", "1", "work:LN-20260308-001", "phx_reply", {
  "status": "ok",
  "response": { "work_key": "LN-20260308-001", "presences": {...} }
}]
```

### Heartbeat (every 30s)

```json
[null, "hb-1", "phoenix", "heartbeat", {}]
```

Server replies:
```json
[null, "hb-1", "phoenix", "phx_reply", { "status": "ok", "response": {} }]
```

### Task events

```json
[null, "2", "work:LN-20260308-001", "task.assign", {
  "to": "builder@gpu",
  "task_id": "task-001",
  "role": "builder",
  "instructions": "Implement feature X",
  "context": {}
}]
```

### Supported channel events

| Event | Direction | Description |
|-------|-----------|-------------|
| `phx_join` | client→server | Join channel |
| `agent.hello` | both | Presence announcement |
| `agent.bye` | server→client | Agent left |
| `task.assign` | client→server | Assign task |
| `task.progress` | client→server | Progress update |
| `task.blocked` | client→server | Blocker report |
| `task.result` | client→server | Task completion |
| `task.approval_requested` | client→server | Human-in-the-loop gate |
| `state.update` | client→server | Update Work Key state |
| `state.get` | client→server | Read Work Key state |
| `mailbox.post` | client→server | Post to offline agent |
| `mailbox.read` | client→server | Read own mailbox |
| `mailbox.message` | server→client | Deliver queued message |

---

## Architecture

```
HarnessServer.Application (Supervisor)
├── HarnessServer.StateStore (GenServer + ETS)
│   ├── :harness_state   — work_key → state_map
│   └── :harness_mailbox — agent_name → [messages]
├── Phoenix.PubSub (HarnessServer.PubSub)
├── HarnessServer.Presence (Phoenix.Presence)
└── HarnessServer.Endpoint (Phoenix HTTP+WS)
    ├── /socket → HarnessServer.UserSocket
    │   └── work:* → HarnessServer.WorkChannel
    └── /* → HarnessServer.Router (REST)
```

---

## Production (NAS / Tailscale)

```bash
# Set env
export PORT=4000
export SECRET_KEY_BASE=$(mix phx.gen.secret)

# Build release
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release

# Run
_build/prod/rel/harness_server/bin/harness_server start
```

Agents connect via Tailscale:
```bash
STATE_SERVER=ws://100.x.x.x:4000 \
AGENT_NAME=builder@gpu \
AGENT_ROLE=builder \
WORK_KEY=LN-20260308-001 \
bun run packages/agent-daemon/src/index.ts
```
