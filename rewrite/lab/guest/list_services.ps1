$ErrorActionPreference='Continue'
$svcs=@(Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'Lock|LDB|Respondus' -or $_.DisplayName -match 'Lock|LDB|Respondus' -or ($_.PathName -and $_.PathName -match 'Lock|Respondus') } | Select-Object Name,State,StartMode,ProcessId,PathName)
$procs=@(Get-Process | Where-Object { $_.Name -match 'Lock|LDB|Respondus' } | Select-Object Name,Id,Path)
@{services=$svcs;processes=$procs} | ConvertTo-Json -Depth 4 -Compress
