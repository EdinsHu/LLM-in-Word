# Installs the built package into an isolated location on a disposable Windows runner.
$ErrorActionPreference = 'Stop'
function Run-Checked([string]$File, [string[]]$Arguments, [int]$Seconds = 120) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -RedirectStandardOutput "$scratch/stdout.txt" -RedirectStandardError "$scratch/stderr.txt" -PassThru
    if (!$process.WaitForExit($Seconds * 1000)) {
        $process.Kill($true)
        throw "$([IO.Path]::GetFileName($File)) timed out"
    }
    Get-Content "$scratch/stdout.txt", "$scratch/stderr.txt"
    if ($process.ExitCode -ne 0) { throw "$([IO.Path]::GetFileName($File)) exited with $($process.ExitCode)" }
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("WordMath Deployment " + [Guid]::NewGuid().ToString('N'))
New-Item $scratch -ItemType Directory | Out-Null
$installed = Join-Path $scratch 'WordMath Installed'
$repo = Split-Path $PSScriptRoot
$installers = @(Get-ChildItem "$repo/dist/WordMath-*-windows-x64-setup.exe")
if ($installers.Count -ne 1) { throw 'Expected a single release installer' }
$installer = $installers[0]
try {
    Run-Checked $installer.FullName @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS',('/DIR="{0}"' -f $installed))
    $exe = Join-Path $installed 'WordMath.exe'
    Run-Checked $exe @('--package-self-test')
    Run-Checked $exe @('--model-self-test')
    Run-Checked $exe @('--panel-self-test') 150
    if ([Type]::GetTypeFromProgID('Word.Application')) {
        $report = Join-Path $scratch 'word-live.json'
        Run-Checked $exe @('--word-live-test',('"{0}"' -f $report)) 180
        Get-Content $report -Raw
    } else {
        Write-Host 'Desktop Word is absent from this runner. Live Word insertion was not tested here.'
    }
} finally {
    $uninstaller = Join-Path $installed 'unins000.exe'
    if (Test-Path $uninstaller) {
        Run-Checked $uninstaller @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
        if (Test-Path (Join-Path $installed 'WordMath.exe')) { throw 'Uninstall left the application executable behind' }
    }
    Remove-Item $scratch -Recurse -Force
}
