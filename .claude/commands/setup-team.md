DureClaw 팀 설정을 대화형으로 안내합니다. 아래 단계를 **순서대로 실행하고 사용자에게 말을 걸며** 진행하세요.

---

**Step 1: 서버 상태 확인**

```bash
curl -sf http://localhost:4000/api/health && echo "RUNNING" || echo "NOT_RUNNING"
```

- `RUNNING` → Step 2로 바로 이동
- `NOT_RUNNING` → 사용자에게 "서버가 없네요. 지금 설치할게요!" 라고 말하고 아래 실행:

```bash
curl -fsSL https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-server.sh | bash &
sleep 8
curl -sf http://localhost:4000/api/health && echo "서버 시작 완료" || echo "서버 시작 중..."
```

---

**Step 2: 서버 IP 자동 감지**

```bash
TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "")
SERVER_IP="${TS_IP:-$LAN_IP}"
echo "SERVER_IP=$SERVER_IP"
echo "TS_IP=$TS_IP"
echo "LAN_IP=$LAN_IP"
```

결과에 따라 사용자에게 말하세요:
- Tailscale IP 있음 → "Tailscale 사설망이 감지됐어요. 원격 머신에서도 연결 가능합니다."
- LAN IP만 있음 → "같은 네트워크 안에서만 연결 가능해요. 다른 네트워크에서 연결하려면 Tailscale이 필요합니다."

---

**Step 3: 현재 팀 현황 파악**

```bash
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'현재 온라인: {len(agents)}명')
for a in agents:
    print(f'  {a.get(\"name\")} [{a.get(\"role\")}]')
"
```

현황을 사용자에게 알려주고, 워커를 더 추가할지 물어보세요:
- "현재 X명이 연결되어 있어요. 워커를 추가할 머신이 있나요?"

---

**Step 4: 워커 설치 명령어를 IP 채워서 안내**

Step 2에서 얻은 `SERVER_IP`를 사용해 실제 실행 가능한 명령어를 출력합니다:

```bash
SERVER_IP=$(tailscale ip -4 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
AGENT_URL="https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 워커 머신에서 복사·붙여넣기 하세요"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "[ macOS / Linux ]"
echo "  PHOENIX=ws://$SERVER_IP:4000 ROLE=builder \\"
echo "    bash <(curl -fsSL $AGENT_URL)"
echo ""
echo "[ Windows PowerShell ]"
echo "  \$env:PHOENIX='ws://$SERVER_IP:4000'; \$env:ROLE='builder'"
echo "  irm https://raw.githubusercontent.com/DureClaw/dureclaw/main/scripts/setup-agent.ps1 | iex"
echo ""
echo "[ ROLE 변경: builder / tester / analyst / executor ]"
echo "  PHOENIX=ws://$SERVER_IP:4000 ROLE=tester bash <(curl -fsSL $AGENT_URL)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

명령어 출력 후 사용자에게 말하세요:
> "위 명령어를 워커로 쓸 머신에서 실행하면 자동으로 연결됩니다. 실행했으면 알려주세요, 연결 확인해 드릴게요!"

---

**Step 5: 연결 확인 (사용자가 워커 설치 완료 후)**

사용자가 "실행했어", "됐어", "완료" 등 완료 신호를 보내면:

```bash
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'✅ 팀 완성: {len(agents)}명 온라인')
for a in agents:
    caps = ', '.join(a.get('capabilities', []))
    print(f'   {a.get(\"name\")} [{a.get(\"role\")}] {caps}')
"
```

결과를 보고 사용자에게 팀 구성 완료를 알려주세요.
추가 워커가 필요하면 Step 4로 돌아가 반복합니다.
