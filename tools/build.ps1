# JZ 音乐助手 · 一键构建脚本
# 用法：
#   pwsh -File .\tools\build.ps1                 # assembleRelease（默认）
#   pwsh -File .\tools\build.ps1 -Task assembleDebug
#   pwsh -File .\tools\build.ps1 -Clean          # 先 clean 再构建
#   pwsh -File .\tools\build.ps1 -Publish        # 构建后复制到 releases\JZ音乐助手-v<版本>.apk
param(
    [string]$Task = 'assembleRelease',
    [switch]$Clean,
    [switch]$Publish
)

$ErrorActionPreference = 'Stop'

$root       = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $root 'android'
$jdk        = 'C:\Users\17948\AppData\Local\Programs\jdk-17'
$gradle     = 'C:\Users\17948\AppData\Local\Programs\gradle-8.9\bin\gradle.bat'

if (-not (Test-Path $jdk))          { throw "JDK 17 未找到：$jdk" }
if (-not (Test-Path $gradle))       { throw "Gradle 8.9 未找到：$gradle" }
if (-not (Test-Path $androidDir))   { throw "工程目录不存在：$androidDir" }

$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;$env:PATH"

# 版本号：从 build.gradle.kts 读取（唯一事实来源）
$gradleKts = Join-Path $androidDir 'app\build.gradle.kts'
$versionName = (Select-String -LiteralPath $gradleKts -Pattern 'versionName\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
$versionCode = (Select-String -LiteralPath $gradleKts -Pattern 'versionCode\s*=\s*(\d+)').Matches[0].Groups[1].Value
Write-Host "==> 构建 $Task  |  v$versionName (vc$versionCode)" -ForegroundColor Cyan

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
    Write-Host ("==> APK: {0}`n    {1:N0} B  MD5 {2}" -f $outApk, $size, $md5) -ForegroundColor Green

    if ($Publish) {
        $rel = Join-Path $root 'releases'
        New-Item -ItemType Directory -Force -Path $rel | Out-Null
        $dst = Join-Path $rel "JZ音乐助手-v$versionName.apk"
        Copy-Item -LiteralPath $outApk -Destination $dst -Force
        Write-Host "==> 已发布到 $dst" -ForegroundColor Green
    }
}
finally {
    Pop-Location
}
