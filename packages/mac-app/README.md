# DureClaw — macOS 서버 앱

터미널 없이 맥에서 DureClaw 서버(Phoenix)를 실행하는 메뉴 막대 앱입니다.

## 사용

1. [최신 릴리스](https://github.com/DureClaw/dureclaw/releases/latest)에서 **`DureClaw-Server-mac-arm64.dmg`** 다운로드 (Apple Silicon)
2. dmg 를 열고 **DureClaw** 를 **Applications(응용 프로그램)** 으로 끌어 놓기
3. 응용 프로그램에서 DureClaw 실행 → 화면 위 메뉴 막대에 아이콘이 생기고 서버가 시작됩니다

> **처음 한 번 — "확인되지 않은 개발자" 경고**
> 서명되지 않은 앱이라 macOS 가 막을 수 있습니다.
> **우클릭 → 열기** 를 누르거나, **시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"** 를 누르세요.

메뉴:

| 항목 | 하는 일 |
|------|---------|
| 상태 | 실행 중 · 연결된 노드 수 · 포트 |
| 대시보드 열기 | `http://localhost:4000` |
| 노드 연결 주소 복사 | `ws://<Tailscale IP 또는 LAN IP>:4000` — Windows 설치 프로그램에 붙여 넣기 |
| Windows 설치 프로그램 다운로드 | dureclaw.baryon.ai/windows |
| Linux/Mac 노드 추가 명령 복사 | `PHOENIX=ws://…:4000 bash <(curl -fsSL https://dureclaw.baryon.ai/agent)` |
| Claude Code 연결 명령 복사 | MCP 등록 명령 (시크릿 포함 — 화면에는 가려서 표시) |
| 로그 보기 · 서버 재시작 · 로그인 시 자동 실행 · 종료 | |

- 데이터: `~/.dureclaw/server/data` (시크릿 `server.secret` 포함), 로그: `~/.dureclaw/server/logs/server.log`
- 포트 변경: `~/.dureclaw/server/config` 에 `PORT=4100` (또는 환경변수 `DURECLAW_PORT`)
- 이미 같은 포트에서 다른 DureClaw 서버(예: 터미널 설치)가 돌고 있으면 새로 띄우지 않고 그 상태를 보여줍니다.
- 서버 설정: `OAH_BIND_IP=0.0.0.0`(localhost·LAN·Tailscale 모두), `OAH_TRUST_LOOPBACK=1`(이 맥에서 오는 요청은 토큰 없이 허용). 원격 노드는 키 없이 접속 요청 → 노드별 토큰 발급(Tailscale 안이면 자동 승인).
- 앱을 종료하면 서버도 함께 종료됩니다.

## 빌드

```bash
# 릴리스까지 한 번에 (packages/phoenix-server 에서 mix release)
packages/mac-app/build.sh

# 이미 만든 릴리스로
packages/mac-app/build.sh path/to/_build/prod/rel/harness_server 0.4.5
```

결과: `packages/mac-app/dist/DureClaw.app`, `dist/DureClaw-Server-mac-arm64.dmg`

- `DureClaw.swift` 단일 파일을 `swiftc` 로 컴파일 (Xcode 프로젝트 없음), 아이콘은 `web/favicon-256.png` → `.icns`
- Elixir 릴리스를 `Contents/Resources/server` 에 번들. 빌드 머신의 openssl(`crypto.so` 가 링크)도 `server/dylibs`·`server/ossl-modules` 로 복사해 Homebrew 가 없는 맥에서도 뜨게 함
- 번들 이름에 공백 금지 — erl 스크립트가 공백 경로에서 깨짐
- ad-hoc 서명(`codesign -s -`)만 함. 정식 배포 서명·공증(notarization)은 Apple Developer ID 필요

CI: 태그 push 시 `.github/workflows/release.yml` 의 `build-mac-app` 잡이 dmg 를 릴리스에 첨부합니다.
