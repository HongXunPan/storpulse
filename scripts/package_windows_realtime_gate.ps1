param(
    [Parameter(Mandatory = $true)] [string]$ApplicationDirectory,
    [Parameter(Mandatory = $true)] [string]$ServiceBinaryPath,
    [Parameter(Mandatory = $true)] [string]$ClientLibraryPath,
    [Parameter(Mandatory = $true)] [string]$EngineLibraryPath,
    [Parameter(Mandatory = $true)] [string]$OutputDirectory,
    [Parameter(Mandatory = $true)] [string]$CommitSha
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ApplicationDirectory = [System.IO.Path]::GetFullPath($ApplicationDirectory)
$ServiceBinaryPath = [System.IO.Path]::GetFullPath($ServiceBinaryPath)
$ClientLibraryPath = [System.IO.Path]::GetFullPath($ClientLibraryPath)
$EngineLibraryPath = [System.IO.Path]::GetFullPath($EngineLibraryPath)
$RequiredInputs = @(
    (Join-Path $ApplicationDirectory "StorPulse.Windows.App.exe"),
    $ServiceBinaryPath,
    $ClientLibraryPath,
    $EngineLibraryPath
)
foreach ($InputPath in $RequiredInputs) {
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "找不到 Windows 阶段 2C 构建产物：$InputPath"
    }
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$PackageRoot = Join-Path $OutputDirectory "storpulse-windows-stage2c-x64"
$ScriptsDirectory = Join-Path $PackageRoot "scripts"
if (Test-Path -LiteralPath $PackageRoot) {
    Remove-Item -Recurse -Force -LiteralPath $PackageRoot
}
New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null
Copy-Item -Path (Join-Path $ApplicationDirectory "*") -Destination $PackageRoot -Recurse -Force
New-Item -ItemType Directory -Force -Path $ScriptsDirectory | Out-Null

$ServiceDestination = Join-Path $PackageRoot "storpulse-windows-service.exe"
$ClientLibraryDestination = Join-Path $PackageRoot "storpulse_windows_client.dll"
$EngineLibraryDestination = Join-Path $PackageRoot "storpulse_ffi.dll"
Copy-Item -LiteralPath $ServiceBinaryPath -Destination $ServiceDestination
Copy-Item -LiteralPath $ClientLibraryPath -Destination $ClientLibraryDestination
Copy-Item -LiteralPath $EngineLibraryPath -Destination $EngineLibraryDestination

$ScriptNames = @(
    "install-service.ps1",
    "launch-service-install.ps1",
    "launch-service-uninstall.ps1",
    "uninstall-service.ps1"
)
foreach ($ScriptName in $ScriptNames) {
    Copy-Item `
        -LiteralPath (Join-Path $Root ("scripts/windows-preview/{0}" -f $ScriptName)) `
        -Destination $ScriptsDirectory
}
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/install-service.cmd") `
    -Destination (Join-Path $PackageRoot "安装 StorPulse 按需服务.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/uninstall-service.cmd") `
    -Destination (Join-Path $PackageRoot "卸载 StorPulse 按需服务.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-realtime-gate/run-realtime-gate.cmd") `
    -Destination (Join-Path $PackageRoot "运行 Windows 实时采集门禁.cmd")
Copy-Item -LiteralPath (Join-Path $Root "docs/Windows实时采集界面实机指南.md") `
    -Destination $PackageRoot

$Encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    (Join-Path $PackageRoot "反馈问题.url"),
    "[InternetShortcut]`r`nURL=https://github.com/HongXunPan/storpulse/issues/new`r`n",
    $Encoding
)

$ApplicationPath = Join-Path $PackageRoot "StorPulse.Windows.App.exe"
$ApplicationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ApplicationPath).Hash.ToLowerInvariant()
$ServiceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ServiceDestination).Hash.ToLowerInvariant()
$ClientLibraryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ClientLibraryDestination).Hash.ToLowerInvariant()
$EngineLibraryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $EngineLibraryDestination).Hash.ToLowerInvariant()
$Manifest = [ordered]@{
    schemaVersion = 1
    product = "StorPulse Windows 阶段 2C 实时采集界面测试包"
    commitSha = $CommitSha
    target = "win-x64"
    applicationSha256 = $ApplicationHash
    serviceSha256 = $ServiceHash
    clientLibrarySha256 = $ClientLibraryHash
    engineLibrarySha256 = $EngineLibraryHash
    signed = $false
    serviceName = "StorPulseCollector"
    serviceStartType = "demand"
    protocolVersion = 1
    snapshotSchemaVersion = 2
    realtimeSnapshotSchemaVersion = 2
    createdAtUtc = [DateTime]::UtcNow.ToString("o")
}
[System.IO.File]::WriteAllText(
    (Join-Path $PackageRoot "package-manifest.json"),
    ($Manifest | ConvertTo-Json -Depth 5),
    $Encoding
)
$HashLines = @(
    ("{0}  StorPulse.Windows.App.exe" -f $ApplicationHash),
    ("{0}  storpulse-windows-service.exe" -f $ServiceHash),
    ("{0}  storpulse_windows_client.dll" -f $ClientLibraryHash),
    ("{0}  storpulse_ffi.dll" -f $EngineLibraryHash)
)
[System.IO.File]::WriteAllText(
    (Join-Path $PackageRoot "SHA256SUMS.txt"),
    (($HashLines -join "`n") + "`n"),
    $Encoding
)

Write-Host "Windows 阶段 2C 实时采集界面测试包已生成：$PackageRoot"
