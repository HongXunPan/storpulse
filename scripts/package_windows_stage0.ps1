param(
    [Parameter(Mandatory = $true)] [string]$BinaryPath,
    [Parameter(Mandatory = $true)] [string]$OutputDirectory,
    [Parameter(Mandatory = $true)] [string]$CommitSha,
    [string]$PdbPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$PackageRoot = Join-Path $OutputDirectory "storpulse-windows-stage0-x64"
$ScriptsDirectory = Join-Path $PackageRoot "scripts"
$ArchivePath = Join-Path $OutputDirectory "storpulse-windows-stage0-x64.zip"
$SymbolsArchivePath = Join-Path $OutputDirectory "storpulse-windows-stage0-symbols-x64.zip"

if (Test-Path $PackageRoot) {
    Remove-Item -Recurse -Force -LiteralPath $PackageRoot
}
New-Item -ItemType Directory -Force -Path $ScriptsDirectory | Out-Null

Copy-Item -LiteralPath $BinaryPath -Destination (Join-Path $PackageRoot "storpulse-windows-probe.exe")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-stage0/collect.ps1") -Destination $ScriptsDirectory
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-stage0/launch-admin.ps1") -Destination $ScriptsDirectory
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-stage0/collect-standard.cmd") -Destination (Join-Path $PackageRoot "收集标准用户日志.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-stage0/collect-admin.cmd") -Destination (Join-Path $PackageRoot "收集管理员日志.cmd")
Copy-Item -LiteralPath (Join-Path $Root "docs/Windows阶段0协作调试指南.md") -Destination $PackageRoot

$ProbePath = Join-Path $PackageRoot "storpulse-windows-probe.exe"
$ProbeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ProbePath).Hash.ToLowerInvariant()
$Manifest = [ordered]@{
    schemaVersion = 1
    product = "StorPulse Windows 阶段 0 协作诊断包"
    commitSha = $CommitSha
    target = "x86_64-pc-windows-msvc"
    probeSha256 = $ProbeHash
    signed = $false
    createdAtUtc = [DateTime]::UtcNow.ToString("o")
}
$Encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    (Join-Path $PackageRoot "package-manifest.json"),
    ($Manifest | ConvertTo-Json -Depth 5),
    $Encoding
)
[System.IO.File]::WriteAllText(
    (Join-Path $PackageRoot "SHA256SUMS.txt"),
    ("{0}  storpulse-windows-probe.exe`n" -f $ProbeHash),
    $Encoding
)

if (Test-Path $ArchivePath) {
    Remove-Item -Force -LiteralPath $ArchivePath
}
Compress-Archive -Path (Join-Path $PackageRoot "*") -DestinationPath $ArchivePath -CompressionLevel Optimal

if ($PdbPath -ne "" -and (Test-Path $PdbPath)) {
    $SymbolsDirectory = Join-Path $OutputDirectory "symbols"
    if (Test-Path $SymbolsDirectory) {
        Remove-Item -Recurse -Force -LiteralPath $SymbolsDirectory
    }
    New-Item -ItemType Directory -Force -Path $SymbolsDirectory | Out-Null
    Copy-Item -LiteralPath $PdbPath -Destination $SymbolsDirectory
    [System.IO.File]::WriteAllText(
        (Join-Path $SymbolsDirectory "commit.txt"),
        ("{0}`n" -f $CommitSha),
        $Encoding
    )
    if (Test-Path $SymbolsArchivePath) {
        Remove-Item -Force -LiteralPath $SymbolsArchivePath
    }
    Compress-Archive -Path (Join-Path $SymbolsDirectory "*") -DestinationPath $SymbolsArchivePath -CompressionLevel Optimal
}

Write-Host "Windows 阶段 0 诊断包已生成：$ArchivePath"
