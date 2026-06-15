# DureClaw — 엣지 브레인 위임 & 물리 신호등 실증 보고서

- **작성일**: 2026-06-16
- **버전**: v0.5.x (`main` 배포 완료)
- **범위**: pi 코딩 백엔드 전환 · 브레인 노드 위임 · 멀티플랫폼/하드웨어 실증 · 엣지 결정론 최적화 · 버스 모니터링

---

## 1. 개요

DureClaw 이종 함대(macOS·Linux·Docker·Raspberry Pi Zero·Windows)가 **마스터 한 곳의 단일 AI 인증**으로 동작하도록 만들고, 이를 **물리 하드웨어(초음파 센서 + 3색 신호등)**까지 끌어내려 실증했다. 핵심은 "**로컬 핸드 · 원격 브레인**" — 키 없는 엣지 노드가 현장 작업(센서·셸·GPIO)은 로컬에서, 판단(LLM/코딩)은 마스터로 위임 — 그리고 이를 "**한 번 배우고(brain) 이후 결정론적으로(edge skill)**" 최적화한 것이다.

## 2. pi 코딩 백엔드 전환 (opencode → pi)

- 코딩 백엔드를 `opencode` → **`pi`**(`@earendil-works/pi-coding-agent`, CLI `pi`, 원샷 `pi -p "<prompt>"`)로 전환.
- 범위: agent-daemon(`buildAgentCmd`/`autoSelectBackend`/탐지/`PI_BIN`), 설치 스크립트(`pi.dev/install.sh`→npm fallback), README×4·랜딩·PROTOCOL(`[OPENCODE]`→`[PI]`).
- `opencode`는 호환을 위해 인식만 유지(설치는 pi). `.opencode/` 하네스 디렉터리는 별개라 보존.

## 3. 브레인 노드 위임 아키텍처

```
서브노드 (키 없음)                         마스터 (단일 pi 인증)
────────────                              ──────────────
로컬 핸드: [SHELL]·센서·GPIO → 로컬 실행      BRAIN_SERVE=1
브레인:    AI 태스크 → BRAIN_URL 위임 ──────▶  POST /brain/exec (Bearer BRAIN_TOKEN)
                                              └ 인증된 pi 실행 → {output, exit_code}
```

- **마스터**: `BRAIN_SERVE=1` + `BRAIN_TOKEN` → 인증된 pi를 토큰 게이트 HTTP(`:4111`, `/brain/exec`)로 노출. `/brain/health` 공개.
- **서브노드**: `BRAIN_URL` 설정 시 backend `remote-pi`(`runRemoteBrain`) → 프롬프트를 마스터로 POST. `[SHELL]`·센서는 로컬.
- 설치 스크립트가 `BRAIN_URL` 감지 시 pi 로컬 설치 생략·`BACKEND=remote-pi`.
- Pi Zero(armv6, stdlib Python 에이전트)는 pi 바이너리를 못 돌리므로 **브레인 위임이 유일한 pi 사용법** — `brain_exec`(urllib) 추가.

## 4. 멀티플랫폼 실증

| 노드 | arch / OS | 모드 | 검증 결과 |
|------|-----------|------|-----------|
| `brain@hong-macbookpro` | arm64 / macOS | **브레인 서버** | `:4111` 가동, 단일 pi 인증 |
| `builder@NUCBOXG3` | x64 / **win32** | remote-pi (키 없음) | 태스크 위임 → 응답 *"I am running on macOS"* = 마스터 실행 증명 |
| `executor@pi-zero` | **armv6** / linux | remote-pi (키 없음) | 태스크 위임 → `backend:remote-pi` 결과 정상 |
| `builder@docker-arm64` | arm64 / linux | claude-haiku 로컬 | 온라인 |
| `builder@linux-builder` | x64 / linux | ollama 로컬 | 온라인 |

> Windows WS 합류엔 `OAH_SECRET`(WS 토큰)이 필수 — 누락 시 401 거부. 현재 `setup-agent`가 미경고(개선 과제).

## 5. 물리 신호등 데모 (Raspberry Pi Zero W)

**하드웨어**
- HC-SR04 초음파: 5V, Trig=GPIO23, **Echo=GPIO24(1kΩ + 2kΩ 분압 필수)**, GND.
  - ⚠️ 단일 1kΩ 직렬만으로는 5V가 분압되지 않아 GPIO24가 HIGH 고정 → 측정 불가. **GPIO24↔GND에 ~2kΩ 추가**(1k:2k → 3.3V)로 해결.
- 3색 LED: 빨강=GPIO19, 노랑=GPIO26, 초록=GPIO20 (+다리, 단다리→GND).

**동작**: 거리 측정(로컬 핸드) → 신호색 판단 → LED 점등(액추에이터). 빨강/노랑/초록 전부 실증.

## 6. 엣지 결정론 최적화 — "한 번 배우고, 이후 결정론적으로"

매 판단을 마스터 브레인이 내리면 정확하지만 **~4–5초/판단**으로 느리다. 학습 루프의 *결정론적 결정화* 패턴을 엣지에 적용:

1. **1차(마스터, 1회)**: Pi가 마스터 브레인에 정책 판단 요청 → **임계값 + 근거(rationale)** 수신.
2. **결정화**: Pi가 정책을 로컬 스킬 파일(`~/.dureclaw/skills/proximity-light.json`)로 동결.
3. **이후(엣지, 결정론)**: brain 호출 없이 로컬 스킬로 판정 → **µs 단위**.

**마스터 판단 결과(예시)**: `red<12cm, yellow<35cm` · 근거: *"Red=12cm (within 10–15cm stop zone); Yellow=35cm (within 30–40cm caution zone)"*

### 처리 속도 개선 로그 (실측)

| 실행 | 마스터 보정 | brain/판단(옛) | 로컬 스킬/판단(새) | 속도 향상 |
|------|------------|----------------|--------------------|-----------|
| 1차(보정) | 6,034 ms (1회) | 4,378.6 ms | 167.2 µs | **≈ 26,193x** |
| 2차(캐시) | **0 ms** | 4,992.5 ms | 44.6 µs | **≈ 111,877x** |
| 3차(캐시) | **0 ms** | 5,260.2 ms | 36.7 µs | **≈ 143,136x** |

- 마스터 1회 보정 비용(~6초)은 N회에 분할 상각, **캐시 후 0**.
- 정확도 동일(brain 규칙을 스킬로 동결) · 판단 지연만 ~5초 → ~40µs (≈10만 배).
- 산출물: `scripts/hc_fleet.py`(brain 매 판단 기준선), `scripts/hc_policy.py`(보정+결정론+속도로그).

## 7. 버스 모니터링 — 시그널을 마스터로

- 매 측정/판단/속도결과를 `sensor@pi-zero`가 **work 버스(`task.result`)로 push** → 마스터 및 모든 구독자가 수신.
- 페이로드: 거리, 신호색, 로컬 스킬 지연(µs), 정책 결정화, 속도개선 요약.
- **현황/과제**: 시그널은 버스에 정상 전달되나, 재설계된 대시보드 레이아웃에서 **이벤트 스트림 카드 노출이 약함**(스크롤 미동작). 마스터 데몬도 `task.result`를 구독만 하고 로깅하지 않음. → *모니터링 가시성 개선*(대시보드 스트림 노출 / 마스터 수신 로깅)이 후속 과제.

## 8. 배포 / 인프라

- **R2 배포 장애 해소**: CI의 `CF_R2_TOKEN` 시크릿 부재로 `agent.py`·`oah-agent.js` R2 업로드가 장기 실패(3월 버전 고착). → 토큰 불필요한 **GitHub Pages**로 이전(`dureclaw.baryon.ai/oah-agent.js`, `/agent.py`), `OAH_BASE`도 dureclaw로. `pages.yml`이 `bun install`+`bun build`로 번들 생성.
- **Windows 무설정 자동탐색**: mDNS(`oah.local`) + Tailscale 피어 스캔. `agent.ps1` 출력 인코딩(mojibake) 수정 + 도달성 진단.
- v0.5.0 changelog 라이브 반영.

## 9. 남은 과제

1. **모니터링 가시성** — 대시보드 이벤트 스트림에 센서 시그널 노출, 또는 마스터 수신 로깅.
2. **마스터 브레인 서버 안정화** — 현재 임시 bun 백그라운드 프로세스 → launchd 서비스.
3. **`OAH_SECRET` 누락 경고** — `setup-agent`가 WS 토큰 없을 때 사전 안내(Windows 401 예방).
4. **`CF_R2_TOKEN`** 설정 또는 R2 경로 정리.
5. **학습 환류** — 결정화된 정책/스킬을 서버 스킬 레지스트리(`/api/skills`)와 통합해 대시보드 🧩 패널에 노출.

---

## 부록 — 재현

**마스터(브레인 서버)**
```bash
BRAIN_SERVE=1 BRAIN_TOKEN=<token> PI_BRAIN_PORT=4111 \
  STATE_SERVER=ws://127.0.0.1:4000 OAH_SECRET=<secret> \
  WORK_KEY=WK-xxxx AGENT_NAME=brain@host bun run packages/agent-daemon/src/index.ts
```

**키 없는 서브노드(Windows/Pi/Docker)**
```powershell
# Windows
$env:OAH_SECRET='<secret>'; $env:BRAIN_URL='http://<master>:4111'; $env:BRAIN_TOKEN='<token>'; `
  $env:PHOENIX='ws://<master>:4000'; irm https://dureclaw.baryon.ai/agent.ps1 | iex
```

**Pi Zero 물리 신호등(보정→결정론)**
```bash
BRAIN_URL=http://<master>:4111 BRAIN_TOKEN=<token> OAH_SECRET=<secret> \
  STATE_SERVER=<master>:4000 WORK_KEY=WK-xxxx AGENT_NAME=sensor@pi-zero \
  python3 -u ~/hc_policy.py 12            # 1회 보정 후 결정론 + 속도로그
```
