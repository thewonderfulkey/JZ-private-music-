# JZ Music · Windows 桌面版一键构建（工具链沿用项目内自带，不依赖 C 盘安装）
#
# 用法（在项目任意位置执行都可以，脚本自己算路径）：
#   pwsh -File D:\Projects\Private_music\tools\build-desktop.ps1            # 编译 + 打包便携版
#   pwsh -File D:\Projects\Private_music\tools\build-desktop.ps1 -Run       # 编译后直接跑（开发用）
#   pwsh -File D:\Projects\Private_music\tools\build-desktop.ps1 -Clean     # 先 clean
#   pwsh -File D:\Projects\Private_music\tools\build-desktop.ps1 -Publish   # 产物放进 releases\windows\
#
# 产物：
#   desktop\build\compose\binaries\main\app\JZ Music\JZ Music.exe   （便携版：整个目录一起拷走即可）
#
# 说明：本机没有 WiX，所以不出 `--type exe` 的安装包（jpackage 的安装包依赖 WiX）。
# 便携版目录里的 JZ Music.exe 已经是自带 JRE 的单入口可执行文件，双击即用。
param(
    [switch]$Clean,
    [switch]$Publish,
    [switch]$Run
)

$ErrorActionPreference = 'Stop'

$root        = Split-Path -Parent $PSScriptRoot
$desktopDir  = Join-Path $root 'desktop'
$buildDir    = Join-Path $root '.build'
$jdk         = Join-Path $buildDir 'toolchain\jdk-17'
$gradleHome  = Join-Path $buildDir 'gradle-home'
$gradle      = Join-Path $buildDir 'toolchain\gradle-8.9\bin\gradle.bat'

if (-not (Test-Path (Join-Path $jdk 'bin\java.exe'))) { throw "JDK 17 不可用：$jdk" }
if (-not (Test-Path $gradle))                         { throw "Gradle 8.9 不可用：$gradle" }
if (-not (Test-Path $desktopDir))                     { throw "工程目录不存在：$desktopDir" }
if (-not (Test-Path $gradleHome)) { New-Item -ItemType Directory -Force -Path $gradleHome | Out-Null }

$env:JAVA_HOME        = $jdk
$env:GRADLE_USER_HOME = $gradleHome
$env:PATH             = "$jdk\bin;$env:PATH"

# 版本号：与 Android 工程同源（build.gradle.kts 是唯一事实来源）
$gradleKts   = Join-Path $root 'android\app\build.gradle.kts'
$versionName = (Select-String -LiteralPath $gradleKts -Pattern 'versionName\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value

Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host " 项目根目录 : $root"
Write-Host " 构建目录   : $desktopDir"
Write-Host " 工具链     : $jdk"
Write-Host "              $gradle"
Write-Host " Gradle缓存 : $gradleHome"
Write-Host " 版本       : v$versionName（Windows 桌面版）"
Write-Host '============================================================' -ForegroundColor DarkGray

Push-Location $desktopDir
try {
    if ($Clean) {
        Write-Host '==> gradle clean'
        & $gradle clean --no-daemon
        if ($LASTEXITCODE -ne 0) { throw "gradle clean 失败：$LASTEXITCODE" }
    }

    if ($Run) {
        Write-Host '==> gradle run'
        & $gradle run --no-daemon --console=plain
        if ($LASTEXITCODE -ne 0) { throw "gradle run 失败：$LASTEXITCODE" }
        return
    }

    Write-Host '==> gradle packageAppImage'
    & $gradle packageAppImage --no-daemon --console=plain
    if ($LASTEXITCODE -ne 0) { throw "gradle packageAppImage 失败：$LASTEXITCODE" }

    $appDir = Join-Path $desktopDir 'build\compose\binaries\main\app\JZ Music'
    $exe    = Join-Path $appDir 'JZ Music.exe'
    if (-not (Test-Path $exe)) { throw "未找到产物：$exe" }

    $sum = (Get-ChildItem -LiteralPath $appDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host ''
    Write-Host ("==> EXE  : {0}" -f $exe) -ForegroundColor Green
    Write-Host ("    目录 : {0} （合计 {1:N1} MB）" -f $appDir, ($sum / 1MB)) -ForegroundColor Green

    if ($Publish) {
        $rel = Join-Path $root 'releases\windows'
        New-Item -ItemType Directory -Force -Path $rel | Out-Null
        $zip = Join-Path $rel "JZ Music-v$versionName-windows-x64.zip"
        if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $appDir '*') -DestinationPath $zip -CompressionLevel Optimal
        $mb = (Get-Item -LiteralPath $zip).Length / 1MB
        Write-Host ("==> 已打包: {0} （{1:N1} MB）" -f $zip, $mb) -ForegroundColor Green
    }
}
finally {
    Pop-Location
}
