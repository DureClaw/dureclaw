# DureClaw — CLAUDE.md

Claude Code가 이 프로젝트에서 작업할 때 참고하는 레지스트리입니다.

## DureClaw Registry

### 팀 구성 (2026-04-06)

**스킬**:
- `/dureclaw` — 팀 설계 메타스킬 (Phase 0-7)
- `/dureclaw-run` — 실제 팀 실행 오케스트레이션

**에이전트 팀**:
| 에이전트 | 역할 |
|---------|------|
| `orchestrator` | 팀 리더, 전체 조율 |
| `network-scout` | Tailscale/Phoenix 네트워크 탐색 |
| `team-builder` | Work Key 생성, 팀 초기화 |
| `task-dispatcher` | 태스크 라우팅 (로컬/원격) |
| `result-watcher` | 결과 수집, 통합 리포트 |

**실행 패턴**: Pipeline
```
orchestrator
  └─[1]─ network-scout   (네트워크 탐색)
  └─[2]─ team-builder    (팀 초기화)
  └─[3]─ task-dispatcher (태스크 배분)
  └─[4]─ result-watcher  (결과 수집)
```

### 인프라

- **Phoenix 서버**: `http://localhost:4000` (로컬) / Tailscale IP (원격)
- **사설망**: Tailscale (WireGuard 기반 mesh VPN)
- **상태 저장**: DETS (디스크 영속, 재시작 유지)
- **Work Key 형식**: `LN-YYYYMMDD-XXX`

### 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-04-06 | 초기 팀 구성 (5 에이전트, 2 스킬) |
| 2026-04-06 | Tailscale 사설망 통합 |
| 2026-04-06 | DureClaw skill (harness 패턴) 추가 |

## 프로젝트 규칙

- Phoenix 서버 코드: `packages/phoenix-server/` (Elixir)
- 에이전트 데몬: `packages/agent-daemon/` (TypeScript/Bun)
- 스킬/에이전트 정의: `.claude/skills/`, `.claude/agents/`
- Credo strict 통과 필수: `mix credo --strict`
- 두 리모트에 항상 push: `origin` (baryonlabs) + `dureclaw`
