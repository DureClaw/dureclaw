# DureClaw Agent — Windows 트레이 런처 (설치형 노드)
#
# 설치 프로그램(DureClaw-Agent-Setup.exe)이 이 파일을 %LOCALAPPDATA%\Programs\DureClaw 에 두고
# 로그온 시 DureClawTray.vbs → 이 스크립트를 콘솔 창 없이 실행한다.
#
#   - 설정: %USERPROFILE%\.oah\config (KEY=VALUE, setup-agent.ps1 과 같은 형식)
#   - PHOENIX 가 비어 있으면 서버 자동 탐색 (oah.local mDNS → Tailscale 피어 :4000 스캔)
#   - oah-agent.exe 를 숨김 실행하고, 죽으면 백오프 재시작
#   - 로그: %LOCALAPPDATA%\DureClaw\logs\agent.log
#
#   -Stop : 실행 중인 트레이를 종료 (제거 프로그램이 호출)

param([switch]$Stop)

$ErrorActionPreference = "Continue"

$StopEventName = "Local\DureClawAgentStop"
$MutexName     = "Local\DureClawAgentTray"

if ($Stop) {
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting($StopEventName)
        [void]$ev.Set()
    } catch {}
    exit 0
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }   # 이미 실행 중
$stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $StopEventName)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentExe   = Join-Path $AppDir "oah-agent.exe"
$IconPath   = Join-Path $AppDir "dureclaw.ico"
$OahDir     = Join-Path $HOME ".oah"
$ConfigPath = Join-Path $OahDir "config"
$LogDir     = Join-Path $env:LOCALAPPDATA "DureClaw\logs"
$AgentLog   = Join-Path $LogDir "agent.log"
$AgentErr   = Join-Path $LogDir "agent.err.log"
$TrayLog    = Join-Path $LogDir "tray.log"

New-Item -ItemType Directory -Force -Path $OahDir, $LogDir | Out-Null

function Write-TrayLog($msg) {
    try { Add-Content -Path $TrayLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -Encoding UTF8 } catch {}
}

# ── 설정 ──────────────────────────────────────────────────────────────────────

function Read-Config {
    $c = @{ PHOENIX = ""; ROLE = "builder"; NAME = ""; BRAIN_URL = ""; BACKEND = ""; DIR = ""; WK = ""; OAH_SECRET = "" }
    if (Test-Path $ConfigPath) {
        foreach ($line in Get-Content -Path $ConfigPath -Encoding UTF8) {
            if ($line -match '^\s*([A-Za-z_]+)\s*=(.*)$') { $c[$Matches[1].ToUpper()] = $Matches[2].Trim() }
        }
    }
    if (-not $c.ROLE) { $c.ROLE = "builder" }
    return $c
}

function Save-Config($c) {
    $keys = @("PHOENIX", "ROLE", "NAME", "BRAIN_URL", "BACKEND", "DIR", "WK", "OAH_SECRET")
    $lines = foreach ($k in $keys) { "$k=$($c[$k])" }
    Set-Content -Path $ConfigPath -Value $lines -Encoding UTF8
}

# ── 서버 탐색 (setup-agent.ps1 과 동일 규칙) ──────────────────────────────────

function Test-OahServer($base) {
    try {
        $r = Invoke-RestMethod "$base/api/health" -TimeoutSec 2
        if ($r.ok) { return $r }
    } catch {}
    return $null
}

function Normalize-Server($s) {
    $s = $s.Trim().TrimEnd('/')
    if (-not $s) { return "" }
    if ($s -notmatch '^(ws|wss|http|https)://') { $s = "ws://$s" }
    $s = $s -replace '^http://', 'ws://' -replace '^https://', 'wss://'
    if ($s -notmatch '://[^/]+:\d+') { $s = "${s}:4000" }
    return $s
}

function Find-Server {
    $r = Test-OahServer "http://oah.local:4000"
    if ($r) { return "ws://oah.local:4000" }

    $ts = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
    if (-not $ts -and (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) { $ts = "$env:ProgramFiles\Tailscale\tailscale.exe" }
    if (-not $ts) { return "" }
    try {
        $status = (& $ts status --json 2>$null | Out-String) | ConvertFrom-Json
        foreach ($p in $status.Peer.PSObject.Properties.Value) {
            if (-not ($p.Online -and $p.TailscaleIPs)) { continue }
            $v4 = $p.TailscaleIPs | Where-Object { $_ -like "100.*" } | Select-Object -First 1
            if ($v4 -and (Test-OahServer "http://${v4}:4000")) { return "ws://${v4}:4000" }
        }
    } catch {}
    return ""
}

# ── 에이전트 프로세스 ─────────────────────────────────────────────────────────

$script:Proc        = $null
$script:Server      = ""
$script:Backoff     = 5
$script:NextStartAt = [DateTime]::MinValue
$script:Quitting    = $false

function Rotate-Log($path) {
    try {
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) { Move-Item -Force $path "$path.1" }
    } catch {}
}

function Start-Agent {
    $c = Read-Config
    $server = Normalize-Server $c.PHOENIX
    if (-not $server) {
        Set-Status "서버 찾는 중..."
        $server = Find-Server
        if (-not $server) {
            Set-Status "서버를 찾지 못함 — 30초 후 재시도 (설정에서 주소 입력 가능)"
            $script:NextStartAt = (Get-Date).AddSeconds(30)
            return
        }
        Write-TrayLog "discovered server: $server"
    }
    $script:Server = $server

    $role = $c.ROLE
    $name = if ($c.NAME) { $c.NAME } else { "$role@$env:COMPUTERNAME" }
    $backend = if ($c.BACKEND) { $c.BACKEND } elseif ($c.BRAIN_URL) { "remote-pi" } else { "auto" }
    $dir = if ($c.DIR -and (Test-Path $c.DIR)) { $c.DIR } else { $HOME }

    $env:STATE_SERVER  = $server
    $env:AGENT_NAME    = $name
    $env:AGENT_ROLE    = $role
    $env:AGENT_BACKEND = $backend
    $env:PROJECT_DIR   = $dir
    $env:WORK_KEY      = $c.WK
    if ($c.BRAIN_URL)  { $env:BRAIN_URL = $c.BRAIN_URL } else { Remove-Item Env:BRAIN_URL -ErrorAction SilentlyContinue }
    if ($c.OAH_SECRET) { $env:OAH_SECRET = $c.OAH_SECRET } else { Remove-Item Env:OAH_SECRET -ErrorAction SilentlyContinue }

    Rotate-Log $AgentLog
    Rotate-Log $AgentErr
    try {
        $script:Proc = Start-Process -FilePath $AgentExe -WorkingDirectory $dir -WindowStyle Hidden `
            -RedirectStandardOutput $AgentLog -RedirectStandardError $AgentErr -PassThru
        $script:StartedAt = Get-Date
        Write-TrayLog "agent started pid=$($script:Proc.Id) name=$name server=$server backend=$backend"
        Set-Status "연결 중... ($name → $server)"
    } catch {
        Write-TrayLog "agent start failed: $_"
        Set-Status "실행 실패: $($_.Exception.Message)"
        $script:Proc = $null
        $script:NextStartAt = (Get-Date).AddSeconds($script:Backoff)
    }
}

function Stop-Agent {
    if ($script:Proc -and -not $script:Proc.HasExited) {
        try { & taskkill.exe /PID $script:Proc.Id /T /F 2>&1 | Out-Null } catch {}
    }
    $script:Proc = $null
}

function Restart-Agent {
    Stop-Agent
    $script:Backoff = 5
    $script:NextStartAt = [DateTime]::MinValue
    Start-Agent
}

# 로그 끝부분으로 연결 상태 추정 (에이전트가 쓰는 중이라 공유 모드로 읽는다)
function Get-LogState {
    try {
        $fs = [System.IO.File]::Open($AgentLog, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length
            [void]$fs.Seek([Math]::Max(0, $len - 8192), 'Begin')
            $text = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)).ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return "" }
    $joined  = $text.LastIndexOf("[channel] joined")
    $down    = $text.LastIndexOf("disconnected")
    $pending = $text.LastIndexOf("pending operator approval")
    $granted = [Math]::Max($text.LastIndexOf("approved — token granted"), $joined)
    if ($pending -ge 0 -and $pending -gt $granted) { return "pending" }
    if ($joined -ge 0 -and $joined -gt $down) { return "joined" }
    if ($down -ge 0) { return "reconnecting" }
    return ""
}

# ── 트레이 UI ─────────────────────────────────────────────────────────────────

$tray = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path $IconPath) { $tray.Icon = New-Object System.Drawing.Icon($IconPath) } else { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Text = "DureClaw Agent"
$tray.Visible = $true

$menu       = New-Object System.Windows.Forms.ContextMenuStrip
$miStatus   = $menu.Items.Add("시작 중...")
$miStatus.Enabled = $false
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miDash     = $menu.Items.Add("대시보드 열기")
$miLog      = $menu.Items.Add("로그 보기")
$miRestart  = $menu.Items.Add("다시 연결")
$miSettings = $menu.Items.Add("설정...")
$miLeave    = $menu.Items.Add("원래 망으로 돌아가기 (자체 망 해제)")
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit     = $menu.Items.Add("종료 (연결 끊기)")
$tray.ContextMenuStrip = $menu

$script:LastStatus = ""
function Set-Status($text) {
    if ($text -eq $script:LastStatus) { return }
    $script:LastStatus = $text
    $miStatus.Text = $text
    # NotifyIcon.Text 는 63자 제한
    $tip = "DureClaw — $text"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + "..." }
    $tray.Text = $tip
}

function Show-Settings {
    $c = Read-Config
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "DureClaw Agent 설정"
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(460, 300)
    $f.Font = New-Object System.Drawing.Font("Malgun Gothic", 9)
    if (Test-Path $IconPath) { $f.Icon = $tray.Icon }

    $fields = @(
        @{ Key = "PHOENIX";   Label = "서버 주소";    Hint = "비우면 자동 탐색 (예: ws://100.x.x.x:4000)" },
        @{ Key = "ROLE";      Label = "역할";         Hint = "builder / tester / executor / reviewer ..." },
        @{ Key = "NAME";      Label = "노드 이름";    Hint = "비우면 역할@$env:COMPUTERNAME" },
        @{ Key = "BRAIN_URL"; Label = "브레인 URL";   Hint = "AI 작업을 마스터에 위임할 때만 (선택)" },
        @{ Key = "DIR";       Label = "작업 폴더";    Hint = "비우면 $HOME" }
    )
    $boxes = @{}
    $y = 14
    foreach ($fd in $fields) {
        $lb = New-Object System.Windows.Forms.Label
        $lb.Text = $fd.Label; $lb.Location = New-Object System.Drawing.Point(14, ($y + 3)); $lb.Size = New-Object System.Drawing.Size(80, 20)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Text = $c[$fd.Key]; $tb.Location = New-Object System.Drawing.Point(100, $y); $tb.Size = New-Object System.Drawing.Size(345, 22)
        $hn = New-Object System.Windows.Forms.Label
        $hn.Text = $fd.Hint; $hn.ForeColor = [System.Drawing.Color]::Gray
        $hn.Location = New-Object System.Drawing.Point(100, ($y + 24)); $hn.Size = New-Object System.Drawing.Size(345, 16)
        $f.Controls.AddRange(@($lb, $tb, $hn))
        $boxes[$fd.Key] = $tb
        $y += 50
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "저장 후 다시 연결"; $ok.Size = New-Object System.Drawing.Size(130, 28)
    $ok.Location = New-Object System.Drawing.Point(224, 262); $ok.DialogResult = 'OK'
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "취소"; $cancel.Size = New-Object System.Drawing.Size(85, 28)
    $cancel.Location = New-Object System.Drawing.Point(360, 262); $cancel.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($ok, $cancel))
    $f.AcceptButton = $ok; $f.CancelButton = $cancel

    if ($f.ShowDialog() -eq 'OK') {
        foreach ($k in $boxes.Keys) { $c[$k] = $boxes[$k].Text.Trim() }
        if ($c.PHOENIX) { $c.PHOENIX = Normalize-Server $c.PHOENIX }
        if (-not $c.ROLE) { $c.ROLE = "builder" }
        Save-Config $c
        Write-TrayLog "settings saved (server=$($c.PHOENIX) role=$($c.ROLE))"
        Restart-Agent
    }
    $f.Dispose()
}

function Quit-Tray {
    if ($script:Quitting) { return }
    $script:Quitting = $true
    $timer.Stop()
    Stop-Agent
    $tray.Visible = $false
    $tray.Dispose()
    Write-TrayLog "tray exit"
    [System.Windows.Forms.Application]::Exit()
}

$miLog.add_Click({ if (Test-Path $AgentLog) { Start-Process notepad.exe $AgentLog } else { Start-Process explorer.exe $LogDir } })
$miRestart.add_Click({ Restart-Agent })
$miSettings.add_Click({ Show-Settings })
$miLeave.add_Click({
    # 자체 사설망 합류 전의 Tailscale 프로필로 복귀 (관리자 권한 필요 → UAC)
    $script = Join-Path $AppDir "MeshJoin.ps1"
    $result = Join-Path $env:USERPROFILE ".dureclaw\mesh\join-result.txt"
    try {
        $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Leave -ResultFile `"$result`""
        $msg = (Get-Content $result -Encoding UTF8 | Where-Object { $_ -like "MESSAGE=*" }) -replace '^MESSAGE=', ''
        $tray.ShowBalloonTip(5000, "DureClaw", "$msg", [System.Windows.Forms.ToolTipIcon]::Info)
        Write-TrayLog "leave mesh: exit=$($p.ExitCode) $msg"
    } catch { Write-TrayLog "leave mesh cancelled: $_" }
})
$miQuit.add_Click({ Quit-Tray })
$miDash.add_Click({
    if ($script:Server) {
        $http = $script:Server -replace '^ws://', 'http://' -replace '^wss://', 'https://'
        Start-Process $http
    }
})
$tray.add_DoubleClick({ Show-Settings })

# ── 감시 루프 ─────────────────────────────────────────────────────────────────

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({
    if ($stopEvent.WaitOne(0)) { Quit-Tray; return }

    if ($script:Proc -and $script:Proc.HasExited) {
        $code = $script:Proc.ExitCode
        $uptime = ((Get-Date) - $script:StartedAt).TotalSeconds
        Write-TrayLog "agent exited code=$code uptime=$([int]$uptime)s"
        $script:Proc = $null
        # 오래 살아 있었으면 백오프 초기화, 바로 죽으면 늘린다 (최대 60초)
        if ($uptime -gt 60) { $script:Backoff = 5 } else { $script:Backoff = [Math]::Min(60, $script:Backoff * 2) }
        $script:NextStartAt = (Get-Date).AddSeconds($script:Backoff)
        Set-Status "에이전트 종료됨 (코드 $code) — $($script:Backoff)초 후 재시작"
        return
    }

    if (-not $script:Proc) {
        if ((Get-Date) -ge $script:NextStartAt) { Start-Agent }
        return
    }

    $name = $env:AGENT_NAME
    switch (Get-LogState) {
        "joined"       { Set-Status "연결됨 — $name" }
        "pending"      { Set-Status "운영자 승인 대기 중 — $name" }
        "reconnecting" { Set-Status "재연결 중... ($($script:Server))" }
    }
})

if (-not (Test-Path $AgentExe)) {
    [System.Windows.Forms.MessageBox]::Show("oah-agent.exe 를 찾을 수 없습니다.`n$AgentExe`n`n설치 프로그램을 다시 실행해 주세요.", "DureClaw Agent") | Out-Null
    $tray.Dispose()
    exit 1
}

Write-TrayLog "tray start (app=$AppDir)"
Start-Agent
$timer.Start()
[System.Windows.Forms.Application]::Run()

$mutex.ReleaseMutex()
