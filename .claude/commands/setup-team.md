DureClaw 멀티머신 팀을 지금 바로 설정합니다. 아래 단계를 순서대로 실행하세요.

**Step 1: Phoenix 서버 상태 확인**

다음 명령을 실행하고 결과를 확인하세요:

```bash
curl -sf http://localhost:4000/api/health && echo "RUNNING" || echo "NOT_RUNNING"
```

결과가 `NOT_RUNNING`이면 서버를 시작합니다 (Elixir 불필요 — Docker 또는 사전빌드 바이너리):

```bash
# Docker가 있으면 자동으로 Docker 사용 (권장)
curl -fsSL https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-server.sh | bash &

# 또는 docker compose 직접
# docker compose up -d
```

**Step 2: 서버 IP 확인**

```bash
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
SERVER_IP="${TAILSCALE_IP:-$LOCAL_IP}"
echo "서버 주소: ws://$SERVER_IP:4000"
```

**Step 3: 현재 온라인 에이전트 확인**

```bash
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'온라인 에이전트: {len(agents)}명')
for a in agents:
    print(f'  ✅ {a.get(\"name\")} [{a.get(\"role\")}]')
if not agents:
    print('  (없음 — 아래 명령으로 워커를 연결하세요)')
"
```

**Step 4: 워커 에이전트 연결 명령 출력**

Step 2에서 확인한 SERVER_IP를 사용해 각 원격 머신에서 실행할 명령을 출력합니다:

```bash
SERVER_IP=$(tailscale ip -4 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || echo "localhost")
echo ""
echo "━━━ 원격 머신에서 실행할 명령 ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "macOS / Linux:"
echo "  curl -fsSL https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.sh \\"
echo "    | PHOENIX=ws://$SERVER_IP:4000 ROLE=builder bash"
echo ""
echo "Windows (PowerShell):"
echo "  \$env:PHOENIX='ws://$SERVER_IP:4000'; \$env:ROLE='builder'"
echo "  irm https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.ps1 | iex"
echo ""
echo "역할 변경: ROLE=builder / tester / analyst / executor"
```

모든 단계가 완료되면 `/team-status`로 팀 상태를 확인하세요.
