# DureClaw Private Network — Tailscale 사설망 구성

인터넷 어디에 있어도 에이전트들을 하나의 팀으로 연결하는 방법입니다.

---

## 개념: 가상 사설망 위의 팀

```
인터넷 (공용망)
─────────────────────────────────────────────────────────────────
           │                    │                    │
    ┌──────┴──────┐      ┌──────┴──────┐      ┌──────┴──────┐
    │  집 Mac Mini│      │  카페 노트북 │      │ 회사 Ubuntu │
    │  (서버+오케) │      │  (builder)  │      │  (tester)   │
    │ 100.64.0.1  │◄────►│ 100.64.0.2  │◄────►│ 100.64.0.3  │
    └─────────────┘      └─────────────┘      └─────────────┘
          │                    │                    │
─────────────────────────────────────────────────────────────────
              Tailscale 가상 사설망 (WireGuard 기반)
              모든 머신이 마치 같은 LAN에 있는 것처럼 통신
```

**핵심**: Tailscale은 포트포워딩 없이, 방화벽을 넘어,
어디서든 안전한 P2P 암호화 터널을 만듭니다.

---

## 1단계: Tailscale 계정 & 설치

### 계정 생성
→ https://tailscale.com 에서 무료 계정 (개인: 100대 무료)

### 각 머신에 설치

```bash
# macOS
brew install tailscale
sudo tailscaled &
tailscale up

# Linux (Ubuntu/Debian)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Raspberry Pi
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Windows
# https://tailscale.com/download/windows 에서 설치 후 로그인
```

### 연결 확인

```bash
# 내 Tailscale IP 확인
tailscale ip -4
# 예: 100.64.0.1

# Tailscale 이름 확인 (DNS 주소)
tailscale status
# mac-mini  100.64.0.1  active
# raspi-4   100.64.0.2  active
# ubuntu-server 100.64.0.3  active
```

---

## 2단계: Phoenix 서버 시작 (한 머신에서만)

```bash
# 서버 머신에서 실행
bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-server.sh)
```

서버 시작 시 자동으로 주소를 안내합니다:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 서버 시작! 에이전트 접속 명령:
  [Tailscale]  PHOENIX=ws://100.64.0.1:4000 bash <(curl -fsSL ...)
  [LAN]        PHOENIX=ws://192.168.1.10:4000 bash <(curl -fsSL ...)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Tailscale 주소를 사용하세요** — IP가 바뀌지 않고, 어디서든 접속 가능.

---

## 3단계: 에이전트 연결 (각 원격 머신에서)

```bash
# Tailscale IP로 서버 지정 (각 원격 머신에서)
PHOENIX=ws://100.64.0.1:4000 ROLE=builder \
  bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)
```

### 자동 서버 탐색 (추천)

Tailscale이 설치되어 있으면 서버를 **자동으로 찾아줍니다**:

```bash
# PHOENIX 없이 실행 → Tailscale 피어 목록 TUI 표시
bash <(curl -fsSL https://open-agent-harness.baryon.ai/setup-agent.sh)
```

```
  OAH  Connect to Server
  ──────────────────────────────────────
  > mac-mini  [100.64.0.1]
    ubuntu-server  [100.64.0.3]

  [↑/↓] select   [Enter] connect   [q] quit
```

화살표로 서버를 선택하면 자동 연결됩니다.

---

## 4단계: 팀 확인

서버 머신에서 온라인 에이전트 확인:

```bash
curl -s http://localhost:4000/api/presence | jq '.'
```

또는 대시보드: http://localhost:4000

---

## 구성 예시

### 소규모 팀 (2대)

```
[내 Mac] Phoenix 서버 + Claude Code 오케스트레이터
    │
    └── [Mac Mini] builder 에이전트 (Tailscale: 100.64.0.2)
```

### 크로스 플랫폼 빌드 팀

```
[Mac Mini] Phoenix 서버 + 오케스트레이터
    ├── [Mac Mini] macOS builder       (Tailscale: 100.64.0.1)
    ├── [Ubuntu 서버] Linux builder    (Tailscale: 100.64.0.2)
    ├── [Windows PC] Windows builder   (Tailscale: 100.64.0.3)
    └── [Raspberry Pi] ARM tester      (Tailscale: 100.64.0.4)
```

### 실제 명령어 (Windows 에이전트)

```powershell
# PowerShell
$env:PHOENIX = "ws://100.64.0.1:4000"
$env:ROLE = "builder"
iex (iwr http://100.64.0.1:4000/setup.ps1).Content
```

---

## Tailscale 없이도 동작하는가?

| 상황 | 방법 |
|------|------|
| 같은 LAN | `PHOENIX=ws://192.168.x.x:4000` 직접 지정 |
| 포트포워딩 가능 | 공인 IP로 접속 (보안 주의) |
| Tailscale (권장) | 어디서든 안전하게 자동 연결 |
| ZeroTier | Tailscale 대안 (동일 개념) |
| Netbird | 오픈소스 자가 호스팅 가능 |

---

## 보안

- Tailscale = WireGuard 기반 E2E 암호화
- Tailnet 내부 머신끼리만 통신
- 공인 IP / 포트 노출 없음
- 추가 인증 필요 시: Phoenix 서버에 `SECRET_KEY_BASE` + JWT 설정

```bash
# 프로덕션 보안 설정
SECRET_KEY_BASE=$(openssl rand -hex 64) \
  PORT=4000 bash <(curl -fsSL .../setup-server.sh)
```
