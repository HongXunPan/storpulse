param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Standard", "Administrator")]
    [string]$ExpectedMode,

    [ValidateRange(5, 300)]
    [int]$DurationSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

New-Item -ItemType Directory -Force -Path $RunDirectory | Out-Null
$ActualAdministrator = Test-Administrator
$PerformanceLogUser = Test-PerformanceLogUser
$OsSnapshot = Get-OsSnapshot
$Manifest = if (Test-Path $ManifestPath) {
    Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
}
else {
    $null
}

$ExpectedHash = if ($null -ne $Manifest) { [string]$Manifest.probeSha256 } else { "" }
$ActualHash = if (Test-Path $ProbePath) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $ProbePath).Hash.ToLowerInvariant()
}
else {
    ""
}
$HashMatches = $ExpectedHash -ne "" -and $ActualHash -eq $ExpectedHash.ToLowerInvariant()
$ModeMatches = ($ExpectedMode -eq "Administrator" -and $ActualAdministrator) -or
    ($ExpectedMode -eq "Standard" -and -not $ActualAdministrator)

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
    packageCommit = if ($null -ne $Manifest) { [string]$Manifest.commitSha } else { "unknown" }
}
Write-Utf8Json -Path (Join-Path $RunDirectory "environment.json") -Value $Environment

$ProbeExitCode = $null
$CollectorStatus = "not_started"
$StandardOutputPath = Join-Path $RunDirectory ".probe-stdout.txt"
$StandardErrorPath = Join-Path $RunDirectory ".probe-stderr.txt"

try {
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

    $Arguments = @(
        "--output", ('"{0}"' -f $RunDirectory),
        "--duration-seconds", $DurationSeconds.ToString()
    )
    $Process = Start-Process -FilePath $ProbePath `
        -ArgumentList $Arguments `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $StandardOutputPath `
        -RedirectStandardError $StandardErrorPath
    $Finished = $Process.WaitForExit(($DurationSeconds + 30) * 1000)
    if (-not $Finished) {
        Stop-Process -Id $Process.Id -Force
        $Process.WaitForExit()
        $CollectorStatus = "probe_timeout"
    }
    else {
        $Process.WaitForExit()
        $ProbeExitCode = $Process.ExitCode
        $CollectorStatus = if ($ProbeExitCode -eq 0) { "completed" } else { "probe_failed" }
    }
}
catch {
    if ($CollectorStatus -eq "not_started") {
        $CollectorStatus = "collector_failed"
    }
}
finally {
    $ConsoleLines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $StandardOutputPath) {
        foreach ($Line in Get-Content -LiteralPath $StandardOutputPath) {
            $ConsoleLines.Add([string]$Line)
        }
        Remove-Item -Force -LiteralPath $StandardOutputPath
    }
    if (Test-Path $StandardErrorPath) {
        foreach ($Line in Get-Content -LiteralPath $StandardErrorPath) {
            $ConsoleLines.Add([string]$Line)
        }
        Remove-Item -Force -LiteralPath $StandardErrorPath
    }
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines(
        (Join-Path $RunDirectory "console.log"),
        $ConsoleLines,
        $Encoding
    )

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
    }
    Write-Utf8Json -Path (Join-Path $RunDirectory "collector-result.json") -Value $CollectorResult

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
Read-Host "按回车键退出" | Out-Null

if ($CollectorStatus -ne "completed") {
    exit 1
}
