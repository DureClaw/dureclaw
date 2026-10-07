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

---

## 자체 사설망 — Tailscale 계정 없이 (Headscale, 오픈소스)

공식 Tailscale 계정·외부 서비스를 쓸 수 없는 사내망·전용망에서는, DureClaw 서버가 **오픈소스 제어 서버 Headscale**을 직접 운영합니다. 노드는 공식 Tailscale 클라이언트(오픈소스)를 그대로 쓰고 접속할 제어 서버만 바꿉니다. 주소 대역은 같은 `100.64.0.0/10`이라 **키 없는 자동 승인도 그대로** 동작합니다.

### 서버

```bash
# Linux 서버 — 사내망 모드 (HTTP, 노드끼리 직접 연결, 외부 의존 0)
MESH=1 bash <(curl -fsSL https://dureclaw.baryon.ai/server)
#   MESH_URL=http://10.0.0.5:8080     제어 서버 주소 지정 (기본: 이 서버의 LAN IP:8080)
#   MESH_PUBLIC_DERP=1                인터넷 허용 시 Tailscale 공개 중계 추가 (NAT 너머 연결)
#   MESH_DOMAIN=mesh.example.com MESH_EMAIL=ops@example.com
#                                     지점 간 모드 (HTTPS 자동 인증서 + 내장 중계, 443 · 3478/UDP 개방)
#   MESH_FORCE=1                      서버가 이미 다른 Tailscale 망에 있어도 자체 망으로 옮김

# Docker — headscale + 서버 다리(공식 Tailscale 컨테이너) + 서버
MESH_URL=http://<서버 LAN IP>:8080 scripts/mesh-docker.sh up
scripts/mesh-docker.sh code      # 새 노드 연결 코드
scripts/mesh-docker.sh nodes     # 합류한 노드
```

설치가 끝나면 **노드 연결 코드**(`dcj1:…`)가 출력됩니다. 코드에는 제어 서버 주소, 유효기간이 있는 가입 키, 버스 주소가 들어 있습니다.
새 코드는 `bash ~/.dureclaw/mesh/mesh.sh join-code --bus ws://<서버 사설망 IP>:4000 [--ttl 1h] [--reusable]`로 발급합니다.

### 노드

```bash
JOIN=dcj1:… bash <(curl -fsSL https://dureclaw.baryon.ai/agent)
```

이 명령은 다음을 차례로 처리합니다: Tailscale 클라이언트 설치(없으면) → 자체 망 합류 → 코드에 든 버스 주소로 에이전트 접속 → 키 없이 자동 승인.
이 컴퓨터가 이미 다른 Tailscale 망(예: 공식 계정)에 연결돼 있으면 덮어쓰지 않고 멈춥니다. 옮기려면 `MESH_FORCE=1`을 붙이세요(기존 망 연결이 끊깁니다).

### 검증 범위와 주의

- **CI에서 자동 검증**(`.github/workflows/e2e.yml`의 `mesh`, `mesh-docker` 잡)
  - 서버 자기 합류 → 다른 기기 역할의 컨테이너가 코드로 합류 → 사설망 주소로 작업 실행 → 사설망 주소에서 키리스 자동 승인
  - 외부 중계 없이 직접 연결
  - 실제 설치 명령(`JOIN=… setup-agent.sh`) 경로 포함
- **아직 검증하지 않음**
  - 지점 간(HTTPS·도메인) 모드
  - Mac 서버 앱·Windows 노드
  - 실제 다지점 NAT 환경
- **사내망 모드의 연결 조건**: 중계가 없으므로 노드와 서버가 UDP로 서로 직접 닿아야 합니다. 방화벽이 막혀 있으면 `MESH_PUBLIC_DERP=1` 또는 지점 간 모드를 쓰세요.
