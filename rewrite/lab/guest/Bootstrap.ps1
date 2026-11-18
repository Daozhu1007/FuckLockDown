$ErrorActionPreference = 'Stop'
$labDirectory = 'C:\NpgLab'
New-Item -ItemType Directory -Path $labDirectory -Force | Out-Null
$mediaDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Copy-Item -LiteralPath (Join-Path $mediaDirectory 'config.json') -Destination (Join-Path $labDirectory 'config.json') -Force
Copy-Item -LiteralPath (Join-Path $mediaDirectory 'GuestAgent.ps1') -Destination (Join-Path $labDirectory 'GuestAgent.ps1') -Force
$agentCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\NpgLab\GuestAgent.ps1'
New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'NpgLabAgent' -Value $agentCommand -PropertyType String -Force | Out-Null
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\NpgLab\GuestAgent.ps1' -WindowStyle Hidden
