function Invoke-StorPulseClient {
    param(
        [Parameter(Mandatory = $true)] [string]$ClientPath,
        [Parameter(Mandatory = $true)] [string]$OutputDirectory,
        [Parameter(Mandatory = $true)] [string]$RunId,
        [Parameter(Mandatory = $true)] [int]$DurationSeconds,
        [Parameter(Mandatory = $true)] [string]$StandardOutputPath,
        [Parameter(Mandatory = $true)] [string]$StandardErrorPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet("continuous_validation", "disconnect_cleanup", "connect_timeout_cleanup", "client_termination_cleanup")]
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
    try {
        if (-not $Process.Start()) {
            throw "client_process_start_failed"
        }
        $ProcessId = [int]$Process.Id
        $StandardOutputTask = $Process.StandardOutput.ReadToEndAsync()
        $StandardErrorTask = $Process.StandardError.ReadToEndAsync()
        $Finished = $Process.WaitForExit(($DurationSeconds + 120) * 1000)
        if (-not $Finished) {
            $Process.Kill()
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
        $Process.Dispose()
    }

    return [pscustomobject]@{
        finished = $Finished
        exitCode = $ExitCode
        processId = $ProcessId
    }
}
