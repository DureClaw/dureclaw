; DureClaw Agent — Windows 설치 프로그램 (Inno Setup 6)
;
; 터미널(irm ... | iex) 없이 설치 마법사로 Windows 노드를 DureClaw 서버에 연결한다.
;   - 사용자 단위 설치 (관리자 권한 불필요): %LOCALAPPDATA%\Programs\DureClaw
;   - 마법사에서 서버 주소(비우면 자동 탐색)·역할·노드 이름 입력 → %USERPROFILE%\.oah\config
;   - 로그온 시 자동 실행 + 트레이 아이콘 (상태 / 로그 / 다시 연결 / 설정 / 종료)
;
; 빌드 (Windows, 같은 폴더에 oah-agent.exe · DureClaw.exe 준비 후):
;   ISCC.exe /DAppVersion=0.4.4 dureclaw-agent.iss      → Output\DureClaw-Agent-Setup.exe
;
; 무인 설치 (대량 배포):
;   DureClaw-Agent-Setup.exe /VERYSILENT /SERVER=ws://100.64.0.1:4000 /ROLE=builder [/NAME=...] [/BRAIN=http://...]

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

[Setup]
AppId={{6F1C2A57-3D0B-4E8A-9C1E-D0EEC1A7A001}
AppName=DureClaw Agent
AppVersion={#AppVersion}
AppVerName=DureClaw Agent {#AppVersion}
AppPublisher=Baryon Labs
AppPublisherURL=https://dureclaw.baryon.ai
AppSupportURL=https://github.com/DureClaw/dureclaw/issues
DefaultDirName={localappdata}\Programs\DureClaw
DefaultGroupName=DureClaw
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=DureClaw-Agent-Setup
SetupIconFile=dureclaw.ico
UninstallDisplayIcon={app}\DureClaw.exe
UninstallDisplayName=DureClaw Agent
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
#if FileExists(AddBackslash(CompilerPath) + "Languages\Korean.isl")
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
#endif
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "Windows 로그인 시 자동으로 연결 (권장)"; GroupDescription: "시작 옵션:"
Name: "desktopicon"; Description: "바탕화면에 바로가기 만들기"; GroupDescription: "시작 옵션:"; Flags: unchecked

[Files]
Source: "oah-agent.exe";      DestDir: "{app}"; Flags: ignoreversion
Source: "DureClaw.exe";       DestDir: "{app}"; Flags: ignoreversion
Source: "DureClawTray.ps1";   DestDir: "{app}"; Flags: ignoreversion
Source: "dureclaw.ico";       DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\DureClaw Agent";          Filename: "{app}\DureClaw.exe"; IconFilename: "{app}\dureclaw.ico"
Name: "{autoprograms}\DureClaw 로그 폴더";       Filename: "{localappdata}\DureClaw\logs"
Name: "{autoprograms}\DureClaw Agent 제거";      Filename: "{uninstallexe}"
Name: "{autodesktop}\DureClaw Agent";           Filename: "{app}\DureClaw.exe"; IconFilename: "{app}\dureclaw.ico"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "DureClaw Agent"; \
  ValueData: """{app}\DureClaw.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[Dirs]
Name: "{localappdata}\DureClaw\logs"

[Run]
Filename: "{app}\DureClaw.exe"; Description: "지금 DureClaw에 연결"; Flags: postinstall nowait skipifsilent
; 무인 설치에서도 바로 연결
Filename: "{app}\DureClaw.exe"; Flags: nowait; Check: WizardSilent

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\DureClaw\logs"

[Code]
var
  ConnPage: TInputQueryWizardPage;
  ExistingCfg: TStringList;

function ConfigPath(): String;
begin
  Result := ExpandConstant('{%USERPROFILE}\.oah\config');
end;

{ 기존 ~/.oah/config 의 KEY 값 (터미널 설치로 연결했던 PC 면 그대로 이어받는다) }
function CfgValue(Key: String): String;
var
  I, P: Integer;
  Line: String;
begin
  Result := '';
  if ExistingCfg = nil then Exit;
  for I := 0 to ExistingCfg.Count - 1 do
  begin
    Line := ExistingCfg[I];
    P := Pos('=', Line);
    if (P > 0) and (CompareText(Trim(Copy(Line, 1, P - 1)), Key) = 0) then
      Result := Trim(Copy(Line, P + 1, Length(Line)));
  end;
end;

{ 명령행 /KEY=값 이 있으면 우선, 없으면 기존 config 값 }
function ParamOrCfg(Param, Key, Default: String): String;
begin
  Result := ExpandConstant('{param:' + Param + '|}');
  if Result = '' then Result := CfgValue(Key);
  if Result = '' then Result := Default;
end;

function NormalizeServer(S: String): String;
var
  Rest: String;
begin
  S := Trim(S);
  while (Length(S) > 0) and (S[Length(S)] = '/') do S := Copy(S, 1, Length(S) - 1);
  Result := S;
  if S = '' then Exit;
  if Pos('://', S) = 0 then S := 'ws://' + S;
  if Pos('http://', S) = 1 then S := 'ws://' + Copy(S, 8, Length(S));
  if Pos('https://', S) = 1 then S := 'wss://' + Copy(S, 9, Length(S));
  Rest := Copy(S, Pos('://', S) + 3, Length(S));
  if Pos(':', Rest) = 0 then S := S + ':4000';
  Result := S;
end;

function HealthUrl(Server: String): String;
begin
  Result := Server;
  if Pos('ws://', Result) = 1 then Result := 'http://' + Copy(Result, 6, Length(Result));
  if Pos('wss://', Result) = 1 then Result := 'https://' + Copy(Result, 7, Length(Result));
  Result := Result + '/api/health';
end;

function ServerReachable(Server: String): Boolean;
var
  Http: Variant;
begin
  Result := False;
  try
    Http := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Http.SetTimeouts(3000, 3000, 3000, 3000);
    Http.Open('GET', HealthUrl(Server), False);
    Http.Send('');
    Result := (Http.Status = 200);
  except
    Result := False;
  end;
end;

procedure InitializeWizard();
begin
  ExistingCfg := TStringList.Create;
  if FileExists(ConfigPath()) then
    ExistingCfg.LoadFromFile(ConfigPath());

  ConnPage := CreateInputQueryPage(wpSelectTasks,
    'DureClaw 서버 연결',
    '이 PC를 어느 DureClaw 서버(마스터)에 연결할지 정합니다.',
    '서버 주소를 비워 두면 같은 네트워크(oah.local)나 Tailscale에서 자동으로 찾습니다.' + #13#10 +
    '원격 서버라면 이 PC도 Tailscale에 로그인되어 있어야 합니다. 설치 후에도 트레이 아이콘 → 설정에서 바꿀 수 있습니다.');
  ConnPage.Add('서버 주소 (예: ws://100.64.0.1:4000, 비우면 자동 탐색):', False);
  ConnPage.Add('역할 (builder / tester / executor / reviewer ...):', False);
  ConnPage.Add('노드 이름 (비우면 역할@' + GetComputerNameString() + '):', False);
  ConnPage.Add('브레인 URL (선택 — AI 작업을 마스터에 위임할 때):', False);

  ConnPage.Values[0] := ParamOrCfg('SERVER', 'PHOENIX', '');
  ConnPage.Values[1] := ParamOrCfg('ROLE', 'ROLE', 'builder');
  ConnPage.Values[2] := ParamOrCfg('NAME', 'NAME', '');
  ConnPage.Values[3] := ParamOrCfg('BRAIN', 'BRAIN_URL', '');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Server: String;
begin
  Result := True;
  if (ConnPage <> nil) and (CurPageID = ConnPage.ID) then
  begin
    Server := NormalizeServer(ConnPage.Values[0]);
    ConnPage.Values[0] := Server;
    if Trim(ConnPage.Values[1]) = '' then ConnPage.Values[1] := 'builder';
    if (Server <> '') and not ServerReachable(Server) then
      Result := MsgBox('서버에 연결할 수 없습니다:' + #13#10 + HealthUrl(Server) + #13#10#13#10 +
        '주소가 맞는지, 이 PC가 같은 네트워크/Tailscale에 있는지 확인해 주세요.' + #13#10 +
        '그래도 이 주소로 계속 설치할까요? (나중에 서버가 켜지면 자동으로 연결됩니다)',
        mbConfirmation, MB_YESNO) = IDYES;
  end;
end;

{ 실행 중인 트레이·에이전트를 멈춘다 (업그레이드·제거 시).
  이 설치 폴더의 oah-agent.exe 만 종료 — 터미널로 띄운 다른 에이전트는 건드리지 않는다. }
procedure StopRunning();
var
  RC: Integer;
  App: String;
begin
  App := ExpandConstant('{app}');
  if not FileExists(App + '\DureClaw.exe') then Exit;
  Exec(App + '\DureClaw.exe', '-Stop', '', SW_HIDE, ewWaitUntilTerminated, RC);
  Sleep(3500);
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -Command "Get-Process oah-agent -ErrorAction SilentlyContinue | ' +
    'Where-Object { $_.Path -like ''' + App + '\*'' } | Stop-Process -Force"',
    '', SW_HIDE, ewWaitUntilTerminated, RC);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopRunning();
  Result := '';
end;

procedure WriteConfig();
var
  Lines: TArrayOfString;
  Dir: String;
begin
  Dir := ExpandConstant('{%USERPROFILE}\.oah');
  ForceDirectories(Dir);
  SetArrayLength(Lines, 8);
  Lines[0] := 'PHOENIX=' + NormalizeServer(ConnPage.Values[0]);
  Lines[1] := 'ROLE=' + Trim(ConnPage.Values[1]);
  Lines[2] := 'NAME=' + Trim(ConnPage.Values[2]);
  Lines[3] := 'BRAIN_URL=' + Trim(ConnPage.Values[3]);
  { 마법사에 없는 값은 기존 설정 유지 }
  Lines[4] := 'BACKEND=' + CfgValue('BACKEND');
  Lines[5] := 'DIR=' + CfgValue('DIR');
  Lines[6] := 'WK=' + CfgValue('WK');
  Lines[7] := 'OAH_SECRET=' + ParamOrCfg('SECRET', 'OAH_SECRET', '');
  SaveStringsToUTF8File(ConfigPath(), Lines, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then WriteConfig();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then StopRunning();
end;
