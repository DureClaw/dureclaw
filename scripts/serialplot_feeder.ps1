# DureClaw — serialplot feeder (Windows)
#
# DureClaw 버스(work 채널)에 붙어 Pi 거리 시그널을 추출해 시리얼 포트로 흘린다.
# serialplot(https://github.com/hyOzd/serialplot)이 짝 포트를 읽어 실시간 파형으로 표시.
#
# 사전 준비 (Windows, 1회):
#   1) com0com 설치 → 가상 COM 쌍 생성 (예: COM3 <-> COM4)
#      winget install com0com  (또는 https://sourceforge.net/projects/com0com/)
#   2) serialplot 설치: winget install hyOzd.serialplot  (또는 릴리스 zip)
#   3) serialplot 실행 → Port=COM4, Baud=115200, 1 channel, ASCII/CSV(newline) 설정 → Open
#
# 실행:
#   $env:OAH_SECRET='...'; $env:PHOENIX='ws://100.108.196.12:4000'; $env:WK='WK-2a56b4f1'; $env:COM='COM3'
#   .\serialplot_feeder.ps1
param(
    [string]$Phoenix = $(if ($env:PHOENIX) { $env:PHOENIX } else { "ws://100.108.196.12:4000" }),
    [string]$Secret  = $env:OAH_SECRET,
    [string]$Wk      = $(if ($env:WK)  { $env:WK }  else { "WK-2a56b4f1" }),
    [string]$Com     = $(if ($env:COM) { $env:COM } else { "COM3" }),
    [int]   $Baud    = $(if ($env:BAUD) { [int]$env:BAUD } else { 115200 })
)
[Console]::OutputEncoding = [System.Text.Encoding]::ASCII
$ErrorActionPreference = "Stop"

# ── 시리얼 포트 열기 (serialplot이 짝 포트를 읽음) ──
$sp = New-Object System.IO.Ports.SerialPort $Com, $Baud, 'None', 8, 'One'
try { $sp.Open() } catch { Write-Host "[error] $Com 열기 실패 — com0com 가상 쌍이 있는지 확인: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
Write-Host "-> serialplot feeder: $Com @ $Baud (serialplot은 짝 포트 열기)" -ForegroundColor Cyan

# ── DureClaw 버스 연결 (Phoenix WS v2) ──
$ws  = New-Object System.Net.WebSockets.ClientWebSocket
$uri = ($Phoenix -replace '^http', 'ws') + "/socket/websocket?vsn=2.0.0"
if ($Secret) { $uri += "&token=" + [System.Uri]::EscapeDataString($Secret) }
$ct  = [Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$uri, $ct).Wait()
function Send($t) {
    $b = [Text.Encoding]::UTF8.GetBytes($t); $seg = New-Object System.ArraySegment[byte] (,$b)
    $ws.SendAsync($seg, 'Text', $true, $ct).Wait()
}
Send ('["1","1","work:' + $Wk + '","phx_join",{"agent_name":"serialfeed@windows","role":"observer"}]')
Write-Host "DureClaw → serialplot 피더 시작 (work:$Wk, Ctrl+C 종료)" -ForegroundColor Green

$buf = New-Object byte[] 16384
$seg = New-Object System.ArraySegment[byte] (,$buf)
$lastHb = Get-Date
$recv = $ws.ReceiveAsync($seg, $ct)
while ($ws.State -eq 'Open') {
    if ($recv.Wait(1000)) {
        $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $recv.Result.Count)
        $recv = $ws.ReceiveAsync($seg, $ct)
        try { $arr = $txt | ConvertFrom-Json } catch { continue }
        if ($arr[3] -ne "task.result") { continue }
        $out = [string]$arr[4].output
        if ($out -match '(\d+(?:\.\d+)?)\s*cm') {
            $d = $matches[1]
            $sp.WriteLine($d)               # serialplot이 한 줄=한 샘플로 플롯
            Write-Host ("  -> {0}" -f $d)
        }
    }
    if (((Get-Date) - $lastHb).TotalSeconds -gt 25) { try { Send '[null,"h","phoenix","heartbeat",{}]' } catch {}; $lastHb = Get-Date }
}
$sp.Close()
