$ErrorActionPreference='Continue'
$procs=@(Get-Process | Where-Object { $_.Name -match 'iris' } | ForEach-Object { @{name=$_.Name; pid=$_.Id; path=$_.Path} })
$procs | ConvertTo-Json -Depth 4 -Compress
