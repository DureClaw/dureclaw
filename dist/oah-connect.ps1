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

function Show-Menu($items) {
    $idx = 0
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  OAH  Connect to Server" -ForegroundColor Cyan
        Write-Host "  --------------------------------------" -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($i -eq $idx) {
                Write-Host "  > $($items[$i].Label)" -ForegroundColor Green
            } else {
                Write-Host "    $($items[$i].Label)" -ForegroundColor White
            }
        }
        Write-Host ""
        Write-Host "  [Up/Down] select   [Enter] connect   [Q] quit" -ForegroundColor DarkGray

        $key = [System.Console]::ReadKey($true)
        switch ($key.Key) {
            "UpArrow"   { if ($idx -gt 0) { $idx-- } }
            "DownArrow" { if ($idx -lt $items.Count - 1) { $idx++ } }
            "Enter"     { return $items[$idx] }
            "Q"         { return $null }
        }
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

# ─── OpenCode 설치 (AI 태스크 지원) ──────────────────────────────────────────
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host "  OpenCode 설치 중 (npm)..." -ForegroundColor DarkGray
        npm install -g opencode 2>&1 | Out-Null
        if (Get-Command opencode -ErrorAction SilentlyContinue) {
            Write-Host "  OpenCode 설치 완료 - AI 태스크 활성화" -ForegroundColor Green
            $env:AGENT_BACKEND = "opencode"
        } else {
            Write-Host "  ⚠ OpenCode 설치 실패 - Shell 태스크만 가능" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠ npm 없음 - Shell 태스크만 가능 (Node.js 설치 권장)" -ForegroundColor Yellow
    }
} else {
    $env:AGENT_BACKEND = "opencode"
    Write-Host "  OpenCode: OK" -ForegroundColor DarkGray
}

& $exe
