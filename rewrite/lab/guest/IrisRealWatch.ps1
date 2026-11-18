# 第三路径实验（整合版）：用户只需运行本脚本 + 正常使用 LockDown。
#
# 流程（脚本自动完成 1-3，用户只做 4-6）：
#   1. 关闭现有 Iris
#   2. 安排 30 秒后自动启动 Iris（延时启动，模拟"浏览器起来之后 Iris 才出现"）
#   3. 每 250ms 采样 Iris 进程与 LockDown 进程，共 300 秒
#   4. 用户：脚本跑起来后，立刻启动 LockDownBrowser.NoProcessGate.exe，正常进入
#   5. 用户：在里面待 2-3 分钟（不用切屏、不用做任何事），然后正常退出
#   6. 时间线自动保存到 C:\Users\Daozh\iris-watch-result.json
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'

Write-Host '=== Iris delayed-start experiment ===' -ForegroundColor Cyan
Get-Process | Where-Object { $_.Name -match 'iris' } | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host 'existing Iris stopped; delayed start armed (30s)' -ForegroundColor Yellow

$job = Start-Job -ScriptBlock {
    Start-Sleep -Seconds 30
    Start-Process -FilePath 'D:\Iris\IrisPortable.exe'
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
$lastIrisCount = -1
while ($sw.Elapsed.TotalSeconds -lt 300) {
    $t = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    $iris = @(Get-Process | Where-Object { $_.Name -match 'iris' } | ForEach-Object { $_.Id })
    $browser = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count
    $samples += [pscustomobject]@{ t = $t; irisPids = ($iris -join ','); irisCount = $iris.Count; browserCount = $browser }
    if ($lastIrisCount -ge 0 -and $iris.Count -eq 0 -and $lastIrisCount -gt 0) {
        Write-Host ("  !! IRIS DIED at t={0}s (browserCount={1})" -f $t, $browser) -ForegroundColor Red
    }
    $lastIrisCount = $iris.Count
    Start-Sleep -Milliseconds 250
}
Stop-Job $job -ErrorAction SilentlyContinue
Remove-Job $job -Force -ErrorAction SilentlyContinue

$samples | ConvertTo-Json -Depth 4 | Out-File -LiteralPath 'C:\Users\Daozh\iris-watch-result.json' -Encoding utf8
Write-Host ''
Write-Host 'Saved: C:\Users\Daozh\iris-watch-result.json' -ForegroundColor Green
Write-Host ('Iris final state: {0} process(es)' -f $lastIrisCount)
