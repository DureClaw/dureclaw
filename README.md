# DureClaw (두레클로)

<img src="https://github.com/user-attachments/assets/7ed690a2-92e8-4fbd-a0c8-510f6ee3944e" alt="DureClaw Logo" width="100%" />

분산된 디바이스의 AI 에이전트들이 하나의 채널로 묶여 실시간 협력하는 오케스트레이션 인프라.
Claude Code를 오케스트레이터로, 각 머신의 AI 에이전트들을 워커로 연결해 멀티머신 팀을 구성한다.

> *[두레(dure)](https://en.wikipedia.org/wiki/Dure): 조선시대 농민들이 각자의 논에서 마을 전체가 함께 경작하던 협동 시스템.*
> *DureClaw는 그 정신을 AI 에이전트에 담는다 — 각자의 머신에서, 하나의 목표로, 하나의 크루.*

🌐 **한국어** | **[English](./README.en.md)** | **[中文](./README.zh.md)** | **[日本語](./README.ja.md)**

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

`get_presence` · `send_task` · `receive_task` · `complete_task` · `read_state` · `write_state` · `read_mailbox` · `post_message`

> 전체 도구 명세 → [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

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

주요 엔드포인트: `/api/health` · `/api/presence` · `/api/work-keys` · `/api/state/:wk` · `/api/task` · `/api/mailbox/:agent`

> 전체 API 명세 및 Phoenix Channel 프로토콜 → [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

---

---

## 스크린샷

### 플랫폼별 설치 & 연결

| 플랫폼 | 설치 출력 |
|--------|----------|
| macOS Apple Silicon | `✅ darwin-arm64 바이너리 다운로드 완료` → `→ 서버 시작 · ws://100.x.x.x:4000` |
| Linux x86_64 (GPU 서버) | `✅ linux-x86_64 에이전트 설치 완료` → `✅ claude-cli 감지됨` → `→ builder@gpu-server 연결 완료` |
| Raspberry Pi 4/5 | `✅ linux-arm64 에이전트 설치 완료` → `✅ opencode 감지됨` → `→ executor@raspberrypi 연결 완료` |
| Raspberry Pi Zero W | `✅ Python 에이전트 모드 (armv6)` → `⚠ aider 경량 모드` → `→ executor@zero-w 연결 완료 (WiFi)` |
| Windows (PowerShell) | `✅ opencode npm 설치 완료` → `→ builder@DESKTOP-WIN 연결 완료` |

### 에이전트 역할별

| Role | AI 백엔드 | 실행 예시 |
|------|----------|---------|
| `builder` | claude-cli / opencode / codex | `[SHELL] make build` → 코드 작성·빌드 |
| `tester` | claude-cli / aider | `[SHELL] pytest tests/` → 테스트 실행·검증 |
| `analyst` | claude-cli / gemini | 코드 분석·리뷰·버그 탐지 |
| `executor` | aider / opencode | 경량 명령 실행 · RPi Zero W 최적 |

### 대시보드

> 실시간 에이전트 현황 및 태스크 모니터링: `http://서버IP:4000/`

**태스크 디스패치 & 멀티 에이전트 현황 (6개 디바이스 동시 연결)**

![DureClaw 대시보드 — 태스크 디스패치](./docs/screenshots/02-task-dispatch.png)

**에이전트 상세 — 각 머신의 capability 실시간 확인**

![DureClaw 대시보드 — 에이전트 상세](./docs/screenshots/03-agent-presence.png)

---

## 지원 환경

| 플랫폼 | 아키텍처 | 서버 | 워커 | 비고 |
|--------|----------|------|------|------|
| macOS (Apple Silicon) | arm64 | ✅ 사전빌드 | ✅ | M1/M2/M3/M4 |
| macOS (Intel) | x86_64 | ✅ 사전빌드 | ✅ | |
| Linux | x86_64 | ✅ 사전빌드 | ✅ | Ubuntu/Debian/CentOS |
| **Raspberry Pi 4/5** | **arm64** | ✅ 사전빌드 | ✅ | **executor 역할 최적** |
| **Raspberry Pi Zero W/2W** | **armv6/arm64** | ❌ | ✅ Python | **WiFi 내장 · IoT executor** |
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

## 왜 팀이 필요한가 — 이동성·권한·전용 소프트웨어의 한계를 조합으로 넘는다

현실의 컴퓨터는 각자 제약이 다르다.

| 제약 | 예시 | 단일 머신의 한계 |
|-----|------|----------------|
| **OS 전용 소프트웨어** | MS Office, Active X, iOS 빌드(Xcode) | Windows가 아니면 실행 불가 |
| **하드웨어 접근** | GPIO, 카메라, 센서 | RPi만 물리 세계에 연결됨 |
| **이동성** | 현장 점검, 야외 인터뷰 | 서버는 들고 나갈 수 없음 |
| **연산 자원** | GPU 추론, 대용량 빌드 | 노트북 배터리·발열 한계 |
| **네트워크 위치** | 로컬 WiFi, VPN, 공공망 | IP 차단·지역 제한 |
| **권한** | sudo, Admin, 사인 인증서 | 조직 정책으로 일부 머신만 허용 |

DureClaw는 이 제약들을 **팀의 역할 분담**으로 해결한다.

### 실제 팀 — 5가지 아키텍처, 1초 안에 협업

```
🌍 초이동형   executor@cmini01      Raspberry Pi Zero W (손바닥 크기)
               └─ GPIO · I2C · 카메라 · WiFi · zeroclaw AI
               └─ 어디든 배포 가능, 배터리 구동, 물리 세계 접점

💼 이동형     tester@NUCBOXG3       Windows 11 NucBox (가방 속 미니PC)
               └─ MS Office 전체 · WSL · Claude · Active X 사이트 접근

🏡 반고정형   builder@hongswui-Macmini   macOS arm64 · Apple M4
               └─ Xcode · Swift · iOS 빌드 · Apple Silicon 네이티브

              builder@macmini-intel      macOS x86_64 · i3-8100B
               └─ Flutter · fastlane · Whisper OCR · 멀티클라우드 CLI
               └─ AWS SAM · Azure · Heroku · Terraform · Tesseract

🏠 고정형     builder@martin-B650M-K    Linux x86_64 · RTX 4090
               └─ Docker · Kubernetes · GPU 추론 · 24시간 연산 서버
```

**헬스체크 결과: 5/5 동시 응답 — 0.61초**

### 제약의 조합이 만드는 시나리오

**① 현장 점검 AI** — 이동성 × 연산 자원
```
cmini01 (현장, 주머니)  → 카메라로 장비 촬영
RTX 4090 서버 (원격)   → GPU로 이상 감지 AI 분석
Windows NucBox (현장)  → Excel 보고서 자동 생성·출력
```
> 단일 노트북으로는 현장 이동 + GPU 추론 + Office 자동화를 동시에 할 수 없다.

**② 멀티플랫폼 앱 빌드** — OS 전용 소프트웨어 × 병렬 실행
```
macmini-intel    → Flutter iOS/Android 빌드 (macOS만 가능)
hongswui-M4      → Swift/Xcode 아카이브  (Apple Silicon 네이티브)
martin-B650M-K   → Docker Linux 이미지 + k8s 배포
NUCBOXG3         → Windows 인스톨러 생성·테스트
cmini01          → ARMv6 임베디드 바이너리 검증
```
> 5개 플랫폼 동시 빌드. 순차 실행 대비 **5× 속도**.

**③ IoT 모니터링** — 하드웨어 접근 × 상시 연산
```
cmini01 (어디서나)  → I2C 온습도 · PIR 움직임 · 카메라 스냅샷 (GPIO)
RTX 4090 서버      → 이상 패턴 AI 감지
macmini-intel      → 주간 Excel 대시보드 자동 생성
```
> GPIO를 가진 머신은 cmini01뿐. 연산 서버는 현장에 나갈 수 없다.

**④ 현장 인터뷰 → AI 자동 정리** — 이동성 × 전용 소프트웨어
```
NUCBOXG3 (현장)    → 인터뷰 녹음 (Windows 마이크)
macmini-intel (귀가 후) → Whisper로 음성→텍스트 전사
martin-B650M-K     → Claude로 인사이트 추출
macmini-intel      → Word/Keynote 보고서 자동 생성
```
> 인터뷰 후 보고서 완성: 수 시간 → **15분 자동 처리**

### 오픈소스만으로 구현

| 구성 요소 | 라이선스 | 역할 |
|---------|:-------:|------|
| Phoenix (Elixir) | MIT | 실시간 WebSocket 채널 |
| Claude Code CLI | 무료 | AI 오케스트레이터 |
| ZeroClaw | Apache 2.0 | ARMv6 경량 AI |
| OpenCode | MIT | 멀티모델 AI 에이전트 |
| Raspberry Pi OS | GPL | IoT 엣지 OS |

비싼 SaaS 없이, 내 네트워크 안의 유휴 머신들을 연결하는 것만으로 —
**Raspberry Pi Zero W부터 RTX 4090 서버까지 — 하나의 AI 협업 팀이 된다.**

---

## License

MIT © 2025-2026 [Seungwoo Hong (홍승우)](https://github.com/hongsw)

자세한 내용은 [LICENSE](./LICENSE) 파일을 참조하세요.
