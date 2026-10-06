# DureClaw Agent — Windows 설치 프로그램

터미널(`irm … | iex`) 없이 설치 마법사로 Windows 노드를 DureClaw 서버에 연결합니다.

| 파일 | 역할 |
|------|------|
| `dureclaw-agent.iss` | Inno Setup 6 스크립트 — 마법사(서버·역할·이름·브레인), 사용자 단위 설치, 로그온 자동 실행, 무인 설치 파라미터 |
| `Launcher.cs` | `DureClaw.exe` — 콘솔 창 없이 트레이 스크립트를 띄우는 얇은 런처 (`-Stop` 으로 종료) |
| `DureClawTray.ps1` | 트레이 상주 — 서버 자동 탐색, `oah-agent.exe` 숨김 실행·재시작, 상태/로그/설정 메뉴 |
| `dureclaw.ico` | 아이콘 |

`oah-agent.exe` 는 빌드 시 `packages/agent-daemon` 에서 생성합니다 (`bun build --compile --target=bun-windows-x64`).

## 빌드

CI: 태그 push 시 `.github/workflows/release.yml` 의 `build-windows-installer` 잡이 `DureClaw-Agent-Setup.exe` 를 릴리스에 올립니다.

로컬(Windows):

```powershell
cd packages\agent-daemon; bun install
bun build src/index.ts --compile --target=bun-windows-x64 --outfile=..\windows-installer\oah-agent.exe
cd ..\windows-installer
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /win32icon:dureclaw.ico /out:DureClaw.exe Launcher.cs
ISCC.exe /DAppVersion=0.4.4 dureclaw-agent.iss   # → Output\DureClaw-Agent-Setup.exe
```

`DureClawTray.ps1` · `dureclaw-agent.iss` 는 **UTF-8 BOM** 으로 저장해야 합니다 (Windows PowerShell 5.1 / Inno 한글 깨짐 방지).
