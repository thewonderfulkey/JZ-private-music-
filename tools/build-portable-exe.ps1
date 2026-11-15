param(
    [string]$Out = 'D:\Projects\Private_music\releases\windows\JZ Music-2.1.95-portable.exe',
    [switch]$KeepWork
)
# 打一个"单个 exe、双击即用"的便携版：
#   把 jpackage 的 app-image 压成 zip，作为资源嵌进一个 .NET 启动器里。
#   首次运行解包到 %LOCALAPPDATA%\JZ音乐助手\app-<版本>\，之后直接拉起内部 exe（秒开）。
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'desktop\build\compose\binaries\main\app\JZ Music'
$work = Join-Path $root '.build\portable'
$zip = Join-Path $work 'payload.zip'
$launcher = Join-Path $work 'Launcher.exe'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$icon = Join-Path $root 'desktop\icons\app.ico'
$src = Join-Path $root 'tools\portable-launcher\Launcher.cs'

if (-not (Test-Path $appDir)) { throw "先构建 app-image：$appDir 不存在（跑 tools\build-desktop.ps1）" }
if (-not (Test-Path $csc)) { throw "找不到 csc.exe（.NET Framework 4.x 必需）：$csc" }

New-Item -ItemType Directory -Force -Path $work | Out-Null
if (Test-Path $zip) { Remove-Item $zip -Force }
if (Test-Path $launcher) { Remove-Item $launcher -Force }

Write-Host '==> 压缩 app-image'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($appDir, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$zipMb = (Get-Item $zip).Length / 1MB
Write-Host ("    payload.zip {0:N1} MB" -f $zipMb)

# payload 指纹（前 8 位）编进启动器：解包目录 = app-<版本>-<指纹>
# 否则同版本重新打包后，%LOCALAPPDATA% 里已有的旧副本会一直被复用（本次踩到的坑）
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
$stampSrc = Join-Path $work 'PayloadStamp.cs'
Set-Content -Path $stampSrc -Value "internal static class PayloadStamp { public const string Value = `"$hash`"; }" -Encoding UTF8
Write-Host "==> payload 指纹 $hash"

Write-Host '==> 编译启动器（内嵌 payload + 图标）'
$refs = @(
    '/r:System.IO.Compression.dll',
    '/r:System.IO.Compression.FileSystem.dll',
    '/r:System.Windows.Forms.dll'
)
& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
    "/out:$launcher" `
    "/win32icon:$icon" `
    "/resource:$zip,payload.zip" `
    $refs $src $stampSrc
if ($LASTEXITCODE -ne 0) { throw "csc 编译失败：$LASTEXITCODE" }

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
Copy-Item $launcher $Out -Force
$mb = (Get-Item $Out).Length / 1MB
Write-Host ("==> 单文件 exe: {0} （{1:N1} MB）" -f $Out, $mb) -ForegroundColor Green
if (-not $KeepWork) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $launcher -Force -ErrorAction SilentlyContinue
}
