param(
    [Parameter(Mandatory = $true)] [string]$ServiceBinaryPath,
    [Parameter(Mandatory = $true)] [string]$ClientBinaryPath,
    [Parameter(Mandatory = $true)] [string]$OutputDirectory,
    [Parameter(Mandatory = $true)] [string]$CommitSha
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ServiceBinaryPath = [System.IO.Path]::GetFullPath($ServiceBinaryPath)
$ClientBinaryPath = [System.IO.Path]::GetFullPath($ClientBinaryPath)
foreach ($BinaryPath in @($ServiceBinaryPath, $ClientBinaryPath)) {
    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
        throw "找不到 Windows 产品构建产物：$BinaryPath"
    }
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$PackageRoot = Join-Path $OutputDirectory "storpulse-windows-stage1-x64"
$ScriptsDirectory = Join-Path $PackageRoot "scripts"
$ArchivePath = Join-Path $OutputDirectory "storpulse-windows-stage1-x64.zip"
if (Test-Path -LiteralPath $PackageRoot) {
    Remove-Item -Recurse -Force -LiteralPath $PackageRoot
}
New-Item -ItemType Directory -Force -Path $ScriptsDirectory | Out-Null

$ServiceDestination = Join-Path $PackageRoot "storpulse-windows-service.exe"
$ClientDestination = Join-Path $PackageRoot "storpulse-windows-client.exe"
Copy-Item -LiteralPath $ServiceBinaryPath -Destination $ServiceDestination
Copy-Item -LiteralPath $ClientBinaryPath -Destination $ClientDestination

$ScriptNames = @(
    "collect-environment.ps1",
    "collect.ps1",
    "diagnostic-export.ps1",
    "install-service.ps1",
    "invoke-client.ps1",
    "launch-service-install.ps1",
    "launch-service-uninstall.ps1",
    "lifecycle-gates.ps1",
    "privacy.ps1",
    "uninstall-service.ps1"
)
foreach ($ScriptName in $ScriptNames) {
    Copy-Item `
        -LiteralPath (Join-Path $Root ("scripts/windows-preview/{0}" -f $ScriptName)) `
        -Destination $ScriptsDirectory
}
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/install-service.cmd") `
    -Destination (Join-Path $PackageRoot "安装 StorPulse 按需服务.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/validate-continuous.cmd") `
    -Destination (Join-Path $PackageRoot "验证持续采集.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/collect-disconnect.cmd") `
    -Destination (Join-Path $PackageRoot "收集断连清理.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/collect-connect-timeout.cmd") `
    -Destination (Join-Path $PackageRoot "验证连接超时清理.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/collect-client-termination.cmd") `
    -Destination (Join-Path $PackageRoot "验证客户端强杀清理.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/validate-sleep-resume.cmd") `
    -Destination (Join-Path $PackageRoot "验证休眠恢复.cmd")
Copy-Item -LiteralPath (Join-Path $Root "scripts/windows-preview/uninstall-service.cmd") `
    -Destination (Join-Path $PackageRoot "卸载 StorPulse 按需服务.cmd")
Copy-Item -LiteralPath (Join-Path $Root "docs/Windows持续采集实机验证指南.md") `
    -Destination $PackageRoot

$Encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    (Join-Path $PackageRoot "反馈问题.url"),
    "[InternetShortcut]`r`nURL=https://github.com/HongXunPan/storpulse/issues/new`r`n",
    $Encoding
)

$ServiceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ServiceDestination).Hash.ToLowerInvariant()
$ClientHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ClientDestination).Hash.ToLowerInvariant()
$Manifest = [ordered]@{
    schemaVersion = 1
    product = "StorPulse Windows 阶段 1 持续采集实机测试包"
    commitSha = $CommitSha
    target = "x86_64-pc-windows-msvc"
    serviceSha256 = $ServiceHash
    clientSha256 = $ClientHash
    signed = $false
    serviceName = "StorPulseCollector"
    serviceStartType = "demand"
    protocolVersion = 1
    snapshotSchemaVersion = 2
    createdAtUtc = [DateTime]::UtcNow.ToString("o")
}
[System.IO.File]::WriteAllText(
    (Join-Path $PackageRoot "package-manifest.json"),
    ($Manifest | ConvertTo-Json -Depth 5),
    $Encoding
)
[System.IO.File]::WriteAllText(
    (Join-Path $PackageRoot "SHA256SUMS.txt"),
    ("{0}  storpulse-windows-service.exe`n{1}  storpulse-windows-client.exe`n" -f $ServiceHash, $ClientHash),
    $Encoding
)

if (Test-Path -LiteralPath $ArchivePath) {
    Remove-Item -Force -LiteralPath $ArchivePath
}
Compress-Archive -Path (Join-Path $PackageRoot "*") -DestinationPath $ArchivePath -CompressionLevel Optimal
Write-Host "Windows 阶段 1 实机测试包已生成：$ArchivePath"
