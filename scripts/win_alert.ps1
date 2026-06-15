# DureClaw — Windows-native alert console
#
# DureClaw 버스(work 채널)에 붙어, Pi Zero 신호등 시그널에 반응해
# Windows 네이티브 기능으로 경보한다:
#   - System.Speech (SAPI) 음성: "Red, stop" / "Yellow, slow" / "Green, go"
#   - [Console]::Beep 시스템 사운드 (색상별 톤)
#   - NotifyIcon 풍선 알림 (Action Center 트레이)
#
# 사용:
#   $env:OAH_SECRET='...'; $env:PHOENIX='ws://100.108.196.12:4000'; $env:WK='WK-2a56b4f1'
#   irm https://dureclaw.baryon.ai/win_alert.ps1 | iex
#   (또는 .\win_alert.ps1)
param(
    [string]$Phoenix = $(if ($env:PHOENIX) { $env:PHOENIX } else { "ws://100.108.196.12:4000" }),
    [string]$Secret  = $env:OAH_SECRET,
    [string]$Wk      = $(if ($env:WK) { $env:WK } else { "WK-2a56b4f1" })
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ── Windows-native: 음성(SAPI) + 트레이 알림 ──
Add-Type -AssemblyName System.Speech
Add-Type -AssemblyName System.Windows.Forms
$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voice.Rate = 1
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Information
$tray.Visible = $true

$SIGNALS = @{
    "RED"    = @{ say = "Red. Stop.";   beep = 300; ico = "Error";   txt = "[정지] 근접 감지" }
    "YELLOW" = @{ say = "Yellow. Slow."; beep = 600; ico = "Warning"; txt = "[서행] 접근 중" }
    "GREEN"  = @{ say = "Green. Go.";   beep = 1000; ico = "Info";    txt = "[통과] 여유" }
}

function Alert($color, $dist) {
    $s = $SIGNALS[$color]; if (-not $s) { return }
    Write-Host ("-> [{0}] {1}cm  (음성+사운드+알림)" -f $color, $dist) -ForegroundColor (@{RED="Red";YELLOW="Yellow";GREEN="Green"}[$color])
    try { [Console]::Beep([int]$s.beep, 220) } catch {}
    try { $voice.SpeakAsync($s.say) | Out-Null } catch {}
    try {
        $tray.BalloonTipIcon  = $s.ico
        $tray.BalloonTipTitle = "DureClaw 신호: $color"
        $tray.BalloonTipText  = ("{0}  ·  거리 {1}cm  ·  sensor@pi-zero" -f $s.txt, $dist)
        $tray.ShowBalloonTip(2500)
    } catch {}
}

# ── DureClaw 버스 연결 (Phoenix WS v2) ──
$ws  = New-Object System.Net.WebSockets.ClientWebSocket
$uri = ($Phoenix -replace '^http', 'ws') + "/socket/websocket?vsn=2.0.0"
if ($Secret) { $uri += "&token=" + [System.Uri]::EscapeDataString($Secret) }
$ct  = [Threading.CancellationToken]::None
Write-Host "-> connecting $uri" -ForegroundColor DarkGray
$ws.ConnectAsync([Uri]$uri, $ct).Wait()

function Send($text) {
    $b = [Text.Encoding]::UTF8.GetBytes($text)
    $seg = New-Object System.ArraySegment[byte] (,$b)
    $ws.SendAsync($seg, 'Text', $true, $ct).Wait()
}
Send ('["1","1","work:' + $Wk + '","phx_join",{"agent_name":"alert@windows","role":"observer"}]')
Write-Host "DureClaw 신호등 경보 콘솔 — work:$Wk 구독 중 (Ctrl+C 종료)" -ForegroundColor Cyan

$buf = New-Object byte[] 16384
$seg = New-Object System.ArraySegment[byte] (,$buf)
$last = ""; $lastHb = Get-Date
$recv = $ws.ReceiveAsync($seg, $ct)
while ($ws.State -eq 'Open') {
    if ($recv.Wait(1500)) {
        $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $recv.Result.Count)
        $recv = $ws.ReceiveAsync($seg, $ct)
        try { $arr = $txt | ConvertFrom-Json } catch { continue }
        if ($arr[3] -ne "task.result") { continue }
        $out = [string]$arr[4].output
        if ($out -match '(\d+(?:\.\d+)?)\s*cm' ) {
            $dist = $matches[1]
            if ($out -match '(RED|YELLOW|GREEN)') {
                $color = $matches[1].ToUpper()
                if ($color -ne $last) { Alert $color $dist; $last = $color }  # 색 변할 때만
            }
        }
    }
    if (((Get-Date) - $lastHb).TotalSeconds -gt 25) {
        try { Send '[null,"h","phoenix","heartbeat",{}]' } catch {}
        $lastHb = Get-Date
    }
}
$tray.Visible = $false
