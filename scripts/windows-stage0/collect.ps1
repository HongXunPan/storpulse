param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Standard", "PerformanceLogUser", "Administrator", "Service")]
    [string]$ExpectedMode,

    [Parameter(Mandatory = $true)]
    [ValidateSet("standard-collection", "performance-log-user-collection", "administrator-collection", "service-collection", "service-disconnect-validation", "package-validation")]
    [string]$StageName,

    [ValidateRange(5, 300)]
    [int]$DurationSeconds = 15,

    [switch]$NoPause,

    [switch]$DisconnectAfterReady
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "collect-environment.ps1")
. (Join-Path $PSScriptRoot "invoke-probe.ps1")

$PackageRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ProbePath = Join-Path $PackageRoot "storpulse-windows-probe.exe"
$ManifestPath = Join-Path $PackageRoot "package-manifest.json"
$DiagnosticsRoot = Join-Path $PackageRoot "diagnostics"
$RunId = "{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"), [Guid]::NewGuid().ToString("N").Substring(0, 8)
$RunDirectory = Join-Path $DiagnosticsRoot $RunId
$ArchivePath = Join-Path $DiagnosticsRoot ("storpulse-diagnostics-{0}-{1}.zip" -f $StageName, $RunId)

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $Json = $Value | ConvertTo-Json -Depth 10
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Json, $Encoding)
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Value
    )

    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $Encoding)
}

$ActualAdministrator = $null
$PerformanceLogUser = $null
$OsSnapshot = $null
$PackageCommit = "unknown"
$ExpectedHash = ""
$ActualHash = ""
$HashMatches = $false
$ModeMatches = $false
$ProbeExitCode = $null
$ProbeOutcome = $null
$EtwSessionStarted = $null
$EtwConsumerStarted = $null
$EtwStartStatus = $null
$WorkloadCompleted = $null
$SequentialReadMode = $null
$ServiceLocalSystem = $null
$ServiceClientAuthenticated = $null
$ServiceClientElevated = $null
$ServiceStopped = $null
$ServiceDisconnectCleanupTest = $null
$CollectorStatus = "initializing"
$FailureStage = "initialize"
$FailureType = $null
$FailureHResult = $null
$StandardOutputPath = Join-Path $RunDirectory ".probe-stdout.txt"
$StandardErrorPath = Join-Path $RunDirectory ".probe-stderr.txt"

New-Item -ItemType Directory -Force -Path $RunDirectory | Out-Null

try {
    $FailureStage = "detect_privileges"
    $ActualAdministrator = Test-Administrator
    $PerformanceLogUser = Test-PerformanceLogUser

    $FailureStage = "read_os"
    $OsSnapshot = Get-OsSnapshot

    $FailureStage = "read_manifest"
    if (Test-Path $ManifestPath) {
        $ManifestText = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
        $Manifest = $ManifestText | ConvertFrom-Json
        $ProbeHashProperty = $Manifest.PSObject.Properties["probeSha256"]
        $CommitProperty = $Manifest.PSObject.Properties["commitSha"]
        if ($null -ne $ProbeHashProperty) {
            $ExpectedHash = [string]$ProbeHashProperty.Value
        }
        if ($null -ne $CommitProperty) {
            $PackageCommit = [string]$CommitProperty.Value
        }
    }

    $FailureStage = "hash_probe"
    if (Test-Path $ProbePath) {
        $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ProbePath).Hash.ToLowerInvariant()
    }
    $HashMatches = $ExpectedHash -ne "" -and $ActualHash -eq $ExpectedHash.ToLowerInvariant()
    $ModeMatches = switch ($ExpectedMode) {
        "Administrator" { $ActualAdministrator }
        "PerformanceLogUser" { -not $ActualAdministrator -and $PerformanceLogUser -eq $true }
        "Standard" { -not $ActualAdministrator -and $PerformanceLogUser -eq $false }
        "Service" { -not $ActualAdministrator }
    }
    $CollectorStatus = "not_started"

    $FailureStage = "validate_probe"
    if (-not (Test-Path $ProbePath)) {
        $CollectorStatus = "probe_missing"
        throw "探针文件缺失"
    }
    if (-not $HashMatches) {
        $CollectorStatus = "hash_mismatch"
        throw "探针哈希不匹配"
    }
    if (-not $ModeMatches) {
        $CollectorStatus = "mode_mismatch"
        throw "当前权限模式与所选入口不一致"
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        $CollectorStatus = "unsupported_architecture"
        throw "当前不是 x64 Windows"
    }

    $FailureStage = "run_probe"
    $ProbeRun = Invoke-StorPulseProbe `
        -ProbePath $ProbePath `
        -OutputDirectory $RunDirectory `
        -DurationSeconds $DurationSeconds `
        -StandardOutputPath $StandardOutputPath `
        -StandardErrorPath $StandardErrorPath `
        -ServiceMode:($ExpectedMode -eq "Service") `
        -DisconnectAfterReady:$DisconnectAfterReady
    if (-not $ProbeRun.finished) {
        $CollectorStatus = "probe_timeout"
        $FailureStage = "probe_timeout"
    }
    elseif ($null -eq $ProbeRun.exitCode) {
        $CollectorStatus = "probe_exit_code_missing"
        $FailureStage = "probe_exit_code"
        throw "无法读取探针退出码"
    }
    else {
        $ProbeExitCode = [int]$ProbeRun.exitCode
        if ($ProbeExitCode -ne 0) {
            $CollectorStatus = "probe_failed"
            $FailureStage = "probe_exit"
        }
        else {
            $CollectorStatus = "probe_report_invalid"
            $FailureStage = "read_probe_summary"
            $ProbeSummaryPath = Join-Path $RunDirectory "summary.json"
            if (-not (Test-Path -LiteralPath $ProbeSummaryPath -PathType Leaf)) {
                throw "探针没有生成 summary.json"
            }
            $ProbeSummaryText = [System.IO.File]::ReadAllText($ProbeSummaryPath, [System.Text.Encoding]::UTF8)
            $ProbeSummary = $ProbeSummaryText | ConvertFrom-Json
            $ProbeOutcome = [string]$ProbeSummary.outcome
            $EtwSessionStarted = [bool]$ProbeSummary.etw.sessionStarted
            $EtwConsumerStarted = [bool]$ProbeSummary.etw.consumerStarted
            $EtwStartStatus = [int]$ProbeSummary.etw.startStatus
            $WorkloadCompleted = [bool]$ProbeSummary.workload.completed
            $SequentialReadMode = $ProbeSummary.workload.sequentialReadMode
            $ServiceProperty = $ProbeSummary.PSObject.Properties["service"]
            if ($null -ne $ServiceProperty) {
                $ServiceSummary = $ServiceProperty.Value
                $ServiceLocalSystem = [bool]$ServiceSummary.serviceLocalSystem
                $ServiceClientAuthenticated = [bool]$ServiceSummary.clientAuthenticated
                $ServiceClientElevated = $ServiceSummary.clientElevated
                $ServiceStopped = [bool]$ServiceSummary.serviceStopped
                $ServiceDisconnectCleanupTest = [bool]$ServiceSummary.disconnectCleanupTest
            }
            $CollectorStatus = "completed"
            $FailureStage = $null
        }
    }
}
catch {
    if ($CollectorStatus -eq "initializing" -or $CollectorStatus -eq "not_started") {
        $CollectorStatus = "collector_failed"
    }
    $FailureType = $_.Exception.GetType().FullName
    $FailureHResult = [int]$_.Exception.HResult
}
finally {
    $ConsoleLines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $StandardOutputPath) {
        foreach ($Line in [System.IO.File]::ReadAllLines($StandardOutputPath, [System.Text.Encoding]::UTF8)) {
            $ConsoleLines.Add([string]$Line)
        }
        Remove-Item -Force -LiteralPath $StandardOutputPath
    }
    if (Test-Path $StandardErrorPath) {
        foreach ($Line in [System.IO.File]::ReadAllLines($StandardErrorPath, [System.Text.Encoding]::UTF8)) {
            $ConsoleLines.Add([string]$Line)
        }
        Remove-Item -Force -LiteralPath $StandardErrorPath
    }

    if ($null -ne $FailureStage) {
        $ConsoleLines.Add("collector_failure_stage=$FailureStage")
    }
    if ($null -ne $FailureType) {
        $ConsoleLines.Add("collector_failure_type=$FailureType")
    }
    if ($null -ne $FailureHResult) {
        $ConsoleLines.Add("collector_failure_hresult=$FailureHResult")
    }

    $Environment = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        collectedAtUtc = [DateTime]::UtcNow.ToString("o")
        expectedMode = $ExpectedMode
        actualAdministrator = $ActualAdministrator
        performanceLogUser = $PerformanceLogUser
        modeMatches = $ModeMatches
        os = $OsSnapshot
        powershellMajorVersion = $PSVersionTable.PSVersion.Major
        packageCommit = $PackageCommit
    }

    $CollectorResult = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        status = $CollectorStatus
        probeExitCode = $ProbeExitCode
        probeOutcome = $ProbeOutcome
        etwSessionStarted = $EtwSessionStarted
        etwConsumerStarted = $EtwConsumerStarted
        etwStartStatus = $EtwStartStatus
        workloadCompleted = $WorkloadCompleted
        sequentialReadMode = $SequentialReadMode
        serviceLocalSystem = $ServiceLocalSystem
        serviceClientAuthenticated = $ServiceClientAuthenticated
        serviceClientElevated = $ServiceClientElevated
        serviceStopped = $ServiceStopped
        serviceDisconnectCleanupTest = $ServiceDisconnectCleanupTest
        expectedMode = $ExpectedMode
        actualAdministrator = $ActualAdministrator
        performanceLogUser = $PerformanceLogUser
        modeMatches = $ModeMatches
        expectedProbeSha256 = $ExpectedHash.ToLowerInvariant()
        actualProbeSha256 = $ActualHash
        hashMatches = $HashMatches
        failureStage = $FailureStage
        failureType = $FailureType
        failureHResult = $FailureHResult
    }

    $FinalizationFailures = New-Object System.Collections.Generic.List[string]
    try {
        Write-Utf8Json -Path (Join-Path $RunDirectory "environment.json") -Value $Environment
    }
    catch {
        $FinalizationFailures.Add("environment_json|$($_.Exception.GetType().FullName)|$([int]$_.Exception.HResult)")
    }
    try {
        $Encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines(
            (Join-Path $RunDirectory "console.log"),
            $ConsoleLines,
            $Encoding
        )
    }
    catch {
        $FinalizationFailures.Add("console_log|$($_.Exception.GetType().FullName)|$([int]$_.Exception.HResult)")
    }
    try {
        Write-Utf8Json -Path (Join-Path $RunDirectory "collector-result.json") -Value $CollectorResult
    }
    catch {
        $FinalizationFailures.Add("collector_result|$($_.Exception.GetType().FullName)|$([int]$_.Exception.HResult)")
    }
    if ($FinalizationFailures.Count -gt 0) {
        Write-Utf8Text `
            -Path (Join-Path $RunDirectory "finalization-errors.log") `
            -Value ($FinalizationFailures -join "`n")
    }

    $ActiveWorkload = Join-Path $RunDirectory "workload-active"
    if (Test-Path $ActiveWorkload) {
        Remove-Item -Recurse -Force -LiteralPath $ActiveWorkload
    }
    if (Test-Path $ArchivePath) {
        Remove-Item -Force -LiteralPath $ArchivePath
    }
    Compress-Archive -Path (Join-Path $RunDirectory "*") -DestinationPath $ArchivePath -CompressionLevel Optimal
}

Write-Host "诊断已完成。请把下面这个 ZIP 返回给 StorPulse 开发者："
Write-Host $ArchivePath
Write-Host "诊断流程状态：$CollectorStatus"
if ($null -ne $ProbeOutcome) {
    Write-Host "能力结果：$ProbeOutcome"
    Write-Host "ETW：sessionStarted=$EtwSessionStarted consumerStarted=$EtwConsumerStarted startStatus=$EtwStartStatus"
    Write-Host "负载：completed=$WorkloadCompleted sequentialReadMode=$SequentialReadMode"
}
if (-not $NoPause) {
    Read-Host "按回车键退出" | Out-Null
}

if ($CollectorStatus -ne "completed") {
    exit 1
}
