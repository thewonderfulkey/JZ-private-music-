# JZ 音乐助手 · 模拟器冒烟测试
#
# 作用：构建之后自动完成「装包 → 启动 → 截图 → 找崩溃 → 点几个关键页面 → 断言文案」，
#       不需要人工安装和点按。跑完把截图和结论留在 tools\smoke\out\<版本>\。
#
# 用法（在项目任意位置执行）：
#   pwsh -File D:\Projects\Private_music\tools\smoke\smoke.ps1
#   pwsh -File ...\smoke.ps1 -Apk releases\JZ音乐助手-v2.1.92.apk
#   pwsh -File ...\smoke.ps1 -KeepEmulator          # 测完不关模拟器（方便手动看）
#   pwsh -File ...\smoke.ps1 -Reuse                 # 复用已在运行的设备，不新起模拟器
#
# 退出码：0 = 全部通过；1 = 有失败项（日志与截图可直接给开发看）
param(
    [string]$Apk = "",
    [string]$AvdName = "jz_smoke",
    [string]$SystemImage = "system-images;android-34;google_apis;x86_64",
    [int]$BootTimeoutSec = 480,
    [int]$LaunchWaitSec = 9,
    [switch]$KeepEmulator,
    [switch]$Reuse,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sdk       = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { 'C:\Users\17948\AppData\Local\Android\Sdk' }
$adb       = Join-Path $sdk 'platform-tools\adb.exe'
$emulator  = Join-Path $sdk 'emulator\emulator.exe'
$avdTool   = Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'
$uidump    = Join-Path $PSScriptRoot 'uidump.py'
$python    = 'python'

# AVD 也放进项目（不污染 C:\Users\<user>\.android）；首次由本脚本自动创建
$avdHome = Join-Path $root '.build\avd'
New-Item -ItemType Directory -Force -Path $avdHome | Out-Null
$env:ANDROID_AVD_HOME = $avdHome
$env:ANDROID_SDK_ROOT = $sdk
$env:ANDROID_HOME     = $sdk

if (-not (Test-Path $adb))      { throw "adb 不存在：$adb" }
if (-not (Test-Path $emulator)) { throw "emulator 未安装：$emulator（先跑 .\tools\smoke\install-emulator.ps1）" }

# ---- 取 APK ----
if (-not $Apk) {
    $Apk = Join-Path $root 'android\app\build\outputs\apk\release\app-release.apk'
} elseif (-not [System.IO.Path]::IsPathRooted($Apk)) {
    $Apk = Join-Path $root $Apk
}
if (-not (Test-Path $Apk)) { throw "APK 不存在：$Apk" }

$gradleKts = Join-Path $root 'android\app\build.gradle.kts'
$versionName = (Select-String -LiteralPath $gradleKts -Pattern 'versionName\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
$pkg = 'com.jz.musichelper'
$activity = "$pkg/.MainActivity"

$outDir = Join-Path $PSScriptRoot "out\v$versionName"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$logFile = Join-Path $outDir 'smoke.log'
$script:steps = @()
function Step($name, $ok, $detail = "") {
    $script:steps += [pscustomobject]@{ Step = $name; Ok = $ok; Detail = $detail }
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    if (-not $Quiet -or -not $ok) { Write-Host ("  {0}  {1}{2}" -f $mark, $name, ($(if ($detail) { "  | $detail" } else { "" }))) -ForegroundColor $color }
    Add-Content -LiteralPath $logFile -Value ("{0}  {1}  {2}" -f $mark, $name, $detail)
}

function Adb { param([Parameter(ValueFromRemainingArguments = $true)]$Args2) & $adb @Args2 2>&1 }

Write-Host '============================================================' -ForegroundColor DarkGray
Write-Host " 冒烟测试 : v$versionName"
Write-Host " APK      : $Apk"
Write-Host " 设备     : $AvdName"
Write-Host " 输出     : $outDir"
Write-Host '============================================================' -ForegroundColor DarkGray
Set-Content -LiteralPath $logFile -Value "smoke v$versionName  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# ---- 1. 设备 ----
$devices = (& $adb devices) -split "`n" | Where-Object { $_ -match '\tdevice$' }
$startedEmulator = $false
if (-not $devices -and -not $Reuse) {
    Write-Host '==> 启动模拟器（首次冷启动可能要 2~4 分钟）' -ForegroundColor Cyan
    $avds = & $avdTool list avd 2>&1 | Out-String
    if ($avds -notmatch [regex]::Escape($AvdName)) {
        Write-Host "==> 创建 AVD $AvdName（放在项目 .build\avd，不污染 C 盘）"
        'no' | & $avdTool create avd -n $AvdName -k $SystemImage -d pixel_5 --force 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "AVD 创建失败（$SystemImage）" }
    }
    $emArgs = @('-avd', $AvdName, '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot',
                '-gpu', 'swiftshader_indirect', '-netdelay', 'none', '-netspeed', 'full')
    $emuLog = Join-Path $outDir 'emulator.log'
    $script:emuProc = Start-Process -FilePath $emulator -ArgumentList $emArgs `
        -RedirectStandardOutput $emuLog -RedirectStandardError "$emuLog.err" -WindowStyle Hidden -PassThru
    $startedEmulator = $true
}
if ($Reuse -and -not $devices) { throw '-Reuse 指定了复用设备，但没有已连接的设备' }

Write-Host '==> 等待设备上线'
$sw = [Diagnostics.Stopwatch]::StartNew()
$booted = $false
$deviceUp = $false
while ($sw.Elapsed.TotalSeconds -lt $BootTimeoutSec) {
    # 模拟器进程挂了就别干等（AVD 名字错、WHPX 没开、镜像缺失都会走这里）
    if ($startedEmulator -and $script:emuProc -and $script:emuProc.HasExited) {
        Write-Host "==> 模拟器进程退出（exit $($script:emuProc.ExitCode)），日志末尾：" -ForegroundColor Red
        if (Test-Path $emuLog) { Get-Content -LiteralPath $emuLog -Tail 12 | ForEach-Object { Write-Host "    $_" } }
        Step '设备启动完成' $false 'emulator 进程退出'
        exit 1
    }
    if (-not $deviceUp) {
        $cur = (& $adb devices 2>$null) -split "`n" | Where-Object { $_ -match '\tdevice$' }
        if ($cur) { $deviceUp = $true }
    }
    if ($deviceUp) {
        $b = (& $adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        if ($b -eq '1') { $booted = $true; break }
    }
    Start-Sleep -Seconds 3
}
Step '设备启动完成' $booted ("{0:N0}s" -f $sw.Elapsed.TotalSeconds)
if (-not $booted) {
    Write-Host '==> 启动超时，见 emulator.log' -ForegroundColor Red
    if (Test-Path $emuLog) { Get-Content -LiteralPath $emuLog -Tail 12 | ForEach-Object { Write-Host "    $_" } }
    & $adb emu kill 2>$null | Out-Null
    exit 1
}
& $adb shell input keyevent 82 | Out-Null   # 解锁
Start-Sleep -Seconds 2

# ---- 2. 装包 ----
Write-Host '==> 安装 APK'
$install = (& $adb install -r -g $Apk 2>&1 | Out-String)
$installed = $install -match 'Success'
Step '安装成功' $installed ($install.Trim() -split "`n" | Select-Object -Last 1)
if (-not $installed) { if ($startedEmulator -and -not $KeepEmulator) { & $adb emu kill }; exit 1 }

$pkgInfo = (& $adb shell dumpsys package $pkg 2>&1 | Out-String)
$vc = [regex]::Match($pkgInfo, 'versionCode=(\d+)').Groups[1].Value
$vn = [regex]::Match($pkgInfo, 'versionName=([^\s]+)').Groups[1].Value
Step '设备上版本与构建一致' ($vn -eq $versionName) "设备 v$vn (vc$vc) / 期望 v$versionName"

# ---- 3. 启动 ----
Write-Host '==> 启动 App'
& $adb shell am force-stop $pkg | Out-Null
& $adb logcat -c | Out-Null
$start = (& $adb shell am start -W -n $activity 2>&1 | Out-String)
Step 'Activity 启动' ($start -match 'Status: ok') (($start -split "`n" | Where-Object { $_ -match 'Status|Error' }) -join ' ')
Start-Sleep -Seconds $LaunchWaitSec

function Shot($name) {
    $p = Join-Path $outDir "$name.png"
    cmd /c "`"$adb`" exec-out screencap -p > `"$p`"" | Out-Null
    return $p
}
function UiDump($name) {
    & $adb shell uiautomator dump /sdcard/ui.xml 2>&1 | Out-Null
    $p = Join-Path $outDir "$name.xml"
    & $adb pull /sdcard/ui.xml $p 2>&1 | Out-Null
    return $p
}
function TapText($text) {
    $xml = UiDump 'tmp_tap'
    $c = (& $python $uidump --file $xml --center $text 2>&1 | Out-String).Trim()
    if ($c -notmatch '^\d+,\d+$') { return $false }
    $x, $y = $c -split ','
    & $adb shell input tap $x $y | Out-Null
    return $true
}

# App 启动时会主动申请「忽略电池优化」，系统会弹一个确认框把界面挡住；
# 另外个别机型/镜像还会弹通知、定位之类的系统框。这里统一点掉（优先允许）。
function DismissSystemDialogs {
    for ($i = 0; $i -lt 4; $i++) {
        $xml = UiDump 'tmp_dialog'
        $hit = $false
        foreach ($t in @('Allow', '允许', 'OK', '确定', 'Got it', '知道了', 'While using the app', '使用应用时允许')) {
            $c = (& $python $uidump --file $xml --center $t 2>$null | Out-String).Trim()
            if ($c -match '^\d+,\d+$') {
                $x, $y = $c -split ','
                & $adb shell input tap $x $y | Out-Null
                Start-Sleep -Milliseconds 900
                $hit = $true
                break
            }
        }
        if (-not $hit) { break }
    }
}

# ---- 4. 崩溃 / ANR ----
$logs = (& $adb logcat -d -t 800 2>&1 | Out-String)
$fatal = $logs -match 'FATAL EXCEPTION'
$anr = $logs -match "ANR in $pkg"
Step '无崩溃（FATAL EXCEPTION）' (-not $fatal)
Step '无 ANR' (-not $anr)
$procAlive = ((& $adb shell pidof $pkg 2>&1 | Out-String).Trim() -ne '')
Step '进程存活' $procAlive

# ---- 5. 首页 UI ----
Write-Host '==> 校验首页'
DismissSystemDialogs
Start-Sleep -Seconds 2
Shot '01-home' | Out-Null
$homeXml = UiDump '01-home'
$tabs = (& $python $uidump --file $homeXml --any '首页,识曲,收藏,下载,历史,设置' 2>&1 | Out-String).Trim()
Step '底部六格导航' ($tabs -match 'FOUND' -and $tabs -match '6/6') $tabs

# ---- 6. 识曲页 ----
Write-Host '==> 进入识曲页'
if (TapText '识曲') {
    Start-Sleep -Seconds 3
    Shot '02-recognize' | Out-Null
    $recXml = UiDump '02-recognize'
    $has = (& $python $uidump --file $recXml --has '听歌识曲' 2>&1 | Out-String).Trim()
    Step '识曲页渲染' ($has -match 'FOUND') $has
} else {
    Step '识曲页渲染' $false '找不到「识曲」标签'
}

# ---- 7. 设置页 + 版本 ----
Write-Host '==> 进入设置页'
if (TapText '设置') {
    Start-Sleep -Seconds 2
    # 「关于」在设置页底部且内容很长：边下滑边 dump，任一次看到版本行即通过
    $foundVer = $false
    for ($i = 0; $i -lt 8; $i++) {
        if ($i -gt 0) {
            & $adb shell input swipe 540 1900 540 700 250 | Out-Null
            Start-Sleep -Milliseconds 450
        }
        $setXml = UiDump "03-settings-$i"
        $ver = (& $python $uidump --file $setXml --has "JZ的音乐助手 v$versionName" 2>&1 | Out-String).Trim()
        if ($ver -match 'FOUND') { $foundVer = $true; break }
    }
    Shot '03-settings' | Out-Null
    Step '关于页版本正确' $foundVer ($(if ($foundVer) { "第 $i 屏命中 v$versionName" } else { "下滑 8 屏未见 JZ的音乐助手 v$versionName" }))
} else {
    Step '关于页版本正确' $false '找不到「设置」标签'
}

# ---- 8. 结果 ----
$fail = $script:steps | Where-Object { -not $_.Ok }
Write-Host ''
Write-Host '========================= 冒烟结果 =========================' -ForegroundColor DarkGray
$script:steps | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "截图与日志：$outDir"
if ($fail) {
    Write-Host "FAILED: $($fail.Count) 项不通过" -ForegroundColor Red
    $tail = (& $adb logcat -d -t 200 2>&1 | Out-String)
    $tail | Set-Content -LiteralPath (Join-Path $outDir 'logcat-tail.txt')
    Write-Host '--- logcat 末尾 ---' -ForegroundColor Yellow
    Write-Host (($tail -split "`n" | Select-Object -Last 25) -join "`n")
} else {
    Write-Host 'ALL PASS' -ForegroundColor Green
}

if ($startedEmulator -and -not $KeepEmulator) { & $adb emu kill 2>$null | Out-Null }
exit ($(if ($fail) { 1 } else { 0 }))
