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

---

**Step 5: 가입 대기(pending) 노드 확인 — 승인 대기 중인 첫 접속**

인증 토큰이 필요합니다(`$OAH_SECRET` 또는 서버의 `data/server.secret`). tailnet 밖에서 온 새 노드가 여기 뜹니다.

```bash
SEC="${OAH_SECRET:-$(cat packages/phoenix-server/data/server.secret 2>/dev/null)}"
curl -sf -H "Authorization: Bearer $SEC" "http://localhost:4000/api/enrollments?status=pending" 2>/dev/null | python3 -c "
import sys, json
try: data = json.load(sys.stdin)
except Exception: print('가입 대기 조회 실패(토큰 확인)'); raise SystemExit
ens = data.get('enrollments', [])
if not ens:
    print('가입 대기 노드 없음 (tailnet 피어는 자동 승인됨)')
else:
    print(f'🔑 가입 대기: {len(ens)}개 — 승인하면 토큰이 발급됩니다')
    for e in ens:
        caps = ', '.join(e.get('capabilities', [])[:4])
        print(f\"  ⏳ {e.get('name')} [{e.get('role')}] {e.get('machine')} · {e.get('source_ip','')} · caps: {caps}\")
        print(f\"     승인: curl -H \\\"Authorization: Bearer \$SEC\\\" -X POST http://localhost:4000/api/join/{e.get('enroll_id')}/approve\")
"
```

> tailnet(100.x)·로컬 피어는 **자동 승인**되어 여기 나타나지 않습니다. 대시보드(`http://서버:4000/`)의 "🔑 가입 대기" 패널에서 버튼으로 승인/거부할 수도 있습니다.
