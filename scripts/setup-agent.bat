@echo off
chcp 65001 >nul 2>&1
setlocal EnableDelayedExpansion

REM oah-agent - DureClaw Windows Agent (CMD)
REM Usage:
REM   set PHOENIX=ws://SERVER:4000&& set ROLE=builder&& curl -fsSL https://open-agent-harness.baryon.ai/agent.bat -o %TEMP%\oah.bat && call %TEMP%\oah.bat

if "%PHOENIX%"=="" (
    echo.
    echo ERROR: PHOENIX address required.
    echo   set PHOENIX=ws://SERVER:4000^&^& set ROLE=builder^&^& call setup-agent.bat
    echo.
    exit /b 1
)

if "%ROLE%"=="" set ROLE=builder
if "%NAME%"=="" set NAME=%ROLE%@%COMPUTERNAME%
if "%PROJECT_DIR%"=="" set PROJECT_DIR=%USERPROFILE%

set OAH_DIR=%USERPROFILE%\.oah
set JS_BUNDLE=%USERPROFILE%\.oah-agent.js
set OAH_BASE=https://open-agent-harness.baryon.ai

set HTTP_BASE=%PHOENIX%
set HTTP_BASE=!HTTP_BASE:ws://=http://!
set HTTP_BASE=!HTTP_BASE:wss://=https://!

if not exist "%OAH_DIR%" mkdir "%OAH_DIR%"

REM -- Check Phoenix server --
echo [1/4] Checking Phoenix server...
curl -sf --max-time 5 "!HTTP_BASE!/api/health" >nul 2>&1
if errorlevel 1 (
    echo FAILED: Cannot reach !HTTP_BASE!
    exit /b 1
)
echo       OK: !HTTP_BASE!

REM -- Download JS bundle --
echo [2/4] Checking agent bundle...
if not exist "%JS_BUNDLE%" (
    echo       Downloading...
    curl -fsSL "%OAH_BASE%/oah-agent.js" -o "%JS_BUNDLE%"
) else (
    echo       Already exists.
)

REM -- Detect runtime --
echo [3/4] Detecting runtime...
set RUNTIME=
where bun >nul 2>&1
if not errorlevel 1 (
    set RUNTIME=bun
    goto :runtime_found
)
where node >nul 2>&1
if not errorlevel 1 (
    set RUNTIME=node
    goto :runtime_found
)

echo.
echo ERROR: Bun or Node.js required.
echo   winget install Oven-sh.Bun
echo   winget install OpenJS.NodeJS
echo.
exit /b 1

:runtime_found
echo       Runtime: %RUNTIME%

REM -- Detect AI backend --
echo [4/4] Detecting AI backend...
set BACKEND=none
where claude >nul 2>&1 && set BACKEND=claude
if "%BACKEND%"=="none" where opencode >nul 2>&1 && set BACKEND=opencode
if "%BACKEND%"=="none" where zeroclaw >nul 2>&1 && set BACKEND=zeroclaw
if "%BACKEND%"=="none" where aider    >nul 2>&1 && set BACKEND=aider
echo       Backend: %BACKEND%

REM -- Save config --
(
echo PHOENIX=%PHOENIX%
echo ROLE=%ROLE%
echo BACKEND=%BACKEND%
echo WK=%WK%
echo NAME=%NAME%
) > "%OAH_DIR%\config"

REM -- Banner --
echo.
echo ========================================
echo  oah-agent  %NAME%  [Windows/%RUNTIME%]
echo  server  ->  %PHOENIX%
echo  backend ->  %BACKEND%
if not "%WK%"=="" echo  work-key->  %WK%
echo ========================================
echo.

REM -- Run agent --
set STATE_SERVER=%PHOENIX%
set AGENT_NAME=%NAME%
set AGENT_ROLE=%ROLE%
set AGENT_BACKEND=%BACKEND%
set WORK_KEY=%WK%

%RUNTIME% "%JS_BUNDLE%"
