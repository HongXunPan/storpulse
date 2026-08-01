Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PackageRoot = Split-Path -Parent $PSScriptRoot
$InstallerPath = Join-Path $PSScriptRoot "install-service.ps1"
$Arguments = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    ('"{0}"' -f $InstallerPath),
    "-PackageRoot",
    ('"{0}"' -f $PackageRoot)
)
$Process = Start-Process -FilePath "powershell.exe" `
    -Verb RunAs `
    -Wait `
    -PassThru `
    -ArgumentList $Arguments
exit $Process.ExitCode
