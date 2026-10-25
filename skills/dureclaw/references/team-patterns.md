# DureClaw 팀 아키텍처 패턴

로컬 + 원격 에이전트를 조합한 6가지 협업 패턴입니다.

---

## 1. Pipeline (파이프라인)

```
orchestrator → analyst → builder-remote → tester-remote → reporter
     ↑______________________________________________|
                    결과 수집
```

**적합한 상황**: CI/CD 파이프라인, 순서가 중요한 다단계 처리

**구현**:
```
TaskCreate(analyst, "코드 분석")
  → 완료 시 TaskCreate(builder-remote, "빌드", depends_on=["analyze-001"])
  → 완료 시 TaskCreate(tester-remote, "테스트", depends_on=["build-001"])
  → 완료 시 TaskCreate(reporter, "리포트 작성", depends_on=["test-001"])
```

**원격 확장 포인트**: builder, tester를 원격 머신에 배치하여
빌드/테스트를 전용 환경에서 실행

---

## 2. Fan-out / Fan-in (병렬 분산)

```
orchestrator ──┬── analyst-1 (코드 품질)
               ├── analyst-2 (보안 취약점)
               ├── builder-mac (macOS 빌드)  ← 원격
               └── builder-linux (Linux 빌드) ← 원격
                         │
                    merge & report
```

**적합한 상황**: 크로스 플랫폼 빌드, 병렬 분석, 독립적 태스크 다수

**구현**:
```
# 동시에 모두 시작
TaskCreate(analyst-1, "품질 분석")          # 로컬
TaskCreate(analyst-2, "보안 분석")          # 로컬
TaskCreate(builder-mac, "macOS 빌드")       # 원격: mac-mini
TaskCreate(builder-linux, "Linux 빌드")     # 원격: ubuntu-server

# 모든 결과 수집 후 통합
결과 = await all([task-qa, task-sec, task-mac, task-linux])
TaskCreate(reporter, "통합 리포트")
```

---

## 3. Expert Pool (전문가 풀)

```
orchestrator
    │
    ├── [iOS 태스크] → ios-expert (mac-mini, xcode 필요)  ← 원격
    ├── [ML 태스크]  → ml-expert (nvidia-gpu 필요)        ← 원격
    ├── [문서 태스크] → writer (로컬)
    └── [테스트]     → tester (로컬)
```

**적합한 상황**: 태스크마다 필요한 환경/역할이 다를 때

**라우팅 로직**:
```
분석: 태스크에 필요한 capabilities
온라인 에이전트 중 해당 capabilities 보유 에이전트 선택
없으면 mailbox에 큐잉 (오프라인 대기)
```

---

## 4. Producer-Reviewer (생성-검토 사이클)

```
producer (로컬) ──► reviewer (로컬/원격) ──► producer (재작업)
      ↑___________________________|
            승인될 때까지 반복
```

**적합한 상황**: 코드 리뷰, 문서 품질 관리, 디자인 반복

**구현**:
```
round = 1
while round <= max_rounds:
    result = TaskCreate(producer, "코드 작성")
    review = TaskCreate(reviewer, "코드 리뷰", context=result)
    if review.approved: break
    SendMessage(producer, f"수정 요청: {review.feedback}")
    round++
```

---

## 5. Supervisor (감독자 모델)

```
supervisor (로컬 오케스트레이터)
    │
    ├── 동적 태스크 생성
    ├── 에이전트 상태 모니터링
    └── 결과에 따라 다음 단계 결정
         │
    ┌────┴────────────────────┐
    ▼         ▼              ▼
worker-1   worker-2    worker-remote
(로컬)     (로컬)       (원격)
```

**적합한 상황**: 결과에 따라 다음 태스크가 동적으로 결정될 때

**구현**:
```
queue = [초기 태스크들]
while queue:
    task = queue.pop()
    result = TaskCreate(적합한_에이전트, task)
    new_tasks = supervisor.analyze(result)  # 결과 분석 → 새 태스크 도출
    queue.extend(new_tasks)
```

---

## 6. Hierarchical Delegation (계층적 위임)

```
top-orchestrator (로컬)
    │
    ├── sub-orchestrator-A (로컬)
    │       ├── worker-1 (원격)
    │       └── worker-2 (원격)
    │
    └── sub-orchestrator-B (로컬)
            ├── worker-3 (로컬)
            └── worker-4 (원격)
```

**적합한 상황**: 대규모 프로젝트, 팀 안의 팀

**DureClaw 구현**:
- 각 sub-orchestrator는 자체 Work Key를 가질 수 있음
- top-orchestrator가 WK 간 결과를 통합
- 또는 하나의 WK에서 모든 계층이 소통

---

## 패턴 선택 가이드

```
태스크가 순서 의존적인가?
  Y → Pipeline

독립적 태스크가 여러 개인가?
  Y → Fan-out/Fan-in

태스크마다 필요한 환경이 다른가?
  Y → Expert Pool

품질 보증이 중요한가?
  Y → Producer-Reviewer

태스크가 동적으로 생성되는가?
  Y → Supervisor

팀이 계층적으로 조직되어야 하는가?
  Y → Hierarchical
```
