@echo off
:: oah-agent — DureClaw Windows Agent Setup (CMD)
::
:: 사용법 (CMD 원라이너):
::   set PHOENIX=ws://100.x.x.x:4000&& set ROLE=builder&& curl -fsSL https://dureclaw.baryon.ai/agent.bat -o %TEMP%\oah.bat && call %TEMP%\oah.bat
::
:: 또는 직접 실행:
::   setup-agent.bat

chcp 65001 >nul 2>&1

if "%PHOENIX%"=="" (
    echo.
    echo PHOENIX 주소가 필요합니다. 다음과 같이 실행하세요:
    echo   set PHOENIX=ws://^<server-ip^>:4000^&^& set ROLE=builder^&^& call setup-agent.bat
    echo.
    exit /b 1
)

if "%ROLE%"=="" set ROLE=builder
if "%NAME%"=="" set NAME=%ROLE%@%COMPUTERNAME%

set OAH_DIR=%USERPROFILE%\.oah
set JS_BUNDLE=%USERPROFILE%\.oah-agent.js
set OAH_BASE=https://open-agent-harness.baryon.ai
set HTTP_BASE=%PHOENIX:ws://=http://%
set HTTP_BASE=%HTTP_BASE:wss://=https://%

if not exist "%OAH_DIR%" mkdir "%OAH_DIR%"

:: ── 서버 연결 확인 ──────────────────────────────────────────────────────────
echo -^> Phoenix 서버 확인 중...
curl -sf --max-time 5 "%HTTP_BASE%/api/health" >nul 2>&1
if errorlevel 1 (
    echo FAILED: Phoenix server unreachable: %HTTP_BASE%
    echo.
    echo PHOENIX 주소를 확인하세요: %PHOENIX%
    exit /b 1
)
echo -^> 서버 연결됨: %HTTP_BASE%

:: ── JS 번들 다운로드 ────────────────────────────────────────────────────────
if not exist "%JS_BUNDLE%" (
    echo -^> 에이전트(JS^) 다운로드 중...
    curl -fsSL "%OAH_BASE%/oah-agent.js" -o "%JS_BUNDLE%"
) else (
    echo -^> 에이전트 번들 존재 확인됨
)

:: ── 런타임 탐지 (Bun 우선, Node.js 폴백) ───────────────────────────────────
set RUNTIME=
where bun >nul 2>&1 && set RUNTIME=bun
if "%RUNTIME%"=="" where node >nul 2>&1 && set RUNTIME=node

if "%RUNTIME%"=="" (
    echo.
    echo Bun 또는 Node.js 가 필요합니다.
    echo.
    echo 설치 방법 (택1^):
    echo   winget install Oven-sh.Bun
    echo   winget install OpenJS.NodeJS
    echo.
    echo 설치 후 CMD 재시작 -^> 이 명령을 다시 실행하세요.
    exit /b 1
)

:: ── AI 백엔드 탐지 ──────────────────────────────────────────────────────────
set BACKEND=none
where claude    >nul 2>&1 && set BACKEND=claude
if "%BACKEND%"=="none" where opencode >nul 2>&1 && set BACKEND=opencode
if "%BACKEND%"=="none" where zeroclaw >nul 2>&1 && set BACKEND=zeroclaw
if "%BACKEND%"=="none" where aider    >nul 2>&1 && set BACKEND=aider

:: ── config 저장 ────────────────────────────────────────────────────────────
(
echo PHOENIX=%PHOENIX%
echo ROLE=%ROLE%
echo BACKEND=%BACKEND%
echo DIR=%PROJECT_DIR%
echo WK=%WK%
echo NAME=%NAME%
) > "%OAH_DIR%\config"

:: ── 배너 ────────────────────────────────────────────────────────────────────
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo  oah-agent  %NAME%  [Windows/%RUNTIME%]
echo  server  -^>  %PHOENIX%
echo  backend -^>  %BACKEND%
if not "%WK%"=="" echo  work-key-^>  %WK%
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.

:: ── 에이전트 실행 ───────────────────────────────────────────────────────────
set STATE_SERVER=%PHOENIX%
set AGENT_NAME=%NAME%
set AGENT_ROLE=%ROLE%
set AGENT_BACKEND=%BACKEND%
set WORK_KEY=%WK%

%RUNTIME% "%JS_BUNDLE%"
