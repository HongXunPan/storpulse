function Get-StorPulseServiceDiagnosticsDirectory {
    $ProgramData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($ProgramData)) {
        throw "service_diagnostics_root_unavailable"
    }
    return (Join-Path $ProgramData "StorPulse\Diagnostics")
}

function Get-ServiceFallbackSnapshot {
    param(
        [string]$Directory = (Get-StorPulseServiceDiagnosticsDirectory)
    )

    $Directory = [System.IO.Path]::GetFullPath($Directory)
    $Files = @()
    if (Test-Path -LiteralPath $Directory) {
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
            throw "service_diagnostics_root_invalid"
        }
        $Files = @(Get-ChildItem -LiteralPath $Directory -File |
            Where-Object {
                $_.Name -match '^service-failure-[0-9]{20}-[0-9]{10}-[0-9]{2}\.ndjson$'
            })
    }
    return [pscustomobject]@{
        directory = $Directory
        names = @($Files | ForEach-Object { [string]$_.Name })
        capturedUtcMilliseconds = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
}

function Complete-ServiceFallbackGate {
    param(
        [Parameter(Mandatory = $true)] $BeforeSnapshot,
        [Parameter(Mandatory = $true)] [string]$RunDirectory
    )

    $Directory = [string]$BeforeSnapshot.directory
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "service_fallback_directory_missing"
    }
    $BeforeNames = @{}
    foreach ($Name in @($BeforeSnapshot.names)) {
        $BeforeNames[[string]$Name] = $true
    }
    $Files = @(Get-ChildItem -LiteralPath $Directory -File |
        Where-Object {
            $_.Name -match '^service-failure-[0-9]{20}-[0-9]{10}-[0-9]{2}\.ndjson$'
        })
    if ($Files.Count -gt 16) {
        throw "service_fallback_rotation_exceeded"
    }
    $TemporaryFiles = @(Get-ChildItem -LiteralPath $Directory -File |
        Where-Object {
            $_.Name -match '^\.service-failure-[0-9]{20}-[0-9]{10}-[0-9]{2}\.ndjson\.writing$'
        })
    if ($TemporaryFiles.Count -ne 0) {
        throw "service_fallback_temporary_file_left"
    }
    $NewFiles = @($Files | Where-Object { -not $BeforeNames.ContainsKey($_.Name) })
    if ($NewFiles.Count -ne 1) {
        throw "service_fallback_new_record_count_mismatch"
    }

    $NewFile = $NewFiles[0]
    if ($NewFile.Length -le 0 -or $NewFile.Length -gt (64 * 1024)) {
        throw "service_fallback_record_size_invalid"
    }
    $Lines = @([System.IO.File]::ReadAllLines($NewFile.FullName, [System.Text.Encoding]::UTF8))
    if ($Lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$Lines[0])) {
        throw "service_fallback_ndjson_invalid"
    }
    $Text = [System.IO.File]::ReadAllText($NewFile.FullName, [System.Text.Encoding]::UTF8)
    $PrivacyViolations = @(Test-DiagnosticText `
        -Text $Text `
        -CurrentUserName ([Environment]::UserName))
    if ($PrivacyViolations.Count -ne 0) {
        throw "service_fallback_privacy_failed"
    }
    $Record = $Text | ConvertFrom-Json -ErrorAction Stop
    $ExpectedProperties = @(
        "schemaVersion",
        "timestampUtc",
        "monotonicMilliseconds",
        "runId",
        "component",
        "phase",
        "event",
        "severity",
        "safeErrorCode",
        "nativeCode",
        "appVersion",
        "serviceVersion",
        "protocolVersion",
        "osProduct",
        "osBuild",
        "architecture",
        "state"
    )
    $ActualProperties = @($Record.PSObject.Properties | ForEach-Object { $_.Name })
    if (@(Compare-Object -ReferenceObject $ExpectedProperties -DifferenceObject $ActualProperties).Count -ne 0) {
        throw "service_fallback_schema_mismatch"
    }

    $NameMatch = [regex]::Match(
        $NewFile.Name,
        '^service-failure-([0-9]{20})-[0-9]{10}-[0-9]{2}\.ndjson$'
    )
    $TimestampUtc = [UInt64]$Record.timestampUtc
    $MonotonicMilliseconds = [UInt64]$Record.monotonicMilliseconds
    $CapturedUtcMilliseconds = [Int64]$BeforeSnapshot.capturedUtcMilliseconds
    $NowUtcMilliseconds = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $SafeIdentifierPattern = '^[A-Za-z0-9._-]{1,128}$'
    $ServiceVersionPattern = '^[A-Za-z0-9._-]{1,64}$'
    if (-not $NameMatch.Success -or
        ([UInt64]$NameMatch.Groups[1].Value) -ne $TimestampUtc -or
        $TimestampUtc -lt ([UInt64][Math]::Max(0, $CapturedUtcMilliseconds - 1000)) -or
        $TimestampUtc -gt ([UInt64]($NowUtcMilliseconds + 5000)) -or
        $MonotonicMilliseconds -lt 25000 -or
        $MonotonicMilliseconds -gt 120000 -or
        ([string]$Record.runId) -notmatch $SafeIdentifierPattern -or
        ([string]$Record.serviceVersion) -notmatch $ServiceVersionPattern -or
        ([int]$Record.schemaVersion) -ne 1 -or
        ([string]$Record.component) -ne "service" -or
        ([string]$Record.phase) -ne "connection" -or
        ([string]$Record.event) -ne "termination_failed" -or
        ([string]$Record.severity) -ne "error" -or
        ([string]$Record.safeErrorCode) -ne "timeout" -or
        ([int]$Record.nativeCode) -ne 1460 -or
        $null -ne $Record.appVersion -or
        ([int]$Record.protocolVersion) -ne 1 -or
        ([string]$Record.osProduct) -notmatch '^(windows10|windows11|unknown)$' -or
        ([string]$Record.architecture) -ne "x64" -or
        ([string]$Record.state) -ne "failed") {
        throw "service_fallback_contract_mismatch"
    }

    $NormalizedRecord = [ordered]@{
        schemaVersion = [int]$Record.schemaVersion
        timestampUtc = $TimestampUtc
        monotonicMilliseconds = $MonotonicMilliseconds
        runId = [string]$Record.runId
        component = [string]$Record.component
        phase = [string]$Record.phase
        event = [string]$Record.event
        severity = [string]$Record.severity
        safeErrorCode = [string]$Record.safeErrorCode
        nativeCode = [int]$Record.nativeCode
        appVersion = $null
        serviceVersion = [string]$Record.serviceVersion
        protocolVersion = [int]$Record.protocolVersion
        osProduct = [string]$Record.osProduct
        osBuild = if ($null -ne $Record.osBuild) { [int]$Record.osBuild } else { $null }
        architecture = [string]$Record.architecture
        state = [string]$Record.state
    }
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        (Join-Path $RunDirectory "events.ndjson"),
        (($NormalizedRecord | ConvertTo-Json -Depth 5 -Compress) + "`n"),
        $Encoding
    )

    return [ordered]@{
        confirmed = $true
        retainedRecordCount = $Files.Count
        recordBytes = [Int64]$NewFile.Length
        schemaVersion = [int]$Record.schemaVersion
        phase = [string]$Record.phase
        event = [string]$Record.event
        safeErrorCode = [string]$Record.safeErrorCode
        nativeCode = [int]$Record.nativeCode
        state = [string]$Record.state
        atomicCommitConfirmed = $true
        privacyPassed = $true
    }
}

function Confirm-ServiceFallbackValidation {
    param(
        [Parameter(Mandatory = $true)] $BeforeSnapshot,
        [Parameter(Mandatory = $true)] [string]$RunDirectory,
        [Parameter(Mandatory = $true)] $Summary
    )

    try {
        $Evidence = Complete-ServiceFallbackGate `
            -BeforeSnapshot $BeforeSnapshot `
            -RunDirectory $RunDirectory
        $Summary | Add-Member `
            -NotePropertyName "serviceFallback" `
            -NotePropertyValue $Evidence `
            -Force
        $Summary.outcome = "windows_service_fallback_validation_completed"
        return $Evidence
    }
    catch {
        $Summary.status = "failed"
        $Summary.outcome = "windows_service_fallback_validation_failed"
        $Summary | Add-Member `
            -NotePropertyName "serviceFallback" `
            -NotePropertyValue ([ordered]@{ confirmed = $false }) `
            -Force
        throw
    }
}
