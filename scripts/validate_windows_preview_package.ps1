param(
    [Parameter(Mandatory = $true)] [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
$RequiredRootFiles = @(
    "storpulse-windows-service.exe",
    "storpulse-windows-client.exe",
    "package-manifest.json",
    "SHA256SUMS.txt",
    "安装 StorPulse 按需服务.cmd",
    "验证持续采集.cmd",
    "收集断连清理.cmd",
    "卸载 StorPulse 按需服务.cmd",
    "Windows持续采集实机验证指南.md",
    "反馈问题.url"
)
$RequiredScripts = @(
    "collect-environment.ps1",
    "collect.ps1",
    "install-service.ps1",
    "invoke-client.ps1",
    "launch-service-install.ps1",
    "launch-service-uninstall.ps1",
    "privacy.ps1",
    "uninstall-service.ps1"
)
foreach ($FileName in $RequiredRootFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $FileName) -PathType Leaf)) {
        throw "Windows 实机测试包缺少文件：$FileName"
    }
}
foreach ($ScriptName in $RequiredScripts) {
    $ScriptPath = Join-Path (Join-Path $PackageRoot "scripts") $ScriptName
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Windows 实机测试包缺少脚本：$ScriptName"
    }
    $Bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
    if ($Bytes.Length -lt 3 -or $Bytes[0] -ne 0xEF -or $Bytes[1] -ne 0xBB -or $Bytes[2] -ne 0xBF) {
        throw "PowerShell 5.1 脚本缺少 UTF-8 BOM：$ScriptName"
    }
}

$Manifest = [System.IO.File]::ReadAllText(
    (Join-Path $PackageRoot "package-manifest.json"),
    [System.Text.Encoding]::UTF8
) | ConvertFrom-Json
if ($Manifest.serviceName -ne "StorPulseCollector" -or
    $Manifest.serviceStartType -ne "demand" -or
    $Manifest.protocolVersion -ne 1 -or
    $Manifest.snapshotSchemaVersion -ne 2) {
    throw "Windows 实机测试包清单契约不匹配"
}
$ServiceHash = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath (Join-Path $PackageRoot "storpulse-windows-service.exe")).Hash.ToLowerInvariant()
$ClientHash = (Get-FileHash -Algorithm SHA256 `
    -LiteralPath (Join-Path $PackageRoot "storpulse-windows-client.exe")).Hash.ToLowerInvariant()
if ($ServiceHash -ne ([string]$Manifest.serviceSha256).ToLowerInvariant() -or
    $ClientHash -ne ([string]$Manifest.clientSha256).ToLowerInvariant()) {
    throw "Windows 实机测试包二进制哈希不匹配"
}

$InstallerText = [System.IO.File]::ReadAllText(
    (Join-Path $PackageRoot "scripts/install-service.ps1"),
    [System.Text.Encoding]::UTF8
)
if (-not $InstallerText.Contains("New-Service @ServiceParameters") -or
    $InstallerText.Contains('"create", $ServiceName') -or
    -not $InstallerText.Contains('$ServiceSddl = "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;RPLCLORC;;;IU)"')) {
    throw "安装脚本没有使用原生手动服务与最小交互用户权限"
}
$CollectorText = [System.IO.File]::ReadAllText(
    (Join-Path $PackageRoot "scripts/collect.ps1"),
    [System.Text.Encoding]::UTF8
)
if ($CollectorText.Contains("-Verb RunAs") -or
    -not $CollectorText.Contains("standard_user_required") -or
    -not $CollectorText.Contains("Test-DiagnosticArchivePrivacy") -or
    -not $CollectorText.Contains("unexpected_diagnostic_content")) {
    throw "采集脚本没有保持标准用户或缺少归档白名单隐私检查"
}

$EntryChecks = [ordered]@{
    "安装 StorPulse 按需服务.cmd" = "launch-service-install.ps1"
    "验证持续采集.cmd" = "windows-stage1-continuous-validation"
    "收集断连清理.cmd" = "windows-stage1-disconnect-cleanup"
    "卸载 StorPulse 按需服务.cmd" = "launch-service-uninstall.ps1"
}
foreach ($Entry in $EntryChecks.GetEnumerator()) {
    $EntryText = [System.IO.File]::ReadAllText(
        (Join-Path $PackageRoot $Entry.Key),
        [System.Text.Encoding]::UTF8
    )
    if (-not $EntryText.Contains($Entry.Value) -or $EntryText -notmatch "(?m)^pause\r?$") {
        throw "入口不会保留输出或阶段名不正确：$($Entry.Key)"
    }
}

$FeedbackText = [System.IO.File]::ReadAllText(
    (Join-Path $PackageRoot "反馈问题.url"),
    [System.Text.Encoding]::UTF8
)
if (-not $FeedbackText.Contains("https://github.com/HongXunPan/storpulse/issues/new")) {
    throw "Windows 实机测试包缺少显式反馈渠道"
}
Write-Host "Windows 阶段 1 实机测试包结构、权限、哈希、日志和反馈入口校验通过。"
