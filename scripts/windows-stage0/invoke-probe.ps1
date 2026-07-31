function Invoke-StorPulseProbe {
    param(
        [Parameter(Mandatory = $true)] [string]$ProbePath,
        [Parameter(Mandatory = $true)] [string]$OutputDirectory,
        [Parameter(Mandatory = $true)] [int]$DurationSeconds,
        [Parameter(Mandatory = $true)] [string]$StandardOutputPath,
        [Parameter(Mandatory = $true)] [string]$StandardErrorPath
    )

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $ProbePath
    $StartInfo.Arguments = '--output "{0}" --duration-seconds {1}' -f $OutputDirectory, $DurationSeconds
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
            throw "probe_process_start_failed"
        }
        $StandardOutputTask = $Process.StandardOutput.ReadToEndAsync()
        $StandardErrorTask = $Process.StandardError.ReadToEndAsync()
        $Finished = $Process.WaitForExit(($DurationSeconds + 30) * 1000)
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
