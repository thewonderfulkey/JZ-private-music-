# JZ Music · Windows 安装包构建
#
# 产物：releases\windows\JZ Music Setup-<版本>.exe  （双击安装；--silent 可静默安装）
#
#   pwsh -File .\tools\build-setup.ps1                 # 先编译 app-image，再打安装包
#   pwsh -File .\tools\build-setup.ps1 -SkipBuild      # 复用已有 app-image（只重打安装包）
#   pwsh -File .\tools\build-setup.ps1 -Install        # 构建完静默装到 D:\JZ Music
#   pwsh -File .\tools\build-setup.ps1 -Install -InstallDir 'E:\Apps\JZ Music'
#
# 安装包结构：
#   一个 .NET 自解压安装器（csc 编译），内嵌：
#     payload.zip   = jpackage app-image（JZ Music.exe + app\ + runtime\）
#     uninstall.exe = 卸载程序
#     doc_*         = 使用说明 / 更新日志 / 卸载说明 / 常见问题 / 日志说明
#   安装时解到用户选的文件夹，并建好 Download / Log / Cache / Data / Backup / 说明。
param(
    [string]$Version,
    [switch]$SkipBuild,
    [switch]$Install,
    [string]$InstallDir = 'D:\JZ Music',
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$appDir   = Join-Path $root 'desktop\build\compose\binaries\main\app\JZ Music'
$work     = Join-Path $root '.build\setup'
$csc      = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$icon     = Join-Path $root 'desktop\icons\app.ico'
$docsDir  = Join-Path $root 'tools\setup\docs'
$relDir   = Join-Path $root 'releases\windows'

if ([string]::IsNullOrWhiteSpace($Version)) {
    $gradleKts = Join-Path $root 'android\app\build.gradle.kts'
    $Version = (Select-String -LiteralPath $gradleKts -Pattern 'versionName\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
}
if (-not (Test-Path $csc)) { throw "找不到 csc.exe（.NET Framework 4.x 必需）：$csc" }

Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host " 项目根目录 : $root"
Write-Host " 版本       : v$Version"
Write-Host " app-image  : $appDir"
Write-Host " 工作目录   : $work"
Write-Host '============================================================' -ForegroundColor DarkGray

if (-not $SkipBuild) {
    Write-Host '==> gradle packageAppImage（app-image）'
    & (Join-Path $root 'tools\build-desktop.ps1')
    if (-not (Test-Path (Join-Path $appDir 'JZ Music.exe'))) { throw "构建后仍找不到 $appDir\JZ Music.exe" }
}

New-Item -ItemType Directory -Force -Path $work, $relDir | Out-Null

# 1) payload：整份 app-image 压成 zip
$payload = Join-Path $work 'payload.zip'
if (Test-Path $payload) { Remove-Item $payload -Force }
Write-Host '==> 压缩 app-image'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $appDir, $payload, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$payloadMb = (Get-Item $payload).Length / 1MB
Write-Host ("    payload.zip {0:N1} MB" -f $payloadMb)

# 2) 说明文档：拷成 ASCII 文件名再嵌进安装器（csc 的资源 id 只认这个）
$docMap = [ordered]@{
    'doc_readme'    = '使用说明.txt'
    'doc_changelog' = '更新日志.txt'
    'doc_uninstall' = '卸载说明.txt'
    'doc_faq'       = '常见问题.txt'
    'doc_log'       = '日志说明.txt'
}
$docArgs = @()
foreach ($id in $docMap.Keys) {
    $src = Join-Path $docsDir $docMap[$id]
    if (-not (Test-Path $src)) { throw "缺少说明文档：$src" }
    $dst = Join-Path $work "$id.txt"
    Copy-Item $src $dst -Force
    $docArgs += "/resource:$dst,$id"
}

# 3) 卸载程序
Write-Host '==> 编译卸载程序'
$uninstall = Join-Path $work 'uninstall.exe'
if (Test-Path $uninstall) { Remove-Item $uninstall -Force }
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
    "/out:$uninstall" "/win32icon:$icon" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    (Join-Path $root 'tools\setup\Uninstall.cs')
if ($LASTEXITCODE -ne 0) { throw "卸载程序编译失败：$LASTEXITCODE" }

# 4) 安装程序（内嵌 payload + 卸载程序 + 说明文档）
Write-Host '==> 编译安装程序'
$setup = Join-Path $work 'Setup.exe'
if (Test-Path $setup) { Remove-Item $setup -Force }
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
    "/out:$setup" "/win32icon:$icon" `
    "/resource:$payload,payload.zip" `
    "/resource:$uninstall,uninstall.exe" `
    $docArgs `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll `
    (Join-Path $root 'tools\setup\Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "安装程序编译失败：$LASTEXITCODE" }

$out = Join-Path $relDir "JZ Music Setup-$Version.exe"
Copy-Item $setup $out -Force
$mb = (Get-Item $out).Length / 1MB
$hash = (Get-FileHash $out -Algorithm SHA256).Hash
Write-Host ''
Write-Host ("==> 安装包: {0}（{1:N1} MB）" -f $out, $mb) -ForegroundColor Green
Write-Host ("    SHA256: {0}" -f $hash)
Write-Host '    双击安装；静默安装：--silent --dir="D:\JZ Music" --no-launch'

if ($Install) {
    Write-Host ''
    Write-Host "==> 静默安装到 $InstallDir"
    $p = Start-Process -FilePath $out -ArgumentList @('--silent', ('--dir="{0}"' -f $InstallDir)) -PassThru -Wait
    if ($p.ExitCode -ne 0) { throw "安装失败：exit $($p.ExitCode)（见 %TEMP%\jz-music-setup.log）" }
    Get-ChildItem -LiteralPath $InstallDir | Select-Object Mode, Name | Format-Table -AutoSize
    Write-Host "==> 已安装：$InstallDir\JZ Music.exe" -ForegroundColor Green
}

if (-not $KeepWork) {
    Remove-Item $payload -Force -ErrorAction SilentlyContinue
    Remove-Item $setup -Force -ErrorAction SilentlyContinue
    Remove-Item $uninstall -Force -ErrorAction SilentlyContinue
}
