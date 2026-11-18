[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference='Continue'
Get-Process -Name ExperimentLauncher -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3
$killed = @(@('ExperimentLauncher','LockDownBrowser') | ForEach-Object { @(Get-Process -Name $_ -ErrorAction SilentlyContinue).Count })
'left:' + ($killed -join ',')
