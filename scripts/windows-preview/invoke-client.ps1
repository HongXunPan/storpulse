function Invoke-StorPulseClient {
    param(
        [Parameter(Mandatory = $true)] [string]$ClientPath,
        [Parameter(Mandatory = $true)] [string]$OutputDirectory,
        [Parameter(Mandatory = $true)] [string]$RunId,
        [Parameter(Mandatory = $true)] [int]$DurationSeconds,
        [Parameter(Mandatory = $true)] [string]$StandardOutputPath,
        [Parameter(Mandatory = $true)] [string]$StandardErrorPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "continuous_validation",
            "disconnect_cleanup",
            "connect_timeout_cleanup",
            "client_termination_cleanup",
            "sleep_resume_validation"
        )]
        [string]$GateMode
    )

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $ClientPath
    $ClientArguments = @(
        '--output', ('"{0}"' -f $OutputDirectory),
        '--run-id', $RunId,
        '--duration-seconds', $DurationSeconds
    )
    switch ($GateMode) {
        "disconnect_cleanup" { $ClientArguments += "--disconnect-after-ready" }
        "connect_timeout_cleanup" { $ClientArguments += "--connect-timeout-validation" }
        "client_termination_cleanup" { $ClientArguments += "--terminate-after-collection-started" }
        "sleep_resume_validation" { $ClientArguments += "--sleep-resume-validation" }
    }
    $StartInfo.Arguments = $ClientArguments -join " "
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $StartInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    $Finished = $false
    $ExitCode = $null
    $ProcessId = $null
    $SleepResumePromptShown = $false
    $ReadyMarkerPath = Join-Path $OutputDirectory ".sleep-resume-ready"
    try {
        if (-not $Process.Start()) {
            throw "client_process_start_failed"
        }
        $ProcessId = [int]$Process.Id
        $StandardOutputTask = $Process.StandardOutput.ReadToEndAsync()
        $StandardErrorTask = $Process.StandardError.ReadToEndAsync()
        if ($GateMode -eq "sleep_resume_validation") {
            $TimedOut = $false
            $ProcessDeadline = [DateTime]::UtcNow.AddSeconds(420)
            while (-not $Process.WaitForExit(500)) {
                $ReadyMarkerExists = Test-Path -LiteralPath $ReadyMarkerPath -PathType Leaf
                if (-not $SleepResumePromptShown -and $ReadyMarkerExists) {
                    Write-Host ""
                    Write-Host "休眠恢复门禁已准备完成。" -ForegroundColor Green
                    Write-Host "请保持当前窗口打开，然后手动选择 Windows 的‘睡眠’。"
                    Write-Host "等待至少 10 秒后唤醒电脑；脚本会自动继续采集并生成诊断 ZIP。"
                    Write-Host "不要选择关机或重启，也不要以管理员身份重新运行。"
                    Write-Host ""
                    $SleepResumePromptShown = $true
                }
                if ([DateTime]::UtcNow -ge $ProcessDeadline) {
                    $TimedOut = $true
                    if (-not $Process.HasExited) {
                        $Process.Kill()
                    }
                    break
                }
            }
            $Finished = -not $TimedOut -and $Process.HasExited
        }
        else {
            $Finished = $Process.WaitForExit(($DurationSeconds + 120) * 1000)
            if (-not $Finished) {
                $Process.Kill()
            }
        }
        $Process.WaitForExit()
        if ($Finished) {
            $ExitCode = [int]$Process.ExitCode
        }

        $Encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($StandardOutputPath, $StandardOutputTask.Result, $Encoding)
        [System.IO.File]::WriteAllText($StandardErrorPath, $StandardErrorTask.Result, $Encoding)
    }
    finally {
        if (Test-Path -LiteralPath $ReadyMarkerPath) {
            Remove-Item -Force -LiteralPath $ReadyMarkerPath
        }
        $Process.Dispose()
    }

    return [pscustomobject]@{
        finished = $Finished
        exitCode = $ExitCode
        processId = $ProcessId
        sleepResumePromptShown = $SleepResumePromptShown
    }
}
