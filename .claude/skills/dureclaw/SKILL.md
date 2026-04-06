---
name: dureclaw
description: |
  DureClaw 에이전트 팀 설계 및 오케스트레이션 메타스킬.
  로컬 subagent + 원격 Phoenix 에이전트를 하나의 팀으로 구성하고
  TeamCreate / SendMessage / TaskCreate 패턴으로 협업을 조율합니다.

  다음 상황에서 이 스킬을 사용하세요:
  - 2개 이상의 에이전트가 협업해야 할 때
  - 원격 머신(Mac Mini, 서버, Raspberry Pi 등)의 에이전트를 팀에 포함할 때
  - 복잡한 태스크를 병렬/파이프라인으로 분해할 때
  - 기존 DureClaw 팀에 새 에이전트를 추가하거나 재구성할 때
triggers:
  - "에이전트 팀 만들어"
  - "원격 에이전트 연결"
  - "팀 구성"
  - "dureclaw"
  - "분산 에이전트"
  - "TaskCreate"
  - "TeamCreate"
  - "팀 설정"
  - "팀 확장"
  - "서버 설정해줘"
  - "워커 추가"
  - "팀 상태"
  - "에이전트 몇 명"
  - "온라인 에이전트"
  - "setup team"
  - "team status"
model: opus
---

# DureClaw 에이전트 팀 오케스트레이션 스킬

DureClaw는 두레(dure)의 정신으로 — 로컬과 원격에 분산된 AI 에이전트들이
하나의 채널로 묶여 실시간 협력하는 팀 오케스트레이션 인프라입니다.

## Phase 0: 현재 상태 감사 (Audit)

실행 전 항상 먼저 확인합니다. **Bash 도구로 직접 실행**하세요:

```bash
# 1. Phoenix 서버 상태
curl -sf http://localhost:4000/api/health || echo "OFFLINE"

# 2. 온라인 에이전트 현황
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'온라인: {len(agents)}명')
for a in agents: print(f'  ✅ {a.get(\"name\")} [{a.get(\"role\")}]')
" 2>/dev/null || echo "에이전트 없음"

# 3. 최신 Work Key
curl -sf http://localhost:4000/api/work-keys/latest 2>/dev/null || echo "Work Key 없음"
```

**실행 모드 결정**:
- Phoenix **오프라인** → 서버 설치 필요 (`팀 확장` 플로우 실행)
- 에이전트 **0명** → 워커 추가 필요 (`팀 확장` 플로우 실행)
- 에이전트 **1명 이상** → 팀 구성 완료, 태스크 배분 가능

---

## 팀 확장 플로우 (대화형 — Phoenix 서버 + 워커 설정)

사용자가 "팀 설정", "서버 설정", "워커 추가" 등을 요청하면
**각 단계 실행 후 사용자에게 말을 걸며** 진행합니다.

### Step 1: Phoenix 서버 확인 및 시작

```bash
curl -sf http://localhost:4000/api/health && echo "RUNNING" || echo "NOT_RUNNING"
```

- RUNNING → "서버가 이미 실행 중이에요!" 라고 말하고 Step 2로
- NOT_RUNNING → "서버가 없네요. 지금 설치할게요!" 라고 말하고:

```bash
curl -fsSL https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-server.sh | bash &
sleep 8 && curl -sf http://localhost:4000/api/health && echo "OK" || echo "시작 중..."
```

### Step 2: 서버 IP 자동 감지 + 사용자에게 알림

```bash
TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "")
SERVER_IP="${TS_IP:-$LAN_IP}"
AGENT_URL="https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.sh"
echo "SERVER_IP=$SERVER_IP"
echo "TS=$TS_IP LAN=$LAN_IP"
```

결과에 따라 사용자에게 상황 설명:
- Tailscale IP 있음 → "Tailscale 사설망이 감지됐어요. 어떤 네트워크에서도 연결 가능합니다."
- LAN IP만 있음 → "같은 네트워크 내에서만 연결 가능해요. 다른 네트워크 머신은 Tailscale이 필요해요."

### Step 3: 현재 팀 현황 파악 + 추가 여부 질문

```bash
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'현재 온라인: {len(agents)}명')
for a in agents: print(f'  {a.get(\"name\")} [{a.get(\"role\")}]')
"
```

현황을 알려주고 질문: "워커를 추가할 머신이 있나요? 있다면 어떤 역할이 필요한지 알려주세요."

### Step 4: IP가 채워진 명령어를 바로 안내

Step 2의 SERVER_IP로 실제 실행 가능한 명령어를 출력합니다:

```bash
SERVER_IP=$(tailscale ip -4 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
AGENT_URL="https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 워커 머신에서 복사·실행하세요"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "[ macOS / Linux — builder ]"
echo "  PHOENIX=ws://$SERVER_IP:4000 ROLE=builder bash <(curl -fsSL $AGENT_URL)"
echo ""
echo "[ macOS / Linux — tester ]"
echo "  PHOENIX=ws://$SERVER_IP:4000 ROLE=tester bash <(curl -fsSL $AGENT_URL)"
echo ""
echo "[ Windows PowerShell ]"
echo "  \$env:PHOENIX='ws://$SERVER_IP:4000'; \$env:ROLE='builder'"
echo "  irm https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.ps1 | iex"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

명령어 출력 후 사용자에게:
> "위 명령어를 워커 머신에서 실행해 보세요. 완료되면 알려주세요!"

사용자가 역할을 지정하면 ROLE 값을 맞춰서 안내합니다.

### Step 5: 연결 확인 (사용자 완료 신호 후)

사용자가 완료 신호를 보내면 즉시 확인:

```bash
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'✅ 팀 완성: {len(agents)}명 온라인')
for a in agents:
    caps = ', '.join(a.get('capabilities', []))
    print(f'   {a.get(\"name\")} [{a.get(\"role\")}] {caps}')
"
```

더 추가할 머신이 있는지 물어보고, 없으면 팀 구성 완료를 알립니다.

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
□ CLAUDE.md DureClaw 레지스트리 업데이트
```

---

## Phase 7: CLAUDE.md 레지스트리 업데이트

팀 구성 후 반드시 CLAUDE.md에 기록:

```markdown
## DureClaw Registry

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
