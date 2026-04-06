# Remote Agent Guide — DureCrew

원격 에이전트를 DureCrew 팀에 연결하고 운영하는 방법입니다.

## 원격 에이전트 아키텍처

```
로컬 머신 (오케스트레이터)          원격 머신들
┌─────────────────────┐            ┌──────────────────┐
│ Claude Code         │            │ Mac Mini M4      │
│ + DureCrew 스킬     │            │ agent-daemon.js  │
│                     │◄──WS──────►│ role: builder    │
│ Phoenix Server      │            └──────────────────┘
│ :4000               │            ┌──────────────────┐
│                     │◄──WS──────►│ Raspberry Pi     │
│ REST API            │            │ agent-daemon.js  │
│ WebSocket Channel   │            │ role: tester     │
└─────────────────────┘            └──────────────────┘
```

## 원격 에이전트 설치

원격 머신에서 one-liner:

```bash
# Linux/Mac
PHOENIX=ws://YOUR_HOST:4000 ROLE=builder bash <(curl -fsSL http://YOUR_HOST:4000/setup.sh)

# Windows PowerShell
$env:PHOENIX="ws://YOUR_HOST:4000"; $env:ROLE="builder"
iex (iwr http://YOUR_HOST:4000/setup.ps1).Content

# Windows cmd
curl -fsSL http://YOUR_HOST:4000/go?role=builder -o go.cmd && go.cmd && del go.cmd
```

## 온라인 에이전트 확인

```bash
# 현재 온라인 에이전트 목록
curl -s http://localhost:4000/api/presence | jq '.'

# 응답 예시
{
  "agents": {
    "builder-mac": {
      "role": "builder",
      "machine": "mac-mini-m4",
      "capabilities": ["apple-gpu", "macos", "xcode"],
      "work_key": "LN-20260406-001",
      "online_since": "2026-04-06T09:00:00Z"
    },
    "tester-pi": {
      "role": "tester",
      "machine": "raspberry-pi-4",
      "capabilities": ["arm", "linux", "rpi-speakerphone"],
      "work_key": "LN-20260406-001",
      "online_since": "2026-04-06T09:01:00Z"
    }
  }
}
```

## Work Key 관리

```bash
# 새 Work Key 생성
curl -s -X POST http://localhost:4000/api/work-keys \
  -H "Content-Type: application/json" \
  -d '{"goal": "프로젝트 목표 설명"}'
# → {"work_key": "LN-20260406-001"}

# 모든 Work Key 목록
curl -s http://localhost:4000/api/work-keys

# 최신 Work Key
curl -s http://localhost:4000/api/work-keys/latest

# Work Key 상태 조회
curl -s http://localhost:4000/api/state/LN-20260406-001

# Work Key 상태 업데이트
curl -s -X PATCH http://localhost:4000/api/state/LN-20260406-001 \
  -H "Content-Type: application/json" \
  -d '{"status": "running", "goal": "iOS 앱 빌드"}'
```

## 원격 에이전트 태스크 할당

```bash
# 태스크 할당 (원격 에이전트가 온라인인 경우: Phoenix channel broadcast)
# 원격 에이전트가 오프라인인 경우: mailbox에 큐잉됨
curl -s -X POST http://localhost:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "work_key": "LN-20260406-001",
    "to": "builder-mac",
    "task_id": "build-ios-001",
    "instructions": "[SHELL] cd ~/MyApp && xcodebuild -scheme MyApp -destination generic/platform=iOS",
    "context": {
      "branch": "main",
      "version": "2.1.0"
    },
    "depends_on": []
  }'
```

## 오프라인 에이전트 mailbox

원격 에이전트가 일시적으로 오프라인일 때 메시지를 큐잉합니다.
에이전트가 재연결되면 자동으로 mailbox의 메시지를 수신합니다.

```bash
# mailbox에 메시지 전송 (오프라인 에이전트)
curl -s -X POST http://localhost:4000/api/mailbox/builder-mac \
  -H "Content-Type: application/json" \
  -d '{
    "from": "orchestrator",
    "instructions": "재연결 후 빌드 캐시 초기화 실행",
    "work_key": "LN-20260406-001"
  }'

# mailbox 메시지 확인
curl -s http://localhost:4000/api/mailbox/builder-mac
```

## 태스크 결과 수신

```bash
# 특정 태스크 결과 폴링
curl -s http://localhost:4000/api/task-result/build-ios-001

# 결과 형식
{
  "ok": true,
  "results": [
    {
      "task_id": "build-ios-001",
      "from": "builder-mac",
      "event": "task.result",
      "status": "done",
      "output": "BUILD SUCCEEDED",
      "ts": "2026-04-06T09:15:30Z"
    }
  ]
}
```

## 연결 문제 해결

```bash
# Ghost presence 제거 (에이전트가 끊겼지만 presence 남아있는 경우)
curl -s -X DELETE http://localhost:4000/api/presence/builder-mac

# 서버 상태 확인
curl -s http://localhost:4000/api/health

# 에이전트 로그 확인 (원격 머신에서)
journalctl -u oah-agent -f   # Linux systemd
# 또는
cat ~/oah-agent.log
```

## 머신별 capabilities 목록

| capability | 의미 |
|-----------|------|
| `apple-gpu` | Apple Silicon GPU (Metal) |
| `nvidia-gpu` | NVIDIA CUDA GPU |
| `macos` | macOS 환경 |
| `linux` | Linux 환경 |
| `windows` | Windows 환경 |
| `arm` | ARM 아키텍처 |
| `xcode` | Xcode 설치됨 |
| `docker` | Docker 사용 가능 |
| `rpi-speakerphone` | Raspberry Pi 스피커폰 |
| `printer` | 프린터 연결 |
| `ram:Xg` | X GB RAM (예: ram:64g) |
