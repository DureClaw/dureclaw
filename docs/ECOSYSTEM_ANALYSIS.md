# OAH Ecosystem Analysis & ClawFit Integration
*Updated: 2026-03-30*

---

## 1. ClawFit 개요

**저장소**: https://github.com/hongsw/clawfit
**첫 릴리즈**: 2026-03-25 (MIT, Python 3.7+)
**정의**: AI 에이전트 인프라 추천 엔진 — "주어진 태스크 타입, 레이턴시 목표, 예산, 네트워크 조건에서 최적의 (에이전트 패턴 × LLM × 하드웨어) 조합은?"

### 핵심 기능

```bash
clawfit recommend --task code-gen --latency low --budget 0.01
clawfit list agents|llms|hardware
clawfit profile
```

**Scoring 공식** (max 1.0):
- Latency 50% (agent 20% + LLM 20% + hardware 10%)
- Cost 25% (tier 기반, ≤$0 = 1.0, $50+ = 0.1)
- Preference Bonus 15% (LLM이 agent preferred list에 있으면)
- Baseline 10%

### 지원 필터

| 필터 | 옵션 |
|------|------|
| --task | qa, research, code-gen, data-analysis, classification, summarization |
| --latency | low, medium, high |
| --network | online, offline, hybrid |
| --statefulness | stateless, stateful |
| --hardware | cloud, edge, on-prem |

---

## 2. ClawFit 7계층 에코시스템 프레임워크

ClawFit은 AI 에이전트 생태계를 7계층으로 분류합니다:

```
┌─────────────────────────────────────────────────────────┐
│  L7: Human Interfaces     Voice, terminal, speech       │
│  L6: Knowledge Infra      RAG, context retrieval        │
│  L5: Research/Bench       평가 하네스, 자율 연구 루프    │
│  L4: Capability Ext.      MCP servers, memory plugins   │
│  L3: Team Harness  ◄──    Executable SSOT, 팀 운영체제  │ ← OAH 위치
│  L2: Meta Wrappers        SuperClaude, oh-my-claudecode │
│  L1: Base Runtimes        Claude Code, OpenCode, Aider  │
└─────────────────────────────────────────────────────────┘
```

**OAH는 L3 (Team Harness)**에 위치:
- 팀 전체의 AI 워크플로를 운영하는 "팀 운영체제"
- L1 런타임(claude-cli, opencode 등)을 백엔드로 선택 실행
- L4 capability 확장(MCP, RAG)을 조율
- L6 knowledge infra(Qdrant)와 통합 준비

---

## 3. OAH vs ClawFit 비교

| 차원 | ClawFit | OAH |
|------|---------|-----|
| **목적** | 배포 전 인프라 선택 지원 | 런타임 오케스트레이션 실행 |
| **질문** | "어떤 조합을 써야 하나?" | "어떻게 실행하고 조율하나?" |
| **입력** | 태스크 제약 조건 | 에이전트 할당 + 태스크 |
| **출력** | 추천 구성 (순위) | 태스크 결과, 상태, 리포트 |
| **상태** | Stateless | Stateful (DETS) |
| **비용 인식** | per-1k-token 명시 | 미추적 (v0.4.0 TODO) |
| **실증 데이터** | 모델 기반 추정 (~5 data points) | 실측 데이터 존재 |
| **네트워크 모델** | online/offline/hybrid 명시 | Phoenix 연결 가정 |
| **하드웨어 모델** | cloud/edge/on-prem 분류 | capabilities 자동 탐지 |

### OAH만 할 수 있는 것

1. 실제 태스크 실행 (shell, AI, pipeline)
2. 머신 간 실시간 상태 공유 (Phoenix DETS)
3. 태스크 의존성 관리 (depends_on, pending ETS)
4. Stuck 감지 + 4가지 탈출 전략
5. 도메인 전문 에이전트 (Phase 1/2, 6개 역할)
6. Offline 큐 (mailbox persistence)
7. 실시간 대시보드 + 이벤트 로그

### ClawFit만 할 수 있는 것

1. 태스크 타입별 최적 인프라 추천
2. 비용-레이턴시 명시적 트레이드오프 scoring
3. 에코시스템 전체 분류 (7계층)
4. 네트워크 조건별 필터링 (offline/hybrid)
5. Machine-readable, 감사 가능한 비교 데이터

---

## 4. Closed-Loop 통합 아키텍처 (전략적 기회)

```
┌─────────────────────────────────────────────────────────────┐
│                    CLOSED-LOOP SYSTEM                       │
│                                                             │
│  사용자 목표                                                  │
│       │                                                     │
│       ▼                                                     │
│  ClawFit ────────────────────────────────────────────────┐  │
│  recommend()                                              │  │
│  "code-gen, low-latency, $0.01"                           │  │
│       │                                                   │  │
│       │ 추천: claude-cli + Hongui-Macmini (apple-gpu)     │  │
│       ▼                                                   │  │
│  OAH Orchestrator ──────────────────────────────────────  │  │
│  - task.assign (backend=claude-cli, target=Hongui-Macmini)│  │
│  - reflectiveAgent() 실행                                 │  │
│  - task.result 수집                                       │  │
│       │                                                   │  │
│       │ 실측: latency=45s, cost=$0.008, success=true      │  │
│       ▼                                                   │  │
│  OAH Metrics Registry ──────────────────────────────────► │  │
│  /api/metrics → {task_type, backend, latency, cost, ok}   │  │
│                                                           │  │
│  ◄────────────────────────────────────────────────────────┘  │
│  ClawFit registry 업데이트 → 다음 추천 품질 향상              │
└─────────────────────────────────────────────────────────────┘
```

**구현 단계**:

1. **v0.4.0**: OAH에 metrics 수집 추가
   - task.result에 `latency_ms`, `cost_usd`, `backend` 필드 포함
   - `/api/metrics` 엔드포인트: task_type별 평균 성공률/레이턴시/비용

2. **v0.5.0**: ClawFit 피드백 루프
   - OAH metrics → ClawFit `registry/empirical.json` 업데이트
   - `clawfit recommend` 결과에 "OAH 실측 데이터 기반" 레이블

3. **v1.0.0**: 완전한 closed-loop
   - 새 태스크 수신 시 ClawFit API 호출 → 최적 에이전트 자동 선택
   - 성공/실패 피드백 → 다음 추천 품질 개선

---

## 5. 에코시스템 포지셔닝 맵

```
                    COMPLEXITY
                    (멀티머신, 병렬, 영속)
                    ▲
              HIGH  │  oah-agent (L3)
                    │    ■ 분산 오케스트레이션
                    │    ■ 실시간 대시보드
                    │    ■ 영속 상태
                    │
             MED    │  Claude Code / OpenCode (L1)
                    │    ■ 대화형 AI 코딩
                    │    ■ 단일 머신
                    │
              LOW   │  ZeroClaw (L1)
                    │    ■ ARM 경량
                    │    ■ 로컬 LLM
                    │
                    └─────────────────────────────►
                    LOW         MED          HIGH
                              AUTOMATION
                          (서버 주도 자동 실행)

 ClawFit ──► 이 맵 자체를 데이터화 (meta-level)
```

---

## 6. 참고 — ClawFit이 추적하는 신흥 패턴 (2026-03)

ClawFit README가 명시적으로 추적 중인 에코시스템 트렌드:

| 패턴 | 대표 도구 | OAH 관련성 |
|------|----------|-----------|
| Agent Orchestration Harness | DeerFlow, revfactory, Scion | OAH와 동일 계층 경쟁 |
| Voice Integration | VibeVoice, local-first voice | rpi-speakerphone capability와 연결 가능 |
| Mobile Actions | Appium MCP | Windows 프린터/Office capability와 유사 |
| Company-Scale Coordination | Paperclip | OAH의 장기 목표 방향 |
| "Oh-my-*" wrapper family | oh-my-claudecode, oh-my-opencode | OAH가 wrapper 역할도 할 수 있음 |

---

*이 문서는 ClawFit (https://github.com/hongsw/clawfit) 분석 기반으로 작성됨.*
*OAH 실측 데이터가 ClawFit registry에 기여할 수 있도록 통합 추진 예정.*
