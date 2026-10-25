# DureClaw — 흩어진 컴퓨터와 브라우저를 하나의 AI 팀으로

어떤 에이전트(Claude Code, Codex, Gemini CLI, Cursor …)에서든 **DureClaw 버스**에 작업을 보내고 결과와 알림을 받을 수 있게 해 주는 **Agent Skills + MCP 서버 + 플러그인** 패키지입니다.

- **MCP 서버** (`mcp/`): 작업 보내기, 결과·알림 받기, 접속 노드 보기, 공유 상태, 메일박스를 도구로 제공합니다.
- **Agent Skills** (`skills/`): 언제 어떻게 버스를 쓰는지 알려 주는 `SKILL.md`입니다. 오픈 표준 형식이라 여러 에이전트가 함께 읽습니다.
- **플러그인 매니페스트**: Claude Code(`.claude-plugin/`, `.mcp.json`), Gemini CLI(`gemini-extension.json`), 공통 안내(`AGENTS.md`)

서버 설치와 노드 추가는 홈페이지를 참고하세요 → **https://dureclaw.baryon.ai**

```bash
bash <(curl -fsSL https://dureclaw.baryon.ai/install)   # 서버 + Claude Code MCP 한 번에
```

## 설치 — 에이전트별

모든 경우 [Bun](https://bun.sh)이 필요합니다. 서버 주소와 비밀값은 환경변수로 넘깁니다.

```bash
export PHOENIX_URL=ws://<서버 IP>:4000
export OAH_SECRET=<서버 비밀값>      # 서버의 ~/.oah-server/data/server.secret
```

### Claude Code — 플러그인 (MCP + Skills + 에이전트 + 명령)

```
/plugin marketplace add dureclaw/dureclaw
/plugin install dureclaw@dureclaw
```

플러그인 없이 MCP만 등록하려면 `bash <(curl -fsSL https://dureclaw.baryon.ai/mcp)`를 실행하세요.

### Gemini CLI — 확장

```bash
gemini extensions install https://github.com/dureclaw/dureclaw
```

### Skills만 (여러 에이전트 공통)

```bash
npx skills add dureclaw/dureclaw
```

### Codex · Cursor · VS Code · 그 밖의 MCP 클라이언트

```bash
git clone https://github.com/dureclaw/dureclaw ~/.dureclaw/plugin
```

Codex:

```bash
codex mcp add dureclaw --env PHOENIX_URL=$PHOENIX_URL --env OAH_SECRET=$OAH_SECRET \
  -- bun run ~/.dureclaw/plugin/mcp/src/index.ts
```

Cursor·VS Code 등 `mcp.json`을 쓰는 클라이언트:

```json
{
  "mcpServers": {
    "dureclaw": {
      "command": "bun",
      "args": ["run", "/Users/<나>/.dureclaw/plugin/mcp/src/index.ts"],
      "env": { "PHOENIX_URL": "ws://<서버 IP>:4000", "OAH_SECRET": "<서버 비밀값>" }
    }
  }
}
```

스킬은 각 에이전트의 스킬 폴더에 `skills/dureclaw-bus`를 복사하면 됩니다(예: `~/.agents/skills/`, `~/.claude/skills/`).

## MCP 도구

| 도구 | 설명 |
|------|------|
| `send_task` | 노드(또는 역할)에게 작업 보내기 |
| `get_notifications` | 최근 알림: 작업 완료·실패·막힘, 승인 요청, 메일박스, 노드 접속·이탈 |
| `get_presence` | 접속 중인 노드 목록 |
| `read_state` / `write_state` | Work Key 공유 상태 |
| `read_mailbox` / `post_message` | 노드 간 메시지 |
| `receive_task` / `complete_task` | 이 에이전트가 작업을 받는 쪽일 때 |
| `get_version` | MCP·서버·최신 릴리스 버전, 업데이트 안내 |

버스 이벤트는 MCP logging(`notifications/message`, logger `dureclaw`)으로도 바로 전달됩니다.

## 환경변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `PHOENIX_URL` | `ws://localhost:4000` | 버스 주소 |
| `OAH_SECRET` | — | 서버 비밀값 (서버에 설정돼 있으면 필수) |
| `AGENT_ROLE` | `builder` (플러그인은 `orchestrator`) | 이 에이전트의 역할 |
| `AGENT_NAME` | `<역할>@<호스트>` | 버스에 표시될 이름 |
| `WORK_KEY` | 최신 Work Key 자동 | 작업 공간 |

## 구성

```
.claude-plugin/   Claude Code 플러그인·마켓플레이스
.mcp.json         Claude Code 플러그인 MCP 설정
gemini-extension.json
AGENTS.md         에이전트 공통 안내
mcp/              MCP 서버 (Bun)
skills/           Agent Skills — dureclaw-bus(공통), dureclaw·dureclaw-run(Claude Code 팀 구성)
agents/ commands/ Claude Code 서브에이전트·슬래시 명령
```

이슈·문의: [DureClaw/homepage Issues](https://github.com/DureClaw/homepage/issues)

## License

MIT
