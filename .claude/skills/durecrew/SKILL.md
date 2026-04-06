---
name: durecrew
description: |
  DureCrew 에이전트 팀 설계 및 오케스트레이션 메타스킬.
  로컬 subagent + 원격 Phoenix 에이전트를 하나의 팀으로 구성하고
  TeamCreate / SendMessage / TaskCreate 패턴으로 협업을 조율합니다.

  다음 상황에서 이 스킬을 사용하세요:
  - 2개 이상의 에이전트가 협업해야 할 때
  - 원격 머신(Mac Mini, 서버, Raspberry Pi 등)의 에이전트를 팀에 포함할 때
  - 복잡한 태스크를 병렬/파이프라인으로 분해할 때
  - 기존 DureCrew 팀에 새 에이전트를 추가하거나 재구성할 때
triggers:
  - "에이전트 팀 만들어"
  - "원격 에이전트 연결"
  - "팀 구성"
  - "durecrew"
  - "분산 에이전트"
  - "TaskCreate"
  - "TeamCreate"
model: opus
---

# DureCrew 에이전트 팀 오케스트레이션 스킬

DureCrew는 두레(dure)의 정신으로 — 로컬과 원격에 분산된 AI 에이전트들이
하나의 채널로 묶여 실시간 협력하는 팀 오케스트레이션 인프라입니다.

## Phase 0: 현재 상태 감사 (Audit)

실행 전 항상 먼저 확인합니다:

```
- .claude/agents/*.md 파일 목록 (기존 에이전트 정의)
- .claude/skills/ 디렉토리 (기존 스킬)
- CLAUDE.md의 DureCrew 레지스트리 섹션
- Phoenix 서버 연결 상태: GET http://localhost:4000/api/health
- 현재 Work Key 목록: GET http://localhost:4000/api/work-keys
- 온라인 에이전트 현황: GET http://localhost:4000/api/presence
```

**실행 모드 결정**:
- 에이전트/스킬 없음 → 신규 팀 구성
- 일부 존재 → 확장 모드
- Phoenix 오프라인 → 로컬 전용 모드 (subagent만)

---

## Phase 1: 도메인 분석

요청을 분석하여 다음을 파악합니다:

1. **핵심 태스크**: 무엇을 달성해야 하는가
2. **분해 가능성**: 병렬화 가능한 서브태스크 식별
3. **전문성 요구**: 각 태스크에 필요한 역할/능력
4. **실행 환경**: 로컬 vs 원격 실행이 적합한 태스크 구분

```
로컬 에이전트 적합:
  - 현재 코드베이스 수정, 파일 I/O
  - 빠른 응답이 필요한 태스크

원격 에이전트 적합:
  - 특수 하드웨어 필요 (GPU, 프린터, 마이크)
  - 장시간 실행 태스크 (빌드, 테스트, 크롤링)
  - 특정 OS/환경 필요 (Windows, ARM, Linux)
```

---

## Phase 2: 팀 아키텍처 설계

### 실행 모드 선택

**에이전트 팀 (기본, 권장)**: TeamCreate + SendMessage + TaskCreate
- 2개 이상 에이전트 협업
- 에이전트 간 실시간 소통 필요
- 로컬+원격 혼합 팀

**Subagent 전용**: Agent 도구 직접 호출
- 단일 독립 태스크
- 협업 불필요

### 6가지 아키텍처 패턴

| 패턴 | 구조 | 적합한 상황 |
|------|------|------------|
| Pipeline | A → B → C (순차) | 순서 의존 태스크 |
| Fan-out/Fan-in | orchestrator → [A,B,C] → merge | 병렬 독립 태스크 |
| Expert Pool | 상황별 전문가 선택 | 다양한 도메인 태스크 |
| Producer-Reviewer | 생성 → 검토 사이클 | 품질 중요 결과물 |
| Supervisor | 중앙 배분자 + 실행자들 | 동적 태스크 분배 |
| Hierarchical | 계층적 위임 | 대규모 복잡 프로젝트 |

### 팀 매니페스트 설계

```yaml
# team-manifest.yml (개념적 표현)
work_key: "LN-YYYYMMDD-XXX"
pattern: "fan-out/fan-in"  # 선택한 패턴

agents:
  - name: orchestrator
    type: local              # Claude Code subagent
    role: "팀 조율, 태스크 분배, 결과 통합"

  - name: builder-mac
    type: remote             # Phoenix WebSocket 에이전트
    machine: "mac-mini-m4"
    capabilities: ["apple-gpu", "macos"]
    role: "iOS/macOS 빌드 실행"

  - name: analyst
    type: local
    role: "코드 분석, 리포트 작성"

  - name: tester-linux
    type: remote
    machine: "raspberry-pi"
    capabilities: ["arm", "linux"]
    role: "ARM 환경 테스트"
```

---

## Phase 3: 에이전트 정의 생성

각 로컬 에이전트를 `.claude/agents/{name}.md`로 생성합니다.

**필수 포함 항목**:
- `model: opus` (항상)
- 역할(Role)과 책임(Responsibilities)
- 팀 소통 프로토콜 (어떻게 SendMessage/TaskCreate 사용)
- 입력/출력 형식
- 에러 처리 방식

원격 에이전트는 Phoenix 서버에서 독립 실행되므로
`.claude/agents/`에 **참조 문서**로만 정의합니다 (실행 정의 아님).

---

## Phase 4: 오케스트레이터 스킬 생성

팀을 조율하는 오케스트레이터 스킬을 생성합니다:

```
.claude/skills/{domain}/
├── SKILL.md          ← 오케스트레이터 워크플로
└── references/
    ├── team.yml      ← 팀 매니페스트
    └── protocols.md  ← 에이전트 간 소통 규약
```

---

## Phase 5: TeamCreate / SendMessage / TaskCreate 구현

### TeamCreate — 팀 초기화

```
목적: Work Key 생성 및 팀 에이전트 등록
```

**실행 순서**:
1. Phoenix Work Key 생성: `POST /api/work-keys`
2. 온라인 원격 에이전트 확인: `GET /api/presence`
3. 로컬 에이전트 목록 확인: `.claude/agents/` 파일
4. 팀 상태 초기화: `PATCH /api/state/{wk}` with goal + agents

**예시**:
```bash
# Work Key 생성
WK=$(curl -s -X POST http://localhost:4000/api/work-keys \
  -H "Content-Type: application/json" \
  -d '{"goal": "iOS 앱 빌드 및 테스트", "agents": ["orchestrator", "builder-mac"]}' \
  | jq -r '.work_key')

# 온라인 에이전트 확인
curl -s http://localhost:4000/api/presence | jq '.agents'
```

---

### SendMessage — 에이전트 간 메시지 전송

```
목적: 에이전트에게 정보/지시 전달 (결과 대기 없음)
```

**라우팅 로직**:
```
에이전트 타입에 따라:
  local → TaskCreate 또는 Agent 도구로 직접 실행
  remote (온라인) → Phoenix channel broadcast
  remote (오프라인) → Phoenix mailbox에 큐잉
```

**원격 에이전트에게 SendMessage**:
```bash
curl -s -X POST http://localhost:4000/api/mailbox/{agent_name} \
  -H "Content-Type: application/json" \
  -d '{
    "from": "orchestrator",
    "type": "info",
    "content": "Phase 1 완료. 빌드 준비 시작 요청.",
    "work_key": "'$WK'"
  }'
```

---

### TaskCreate — 태스크 생성 및 할당

```
목적: 에이전트에게 실행 태스크 할당, 결과 수신
```

**로컬 에이전트 태스크** (Agent 도구):
```
Agent 도구를 사용하여 .claude/agents/{name}.md 기반으로
subagent를 spawn하고 태스크를 실행합니다.
태스크 완료 시 결과를 오케스트레이터에게 반환합니다.
```

**원격 에이전트 태스크** (Phoenix REST):
```bash
# 원격 에이전트에게 태스크 할당
curl -s -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "work_key": "'$WK'",
    "to": "builder-mac",
    "task_id": "build-001",
    "instructions": "[SHELL] cd ~/project && xcodebuild -scheme App",
    "depends_on": []
  }'

# 결과 대기 (폴링)
curl -s http://localhost:4000/api/task-result/build-001
```

**의존성 있는 태스크 체인**:
```json
{
  "task_id": "test-001",
  "to": "tester-linux",
  "instructions": "ARM 환경에서 통합 테스트 실행",
  "depends_on": ["build-001"]   ← build-001 완료 후 자동 트리거
}
```

---

## Phase 6: 팀 검증

구성 완료 후 검증:

```
□ Phoenix 서버 health check 통과
□ Work Key 생성 성공
□ 원격 에이전트 presence 확인
□ 로컬 에이전트 정의 파일 존재
□ SendMessage 테스트 (에코 메시지)
□ TaskCreate 테스트 (간단한 태스크)
□ 결과 수신 확인
□ CLAUDE.md DureCrew 레지스트리 업데이트
```

---

## Phase 7: CLAUDE.md 레지스트리 업데이트

팀 구성 후 반드시 CLAUDE.md에 기록:

```markdown
## DureCrew Registry

### 현재 팀: {domain}
- Work Key: LN-YYYYMMDD-XXX
- 패턴: {pattern}
- 에이전트: {list}
- 생성일: {date}
- 상태: active

### 변경 이력
- {date}: 팀 초기 구성
```

---

## 참고 자료

- `references/team-patterns.md` — 6가지 패턴 상세 예시
- `references/remote-agent-guide.md` — Phoenix 연결 및 원격 에이전트 운영
- `references/task-dispatch.md` — TaskCreate/SendMessage API 레퍼런스
