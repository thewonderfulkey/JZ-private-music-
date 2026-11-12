# 一次性安装模拟器镜像（约 1.5GB，装到 Android SDK 目录；只在首次或换镜像时跑）
#
#   pwsh -File D:\Projects\Private_music\tools\smoke\install-emulator.ps1
param(
    [string]$SystemImage = "system-images;android-34;google_apis;x86_64"
)
$ErrorActionPreference = 'Stop'
$sdk    = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { 'C:\Users\17948\AppData\Local\Android\Sdk' }
$sdkMgr = Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
$jdk    = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.build\toolchain\jdk-17'
if (-not (Test-Path (Join-Path $jdk 'bin\java.exe'))) { $jdk = 'C:\Users\17948\AppData\Local\Programs\jdk-17' }
$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;$env:PATH"

if (-not (Test-Path $sdkMgr)) { throw "sdkmanager 不存在：$sdkMgr" }

Write-Host "==> 接受许可" -ForegroundColor Cyan
("y`n" * 30) | & $sdkMgr --licenses | Out-Null

Write-Host "==> 安装 emulator + $SystemImage（约 1.5GB）" -ForegroundColor Cyan
("y`n" * 30) | & $sdkMgr --install "emulator" $SystemImage
if ($LASTEXITCODE -ne 0) { throw "sdkmanager 安装失败：$LASTEXITCODE" }

Write-Host "==> 完成：$(Join-Path $sdk 'emulator\emulator.exe')" -ForegroundColor Green
