# 개발 방법론 — open-agent-harness

멀티에이전트 AI 개발 워크플로우의 운영 방법론. 로컬 단일머신 모드와 분산 멀티머신 모드 두 가지를 지원한다.

---

## 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────┐
│  L4: A2A (task.assign) + ACP (task.approval_requested)      │
│  L3: Agent TTY (OpenCode + harness plugin)                  │
│  L2: MCP (파일/DB 접근)                                      │
│  L1: Phoenix Channel (메시지 버스) ← 분산 모드              │
│  L0: Tailscale (E2E 암호화)                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 운영 모드 선택

| 상황 | 권장 모드 |
|------|-----------|
| 단일 개발자, 로컬 Mac | **Mode A (로컬)** |
| GPU 머신에서 builder만 분리 | **Mode B (분산)** |
| NAS + Mac + GPU 풀 활용 | **Mode B (분산)** |
| CI/CD 파이프라인 | **Mode B (분산)** |

---

## Mode A: 로컬 단일머신 (기존 방식)

```
HARNESS_STATE_SERVER 미설정 → 파일 기반 state.json 사용
```

### 시작 방법

```bash
cd /your/project
opencode
```

OpenCode 내에서:
```
/workloop Add pagination to the user list API
```

### 상태 흐름

```
.opencode/state/state.json   ← 런타임 상태
.opencode/state/mailbox/     ← 에이전트 간 메시지
.opencode/reports/           ← 훅 실행 결과
```

### 워크루프

```
orchestrator
  → planner   (task decomposition)
  → builder   (implement)
  → verifier  (lint + test + typecheck)
  → reviewer  (code review)
  → 09_completion_gate.sh
     ├─ exit 0 → ✅ Done
     ├─ exit 1 → ❌ loop again (max 5)
     └─ exit 2 → ⚠️  no tests, add tests
```

---

## Mode B: 분산 멀티머신 (Phoenix Channel)

```
HARNESS_STATE_SERVER=ws://100.x.x.x:4000 설정 시 자동 활성화
```

### 전제 조건

1. NAS (또는 상시 기동 머신)에 Elixir/Phoenix 설치
2. 모든 머신이 Tailscale 네트워크 연결
3. 각 머신에 Bun + OpenCode 설치

### 인프라 토폴로지

```
┌─────────────────────────────────────────────────────────────┐
│  NAS (24/7)                                                 │
│  packages/phoenix-server/ (Elixir/Phoenix)                 │
│  PORT 4000                                                  │
└─────────────────────┬───────────────────────────────────────┘
       Tailscale       │  ws://100.x.x.x:4000/socket/websocket
      ┌───────────────┤────────────────────┐
      │               │                    │
┌─────▼──────┐  ┌─────▼──────┐  ┌─────────▼───┐
│ Mac        │  │ GPU PC     │  │ NAS CLI     │
│ orchestrator│  │ builder    │  │ verifier    │
│ agent-daemon│  │ agent-daemon│  │ agent-daemon│
└────────────┘  └────────────┘  └─────────────┘
```

### Step 1: Phoenix 서버 시작 (NAS)

```bash
cd packages/phoenix-server
mix deps.get
mix phx.server
```

또는 프로덕션 릴리즈:

```bash
export SECRET_KEY_BASE=$(mix phx.gen.secret)
export PORT=4000
MIX_ENV=prod mix release
_build/prod/rel/harness_server/bin/harness_server start
```

### Step 2: Orchestrator 시작 (Mac)

```bash
# orchestrator가 Work Key 생성
STATE_SERVER=ws://100.x.x.x:4000 \
AGENT_NAME=orchestrator@mac \
AGENT_ROLE=orchestrator \
PROJECT_DIR=/path/to/project \
bun run packages/agent-daemon/src/index.ts
```

Work Key가 자동 발급됨: `LN-20260308-001`

### Step 3: 나머지 에이전트 시작

```bash
# GPU 머신 — builder
STATE_SERVER=ws://100.x.x.x:4000 \
AGENT_NAME=builder@gpu \
AGENT_ROLE=builder \
WORK_KEY=LN-20260308-001 \
PROJECT_DIR=/shared/nfs/project \
bun run packages/agent-daemon/src/index.ts

# NAS — verifier
STATE_SERVER=ws://100.x.x.x:4000 \
AGENT_NAME=verifier@nas \
AGENT_ROLE=verifier \
WORK_KEY=LN-20260308-001 \
PROJECT_DIR=/volume1/project \
bun run packages/agent-daemon/src/index.ts
```

### Step 4: 워크루프 실행

orchestrator가 연결된 OpenCode 세션에서:

```
/workloop Add pagination to the user list API
```

orchestrator가 자동으로 Work Key로 task.assign을 전송한다.

---

## Work Key 라이프사이클

```
POST /api/work-keys
  → "LN-20260308-001" 발급
  → Phoenix Channel "work:LN-20260308-001" 자동 생성 (첫 join 시)
  → 각 에이전트가 phx_join으로 채널 JOIN
  → task.assign → task.progress → task.result 이벤트 흐름
  → state.status = "done" 시 완료
```

### Work Key 명세

```
LN-YYYYMMDD-XXX
├─ LN: 프로젝트 접두어 (Linear-style)
├─ YYYYMMDD: 날짜
└─ XXX: 당일 순번 (001부터)
```

예: `LN-20260308-001`, `LN-20260308-002`

---

## Phoenix Channel 이벤트 흐름

### 연결 수립

```
client → server: [join_ref, ref, "work:LN-20260308-001", "phx_join",
                  {"agent_name":"builder@gpu","role":"builder","machine":"gpu"}]

server → client: [join_ref, ref, "work:LN-20260308-001", "phx_reply",
                  {"status":"ok","response":{"work_key":"LN-20260308-001"}}]
```

### 태스크 실행

```
orchestrator → (channel) → "task.assign":
  { task_id: "t-001", to: "builder@gpu", role: "builder",
    instructions: "...", context: {} }

builder → (channel) → "task.progress":
  { task_id: "t-001", message: "Working...", status: "running" }

builder → (channel) → "task.result":
  { task_id: "t-001", status: "done", exit_code: 0, artifacts: [...] }
```

### Heartbeat

```
client → server: [null, "hb-1", "phoenix", "heartbeat", {}]
server → client: [null, "hb-1", "phoenix", "phx_reply", {"status":"ok","response":{}}]
(매 30초)
```

---

## 에이전트별 책임

### Orchestrator

- Work Key 발급 (orchestrator 역할만 생성)
- `task.assign`으로 태스크 분배
- `task.result` / `task.blocked` 수신 후 다음 단계 결정
- `09_completion_gate.sh` 실행으로 완료 판단
- 루프 횟수 추적 (max 5회)

### Planner

- orchestrator로부터 `task.assign` 수신 (`role: "planner"`)
- 목표를 태스크 목록으로 분해
- `state.update`로 tasks[] 업데이트
- `task.result`로 계획 완료 보고

### Builder

- orchestrator로부터 `task.assign` 수신 (`role: "builder"`)
- OpenCode 서브프로세스로 구현
- `task.progress`로 진행 상황 스트리밍
- `task.result`로 완료 보고 (artifacts 포함)
- 실패 시 `task.blocked`

### Verifier

- orchestrator로부터 `task.assign` 수신 (`role: "verifier"`)
- 훅 파이프라인 실행 (format → lint → typecheck → test)
- `task.result`에 report_path만 포함 (파일 내용 제외)
- 실패 분류는 `08_fail_classifier.py` 위임

### Reviewer

- orchestrator로부터 `task.assign` 수신 (`role: "reviewer"`)
- diff report 읽기 → 코드 리뷰
- `task.result`에 verdict + fix_instructions 포함
- CHANGES_NEEDED 시 fix_instructions를 orchestrator에게 전달
- 파일 직접 수정 금지

---

## 에러 처리 전략

### task.blocked 처리

```
builder → "task.blocked": { task_id, error: "...", status: "blocked" }

orchestrator 수신 시:
  1. state.loop_count 확인
  2. loop_count < 5 → planner에게 재계획 요청
  3. loop_count >= 5 → 작업 중단, 사람 개입 요청
     → task.approval_requested 전송
```

### 에이전트 오프라인 처리

```
target agent 오프라인 → Phoenix.Presence 확인 미스
  → StateStore.enqueue_mailbox(agent_name, msg)
  → agent 재연결 시 phx_join 후 자동 mailbox 배달
```

### 재연결 전략

agent-daemon의 지수 백오프:
```
초기: 1s → 2s → 4s → 8s → ... → 30s (상한)
phx_join 재전송 후 채널 복구
```

---

## 시나리오 예시

### 시나리오 1: 새 API 엔드포인트 추가

```bash
# 1. NAS: Phoenix 서버 시작
mix phx.server  # port 4000

# 2. Mac: orchestrator 시작 (Work Key 자동 발급)
STATE_SERVER=ws://100.x.x.x:4000 AGENT_ROLE=orchestrator \
  bun run packages/agent-daemon/src/index.ts
# → "created Work Key: LN-20260308-001"

# 3. GPU: builder 시작
STATE_SERVER=ws://100.x.x.x:4000 AGENT_ROLE=builder \
  WORK_KEY=LN-20260308-001 \
  bun run packages/agent-daemon/src/index.ts

# 4. 목표 입력 (orchestrator OpenCode 세션)
/workloop Add GET /api/users/:id endpoint with rate limiting

# 5. 자동 흐름:
#    orchestrator → planner: plan_request
#    planner → state.update: tasks = [...]
#    orchestrator → builder: task.assign (구현)
#    builder → task.result
#    orchestrator → verifier: task.assign (검증)
#    verifier → task.result: {report_path: "..."}
#    09_completion_gate.sh → exit 0 ✅
```

### 시나리오 2: 버그 수정

```bash
/workloop Fix NullPointerException in UserService.findById when user not found
```

gate가 exit 1 → 루프 재실행 (max 5회)

### 시나리오 3: 대규모 리팩토링

```bash
/workloop Refactor authentication module to use JWT instead of session cookies
```

복잡도 높음 → planner가 5+ 태스크로 분해 → builder가 순차 구현

---

## 상태 확인

```bash
# 온라인 에이전트 목록
curl http://100.x.x.x:4000/api/presence

# 현재 Work Key 상태
curl http://100.x.x.x:4000/api/state/LN-20260308-001

# 특정 에이전트 mailbox 확인
curl http://100.x.x.x:4000/api/mailbox/builder@gpu
```

---

## 로컬 ↔ 분산 전환

| 항목 | 로컬 (Mode A) | 분산 (Mode B) |
|------|---------------|---------------|
| 상태 저장 | `state.json` 파일 | Phoenix ETS + PubSub |
| 메시지 버스 | `mailbox/` 파일 | Phoenix Channel |
| 에이전트 실행 | OpenCode subagent | agent-daemon 프로세스 |
| 실행 모델 | 순차 (한 OpenCode 세션) | 병렬 (머신별 OpenCode) |
| 전환 방법 | `STATE_SERVER` 미설정 | `STATE_SERVER=ws://...` 설정 |

플러그인(`harness.ts`)은 `HARNESS_STATE_SERVER` 환경변수로 자동 감지한다:
- 설정 없음: 로컬 파일 기반
- 설정 있음: Phoenix REST + Channel
