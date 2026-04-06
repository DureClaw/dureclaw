# DureCrew Protocol Specification v1.0

분산 AI 에이전트 팀이 사용하는 모든 통신 프로토콜의 공식 정의입니다.

---

## 계층 구조

```
┌─────────────────────────────────────────────────────────────┐
│  L4  Team Protocol     TeamCreate / SendMessage / TaskCreate │
├─────────────────────────────────────────────────────────────┤
│  L3  Application       Channel Events + REST API            │
├─────────────────────────────────────────────────────────────┤
│  L2  Transport         Phoenix WebSocket (5-tuple)          │
├─────────────────────────────────────────────────────────────┤
│  L1  Network           Tailscale (WireGuard) / LAN / TCP    │
└─────────────────────────────────────────────────────────────┘
```

---

## L1 — 네트워크 프로토콜

### Tailscale (권장)
- WireGuard 기반 E2E 암호화 mesh VPN
- 에이전트 연결 주소: `ws://<tailscale-ip>:4000`
- 자동 NAT 통과, 포트포워딩 불필요
- mDNS 대안: `ws://oah.local:4000` (같은 LAN)

### 포트
| 포트 | 용도 |
|------|------|
| `4000` | Phoenix HTTP + WebSocket (단일 포트) |

---

## L2 — 전송 프로토콜: Phoenix 5-tuple

WebSocket 연결 주소:
```
ws://<host>:4000/socket/websocket?vsn=2.0.0
```

### 메시지 형식 (JSON 배열)
```json
[join_ref, ref, topic, event, payload]
```

| 필드 | 타입 | 설명 |
|------|------|------|
| `join_ref` | `string \| null` | 채널 join 시 발급된 참조 ID |
| `ref` | `string \| null` | 메시지 고유 참조 ID (응답 매칭용) |
| `topic` | `string` | 채널 토픽: `work:LN-YYYYMMDD-XXX` |
| `event` | `string` | 이벤트 이름 |
| `payload` | `object` | 이벤트 데이터 |

### 시스템 이벤트
| 이벤트 | 방향 | 설명 |
|--------|------|------|
| `phx_join` | C→S | 채널 입장 |
| `phx_reply` | S→C | join/push 응답 |
| `phx_leave` | C→S | 채널 퇴장 |
| `phx_error` | S→C | 채널 에러 |
| `phx_close` | S→C | 채널 종료 |
| `heartbeat` | C→S | 30초 간격 ping (`topic: "phoenix"`) |

### 연결 순서
```
1. WebSocket upgrade (HTTP → WS)
2. [null, "1", "work:LN-...", "phx_join", {agent_name, role, machine, capabilities}]
3. S→C: [joinRef, "1", topic, "phx_reply", {"status":"ok", "response":{presences, work_key, project}}]
4. S→C: [null, null, topic, "agent.hello", {agent, role, machine, work_key}]  ← broadcast
5. S→C: [null, null, topic, "mailbox.message", msg]  ← 쌓인 mailbox 전달
```

---

## L3 — 애플리케이션 프로토콜

### 3-A: 에이전트 아이덴티티

#### Agent Name (고유 식별자)
```
형식: {role}@{machine}
예시: builder@mac-mini-m4
      orchestrator@Hongui-MacBookPro
      tester@raspi-4
```

#### Work Key (작업 세션 식별자)
```
형식: LN-YYYYMMDD-NNN
예시: LN-20260406-001

- LN: DureCrew 고정 접두사
- YYYYMMDD: UTC 날짜
- NNN: 당일 시퀀스 (001~999, 자동 증가)
```

#### Work Key 생명주기
```
created → running → done
                 ↘ failed
```

#### Agent 역할 (role)
| role | 설명 |
|------|------|
| `orchestrator` | 팀 조율, 태스크 분배 |
| `builder` | 코드 생성, 빌드, 파일 수정 |
| `tester` | 테스트 실행, 검증 |
| `analyst` | 코드 분석, 리포트 |
| `deployer` | 배포, 서비스 관리 |
| `executor` | 범용 실행자 |

#### Capabilities 형식
```json
["macos", "apple-gpu", "xcode", "ram:64g", "docker"]
```

| capability | 의미 |
|-----------|------|
| `macos` / `linux` / `windows` | OS |
| `apple-gpu` / `nvidia-gpu` | GPU |
| `arm` / `x86_64` | 아키텍처 |
| `ram:Xg` | RAM 크기 (예: `ram:16g`) |
| `xcode` / `docker` | 설치된 도구 |
| `rpi-speakerphone` / `printer` | 특수 장치 |

---

### 3-B: 채널 이벤트 프로토콜

#### phx_join payload (C→S)
```json
{
  "agent_name": "builder@mac-mini",
  "role": "builder",
  "machine": "mac-mini-m4",
  "capabilities": ["macos", "apple-gpu"]
}
```

#### phx_join response (S→C)
```json
{
  "presences": { "<agent_name>": { "metas": [{ ... }] } },
  "work_key": "LN-20260406-001",
  "project": { "status": "running", "goal": "..." }
}
```

---

#### task.assign (S→C, 브로드캐스트)
태스크 할당. **클라이언트가 `to` 필드로 자신에게 해당하는 것만 처리.**

```json
{
  "task_id": "build-001",
  "to": "builder@mac-mini",
  "from": "orchestrator@MacBook",
  "instructions": "[SHELL] make build",
  "work_key": "LN-20260406-001",
  "context": {},
  "depends_on": [],
  "ts": "2026-04-06T12:00:00Z"
}
```

#### task.progress (C→S, 브로드캐스트)
진행 상황 스트리밍.

```json
{
  "task_id": "build-001",
  "from": "builder@mac-mini",
  "percent": 42,
  "message": "컴파일 중... 3/7",
  "ts": "2026-04-06T12:01:00Z"
}
```

#### task.result (C→S, 브로드캐스트)
태스크 완료.

```json
{
  "task_id": "build-001",
  "from": "builder@mac-mini",
  "event": "task.result",
  "status": "done",
  "output": "BUILD SUCCEEDED\n...",
  "exit_code": 0,
  "ts": "2026-04-06T12:05:00Z"
}
```

#### task.blocked (C→S, 브로드캐스트)
태스크 진행 불가.

```json
{
  "task_id": "build-001",
  "from": "builder@mac-mini",
  "event": "task.blocked",
  "reason": "missing_dependency",
  "message": "gcc를 찾을 수 없습니다",
  "ts": "2026-04-06T12:02:00Z"
}
```

#### task.approval_requested (C→S, 브로드캐스트)
Human-in-the-loop 승인 요청.

```json
{
  "task_id": "deploy-001",
  "from": "deployer@server",
  "prompt": "프로덕션 배포를 진행할까요?",
  "options": ["yes", "no", "later"],
  "ts": "2026-04-06T12:10:00Z"
}
```

---

#### agent.hello (S→C, 브로드캐스트)
에이전트 입장 알림.

```json
{
  "agent": "builder@mac-mini",
  "role": "builder",
  "machine": "mac-mini-m4",
  "work_key": "LN-20260406-001"
}
```

#### agent.bye (S→C, 브로드캐스트)
에이전트 퇴장 알림.

```json
{
  "agent": "builder@mac-mini",
  "role": "builder",
  "work_key": "LN-20260406-001"
}
```

---

#### mailbox.post (C→S)
오프라인 에이전트에게 메시지 전송.

```json
{
  "to": "tester@raspi",
  "from": "orchestrator@MacBook",
  "type": "info | instruction | join_request",
  "content": "메시지 내용",
  "work_key": "LN-20260406-001"
}
```

응답 (온라인): `{"delivered": true}`
응답 (오프라인): `{"delivered": false, "queued": true}`

#### mailbox.message (S→C, push)
재연결 시 mailbox 메시지 전달.

```json
{
  "from": "orchestrator@MacBook",
  "type": "join_request",
  "content": "...",
  "work_key": "LN-20260406-001",
  "ts": "2026-04-06T11:00:00Z"
}
```

---

#### state.update (C→S)
Work Key 상태 업데이트.

```json
{
  "status": "running",
  "goal": "iOS 앱 빌드",
  "shared_context": { "branch": "main" }
}
```

#### state.get (C→S)
현재 상태 조회. payload: `{}`
응답: `{"state": { ... }}`

---

### 3-C: REST API

| 메서드 | 경로 | 설명 |
|--------|------|------|
| `GET` | `/api/health` | 서버 상태 |
| `GET` | `/api/presence` | 전체 온라인 에이전트 목록 |
| `DELETE` | `/api/presence/:agent` | Ghost 에이전트 강제 제거 |
| `GET` | `/api/capabilities` | 빌더 capabilities 목록 |
| `GET` | `/api/work-keys` | 전체 Work Key 목록 |
| `GET` | `/api/work-keys/latest` | 최신 Work Key |
| `POST` | `/api/work-keys` | Work Key 생성 |
| `GET` | `/api/state/:wk` | Work Key 상태 조회 |
| `PATCH` | `/api/state/:wk` | Work Key 상태 업데이트 |
| `GET` | `/api/team/:wk` | 팀 대시보드 (state+agents+tasks) |
| `POST` | `/api/task` | 태스크 생성 및 브로드캐스트 |
| `GET` | `/api/task/:task_id` | 태스크 결과 조회 |
| `POST` | `/api/task/:task_id/result` | 태스크 결과 저장 (에이전트→서버) |
| `POST` | `/api/task/:task_id/cancel` | 태스크 취소 |
| `GET` | `/api/mailbox/:agent` | mailbox 메시지 수신 (pop) |
| `POST` | `/api/mailbox/:agent` | mailbox 메시지 전송 (push) |

#### POST /api/task
```json
{
  "work_key": "LN-20260406-001",
  "to": "builder@mac-mini",
  "task_id": "build-001",
  "instructions": "[SHELL] make build",
  "context": {},
  "depends_on": ["analyze-001"]
}
```

응답:
```json
{ "pending": false, "work_key": "LN-20260406-001", "task_id": "build-001" }
```
- `pending: false` = 에이전트 온라인, 즉시 전달
- `pending: true` = 의존성 있음, 조건 충족 시 자동 전달

---

## L4 — 팀 프로토콜

### 4-A: Task Instruction 형식

```
[PREFIX] <내용>
```

| 접두사 | 실행 방법 | 예시 |
|--------|----------|------|
| `[SHELL]` | bash 직접 실행 | `[SHELL] npm run build` |
| `[CLAUDE]` | claude CLI | `[CLAUDE] 이 파일을 리팩토링해줘` |
| `[OPENCODE]` | opencode CLI | `[OPENCODE] fix the failing tests` |
| `[GEMINI]` | gemini CLI | `[GEMINI] 코드 리뷰 해줘` |
| `[AIDER]` | aider CLI | `[AIDER] refactor auth module` |
| `[ORCHESTRATE]` | 서브 태스크 분해 | `[ORCHESTRATE] 앱 전체 빌드 및 테스트` |
| `[PIPELINE]` | Phase 1/2 파이프라인 | `[PIPELINE] 교육 콘텐츠 분석` |
| `(없음)` | 에이전트 기본 AI | 자연어 지시 |

### 4-B: TeamCreate

Work Key 생성 + 팀 초기화.

**요청**:
```json
{
  "goal": "달성할 목표",
  "pattern": "pipeline | fan-out | supervisor | hierarchical",
  "agents": [
    { "name": "builder@mac-mini", "type": "remote", "role": "builder" },
    { "name": "analyst", "type": "local", "role": "analyst" }
  ]
}
```

**실행 순서**:
1. `POST /api/work-keys` → WK 발급
2. `PATCH /api/state/{wk}` → 팀 매니페스트 저장
3. 오프라인 에이전트 → `POST /api/mailbox/{agent}` (join_request)
4. 반환: `{ work_key, online_agents, pending_agents }`

### 4-C: SendMessage

에이전트 간 정보 전달 (결과 대기 없음).

```json
{
  "from": "orchestrator@MacBook",
  "to": "builder@mac-mini",
  "type": "info | instruction | warning | join_request",
  "work_key": "LN-20260406-001",
  "content": "메시지 내용"
}
```

**라우팅**:
- 온라인 → WebSocket channel `mailbox.post` (즉시)
- 오프라인 → `POST /api/mailbox/{agent}` (재연결 시 전달)

### 4-D: TaskCreate

태스크 할당 + 결과 대기.

```json
{
  "work_key": "LN-20260406-001",
  "to": "builder@mac-mini",
  "task_id": "build-001",
  "instructions": "[SHELL] make build",
  "context": { "branch": "main", "version": "2.0" },
  "depends_on": ["analyze-001"]
}
```

**라우팅**:
- 로컬 에이전트 → Agent 도구로 subagent spawn
- 원격 온라인 → `POST /api/task` → channel broadcast
- 원격 오프라인 → `POST /api/mailbox/{agent}` 큐잉

**의존성 체인 자동 실행**:
```
task A (depends_on: [])  → 즉시 dispatch
task B (depends_on: [A]) → A 완료 시 자동 unblock + dispatch
task C (depends_on: [A, B]) → A, B 모두 완료 시 dispatch
```

---

## 에러 코드

| 코드 | 의미 | 처리 |
|------|------|------|
| `agent_offline` | 에이전트 미연결 | mailbox 큐잉 |
| `task_timeout` | 태스크 타임아웃 | `task.blocked` 발생 |
| `task_failed` | 태스크 실패 | 재시도 또는 에스컬레이션 |
| `missing_dependency` | 의존 태스크 미완료 | depends_on 대기 |
| `unknown_event` | 미정의 이벤트 | `{error: "unknown_event"}` 반환 |
| `not_found` | WK/태스크 없음 | 404 응답 |

---

## 버전 정보

| 항목 | 값 |
|------|-----|
| Phoenix vsn | `2.0.0` |
| Protocol spec | `1.0` |
| Server version | `0.3.0` |
