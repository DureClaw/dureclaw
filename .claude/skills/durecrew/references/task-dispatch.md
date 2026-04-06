# TaskCreate / SendMessage / TeamCreate API 레퍼런스

DureCrew의 세 가지 핵심 오퍼레이션 상세 명세입니다.

---

## TeamCreate

팀을 초기화하고 Work Key를 생성합니다.

### 입력

```json
{
  "goal": "달성할 목표 설명",
  "pattern": "pipeline|fan-out|expert-pool|producer-reviewer|supervisor|hierarchical",
  "agents": [
    {
      "name": "orchestrator",
      "type": "local",
      "role": "팀 조율"
    },
    {
      "name": "builder-mac",
      "type": "remote",
      "machine": "mac-mini-m4",
      "required_capabilities": ["macos", "xcode"],
      "role": "iOS 빌드"
    }
  ]
}
```

### 실행 순서

1. `POST /api/work-keys` → Work Key 발급
2. `GET /api/presence` → 원격 에이전트 온라인 확인
3. 오프라인 원격 에이전트 → mailbox에 "팀 합류 요청" 전송
4. `PATCH /api/state/{wk}` → 팀 정보 저장
5. 결과: `{work_key, online_agents, offline_agents}`

### curl 예시

```bash
# 1. Work Key 생성
WK=$(curl -s -X POST http://localhost:4000/api/work-keys \
  -H "Content-Type: application/json" \
  -d '{"goal": "크로스 플랫폼 빌드 및 테스트"}' \
  | jq -r '.work_key')

# 2. 팀 상태 저장
curl -s -X PATCH http://localhost:4000/api/state/$WK \
  -H "Content-Type: application/json" \
  -d '{
    "status": "running",
    "team": {
      "pattern": "fan-out",
      "agents": ["orchestrator", "builder-mac", "tester-pi"]
    }
  }'

echo "Team created: $WK"
```

---

## SendMessage

에이전트에게 정보/알림을 전송합니다. 결과를 기다리지 않습니다.

### 로컬 에이전트

Agent 도구를 통해 직접 메시지 전달 (subagent 컨텍스트에서).

### 원격 에이전트 (온라인)

Phoenix channel로 실시간 전달됩니다 (mailbox.post 이벤트).

### 원격 에이전트 (오프라인)

Phoenix mailbox에 큐잉, 재연결 시 자동 전달.

```bash
# 원격 에이전트에게 SendMessage
curl -s -X POST http://localhost:4000/api/mailbox/{agent_name} \
  -H "Content-Type: application/json" \
  -d '{
    "from": "orchestrator",
    "type": "info|instruction|warning|request",
    "content": "메시지 내용",
    "work_key": "'$WK'",
    "ts": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
  }'
```

---

## TaskCreate

에이전트에게 실행 태스크를 할당합니다. 결과를 기다립니다.

### 로컬 에이전트 (Agent 도구)

```
Agent 도구를 사용하여 .claude/agents/{name}.md를 참조하고
subagent를 spawn하여 태스크를 실행합니다.
결과는 Agent 도구의 반환값으로 수신됩니다.
```

### 원격 에이전트 (Phoenix REST)

```bash
# 태스크 할당
curl -s -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "work_key": "'$WK'",
    "to": "builder-mac",
    "task_id": "build-001",
    "instructions": "[SHELL] cd ~/project && make build",
    "context": {},
    "depends_on": [],
    "timeout_seconds": 300
  }'

# 결과 폴링 (완료까지 대기)
for i in $(seq 1 60); do
  RESULT=$(curl -s http://localhost:4000/api/task-result/build-001)
  if echo $RESULT | jq -e '.results[0]' > /dev/null 2>&1; then
    echo "$RESULT" | jq '.'
    break
  fi
  sleep 5
done
```

### 의존성 체인

```bash
# 태스크 A (의존성 없음)
curl -s -X POST http://localhost:4000/api/task \
  -d '{"task_id": "analyze-001", "to": "analyst", "depends_on": [], ...}'

# 태스크 B (A 완료 후 자동 실행)
curl -s -X POST http://localhost:4000/api/task \
  -d '{"task_id": "build-001", "to": "builder", "depends_on": ["analyze-001"], ...}'

# 태스크 C (A, B 모두 완료 후 실행)
curl -s -X POST http://localhost:4000/api/task \
  -d '{"task_id": "deploy-001", "to": "deployer", "depends_on": ["analyze-001", "build-001"], ...}'
```

### 지원 instructions 형식

```
[SHELL] <bash 명령>          — 쉘 직접 실행
[CLAUDE] <프롬프트>           — claude-cli 실행
[OPENCODE] <프롬프트>         — opencode 실행
[AIDER] <프롬프트>            — aider 실행
[GEMINI] <프롬프트>           — gemini CLI 실행
<일반 텍스트>                 — 에이전트 기본 AI로 처리
```

---

## MCP 도구로 사용하기

Claude Code에서 `mcp__oah__*` 도구로 직접 사용 가능합니다:

```
mcp__oah__write_state     ← TeamCreate 상태 저장
mcp__oah__read_state      ← 팀 상태 조회
mcp__oah__post_message    ← SendMessage
mcp__oah__read_mailbox    ← mailbox 수신
mcp__oah__send_task       ← TaskCreate (원격)
mcp__oah__receive_task    ← 태스크 수신 (에이전트 측)
mcp__oah__complete_task   ← 태스크 완료 보고
mcp__oah__get_presence    ← 온라인 에이전트 확인
```

---

## 에러 처리

| 상황 | 처리 방법 |
|------|----------|
| 원격 에이전트 오프라인 | mailbox 큐잉 + 로컬 fallback 고려 |
| 태스크 타임아웃 | `task.blocked` 이벤트 발생 → Supervisor에게 알림 |
| Phoenix 서버 다운 | 로컬 전용 모드 전환 (subagent만) |
| 태스크 실패 | `status: "failed"` + 재시도 또는 대체 에이전트 |
