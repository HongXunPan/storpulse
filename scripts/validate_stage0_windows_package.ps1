param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-PackageDiagnostics {
    param([Parameter(Mandatory = $true)] [string]$Directory)

    foreach ($FileName in @("collector-result.json", "console.log", "summary.json", "errors.json", "workload.json", "timeline.ndjson")) {
        $Path = Join-Path $Directory $FileName
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Write-Host "===== $FileName ====="
            Write-Host ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
        }
    }
}

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
    Write-PackageDiagnostics -Directory $RunDirectory.FullName
    throw "成品包采集入口失败：exitCode=$CollectorExitCode status=$($CollectorResult.status)"
}

$SummaryPath = Join-Path $RunDirectory.FullName "summary.json"
$SummaryText = [System.IO.File]::ReadAllText($SummaryPath, [System.Text.Encoding]::UTF8)
$Summary = $SummaryText | ConvertFrom-Json
if ($CollectorResult.probeOutcome -ne $Summary.outcome -or
    $CollectorResult.etwSessionStarted -ne $Summary.etw.sessionStarted -or
    $CollectorResult.etwConsumerStarted -ne $Summary.etw.consumerStarted -or
    $CollectorResult.workloadCompleted -ne $Summary.workload.completed -or
    $CollectorResult.sequentialReadMode -ne $Summary.workload.sequentialReadMode) {
    Write-PackageDiagnostics -Directory $RunDirectory.FullName
    throw "成品包采集摘要与探针报告不一致"
}
if (-not $Summary.etw.sessionStarted -or -not $Summary.etw.consumerStarted) {
    Write-PackageDiagnostics -Directory $RunDirectory.FullName
    throw "成品包 ETW 会话没有成功启动：startStatus=$($Summary.etw.startStatus) openStatus=$($Summary.etw.openStatus)"
}
if (-not $Summary.workload.completed -or $Summary.workload.sequentialReadMode -ne "windows_unbuffered_file") {
    Write-PackageDiagnostics -Directory $RunDirectory.FullName
    throw "成品包没有完成绕过系统缓存的读取负载"
}
if ($Summary.workload.sequentialReadBytes -ne $Summary.workload.sequentialWriteBytes) {
    Write-PackageDiagnostics -Directory $RunDirectory.FullName
    throw "成品包顺序读写负载字节数不一致"
}
$ProbeEtw = @($Summary.etw.topProcesses | Where-Object { $_.isProbe }) | Select-Object -First 1
if ($null -eq $ProbeEtw -or $ProbeEtw.readBytes -le 0 -or $Summary.etw.diskReadEvents -le 0) {
    Write-PackageDiagnostics -Directory $RunDirectory.FullName
    throw "成品包 ETW 没有观察到探针的不缓存读取"
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
