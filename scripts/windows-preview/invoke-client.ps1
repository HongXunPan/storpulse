function Invoke-StorPulseClient {
    param(
        [Parameter(Mandatory = $true)] [string]$ClientPath,
        [Parameter(Mandatory = $true)] [string]$OutputDirectory,
        [Parameter(Mandatory = $true)] [string]$RunId,
        [Parameter(Mandatory = $true)] [int]$DurationSeconds,
        [Parameter(Mandatory = $true)] [string]$StandardOutputPath,
        [Parameter(Mandatory = $true)] [string]$StandardErrorPath,
        [switch]$DisconnectAfterReady
    )

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $ClientPath
    $ClientArguments = @(
        '--output', ('"{0}"' -f $OutputDirectory),
        '--run-id', $RunId,
        '--duration-seconds', $DurationSeconds
    )
    if ($DisconnectAfterReady) {
        $ClientArguments += "--disconnect-after-ready"
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
    try {
        if (-not $Process.Start()) {
            throw "client_process_start_failed"
        }
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
    }
}
