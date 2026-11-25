# 盯构建：每 60 秒查一次，打包任务一结束就退出并打印结论。
# 为什么用后台任务：GitHub 的 macOS 机器什么时候派下来完全不可控，人不用一直守着。
$ErrorActionPreference = 'Continue'
$raw = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
$pat = ($raw | Select-String '^password=') -replace '^password=', ''
$h = @{ Authorization = "token $pat"; Accept = "application/vnd.github+json" }

for ($i = 0; $i -lt 150; $i++) {
    $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/thewonderfulkey/JZ-private-music-/actions/runs?per_page=3" -Headers $h
    $active = $runs.workflow_runs | Where-Object { $_.status -ne 'completed' }
    if (-not $active) {
        "NO_ACTIVE_RUN"
        exit 0
    }
    foreach ($r in $active) {
        $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/thewonderfulkey/JZ-private-music-/actions/runs/$($r.id)/jobs" -Headers $h
        $b = $jobs.jobs | Where-Object { $_.name -like 'build*' } | Select-Object -First 1
        $bstat = if ($b) { "$($b.status)/$($b.conclusion)" } else { 'none' }
        "{0} run={1} 状态={2} 打包={3}" -f (Get-Date -Format 'HH:mm:ss'), $r.run_number, $r.status, $bstat
        if ($b -and $b.status -eq 'completed') {
            "BUILD_JOB_DONE conclusion=$($b.conclusion) run=$($r.run_number)"
            exit 0
        }
        if ($r.status -eq 'completed') {
            "RUN_DONE conclusion=$($r.conclusion) run=$($r.run_number)"
            exit 0
        }
    }
    Start-Sleep -Seconds 60
}
"TIMEOUT_150_MIN"
