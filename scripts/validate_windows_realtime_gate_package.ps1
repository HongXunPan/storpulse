param(
    [Parameter(Mandatory = $true)] [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
$RequiredRootFiles = @(
    "StorPulse.Windows.App.exe",
    "storpulse-windows-service.exe",
    "storpulse_windows_client.dll",
    "storpulse_ffi.dll",
    "package-manifest.json",
    "SHA256SUMS.txt",
    "安装 StorPulse 按需服务.cmd",
    "运行 Windows 实时采集门禁.cmd",
    "卸载 StorPulse 按需服务.cmd",
    "Windows实时采集界面实机指南.md",
    "反馈问题.url"
)
$RequiredScripts = @(
    "install-service.ps1",
    "launch-service-install.ps1",
    "launch-service-uninstall.ps1",
    "uninstall-service.ps1"
)
foreach ($FileName in $RequiredRootFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $FileName) -PathType Leaf)) {
        throw "Windows 阶段 2C 测试包缺少文件：$FileName"
    }
}
foreach ($ScriptName in $RequiredScripts) {
    $ScriptPath = Join-Path (Join-Path $PackageRoot "scripts") $ScriptName
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Windows 阶段 2C 测试包缺少脚本：$ScriptName"
    }
    $Bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
    if ($Bytes.Length -lt 3 -or $Bytes[0] -ne 0xEF -or
        $Bytes[1] -ne 0xBB -or $Bytes[2] -ne 0xBF) {
        throw "PowerShell 5.1 脚本缺少 UTF-8 BOM：$ScriptName"
    }
}

$ApplicationResourceCandidates = @(
    (Join-Path $PackageRoot "resources.pri"),
    (Join-Path $PackageRoot "StorPulse.Windows.App.pri")
)
$ApplicationResource = $ApplicationResourceCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $ApplicationResource) {
    throw "Windows 阶段 2C 测试包缺少 WinUI 应用 PRI"
}

$Manifest = [System.IO.File]::ReadAllText(
    (Join-Path $PackageRoot "package-manifest.json"),
    [System.Text.Encoding]::UTF8
) | ConvertFrom-Json
if ($Manifest.schemaVersion -ne 1 -or
    $Manifest.target -ne "win-x64" -or
    $Manifest.serviceName -ne "StorPulseCollector" -or
    $Manifest.serviceStartType -ne "demand" -or
    $Manifest.protocolVersion -ne 1 -or
    $Manifest.snapshotSchemaVersion -ne 2 -or
    $Manifest.realtimeSnapshotSchemaVersion -ne 2 -or
    $Manifest.signed -ne $false) {
    throw "Windows 阶段 2C 测试包清单契约不匹配"
}

$HashChecks = [ordered]@{
    "StorPulse.Windows.App.exe" = "applicationSha256"
    "storpulse-windows-service.exe" = "serviceSha256"
    "storpulse_windows_client.dll" = "clientLibrarySha256"
    "storpulse_ffi.dll" = "engineLibrarySha256"
}
foreach ($Entry in $HashChecks.GetEnumerator()) {
    $ActualHash = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath (Join-Path $PackageRoot $Entry.Key)).Hash.ToLowerInvariant()
    $ExpectedHash = ([string]$Manifest.PSObject.Properties[$Entry.Value].Value).ToLowerInvariant()
    if ($ActualHash -ne $ExpectedHash) {
        throw "Windows 阶段 2C 测试包哈希不匹配：$($Entry.Key)"
    }
}

$RunText = [System.IO.File]::ReadAllText(
    (Join-Path $PackageRoot "运行 Windows 实时采集门禁.cmd"),
    [System.Text.Encoding]::UTF8
)
if (-not $RunText.Contains("STORPULSE_SHELL_GATE_CONSOLE=1") -or
    -not $RunText.Contains('start "" /wait "%~dp0StorPulse.Windows.App.exe"') -or
    -not $RunText.Contains("Stage 2C realtime collection gate") -or
    $RunText.Contains("-Verb RunAs") -or
    $RunText -notmatch "(?m)^pause\r?$") {
    throw "Windows 阶段 2C 标准用户入口不完整"
}

$InstallerText = [System.IO.File]::ReadAllText(
    (Join-Path $PackageRoot "scripts/install-service.ps1"),
    [System.Text.Encoding]::UTF8
)
if (-not $InstallerText.Contains("New-Service @ServiceParameters") -or
    -not $InstallerText.Contains('$ServiceSddl = "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCRPLCLORC;;;IU)"')) {
    throw "Windows 阶段 2C 安装脚本没有保持手动服务与最小交互用户权限"
}

$FeedbackText = [System.IO.File]::ReadAllText(
    (Join-Path $PackageRoot "反馈问题.url"),
    [System.Text.Encoding]::UTF8
)
if (-not $FeedbackText.Contains("https://github.com/HongXunPan/storpulse/issues/new")) {
    throw "Windows 阶段 2C 测试包缺少显式反馈渠道"
}

Write-Host "Windows 阶段 2C 测试包结构、权限、资源、哈希和反馈入口校验通过。"
