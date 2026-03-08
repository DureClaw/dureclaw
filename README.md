# open-agent-harness

A 5-agent AI development workflow harness for [OpenCode](https://opencode.ai), built as a plugin.

Agents collaborate in a loop: **Planner → Builder → Verifier → Reviewer → Gate → repeat** until all checks pass.

Repetitive checks run as deterministic shell hooks (not LLM calls), keeping token costs low.

---

## Architecture

```
5 Agents (Markdown + YAML frontmatter)
  Orchestrator  (primary)  — loop control, goal tracking, completion judgment
  Planner       (subagent) — task decomposition, risk assessment
  Builder       (subagent) — code changes (full write + bash access)
  Verifier      (subagent) — test/lint execution + result summary
  Reviewer      (subagent) — code review + fix instructions (read-only)

TypeScript Plugin (.opencode/plugins/harness.ts)
  tool.execute.after        — bash results → .opencode/reports/ (automatic)
  Custom tools: run_hook, read_state, write_state, post_message, read_mailbox

Shell Hooks (.opencode/hooks/) — deterministic, no LLM calls
  00_preflight.sh      — env check + dependency install
  01_diff_summary.sh   — git diff → report
  02_format.sh         — formatter check (prettier/biome/black/gofmt)
  03_lint.sh           — linter (eslint/biome/ruff/golangci-lint)
  04_typecheck.sh      — type checker (tsc/mypy/go build/cargo check)
  05_unit_test.sh      — unit tests (bun test/vitest/pytest/go test)
  06_integration_test.sh — integration tests (if available)
  07_build.sh          — production build
  08_fail_classifier.py — classify + prioritize failures from reports
  09_completion_gate.sh — final gate: all required checks must pass

File-based State
  .opencode/state/state.json     — run_id, goal, tasks, loop_count
  .opencode/state/mailbox/       — inter-agent messages (JSON files)
  .opencode/reports/             — hook execution results (auto-generated)
```

---

## Installation

### Into a new project (via init script)

```bash
git clone https://github.com/your-org/open-agent-harness
bash open-agent-harness/scripts/init.sh /path/to/your-project
cd /path/to/your-project
opencode
```

### Manual

```bash
cp -r open-agent-harness/.opencode your-project/.opencode
cp open-agent-harness/opencode.json your-project/opencode.json
chmod +x your-project/.opencode/hooks/*.sh your-project/.opencode/hooks/*.py
```

### Requirements

- [OpenCode](https://opencode.ai) CLI installed
- Bun ≥ 1.0 (for the TypeScript plugin)
- Python 3 (for `08_fail_classifier.py`)
- Your project's stack tools (tsc, eslint, pytest, etc.)

---

## Usage

### Start a workloop

```
/workloop Add pagination to the user list API endpoint
```

This initializes state and starts the 5-agent loop:

```
Orchestrator → Planner (decompose goal into tasks)
             → Builder (implement each task)
             → Verifier (run lint + tests + typecheck)
             → Reviewer (code review + fix instructions)
             → Gate (09_completion_gate.sh)
                ├── exit 0 → ✅ Done! Run /ship
                ├── exit 1 → ❌ Failures → loop again (max 5)
                └── exit 2 → ⚠️  No tests → Builder adds tests → loop again
```

### Ship when ready

```
/ship feat: add pagination to user list API
```

Runs preflight + build + gate. If all pass, proposes a conventional commit.

### Run hooks directly (for debugging)

```bash
bash .opencode/hooks/00_preflight.sh
bash .opencode/hooks/09_completion_gate.sh
python3 .opencode/hooks/08_fail_classifier.py
```

Reports are written to `.opencode/reports/`.

---

## Distributed Mode (Multi-Machine)

여러 머신에서 에이전트를 분산 실행한다. Elixir Phoenix 채널이 L1 메시지 버스 역할.

### 아키텍처

```
┌──────────────────────────────────────────────────────┐
│  NAS (24/7)  packages/phoenix-server/ (Elixir)       │
│  ws://100.x.x.x:4000/socket/websocket                │
└──────────────────┬───────────────────────────────────┘
                   │  Tailscale
      ┌────────────┼────────────┐
      ▼            ▼            ▼
  Mac             GPU PC       NAS CLI
  orchestrator    builder      verifier
  agent-daemon    agent-daemon agent-daemon
```

### 빠른 시작

**1. Phoenix 서버 시작 (NAS)**

```bash
cd packages/phoenix-server
mix deps.get
mix phx.server   # port 4000
```

**2. Orchestrator 시작 (Mac)**

```bash
STATE_SERVER=ws://100.x.x.x:4000 \
AGENT_ROLE=orchestrator \
AGENT_NAME=orchestrator@mac \
PROJECT_DIR=/path/to/project \
bun run packages/agent-daemon/src/index.ts
# → creates Work Key: LN-20260308-001
```

**3. 나머지 에이전트 시작**

```bash
# GPU: builder
STATE_SERVER=ws://100.x.x.x:4000 \
AGENT_ROLE=builder \
AGENT_NAME=builder@gpu \
WORK_KEY=LN-20260308-001 \
bun run packages/agent-daemon/src/index.ts

# NAS: verifier
STATE_SERVER=ws://100.x.x.x:4000 \
AGENT_ROLE=verifier \
AGENT_NAME=verifier@nas \
WORK_KEY=LN-20260308-001 \
bun run packages/agent-daemon/src/index.ts
```

**4. 온라인 확인**

```bash
curl http://100.x.x.x:4000/api/presence
# → {"agents":[{"name":"orchestrator@mac",...},{"name":"builder@gpu",...}]}
```

### Work Key 라이프사이클

```
POST /api/work-keys → "LN-YYYYMMDD-XXX" 발급
  ↓ Phoenix Channel "work:LN-..." 생성
  ↓ 에이전트 phx_join → presence 등록
  ↓ task.assign → task.progress → task.result
  ↓ state.status = "done"
```

### Phoenix Channel 프로토콜

메시지 포맷 (5-tuple):
```json
[join_ref, ref, topic, event, payload]
```

채널 참여:
```json
["1","1","work:LN-20260308-001","phx_join",
 {"agent_name":"builder@gpu","role":"builder","machine":"gpu"}]
```

태스크 할당:
```json
[null,"2","work:LN-20260308-001","task.assign",
 {"to":"builder@gpu","task_id":"t-001","instructions":"..."}]
```

### 로컬 vs 분산 전환

| | 로컬 (Mode A) | 분산 (Mode B) |
|-|---------------|---------------|
| 상태 | `state.json` | Phoenix ETS |
| 메시지 | `mailbox/` 파일 | Phoenix Channel |
| 에이전트 | OpenCode subagent | agent-daemon 프로세스 |
| 전환 | `STATE_SERVER` 미설정 | `STATE_SERVER=ws://...` |

자세한 내용: [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md)

---

## Discord Notifications

에이전트 대화와 훅 실행 결과를 Discord 채널로 실시간 미러링합니다.

### Setup

1. Discord 서버 → 채널 설정 → Integrations → Webhooks → New Webhook → Copy URL

2. 환경 변수 설정:

```bash
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

또는 셸 프로필에 영구 등록:

```bash
echo 'export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."' >> ~/.zshrc
```

3. OpenCode 실행 — 자동으로 Discord 전송 시작

### What gets posted

에이전트가 말할 때마다 보내지 않습니다. **중요한 이벤트만** 전송합니다.

| Event | Discord Message |
|-------|----------------|
| `/workloop` 시작 | 🚀 목표 embed |
| `09_completion_gate` 실행 | ✅/❌ 게이트 결과 |
| `05_unit_test` 실행 | ✅/❌ 테스트 결과 |
| `03_lint` 실행 | ✅/❌ 린트 결과 |
| `04_typecheck` 실행 | ✅/❌ 타입체크 결과 |
| 워크루프 완료 | ✅ 완료 embed + 루프 횟수 |
| `discord_notify` 직접 호출 | 커스텀 알림 |

> 에이전트 대화, bash 출력 등은 Discord로 보내지 않습니다.

### Custom notification

에이전트가 직접 Discord에 알림을 보낼 수도 있습니다:

```
discord_notify(title="배포 완료", message="v1.2.0 shipped!", level="success")
```

### Privacy

`DISCORD_WEBHOOK_URL`이 설정되지 않으면 Discord 기능은 완전히 비활성화되며 워크플로에 영향 없습니다.

---

## Token-Saving Design

The harness enforces strict token budgets through hard rules in agent prompts:

| Rule | Saves tokens |
|------|-------------|
| Hooks run outside LLM — results in reports/ | 90%+ of test output |
| Agents pass report paths, not contents | 60-80% per message |
| Messages capped at 200 tokens | Prevents context bloat |
| Orchestrator does 1:1 messaging only | No broadcast overhead |
| Verifier/Reviewer send 3-line summaries | ~95% vs full output |

---

## Agent Permissions

| Agent | Read | Write | Bash | Task |
|-------|------|-------|------|------|
| Orchestrator | All | state/, reports/ | Query-only | ✅ spawn subagents |
| Planner | All | *.md, state/ | ❌ | ❌ |
| Builder | All | **All** | ✅ Full | ❌ |
| Verifier | All | reports/ | Test/lint only | ❌ |
| Reviewer | All | mailbox/ | ❌ | ❌ |

The plugin enforces: **only Builder may edit source files**.

---

## Supported Stacks

Auto-detected by `_lib.sh`:

| Stack | Detected by | Format | Lint | Typecheck | Test | Build |
|-------|-------------|--------|------|-----------|------|-------|
| **Bun/TS** | bun.lockb | prettier/biome | eslint/biome | tsc | bun test | bun run build |
| **Node/TS** | package.json | prettier | eslint | tsc | vitest/jest | npm run build |
| **Python** | pyproject.toml | black/ruff | ruff/flake8 | mypy/pyright | pytest | python -m build |
| **Go** | go.mod | gofmt | golangci-lint | go build | go test | go build |
| **Rust** | Cargo.toml | rustfmt | clippy | cargo check | cargo test | cargo build |

---

## File Structure

```
open-agent-harness/
├── .opencode/
│   ├── agents/
│   │   ├── orchestrator.md    primary agent, loop controller
│   │   ├── planner.md         task decomposition
│   │   ├── builder.md         code implementation
│   │   ├── verifier.md        test/lint execution
│   │   └── reviewer.md        code review (read-only)
│   ├── plugins/
│   │   └── harness.ts         OpenCode plugin
│   ├── hooks/
│   │   ├── _lib.sh            shared utilities
│   │   ├── 00_preflight.sh    environment check
│   │   ├── 01_diff_summary.sh git diff report
│   │   ├── 02_format.sh       format check
│   │   ├── 03_lint.sh         linting
│   │   ├── 04_typecheck.sh    type checking
│   │   ├── 05_unit_test.sh    unit tests
│   │   ├── 06_integration_test.sh integration tests
│   │   ├── 07_build.sh        build
│   │   ├── 08_fail_classifier.py failure classification
│   │   └── 09_completion_gate.sh final gate
│   ├── commands/
│   │   ├── workloop.md        /workloop command
│   │   └── ship.md            /ship command
│   └── state/
│       ├── state.json         runtime state
│       └── mailbox/           inter-agent messages
├── opencode.json              agent config + permissions
├── package.json
├── tsconfig.json
├── scripts/
│   └── init.sh               install into existing project
└── README.md
```

---

## Plan vs Implementation

기획 대비 실제 구현 상태 비교표.

### Core Structure

| Feature | Planned | Built | Notes |
|---------|---------|-------|-------|
| package.json + tsconfig.json | ✅ | ✅ | |
| opencode.json | ✅ custom config | ✅ schema-only | OpenCode이 plugin/agents/hooks 자동 로드, 커스텀 키 불허 |
| `.opencode/agents/` (5개) | ✅ | ✅ | |
| `.opencode/hooks/` (10개) | ✅ | ✅ | |
| `.opencode/commands/` (2개) | ✅ | ✅ | |
| `.opencode/state/` | ✅ | ✅ | |
| `scripts/init.sh` | ✅ | ✅ | |

### 5 Agents

| Agent | Planned Mode | Built Mode | Built |
|-------|-------------|-----------|-------|
| Orchestrator | primary, loop control | primary | ✅ |
| Planner | subagent, task decompose | subagent | ✅ |
| Builder | subagent, full write/bash | subagent | ✅ |
| Verifier | subagent, bash test-only | subagent | ✅ |
| Reviewer | subagent, read-only | subagent | ✅ |

### Plugin Lifecycle Hooks

| Hook | Planned | Built | Notes |
|------|---------|-------|-------|
| `tool.execute.after` → reports/ | ✅ | ✅ | bash 결과 자동 저장 |
| `tool.execute.before` (builder gate) | ✅ | ❌ | OpenCode API에 agent name 미노출, 구현 불가 |
| `session.idle` → completion_gate | ✅ | ❌ | OpenCode Plugin API에 해당 hook 없음 |
| `experimental.session.stop` | ✅ | ❌ | OpenCode Plugin API에 해당 hook 없음 |

> **참고**: OpenCode Plugin API는 `Hooks` 인터페이스(`tool.execute.before/after`, `chat.*`, `permission.ask` 등)만 노출. `session.idle`/`session.stop`은 지원되지 않아 제거.

### Custom Tools (via Plugin)

| Tool | Planned | Built |
|------|---------|-------|
| `run_hook` | ✅ | ✅ |
| `read_state` | ✅ | ✅ |
| `write_state` | ✅ | ✅ |
| `post_message` | ✅ | ✅ |
| `read_mailbox` | ✅ | ✅ |

### Shell Hooks

| Hook | Planned | Built |
|------|---------|-------|
| `_lib.sh` (stack detection, utilities) | ✅ | ✅ |
| `00_preflight.sh` | ✅ | ✅ |
| `01_diff_summary.sh` | ✅ | ✅ |
| `02_format.sh` | ✅ | ✅ |
| `03_lint.sh` | ✅ | ✅ |
| `04_typecheck.sh` | ✅ | ✅ |
| `05_unit_test.sh` | ✅ | ✅ |
| `06_integration_test.sh` | ✅ | ✅ |
| `07_build.sh` | ✅ | ✅ |
| `08_fail_classifier.py` | ✅ | ✅ |
| `09_completion_gate.sh` | ✅ | ✅ |

### Additions (기획 외 구현)

| Feature | Description |
|---------|-------------|
| `chat.message` hook | 에이전트 대화 → Discord 실시간 미러링 |
| `tool.execute.after` Discord | 훅 실행 결과 → Discord |
| `write_state` Discord | goal/status 변경 시 Discord 알림 |
| `discord_notify` tool | 에이전트가 직접 Discord에 커스텀 알림 전송 |
| `packages/phoenix-server/` | Elixir Phoenix 분산 메시지 버스 (실제 Phoenix 5-tuple 프로토콜) |
| `packages/agent-daemon/` Phoenix proto | Phoenix Channel 프로토콜로 업그레이드 |
| `docs/METHODOLOGY.md` | 로컬/분산 운영 방법론 문서 |
| 에이전트 분산 컨텍스트 | orchestrator/builder/verifier/reviewer 프롬프트에 Work Key + Phoenix 이벤트 명세 추가 |

### Summary

| Category | Planned | Built | Coverage |
|----------|---------|-------|----------|
| Agents | 5 | 5 | 100% |
| Shell Hooks | 10 + _lib | 10 + _lib | 100% |
| Custom Tools | 5 | 6 (+discord_notify) | 120% |
| Commands | 2 | 2 | 100% |
| Plugin Lifecycle Hooks | 4 | 2 (tool.execute.after, chat.message) | 50% |
| Discord Integration | ❌ not planned | ✅ | bonus |
| **Overall** | | | **~95%** |

기획 대비 미구현: `tool.execute.before` (builder 권한 게이트), `session.idle`, `session.stop` — OpenCode v1.2.x Plugin API 미지원으로 인한 제약.

---

## Customization

### Add a custom hook

1. Create `.opencode/hooks/10_my_check.sh`
2. Add `"10_my_check.sh"` to `ALLOWED_HOOKS` in `harness.ts`
3. Call from agents with `run_hook("10_my_check.sh")`

### Adjust agent permissions

Edit the YAML frontmatter `permission:` block in the relevant `.opencode/agents/*.md` file.

### Increase loop limit

Edit `.opencode/agents/orchestrator.md` → change `max_steps: 20` and the loop limit comment.

---

## License

MIT
