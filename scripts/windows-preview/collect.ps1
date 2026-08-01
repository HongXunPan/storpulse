param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "windows-stage1-continuous-validation",
        "windows-stage1-disconnect-cleanup",
        "windows-stage1-connect-timeout-cleanup",
        "windows-stage1-service-fallback-validation",
        "windows-stage1-client-termination-cleanup",
        "windows-stage1-sleep-resume-validation",
        "package-validation"
    )]
    [string]$StageName,

    [ValidateRange(5, 60)]
    [int]$DurationSeconds = 8,

    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "collect-environment.ps1")
. (Join-Path $PSScriptRoot "invoke-client.ps1")
. (Join-Path $PSScriptRoot "privacy.ps1")
. (Join-Path $PSScriptRoot "service-diagnostics.ps1")
. (Join-Path $PSScriptRoot "diagnostic-export.ps1")
. (Join-Path $PSScriptRoot "lifecycle-gates.ps1")

$PackageRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ClientPath = Join-Path $PackageRoot "storpulse-windows-client.exe"
$ManifestPath = Join-Path $PackageRoot "package-manifest.json"
$InstalledServicePath = Join-Path ${env:ProgramFiles} "StorPulse\Collector\storpulse-windows-service.exe"
$DiagnosticsRoot = Join-Path $PackageRoot "diagnostics"
$RunId = "{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"), [Guid]::NewGuid().ToString("N").Substring(0, 8)
$RunDirectory = Join-Path $DiagnosticsRoot $RunId
$ArchivePath = Join-Path $DiagnosticsRoot ("storpulse-diagnostics-{0}-{1}.zip" -f $StageName, $RunId)
$StandardOutputPath = Join-Path $RunDirectory ".client-stdout.txt"
$StandardErrorPath = Join-Path $RunDirectory ".client-stderr.txt"
$GateMode = switch ($StageName) {
    "windows-stage1-disconnect-cleanup" { "disconnect_cleanup" }
    "windows-stage1-connect-timeout-cleanup" { "connect_timeout_cleanup" }
    "windows-stage1-service-fallback-validation" { "connect_timeout_cleanup" }
    "windows-stage1-client-termination-cleanup" { "client_termination_cleanup" }
    "windows-stage1-sleep-resume-validation" { "sleep_resume_validation" }
    default { "continuous_validation" }
}

$CollectorStatus = "initializing"
$FailureStage = "initialize"
$FailureSafeErrorCode = "collector_failure"
$FailureType = $null
$FailureHResult = $null
$ClientExitCode = $null
$ClientFinished = $false
$SleepResumePromptShown = $false
$ServiceFallbackSnapshot = $null
$ServiceFallbackConfirmed = $false
$PackageCommit = "unknown"
$ClientHashMatches = $false
$InstalledServiceHashMatches = $false
$ServiceInstalled = $false
$ServiceConfigReadable = $false
$ServiceManual = $false
$ServiceLocalSystem = $false
$ServicePathMatches = $false
$ActualAdministrator = $null
$OsSnapshot = $null
$Summary = $null
$ConsoleLines = New-Object System.Collections.Generic.List[string]

New-Item -ItemType Directory -Force -Path $RunDirectory | Out-Null

try {
    $FailureStage = "detect_environment"
    $ActualAdministrator = Test-Administrator
    if ($ActualAdministrator) {
        throw "standard_user_required"
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "x64_windows_required"
    }
    $OsSnapshot = Get-OsSnapshot

    $FailureStage = "validate_package"
    if (-not (Test-Path -LiteralPath $ClientPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "package_file_missing"
    }
    $Manifest = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8) |
        ConvertFrom-Json
    if ($Manifest.serviceName -ne "StorPulseCollector" -or
        $Manifest.serviceStartType -ne "demand") {
        throw "package_manifest_invalid"
    }
    $PackageCommit = [string]$Manifest.commitSha
    $ClientHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ClientPath).Hash.ToLowerInvariant()
    $ClientHashMatches = $ClientHash -eq ([string]$Manifest.clientSha256).ToLowerInvariant()
    if (-not $ClientHashMatches) {
        throw "client_hash_mismatch"
    }

    $FailureStage = "validate_service"
    $FailureSafeErrorCode = "service_validation_failed"
    $ServiceState = Get-InstalledServiceState `
        -ServiceName "StorPulseCollector" `
        -InstalledServicePath $InstalledServicePath `
        -ExpectedSha256 ([string]$Manifest.serviceSha256)
    $ServiceInstalled = [bool]$ServiceState.installed
    $ServiceConfigReadable = [bool]$ServiceState.configReadable
    $ServiceManual = [bool]$ServiceState.manual
    $ServiceLocalSystem = [bool]$ServiceState.localSystem
    $ServicePathMatches = [bool]$ServiceState.pathMatches
    $InstalledServiceHashMatches = [bool]$ServiceState.hashMatches
    if (-not $ServiceInstalled) {
        $FailureSafeErrorCode = "service_not_installed"
        throw "service_not_installed"
    }
    if (-not $ServiceConfigReadable) {
        $FailureSafeErrorCode = "service_config_query_unavailable"
        throw "service_config_query_unavailable"
    }
    if (-not $InstalledServiceHashMatches) {
        $FailureSafeErrorCode = "installed_service_hash_mismatch"
        throw "installed_service_hash_mismatch"
    }
    if (-not $ServiceManual -or -not $ServiceLocalSystem -or -not $ServicePathMatches) {
        $FailureSafeErrorCode = "installed_service_contract_mismatch"
        throw "installed_service_contract_mismatch"
    }

    if ($StageName -eq "windows-stage1-service-fallback-validation") {
        $FailureStage = "capture_service_fallback_baseline"
        $FailureSafeErrorCode = "service_fallback_validation_failed"
        $ServiceFallbackSnapshot = Get-ServiceFallbackSnapshot
    }

    $FailureStage = "run_client"
    $FailureSafeErrorCode = "client_execution_failed"
    $ClientRun = Invoke-StorPulseClient `
        -ClientPath $ClientPath `
        -OutputDirectory $RunDirectory `
        -RunId $RunId `
        -DurationSeconds $DurationSeconds `
        -StandardOutputPath $StandardOutputPath `
        -StandardErrorPath $StandardErrorPath `
        -GateMode $GateMode
    $ClientFinished = [bool]$ClientRun.finished
    $ClientExitCode = $ClientRun.exitCode
    $SleepResumePromptShown = [bool]$ClientRun.sleepResumePromptShown
    if (-not $ClientFinished) {
        throw "client_timeout"
    }

    if ($GateMode -eq "client_termination_cleanup") {
        $FailureStage = "validate_client_termination_cleanup"
        $FailureSafeErrorCode = "client_termination_cleanup_failed"
        $Summary = Complete-ClientTerminationGate `
            -ClientPath $ClientPath `
            -RunDirectory $RunDirectory `
            -RunId $RunId `
            -ClientRun $ClientRun
    }
    else {
        $FailureStage = "read_summary"
        $FailureSafeErrorCode = "summary_validation_failed"
        $SummaryPath = Join-Path $RunDirectory "summary.json"
        if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) {
            throw "summary_missing"
        }
        $Summary = [System.IO.File]::ReadAllText($SummaryPath, [System.Text.Encoding]::UTF8) |
            ConvertFrom-Json
    }
    if ($Summary.runId -ne $RunId -or
        $Summary.serviceName -ne "StorPulseCollector" -or
        $Summary.mode -ne $GateMode) {
        throw "summary_contract_mismatch"
    }
    if ($StageName -eq "windows-stage1-service-fallback-validation") {
        $FailureStage = "validate_service_fallback"
        $FailureSafeErrorCode = "service_fallback_validation_failed"
        $ServiceFallback = Confirm-ServiceFallbackValidation `
            -BeforeSnapshot $ServiceFallbackSnapshot `
            -RunDirectory $RunDirectory `
            -Summary $Summary
        $ServiceFallbackConfirmed = [bool]$ServiceFallback.confirmed
    }
    $CollectorStatus = "completed"
    $FailureStage = $null
}
catch {
    $CollectorStatus = "failed"
    $FailureType = $_.Exception.GetType().FullName
    $FailureHResult = [int]$_.Exception.HResult
}

foreach ($Line in @(Read-SafeConsole -Path $StandardOutputPath)) {
    $ConsoleLines.Add([string]$Line)
}
foreach ($Line in @(Read-SafeConsole -Path $StandardErrorPath)) {
    $ConsoleLines.Add([string]$Line)
}
if ($null -ne $FailureStage) {
    $ConsoleLines.Add("collector_failure_stage=$FailureStage")
    $ConsoleLines.Add("collector_failure_code=$FailureSafeErrorCode")
}
if ($null -ne $FailureType) {
    $ConsoleLines.Add("collector_failure_type=$FailureType")
}
if ($null -ne $FailureHResult) {
    $ConsoleLines.Add("collector_failure_hresult=$FailureHResult")
}

$ActiveWorkload = Join-Path $RunDirectory "workload-active"
if (Test-Path -LiteralPath $ActiveWorkload) {
    Remove-Item -Recurse -Force -LiteralPath $ActiveWorkload
}
$TemporarySummary = Join-Path $RunDirectory ".summary.json.writing"
if (Test-Path -LiteralPath $TemporarySummary) {
    Remove-Item -Force -LiteralPath $TemporarySummary
}
if ($null -eq $Summary) {
    $Summary = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        mode = $GateMode
        status = "failed"
        outcome = "windows_client_not_completed"
        serviceName = "StorPulseCollector"
        failure = [ordered]@{
            phase = if ($null -ne $FailureStage) { $FailureStage } else { "collector" }
            safeErrorCode = $FailureSafeErrorCode
            nativeCode = $null
        }
    }
    Write-Utf8Json -Path (Join-Path $RunDirectory "summary.json") -Value $Summary
}

$Errors = @()
$SummaryFailureProperty = $Summary.PSObject.Properties["failure"]
if ($null -ne $SummaryFailureProperty -and $null -ne $SummaryFailureProperty.Value) {
    $Errors += $SummaryFailureProperty.Value
}
if ($null -ne $FailureStage) {
    $Errors += [ordered]@{
        phase = $FailureStage
        safeErrorCode = $FailureSafeErrorCode
        failureType = $FailureType
        hresult = $FailureHResult
    }
}
$Capabilities = [ordered]@{
    schemaVersion = 1
    runId = $RunId
    stageName = $StageName
    actualAdministrator = $ActualAdministrator
    os = $OsSnapshot
    powershellMajorVersion = $PSVersionTable.PSVersion.Major
    packageCommit = $PackageCommit
    clientHashMatches = $ClientHashMatches
    serviceInstalled = $ServiceInstalled
    serviceConfigReadable = $ServiceConfigReadable
    serviceManual = $ServiceManual
    serviceLocalSystem = $ServiceLocalSystem
    servicePathMatches = $ServicePathMatches
    installedServiceHashMatches = $InstalledServiceHashMatches
    clientFinished = $ClientFinished
    clientExitCode = $ClientExitCode
    sleepResumePromptShown = $SleepResumePromptShown
    serviceFallbackConfirmed = $ServiceFallbackConfirmed
}
$DiagnosticFiles = @(Get-DiagnosticFileNames -RunDirectory $RunDirectory)
$DiagnosticManifest = [ordered]@{
    schemaVersion = 1
    product = "StorPulse Windows 持续采集实机诊断"
    runId = $RunId
    stageName = $StageName
    collectorStatus = $CollectorStatus
    packageCommit = $PackageCommit
    files = $DiagnosticFiles
    privacy = "只含平台能力、稳定错误码和聚合证据；不含原始 ETL、路径、命令行、用户名、SID 或 nonce"
}

$ExportResult = Export-StorPulseDiagnostic `
    -RunDirectory $RunDirectory `
    -ArchivePath $ArchivePath `
    -Manifest $DiagnosticManifest `
    -Capabilities $Capabilities `
    -Summary $Summary `
    -Errors $Errors `
    -ConsoleLines $ConsoleLines
$ArchiveCreated = [bool]$ExportResult.created

Write-Host "诊断流程状态：$CollectorStatus"
if ($null -ne $Summary) {
    Write-Host "能力结果：$($Summary.outcome)"
}
if ($ArchiveCreated) {
    Write-Host "请把下面这个 ZIP 返回给 StorPulse 开发者："
    Write-Host $ArchivePath
}
else {
    Write-Host "隐私检查未通过，未生成可提交 ZIP。" -ForegroundColor Red
}
if (-not $NoPause) {
    Read-Host "按回车键退出" | Out-Null
}

if (-not $ArchiveCreated -or
    $CollectorStatus -ne "completed" -or
    $Summary.status -ne "completed") {
    exit 1
}
