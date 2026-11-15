param(
    [Parameter(Mandatory = $true)][string]$Cmd,
    [int[]]$Coords = @(),
    [string]$Text = '',
    [string]$Out = ''
)
# 桌面版黑盒验证工具：把"窗口内的截图坐标"换算成 Java 用户空间坐标后调用 UiDrive。
# 用法示例：
#   pwsh -File tools\desktop-ui.ps1 -Cmd click -Coords 70,1290
#   pwsh -File tools\desktop-ui.ps1 -Cmd shot -Out .build\tabs.png
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$jdk = Join-Path $root '.build\toolchain\jdk-17'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DpiUtil {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
try { [DpiUtil]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch {}

$p = Get-Process java, javaw, 'JZ Music' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*JZ Music*' -and $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -notlike '*后台*' -and $_.MainWindowTitle -notlike '*桌面歌词*' } | Select-Object -First 1
if ($p) {
    $h = $p.MainWindowHandle
} else {
    # 主窗口被"桌面歌词"抢了 MainWindowTitle 时，用 FindWindow 按精确标题找
    $h = [DpiUtil]::FindWindow([NullString]::Value, 'JZ Music')
    if ($h -eq [IntPtr]::Zero) { throw '应用窗口没找到（JZ Music）' }
}
$r = New-Object DpiUtil+RECT
[DpiUtil]::GetWindowRect($h, [ref]$r) | Out-Null
$dpi = [DpiUtil]::GetDpiForWindow($h)
if ($dpi -eq 0) { $dpi = 96 }
$scale = $dpi / 96.0
[DpiUtil]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 150

switch ($Cmd) {
    'shot' {
        $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap($w, $hh)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $hh)))
        $g.Dispose(); $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        Write-Host "shot -> $Out (${w}x${hh} @ ${scale}x)"
    }
    default {
        # 截图坐标（窗口内物理像素）→ 屏幕用户空间坐标
        $user = @()
        for ($i = 0; $i -lt $Coords.Count; $i += 2) {
            $sx = ($r.Left + $Coords[$i]) / $scale
            $sy = ($r.Top + $Coords[$i + 1]) / $scale
            $user += [int][math]::Round($sx)
            $user += [int][math]::Round($sy)
        }
        $args2 = @($Cmd) + $user
        if ($Cmd -eq 'key') { $args2 = @($Cmd, $Text) }
        if ($Cmd -eq 'type') { $args2 = @($Cmd, $Text) }
        if ($Cmd -eq 'wheel') { $args2 = @($Cmd, $Coords[0], $Coords[1], $Text) }
        Write-Host ("ui: {0} {1} (scale {2}x)" -f $Cmd, ($args2[1..($args2.Count-1)] -join ' '), $scale)
        & (Join-Path $jdk 'bin\java.exe') (Join-Path $root 'tools\UiDrive.java') @args2
    }
}
