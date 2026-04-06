# 원격 에이전트 운영 — Remote Agent Operations

**DureCrew** *(두레크루)* 의 핵심 운영 철학.

> **원격지에 있는 AI 에이전트를 실시간으로 진단하고, 명령하고, 복구한다.**
> 이것은 실험적 아이디어가 아니라, 이미 작동하는 현실이다.

---

## 배경: 문제는 항상 손이 닿지 않는 곳에서 생긴다

당신이 서울 카페에 앉아 있을 때, 인천 데이터센터의 서버가 죽는다.
당신이 잠든 새벽 2시, 도쿄 사무실의 AI 에이전트가 침묵한다.
당신이 회의 중일 때, 집에 있는 Mac Mini의 Discord 봇이 멈춘다.

전통적인 답은 하나였다: **직접 가거나, SSH로 접속해서, 직접 고친다.**

그러나 AI 에이전트가 여러 머신에 분산된 시대에, 이 답은 더 이상 충분하지 않다.

---

## 실제 사례: 원격 진단 및 복구

MacBook Pro 앞에 앉아 **물리적으로 접근 불가능한** Mac Mini(100.69.140.79)에서
발생한 문제를 OAH를 통해 원격으로 진단하고 해결한 실제 사례다.

### 발생한 문제들

| # | 증상 | 원인 | 복구 방법 |
|---|------|------|----------|
| 1 | 모든 AI 태스크가 죽음 | `config.json`에 잘못된 필드 삽입 | Python one-liner로 원격 파일 수정 |
| 2 | 태스크를 보내도 에이전트가 무반응 | REST payload 포맷 오류 (`type:SHELL` vs `[SHELL]` prefix) | 소스 코드 분석 후 올바른 포맷 발견 |
| 3 | Discord 봇 `exec denied: allowlist miss` | OpenClaw.app이 27시간 된 설정 캐시 보유 | 원격으로 프로세스 재시작 |

### 원격에서 실행한 실제 명령들

```bash
# 원격 머신의 파일 읽기
[SHELL] cat ~/.config/opencode/config.json

# 원격 파일 수리
[SHELL] python3 -c "
import json
path = open('~/.config/opencode/config.json')
cfg = json.load(path)
cfg.pop('permission', None)   # 잘못된 필드 제거
json.dump(cfg, open(path, 'w'), indent=2)
"

# 원격 프로세스 진단
[SHELL] lsof -p $(pgrep -f OpenClaw) | grep sock

# 원격 프로세스 재시작
[SHELL] pkill -f OpenClaw.app && sleep 2 && open /Applications/OpenClaw.app

# 원격 설정 변경
[SHELL] python3 -c "
import json
cfg = json.load(open('~/.openclaw/openclaw.json'))
cfg['channels']['discord']['groupPolicy'] = 'open'
json.dump(cfg, open('~/.openclaw/openclaw.json', 'w'), indent=2)
"
```

이 모든 것이 **WebSocket 하나, REST API 하나**로 이루어졌다.
Mac Mini 앞에 사람이 앉을 필요가 전혀 없었다.

---

## 왜 원격 에이전트 운영이 필요한가

### 1. AI 에이전트는 24시간 돌아가야 한다

AI 에이전트는 사람이 아니다. 퇴근하지 않고, 잠들지 않는다.
그러나 **문제는 사람이 있는 시간에만 생기지 않는다.**

- Discord 봇이 새벽 3시에 `allowlist miss`를 반환하기 시작했다면?
- 배포된 AI 워커가 잘못된 설정으로 모든 태스크를 거부하고 있다면?

기다릴 수 없다. **원격에서 즉시 개입**할 수 있어야 한다.

### 2. 멀티-머신 AI 시스템이 현실이 되고 있다

AI 워크로드는 단일 머신에 머물지 않는다.

```
MacBook Pro    → 오케스트레이터 (작업 분배, 의사결정)
Mac Mini       → 빌더 에이전트 (코드 실행, 파일 처리)
Ubuntu 서버    → 리뷰어 에이전트 (검증, 테스트)
Raspberry Pi   → 현장 에이전트 (물리적 작업, 센서)
```

이 머신들이 집, 사무실, 클라우드, 공장에 흩어져 있다.
**중앙에서 통제하고, 원격에서 수리할 수 있어야 한다.**

### 3. 문제는 예상치 못한 곳에서 온다

이번 사례의 핵심 발견:

> `exec-approvals.json`에 `security=full`을 설정했는데 왜 여전히 막히지?

원인: **OpenClaw.app 자체가 exec-approval 데몬**이었고,
27시간 전 설정을 메모리에 올린 채 좀비처럼 살아있었다.

파일을 고치는 것만으로 부족했다. 프로세스를 진단하고, 종료하고, 재시작해야 했다.
이 전체 과정을 원격에서 수행할 수 없었다면? 직접 Mac Mini 앞에 앉아야 했다.

---

## OAH의 원격 운영 아키텍처

```
사람 (MacBook Pro)
      │
      │  mcp__oah__send_task(instructions="[SHELL] <command>")
      ▼
oah-mcp (MCP 서버)
      │
      │  REST POST /api/task
      ▼
Phoenix Server (oah.local:4000)
      │
      │  task.assign broadcast → Phoenix Channel work:{WORK_KEY}
      ▼
agent-daemon (Mac Mini — 방화벽 뒤)
      │
      │  sh -c "<command>"   (exec-approvals 검사 후 실행)
      ▼
실행 결과 → task.result → Phoenix → MCP → 사람
```

### 핵심 설계 원칙

**에이전트가 outbound로 연결한다**
- SSH 포트 불필요, 방화벽 예외 불필요
- 에이전트가 서버에 WebSocket 연결을 먼저 시작
- 연결 끊김 시 자동 재연결 (heartbeat 30초)

**비동기 task 모델**
- 명령 전송 → task_id 즉시 반환
- `GET /api/task/{task_id}` 로 결과 폴링
- 장시간 작업도 타임아웃 없이 처리 가능

**work key로 에이전트 그룹 격리**
- 각 프로젝트/팀에 독립된 work key 발급
- 에이전트는 자신의 work key 채널만 구독
- 명령이 다른 프로젝트의 에이전트에 전달되지 않음

---

## 원격 운영 vs 전통 DevOps

| 전통 DevOps | AI 에이전트 Ops (OAH) |
|-------------|----------------------|
| SSH + bash | WebSocket + `[SHELL]` task |
| 서버 상태 모니터링 | 에이전트 presence 모니터링 |
| 프로세스 재시작 스크립트 | `send_task` → `pkill && restart` |
| 로그 수집 (ELK, Datadog) | `task.result` 실시간 수신 |
| Ansible playbook | `task.assign` 브로드캐스트 |
| 단일 서버 대상 | 멀티머신 동시 병렬 실행 |

---

## 원격 운영을 위한 필수 요소

### 1. 신뢰할 수 있는 통신 채널
에이전트가 어디에 있든 서버에 연결을 유지해야 한다.
연결이 끊겨도 자동 재연결, heartbeat로 생존 확인.

### 2. 양방향 명령 실행
명령을 보내고, 결과를 받아야 한다.
단순 fire-and-forget이 아닌 결과 수신이 필수.

```bash
# task 전송
curl -X POST http://oah.local:4000/api/task \
  -d '{"work_key":"LN-...", "instructions":"[SHELL] df -h"}'
# → {"task_id": "http-1775308...", "pending": false}

# 결과 수신
curl http://oah.local:4000/api/task/http-1775308...
# → {"status": "done", "output": "Filesystem ...", "exit_code": 0}
```

### 3. 에이전트 상태 가시성
어떤 에이전트가 온라인인지, 어느 work key에 속해있는지 실시간 확인.

```bash
curl http://oah.local:4000/api/presence
# → 현재 연결된 모든 에이전트 목록
```

### 4. 실행 경계 (exec-approvals)
원격 실행은 강력하다. 그만큼 통제가 필요하다.
어떤 명령이 실행될 수 있는지 명시적으로 정의.

```json
{
  "defaults": { "security": "full", "ask": "off" },
  "agents": { "*": { "allowlist": ["/usr/bin/gh", "git"] } }
}
```

### 5. 에이전트 자기 치유
사람이 없는 시간에도 에이전트 스스로 일부 문제를 복구.
`stuck` 감지 → 4가지 탈출 전략 → 자동 재시도.

---

## 빠른 시작: 원격 에이전트에 명령 보내기

```bash
# 1. 에이전트 연결 확인
curl http://oah.local:4000/api/presence

# 2. 원격 머신 상태 확인
curl -X POST http://oah.local:4000/api/task \
  -H "Content-Type: application/json" \
  -d '{"work_key":"YOUR-WORK-KEY", "instructions":"[SHELL] uname -a && uptime"}'

# 3. 결과 확인 (task_id로 폴링)
curl http://oah.local:4000/api/task/{task_id}

# 4. MCP를 통해 Claude에서 직접 (권장)
# mcp__oah__send_task(instructions="[SHELL] <명령>", to="builder@machine")
```

---

## 결론

> AI 에이전트가 하나의 머신에서 사람 옆에서만 돌아가는 시대는 끝나고 있다.

에이전트는 집에, 사무실에, 공장에, 클라우드에 분산되어 24시간 일한다.
그리고 그 에이전트들이 문제를 일으킬 때 — **반드시 일으킨다** —
우리는 원격에서 대화하고, 진단하고, 고칠 수 있어야 한다.

OAH는 그 가능성을 증명했다.
Mac Mini가 27시간 된 설정 캐시를 들고 Discord 봇을 막고 있을 때,
집 어딘가에 앉아 WebSocket 하나로 그것을 찾아내고, 재시작하고, 고쳤다.

**이것이 멀티-에이전트 시대의 운영이다.**

---

## 관련 문서

- [AGENTS.md](./AGENTS.md) — 에이전트 역할 정의
- [METHODOLOGY.md](./METHODOLOGY.md) — 워크루프 방법론
- [GAP_ANALYSIS.md](./GAP_ANALYSIS.md) — 현재 상태 및 개선 방향
- [INSTALL.md](./INSTALL.md) — 설치 가이드
