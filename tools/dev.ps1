# JZ 音乐助手 · 一条命令跑完「构建 → 静态验证 → 模拟器冒烟 → 飞书通知」
#
#   cd D:\Projects\Private_music
#   pwsh -File .\tools\dev.ps1                 # 完整流程
#   pwsh -File .\tools\dev.ps1 -SkipSmoke      # 只构建+验证，不启模拟器
#   pwsh -File .\tools\dev.ps1 -SkipNotify     # 不往飞书发
#   pwsh -File .\tools\dev.ps1 -Note "修了识曲取消"   # 追加一句到飞书消息
#
# 退出码：0 = 全通过；1 = 构建/验证/冒烟任一失败（失败会自动发飞书）
param(
    [string]$Task = 'assembleRelease',
    [switch]$Clean,
    [switch]$SkipSmoke,
    [switch]$SkipNotify,
    [switch]$KeepEmulator,
    [string]$Note = ""
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gradleKts = Join-Path $root 'android\app\build.gradle.kts'
$versionName = (Select-String -LiteralPath $gradleKts -Pattern 'versionName\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
$versionCode = (Select-String -LiteralPath $gradleKts -Pattern 'versionCode\s*=\s*(\d+)').Matches[0].Groups[1].Value
$apk = Join-Path $root 'android\app\build\outputs\apk\release\app-release.apk'
$relApk = Join-Path $root "releases\JZ音乐助手-v$versionName.apk"

function Notify($title, $body, [switch]$Fail) {
    if ($SkipNotify) { return }
    $larkArgs = @('tools\notify\lark.py', '--title', $title, '--body', $body)
    if ($Fail) { $larkArgs += '--fail' }
    if (Test-Path $apk) { $larkArgs += @('--apk', (Resolve-Path $apk).Path) }
    Push-Location $root
    try { & python @larkArgs } finally { Pop-Location }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host " 目录   : $root"
Write-Host " 版本   : v$versionName (vc$versionCode)"
Write-Host " 流程   : 构建$(if(-not $SkipSmoke){' → 静态验证 → 模拟器冒烟'}else{' → 静态验证'})$(if(-not $SkipNotify){' → 飞书通知'})"
Write-Host '============================================================' -ForegroundColor DarkGray

# ---------- 1. 构建 ----------
Write-Host ''
Write-Host '【1/3】构建' -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
$buildArgs = @('-NoProfile', '-File', (Join-Path $root 'tools\build.ps1'), '-Task', $Task, '-Publish')
if ($Clean) { $buildArgs += '-Clean' }
& pwsh @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host '构建失败' -ForegroundColor Red
    Notify "v$versionName 构建失败" "gradle $Task 返回 $LASTEXITCODE。$Note" -Fail
    exit 1
}
$buildSec = [int]$sw.Elapsed.TotalSeconds

# ---------- 2. 静态验证 ----------
Write-Host ''
Write-Host '【2/3】静态验证' -ForegroundColor Cyan
$vdigits = $versionName.Replace('.', '')
$verify = Join-Path $root "tools\verify\verify_$vdigits.py"
$verifyLine = '未找到本版验证脚本（跳过）'
if (Test-Path $verify) {
    Push-Location $root
    try {
        $vout = (& python $verify 2>&1 | Out-String)
        $vout | Set-Content -LiteralPath (Join-Path $root "tools\verify\verify_$vdigits.txt")
        Write-Host (($vout -split "`n" | Where-Object { $_ -match '^(FAIL|合计)' }) -join "`n")
        $verifyLine = (($vout -split "`n" | Where-Object { $_ -match '^合计' }) -join ' ').Trim()
        if ($vout -match '(?m)^FAIL') {
            Write-Host '静态验证有 FAIL' -ForegroundColor Red
            Notify "v$versionName 静态验证失败" "$verifyLine`n$Note" -Fail
            exit 1
        }
    } finally { Pop-Location }
} else {
    Write-Host "  $verifyLine" -ForegroundColor Yellow
}

# ---------- 3. 模拟器冒烟 ----------
Write-Host ''
Write-Host '【3/3】模拟器冒烟' -ForegroundColor Cyan
$smokeLine = '已跳过'
$smokeOk = $true
if (-not $SkipSmoke) {
    $smokeArgs = @('-NoProfile', '-File', (Join-Path $root 'tools\smoke\smoke.ps1'), '-Apk', $apk)
    if ($KeepEmulator) { $smokeArgs += '-KeepEmulator' }
    & pwsh @smokeArgs
    $smokeOk = ($LASTEXITCODE -eq 0)
    $smokeLine = if ($smokeOk) { '模拟器冒烟 全部 PASS' } else { '模拟器冒烟 有 FAIL' }
}

# ---------- 4. 通知 ----------
Write-Host ''
$totalSec = [int]$sw.Elapsed.TotalSeconds
if ($smokeOk) {
    $body = @"
构建 $buildSec s / 全程 $totalSec s
$verifyLine
$smokeLine
产物：releases\JZ音乐助手-v$versionName.apk
$(if ($Note) { $Note })
"@
    Notify "v$versionName 已出包（冒烟通过）" $body
    Write-Host '流程完成：全部通过' -ForegroundColor Green
    exit 0
} else {
    $body = @"
构建 $buildSec s / 全程 $totalSec s
$verifyLine
$smokeLine（截图与 logcat 在 tools\smoke\out\v$versionName\）
$(if ($Note) { $Note })
"@
    Notify "v$versionName 冒烟失败" $body -Fail
    Write-Host '流程完成：冒烟未通过，见上方 FAIL 项' -ForegroundColor Red
    exit 1
}
