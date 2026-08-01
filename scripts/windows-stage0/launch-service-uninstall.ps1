Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$UninstallerPath = Join-Path $PSScriptRoot "uninstall-service.ps1"
$Arguments = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    ('"{0}"' -f $UninstallerPath)
)
$Process = Start-Process -FilePath "powershell.exe" `
    -Verb RunAs `
    -Wait `
    -PassThru `
    -ArgumentList $Arguments
exit $Process.ExitCode
