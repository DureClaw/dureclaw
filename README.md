# DureClaw (두레클로)

<img src="https://github.com/user-attachments/assets/7ed690a2-92e8-4fbd-a0c8-510f6ee3944e" alt="DureClaw Logo" width="100%" />

분산된 디바이스의 AI 에이전트들이 하나의 채널로 묶여 실시간 협력하는 오케스트레이션 인프라.
Claude Code를 오케스트레이터로, 각 머신의 AI 에이전트들을 워커로 연결해 멀티머신 팀을 구성한다.

> *[두레(dure)](https://en.wikipedia.org/wiki/Dure): 조선시대 농민들이 각자의 논에서 마을 전체가 함께 경작하던 협동 시스템.*
> *DureClaw는 그 정신을 AI 에이전트에 담는다 — 각자의 머신에서, 하나의 목표로, 하나의 크루.*

🌐 **한국어** | **[English](./README.en.md)**

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

다른 머신에 작업을 분산시키려면 **Claude Code CLI 안에서** 명령어 또는 자연어로 실행합니다:

```
/setup-team
```

또는 **자연어로도 동일하게 실행** 가능합니다:

```
"팀 설정해줘"   "워커 추가해줘"   "setup team"
```

자동으로 실행되는 순서:
1. Phoenix 서버 상태 확인 → 없으면 설치 (**Elixir 불필요 — Docker 또는 사전빌드 바이너리**)
2. 서버 IP 감지 (Tailscale 우선)
3. 현재 온라인 에이전트 목록 출력
4. 원격 머신용 워커 설치 명령 출력 (macOS/Linux/Windows)

```
/team-status   ← 팀 현황 확인 (또는 "팀 상태 알려줘", "온라인 에이전트 몇 명이야")
```

> Phoenix 서버는 **Docker만 있으면 Elixir 없이 바로 실행**됩니다.
> `USE_DOCKER=1 bash <(curl -fsSL .../setup-server.sh)` 또는 `docker compose up`

> 멀티머신 분산 처리가 필요할 때만 실행하세요.

---

### Step 4 — 워커 에이전트 설치 (각 원격 머신)

**Claude Code에게 말하면 직접 안내해 줍니다.**

```
"워커 추가해줘"   "tester 머신 연결하고 싶어"   "팀에 Mac Mini 추가해줘"
```

Claude가 서버 IP를 자동으로 감지해 **바로 복사·실행 가능한 명령어**를 머신별로 알려줍니다.
Tailscale이 없어도 설치까지 단계별로 안내합니다.

---

## 아키텍처

```
① Claude Code (오케스트레이터, 맥북)
     /plugin install dureclaw@dureclaw
   └─ MCP (oah-mcp) → Phoenix WebSocket

② Phoenix Server (메시지 버스)
     bash <(curl -fsSL .../setup-server.sh)   ← Docker 또는 사전빌드 바이너리
   ws://host:4000

③ oah-agent (워커, 각 머신)
     PHOENIX=ws://host:4000 ROLE=builder bash <(curl -fsSL .../setup-agent.sh)
   → WebSocket 연결 → task.assign 수신
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

## 지원 환경

| 플랫폼 | 아키텍처 | 서버 | 워커 | 비고 |
|--------|----------|------|------|------|
| macOS (Apple Silicon) | arm64 | ✅ 사전빌드 | ✅ | M1/M2/M3/M4 |
| macOS (Intel) | x86_64 | ✅ 사전빌드 | ✅ | |
| Linux | x86_64 | ✅ 사전빌드 | ✅ | Ubuntu/Debian/CentOS |
| **Raspberry Pi 4/5** | **arm64** | ✅ 사전빌드 | ✅ | **executor 역할 최적** |
| **Raspberry Pi Zero W/2W** | **armv6/arm64** | ❌ | ✅ JS 번들 | **WiFi 내장 · IoT executor** |
| Windows 10/11 | x86_64 | 🐳 Docker | ✅ PowerShell | |
| Docker (모든 플랫폼) | any | ✅ | — | `ghcr.io/dureclaw/dureclaw` |

> **Raspberry Pi**: `PHOENIX=ws://서버IP:4000 ROLE=executor bash <(curl -fsSL https://dureclaw.baryon.ai/agent)` 한 줄로 연결.

---

## 선행 설치 조건

| | 필요한 것 | 설치 |
|--|----------|------|
| **필수** | [Claude Code CLI](https://claude.ai/download) | 오케스트레이터 |
| **멀티머신** | [Tailscale](https://tailscale.com/download) | 원격 머신 간 사설망 (무료, 100대) |

나머지(Phoenix 서버, oah-agent)는 **사전빌드 바이너리를 자동 다운로드**하므로 별도 설치가 필요 없습니다.

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

## 활용사례

| 예제 | 설명 |
|------|------|
| [fix-agent](./examples/fix-agent/) | 여러 AI 에이전트가 협력해 레포지토리 버그를 자동 분석·수정·PR 생성 |

```
Claude Code → analyzer-agent (버그 탐지)
           → fixer-agent    (코드 수정)
           → tester-agent   (검증 + PR 생성)
```

---

## License

MIT © 2025-2026 [Seungwoo Hong (홍승우)](https://github.com/hongsw)

자세한 내용은 [LICENSE](./LICENSE) 파일을 참조하세요.
