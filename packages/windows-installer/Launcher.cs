// DureClaw.exe — 콘솔 창 없이 DureClawTray.ps1 을 띄우는 얇은 런처.
// 시작 메뉴 / 로그온 자동 실행이 이 exe 를 가리킨다 (VBScript 의존 없음).
//   DureClaw.exe        → 트레이 시작 (이미 떠 있으면 아무것도 안 함)
//   DureClaw.exe -Stop  → 실행 중인 트레이 종료 (제거·업그레이드 시)
//
// 빌드 (Windows 기본 .NET Framework csc):
//   csc /nologo /target:winexe /win32icon:dureclaw.ico /out:DureClaw.exe Launcher.cs
using System;
using System.Diagnostics;
using System.IO;

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "DureClawTray.ps1");
        string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        bool stop = args.Length > 0 && args[0].TrimStart('-', '/').Equals("Stop", StringComparison.OrdinalIgnoreCase);

        var psi = new ProcessStartInfo(powershell,
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"" + (stop ? " -Stop" : ""));
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;

        using (Process p = Process.Start(psi))
        {
            if (stop) p.WaitForExit(10000);
        }
        return 0;
    }
}
