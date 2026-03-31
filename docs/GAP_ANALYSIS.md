# OAH Gap Analysis & Evolution Plan
*Updated: 2026-03-30*

---

## 역할 비교

| 항목 | Claude Code | OpenCode | ZeroClaw | **oah-agent** |
|------|------------|----------|---------|--------------|
| **핵심 역할** | 대화형 AI 코딩 CLI | 오픈소스 CC 대체 | 경량 AI (ARM) | **멀티머신 AI 오케스트레이션 데몬** |
| **실행 모델** | 사람↔AI 인터랙티브 | 사람↔AI 인터랙티브 | 사람↔AI 인터랙티브 | **서버 주도 자동 실행 (WebSocket)** |
| **멀티머신** | ❌ | ❌ | ❌ | ✅ Phoenix Channel |
| **병렬 에이전트** | Sub-agent (동일 세션) | ❌ | ❌ | ✅ 머신별 독립 프로세스 |
| **태스크 수신** | 사용자 입력 | 사용자 입력 | 사용자 입력 | **Phoenix WS broadcast** |
| **AI 백엔드** | Claude API | Claude/GPT 등 | 로컬 LLM | **claude-cli/opencode/gemini/codex/aider/zeroclaw (auto-detect)** |
| **Shell 실행** | Bash 도구 | Bash 도구 | 있음 | ✅ `[SHELL]` 직접 실행 |
| **상태 영속** | 세션 내 | 세션 내 | 세션 내 | **DETS 디스크 영속** |
| **대시보드** | ❌ | ❌ | ❌ | ✅ 웹 실시간 |
| **Windows** | ✅ | ❌ | ❌ | ✅ exe 바이너리 + PowerShell TUI |
| **ARM 32bit** | ❌ | ❌ | ✅ | ✅ Node.js JS 번들 |
| **태스크 취소** | ❌ | ❌ | ❌ | ✅ AbortController |
| **의존성 그래프** | ❌ | ❌ | ❌ | ✅ depends_on + pending ETS |
| **Stuck 감지** | 제한적 | ❌ | ❌ | ✅ 4가지 탈출 전략 |
| **도메인 전문 에이전트** | ❌ | ❌ | ❌ | ✅ 6개 Phase 1/2 에이전트 |
| **Capability 탐지** | ❌ | ❌ | ❌ | ✅ GPU/RAM/OS/백엔드/주변기기 |
| **인증** | OAuth | — | — | ⚠️ Tailscale 의존 (TODO) |
| **파일 전송** | 로컬 FS | 로컬 FS | 로컬 FS | ⚠️ 공유 FS 가정 (TODO) |

---

## Gap 목록 및 해결 상태

### ✅ 해결된 Gap (2026-03-30 기준)

| Gap | 해결책 | 날짜 |
|-----|--------|------|
| Windows AI 실행 불가 | oah-connect.ps1 opencode npm 자동설치 | 2026-03-30 |
| 태스크 결과 비영속 | harness_tasks DETS 테이블 추가 | 2026-03-30 |
| 태스크 취소 없음 | task.cancel 이벤트 + AbortController | 2026-03-30 |
| Ghost Presence | DELETE /api/presence/:agent | 2026-03-30 |
| 단일 AI 백엔드만 지원 | claude-cli/gemini/codex/aider/zeroclaw auto-detect, task별 backend 필드 | 2026-03-30 |
| RAM/GPU 탐지 없음 | ram:Xg, apple-gpu, nvidia-gpu capabilities | 2026-03-30 |
| 특수 주변기기 탐지 없음 | rpi-speakerphone, Windows 프린터/Office suite | 2026-03-30 |

### 🔴 Critical — 미해결

| Gap | 영향 | 해결 방향 | 예상 공수 |
|-----|------|----------|---------|
| **인증 없음** | 공개 네트워크 배포 불가 | Phoenix channel JWT + HMAC 태스크 서명 | 2-3일 |
| **파일 전송 없음** | 결과물 머신 간 공유 불가 | presigned URL + multipart upload 엔드포인트 | 2-3일 |

### 🟡 Important — TODO

| Gap | 영향 | 해결 방향 | 예상 공수 |
|-----|------|----------|---------|
| **결과 스트리밍 불완전** | 10초 tail만 전송, 실시간 아님 | 청크 스트리밍 + backpressure | 1-2일 |
| **태스크 재시도 없음** | 1회 실패 = blocked | max_retries + exponential backoff | 1일 |
| **비용 추적 없음** | 토큰 비용 모름 | per-task token_count 집계 → WK state | 0.5일 |
| **Linux 서버 빌드 없음** | setup-server.sh 소스빌드만 | GitHub Actions cross-compile matrix | 1일 |

### 🟢 Nice-to-have — ClawFit 분석 기반 신규 도출

| Gap | ClawFit 관점 | OAH 진화 방향 |
|-----|------------|--------------|
| **태스크→에이전트 자동 매핑** | qa→Router, research→Plan-Execute 패턴 | task_type별 최적 에이전트 auto-select |
| **비용-레이턴시 트레이드오프** | scoring (latency 50%, cost 25%) | budget/latency 제약 필드 지원 |
| **네트워크 적응** | online/offline/hybrid 필터 | Phoenix 단절 시 local fallback 모드 |
| **실증적 성공률 집계** | 모델 기반 추정만 존재 | task.result 기반 실측 성공률 → registry |

---

## 아키텍처 진화 방향

```
현재 (v0.3.0):
  대시보드 → Phoenix → task.assign broadcast → 에이전트 (role 필터)
                                                └─ capability 기반 라우팅
                    ↑
          [ORCHESTRATE] → Claude Haiku 분해 → subtasks 병렬 dispatch

목표 (v0.4.0):
  대시보드 → Phoenix → orchestrator AI
                          └─ ClawFit 스타일 scoring (task_type × caps × latency × cost)
                          └─ 최적 에이전트 선택 + 의존성 그래프 관리
                          └─ 실시간 청크 스트리밍
                          └─ 자동 재시도 + 비용 추적

장기 (v1.0.0):
  대시보드 → Phoenix → OAH + ClawFit closed-loop
                          └─ 실측 성공률/레이턴시/비용 축적
                          └─ ClawFit registry 피드백 → 추천 품질 향상
                          └─ JWT 인증 + 파일 전송 → 공개 네트워크 배포 가능
```

---

## 주요 변경 이력

- 2026-03-30: v0.3.0 — AI 오케스트레이션, capability registry, 태스크 의존성, 멀티 백엔드
- 2026-03-30: Windows OpenCode npm 설치, 태스크 결과 DETS 영속, task.cancel, presence cleanup
- 2026-03-29: Windows exe 빌드, Pi JS 번들, CDN 캐시 우회, 롤 기반 라우팅
- 2026-03-10: 6-agent 분석 파이프라인, RAG, Phase 1/2 orchestration
