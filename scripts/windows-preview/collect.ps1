param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows-stage1-continuous-validation", "windows-stage1-disconnect-cleanup", "package-validation")]
    [string]$StageName,

    [ValidateRange(5, 60)]
    [int]$DurationSeconds = 8,

    [switch]$DisconnectAfterReady,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "collect-environment.ps1")
. (Join-Path $PSScriptRoot "invoke-client.ps1")
. (Join-Path $PSScriptRoot "privacy.ps1")

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

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 12),
        $Encoding
    )
}

function Read-SafeConsole {
    param([Parameter(Mandatory = $true)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $Lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
    Remove-Item -Force -LiteralPath $Path
    return $Lines
}

$CollectorStatus = "initializing"
$FailureStage = "initialize"
$FailureType = $null
$FailureHResult = $null
$ClientExitCode = $null
$ClientFinished = $false
$PackageCommit = "unknown"
$ClientHashMatches = $false
$InstalledServiceHashMatches = $false
$ServiceInstalled = $false
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
    $ServiceRecord = Get-CimInstance -ClassName Win32_Service -Filter "Name='StorPulseCollector'"
    $ServiceInstalled = $null -ne $ServiceRecord
    if (-not $ServiceInstalled -or
        -not (Test-Path -LiteralPath $InstalledServicePath -PathType Leaf)) {
        throw "service_not_installed"
    }
    $ServiceManual = $ServiceRecord.StartMode -eq "Manual"
    $ServiceLocalSystem = $ServiceRecord.StartName -eq "LocalSystem"
    $ExpectedServicePath = ('"{0}"' -f $InstalledServicePath)
    $ServicePathMatches = [string]::Equals(
        ([string]$ServiceRecord.PathName).Trim(),
        $ExpectedServicePath,
        [StringComparison]::OrdinalIgnoreCase
    )
    $InstalledServiceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstalledServicePath).Hash.ToLowerInvariant()
    $InstalledServiceHashMatches = $InstalledServiceHash -eq ([string]$Manifest.serviceSha256).ToLowerInvariant()
    if (-not $ServiceManual -or -not $ServiceLocalSystem -or
        -not $ServicePathMatches -or -not $InstalledServiceHashMatches) {
        throw "installed_service_contract_mismatch"
    }

    $FailureStage = "run_client"
    $ClientRun = Invoke-StorPulseClient `
        -ClientPath $ClientPath `
        -OutputDirectory $RunDirectory `
        -RunId $RunId `
        -DurationSeconds $DurationSeconds `
        -StandardOutputPath $StandardOutputPath `
        -StandardErrorPath $StandardErrorPath `
        -DisconnectAfterReady:$DisconnectAfterReady
    $ClientFinished = [bool]$ClientRun.finished
    $ClientExitCode = $ClientRun.exitCode
    if (-not $ClientFinished) {
        throw "client_timeout"
    }

    $FailureStage = "read_summary"
    $SummaryPath = Join-Path $RunDirectory "summary.json"
    if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) {
        throw "summary_missing"
    }
    $Summary = [System.IO.File]::ReadAllText($SummaryPath, [System.Text.Encoding]::UTF8) |
        ConvertFrom-Json
    if ($Summary.runId -ne $RunId -or $Summary.serviceName -ne "StorPulseCollector") {
        throw "summary_contract_mismatch"
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
        status = "failed"
        outcome = "windows_client_not_completed"
        serviceName = "StorPulseCollector"
        failure = [ordered]@{
            phase = if ($null -ne $FailureStage) { $FailureStage } else { "collector" }
            safeErrorCode = "collector_failure"
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
        safeErrorCode = "collector_failure"
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
    serviceManual = $ServiceManual
    serviceLocalSystem = $ServiceLocalSystem
    servicePathMatches = $ServicePathMatches
    installedServiceHashMatches = $InstalledServiceHashMatches
    clientFinished = $ClientFinished
    clientExitCode = $ClientExitCode
}
$DiagnosticManifest = [ordered]@{
    schemaVersion = 1
    product = "StorPulse Windows 持续采集实机诊断"
    runId = $RunId
    stageName = $StageName
    collectorStatus = $CollectorStatus
    packageCommit = $PackageCommit
    files = @("manifest.json", "capabilities.json", "summary.json", "errors.json", "privacy-check.json", "console.log")
    privacy = "只含平台能力、稳定错误码和聚合证据；不含原始 ETL、路径、命令行、用户名、SID 或 nonce"
}

Write-Utf8Json -Path (Join-Path $RunDirectory "manifest.json") -Value $DiagnosticManifest
Write-Utf8Json -Path (Join-Path $RunDirectory "capabilities.json") -Value $Capabilities
Write-Utf8Json -Path (Join-Path $RunDirectory "errors.json") -Value ([ordered]@{ schemaVersion = 1; errors = $Errors })
$Encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines((Join-Path $RunDirectory "console.log"), $ConsoleLines, $Encoding)

$Privacy = Test-DiagnosticDirectoryPrivacy -Directory $RunDirectory -CurrentUserName ([Environment]::UserName)
$AllowedFiles = @("manifest.json", "capabilities.json", "summary.json", "errors.json", "privacy-check.json", "console.log")
$UnexpectedFiles = @(Get-ChildItem -LiteralPath $RunDirectory -File |
    Where-Object { $AllowedFiles -notcontains $_.Name })
$UnexpectedDirectories = @(Get-ChildItem -LiteralPath $RunDirectory -Directory)
$AllowListPassed = $UnexpectedFiles.Count -eq 0 -and $UnexpectedDirectories.Count -eq 0
$PrivacyViolations = @($Privacy.violations)
if (-not $AllowListPassed) {
    $PrivacyViolations += "unexpected_diagnostic_content"
}
$PrivacyCheck = [ordered]@{
    schemaVersion = 1
    rulesVersion = 1
    preArchivePassed = [bool]$Privacy.passed -and $AllowListPassed
    postArchivePassed = [bool]$Privacy.passed -and $AllowListPassed
    checkedFileCount = [int]$Privacy.checkedFileCount + 1
    violations = $PrivacyViolations
}
Write-Utf8Json -Path (Join-Path $RunDirectory "privacy-check.json") -Value $PrivacyCheck
$FinalPrivacy = Test-DiagnosticDirectoryPrivacy -Directory $RunDirectory -CurrentUserName ([Environment]::UserName)
$ArchiveCreated = $false
if ($Privacy.passed -and $FinalPrivacy.passed -and $AllowListPassed) {
    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -Force -LiteralPath $ArchivePath
    }
    Compress-Archive -Path (Join-Path $RunDirectory "*") -DestinationPath $ArchivePath -CompressionLevel Optimal
    $ArchivePrivacy = Test-DiagnosticArchivePrivacy -ArchivePath $ArchivePath -CurrentUserName ([Environment]::UserName)
    if ($ArchivePrivacy.passed) {
        $ArchiveCreated = $true
    }
    else {
        Remove-Item -Force -LiteralPath $ArchivePath
    }
}

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

if (-not $ArchiveCreated -or $CollectorStatus -ne "completed") {
    exit 1
}
