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

function New-EmptySnapshotEvidence {
    return [ordered]@{
        snapshotCount = 0
        firstSequence = $null
        lastSequence = $null
        finalSequence = $null
        completeSnapshots = 0
        partialSnapshots = 0
        restrictedSnapshots = 0
        maxProcesses = 0
        maxRestrictedProcesses = 0
        maxDevices = 0
        clientProcessObserved = $false
        clientReadBytes = 0
        clientWriteBytes = 0
        deviceReadBytes = 0
        deviceWriteBytes = 0
        unmappedDiskEvents = 0
        eventsLost = 0
        buffersLost = 0
    }
}

function New-EmptyWorkloadEvidence {
    return [ordered]@{
        attempted = $false
        completed = $false
        writeBytes = 0
        readBytes = 0
        readMode = $null
        cleanupSucceeded = $false
    }
}

function Export-StorPulseDiagnostic {
    param(
        [Parameter(Mandatory = $true)] [string]$RunDirectory,
        [Parameter(Mandatory = $true)] [string]$ArchivePath,
        [Parameter(Mandatory = $true)] $Manifest,
        [Parameter(Mandatory = $true)] $Capabilities,
        [Parameter(Mandatory = $true)] $Summary,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Errors,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$ConsoleLines
    )

    Write-Utf8Json -Path (Join-Path $RunDirectory "manifest.json") -Value $Manifest
    Write-Utf8Json -Path (Join-Path $RunDirectory "capabilities.json") -Value $Capabilities
    Write-Utf8Json -Path (Join-Path $RunDirectory "summary.json") -Value $Summary
    Write-Utf8Json `
        -Path (Join-Path $RunDirectory "errors.json") `
        -Value ([ordered]@{ schemaVersion = 1; errors = $Errors })
    $Encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines(
        (Join-Path $RunDirectory "console.log"),
        $ConsoleLines,
        $Encoding
    )

    $AllowedFiles = @(
        "manifest.json",
        "capabilities.json",
        "summary.json",
        "errors.json",
        "privacy-check.json",
        "console.log"
    )
    $Privacy = Test-DiagnosticDirectoryPrivacy `
        -Directory $RunDirectory `
        -CurrentUserName ([Environment]::UserName)
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

    $FinalPrivacy = Test-DiagnosticDirectoryPrivacy `
        -Directory $RunDirectory `
        -CurrentUserName ([Environment]::UserName)
    if (-not $Privacy.passed -or -not $FinalPrivacy.passed -or -not $AllowListPassed) {
        return [pscustomobject]@{ created = $false; path = $ArchivePath }
    }
    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -Force -LiteralPath $ArchivePath
    }
    Compress-Archive `
        -Path (Join-Path $RunDirectory "*") `
        -DestinationPath $ArchivePath `
        -CompressionLevel Optimal
    $ArchivePrivacy = Test-DiagnosticArchivePrivacy `
        -ArchivePath $ArchivePath `
        -CurrentUserName ([Environment]::UserName)
    if (-not $ArchivePrivacy.passed) {
        Remove-Item -Force -LiteralPath $ArchivePath
        return [pscustomobject]@{ created = $false; path = $ArchivePath }
    }
    return [pscustomobject]@{ created = $true; path = $ArchivePath }
}
