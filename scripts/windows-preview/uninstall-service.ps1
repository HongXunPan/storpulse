Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ServiceName = "StorPulseCollector"
$EtwSessionName = "StorPulse.Collector.Etw.v1"
$InstallDirectory = Join-Path ${env:ProgramFiles} "StorPulse\Collector"
$CommonApplicationData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData
)
$ProductDataDirectory = $null
$DiagnosticsDirectory = $null

function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$ExitCode = 0
try {
    if (-not (Test-Administrator)) {
        throw "服务卸载必须在 UAC 提升后的管理员进程中执行"
    }
    if ([string]::IsNullOrWhiteSpace($CommonApplicationData)) {
        throw "无法解析 Windows 公共应用数据目录"
    }
    $ProductDataDirectory = Join-Path $CommonApplicationData "StorPulse"
    $DiagnosticsDirectory = Join-Path $ProductDataDirectory "Diagnostics"

    $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $Service) {
        if ($Service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            & sc.exe stop $ServiceName | Out-Null
            $Deadline = [DateTime]::UtcNow.AddSeconds(30)
            do {
                Start-Sleep -Milliseconds 250
                $Service.Refresh()
            } while ($Service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped -and
                [DateTime]::UtcNow -lt $Deadline)
            if ($Service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                throw "服务未在 30 秒内停止，保留安装目录以便诊断"
            }
        }
        $Service.Dispose()
        & sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "删除服务失败，退出码：$LASTEXITCODE"
        }
    }

    # 只清理 StorPulse 自己的固定产品会话；不存在时忽略。
    & logman.exe stop $EtwSessionName -ets 2>$null | Out-Null
    if (Test-Path -LiteralPath $InstallDirectory) {
        Remove-Item -Recurse -Force -LiteralPath $InstallDirectory
    }
    if (Test-Path -LiteralPath $DiagnosticsDirectory) {
        Remove-Item -Recurse -Force -LiteralPath $DiagnosticsDirectory
    }
    if (Test-Path -LiteralPath $ProductDataDirectory -PathType Container) {
        $RemainingProductData = @(Get-ChildItem -LiteralPath $ProductDataDirectory -Force)
        if ($RemainingProductData.Count -eq 0) {
            Remove-Item -Force -LiteralPath $ProductDataDirectory
        }
    }
    Write-Host "StorPulse 按需采集服务、安装目录和诊断记录已清理。" -ForegroundColor Green
}
catch {
    $ExitCode = 1
    Write-Host ("卸载失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
}

Read-Host "请记录上面的结果，然后按回车键关闭提升窗口" | Out-Null
exit $ExitCode
