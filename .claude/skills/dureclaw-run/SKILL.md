---
name: dureclaw-run
description: |
  DureClaw 팀을 실제로 실행하는 오케스트레이션 스킬.
  network-scout → team-builder → task-dispatcher → result-watcher
  4개 에이전트가 파이프라인으로 협력하여 목표를 달성합니다.

  다음 상황에서 이 스킬을 사용하세요:
  - "팀으로 구현해", "에이전트 팀으로 실행"
  - "원격 에이전트와 함께 작업"
  - "TaskCreate로 분산 실행"
  - 구체적인 구현 태스크를 팀에게 위임할 때
triggers:
  - "팀으로 구현"
  - "에이전트 팀으로"
  - "dureclaw run"
  - "원격 에이전트와"
  - "분산 실행"
model: opus
---

# DureClaw Run — 팀 실행 오케스트레이션

## 입력 파싱

사용자 요청에서 다음을 추출합니다:

```
GOAL      = 달성할 목표 (자연어)
TASKS     = 분해된 태스크 목록 (없으면 orchestrator가 분해)
PATTERN   = 실행 패턴 (기본: 자동 감지)
TIMEOUT   = 전체 타임아웃 (기본: 600초)
```

---

## Step 1: TeamCreate — network-scout 실행

**Agent 도구**로 network-scout subagent 실행:

```
목적: 네트워크 + presence 상태 파악
에이전트: .claude/agents/network-scout.md
태스크: 현재 Phoenix 서버, Tailscale 피어, 온라인 에이전트 전체 탐색
출력: network_report
```

network_report에서:
- `phoenix_server` → 이후 모든 API 호출에 사용
- `online_agents` → team-builder에 전달
- `tailscale_peers` → 오프라인 에이전트 합류 가능성 판단

---

## Step 2: TeamCreate — team-builder 실행

network_report를 컨텍스트로 **Agent 도구** 실행:

```
목적: Work Key 생성, 팀 매니페스트 구성
에이전트: .claude/agents/team-builder.md
입력: network_report + GOAL + PATTERN
출력: team_manifest {work_key, agents, state_url}
```

팀 구성 원칙:
- 온라인 원격 에이전트 → 즉시 태스크 배정
- 오프라인 피어 → mailbox로 합류 요청
- 원격 에이전트 0명 → 로컬 subagent만으로 구성

---

## Step 3: 태스크 분해

GOAL을 구체적인 태스크로 분해합니다.

**분해 기준**:
```
1. 병렬 실행 가능한가? → 독립 태스크로 분리
2. 순서 의존성 있는가? → depends_on 설정
3. 원격 환경 필요한가? → 원격 에이전트 배정
4. 로컬 파일 접근 필요한가? → 로컬 에이전트 배정
```

**태스크 형식**:
```json
[
  {
    "task_id": "step-001",
    "to": "builder@mac-mini",
    "type": "remote",
    "instructions": "[SHELL] make build",
    "depends_on": []
  },
  {
    "task_id": "step-002",
    "to": "analyst",
    "type": "local",
    "instructions": "빌드 결과 분석 후 품질 리포트 작성",
    "depends_on": ["step-001"]
  }
]
```

---

## Step 4: TaskCreate — task-dispatcher 실행

team_manifest + 태스크 목록을 컨텍스트로 **Agent 도구** 실행:

```
목적: 태스크를 올바른 에이전트에게 dispatch
에이전트: .claude/agents/task-dispatcher.md
입력: team_manifest + tasks[]
출력: dispatch_report
```

dispatch 우선순위:
```
1. depends_on == [] 태스크 동시 시작
2. 원격 온라인 → POST /api/task
3. 원격 오프라인 → POST /api/mailbox (큐잉)
4. 로컬 → Agent 도구 spawn
```

---

## Step 5: 결과 수집 — result-watcher 실행

dispatch_report를 컨텍스트로 **Agent 도구** 실행:

```
목적: 모든 태스크 완료 감시 + 통합 리포트
에이전트: .claude/agents/result-watcher.md
입력: dispatch_report + work_key + timeout
출력: final_report
```

감시 동안:
- 30초마다 GET /api/task-result/{task_id} 폴링
- 완료된 태스크의 depends_on을 가진 태스크 자동 unblock
- 실패 시 최대 3회 재시도
- 타임아웃 시 에스컬레이션

---

## Step 6: 최종 결과 통합

result-watcher의 final_report를 받아:

1. Work Key 상태 업데이트: `status: "done"`
2. 핵심 산출물 추출
3. 사용자에게 요약 보고

---

## 에러 핸들링

| 상황 | 처리 |
|------|------|
| Phoenix 오프라인 | 로컬 전용 모드 전환 (subagent만) |
| 원격 에이전트 전원 오프라인 | 로컬 에이전트로 대체 + 경고 |
| 태스크 반복 실패 | orchestrator에게 에스컬레이션 |
| Tailscale 없음 | LAN/로컬 IP로 폴백 |

---

## 참고

- `references/agent-protocols.md` — 에이전트 간 메시지 형식
- `.claude/agents/network-scout.md`
- `.claude/agents/team-builder.md`
- `.claude/agents/task-dispatcher.md`
- `.claude/agents/result-watcher.md`
