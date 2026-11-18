[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$ErrorActionPreference='Stop'
if (-not (Test-Path -LiteralPath 'C:\NpgLab\config.json')) { throw 'Requires NpgLab guest.' }
$target='C:\Program Files\Respondus\LockDown Browser'
$locations=@($target,"$env:LOCALAPPDATA\Respondus","$env:APPDATA\Respondus","$env:LOCALAPPDATA\LockDown Browser","$env:APPDATA\LockDown Browser")
$files=@()
foreach($directory in $locations) {
 if(Test-Path -LiteralPath $directory) {
  $files+=@(Get-ChildItem -LiteralPath $directory -File -Recurse -ErrorAction SilentlyContinue |
   Where-Object {$_.Extension -in @('.log','.txt') -and $_.BaseName -notmatch '^\d+$' -and $_.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddHours(-1)} |
   Select-Object -First 25 | ForEach-Object {
    $text=[IO.File]::ReadAllText($_.FullName)
    if($text.Length -gt 12000){$text=$text.Substring($text.Length-12000)}
    @{path=$_.FullName;modified=$_.LastWriteTimeUtc.ToString('o');tail=$text}
   })
 }
}
$events=@(Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=[DateTime]::Now.AddMinutes(-15)} -ErrorAction SilentlyContinue |
 Where-Object {$_.Message -match 'LockDownBrowser'} | Select-Object -First 10 TimeCreated,Id,ProviderName,Message)
@{files=$files;events=$events;active=@(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Select-Object Id,Path)} | ConvertTo-Json -Depth 8 -Compress
