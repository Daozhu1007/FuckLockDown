# Iris 生存监视器（在用户真机上运行）
# 用法：先运行本脚本（普通 PowerShell 即可，无需管理员），它会先记录 Iris 基线，
#       然后你去正常启动 LockDownBrowser.NoProcessGate.exe、进入考试环境再退出。
#       全程结束后按回车，时间线保存到 C:\Users\Daozh\iris-watch-result.json
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$sw = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
Write-Host '=== Iris survival watcher ===' -ForegroundColor Cyan
Write-Host 'Monitoring for 180 seconds. Now launch LockDownBrowser.NoProcessGate.exe and use it normally.'
$last = -1
while ($sw.Elapsed.TotalSeconds -lt 180) {
    $t = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    $iris = @(Get-Process | Where-Object { $_.Name -match 'iris' } | ForEach-Object { $_.Id })
    $browser = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count
    $samples += [pscustomobject]@{ t = $t; irisPids = ($iris -join ','); irisCount = $iris.Count; browserCount = $browser }
    if ($iris.Count -eq 0 -and $last -ne -1) {
        Write-Host ("  !! IRIS DIED at t={0}s (browserCount={1})" -f $t, $browser) -ForegroundColor Red
        $last = -2
    }
    if ($browser -gt 0 -and $last -lt 0) { $last = $t; Write-Host ("  browser appeared at t={0}s" -f $t) -ForegroundColor Yellow }
    Start-Sleep -Milliseconds 250
}
$samples | ConvertTo-Json -Depth 4 | Out-File -LiteralPath 'C:\Users\Daozh\iris-watch-result.json' -Encoding utf8
Write-Host 'Saved: C:\Users\Daozh\iris-watch-result.json' -ForegroundColor Green
