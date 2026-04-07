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

# ── 서버 자동 탐색 ──────────────────────────────────────────────────────────────

if (-not $Phoenix) {
    # oah.local 시도
    try {
        $r = Invoke-RestMethod "http://oah.local:4000/api/health" -TimeoutSec 3
        if ($r.ok) { $Phoenix = "ws://oah.local:4000"; Write-Host "-> oah.local 연결됨" }
    } catch {}
}

if (-not $Phoenix) {
    Write-Host ""
    Write-Host "PHOENIX 주소가 필요합니다. 서버 IP 를 확인 후 실행하세요:"
    Write-Host "  `$env:PHOENIX=`"ws://<server-ip>:4000`"; iex (irm https://dureclaw.baryon.ai/agent.ps1)"
    Write-Host ""
    Write-Host "서버 IP 확인 (서버 Mac/Linux 에서): ipconfig getifaddr en0"
    exit 1
}

$HTTP_BASE = $Phoenix -replace "^ws://","http://" -replace "^wss://","https://"

# ── 서버 연결 확인 ──────────────────────────────────────────────────────────────

$connected = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        $r = Invoke-RestMethod "$HTTP_BASE/api/health" -TimeoutSec 3
        if ($r.ok) { $connected = $true; break }
    } catch {}
    Write-Host "-> 서버 대기 중... ($i/5)"
    Start-Sleep 2
}
if (-not $connected) {
    Write-Host "FAILED: Phoenix server unreachable: $HTTP_BASE"
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
    Write-Host "-> 에이전트(JS) 다운로드 중..."
    Invoke-WebRequest $JS_URL -OutFile $JS_BUNDLE -UseBasicParsing
}

# ── Bun 확인 / 설치 ────────────────────────────────────────────────────────────

$env:PATH = "$HOME\.bun\bin;$env:PATH"

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "-> Bun 설치 중..."
    try {
        $bunScript = "$env:TEMP\bun-install.ps1"
        Invoke-RestMethod "https://bun.sh/install.ps1" -OutFile $bunScript
        & $bunScript
        $env:PATH = "$HOME\.bun\bin;$env:PATH"
        Write-Host "Bun $(bun --version) 설치 완료"
    } catch {
        Write-Host "⚠ Bun 설치 실패. Node.js 로 시도합니다..."
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
    Write-Host "Bun 또는 Node.js 가 필요합니다."
    Write-Host ""
    Write-Host "설치 방법 (택1):"
    Write-Host "  winget install Oven-sh.Bun    # 권장"
    Write-Host "  winget install OpenJS.NodeJS"
    Write-Host ""
    Write-Host "설치 후 터미널 재시작 → 이 명령을 다시 실행하세요."
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
    Write-Host "-> OpenCode 설치 중..."
    try {
        iex (irm https://opencode.ai/install.ps1)
        $env:PATH = "$HOME\.opencode\bin;$env:PATH"
        if (Get-Command opencode -ErrorAction SilentlyContinue) { $BACKEND = "opencode" }
    } catch {
        Write-Host "⚠ OpenCode 설치 실패. [SHELL] 태스크만 사용 가능."
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
