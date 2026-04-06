# DureClaw (두레클로)

<img src="https://github.com/user-attachments/assets/b0169be5-c373-4e38-894b-7f4f1b17aa94" alt="DureClaw Logo" width="100%" />

분산된 디바이스의 AI 에이전트들이 하나의 채널로 묶여 실시간 협력하는 오케스트레이션 인프라.
Claude Code를 오케스트레이터로, 각 머신의 AI 에이전트들을 워커로 연결해 멀티머신 팀을 구성한다.

> *두레(dure): 조선시대 농민들이 각자의 논에서 마을 전체가 함께 경작하던 협동 시스템.*
> *DureClaw는 그 정신을 AI 에이전트에 담는다 — 각자의 머신에서, 하나의 목표로, 하나의 크루.*

[![GitHub](https://img.shields.io/badge/DureClaw-dureclaw-black?logo=github)](https://github.com/DureClaw/dureclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![npm](https://img.shields.io/badge/npm-%40dureclaw%2Fmcp-red?logo=npm)](https://www.npmjs.com/package/@dureclaw/mcp)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-io.github.dureclaw%2Fmcp-purple?logo=anthropic)](https://registry.modelcontextprotocol.io)
[![Smithery](https://img.shields.io/badge/Smithery-dureclaw%2Fmcp-blue)](https://smithery.ai/server/@dureclaw/mcp)

---

## 설치

### Step 1 — Claude Code에 플러그인 추가 (필수)

```shell
/plugin marketplace add DureClaw/dureclaw
```

```shell
/plugin install dureclaw@dureclaw
```

> 수동 등록: `oah setup-mcp` 또는 `curl -fsSL .../scripts/setup-mcp.sh | bash`

**여기까지만 해도 바로 사용 가능합니다.** Claude Code가 오케스트레이터 역할을 하며, 로컬에서 태스크를 직접 실행할 수 있습니다.

---

### Step 2+3 — 멀티머신 팀 확장 (선택)

다른 머신에 작업을 분산시키려면 아래 명령 하나로 자동 설정합니다:

```bash
oah setup-team
```

대화형 위저드가 자동으로:
1. Phoenix 서버 실행 여부 확인 → 없으면 설치
2. 원격 머신용 워커 에이전트 설치 명령 출력
3. 로컬에도 워커 추가 여부 선택

> 멀티머신 분산 처리가 필요할 때만 실행하세요.

---

## 아키텍처

```
Claude Code (오케스트레이터, 맥북)
  └─ packages/oah-mcp/         MCP 서버 → Phoenix WebSocket
       send_task / receive_task / get_presence / ...

Phoenix Channel (메시지 버스, Elixir)
  packages/phoenix-server/      ws://host:4000

oah-agent (워커, 각 머신)
  packages/agent-daemon/        WebSocket 연결 → task.assign 수신
  → AI 백엔드 실행 (claude / opencode / gemini / aider)
  → task.result 반환
```

---

## 패키지 구조

```
dureclaw/
├── .claude-plugin/             Claude Code 플러그인 메타데이터
│   ├── plugin.json
│   └── marketplace.json
│
├── .claude/
│   ├── commands/               슬래시 커맨드 (/setup-team, /team-status)
│   ├── agents/                 에이전트 정의 (orchestrator 등)
│   └── skills/dureclaw/        DureClaw 오케스트레이션 스킬
│
├── packages/
│   ├── phoenix-server/         Elixir/Phoenix 메시지 버스 (핵심)
│   ├── agent-daemon/           WebSocket 에이전트 데몬 (oah-agent)
│   ├── oah-mcp/                Claude Code MCP 서버 (@dureclaw/mcp)
│   └── ctl/                    oah-ctl 관리 CLI
│
└── scripts/
    ├── setup-server.sh         Phoenix 서버 설치
    ├── setup-agent.sh          워커 에이전트 설치 (oah 명령어)
    ├── setup-mcp.sh            Claude Code MCP 등록
    └── oah                     통합 CLI
```

---

## 사용법

플러그인 설치 후 Claude Code에서 바로 사용합니다:

```
# 팀 상태 확인
/team-status

# 멀티머신 팀 확장 (Phoenix 서버 + 워커 에이전트 자동 설정)
/setup-team

# 에이전트에게 태스크 전송
mcp__oah__send_task(to: "builder@mac-mini", instructions: "[SHELL] make build")

# 온라인 에이전트 목록
mcp__oah__get_presence
```

### 사용 가능한 MCP 도구

| 도구 | 설명 |
|------|------|
| `mcp__oah__get_presence` | 온라인 에이전트 목록 |
| `mcp__oah__send_task` | 에이전트에게 태스크 전송 |
| `mcp__oah__receive_task` | 태스크 수신 대기 (30초) |
| `mcp__oah__complete_task` | 태스크 완료 보고 |
| `mcp__oah__read_state` | Work Key 상태 조회 |
| `mcp__oah__write_state` | Work Key 상태 업데이트 |
| `mcp__oah__read_mailbox` | mailbox 읽기 |
| `mcp__oah__post_message` | mailbox 메시지 전송 |

### 구성도

```
Claude Code (오케스트레이터)
  │  MCP (oah-mcp)
  ▼
Phoenix Server              ws://host:4000
  │  Phoenix Channel
  ├──▶ oah-agent (맥미니)   builder@mac-mini
  ├──▶ oah-agent (GPU 서버) builder@gpu-server
  └──▶ oah-agent (라즈파이)  executor@raspi
          └─ AI 백엔드 실행 → task.result 반환
```

---

## REST API

| Method | Endpoint | 설명 |
|--------|----------|------|
| GET | `/api/health` | 서버 상태 |
| GET | `/api/presence` | 연결된 에이전트 목록 |
| GET | `/api/work-keys` | Work Key 목록 |
| GET | `/api/work-keys/latest` | 최신 Work Key |
| POST | `/api/work-keys` | 새 Work Key 생성 |
| GET | `/api/state/:wk` | Work Key 상태 조회 |
| PATCH | `/api/state/:wk` | Work Key 상태 업데이트 |
| POST | `/api/task` | 태스크 디스패치 (Phoenix broadcast) |
| GET | `/api/task/:id` | 태스크 결과 폴링 |
| POST | `/api/task/:id/result` | 태스크 결과 제출 |
| GET | `/api/mailbox/:agent` | 에이전트 mailbox 읽기 |
| POST | `/api/mailbox/:agent` | 에이전트 mailbox 메시지 전송 |

---

---

## 요구사항

| 컴포넌트 | 요구사항 |
|----------|----------|
| 오케스트레이터 (Claude Code) | Claude Code CLI, Bun ≥ 1.0 |
| Phoenix 서버 | Elixir ≥ 1.14, OTP ≥ 25 |
| 워커 에이전트 | Bun ≥ 1.0, AI CLI (claude / opencode / gemini 등) |

---

## 문서

| 문서 | 설명 |
|------|------|
| [docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md) | **개발 가이드** — 테스트, Phoenix Channel 프로토콜, PR 기여 방법 |
| [docs/PROTOCOL.md](./docs/PROTOCOL.md) | **프로토콜 명세** — 4계층 통신 프로토콜 공식 정의 (L1 네트워크 ~ L4 팀 프로토콜) |
| [docs/PRIVATE_NETWORK.md](./docs/PRIVATE_NETWORK.md) | **사설망 구성** — Tailscale로 원격 에이전트를 하나의 팀으로 연결하는 방법 |
| [docs/REMOTE_AGENT_OPS.md](./docs/REMOTE_AGENT_OPS.md) | **원격 에이전트 운영** — 원격지 에이전트를 실시간 진단·명령·복구하는 방법 |
| [docs/AGENTS.md](./docs/AGENTS.md) | 에이전트 역할 정의 |
| [docs/METHODOLOGY.md](./docs/METHODOLOGY.md) | 워크루프 방법론 |
| [docs/GAP_ANALYSIS.md](./docs/GAP_ANALYSIS.md) | 현재 상태 및 개선 방향 |
| [docs/INSTALL.md](./docs/INSTALL.md) | 설치 가이드 |
| [docs/ECOSYSTEM_ANALYSIS.md](./docs/ECOSYSTEM_ANALYSIS.md) | 에코시스템 분석 (ClawFit, 경쟁 도구 비교) |

---

## License

MIT © 2025-2026 [Seungwoo Hong (홍승우)](https://github.com/hongsw)

자세한 내용은 [LICENSE](./LICENSE) 파일을 참조하세요.
