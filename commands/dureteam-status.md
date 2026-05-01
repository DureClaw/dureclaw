DureClaw 두레팀 현재 상태를 확인합니다.

먼저 Phoenix 서버 상태를 확인하고, **서버가 꺼져 있으면 실행 명령을 안내한 뒤 종료합니다**.
서버가 떠 있을 때만 presence/work-key 정보를 조회하세요.

---

**Step 1: 서버 상태 확인**

```bash
curl -sf http://localhost:4000/api/health > /dev/null && echo "RUNNING" || echo "NOT_RUNNING"
```

---

**Step 2: NOT_RUNNING이면 — 실행 안내만 출력하고 종료**

사용자에게 그대로 보여주세요:

```
❌ Phoenix 서버 미실행 (http://localhost:4000)

새 터미널 / 별도 창에서 다음 한 줄을 실행하면 두레팀 서버가 시작됩니다:

  bash <(curl -fsSL https://dureclaw.baryon.ai/server)

옵션:
  PORT=8080 bash <(curl -fsSL https://dureclaw.baryon.ai/server)         # 포트 변경
  USE_DOCKER=1 bash <(curl -fsSL https://dureclaw.baryon.ai/server)      # Elixir 없이 Docker 강제
  docker compose up                                                       # 레포 클론으로 실행

서버는 포그라운드(blocking)로 실행됩니다 — 별도 탭/창에 띄워 두세요.
서버가 뜨면 다시 /dureteam-status 또는 "두레팀 상태 알려줘" 라고 입력하세요.
```

여기서 멈춥니다 — Step 3·4는 실행하지 마세요.

---

**Step 3: RUNNING이면 — 두레팀 현황 출력**

```bash
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'━━━ DureClaw 두레팀 현황 ━━━━━━━━━━━━━━━━━━')
print(f'온라인 에이전트: {len(agents)}명')
for a in agents:
    caps = ', '.join(a.get('capabilities', []))
    print(f'  ✅ {a.get(\"name\")} [{a.get(\"role\")}] {caps}')
if not agents:
    print('  (연결된 에이전트 없음)')
    print()
    print('  워커 추가: /setup-team 또는 \"두레팀에 워커 추가\"')
"
```

---

**Step 4: 활성 Work Key 확인**

```bash
curl -sf http://localhost:4000/api/work-keys/latest | python3 -m json.tool 2>/dev/null || echo "활성 Work Key 없음"
```
