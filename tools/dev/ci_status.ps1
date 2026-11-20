# 查 CI：用 Windows 凭据管理器里的 PAT 调 GitHub API（不打印 token）
param([string]$Sha = "", [switch]$Watch)
$ErrorActionPreference = "Continue"
$input = "protocol=https`nhost=github.com`n`n"
$out = $input | git credential fill 2>$null
$token = ($out | Where-Object { $_ -like "password=*" }) -replace "^password=", ""
if (-not $token) { Write-Output "拿不到 PAT"; exit 1 }
$headers = @{ Authorization = "Bearer $token"; Accept = "application/vnd.github+json" }

$repo = "thewonderfulkey/JZ-private-music-"
$runs = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$repo/actions/runs?per_page=5"
foreach ($r in $runs.workflow_runs) {
    $short = $r.head_sha.Substring(0, 7)
    Write-Output ("{0} {1} {2,-18} {3,-10} {4}" -f $r.run_number, $short, $r.status, $r.conclusion, $r.display_title)
}

if ($Sha) {
    $s = $Sha.Substring(0, 7)
    $target = $runs.workflow_runs | Where-Object { $_.head_sha.StartsWith($s) } | Select-Object -First 1
    if (-not $target) { Write-Output "还没看到 $s 的 run"; exit 2 }
    Write-Output "`n目标 run: #$($target.run_number) status=$($target.status) conclusion=$($target.conclusion)"
    if ($Watch -and $target.status -ne "completed") {
        $id = $target.id
        for ($i = 0; $i -lt 80; $i++) {
            Start-Sleep -Seconds 20
            $cur = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$repo/actions/runs/$id"
            if ($cur.status -eq "completed") { Write-Output "完成：$($cur.conclusion)"; break }
            Write-Output ("  … {0}  {1}" -f $cur.status, (Get-Date -Format "HH:mm:ss"))
        }
    }
    # 产物
    $arts = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$repo/actions/runs/$id/artifacts"
    foreach ($a in $arts.artifacts) { Write-Output ("artifact: {0}  {1} B" -f $a.name, $a.size_in_bytes) }
}
