param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
$CollectorPath = Join-Path $PackageRoot "scripts/collect.ps1"
$DiagnosticsRoot = Join-Path $PackageRoot "diagnostics"

if (-not (Test-Path -LiteralPath $CollectorPath -PathType Leaf)) {
    throw "找不到成品包采集入口：$CollectorPath"
}
if (Test-Path -LiteralPath $DiagnosticsRoot) {
    Remove-Item -Recurse -Force -LiteralPath $DiagnosticsRoot
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
$ActualAdministrator = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$ExpectedMode = if ($ActualAdministrator) { "Administrator" } else { "Standard" }

& powershell.exe `
    -NoLogo `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $CollectorPath `
    -ExpectedMode $ExpectedMode `
    -DurationSeconds 5 `
    -NoPause
$CollectorExitCode = $LASTEXITCODE

$RunDirectory = Get-ChildItem -LiteralPath $DiagnosticsRoot -Directory |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if ($null -eq $RunDirectory) {
    throw "成品包采集入口没有生成运行目录"
}

$RequiredFiles = @(
    "environment.json",
    "collector-result.json",
    "console.log",
    "summary.json",
    "errors.json",
    "timeline.ndjson",
    "workload.json"
)
foreach ($RequiredFile in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $RunDirectory.FullName $RequiredFile) -PathType Leaf)) {
        throw "成品包采集结果缺少文件：$RequiredFile"
    }
}

$CollectorResultPath = Join-Path $RunDirectory.FullName "collector-result.json"
$CollectorResultText = [System.IO.File]::ReadAllText($CollectorResultPath, [System.Text.Encoding]::UTF8)
$CollectorResult = $CollectorResultText | ConvertFrom-Json
if ($CollectorExitCode -ne 0 -or $CollectorResult.status -ne "completed") {
    throw "成品包采集入口失败：exitCode=$CollectorExitCode status=$($CollectorResult.status)"
}

$ArchivePath = Join-Path $DiagnosticsRoot ("storpulse-diagnostics-{0}.zip" -f $CollectorResult.runId)
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "成品包采集入口没有生成诊断 ZIP：$ArchivePath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $ArchiveEntries = @($Archive.Entries | ForEach-Object { $_.FullName })
    foreach ($RequiredFile in $RequiredFiles) {
        if ($ArchiveEntries -notcontains $RequiredFile) {
            throw "诊断 ZIP 缺少文件：$RequiredFile"
        }
    }
}
finally {
    $Archive.Dispose()
}

Write-Host "Windows 阶段 0 成品包入口、日志和 ZIP 冒烟通过。"
