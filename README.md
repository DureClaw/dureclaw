# ClawNet *(두레Claw)*

> **공식명**: ClawNet &nbsp;|&nbsp; **닉네임**: 두레Claw (DureClaw)

분산된 디바이스의 AI 에이전트들이 하나의 채널로 묶여 실시간 협력하는 오케스트레이션 인프라.
로컬 단일머신(Mode A)과 분산 멀티머신(Mode B) 두 가지 모드를 지원한다.

> *두레(두레): 조선시대 농민들이 각자의 논에서 마을 전체가 함께 경작하던 협동 시스템.*
> *ClawNet은 그 정신을 AI 에이전트에 담는다 — 각자의 머신에서, 하나의 목표로.*

[![GitHub](https://img.shields.io/badge/repo-open--agent--harness-blue)](https://github.com/baryonlabs/open-agent-harness)

---

## 아키텍처

```
Mode A — 로컬 (단일 머신)
─────────────────────────────────
OpenCode (단일 세션)
  └─ .opencode/plugins/harness.ts   (플러그인)
  └─ .opencode/hooks/               (품질 게이트)
  └─ .opencode/agents/              (5 에이전트 역할)
  └─ .opencode/state/               (로컬 파일 상태)


Mode B — 분산 (멀티 머신)
─────────────────────────────────
Claude Code (오케스트레이터)
  └─ packages/oah-mcp/         MCP 서버 → Phoenix WebSocket
       send_task / receive_task / get_presence / ...

Phoenix Channel (메시지 버스, Elixir)
  packages/phoenix-server/      ws://host:4000

oah-agent (워커, 각 머신)
  packages/agent-daemon/        WebSocket 연결 → task.assign 수신
  → OpenCode 서브프로세스 실행  → task.result 반환
```

---

## 패키지 구조

```
open-agent-harness/
├── .opencode/                  Mode A 로컬 워크루프
│   ├── agents/                 5 에이전트 (orchestrator/planner/builder/verifier/reviewer)
│   ├── plugins/harness.ts      OpenCode 플러그인 (run_hook, read_state, write_state, post_message, read_mailbox)
│   ├── hooks/                  품질 게이트 (00_preflight ~ 09_completion_gate)
│   └── commands/               /workloop, /ship
│
├── packages/
│   ├── phoenix-server/         Elixir/Phoenix 메시지 버스 (분산 인프라 핵심)
│   ├── agent-daemon/           WebSocket 에이전트 데몬 (oah-agent)
│   ├── oah-mcp/                Claude Code MCP 서버
│   └── ctl/                    oah-ctl 관리 CLI
│
├── scripts/
│   ├── setup-server.sh         서버 설치 스크립트
│   └── setup-agent.sh          에이전트 설치 스크립트 (oah-agent 명령어)
│
└── web/                        GitHub Pages (원클릭 설치)
    ├── install.sh
    ├── agent-daemon.ts
    └── index.html
```

---

## Mode A: 로컬 워크루프

단일 머신, OpenCode 세션 1개에서 5 에이전트가 협력 루프를 실행한다.

### 설치

```bash
# 기존 프로젝트에 harness 적용
git clone https://github.com/baryonlabs/open-agent-harness
bash open-agent-harness/scripts/init.sh /path/to/your-project
cd /path/to/your-project
opencode
```

### 사용법

```
# OpenCode 세션에서:
/workloop Add pagination to the user list API
```

### 워크루프 흐름

```
/workloop 실행
  └─ Orchestrator
       └─ Planner      태스크 분해
       └─ Builder       구현 (전체 파일 접근)
       └─ Verifier      lint + test + typecheck (훅 실행)
       └─ Reviewer      코드 리뷰 (읽기 전용)
       └─ 09_completion_gate.sh
            ├─ exit 0  ✅ 완료 → /ship 실행
            ├─ exit 1  ❌ 실패 → 루프 재실행 (최대 5회)
            └─ exit 2  ⚠️  테스트 없음 → Builder가 테스트 추가

/ship feat: add pagination
  └─ preflight + build + gate → conventional commit 제안
```

### 분산 모드로 전환

`HARNESS_STATE_SERVER=ws://host:4000` 환경변수를 설정하면 `harness.ts` 플러그인이 자동으로 Phoenix REST API를 사용한다.

---

## Mode B: 분산 멀티에이전트

### 전체 구성도

```
Claude Code (오케스트레이터, 맥북)
  │  MCP (oah-mcp)
  ▼
Phoenix Server (NAS / 서버)        ws://host:4000
  │  Phoenix Channel
  ├──▶ oah-agent (맥북)            NAME=agent1@mac
  ├──▶ oah-agent (GPU 서버)        NAME=builder@gpu
  └──▶ oah-agent (다른 머신)        NAME=reviewer@nas
          │
          └─ OpenCode 서브프로세스 실행 → 결과 반환
```

### Step 1: Phoenix 서버 시작

```bash
# 서버 머신에서
cd packages/phoenix-server
mix deps.get && mix phx.server
# → http://localhost:4000

# 또는 원클릭 설치
curl -fsSL https://baryonlabs.github.io/install.sh | ROLE=server bash
```

서버 확인:
```bash
curl http://localhost:4000/api/health
# → {"ok":true,"work_keys":0}
```

### Step 2: oah-agent 시작 (각 워커 머신)

```bash
# 원클릭 설치 + 실행
curl -fsSL https://baryonlabs.github.io/install.sh | \
  PHOENIX=ws://host:4000 ROLE=builder bash

# 또는 직접 실행
NAME=builder@mymachine \
ROLE=builder \
DIR=/path/to/project \
oah-agent ws://host:4000
```

### Step 3: Claude Code에 oah MCP 등록

```bash
claude mcp add oah \
  --scope user \
  -e PHOENIX_URL=ws://localhost:4000 \
  -e AGENT_NAME=orchestrator@mymachine \
  -e AGENT_ROLE=orchestrator \
  -- bun run /path/to/packages/oah-mcp/src/index.ts
```

Claude Code 재시작 후 MCP 도구 사용 가능:

```
mcp__oah__get_presence      연결된 에이전트 목록
mcp__oah__send_task         에이전트에게 태스크 전송 (WebSocket Push)
mcp__oah__receive_task      태스크 수신 대기 (최대 30초)
mcp__oah__complete_task     태스크 완료 결과 전송
mcp__oah__read_state        Work Key 상태 조회
mcp__oah__write_state       Work Key 상태 업데이트
mcp__oah__read_mailbox      에이전트 mailbox 읽기
mcp__oah__post_message      에이전트 mailbox에 메시지 전송
```

---

## REST API

| Method | Endpoint | 설명 |
|--------|----------|------|
| GET | `/api/health` | 서버 상태 |
| GET | `/api/presence` | 연결된 에이전트 목록 |
| GET | `/api/work-keys` | Work Key 목록 |
| GET | `/api/work-keys/latest` | 최신 Work Key |
| POST | `/api/work-keys` | 새 Work Key 생성 |
| GET | `/api/state/:wk` | Work Key 상태 조회 |
| PATCH | `/api/state/:wk` | Work Key 상태 업데이트 |
| POST | `/api/task` | 태스크 디스패치 (Phoenix broadcast) |
| GET | `/api/task/:id` | 태스크 결과 폴링 |
| POST | `/api/task/:id/result` | 태스크 결과 제출 |
| GET | `/api/mailbox/:agent` | 에이전트 mailbox 읽기 |
| POST | `/api/mailbox/:agent` | 에이전트 mailbox 메시지 전송 |

---

## 테스트 가이드

### Mode A 로컬 테스트

```bash
# 훅 개별 실행
bash .opencode/hooks/00_preflight.sh    # 환경 확인
bash .opencode/hooks/09_completion_gate.sh  # 완료 게이트
python3 .opencode/hooks/08_fail_classifier.py  # 실패 분류

# TypeScript 타입 체크
bun run typecheck
```

### Mode B 분산 테스트

**1. 서버 상태 확인**
```bash
curl http://localhost:4000/api/health
# → {"ok":true}
```

**2. 에이전트 연결 확인**
```bash
curl http://localhost:4000/api/presence
# → {"agents":[{"name":"agent1@mac","role":"builder",...}]}
```

**3. 태스크 전송 테스트 (curl)**
```bash
curl -s -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{"instructions":"hello.txt 만들고 Hello! 써줘. ARTIFACT: hello.txt 출력.", "to":"builder@mymachine"}' \
  -o /tmp/task.json && cat /tmp/task.json
# → {"task_id":"http-...","work_key":"LN-..."}
```

**4. 결과 폴링**
```bash
TASK_ID=$(python3 -c "import json; print(json.load(open('/tmp/task.json'))['task_id'])")
for i in $(seq 1 20); do
  curl -s "http://localhost:4000/api/task/$TASK_ID" -o /tmp/result.json
  STATUS=$(python3 -c "import json; print(json.load(open('/tmp/result.json')).get('status','done'))")
  [ "$STATUS" != "pending" ] && python3 -m json.tool /tmp/result.json && break
  echo "대기 중... ($i)"
  sleep 5
done
```

**5. Claude Code MCP로 태스크 전송**

Claude Code 세션에서:
```
agent1에게 test.py 파일 만들어서 print("hello") 써달라고 태스크 보내줘
```

MCP 도구를 직접 호출할 수도 있다:
```
mcp__oah__send_task(
  to: "agent1@mymachine",
  instructions: "test.py 만들고 print('hello') 써줘",
  role: "builder"
)
```

---

## Phoenix Channel 프로토콜

메시지 포맷 (5-tuple):
```json
[join_ref, ref, topic, event, payload]
```

주요 이벤트:
```
phx_join          채널 참여 + presence 등록
agent.hello       에이전트 온라인 알림
agent.bye         에이전트 오프라인 알림
task.assign       태스크 할당 (to 필드로 대상 지정)
task.progress     진행 상황 스트리밍
task.result       태스크 완료 결과
task.blocked      태스크 실패/차단
```

WebSocket URL: `ws://host:4000/socket/websocket?vsn=2.0.0`
Channel topic: `work:{WORK_KEY}`

---

## 지원 스택 (Mode A 훅 자동 감지)

| 스택 | 감지 기준 | Format | Lint | Test |
|------|-----------|--------|------|------|
| Bun/TS | bun.lockb | biome/prettier | eslint | bun test |
| Node/TS | package.json | prettier | eslint | vitest/jest |
| Python | pyproject.toml | black/ruff | ruff | pytest |
| Go | go.mod | gofmt | golangci-lint | go test |
| Rust | Cargo.toml | rustfmt | clippy | cargo test |

---

## 요구사항

| 컴포넌트 | 요구사항 |
|----------|----------|
| Mode A | OpenCode CLI, Bun ≥ 1.0, Python 3 |
| Mode B 서버 | Elixir ≥ 1.14, OTP ≥ 25 |
| Mode B 에이전트 | Bun ≥ 1.0, OpenCode CLI |
| Claude Code MCP | Claude Code CLI, Bun ≥ 1.0 |

---

## Discord 알림

`DISCORD_WEBHOOK_URL` 환경변수 설정 시 주요 이벤트를 Discord로 전송한다.

```bash
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

전송 이벤트: `/workloop` 시작, completion gate 결과, 테스트/린트 결과, 워크루프 완료.

---

## 문서

| 문서 | 설명 |
|------|------|
| [docs/REMOTE_AGENT_OPS.md](./docs/REMOTE_AGENT_OPS.md) | **원격 에이전트 운영** — 원격지 에이전트를 실시간 진단·명령·복구하는 방법 |
| [docs/AGENTS.md](./docs/AGENTS.md) | 에이전트 역할 정의 |
| [docs/METHODOLOGY.md](./docs/METHODOLOGY.md) | 워크루프 방법론 |
| [docs/GAP_ANALYSIS.md](./docs/GAP_ANALYSIS.md) | 현재 상태 및 개선 방향 |
| [docs/INSTALL.md](./docs/INSTALL.md) | 설치 가이드 |
| [docs/ECOSYSTEM_ANALYSIS.md](./docs/ECOSYSTEM_ANALYSIS.md) | 에코시스템 분석 (ClawFit, 경쟁 도구 비교) |

---

## License

MIT
