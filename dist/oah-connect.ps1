# oah-connect.ps1 — OAH Server Connect (Tailscale TUI)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

function Find-Tailscale {
    $candidates = @(
        "tailscale",
        "tailscale.exe",
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "$env:ProgramFiles(x86)\Tailscale\tailscale.exe",
        "$env:LOCALAPPDATA\Tailscale\tailscale.exe"
    )
    foreach ($c in $candidates) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { return $c }
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-TailscalePeers {
    $ts = Find-Tailscale
    if (-not $ts) {
        Write-Host "  Tailscale not found." -ForegroundColor Yellow
        return @()
    }

    $peers = @()
    try {
        $json = & $ts status --json 2>$null | Out-String
        $data = $json | ConvertFrom-Json
        foreach ($key in $data.Peer.PSObject.Properties.Name) {
            $peer = $data.Peer.$key
            if ($peer.Online -eq $true) {
                $ip       = $peer.TailscaleIPs[0]
                $peerHost = $peer.HostName
                $peers += [PSCustomObject]@{ Label = "$peerHost  [$ip]"; URL = "ws://${ip}:4000" }
            }
        }
    } catch {}
    return $peers
}

# 번호 입력 폴백 — iex 파이프 등 비대화형/화면깨짐 환경에서 항상 동작.
function Read-MenuFallback($items) {
    Write-Host ""
    Write-Host "  OAH  Connect to Server" -ForegroundColor Cyan
    Write-Host "  --------------------------------------" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $items[$i].Label)
    }
    Write-Host ""
    while ($true) {
        $sel = Read-Host "  번호 선택 (1-$($items.Count)), q=종료"
        if ($sel -match '^[Qq]$') { return $null }
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $items.Count) {
            return $items[[int]$sel - 1]
        }
        Write-Host "  올바른 번호를 입력하세요." -ForegroundColor Yellow
    }
}

function Show-Menu($items) {
    # 입력이 리다이렉트된(iex 파이프) 환경에서는 화살표 메뉴가 깨지므로 번호 입력으로.
    try { if ([Console]::IsInputRedirected) { return (Read-MenuFallback $items) } } catch { return (Read-MenuFallback $items) }

    try {
        $idx = 0
        while ($true) {
            Clear-Host
            Write-Host ""
            Write-Host "  OAH  Connect to Server" -ForegroundColor Cyan
            Write-Host "  --------------------------------------" -ForegroundColor DarkGray
            Write-Host ""
            for ($i = 0; $i -lt $items.Count; $i++) {
                $n = $i + 1
                if ($i -eq $idx) {
                    Write-Host ("  [{0}] > {1}" -f $n, $items[$i].Label) -ForegroundColor Green
                } else {
                    Write-Host ("  [{0}]   {1}" -f $n, $items[$i].Label) -ForegroundColor White
                }
            }
            Write-Host ""
            Write-Host "  [1-9] 번호   [Up/Down] 이동   [Enter] 연결   [Q] 종료" -ForegroundColor DarkGray

            $key = [System.Console]::ReadKey($true)
            # 숫자 키 → 즉시 선택·연결
            $ch = $key.KeyChar
            if ($ch -ge '1' -and $ch -le '9') {
                $n = [int]::Parse($ch)
                if ($n -ge 1 -and $n -le $items.Count) { return $items[$n - 1] }
            }
            switch ($key.Key) {
                "UpArrow"   { if ($idx -gt 0) { $idx-- } }
                "DownArrow" { if ($idx -lt $items.Count - 1) { $idx++ } }
                "Enter"     { return $items[$idx] }
                "Q"         { return $null }
            }
        }
    } catch {
        # 실제 콘솔이 아니면 ReadKey가 실패 → 번호 입력으로 폴백
        return (Read-MenuFallback $items)
    }
}

# ─── Main ─────────────────────────────────────────────────────────────────────

$peers = Get-TailscalePeers

if ($peers.Count -eq 0) {
    Write-Host ""
    Write-Host "  No Tailscale peers found." -ForegroundColor Yellow
    Write-Host ""
    # Debug: show raw tailscale output
    $ts = Find-Tailscale
    if ($ts) {
        Write-Host "  tailscale status:" -ForegroundColor DarkGray
        & $ts status 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host ""
    pause
    exit 1
}

$selected = Show-Menu $peers
if ($null -eq $selected) { exit 0 }

$env:STATE_SERVER = $selected.URL
if (-not $env:AGENT_ROLE) { $env:AGENT_ROLE = "builder" }
Write-Host ""
Write-Host "  Connecting: $($selected.URL)" -ForegroundColor Cyan

$exe       = "$env:USERPROFILE\.oah-agent.exe"
$baseUrl   = "https://open-agent-harness.baryon.ai/oah-agent-windows.exe"
$ncDate    = (Get-Date -Format "yyyyMMdd")
$exeUrl    = "${baseUrl}?nc=${ncDate}"   # CDN 캐시 우회 (날짜별 fresh)

if (-not (Test-Path $exe)) {
    Write-Host "  Downloading agent..." -ForegroundColor DarkGray
    curl.exe -L --progress-bar $exeUrl -o $exe
} else {
    try {
        $remoteSize = (Invoke-WebRequest -Uri $exeUrl -Method Head -UseBasicParsing -TimeoutSec 5).Headers.'Content-Length'
        $localSize  = (Get-Item $exe).Length
        if ($remoteSize -and [long]$remoteSize -ne $localSize) {
            Write-Host "  Updating agent..." -ForegroundColor DarkGray
            curl.exe -L --progress-bar $exeUrl -o $exe
        }
    } catch {}
}

# ─── pi coding agent 설치 (AI 태스크 지원) ───────────────────────────────────
if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host "  pi coding agent 설치 중 (npm)..." -ForegroundColor DarkGray
        npm install -g --ignore-scripts @earendil-works/pi-coding-agent 2>&1 | Out-Null
        if (Get-Command pi -ErrorAction SilentlyContinue) {
            Write-Host "  pi 설치 완료 - AI 태스크 활성화" -ForegroundColor Green
            $env:AGENT_BACKEND = "pi"
        } else {
            Write-Host "  ⚠ pi 설치 실패 - Shell 태스크만 가능" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠ npm 없음 - Shell 태스크만 가능 (Node.js 설치 권장)" -ForegroundColor Yellow
    }
} else {
    $env:AGENT_BACKEND = "pi"
    Write-Host "  pi: OK" -ForegroundColor DarkGray
}

& $exe
