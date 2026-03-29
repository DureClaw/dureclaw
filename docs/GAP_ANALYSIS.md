# OAH Gap Analysis & Evolution Plan
*Updated: 2026-03-30*

## 역할 비교

| 항목 | Claude Code | OpenCode | ZeroClaw | **oah-agent** |
|---|---|---|---|---|
| 핵심 역할 | 대화형 AI 코딩 CLI | 오픈소스 CC 대체 | 경량 AI (ARM) | **멀티머신 AI 데몬** |
| 실행 모델 | 사람↔AI 인터랙티브 | 사람↔AI 인터랙티브 | 사람↔AI 인터랙티브 | **서버 태스크 자동 실행** |
| 멀티머신 | ❌ | ❌ | ❌ | ✅ |
| 병렬 에이전트 | Sub-agent (동일 세션) | ❌ | ❌ | ✅ 머신별 독립 프로세스 |
| 태스크 수신 | 사용자 입력 | 사용자 입력 | 사용자 입력 | **Phoenix WS broadcast** |
| AI 실행 | Claude API | Claude/GPT 등 | 로컬 LLM | **opencode/zeroclaw 위임** |
| Shell 실행 | Bash 도구 | Bash 도구 | 있음 | ✅ `[SHELL]` 직접 실행 |
| 상태 영속 | 세션 내 | 세션 내 | 세션 내 | **DETS 디스크 영속** |
| 대시보드 | ❌ | ❌ | ❌ | ✅ 웹 실시간 대시보드 |
| Windows | ✅ | ❌ | ❌ | ✅ exe 바이너리 |
| ARM 32bit | ❌ | ❌ | ✅ | ✅ Node.js JS 번들 |

## Gap 목록 및 해결 상태

### 🔴 Critical

| Gap | 해결 방법 | 상태 |
|---|---|---|
| **Windows AI 실행 불가** | `npm install -g opencode` 자동 설치 in oah-connect.ps1 | ✅ **해결** (2026-03-30) |
| **태스크 결과 비영속** | state_store.ex → `harness_tasks` DETS 테이블 추가 | ✅ **해결** (2026-03-30) |

### 🟡 Important

| Gap | 해결 방법 | 상태 |
|---|---|---|
| **태스크 취소 없음** | `task.cancel` 이벤트 + `POST /api/task/:id/cancel` | ✅ **해결** (2026-03-30) |
| **Ghost Presence 정리** | `DELETE /api/presence/:agent` 강제 연결 해제 API | ✅ **해결** (2026-03-30) |
| **인증 없음** | Tailscale 의존 보안 (현재 유지, API key는 TODO) | ⏳ TODO |
| **파일 전송 없음** | 공유 FS 또는 presigned URL 방식 필요 | ⏳ TODO |

### 🟢 Nice-to-have

| Gap | 해결 방법 | 상태 |
|---|---|---|
| **Linux 서버 빌드** | Docker cross-build 또는 Linux 머신에서 빌드 | ⏳ TODO |
| **태스크 재시도 정책** | max_retries 파라미터 + automatic re-assign | ⏳ TODO |
| **오케스트레이터 AI 라우팅** | builder별 전문화 + load balancing | ⏳ TODO |
| **출력 스트리밍** | task.progress 고도화 (실시간 청크) | ⏳ TODO |

## 아키텍처 진화 방향

```
현재 (v1):
  대시보드 → Phoenix → task.assign broadcast → 모든 builder 수신
                                               └─ role 필터 후 처리

목표 (v2):
  대시보드 → Phoenix → orchestrator AI
                          └─ 태스크 분해 + builder 지정 할당
                          └─ builder 결과 수집 + 종합
                          └─ 파이프라인 의존성 관리
```

## 주요 변경 이력

- 2026-03-30: Windows OpenCode npm 설치, 태스크 결과 DETS 영속, task.cancel, presence cleanup
- 2026-03-29: Windows exe 빌드, Pi JS 번들, CDN 캐시 우회, 롤 기반 라우팅
- 2026-03-10: 6-agent 분석 파이프라인, RAG, Phase 1/2 orchestration
