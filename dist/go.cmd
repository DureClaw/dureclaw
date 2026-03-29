@echo off
echo [oah] Checking server at oah.local...
curl -sf --max-time 3 "http://oah.local:4000/api/health" >nul 2>&1
if %errorlevel% equ 0 (
    set STATE_SERVER=ws://oah.local:4000
    goto :run
)

echo [oah] Launching server discovery...
set PS1=%TEMP%\oah-connect.ps1
curl -fsSL "https://open-agent-harness.baryon.ai/oah-connect.ps1" -o "%PS1%"
powershell -ExecutionPolicy Bypass -File "%PS1%"
exit /b

:run
set EXE=%USERPROFILE%\.oah-agent.exe
if exist "%EXE%" (
    echo [oah] Starting agent...
) else (
    echo [oah] Downloading agent...
    curl -fsSL "https://open-agent-harness.baryon.ai/oah-agent-windows.exe" -o "%EXE%"
)
"%EXE%"
