# MeshJoin.ps1 — Windows 노드를 DureClaw 자체 사설망(Headscale)에 합류 / 원래 망으로 복귀
#
#   MeshJoin.ps1 -Code dcj1:...            합류 (Tailscale 이 없으면 공식 MSI 설치)
#   MeshJoin.ps1 -Code dcj1:... -Force     이미 다른 망에 있어도 '새 프로필'로 합류 (기존 프로필 보존)
#   MeshJoin.ps1 -Leave                    -Force 로 옮기기 전의 원래 망으로 복귀
#
# 관리자 권한이 필요하다 (Tailscale 설치·제어). 설치 프로그램은 UAC 확인 후 이 스크립트를 실행한다.
# 결과는 %USERPROFILE%\.dureclaw\mesh\join-result.txt 에도 남긴다 (설치 프로그램이 읽음).
#   종료 코드: 0 성공 · 2 코드 오류 · 3 이미 다른 망(-Force 필요) · 4 Tailscale 설치·합류 실패

param(
    [string]$Code = "",
    [switch]$Force,
    [switch]$Leave,
    [string]$HostName = $env:COMPUTERNAME,
    [string]$ResultFile = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$MeshDir = Join-Path $env:USERPROFILE ".dureclaw\mesh"
New-Item -ItemType Directory -Force -Path $MeshDir | Out-Null
if (-not $ResultFile) { $ResultFile = Join-Path $MeshDir "join-result.txt" }
$PrevFile = Join-Path $MeshDir "previous-profile"

function Finish([int]$exit, [string]$msg, [string]$bus = "") {
    $lines = @("EXIT=$exit", "MESSAGE=$msg")
    if ($bus) { $lines += "PHOENIX=$bus" }
    Set-Content -Path $ResultFile -Value $lines -Encoding UTF8
    Write-Host $msg
    exit $exit
}

function Find-Tailscale {
    $c = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Ts-Json($ts, [string[]]$argv) {
    try { return (& $ts @argv 2>$null | Out-String) | ConvertFrom-Json } catch { return $null }
}

# ── 복귀 ─────────────────────────────────────────────────────────────────────
if ($Leave) {
    $ts = Find-Tailscale
    if (-not $ts) { Finish 4 "Tailscale 클라이언트가 없습니다" }
    if (-not (Test-Path $PrevFile)) { Finish 2 "되돌아갈 망 기록이 없습니다 — 'tailscale switch --list' 에서 ID 를 골라 'tailscale switch <ID>'" }
    $prev = (Get-Content $PrevFile -Encoding UTF8 | Select-Object -First 1).Split("`t")
    & $ts switch $prev[0] | Out-Null
    Remove-Item $PrevFile -Force
    Finish 0 "원래 망으로 돌아갔습니다: $($prev[1])"
}

# ── 코드 해석 ────────────────────────────────────────────────────────────────
if (-not $Code.StartsWith("dcj1:")) { Finish 2 "노드 연결 코드 형식이 아닙니다 (dcj1: 로 시작)" }
try {
    $b64 = $Code.Substring(5).Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) { 2 { $b64 += "==" } 3 { $b64 += "=" } }
    $payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
} catch { Finish 2 "노드 연결 코드를 해석하지 못했습니다" }
$login = $payload.login; $key = $payload.key; $bus = "$($payload.bus)"
if (-not $login -or -not $key) { Finish 2 "코드에 제어 서버 주소나 가입 키가 없습니다" }

# ── Tailscale 클라이언트 (없으면 공식 MSI 무인 설치) ─────────────────────────
$ts = Find-Tailscale
if (-not $ts) {
    Write-Host "Tailscale 클라이언트 설치 중 (오픈소스 공식 클라이언트)…"
    $msi = Join-Path $env:TEMP "tailscale-setup.msi"
    try {
        Invoke-WebRequest "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi" -OutFile $msi -UseBasicParsing
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
        if ($p.ExitCode -ne 0) { Finish 4 "Tailscale 설치 실패 (msiexec $($p.ExitCode))" }
    } catch { Finish 4 "Tailscale 설치 실패: $($_.Exception.Message)" }
    for ($i = 0; $i -lt 30 -and -not (Find-Tailscale); $i++) { Start-Sleep 1 }
    $ts = Find-Tailscale
    if (-not $ts) { Finish 4 "Tailscale 설치 후 실행 파일을 찾지 못했습니다" }
    Start-Sleep 3
}

# ── 지금 상태 ────────────────────────────────────────────────────────────────
$st = Ts-Json $ts @("status", "--json")
$prefs = Ts-Json $ts @("debug", "prefs")
$state = "$($st.BackendState)"; $curUrl = "$($prefs.ControlURL)"; $curNet = "$($st.CurrentTailnet.Name)"
$common = @("--login-server=$login", "--auth-key=$key", "--hostname=$HostName", "--accept-dns=false")

if ($state -eq "Running" -and $curUrl -and $curUrl -ne $login) {
    if (-not $Force) { Finish 3 "이미 다른 사설망($curNet)에 연결돼 있습니다 — 새 프로필로 전환하려면 -Force (기존 망 프로필은 남습니다)" }
    $profiles = Ts-Json $ts @("switch", "--list", "--json")
    $sel = $profiles | Where-Object { $_.selected } | Select-Object -First 1
    if ($sel) { Set-Content -Path $PrevFile -Value "$($sel.id)`t$($sel.tailnet)" -Encoding UTF8 }
    Write-Host "기존 망($curNet)은 프로필로 남겨 두고, 새 프로필로 자체 망에 합류합니다"
    & $ts login @common
} elseif ($state -eq "Running" -and $curUrl -eq $login) {
    Write-Host "이미 이 자체 망에 연결돼 있습니다"
} else {
    & $ts up @common --reset --unattended
}
if ($LASTEXITCODE -ne 0) { Finish 4 "자체 망 합류 실패 (tailscale 종료 코드 $LASTEXITCODE)" }

$ip = $null
for ($i = 0; $i -lt 20; $i++) {
    $ip = (& $ts ip -4 2>$null | Select-Object -First 1)
    if ("$ip".StartsWith("100.")) { break }
    Start-Sleep 1
}
if (-not "$ip".StartsWith("100.")) { Finish 4 "합류 후 사설망 IP 를 받지 못했습니다" }
Finish 0 "자체 망 합류 완료 — 이 PC 의 사설망 IP: $ip" $bus
