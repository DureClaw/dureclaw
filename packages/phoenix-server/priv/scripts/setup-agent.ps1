# oah-agent — DureClaw Windows Agent Setup (PowerShell)
#
# 사용법 (원라이너):
#   $env:PHOENIX="ws://192.168.1.10:4000"; $env:ROLE="builder"; iex (irm https://dureclaw.baryon.ai/agent.ps1)
#
# 파라미터로도 사용 가능:
#   .\setup-agent.ps1 -Phoenix ws://192.168.1.10:4000 -Role builder

param(
    [string]$Phoenix = $env:PHOENIX,
    [string]$Role    = $(if ($env:ROLE)   { $env:ROLE }   else { "builder" }),
    [string]$Wk      = $env:WK,
    [string]$Name    = $env:NAME,
    [string]$Dir     = $(if ($env:PROJECT_DIR) { $env:PROJECT_DIR } else { $HOME })
)

# UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
try { chcp 65001 | Out-Null } catch {}

$ErrorActionPreference = "Stop"
$OAH_BASE   = "https://open-agent-harness.baryon.ai"
$OAH_DIR    = "$HOME\.oah"
$JS_BUNDLE  = "$HOME\.oah-agent.js"
$OAH_CONFIG = "$OAH_DIR\config"

New-Item -ItemType Directory -Force -Path $OAH_DIR | Out-Null

# ── Discover server ─────────────────────────────────────────────────────────

if (-not $Phoenix) {
    # try oah.local
    try {
        $r = Invoke-RestMethod "http://oah.local:4000/api/health" -TimeoutSec 5
        if ($r.ok) { $Phoenix = "ws://oah.local:4000"; Write-Host "-> connected to oah.local" }
    } catch {}
}

if (-not $Phoenix) {
    Write-Host ""
    Write-Host "PHOENIX address required. Set the server address and re-run:"
    Write-Host "  `$env:PHOENIX=`"ws://<server-ip>:4000`"; iex (irm https://dureclaw.baryon.ai/agent.ps1)"
    Write-Host ""
    Write-Host "Find the server IP on the server (Mac/Linux):"
    Write-Host "  Tailscale: tailscale ip -4      LAN: ipconfig getifaddr en0"
    exit 1
}

$HTTP_BASE = $Phoenix -replace "^ws://","http://" -replace "^wss://","https://"
$HostName  = ([uri]$HTTP_BASE).Host
$HostPort  = ([uri]$HTTP_BASE).Port

# ── Reachability check ────────────────────────────────────────────────────────

Write-Host "-> Checking server: $HTTP_BASE"
$connected = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        $r = Invoke-RestMethod "$HTTP_BASE/api/health" -TimeoutSec 8
        if ($r.ok) { $connected = $true; Write-Host "-> server OK (v$($r.version), $($r.work_keys) work keys)"; break }
    } catch {}
    Write-Host "-> waiting for server... ($i/5)"
    Start-Sleep 2
}
if (-not $connected) {
    Write-Host ""
    Write-Host "FAILED: Phoenix server unreachable at $HTTP_BASE"
    Write-Host ""
    Write-Host "Diagnose on THIS Windows machine:"
    Write-Host "  1) Direct hit  :  irm $HTTP_BASE/api/health"
    Write-Host "  2) TCP reach   :  Test-NetConnection $HostName -Port $HostPort"
    if ($HostName -like "100.*") {
        Write-Host "  3) Tailscale   :  tailscale status   (is THIS PC logged in?)"
        Write-Host "                    tailscale ping $HostName"
        Write-Host "     -> If 'tailscale' is missing/logged-out, install & sign in first:"
        Write-Host "        winget install Tailscale.Tailscale   (then: tailscale up)"
    } else {
        Write-Host "  3) Same network? Server LAN IP must match and port 4000 open."
    }
    Write-Host ""
    Write-Host "Make sure PHOENIX uses the server's CURRENT address (Tailscale IP recommended)."
    exit 1
}

# ── JS 번들 다운로드 ────────────────────────────────────────────────────────────

$NC = (Get-Date -Format "yyyyMMdd")
$JS_URL = "$OAH_BASE/oah-agent.js?nc=$NC"

$needDownload = $true
if (Test-Path $JS_BUNDLE) {
    try {
        $remoteSize = (Invoke-WebRequest $JS_URL -Method Head -UseBasicParsing).Headers["Content-Length"]
        $localSize  = (Get-Item $JS_BUNDLE).Length
        if ($remoteSize -and [long]$remoteSize -eq $localSize) { $needDownload = $false }
    } catch {}
}
if ($needDownload) {
    Write-Host "-> downloading agent (JS)..."
    Invoke-WebRequest $JS_URL -OutFile $JS_BUNDLE -UseBasicParsing
}

# ── Bun 확인 / 설치 ────────────────────────────────────────────────────────────

$env:PATH = "$HOME\.bun\bin;$env:PATH"

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "-> installing Bun..."
    try {
        $bunScript = "$env:TEMP\bun-install.ps1"
        Invoke-RestMethod "https://bun.sh/install.ps1" -OutFile $bunScript
        & $bunScript
        $env:PATH = "$HOME\.bun\bin;$env:PATH"
        Write-Host "Bun $(bun --version) installed"
    } catch {
        Write-Host "[warn] Bun install failed. Trying Node.js..."
    }
}

# Bun 없으면 Node.js 확인
$runtime = $null
if (Get-Command bun -ErrorAction SilentlyContinue) {
    $runtime = "bun"
} elseif (Get-Command node -ErrorAction SilentlyContinue) {
    $runtime = "node"
} else {
    Write-Host ""
    Write-Host "Bun or Node.js is required."
    Write-Host ""
    Write-Host "Install one of:"
    Write-Host "  winget install Oven-sh.Bun    # recommended"
    Write-Host "  winget install OpenJS.NodeJS"
    Write-Host ""
    Write-Host "Then restart the terminal and re-run this command."
    exit 1
}

# ── AI 백엔드 자동 탐지 ────────────────────────────────────────────────────────

$BACKEND = "none"
foreach ($cmd in @("claude", "opencode", "zeroclaw", "aider")) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        $BACKEND = $cmd; break
    }
}

# ── OpenCode 설치 (없으면) ─────────────────────────────────────────────────────

$env:PATH = "$HOME\.opencode\bin;$env:PATH"
if ($BACKEND -eq "none" -and -not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Write-Host "-> installing OpenCode..."
    try {
        iex (irm https://opencode.ai/install.ps1)
        $env:PATH = "$HOME\.opencode\bin;$env:PATH"
        if (Get-Command opencode -ErrorAction SilentlyContinue) { $BACKEND = "opencode" }
    } catch {
        Write-Host "[warn] OpenCode install failed. Only [SHELL] tasks available."
    }
}

# ── 이름 결정 ───────────────────────────────────────────────────────────────────

if (-not $Name) { $Name = "${Role}@$env:COMPUTERNAME" }

# ── config 저장 ────────────────────────────────────────────────────────────────

@"
PHOENIX=$Phoenix
ROLE=$Role
BACKEND=$BACKEND
DIR=$Dir
WK=$Wk
NAME=$Name
"@ | Set-Content $OAH_CONFIG -Encoding UTF8

# ── 배너 출력 ──────────────────────────────────────────────────────────────────

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host " oah-agent  $Name  [Windows/$runtime]"
Write-Host " server  ->  $Phoenix"
Write-Host " backend ->  $BACKEND"
Write-Host " dir     ->  $Dir"
if ($Wk) { Write-Host " work-key->  $Wk" }
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host ""

# ── 에이전트 실행 ──────────────────────────────────────────────────────────────

$env:STATE_SERVER  = $Phoenix
$env:AGENT_NAME    = $Name
$env:AGENT_ROLE    = $Role
$env:AGENT_BACKEND = $BACKEND
$env:WORK_KEY      = $Wk
$env:PROJECT_DIR   = $Dir

& $runtime $JS_BUNDLE
