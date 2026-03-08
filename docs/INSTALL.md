# 머신별 설치 가이드

다른 머신에 open-agent-harness를 설치하는 방법. 역할에 따라 설치 내용이 다르다.

---

## 역할 구분

| 역할 | 설치 내용 | 권장 머신 |
|------|-----------|-----------|
| **Phoenix 서버** | Elixir + phoenix-server | NAS (24/7 가동) |
| **Agent 머신** | Bun + OpenCode + agent-daemon | Mac / Linux PC / WSL2 |

> Tailscale이 없으면 같은 LAN 내에서도 동작한다 (사설 IP 직접 사용).

---

## 1. Phoenix 서버 설치 (NAS / 서버)

### 1-A. Synology NAS

```bash
# 1. SSH 활성화: DSM → 제어판 → 터미널 및 SNMP → SSH 서비스 활성화
ssh admin@<nas-ip>

# 2. asdf (버전 관리자) 설치
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc && source ~/.bashrc

# 3. Erlang + Elixir 설치 (Synology은 빌드 도구 필요)
sudo apt-get install -y build-essential autoconf m4 libncurses5-dev \
  libwxwidgets-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev \
  libssh-dev unixodbc-dev  # Synology은 패키지 매니저 다를 수 있음

asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 26.2.5
asdf install elixir 1.16.3-otp-26
asdf global erlang 26.2.5
asdf global elixir 1.16.3-otp-26

# 4. 코드 복사 (git clone 또는 NFS 공유)
git clone <repo-url> ~/open-agent-harness
cd ~/open-agent-harness/packages/phoenix-server

# 5. 의존성 설치
mix local.hex --force
mix local.rebar --force
mix deps.get

# 6. 서버 시작 (포트 4000)
PORT=4000 mix phx.server
```

**백그라운드 실행 (재부팅 시 자동 시작):**
```bash
# systemd 없으면 /etc/rc.local 또는 DSM 작업 스케줄러 사용
nohup sh -c 'cd ~/open-agent-harness/packages/phoenix-server && PORT=4000 mix phx.server' \
  > ~/phoenix-server.log 2>&1 &
echo $! > ~/phoenix-server.pid
```

### 1-B. QNAP NAS

```bash
# QNAP은 Container Station (Docker)이 더 편리
ssh admin@<nas-ip>

# Docker가 설치되어 있으면:
docker run -d \
  --name harness-phoenix \
  --restart unless-stopped \
  -p 4000:4000 \
  -e SECRET_KEY_BASE=<64자_이상_랜덤_문자열> \
  -v /share/harness:/app \
  hexpm/elixir:1.16.3-erlang-26.2.5-alpine-3.19.0 \
  sh -c "cd /app/packages/phoenix-server && mix local.hex --force && mix deps.get && mix phx.server"
```

> 더 간단한 방법: **Linux 서버 (1-C)** 방식으로 Docker 없이 직접 설치

### 1-C. Ubuntu / Debian Linux 서버

```bash
# 1. Erlang + Elixir 설치
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update
sudo apt-get install -y esl-erlang elixir

# 버전 확인
elixir --version  # Elixir 1.15+ 필요

# 2. 코드 가져오기
git clone <repo-url> ~/open-agent-harness
cd ~/open-agent-harness/packages/phoenix-server
mix local.hex --force && mix deps.get

# 3. systemd 서비스 등록
sudo tee /etc/systemd/system/harness-phoenix.service << 'EOF'
[Unit]
Description=open-agent-harness Phoenix Server
After=network.target

[Service]
Type=simple
User=<your-user>
WorkingDirectory=/home/<your-user>/open-agent-harness/packages/phoenix-server
Environment=PORT=4000
Environment=MIX_ENV=dev
ExecStart=/usr/bin/mix phx.server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable harness-phoenix
sudo systemctl start harness-phoenix

# 상태 확인
curl http://localhost:4000/api/health
```

---

## 2. Agent 머신 설치 (Mac / Linux / WSL2)

각 머신은 agent-daemon만 실행하면 된다. Phoenix 서버는 필요 없다.

### 2-A. Mac (다른 대)

```bash
# 1. Bun 설치 (없으면)
curl -fsSL https://bun.sh/install | bash
source ~/.zshrc

# 2. OpenCode 설치 (없으면)
curl -fsSL https://opencode.ai/install | bash

# 3. 코드 복사
# 방법 A: git clone
git clone <repo-url> ~/open-agent-harness

# 방법 B: rsync (메인 Mac에서 복사)
rsync -av --exclude='.git' --exclude='node_modules' --exclude '_build' \
  /path/to/open-agent-harness/ user@other-mac:~/open-agent-harness/

cd ~/open-agent-harness/packages/agent-daemon
bun install

# 4. 실행
STATE_SERVER=ws://<phoenix-server-ip>:4000 \
AGENT_NAME=builder@mac2 \
AGENT_ROLE=builder \
WORK_KEY=<work-key> \
PROJECT_DIR=~/myproject \
bun run src/index.ts
```

### 2-B. Linux PC / GPU 서버 (Ubuntu)

```bash
# 1. Bun 설치
curl -fsSL https://bun.sh/install | bash
source ~/.bashrc

# 2. OpenCode 설치
curl -fsSL https://opencode.ai/install | bash

# 3. 코드 복사
git clone <repo-url> ~/open-agent-harness
cd ~/open-agent-harness/packages/agent-daemon && bun install

# 4. 실행 스크립트 작성 (편의용)
cat > ~/start-builder.sh << 'EOF'
#!/bin/bash
STATE_SERVER=ws://100.x.x.x:4000 \
AGENT_NAME=builder@gpu \
AGENT_ROLE=builder \
WORK_KEY=${1:-$(curl -s -X POST http://100.x.x.x:4000/api/work-keys | python3 -c "import sys,json; print(json.load(sys.stdin)['work_key'])")} \
PROJECT_DIR=${2:-$(pwd)} \
bun run ~/open-agent-harness/packages/agent-daemon/src/index.ts
EOF
chmod +x ~/start-builder.sh

# 실행
~/start-builder.sh LN-20260308-001 /path/to/project
```

### 2-C. Windows (WSL2)

```bash
# WSL2 Ubuntu 터미널에서 실행

# 1. Bun 설치
curl -fsSL https://bun.sh/install | bash
source ~/.bashrc

# 2. OpenCode 설치
curl -fsSL https://opencode.ai/install | bash

# 3. 코드 복사
git clone <repo-url> ~/open-agent-harness
cd ~/open-agent-harness/packages/agent-daemon && bun install

# 4. Phoenix 서버 주소 (WSL2에서 Windows 호스트 IP)
PHOENIX_IP=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}')
# 또는 Tailscale IP 직접 사용

# 5. 실행
STATE_SERVER=ws://${PHOENIX_IP}:4000 \
AGENT_NAME=builder@windows \
AGENT_ROLE=builder \
WORK_KEY=LN-20260308-001 \
PROJECT_DIR=/mnt/c/Users/<user>/myproject \
bun run src/index.ts
```

---

## 3. Tailscale 설정 (선택 — 외부 네트워크 연결 시)

같은 LAN이면 사설 IP로 충분하다. 외부 네트워크(카페, VPN 없는 원격)라면 Tailscale을 사용한다.

```bash
# 각 머신에서 (Mac/Linux 동일)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# IP 확인
tailscale ip -4
# → 100.x.x.x (이 IP를 STATE_SERVER에 사용)
```

Phoenix 서버 IP 예시:
```bash
STATE_SERVER=ws://100.64.0.1:4000  # Tailscale IP
```

---

## 4. 전체 연결 확인

```bash
# Phoenix 서버 상태
curl http://<phoenix-ip>:4000/api/health
# → {"ok":true,"work_keys":0}

# Work Key 발급
curl -X POST http://<phoenix-ip>:4000/api/work-keys
# → {"work_key":"LN-20260308-001"}

# 현재 접속 에이전트 확인
curl http://<phoenix-ip>:4000/api/presence
# → {"agents":[{"name":"builder@gpu","role":"builder",...}]}
```

---

## 5. 빠른 시작 요약

### Phoenix 서버 (NAS / 서버, 한 번만)
```bash
cd open-agent-harness/packages/phoenix-server
mix deps.get && PORT=4000 mix phx.server
```

### 각 Agent 머신 (매 세션)
```bash
# Work Key 발급 (orchestrator 역할 머신에서만)
WK=$(curl -s -X POST http://<server>:4000/api/work-keys | python3 -c "import sys,json;print(json.load(sys.stdin)['work_key'])")

# 에이전트 시작
STATE_SERVER=ws://<server>:4000 \
AGENT_NAME=<role>@<machine> \
AGENT_ROLE=<role> \
WORK_KEY=$WK \
PROJECT_DIR=/path/to/project \
bun run open-agent-harness/packages/agent-daemon/src/index.ts
```

`<role>`: `orchestrator` | `builder` | `verifier` | `reviewer`
`<machine>`: 머신 식별자 (예: `mac`, `gpu`, `nas`)
