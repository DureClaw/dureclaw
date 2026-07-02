# 브라우저 에이전트 비교 — dureclaw/webclaw vs Playwright+LLM · Aside+skills · vercel agent-browser

> 이 문서는 실제 작업(LearnUs LMS에서 12개 과제 채점 자료 다운로드·정리)을 dureclaw/webclaw로 수행한 세션의 경험을 근거로, 기존 3개 접근과 나란히 비교한다. 강점만이 아니라 이번에 드러난 한계·실수까지 그대로 기록한다.

## 한 줄 요약

| 방식 | 제일 잘 맞는 일 |
|---|---|
| **일반 Playwright + LLM** | 내가 직접 에이전트 루프·파일 저장·검증 로직을 설계할 때 (코드 자동화·CI) |
| **Aside + skills** | 실제 사용자 브라우저·계정·파일·반복 업무까지 끝까지 처리할 때 |
| **vercel agent-browser + LLM** | 개발자/CI/서버 환경에서 가볍고 재현 가능한 브라우저 에이전트를 만들 때 |
| **dureclaw / webclaw** | 브라우저를 **여러 이기종 머신(엣지·GPU·Windows)과 함께 하나의 fleet**로 묶어, 한 마스터가 브라우저+셸+GPU를 교차 지휘할 때 |

핵심 차이: 앞의 셋은 **브라우저 중심**(브라우저가 시스템의 전부)이다. webclaw는 **fleet 중심** — 브라우저는 분산 버스 위 **하나의 손(node)** 이고, 같은 마스터가 Linux GPU·Windows·엣지 노드도 동시에 지휘한다. 이게 webclaw의 유일한 축이다.

---

## webclaw는 무엇인가 (다른 셋과 근본적으로 다른 점)

- **fleet node**: Chrome MV3 확장이 DureClaw Phoenix 버스에 붙어, 다른 노드(edgeclaw=OS·GPIO, linux-builder=GPU, Windows, deskclaw)와 **같은 채널**에 존재한다. 마스터(Claude Code)가 `to: webclaw@chrome-...`로 브라우저에, `to: builder@linux-builder`로 GPU 박스에 **동시에** 태스크를 보낸다.
- **keyless**: 브라우저에 LLM 키가 없다. "생각"은 마스터가 하고(brain 위임), 브라우저는 **손**(fetch/DOM/click/download)만 제공한다.
- **실제 사용자 세션**: 사용자의 로그인된 Chrome 프로필에서 그대로 동작 — LearnUs 세션 쿠키로 실제 파일 다운로드가 됐다(이 점은 Aside와 같다).
- **마커 인터페이스**: `[FETCH]` `[DOM]` `[CLICK]` `[FILL]` `[SUBMIT]` `[JS]` `[TABS]` `[DOWNLOAD] <url> :: <path>` — 마스터가 자연어가 아니라 마커로 정확히 지시.

즉 webclaw는 "더 나은 Aside"가 아니라 **다른 축**이다: 브라우저를 *독립 에이전트*로 보느냐(Aside/agent-browser) vs *분산 fleet의 한 노드*로 보느냐(webclaw).

---

## 이번 LearnUs 세션에서 webclaw가 실제로 한 일 (검증됨)

- `[TABS]`로 로그인된 탭을 찾고, `@<url-substring>`으로 특정 세션 탭을 타깃팅
- `[FETCH]`(세션 쿠키 포함)로 코스 페이지를 읽어 **과제 id → 주차 → 과제명** 매핑을 서버측에서 확정 — 추정 없이 실제 데이터
- `[DOM]`으로 채점 테이블 전체를 읽어 **학생별 정확한 제출 파일명** 확보 → 파일명만으론 불가능했던 귀속(IMG_*, 발표.mov, REPORT.md)을 정확히 해결
- `[CLICK]`으로 로그인 세션에서 파일 실제 다운로드, `[DOWNLOAD] <url> :: <student>/<file>`로 **학생별 폴더에 직접 저장**(충돌 방지)
- 다운로드 후 **`find`/`stat`로 디스크 파일 존재·크기 검증** 후에만 완료로 보고

결과: OSS 12개 과제 + NLP 10개 과제를 `oss|NLP/<주차>/<과제>/<학생>/`로 정리(학생 125+명, 파일 195+개), 각 과제 정의를 `과제정의.md`로 추출.

---

## 이번 세션에서 드러난 webclaw의 실제 한계 (정직하게)

1. **다운로드 완료 신호 부재** — `chrome.downloads.download`는 "시작"만 콜백하고 대용량은 ack가 안 왔다("무응답"). → **디스크로만 검증**하도록 우회. (교훈: "요청 성공 ≠ 저장 완료")
2. **취소 API 없음** — 폭주한 대용량 일괄 다운로드를 webclaw로 못 멈춰 사용자가 `chrome://downloads`에서 취소해야 했다.
3. **Chrome 다중 다운로드 차단** — 다수를 동시에 트리거하니 브라우저가 자동 다운로드를 막았다. → **순차(1개씩→디스크확인→다음)**로 전환.
4. **기능 추가마다 확장 재로드** — `[DOWNLOAD]`·경로지정·캡 상향을 넣을 때마다 사용자가 확장을 재로드해야 했다(v0.2→0.3→0.3.2). 성숙한 제품 대비 반복 마찰.
5. **`[JS]` eval이 페이지 CSP에 막힘** — LearnUs의 `unsafe-eval` 금지로 임의 JS 실행 불가. 정적 함수 기반 `[CLICK]`/`[DOM]`으로 우회.
6. **snapshot/ref가 아니라 CSS 셀렉터 + 출력 캡** — 토큰 효율·안정성이 Aside/agent-browser의 accessibility-snapshot+ref 방식보다 떨어진다(초기 200KB 캡이 채점 페이지를 잘라 2MB로 올려야 했다).

이 중 1·3은 dureclaw 프로토콜 개선으로 일부 제도화했다 — 예: **태스크 상태 라이프사이클 `queued→running→done|failed`**(이슈 #19)는 "서버 응답"과 "실제 완료"를 프로토콜 레벨에서 구분한다.

---

## 축별 비교

| 축 | Playwright+LLM | Aside+skills | agent-browser+LLM | **dureclaw/webclaw** |
|---|---|---|---|---|
| 안정성 | 코드 잘 짜면 최고 | 실무 환경 최적 | LLM 조작 안정적 | 마커 기반 안정, 단 다운로드 UX 미성숙 |
| 토큰 효율 | raw DOM 나쁨 / MCP 좋음 | snapshot 좋음 | snapshot **매우 좋음** | 캡 기반, ref 아님 → **보통** |
| 실제 사용자 업무 | 직접 많이 구현 | **가장 강함** | 개발/제품용 | 강함(실 세션) + fleet 확장 |
| 파일/다운로드 | 직접 구현 시 강함 | 사용자 파일까지 연결 | 서버환경 강함 | 세션 다운로드+로컬 정리 O, **ack/취소 약함** |
| 세션/로그인 | auth state 직접 | **실 브라우저 세션** | profile restore | **실 브라우저 세션**(keyless) |
| 장기 업무 | 스케줄러 직접 | routines/알림 | 외부 orchestration | 버스 presence·자동재접속·대시보드 |
| **이기종 fleet** | ✗ (브라우저 단독) | ✗ | ✗ | ✅ **브라우저+엣지+GPU+Windows 한 버스** |
| LLM 위치 | 별도 | 내장 | 별도 | **마스터 위임(keyless)** |

---

## 언제 무엇을 쓰나

- **연구/프로토타입** → agent-browser + LLM (빠르고 snapshot이 LLM 친화적)
- **사내 자동화 스크립트** → Playwright + LLM (재현성·테스트·CI)
- **실제 사용자 대신 단일 브라우저 업무** → Aside + skills (로그인 세션·파일·문서·확인·장기 작업이 한 흐름)
- **브라우저를 다른 머신들과 함께 한 fleet로** → dureclaw/webclaw
  - 예: "브라우저로 LMS에서 제출물 받아서 → **GPU 서버(linux-builder)에서 표절/이상 탐지 모델 돌리고** → Windows에서 성적표 xlsx 생성" 같이 **브라우저+GPU+Windows를 한 마스터가 교차 지휘**하는 작업
  - keyless가 필요하거나(브라우저에 키를 두기 싫음), 여러 프로필/머신을 동시에 다뤄야 할 때

### 이번 LearnUs 같은 "단일 브라우저 + 파일 정리" 작업만 놓고 보면
성숙도(다운로드 ack·취소, skills 자산, snapshot)에서는 **Aside가 더 매끄럽다.** webclaw의 이점은 "이 작업을 fleet의 다른 노드(GPU 채점, Windows 성적표)로 **자연스럽게 이어붙일 수 있다**"는 확장성 쪽이다. 순수 브라우저 작업 하나만이면 Aside가, 그 뒤에 이기종 처리가 붙으면 webclaw가 유리하다.

---

## 운영 원칙 (이번 사례에서 검증)

브라우저 에이전트가 어느 도구든 지켜야 할 규율 — 이번 세션에서 실제로 지킨(그리고 초반에 어긴) 것:

1. **링크는 추정하지 말고 실제 href를 읽는다** — 코스/채점 페이지의 pluginfile href를 파싱해 사용(초기에 URL 추정하던 다른 에이전트의 실수를 피함).
2. **서버 응답 성공과 로컬 저장 성공을 구분한다** — `fetch()` 200 ≠ 디스크 저장. (다른 에이전트가 이걸 혼동해 "완료"로 오보한 사례를 이 세션에서 명시적으로 교정.)
3. **다운로드 후 파일 존재·크기를 확인한다** — `stat -f%z`로 0바이트·누락 검증.
4. **최종 산출물 구조를 `find`로 검증한다** — 학생 폴더·파일 수를 실측.
5. **"시도함 / 응답 확인 / 저장 완료"를 구분해서 보고한다** — 완료로 말하기 전에 디스크 검증.

dureclaw는 이 중 2·5를 **프로토콜로 제도화**했다: 태스크 상태 `queued→running→done`, 그리고 `[DOWNLOAD]`가 실제 브라우저 다운로드(디스크 저장)를 트리거하도록 설계(응답만 받는 `fetch()`와 구분).

---

## 결론

- webclaw는 **브라우저 에이전트라기보다 "브라우저를 fleet에 빌려주는 노드"** 다. 그래서 Aside/agent-browser/Playwright와 *경쟁*이라기보다 *다른 층*이다.
- 순수 단일 브라우저 업무 성숙도는 아직 **Aside가 앞선다**(ack·취소·skills·snapshot).
- webclaw가 유일한 지점은 **"브라우저 + 이기종 머신을 한 마스터·한 버스로 keyless 지휘"** — 이번처럼 브라우저 다운로드 뒤에 GPU 채점·Windows 성적표가 붙는 파이프라인에서 진가가 난다.
- 이번 세션의 실수(다운로드 ack 혼동, 재로드 마찰, 다중 다운로드 차단)는 webclaw를 개선(v0.3.2: 경로지정 다운로드·2MB 캡)하고 운영 규율(디스크 검증)을 세우는 계기가 됐다.
