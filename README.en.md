# DureClaw (두레클로)

<img src="https://github.com/user-attachments/assets/7ed690a2-92e8-4fbd-a0c8-510f6ee3944e" alt="DureClaw Logo" width="100%" />

Orchestration infrastructure where AI agents across distributed devices collaborate in real time through a single channel.
Uses Claude Code as the orchestrator and connects AI agents on each machine as workers to form a multi-machine AI team.

> *Dure (두레): A cooperative farming system from Joseon-era Korea, where an entire village worked together across each farmer's individual fields.*
> *DureClaw embodies that spirit in AI agents — each on their own machine, one shared goal, one crew.*

[![GitHub](https://img.shields.io/badge/DureClaw-dureclaw-black?logo=github)](https://github.com/DureClaw/dureclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![npm](https://img.shields.io/badge/npm-%40dureclaw%2Fmcp-red?logo=npm)](https://www.npmjs.com/package/@dureclaw/mcp)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-io.github.dureclaw%2Fmcp-purple?logo=anthropic)](https://registry.modelcontextprotocol.io)
[![Smithery](https://img.shields.io/badge/Smithery-dureclaw%2Fmcp-blue)](https://smithery.ai/server/@dureclaw/mcp)

🌐 **[한국어](./README.md)** | **English**

---

## Installation

### Step 1 — Add Plugin to Claude Code (Required)

```shell
/plugin marketplace add DureClaw/dureclaw
```

```shell
/plugin install dureclaw@dureclaw
```

> Manual registration: `oah setup-mcp` or `curl -fsSL .../scripts/setup-mcp.sh | bash`

**This alone is enough to get started.** Claude Code acts as the orchestrator and can execute tasks locally right away.

---

### Step 2+3 — Expand to Multi-Machine Team (Optional)

To distribute work across other machines, run the following inside **Claude Code CLI** — either as a command or in natural language:

```
/setup-team
```

Or use **natural language** — works the same way:

```
"set up the team"   "add a worker"   "setup team"
```

What happens automatically:
1. Check Phoenix server status → install if not running (**No Elixir required — uses Docker or pre-built binary**)
2. Auto-detect server IP (Tailscale preferred)
3. List currently online agents
4. Output ready-to-run worker install commands for each platform (macOS/Linux/Windows)

```
/team-status   ← Check team status (or "how many agents are online?", "show team status")
```

> Phoenix server runs **without Elixir — just Docker** is enough.
> `USE_DOCKER=1 bash <(curl -fsSL .../setup-server.sh)` or `docker compose up`

> Only run this when you need multi-machine distributed processing.

---

### Step 4 — Install Worker Agents (Each Remote Machine)

**Just tell Claude Code — it will guide you through it.**

```
"add a worker"   "connect a tester machine"   "add my Mac Mini to the team"
```

Claude auto-detects the server IP and provides **ready-to-copy-and-run commands** for each machine.
Even if Tailscale isn't installed, it will walk you through the setup step by step.

---

## Architecture

```
① Claude Code (Orchestrator, MacBook)
     /plugin install dureclaw@dureclaw
   └─ MCP (oah-mcp) → Phoenix WebSocket

② Phoenix Server (Message Bus)
     bash <(curl -fsSL .../setup-server.sh)   ← Docker or pre-built binary
   ws://host:4000

③ oah-agent (Worker, each machine)
     PHOENIX=ws://host:4000 ROLE=builder bash <(curl -fsSL .../setup-agent.sh)
   → WebSocket connect → receive task.assign
   → Execute AI backend (claude / opencode / gemini / aider / codex)
   → Return task.result
```

---

## Package Structure

```
dureclaw/
├── .claude-plugin/             Claude Code plugin metadata
│   ├── plugin.json
│   └── marketplace.json
│
├── .claude/
│   ├── commands/               Slash commands (/setup-team, /team-status)
│   ├── agents/                 Agent definitions (orchestrator, etc.)
│   └── skills/dureclaw/        DureClaw orchestration skills
│
├── packages/
│   ├── phoenix-server/         Elixir/Phoenix message bus (core)
│   ├── agent-daemon/           WebSocket agent daemon (oah-agent)
│   ├── oah-mcp/                Claude Code MCP server (@dureclaw/mcp)
│   └── ctl/                    oah-ctl management CLI
│
└── scripts/
    ├── setup-server.sh         Phoenix server install
    ├── setup-agent.sh          Worker agent install (oah command)
    ├── setup-mcp.sh            Claude Code MCP registration
    └── oah                     Unified CLI
```

---

## Usage

After installing the plugin, use directly inside Claude Code:

```
# Check team status
/team-status

# Expand to multi-machine team (auto setup Phoenix server + worker agents)
/setup-team

# Send a task to an agent
mcp__oah__send_task(to: "builder@mac-mini", instructions: "[SHELL] make build")

# List online agents
mcp__oah__get_presence
```

### Available MCP Tools

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

### System Diagram

```
Claude Code (Orchestrator)
  │  MCP (oah-mcp)
  ▼
Phoenix Server              ws://host:4000
  │  Phoenix Channel
  ├──▶ oah-agent (Mac Mini)   builder@mac-mini
  ├──▶ oah-agent (GPU server) builder@gpu-server
  └──▶ oah-agent (Raspberry Pi) executor@raspi
          └─ Execute AI backend → return task.result
```

---

## REST API

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Server status |
| GET | `/api/presence` | List connected agents |
| GET | `/api/work-keys` | List Work Keys |
| GET | `/api/work-keys/latest` | Latest Work Key |
| POST | `/api/work-keys` | Create new Work Key |
| GET | `/api/state/:wk` | Get Work Key state |
| PATCH | `/api/state/:wk` | Update Work Key state |
| POST | `/api/task` | Dispatch task (Phoenix broadcast) |
| GET | `/api/task/:id` | Poll task result |
| POST | `/api/task/:id/result` | Submit task result |
| GET | `/api/mailbox/:agent` | Read agent mailbox |
| POST | `/api/mailbox/:agent` | Send agent mailbox message |

---

## Prerequisites

| | Required | Purpose |
|--|----------|---------|
| **Required** | [Claude Code CLI](https://claude.ai/download) | Orchestrator |
| **Multi-machine** | [Tailscale](https://tailscale.com/download) | Private network between machines (free, up to 100 devices) |

Everything else (Phoenix server, oah-agent) **downloads pre-built binaries automatically** — no additional installation needed.

---

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md) | **Development Guide** — testing, Phoenix Channel protocol, how to contribute PRs |
| [docs/PROTOCOL.md](./docs/PROTOCOL.md) | **Protocol Spec** — official 4-layer communication protocol definition (L1 network ~ L4 team protocol) |
| [docs/PRIVATE_NETWORK.md](./docs/PRIVATE_NETWORK.md) | **Private Network Setup** — connecting remote agents into one team via Tailscale |
| [docs/REMOTE_AGENT_OPS.md](./docs/REMOTE_AGENT_OPS.md) | **Remote Agent Ops** — real-time diagnostics, commands, and recovery for remote agents |
| [docs/AGENTS.md](./docs/AGENTS.md) | Agent role definitions |
| [docs/METHODOLOGY.md](./docs/METHODOLOGY.md) | Work loop methodology |
| [docs/GAP_ANALYSIS.md](./docs/GAP_ANALYSIS.md) | Current state and improvement roadmap |
| [docs/INSTALL.md](./docs/INSTALL.md) | Installation guide |
| [docs/ECOSYSTEM_ANALYSIS.md](./docs/ECOSYSTEM_ANALYSIS.md) | Ecosystem analysis (ClawFit, competitive tool comparison) |

---

## Examples

| Example | Description |
|---------|-------------|
| [fix-agent](./examples/fix-agent/) | Multiple AI agents collaborate to automatically analyze bugs, apply fixes, and create PRs |

```
Claude Code → analyzer-agent (bug detection)
           → fixer-agent    (code fix)
           → tester-agent   (verification + PR creation)
```

---

## License

MIT © 2025-2026 [Seungwoo Hong (홍승우)](https://github.com/hongsw)

See the [LICENSE](./LICENSE) file for details.
