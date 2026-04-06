DureClaw 팀 현재 상태를 한눈에 확인합니다.

```bash
curl -sf http://localhost:4000/api/health | python3 -m json.tool
```

```bash
curl -sf http://localhost:4000/api/presence | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data.get('agents', [])
print(f'━━━ DureClaw 팀 현황 ━━━━━━━━━━━━━━━━━━')
print(f'온라인 에이전트: {len(agents)}명')
for a in agents:
    caps = ', '.join(a.get('capabilities', []))
    print(f'  ✅ {a.get(\"name\")} [{a.get(\"role\")}] {caps}')
if not agents:
    print('  (연결된 에이전트 없음)')
    print()
    print('  에이전트 추가: /setup-team')
"
```

```bash
curl -sf http://localhost:4000/api/work-keys/latest | python3 -m json.tool 2>/dev/null || echo "활성 Work Key 없음"
```
