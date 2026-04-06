DureClaw 멀티머신 팀을 자동으로 설정합니다. 아래 순서대로 실행하세요.

## Step 1 — Phoenix 서버 상태 확인

먼저 Phoenix 서버가 실행 중인지 확인합니다:

```bash
curl -sf http://localhost:4000/api/health || echo "NOT_RUNNING"
```

**서버가 실행 중이면** → Step 2로 이동
**서버가 없으면** → 아래 명령으로 설치:

```bash
curl -fsSL https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-server.sh | bash
```

설치 후 서버 주소를 확인합니다 (Tailscale IP 우선):

```bash
tailscale ip -4 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || hostname -I | awk '{print $1}'
```

## Step 2 — 온라인 에이전트 현황

현재 연결된 에이전트를 확인합니다:

```bash
curl -sf http://localhost:4000/api/presence | python3 -m json.tool
```

## Step 3 — 워커 에이전트 연결

원격 머신(맥미니, GPU 서버, 라즈파이 등)에서 실행할 명령을 출력합니다.

`<서버IP>`를 Step 1에서 확인한 실제 IP로 바꿔서 각 머신에 전달하세요:

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.sh \
  | PHOENIX=ws://<서버IP>:4000 ROLE=builder bash
```

**Windows (PowerShell):**
```powershell
$env:PHOENIX="ws://<서버IP>:4000"; $env:ROLE="builder"
irm https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.ps1 | iex
```

역할(ROLE)은 상황에 맞게 변경하세요: `builder` / `tester` / `analyst` / `executor`

## Step 4 — 팀 확인

에이전트들이 연결되면 팀 상태를 확인합니다:

```bash
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'온라인 에이전트: {len(agents)}명')
for a in agents:
    print(f'  - {a.get(\"name\")} ({a.get(\"role\")})')
"
```

모든 에이전트가 연결되면 `mcp__oah__send_task` 로 태스크를 보낼 수 있습니다.
