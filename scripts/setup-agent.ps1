# oah-agent -- open-agent-harness Windows Agent Setup (PowerShell)
# Usage: iex (iwr "http://192.168.219.42:4000/setup.ps1?role=learner-simulator").Content

param(
    [string]$Phoenix = $(if ($env:PHOENIX) { $env:PHOENIX } else { "ws://oah.local:4000" }),
    [string]$Role    = $(if ($env:ROLE) { $env:ROLE } else { "builder" }),
    [string]$Wk      = $(if ($env:WK)   { $env:WK }   else { "" }),
    [string]$Dir     = $(if ($env:DIR)  { $env:DIR }  else { (Get-Location).Path })
)

# UTF-8 output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

$ErrorActionPreference = "Stop"
$OAH_REPO = "https://github.com/baryonlabs/open-agent-harness.git"
$OAH_DIR  = "$env:USERPROFILE\.open-agent-harness"

$HTTP_BASE = $Phoenix -replace "^ws:", "http:" -replace "^wss:", "https:"

Write-Host "======================================="
Write-Host " oah-agent  $Role@$env:COMPUTERNAME"
Write-Host " server  ->  $Phoenix"
Write-Host " dir     ->  $Dir"
Write-Host "======================================="

# --- 1. Bun ---
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "-> Bun installing..."
    $bunInstaller = "$env:TEMP\bun-install.ps1"
    Invoke-RestMethod "https://bun.sh/install.ps1" -OutFile $bunInstaller
    & $bunInstaller
    $env:PATH = "$env:USERPROFILE\.bun\bin;$env:PATH"
}
Write-Host "Bun: $(bun --version)"

# --- 2. OAH repo ---
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$DAEMON_ENTRY = ""

if (Test-Path "$SCRIPT_DIR\..\packages\agent-daemon\src\index.ts") {
    $DAEMON_ENTRY = (Resolve-Path "$SCRIPT_DIR\..\packages\agent-daemon\src\index.ts").Path
} elseif (Test-Path "$OAH_DIR\packages\agent-daemon\src\index.ts") {
    $DAEMON_ENTRY = "$OAH_DIR\packages\agent-daemon\src\index.ts"
} else {
    Write-Host "-> Downloading open-agent-harness..."
    $zipPath = "$env:TEMP\oah.zip"
    Invoke-WebRequest "https://github.com/baryonlabs/open-agent-harness/archive/refs/heads/main.zip" -OutFile $zipPath -UseBasicParsing
    Expand-Archive $zipPath -DestinationPath "$env:TEMP\oah-extract" -Force
    Move-Item "$env:TEMP\oah-extract\open-agent-harness-main" $OAH_DIR
    $DAEMON_ENTRY = "$OAH_DIR\packages\agent-daemon\src\index.ts"
    Set-Location $OAH_DIR
    bun install
}

# --- 4. Phoenix health check ---
Write-Host "-> Checking Phoenix server..."
$connected = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        $resp = Invoke-RestMethod "$HTTP_BASE/api/health" -TimeoutSec 3
        if ($resp.ok) { $connected = $true; break }
    } catch {}
    Write-Host "  waiting... ($i/5)"
    Start-Sleep 2
}
if (-not $connected) {
    Write-Host ""
    Write-Host "FAILED: Cannot reach Phoenix server at $HTTP_BASE"
    Write-Host ""
    Write-Host "oah.local 이 안 된다면 서버 IP 로 직접 지정하세요:"
    Write-Host "  .\setup-agent.ps1 -Phoenix ws://<server-ip>:4000"
    Write-Host ""
    Write-Host "서버 IP 확인 방법 (서버 Mac 에서): ipconfig getifaddr en0"
    exit 1
}
Write-Host "Phoenix OK"

# --- 5. Run agent ---
$NAME = "${Role}@$env:COMPUTERNAME"

$env:STATE_SERVER  = $Phoenix
$env:AGENT_NAME    = $NAME
$env:AGENT_ROLE    = $Role
$env:WORK_KEY      = $Wk
$env:PROJECT_DIR   = $Dir

Write-Host ""
Write-Host ">> Agent starting: $NAME"
Write-Host ""

bun run $DAEMON_ENTRY
