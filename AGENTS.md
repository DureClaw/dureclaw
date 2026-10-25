# DureClaw — 에이전트 안내

이 저장소를 설치한 에이전트는 **DureClaw 버스**를 통해 다른 컴퓨터(Windows·macOS·Linux·라즈베리파이)와 사용자의 Chrome(webclaw)에 작업을 맡길 수 있습니다.

- 사용법 전체: `skills/dureclaw-bus/SKILL.md`
- 도구: MCP 서버 `dureclaw` — `send_task`, `get_notifications`, `get_presence`, `read_state`/`write_state`, `read_mailbox`/`post_message`, `receive_task`/`complete_task`, `get_version`

## 규칙

1. 작업을 보내기 전에 `get_presence`로 실제 노드 이름을 확인합니다. 이름을 추측하지 않습니다.
2. 보낸 뒤에는 `get_notifications`로 완료·실패를 확인하고, 그 결과를 있는 그대로 보고합니다.
3. 비밀값(`OAH_SECRET`)을 지시문이나 출력에 쓰지 않습니다.
4. 결제·삭제·배포처럼 되돌릴 수 없는 작업은 사용자 확인 후에만 보냅니다.
