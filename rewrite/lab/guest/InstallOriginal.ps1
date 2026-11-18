$ErrorActionPreference = 'Stop'
$labDirectory = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $labDirectory 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
foreach ($file in @('LockDownBrowser-2-1-6-03-356540564.msi','LockDownBrowser.NoProcessGate.exe','VerifyVersion.exe','patch-plan.json','Register-Protocol.ps1')) {
    Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/' + $file) -Headers $headers -OutFile (Join-Path $labDirectory $file) -TimeoutSec 180
}
$installer = Join-Path $labDirectory 'LockDownBrowser-2-1-6-03-356540564.msi'
$installerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
if ($installerHash -ne '1d4a35e0f116740e57e46dacfaa4fd1d4756fb4c0466d1c1fc1b77e3944bf6a0') { throw 'Installer transfer identity mismatch' }
$installation = Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i C:\NpgLab\LockDownBrowser-2-1-6-03-356540564.msi /qn /norestart /L*v C:\NpgLab\msi-install.log' -WindowStyle Hidden -Wait -PassThru
$target = 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe'
$details = @{ installerExit=$installation.ExitCode; targetExists=(Test-Path -LiteralPath $target) }
if ($details.targetExists) {
    $details.targetSha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    $signature = Get-AuthenticodeSignature -LiteralPath $target
    $details.signatureStatus = [string]$signature.Status
    if ($signature.SignerCertificate) { $details.signer = $signature.SignerCertificate.Subject }
    $details.versionCheck = (& (Join-Path $labDirectory 'VerifyVersion.exe') --log 'C:\NpgLab\installed-version-check.jsonl' | Out-String)
    $details.versionCheckExit = $LASTEXITCODE
}
$details.drivers = @(Get-CimInstance Win32_SystemDriver | Where-Object { $_.PathName -match 'LockDown' } | Select-Object Name,State,StartMode,PathName)
$details | ConvertTo-Json -Depth 8
