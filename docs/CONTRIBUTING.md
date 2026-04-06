# DureClaw 개발 가이드 (Contributing)

개발, 테스트, 기여에 필요한 정보입니다.

---

## 개발 환경 설정

```bash
git clone https://github.com/DureClaw/dureclaw
cd dureclaw

# Phoenix 서버
cd packages/phoenix-server && mix deps.get

# TypeScript (MCP, agent-daemon)
bun install
```

---

## 테스트 가이드

### 1. 서버 상태 확인

```bash
cd packages/phoenix-server && mix phx.server

curl http://localhost:4000/api/health
# → {"ok":true}
```

### 2. 에이전트 연결 확인

```bash
curl http://localhost:4000/api/presence
# → {"agents":[{"name":"builder@mac","role":"builder",...}]}
```

### 3. 태스크 전송 테스트 (curl)

```bash
curl -s -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{"instructions":"[SHELL] echo hello", "to":"builder@mymachine"}' \
  | python3 -m json.tool
# → {"task_id":"http-...","work_key":"LN-..."}
```

### 4. 결과 폴링

```bash
TASK_ID=$(python3 -c "import json; print(json.load(open('/tmp/task.json'))['task_id'])")
for i in $(seq 1 20); do
  curl -s "http://localhost:4000/api/task/$TASK_ID" -o /tmp/result.json
  STATUS=$(python3 -c "import json; print(json.load(open('/tmp/result.json')).get('status','done'))")
  [ "$STATUS" != "pending" ] && python3 -m json.tool /tmp/result.json && break
  echo "대기 중... ($i)"
  sleep 5
done
```

### 5. TypeScript 타입 체크

```bash
bun run typecheck
```

### 6. Elixir Credo (정적 분석)

```bash
cd packages/phoenix-server && mix credo --strict
```

---

## Phoenix Channel 프로토콜

WebSocket 메시지 포맷 (5-tuple):

```json
[join_ref, ref, topic, event, payload]
```

| 필드 | 설명 |
|------|------|
| `join_ref` | 채널 join 시 발급된 참조 ID |
| `ref` | 메시지 고유 참조 ID |
| `topic` | 채널 토픽 (`work:LN-YYYYMMDD-XXX`) |
| `event` | 이벤트 이름 |
| `payload` | 이벤트 데이터 |

WebSocket URL: `ws://host:4000/socket/websocket?vsn=2.0.0`
Channel topic: `work:{WORK_KEY}`

### 주요 이벤트

| 이벤트 | 방향 | 설명 |
|--------|------|------|
| `phx_join` | C→S | 채널 참여 + presence 등록 |
| `agent.hello` | S→C | 에이전트 온라인 알림 |
| `agent.bye` | S→C | 에이전트 오프라인 알림 |
| `task.assign` | S→C | 태스크 할당 |
| `task.progress` | C→S | 진행 상황 스트리밍 |
| `task.result` | C→S | 태스크 완료 결과 |
| `task.blocked` | C→S | 태스크 실패/차단 |
| `mailbox.post` | C→S | 오프라인 에이전트에게 메시지 |
| `mailbox.message` | S→C | 재연결 시 mailbox 전달 |

전체 프로토콜 명세: [docs/PROTOCOL.md](./PROTOCOL.md)

---

## Discord 알림 (개발용)

```bash
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

이벤트 수신 시 Discord로 알림 전송 (task.result, agent.hello/bye 등).

---

## PR / 기여 가이드

- Elixir: `mix credo --strict` 통과 필수
- TypeScript: `bun run typecheck` 통과 필수
- 커밋 메시지: Conventional Commits (`feat:`, `fix:`, `docs:` 등)
- 두 리모트에 push: `origin` (baryonlabs) + `dureclaw`
