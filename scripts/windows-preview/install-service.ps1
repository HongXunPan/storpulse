param(
    [Parameter(Mandatory = $true)] [string]$PackageRoot,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ServiceName = "StorPulseCollector"
$ServiceDisplayName = "StorPulse 按需磁盘采集服务"
$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
$SourceBinary = Join-Path $PackageRoot "storpulse-windows-service.exe"
$ManifestPath = Join-Path $PackageRoot "package-manifest.json"
$InstallDirectory = Join-Path ${env:ProgramFiles} "StorPulse\Collector"
$InstalledBinary = Join-Path $InstallDirectory "storpulse-windows-service.exe"
$ServiceSddl = "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;RPLCLORC;;;IU)"

function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Sc {
    param([Parameter(Mandatory = $true)] [string[]]$Arguments)

    & sc.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe 执行失败：$($Arguments[0])，退出码 $LASTEXITCODE"
    }
}

$ExitCode = 0
$Created = $false
$InstallDirectoryPrepared = $false
try {
    if (-not (Test-Administrator)) {
        throw "服务安装必须在 UAC 提升后的管理员进程中执行"
    }
    if (-not (Test-Path -LiteralPath $SourceBinary -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Windows 持续采集包缺少服务或清单"
    }
    if ($null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        throw "服务已存在；请先运行卸载入口，不执行覆盖安装"
    }

    $Manifest = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8) |
        ConvertFrom-Json
    if ($Manifest.serviceName -ne $ServiceName -or $Manifest.serviceStartType -ne "demand") {
        throw "服务名称或启动类型与 package-manifest.json 不一致"
    }
    $ExpectedHash = [string]$Manifest.serviceSha256
    $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SourceBinary).Hash.ToLowerInvariant()
    if ($ExpectedHash.ToLowerInvariant() -ne $ActualHash) {
        throw "产品服务哈希与 package-manifest.json 不一致"
    }

    New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
    $InstallDirectoryPrepared = $true
    Copy-Item -LiteralPath $SourceBinary -Destination $InstalledBinary -Force
    $InstalledHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstalledBinary).Hash.ToLowerInvariant()
    if ($InstalledHash -ne $ActualHash) {
        throw "复制到受保护目录后的产品服务哈希不一致"
    }

    $ServiceParameters = @{
        Name = $ServiceName
        BinaryPathName = ('"{0}"' -f $InstalledBinary)
        DisplayName = $ServiceDisplayName
        Description = "StorPulse 用户主动启用的手动磁盘采集服务；不会开机自启。"
        StartupType = "Manual"
    }
    New-Service @ServiceParameters | Out-Null
    $Created = $true

    $ServiceRecord = Get-CimInstance -ClassName Win32_Service `
        -Filter ("Name='{0}'" -f $ServiceName)
    if ($null -eq $ServiceRecord -or $ServiceRecord.StartName -ne "LocalSystem" -or
        $ServiceRecord.StartMode -ne "Manual") {
        throw "新建服务的运行身份或启动类型不符合契约"
    }
    Invoke-Sc -Arguments @("sdset", $ServiceName, $ServiceSddl)

    Write-Host "StorPulse 按需采集服务已安装。" -ForegroundColor Green
    Write-Host "服务启动类型：手动；运行身份：LocalSystem。"
    Write-Host "关闭本窗口后，请按指南用普通权限运行两个采集入口。"
}
catch {
    if ($Created) {
        & sc.exe delete $ServiceName | Out-Null
    }
    if ($InstallDirectoryPrepared -and (Test-Path -LiteralPath $InstallDirectory)) {
        Remove-Item -Recurse -Force -LiteralPath $InstallDirectory
    }
    $ExitCode = 1
    Write-Host ("安装失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
}

if (-not $NoPause) {
    Read-Host "请记录上面的结果，然后按回车键关闭提升窗口" | Out-Null
}
exit $ExitCode
