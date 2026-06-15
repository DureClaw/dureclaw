# DureClaw — 가상 시리얼 포트 제공 + serialplot 피더 (Windows, 관리자 권장)
#
# DureClaw가 가상 COM 쌍(COM9<->COM10)을 직접 만들어 거리 시그널을 흘린다.
# 사용자는 serialplot에서 COM10만 열면 실시간 파형을 본다 — 별도 수동 설정 불필요.
#
#   - com0com 드라이버가 있으면: setupc로 COM9/COM10 쌍 자동 생성
#   - 없으면: winget 설치 시도 → 실패 시 다운로드 링크 안내
#   - 그 뒤 버스(work 채널)에 붙어 거리값을 COM9로 피딩
#
# 실행(관리자 PowerShell 권장 — 가상포트 생성에 필요):
#   $env:OAH_SECRET='...'; $env:PHOENIX='ws://100.108.196.12:4000'; $env:WK='WK-2a56b4f1'
#   powershell -ExecutionPolicy Bypass -File C:\Users\Public\dureclaw\serialplot_setup.ps1
param(
    [string]$Phoenix = $(if ($env:PHOENIX) { $env:PHOENIX } else { "ws://100.108.196.12:4000" }),
    [string]$Secret  = $env:OAH_SECRET,
    [string]$Wk      = $(if ($env:WK) { $env:WK } else { "WK-2a56b4f1" }),
    [string]$Feed    = $(if ($env:FEED) { $env:FEED } else { "COM9" }),   # 피더가 쓰는 포트
    [string]$View    = $(if ($env:VIEW) { $env:VIEW } else { "COM10" }),  # serialplot이 읽는 포트
    [int]   $Baud    = 115200
)
[Console]::OutputEncoding = [System.Text.Encoding]::ASCII
$ErrorActionPreference = "Continue"

function Find-Setupc {
    foreach ($p in @("$env:ProgramFiles\com0com\setupc.exe", "${env:ProgramFiles(x86)}\com0com\setupc.exe")) {
        if (Test-Path $p) { return $p }
    }
    $c = Get-Command setupc.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

# ── 1. 가상 시리얼 포트 제공 (com0com) ──
$setupc = Find-Setupc
if (-not $setupc) {
    Write-Host "-> com0com 미설치. winget 설치 시도..." -ForegroundColor Yellow
    try { winget install --id com0com.com0com --silent --accept-package-agreements --accept-source-agreements 2>$null } catch {}
    $setupc = Find-Setupc
}
if (-not $setupc) {
    Write-Host ""
    Write-Host "[안내] com0com(가상 시리얼 드라이버)이 필요합니다. 1회만 설치하면 됩니다:" -ForegroundColor Cyan
    Write-Host "  https://sourceforge.net/projects/com0com/files/com0com/3.0.0.0/" -ForegroundColor Cyan
    Write-Host "  (i386-and-x64-signed 버전 설치 후 이 스크립트를 다시 실행하세요.)"
    Write-Host "설치 후 DureClaw가 COM 쌍을 자동 생성하고 데이터를 흘립니다."
    exit 1
}
Write-Host "-> com0com: $setupc" -ForegroundColor DarkGray
Write-Host "-> 가상 시리얼 쌍 생성: $Feed <-> $View" -ForegroundColor Cyan
& $setupc install PortName=$Feed PortName=$View 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

# ── 2. 피드 포트 열기 ──
$sp = New-Object System.IO.Ports.SerialPort $Feed, $Baud, 'None', 8, 'One'
try { $sp.Open() } catch { Write-Host "[error] $Feed 열기 실패: $($_.Exception.Message). 관리자 권한으로 재시도하세요." -ForegroundColor Red; exit 1 }
Write-Host ""
Write-Host "===== serialplot에서 다음으로 여세요 =====" -ForegroundColor Green
Write-Host "   Port=$View  Baud=$Baud  1 channel  ASCII/CSV(newline)  -> Open" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# ── 3. DureClaw 버스 연결 → 거리값 피딩 ──
$ws  = New-Object System.Net.WebSockets.ClientWebSocket
$uri = ($Phoenix -replace '^http', 'ws') + "/socket/websocket?vsn=2.0.0"
if ($Secret) { $uri += "&token=" + [System.Uri]::EscapeDataString($Secret) }
$ct  = [Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$uri, $ct).Wait()
function Send($t) { $b=[Text.Encoding]::UTF8.GetBytes($t); $seg=New-Object System.ArraySegment[byte] (,$b); $ws.SendAsync($seg,'Text',$true,$ct).Wait() }
Send ('["1","1","work:' + $Wk + '","phx_join",{"agent_name":"serialfeed@windows","role":"observer"}]')
Write-Host "DureClaw 버스 → $Feed 피딩 시작 (work:$Wk, Ctrl+C 종료)" -ForegroundColor Cyan

$buf = New-Object byte[] 16384; $seg = New-Object System.ArraySegment[byte] (,$buf)
$lastHb = Get-Date; $recv = $ws.ReceiveAsync($seg, $ct)
while ($ws.State -eq 'Open') {
    if ($recv.Wait(1000)) {
        $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $recv.Result.Count)
        $recv = $ws.ReceiveAsync($seg, $ct)
        try { $arr = $txt | ConvertFrom-Json } catch { continue }
        if ($arr[3] -ne "task.result") { continue }
        $out = [string]$arr[4].output
        if ($out -match '(\d+(?:\.\d+)?)\s*cm') { $d=$matches[1]; $sp.WriteLine($d); Write-Host ("  -> {0}" -f $d) }
    }
    if (((Get-Date) - $lastHb).TotalSeconds -gt 25) { try { Send '[null,"h","phoenix","heartbeat",{}]' } catch {}; $lastHb = Get-Date }
}
$sp.Close()
