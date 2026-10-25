---
name: dureclaw-bus
description: Use when work should run on another machine or several machines at once — a Windows/Linux/GPU box, a Raspberry Pi, or a Chrome browser joined to a DureClaw fleet — or when the user mentions DureClaw, the bus, Work Key, fleet, nodes, or "다른 컴퓨터에서 실행". Dispatches tasks to fleet nodes, waits for results, and reads presence, shared state, mailboxes and notifications. Works from any agent via the DureClaw MCP tools, with a curl fallback.
---

# DureClaw bus — 여러 컴퓨터를 한 팀으로

DureClaw는 흩어진 컴퓨터(Windows·macOS·Linux·라즈베리파이)와 브라우저(Chrome 확장 webclaw)를 **버스**(Phoenix 서버) 하나로 묶는다. 이 에이전트가 두뇌, 버스에 붙은 노드가 손이다.

## 언제 쓰나

- 이 머신에서 할 수 없는 일: Windows 빌드, GPU 학습, 실제 장치(GPIO·센서) 테스트, 로그인된 브라우저 작업
- 여러 머신에서 **동시에** 돌려야 하는 일: OS별 빌드·테스트, 채널별 반복 업무
- 사용자가 "노드", "플릿", "Work Key", "두레클로", "다른 PC에서"를 말할 때

## 준비 확인

1. MCP 도구 `get_version` 이 있으면 연결된 것이다. 없으면 아래 **설치** 참고.
2. `get_presence` 로 온라인 노드를 본다. 각 노드는 `name`(예: `builder@win-pc`), `role`, `machine`, `capabilities` 를 가진다.
3. 노드가 없으면 사용자에게 노드 추가를 안내한다: Linux/macOS `PHOENIX=ws://<서버>:4000 bash <(curl -fsSL https://dureclaw.baryon.ai/agent)`, Windows는 https://dureclaw.baryon.ai/windows

## 작업 보내기 → 결과 받기

| 도구 | 용도 |
|---|---|
| `send_task` | `{to?, role?, instructions, task_id?}` — `to` 를 비우면 해당 `role` 노드 전체에 브로드캐스트 |
| `get_notifications` | 완료·실패·막힘·승인 요청·노드 접속/이탈 알림(최근 200건, `since` 로 증분 조회) |
| `get_presence` | 온라인 노드 목록 |
| `read_state` / `write_state` | Work Key 단위 공유 상태(JSON) |
| `read_mailbox` / `post_message` | 노드 간 메시지 |
| `receive_task` / `complete_task` | 이 에이전트 자신이 작업을 받는 쪽일 때 |
| `get_version` | MCP·서버·최신 릴리스 버전, 업데이트 안내 |

**표준 흐름**

1. `get_presence` → 대상 노드 이름 확인 (추측 금지)
2. `send_task` 로 지시 — 지시문은 그 머신에서 그대로 실행 가능한 구체적 문장으로. 셸 작업은 `[SHELL] <명령>` 으로 시작하면 노드가 LLM 없이 바로 실행한다.
3. `get_notifications(since=<보낸 시각>)` 를 몇 초 간격으로 확인 — `✅ 작업 완료` / `❌ 작업 실패` / `⏸ 작업 막힘`
4. 결과를 사용자에게 요약. 여러 노드에 보냈으면 노드별로 정리.

**병렬**: 노드마다 `send_task` 를 연달아 보내고, 알림이 모두 올 때까지 기다린 뒤 한 번에 정리한다.

## 브라우저 노드 (webclaw)

`to` 가 `webclaw@chrome-…` 인 노드는 사용자의 로그인된 Chrome이다. 지시는 마커로 보낸다: `[OPEN] <url>`, `[DOM@사이트] <css>`, `[CLICK@사이트] <css|@N>`, `[FILL@사이트] <css> = <값>`, `[OUTLINE@사이트]`, `[RUN@사이트] <js>`. 쓰기 후에는 반드시 다시 읽어 확인한다. 결제·삭제처럼 되돌릴 수 없는 동작은 사용자 확인 후에만.

## MCP가 없을 때 (curl)

```bash
B=http://<서버>:4000; H="Authorization: Bearer $OAH_SECRET"
curl -s -H "$H" $B/api/presence
WK=$(curl -s -H "$H" $B/api/work-keys/latest | jq -r .work_key)
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/api/task \
  -d "{\"work_key\":\"$WK\",\"to\":\"builder@win-pc\",\"task_id\":\"t-$(date +%s)\",\"instructions\":\"[SHELL] dir\"}"
curl -s -H "$H" $B/api/task/<task_id>   # 200=완료, 202=대기
```

## 설치

- Claude Code: `/plugin marketplace add DureClaw/dureclaw` → `/plugin install dureclaw@dureclaw`
- 그 밖의 에이전트: https://github.com/DureClaw/dureclaw README 의 에이전트별 설치
- 서버: `bash <(curl -fsSL https://dureclaw.baryon.ai/install)`

## 주의

- 비밀값(`OAH_SECRET`)을 지시문·로그·사용자 화면에 그대로 쓰지 않는다.
- 노드가 `pending operator approval` 이면 사용자가 대시보드에서 승인해야 한다.
- 실패 알림은 그대로 사용자에게 보고한다. 성공으로 바꿔 말하지 않는다.
