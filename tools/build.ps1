# JZ 音乐助手 · 一键构建脚本（工具链自带，不依赖 C 盘安装路径）
#
# 用法（在项目任意位置执行都可以，脚本自己算路径）：
#   pwsh -File D:\Projects\Private_music\tools\build.ps1                 # assembleRelease
#   pwsh -File D:\Projects\Private_music\tools\build.ps1 -Task assembleDebug
#   pwsh -File D:\Projects\Private_music\tools\build.ps1 -Clean          # 先 clean
#   pwsh -File D:\Projects\Private_music\tools\build.ps1 -Publish        # 出包后放进 releases\
#
# 工具链位置（全部在项目内）：
#   .build\toolchain\jdk-17         JDK 17
#   .build\toolchain\gradle-8.9     Gradle 8.9
#   .build\gradle-home              GRADLE_USER_HOME（依赖缓存，离线可编）
param(
    [string]$Task = 'assembleRelease',
    [switch]$Clean,
    [switch]$Publish
)

$ErrorActionPreference = 'Stop'

$root       = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $root 'android'
$buildDir   = Join-Path $root '.build'
$jdk        = Join-Path $buildDir 'toolchain\jdk-17'
$gradleHome = Join-Path $buildDir 'gradle-home'
$gradle     = Join-Path $buildDir 'toolchain\gradle-8.9\bin\gradle.bat'

# 兜底：项目内没带工具链时，退回本机安装位置（并提示）
if (-not (Test-Path $jdk)) {
    $jdk = 'C:\Users\17948\AppData\Local\Programs\jdk-17'
    Write-Host "!! 项目内未找到 JDK，改用 $jdk" -ForegroundColor Yellow
}
if (-not (Test-Path $gradle)) {
    $gradle = 'C:\Users\17948\AppData\Local\Programs\gradle-8.9\bin\gradle.bat'
    Write-Host "!! 项目内未找到 Gradle，改用 $gradle" -ForegroundColor Yellow
}
if (-not (Test-Path $gradleHome)) { New-Item -ItemType Directory -Force -Path $gradleHome | Out-Null }

if (-not (Test-Path (Join-Path $jdk 'bin\java.exe'))) { throw "JDK 17 不可用：$jdk" }
if (-not (Test-Path $gradle))                        { throw "Gradle 8.9 不可用：$gradle" }
if (-not (Test-Path $androidDir))                    { throw "工程目录不存在：$androidDir" }

$env:JAVA_HOME        = $jdk
$env:GRADLE_USER_HOME = $gradleHome
$env:PATH             = "$jdk\bin;$env:PATH"

# 版本号：从 build.gradle.kts 读取（唯一事实来源）
$gradleKts   = Join-Path $androidDir 'app\build.gradle.kts'
$versionName = (Select-String -LiteralPath $gradleKts -Pattern 'versionName\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
$versionCode = (Select-String -LiteralPath $gradleKts -Pattern 'versionCode\s*=\s*(\d+)').Matches[0].Groups[1].Value

Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host " 项目根目录 : $root"
Write-Host " 构建目录   : $androidDir"
Write-Host " 工具链     : $jdk"
Write-Host "              $gradle"
Write-Host " Gradle缓存 : $gradleHome"
Write-Host " 版本       : v$versionName (vc$versionCode) / 任务 $Task"
Write-Host '============================================================' -ForegroundColor DarkGray

Push-Location $androidDir
try {
    if ($Clean) {
        Write-Host '==> gradle clean'
        & $gradle clean --no-daemon
        if ($LASTEXITCODE -ne 0) { throw "gradle clean 失败：$LASTEXITCODE" }
    }
    & $gradle ":app:$Task" --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "gradle $Task 失败：$LASTEXITCODE" }

    $outApk = Join-Path $androidDir 'app\build\outputs\apk\release\app-release.apk'
    if (-not (Test-Path $outApk)) {
        $outApk = Get-ChildItem -Path (Join-Path $androidDir 'app\build\outputs\apk') -Recurse -Filter '*.apk' |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $outApk) { throw '未找到构建产物 APK' }

    $size = (Get-Item -LiteralPath $outApk).Length
    $md5  = (Get-FileHash -LiteralPath $outApk -Algorithm MD5).Hash
    Write-Host ''
    Write-Host ("==> APK  : {0}" -f $outApk) -ForegroundColor Green
    Write-Host ("    size : {0:N0} B" -f $size) -ForegroundColor Green
    Write-Host ("    md5  : {0}" -f $md5) -ForegroundColor Green

    if ($Publish) {
        $rel = Join-Path $root 'releases'
        New-Item -ItemType Directory -Force -Path $rel | Out-Null
        $dst = Join-Path $rel "JZ音乐助手-v$versionName.apk"
        Copy-Item -LiteralPath $outApk -Destination $dst -Force
        Write-Host "==> 已复制到 $dst" -ForegroundColor Green
    }
}
finally {
    Pop-Location
}
