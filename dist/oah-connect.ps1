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
        Write-Host "  ──────────────────────────────────────" -ForegroundColor DarkGray
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
Write-Host ""
Write-Host "  Connecting: $($selected.URL)" -ForegroundColor Cyan

$exe = "$env:USERPROFILE\.oah-agent.exe"
if (-not (Test-Path $exe)) {
    Write-Host "  Downloading agent (~108MB)..." -ForegroundColor DarkGray
    curl.exe -L --progress-bar "https://open-agent-harness.baryon.ai/oah-agent-windows.exe" -o $exe
}

& $exe
