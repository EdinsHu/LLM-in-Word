[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Exe,
    [string] $ResultPath = (Join-Path ([IO.Path]::GetTempPath()) ("wordmath-live-{0}.json" -f [guid]::NewGuid()))
)
$ErrorActionPreference = 'Stop'
$exePath = (Resolve-Path -LiteralPath $Exe).Path
$result = [IO.Path]::GetFullPath($ResultPath)
if (Test-Path -LiteralPath $result) { throw "Choose a new result path: $result" }
# Launch from a signed-in desktop session and allow the disposable test document to take focus.
$process = Start-Process -FilePath $exePath -ArgumentList @('--word-live-test', ('"{0}"' -f $result)) -PassThru
if (-not $process.WaitForExit(90000)) {
    # End only this verification client. Never kill any WINWORD process or a running WordMath tray.
    $process.Kill()
    throw 'Desktop Word did not answer. Check the separate test window for an Office setup or activation dialog.'
}
if (-not (Test-Path -LiteralPath $result)) { throw "No Word integration result was produced. Exit code $($process.ExitCode)" }
$report = Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json
$report | ConvertTo-Json -Depth 3
if ($process.ExitCode -ne 0 -or -not $report.passed) { throw "Desktop Word integration failed. Report: $result" }
