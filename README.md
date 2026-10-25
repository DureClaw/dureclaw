# DureClaw MCP

Claude Code를 DureClaw 버스(Phoenix 서버)에 연결하는 MCP 서버입니다. 여러 머신의 에이전트에게 작업을 보내고, 결과·프레즌스·메일박스·공유 상태를 다룹니다.

## 설치

```bash
curl -fsSL https://dureclaw.baryon.ai/mcp | bash
```

서버 주소는 `PHOENIX=ws://<서버>:4000` 환경변수로 지정할 수 있습니다. 직접 등록하려면:

```bash
bun install
claude mcp add oah --scope user -e PHOENIX_URL=ws://<서버>:4000 -- bun run src/index.ts
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

## 환경변수

`PHOENIX_URL`(기본 `ws://localhost:4000`), `AGENT_ROLE`, `AGENT_NAME`, `WORK_KEY`

홈페이지: https://dureclaw.baryon.ai

## License

MIT
