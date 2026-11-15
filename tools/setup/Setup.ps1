# JZ Music · 脚本版安装器（等价于 Setup.exe，适合没有图形界面 / 批量部署）
#
# 从 jpackage app-image（或任意一份 portable 目录）装成「JZ Music」文件夹：
#   JZ Music.exe + app\ + runtime\   程序
#   Download\ Log\ Cache\ Data\ Backup\ 说明\   用户目录
#   卸载 JZ Music.exe                 卸载程序（需要 csc.exe）
#
# 用法：
#   pwsh -File .\tools\setup\Setup.ps1
#   pwsh -File .\tools\setup\Setup.ps1 -Dir 'E:\Apps\JZ Music'
#   pwsh -File .\tools\setup\Setup.ps1 -Source '.\desktop\build\compose\binaries\main\app\JZ Music' -NoLaunch
param(
    [string]$Source = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'desktop\build\compose\binaries\main\app\JZ Music'),
    [string]$Dir = 'D:\JZ Music',
    [switch]$NoShortcut,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$docsDir  = Join-Path $PSScriptRoot 'docs'
$csc      = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$icon     = Join-Path $repoRoot 'desktop\icons\app.ico'
$exeName  = 'JZ Music.exe'

if (-not (Test-Path -LiteralPath (Join-Path $Source $exeName))) {
    throw "Source 不像 app-image（找不到 $exeName）：$Source"
}
$Dir = [System.IO.Path]::GetFullPath($Dir)
if ($Dir -match '^[A-Za-z]:\\?$') { throw "不能直接装到磁盘根目录：$Dir" }

Write-Host "==> 安装 JZ Music 到 $Dir"

# 1) 停掉旧版本（只停这个目录里的）
Get-Process -Name 'JZ Music' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Dir, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Write-Host "    停止正在运行的 $($_.Path)"; $_.Kill(); $_.WaitForExit(8000) | Out-Null }

# 2) 程序目录换新，用户目录保留
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
foreach ($sub in @('app', 'runtime')) {
    $p = Join-Path $Dir $sub
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Dir -Recurse -Force
# app-image 里的文件可能带只读属性（jpackage 产物就是这样），拷过来顺手去掉，免得以后升级删不掉
Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }

# 3) 用户目录
foreach ($sub in @('Download', 'Log', 'Cache', 'Data', 'Backup', '说明')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir $sub) | Out-Null
}

# 4) 说明文档
Copy-Item -LiteralPath (Join-Path $docsDir '使用说明.txt')  -Destination (Join-Path $Dir '使用说明.txt') -Force
foreach ($d in @('更新日志.txt', '卸载说明.txt', '常见问题.txt')) {
    Copy-Item -LiteralPath (Join-Path $docsDir $d) -Destination (Join-Path $Dir '说明' ) -Force
}
Copy-Item -LiteralPath (Join-Path $docsDir '日志说明.txt') -Destination (Join-Path $Dir 'Log') -Force

# 5) 卸载程序（有 csc 就现编一个）
if (Test-Path $csc) {
    $uninstaller = Join-Path $Dir '卸载 JZ Music.exe'
    & $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
        "/out:$uninstaller" "/win32icon:$icon" `
        /r:System.Windows.Forms.dll /r:System.Drawing.dll `
        (Join-Path $PSScriptRoot 'Uninstall.cs')
    if ($LASTEXITCODE -ne 0) { Write-Warning "卸载程序编译失败，跳过：$LASTEXITCODE" }
} else {
    Write-Warning "找不到 csc.exe，没装卸载程序（删文件夹即可卸载）"
}

# 6) 快捷方式
if (-not $NoShortcut) {
    $exe = Join-Path $Dir $exeName
    $ws = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    $lnk = $ws.CreateShortcut((Join-Path $desktop 'JZ Music.lnk'))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $Dir
    $lnk.IconLocation = $exe
    $lnk.Description = 'JZ Music'
    $lnk.Save()

    $menuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'JZ Music'
    New-Item -ItemType Directory -Force -Path $menuDir | Out-Null
    $lnk = $ws.CreateShortcut((Join-Path $menuDir 'JZ Music.lnk'))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $Dir
    $lnk.IconLocation = $exe
    $lnk.Save()
}

# 7) 「设置 → 应用」里的登记项
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\JZ Music'
New-Item -Path $key -Force | Out-Null
$version = (Select-String -LiteralPath (Join-Path $repoRoot 'android\app\build.gradle.kts') -Pattern 'versionName\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
Set-ItemProperty -Path $key -Name DisplayName     -Value 'JZ Music'
Set-ItemProperty -Path $key -Name DisplayVersion  -Value $version
Set-ItemProperty -Path $key -Name Publisher       -Value 'JZ'
Set-ItemProperty -Path $key -Name InstallLocation -Value $Dir
Set-ItemProperty -Path $key -Name DisplayIcon     -Value (Join-Path $Dir $exeName)
Set-ItemProperty -Path $key -Name UninstallString -Value ('"' + (Join-Path $Dir '卸载 JZ Music.exe') + '"')

Get-ChildItem -LiteralPath $Dir | Select-Object Mode, Name | Format-Table -AutoSize
Write-Host "==> 安装完成：$(Join-Path $Dir $exeName)" -ForegroundColor Green

if (-not $NoLaunch) {
    Start-Process -FilePath (Join-Path $Dir $exeName) -WorkingDirectory $Dir
}
