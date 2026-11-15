param(
    [string]$Out = 'D:\Projects\Private_music\.build\shot.png'
)
# 直接抓窗口位图（PrintWindow + PW_RENDERFULLCONTENT）：即使窗口被别的程序挡住也能截到，
# 不受"前台窗口抢焦点"影响。
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinShot {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
try { [WinShot]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch {}
$p = Get-Process java, javaw, 'JZ Music' -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like '*JZ Music*' -and $_.MainWindowTitle -notlike '*后台*' -and $_.MainWindowTitle -notlike '*桌面歌词*' -and $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1
if (-not $p) { throw 'app window not found' }
$h = $p.MainWindowHandle
$r = New-Object WinShot+RECT
[WinShot]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap($w, $hh)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# 2 = PW_RENDERFULLCONTENT（含 DirectComposition/Skia 渲染内容）
[WinShot]::PrintWindow($h, $hdc, 2) | Out-Null
$g.ReleaseHdc($hdc)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "printwindow -> $Out (${w}x${hh})"
