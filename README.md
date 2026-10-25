# DureClaw MCP

Claude Code를 DureClaw 버스(Phoenix 서버)에 연결하는 MCP 서버입니다. 여러 머신의 에이전트에게 작업을 보내고, 결과·프레즌스·메일박스·공유 상태를 다룹니다.

## 설치

```bash
curl -fsSL https://dureclaw.baryon.ai/mcp | bash
```

서버 주소와 비밀값은 `PHOENIX=ws://<서버>:4000 OAH_SECRET=<값>` 환경변수로 지정할 수 있습니다. 직접 등록하려면:

```bash
bun install
claude mcp add oah --scope user -e PHOENIX_URL=ws://<서버>:4000 -e OAH_SECRET=<값> -- bun run src/index.ts
```

## 도구

| 도구 | 설명 |
|------|------|
| `send_task` | 역할/에이전트에게 작업 보내기 |
| `receive_task` | 나에게 배정된 작업 받기 |
| `complete_task` | 작업 결과 보고 |
| `get_presence` | 접속 중인 에이전트 목록 |
| `read_state` / `write_state` | Work Key 공유 상태 읽기/쓰기 |
| `read_mailbox` / `post_message` | 메일박스 |
| `get_notifications` | 최근 버스 알림 (작업 완료·실패·막힘, 승인 요청, 메일박스, 노드 접속·이탈) |
| `get_version` | MCP·서버·최신 릴리스 버전, 업데이트 필요 여부 |

## 알림

위 버스 이벤트는 MCP logging(`notifications/message`, logger `dureclaw`)으로 클라이언트에 바로 전달되고, 최근 200건은 `get_notifications`로 다시 볼 수 있습니다.

## 환경변수

`PHOENIX_URL`(기본 `ws://localhost:4000`), `OAH_SECRET`(서버 비밀값), `AGENT_ROLE`, `AGENT_NAME`, `WORK_KEY`

홈페이지: https://dureclaw.baryon.ai

## License

MIT
