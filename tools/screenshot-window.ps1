param(
    [string]$Out = 'D:\Projects\Private_music\.build\shot.png',
    [int]$ProcId = 0
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Cap3 {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
# 设为 Per-Monitor V2 DPI 感知：否则非 DPI 感知进程拿到的是被系统缩放过的窗口坐标，
# 截出来的图会缺一块（本机 125% 缩放，460dp 的窗口实际 575px）
try { [Win32Cap3]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch { try { [Win32Cap3]::SetProcessDpiAwareness(2) | Out-Null } catch {} }
$p = if ($ProcId -gt 0) { Get-Process -Id $ProcId } else {
    Get-Process java,javaw -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
if (-not $p) { Write-Error 'no windowed java process'; exit 1 }
$h = $p.MainWindowHandle
if ($h -eq [IntPtr]::Zero) { Write-Error "process $($p.Id) has no main window"; exit 1 }
[Win32Cap3]::ShowWindow($h, 9) | Out-Null
[Win32Cap3]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800
$r = New-Object Win32Cap3+RECT
[Win32Cap3]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
Write-Host "pid=$($p.Id) title='$($p.MainWindowTitle)' rect=$($r.Left),$($r.Top) ${w}x${hgt}"
$bmp = New-Object System.Drawing.Bitmap($w, $hgt)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $hgt)))
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "saved $Out"
