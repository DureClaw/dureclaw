@echo off
set STATE_SERVER=ws://oah.local:4000

echo [oah] Checking server at oah.local...
curl -sf --max-time 3 "http://oah.local:4000/api/health" >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo FAILED: Cannot reach oah.local:4000
    echo.
    echo oah.local is not supported on Windows without Bonjour.
    echo Please run with the server IP instead:
    echo.
    echo   set STATE_SERVER=ws://^<server-ip^>:4000
    echo   curl -fsSL https://open-agent-harness.baryon.ai/go.cmd -o go.cmd ^&^& go.cmd
    echo.
    echo To find server IP, run on the server Mac: ipconfig getifaddr en0
    echo.
    pause
    exit /b 1
)

echo [oah] Downloading agent...
curl -fsSL "https://open-agent-harness.baryon.ai/oah-agent-windows.exe" -o "%TEMP%\oah-agent.exe"
echo [oah] Starting...
"%TEMP%\oah-agent.exe"
