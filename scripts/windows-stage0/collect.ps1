param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Standard", "Administrator")]
    [string]$ExpectedMode,

    [ValidateRange(5, 300)]
    [int]$DurationSeconds = 15,

    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "invoke-probe.ps1")

$PackageRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ProbePath = Join-Path $PackageRoot "storpulse-windows-probe.exe"
$ManifestPath = Join-Path $PackageRoot "package-manifest.json"
$DiagnosticsRoot = Join-Path $PackageRoot "diagnostics"
$RunId = "{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"), [Guid]::NewGuid().ToString("N").Substring(0, 8)
$RunDirectory = Join-Path $DiagnosticsRoot $RunId
$ArchivePath = Join-Path $DiagnosticsRoot ("storpulse-diagnostics-{0}.zip" -f $RunId)

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

function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PerformanceLogUser {
    try {
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
        $Sid = New-Object Security.Principal.SecurityIdentifier("S-1-5-32-559")
        return $Principal.IsInRole($Sid)
    }
    catch {
        return $null
    }
}

function Get-OsSnapshot {
    $CurrentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $Build = [int]$CurrentVersion.CurrentBuildNumber
    $ProductName = [string]$CurrentVersion.ProductName
    $DisplayVersionProperty = $CurrentVersion.PSObject.Properties["DisplayVersion"]
    $UbrProperty = $CurrentVersion.PSObject.Properties["UBR"]
    $EvidenceClass = if ($ProductName -match "Server") {
        "server_exploratory"
    }
    elseif ($Build -ge 22000) {
        "windows_11_preliminary"
    }
    elseif ($Build -ge 19045) {
        "windows_10_22h2_candidate"
    }
    else {
        "older_windows_exploratory"
    }

    return [ordered]@{
        productName = $ProductName
        displayVersion = if ($null -ne $DisplayVersionProperty) { [string]$DisplayVersionProperty.Value } else { "unknown" }
        buildNumber = $Build
        updateBuildRevision = if ($null -ne $UbrProperty) { [int]$UbrProperty.Value } else { $null }
        architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
        evidenceClass = $EvidenceClass
    }
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
    $ModeMatches = ($ExpectedMode -eq "Administrator" -and $ActualAdministrator) -or
        ($ExpectedMode -eq "Standard" -and -not $ActualAdministrator)
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
        -StandardErrorPath $StandardErrorPath
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
        $CollectorStatus = if ($ProbeExitCode -eq 0) { "completed" } else { "probe_failed" }
        $FailureStage = if ($ProbeExitCode -eq 0) { $null } else { "probe_exit" }
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
        expectedMode = $ExpectedMode
        actualAdministrator = $ActualAdministrator
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
Write-Host "状态：$CollectorStatus"
if (-not $NoPause) {
    Read-Host "按回车键退出" | Out-Null
}

if ($CollectorStatus -ne "completed") {
    exit 1
}
