Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ServiceName = "StorPulseStage0Collector"
$EtwSessionName = "StorPulse.Stage0.Service"
$InstallDirectory = Join-Path ${env:ProgramFiles} "StorPulse\Stage0ServiceProbe"

function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    throw "服务卸载必须在 UAC 提升后的管理员进程中执行"
}

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

# 只清理 StorPulse 自己的固定阶段 0 会话；不存在时忽略。
& logman.exe stop $EtwSessionName -ets 2>$null | Out-Null

if (Test-Path -LiteralPath $InstallDirectory) {
    Remove-Item -Recurse -Force -LiteralPath $InstallDirectory
}

Write-Host "StorPulse 阶段 0 按需服务和受保护目录已清理。"
