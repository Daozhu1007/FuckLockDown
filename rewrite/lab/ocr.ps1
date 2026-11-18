param(
    [Parameter(Mandatory=$true, Position=0, ValueFromRemainingArguments=$true)][string[]]$Path
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($WinRtTask, $ResultType) {
    $task = $asTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($WinRtTask))
    $task.Wait()
    return $task.Result
}

$null = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { throw 'No OCR engine for user profile languages.' }

foreach ($p in $Path) {
    Write-Output ("===== " + $p)
    if (-not (Test-Path -LiteralPath $p)) { Write-Output "MISSING"; continue }
    $bytes = [IO.File]::ReadAllBytes($p)
    $ms = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream([IO.MemoryStream]::new($bytes))
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ms)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $soft = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Await ($engine.RecognizeAsync($soft)) ([Windows.Media.Ocr.OcrResult])
    Write-Output $result.Text
    $soft.Dispose()
    $ms.Dispose()
}
