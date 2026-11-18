"""Build WatchDist6.ps1: child pid from the launcher trace, not Get-Process[0]."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
src = (ROOT / "guest" / "WatchDist5.ps1").read_text(encoding="utf-8")

old = (
    "$launcher = Start-Process -FilePath $launcherPath -ArgumentList "
    "'--no-ui','--log','C:\\NpgLab\\distlog5.jsonl' -WindowStyle Hidden -PassThru\n"
    "$elapsed = [Diagnostics.Stopwatch]::StartNew()"
)
new = (
    "$launcher = Start-Process -FilePath $launcherPath -ArgumentList "
    "'--no-ui','--log','C:\\NpgLab\\distlog6.jsonl' -WindowStyle Hidden -PassThru\n"
    "$childPid = 0\n"
    "for ($wait = 0; $wait -lt 40; $wait++) {\n"
    "    Start-Sleep -Milliseconds 250\n"
    "    if (Test-Path -LiteralPath 'C:\\NpgLab\\distlog6.jsonl') {\n"
    "        $created = @(Get-Content -LiteralPath 'C:\\NpgLab\\distlog6.jsonl' |\n"
    "            Where-Object { $_ -match 'child_created_suspended' } | Select-Object -First 1)\n"
    "        if ($created.Count) {\n"
    "            $childPid = ([regex]::Match($created[0], '\"pid\"\\s*:\\s*(\\d+)')).Groups[1].Value -as [int]\n"
    "            if ($childPid) { break }\n"
    "        }\n"
    "    }\n"
    "}\n"
    "Write-Output ('child pid from trace: ' + $childPid)\n"
    "$elapsed = [Diagnostics.Stopwatch]::StartNew()"
)
assert old in src, "launcher start block not found"
src = src.replace(old, new, 1)

old2 = (
    "    if (-not $selected) {\n"
    "        [AcceptUI]::DismissUpdateWarning($browser[0].Id) | Out-Null\n"
    "        $click = [AcceptUI]::SelectServer($browser[0].Id)\n"
    "        if ($null -ne $click) { $selected = @{t=$t; result=$click} }\n"
    "    }"
)
new2 = (
    "    if (-not $selected -and $childPid) {\n"
    "        [AcceptUI]::DismissUpdateWarning($childPid) | Out-Null\n"
    "        $click = [AcceptUI]::SelectServer($childPid)\n"
    "        if ($null -ne $click) { $selected = @{t=$t; result=$click} }\n"
    "    }"
)
assert old2 in src, "select block not found"
src = src.replace(old2, new2, 1)

(ROOT / "guest" / "WatchDist6.ps1").write_text(src, encoding="utf-8")
print("WatchDist6 written (pid from launcher trace)")
