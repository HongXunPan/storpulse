function Complete-ClientTerminationGate {
    param(
        [Parameter(Mandatory = $true)] [string]$ClientPath,
        [Parameter(Mandatory = $true)] [string]$RunDirectory,
        [Parameter(Mandatory = $true)] [string]$RunId,
        [Parameter(Mandatory = $true)] $ClientRun
    )

    $ExpectedTerminationExitCode = 197
    $InitialSummaryAbsent = -not (Test-Path -LiteralPath (Join-Path $RunDirectory "summary.json"))
    $ServiceStop = Wait-StorPulseServiceStopped `
        -ServiceName "StorPulseCollector" `
        -TimeoutSeconds 45
    $RecoveryDirectory = Join-Path $RunDirectory ".recovery"
    $RecoverySummary = $null
    $RecoveryClientExitCode = $null
    $RecoveryFinished = $false
    try {
        if ($ServiceStop.stopped) {
            New-Item -ItemType Directory -Force -Path $RecoveryDirectory | Out-Null
            $RecoveryRun = Invoke-StorPulseClient `
                -ClientPath $ClientPath `
                -OutputDirectory $RecoveryDirectory `
                -RunId ("{0}-recovery" -f $RunId) `
                -DurationSeconds 5 `
                -StandardOutputPath (Join-Path $RecoveryDirectory ".stdout.txt") `
                -StandardErrorPath (Join-Path $RecoveryDirectory ".stderr.txt") `
                -GateMode "continuous_validation"
            $RecoveryFinished = [bool]$RecoveryRun.finished
            $RecoveryClientExitCode = $RecoveryRun.exitCode
            $RecoverySummaryPath = Join-Path $RecoveryDirectory "summary.json"
            if (Test-Path -LiteralPath $RecoverySummaryPath -PathType Leaf) {
                $RecoverySummary = [System.IO.File]::ReadAllText(
                    $RecoverySummaryPath,
                    [System.Text.Encoding]::UTF8
                ) | ConvertFrom-Json
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $RecoveryDirectory) {
            Remove-Item -Recurse -Force -LiteralPath $RecoveryDirectory
        }
    }

    $ClientTerminated = [bool]$ClientRun.finished -and
        $null -ne $ClientRun.exitCode -and
        [int]$ClientRun.exitCode -eq $ExpectedTerminationExitCode
    $RecoveryPassed = $RecoveryFinished -and
        $RecoveryClientExitCode -eq 0 -and
        $null -ne $RecoverySummary -and
        $RecoverySummary.status -eq "completed" -and
        $RecoverySummary.protocolCompleted -eq $true -and
        $RecoverySummary.serviceStopped -eq $true -and
        [int]$RecoverySummary.snapshots.snapshotCount -ge 3 -and
        [int]$RecoverySummary.snapshots.eventsLost -eq 0 -and
        [int]$RecoverySummary.snapshots.buffersLost -eq 0
    $Confirmed = $ClientTerminated -and
        $InitialSummaryAbsent -and
        [bool]$ServiceStop.stopped -and
        $RecoveryPassed

    return [ordered]@{
        schemaVersion = 1
        runId = $RunId
        mode = "client_termination_cleanup"
        status = if ($Confirmed) { "completed" } else { "failed" }
        outcome = if ($Confirmed) {
            "windows_client_termination_cleanup_completed"
        } else {
            "windows_client_termination_cleanup_failed"
        }
        serviceName = "StorPulseCollector"
        clientProcessId = $ClientRun.processId
        clientExitCode = $ClientRun.exitCode
        expectedClientExitCode = $ExpectedTerminationExitCode
        clientElevated = $false
        serviceProcessId = $null
        serviceWin32ExitCode = $ServiceStop.win32ExitCode
        serviceSpecificExitCode = $ServiceStop.serviceSpecificExitCode
        protocolCompleted = $false
        serviceStopped = [bool]$ServiceStop.stopped
        disconnectCleanupConfirmed = $false
        connectTimeoutConfirmed = $false
        clientTerminationCleanupConfirmed = $Confirmed
        snapshots = New-EmptySnapshotEvidence
        workload = New-EmptyWorkloadEvidence
        recovery = [ordered]@{
            clientFinished = $RecoveryFinished
            clientExitCode = $RecoveryClientExitCode
            status = if ($null -ne $RecoverySummary) { $RecoverySummary.status } else { $null }
            outcome = if ($null -ne $RecoverySummary) { $RecoverySummary.outcome } else { $null }
            protocolCompleted = if ($null -ne $RecoverySummary) {
                $RecoverySummary.protocolCompleted
            } else {
                $false
            }
            serviceStopped = if ($null -ne $RecoverySummary) {
                $RecoverySummary.serviceStopped
            } else {
                $false
            }
            snapshotCount = if ($null -ne $RecoverySummary) {
                $RecoverySummary.snapshots.snapshotCount
            } else {
                0
            }
            eventsLost = if ($null -ne $RecoverySummary) {
                $RecoverySummary.snapshots.eventsLost
            } else {
                0
            }
            buffersLost = if ($null -ne $RecoverySummary) {
                $RecoverySummary.snapshots.buffersLost
            } else {
                0
            }
        }
        failure = if ($Confirmed) {
            $null
        } else {
            [ordered]@{
                phase = "client_termination_cleanup"
                safeErrorCode = "client_termination_cleanup_failed"
                nativeCode = $null
            }
        }
        limitations = @(
            "Windows 10 结果不能替代 Windows 11、签名、安装器或长期运行门禁",
            "客户端强杀只验证当前单用户会话，不替代休眠恢复和多用户验证",
            "恢复采集只保存聚合证据，不保存路径、命令行、用户名、SID 或 nonce"
        )
    }
}
