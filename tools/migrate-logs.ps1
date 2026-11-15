param(
    [string]$SrcDir = "$env:APPDATA\JZ Music\files",
    [string]$DstDir = 'D:\Projects\Private_music\logs'
)
# 把 C 盘 %APPDATA%\JZ Music\files 下的日志迁到项目 logs 目录，并做完整性校验。
# 校验通过才删除源文件（等价于"移动"）。
$ErrorActionPreference = 'Stop'
function Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
function Lines([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    $n = 0
    foreach ($_ in [System.IO.File]::ReadLines($p)) { $n++ }
    return $n
}
function Bytes([string]$p) { (Get-Item -LiteralPath $p).Length }

if (-not (Test-Path -LiteralPath $SrcDir)) { Write-Output "源目录不存在：$SrcDir"; exit 0 }
New-Item -ItemType Directory -Force -Path $DstDir | Out-Null

$report = @()
$files = Get-ChildItem -LiteralPath $SrcDir -File -Filter '*.log'
if (-not $files) { Write-Output '源目录没有 .log 文件'; exit 0 }

foreach ($f in $files) {
    $src = $f.FullName
    $dst = Join-Path $DstDir $f.Name
    $srcHash = Sha $src
    $srcLines = Lines $src
    $srcBytes = Bytes $src

    if (Test-Path -LiteralPath $dst) {
        # 目标已存在（本次运行已经写了几行）：老内容放前面，保持时间顺序
        $oldDstHash = Sha $dst
        $oldDstBytes = Bytes $dst
        $oldDstLines = Lines $dst
        $srcText = [System.IO.File]::ReadAllText($src)
        $dstText = [System.IO.File]::ReadAllText($dst)
        $merged = $srcText + $dstText
        [System.IO.File]::WriteAllText($dst, $merged, (New-Object System.Text.UTF8Encoding($false)))
        $newHash = Sha $dst
        $profile = [System.Security.Cryptography.SHA256]::Create()
        $expected = [System.BitConverter]::ToString($profile.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($merged))).Replace('-','')
        $newLines = Lines $dst
        $ok = ($newHash -eq $expected) -and ($newLines -eq ($srcLines + $oldDstLines)) -and
              ([System.IO.File]::ReadAllText($dst).StartsWith($srcText)) -and
              ([System.IO.File]::ReadAllText($dst).EndsWith($dstText))
        $report += [pscustomobject]@{
            文件 = $f.Name; 方式 = '合并（旧+新）'
            源字节 = $srcBytes; 源行数 = $srcLines
            目标字节 = (Bytes $dst); 目标行数 = $newLines
            期望行数 = ($srcLines + $oldDstLines)
            校验 = if ($ok) { 'PASS' } else { 'FAIL' }
        }
    } else {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $dstHash = Sha $dst
        $dstLines = Lines $dst
        $dstBytes = Bytes $dst
        $ok = ($dstHash -eq $srcHash) -and ($dstLines -eq $srcLines) -and ($dstBytes -eq $srcBytes)
        $report += [pscustomobject]@{
            文件 = $f.Name; 方式 = '复制'
            源字节 = $srcBytes; 源行数 = $srcLines
            目标字节 = $dstBytes; 目标行数 = $dstLines
            期望行数 = $srcLines
            校验 = if ($ok) { 'PASS' } else { 'FAIL' }
        }
    }
}

$report | Format-Table -AutoSize | Out-String -Width 160 | Write-Output

$failed = $report | Where-Object { $_.校验 -ne 'PASS' }
if ($failed) {
    Write-Output '有文件校验失败，保留源文件不删除：'
    $failed | ForEach-Object { Write-Output ("  - " + $_.文件) }
    exit 1
}

# 全部 PASS 才删源（移动语义）
foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force }
Write-Output '全部校验通过，源文件已删除（迁移完成）。'
