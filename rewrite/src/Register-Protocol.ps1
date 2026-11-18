[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$protocolSubkey = 'Software\Classes\rldb'
$backupDirectory = Join-Path $PSScriptRoot 'protocol-backup'
$statePath = Join-Path $backupDirectory 'state.json'
$backupPath = Join-Path $backupDirectory 'original.reg'
$currentUser = [Microsoft.Win32.Registry]::CurrentUser

function Get-CurrentCommand {
    $key = $currentUser.OpenSubKey($protocolSubkey + '\shell\open\command')
    try { if ($key) { return [string]$key.GetValue('') }; return $null }
    finally { if ($key) { $key.Dispose() } }
}

if ($Restore) {
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'No protocol backup exists.' }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ((Get-CurrentCommand) -ne $state.installedCommand) { throw 'The protocol was changed after this registration. Inspect the backup before restoring.' }
    if ($state.hadKey) {
        if (-not (Test-Path -LiteralPath $backupPath)) { throw 'The original registry export is missing.' }
        if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -ne $state.backupSha256) { throw 'The original registry export was modified.' }
    }
    if ($PSCmdlet.ShouldProcess('HKCU\Software\Classes\rldb', 'Restore the previous protocol registration')) {
        # The key name is a constant; only this per-user override is removed.
        $currentUser.DeleteSubKeyTree($protocolSubkey, $false)
        if ($state.hadKey) {
            & reg.exe import $backupPath | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ('Restore failed. The original export remains at ' + $backupPath) }
        }
        Write-Output 'Previous rldb protocol registration restored.'
    }
    exit
}

$launcher = Join-Path $PSScriptRoot 'LockDownBrowser.NoProcessGate.exe'
$verifier = Join-Path $PSScriptRoot 'VerifyVersion.exe'
if (-not (Test-Path -LiteralPath $launcher) -or -not (Test-Path -LiteralPath $verifier)) { throw 'Run this script from the built dist directory.' }
& $verifier --no-ui
if ($LASTEXITCODE -ne 0) { throw 'Install the exact original browser version before registering this launcher.' }
$command = '"' + $launcher + '" "%1"'
if (Test-Path -LiteralPath $statePath) {
    $existing = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ((Get-CurrentCommand) -ne $existing.installedCommand) { throw 'An earlier backup exists and the handler changed. Inspect it before registering again.' }
}
if (-not $PSCmdlet.ShouldProcess('HKCU\Software\Classes\rldb', 'Register the process-policy launcher')) { exit }
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $statePath)) {
    $oldKey = $currentUser.OpenSubKey($protocolSubkey)
    $hadKey = $null -ne $oldKey
    if ($oldKey) { $oldKey.Dispose() }
    $backupDigest = $null
    if ($hadKey) {
        & reg.exe export 'HKCU\Software\Classes\rldb' $backupPath /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot back up the existing per-user registration.' }
        $backupDigest = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
    }
    @{ hadKey=$hadKey; backupSha256=$backupDigest; installedCommand=$command } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}
$key = $currentUser.CreateSubKey($protocolSubkey)
try {
    $key.SetValue('', 'URL:LockDown Browser process policy variant', [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('URL Protocol', '', [Microsoft.Win32.RegistryValueKind]::String)
    $icon = $key.CreateSubKey('DefaultIcon')
    try { $icon.SetValue('', $launcher, [Microsoft.Win32.RegistryValueKind]::String) } finally { $icon.Dispose() }
    $open = $key.CreateSubKey('shell\open\command')
    try { $open.SetValue('', $command, [Microsoft.Win32.RegistryValueKind]::String) } finally { $open.Dispose() }
} finally { $key.Dispose() }
Write-Output 'Registered the per-user rldb handler. Use -Restore to restore the saved registration.'
