# 에이전트 설정 가이드 — open-agent-harness

각 에이전트의 역할, 시작 명령, 태스크 디스패치 패턴을 정의한다.

---

## 에이전트 로스터

| 이름 | 역할 | 담당 |
|------|------|------|
| `agent1@mac` | `builder` | 신규 기능 모듈 작성 (auth, cart 등) |
| `agent2@mac` | `builder` | 신규 기능 모듈 작성 (products, orders 등) |
| `agent3@mac` | `integrator` | 통합(main.py 업데이트) + 테스트 작성 |
| `orchestrator@mac` | `orchestrator` | 태스크 분해 및 에이전트 조율 |

---

## 에이전트 시작 명령

### 공통 변수 (프로젝트마다 변경)

```bash
export PHOENIX=ws://localhost:4000          # Phoenix 서버 주소
export WK=LN-20260308-002                  # 현재 Work Key
export PROJECT=/path/to/project            # 프로젝트 루트
export OAH=/Users/hongmartin/dev/open-agent-harness/packages/agent-daemon/src/index.ts
```

### agent1@mac (builder)

```bash
AGENT_NAME=agent1@mac \
AGENT_ROLE=builder \
WORK_KEY=$WK \
PROJECT_DIR=$PROJECT \
bun run $OAH $PHOENIX
```

### agent2@mac (builder)

```bash
AGENT_NAME=agent2@mac \
AGENT_ROLE=builder \
WORK_KEY=$WK \
PROJECT_DIR=$PROJECT \
bun run $OAH $PHOENIX
```

### agent3@mac (integrator)

```bash
AGENT_NAME=agent3@mac \
AGENT_ROLE=integrator \
WORK_KEY=$WK \
PROJECT_DIR=$PROJECT \
bun run $OAH $PHOENIX
```

---

## Work Key 관리

### 새 세션 시작

```bash
# Work Key 새로 발급
WK=$(curl -sf -X POST http://localhost:4000/api/work-keys \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['work_key'])")
echo "Work Key: $WK"
```

### 기존 세션 이어서

```bash
# 최근 Work Key 조회
WK=$(curl -sf http://localhost:4000/api/work-keys/latest \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['work_key'])")
echo "Work Key: $WK"
```

---

## 태스크 디스패치 패턴

### 단일 에이전트에게

```bash
curl -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "work_key": "'"$WK"'",
    "to": "agent1@mac",
    "role": "builder",
    "task_id": "my-task-001",
    "instructions": "여기에 구체적인 작업 지시 내용"
  }'
```

### 병렬 디스패치 (agent1 + agent2 동시)

```bash
# agent1에게
curl -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{"work_key":"'"$WK"'","to":"agent1@mac","role":"builder","task_id":"task-A","instructions":"..."}'

# agent2에게 (동시)
curl -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{"work_key":"'"$WK"'","to":"agent2@mac","role":"builder","task_id":"task-B","instructions":"..."}'
```

### 통합 (agent1+2 완료 후 agent3에게)

```bash
curl -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "work_key": "'"$WK"'",
    "to": "agent3@mac",
    "role": "integrator",
    "task_id": "integrate-001",
    "instructions": "agent1이 만든 X와 agent2가 만든 Y를 main.py에 통합하고 테스트를 추가하라."
  }'
```

---

## 반복 워크플로 (표준 사이클)

```
1. Phoenix 서버 확인
   curl http://localhost:4000/api/health

2. Work Key 확인/발급
   WK=$(curl -sf http://localhost:4000/api/work-keys/latest | ...)

3. 에이전트 3개 iTerm 탭에서 시작
   (agent1@mac, agent2@mac, agent3@mac)

4. 기능 요청 → agent1 + agent2 병렬 디스패치
   (각자 독립 모듈 작성)

5. agent3 통합 디스패치
   (main.py 업데이트 + 테스트 작성)

6. 대시보드 확인
   http://localhost:4000/
```

---

## instructions 작성 가이드

에이전트가 올바르게 동작하려면 instructions를 명확하게 써야 한다.

| 항목 | 예시 |
|------|------|
| 파일 경로 | `src/cart.py` (프로젝트 루트 기준 상대경로) |
| 의존성 | `auth.py의 JWT 검증 함수를 재사용하라` |
| 데이터 구조 | Pydantic 모델, 필드 명세 포함 |
| 금지 사항 | `외부 DB 사용 금지, in-memory 스토어만` |
| 완료 기준 | `파일이 생성되고 import 오류 없어야 함` |

---

## 현재 프로젝트별 설정

### project3 (FastAPI 서버 테스트)

```bash
PROJECT=/Volumes/homes/kilosnetwork/nas-dev/nas_workspace/project3
WK=LN-20260308-002
PHOENIX=ws://localhost:4000
```

생성된 모듈:
- `src/auth.py` — JWT 인증 (agent1)
- `src/products.py` — 상품 CRUD (agent2)
- `src/cart.py` — 장바구니 (agent1)
- `src/orders.py` — 주문 (agent2)
- `src/main.py` — FastAPI 앱 통합 (agent3)
- `tests/test_api.py` — 통합 테스트 (agent3)
- `requirements.txt` — 의존성 목록 (agent3)
