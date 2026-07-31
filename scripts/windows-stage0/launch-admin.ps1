Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CollectorPath = Join-Path $PSScriptRoot "collect.ps1"
$Arguments = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    ('"{0}"' -f $CollectorPath),
    "-ExpectedMode",
    "Administrator"
)
$Process = Start-Process -FilePath "powershell.exe" `
    -Verb RunAs `
    -Wait `
    -PassThru `
    -ArgumentList $Arguments
exit $Process.ExitCode
