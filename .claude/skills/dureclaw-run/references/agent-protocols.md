# 에이전트 간 소통 프로토콜

DureClaw 팀 내 에이전트들이 주고받는 메시지 형식입니다.

## SendMessage 페이로드

```json
{
  "from": "에이전트 이름",
  "to": "수신 에이전트 이름",
  "type": "info | instruction | result | error | join_request",
  "work_key": "LN-YYYYMMDD-XXX",
  "payload": { },
  "ts": "2026-04-06T12:00:00Z"
}
```

## 타입별 payload

### info
```json
{ "content": "텍스트 메시지" }
```

### instruction
```json
{
  "action": "실행할 액션",
  "params": {},
  "priority": "high | normal | low"
}
```

### result
```json
{
  "task_id": "step-001",
  "status": "done | failed | blocked",
  "output": "결과 내용",
  "artifacts": ["파일경로1", "파일경로2"]
}
```

### error
```json
{
  "code": "TIMEOUT | AGENT_OFFLINE | TASK_FAILED",
  "message": "에러 설명",
  "task_id": "step-001",
  "retry_count": 2
}
```

### join_request
```json
{
  "server": "ws://100.64.0.1:4000",
  "role": "builder",
  "work_key": "LN-YYYYMMDD-XXX"
}
```

## 파이프라인 메시지 흐름

```
orchestrator
  → [Agent tool] → network-scout
      → network_report → team-builder
          → team_manifest → task-dispatcher
              → dispatch_report → result-watcher
                  → final_report → orchestrator
```

각 단계는 이전 에이전트의 출력을 컨텍스트로 받아 실행합니다.
