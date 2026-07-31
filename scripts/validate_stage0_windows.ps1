param(
    [string]$Target = "x86_64-pc-windows-msvc"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-ProbeDiagnostics {
    param([Parameter(Mandatory = $true)] [string]$Directory)

    foreach ($FileName in @("summary.json", "errors.json", "timeline.ndjson")) {
        $Path = Join-Path $Directory $FileName
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Write-Host "===== $FileName ====="
            Write-Host ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
        }
    }
}

$Root = Split-Path -Parent $PSScriptRoot
$TemporaryRoot = Join-Path $Root ".codex-tmp/windows-stage0-ci"
$ReportDirectory = Join-Path $TemporaryRoot "probe-report"
$env:CARGO_HOME = Join-Path $Root ".codex-tmp/cargo-home"
$env:CARGO_TARGET_DIR = Join-Path $Root ".codex-tmp/cargo-target"

Push-Location $Root
try {
    cargo fmt --all -- --check
    cargo check --locked --workspace --all-targets --target $Target
    cargo test --locked --workspace --target $Target
    cargo clippy --locked --workspace --all-targets --target $Target -- -D warnings
    cargo build --locked --package storpulse-windows-probe --target $Target

    if (Test-Path $ReportDirectory) {
        Remove-Item -Recurse -Force -LiteralPath $ReportDirectory
    }
    $ProbePath = Join-Path $env:CARGO_TARGET_DIR "$Target/debug/storpulse-windows-probe.exe"
    & $ProbePath --output $ReportDirectory --duration-seconds 8
    if ($LASTEXITCODE -ne 0) {
        Write-ProbeDiagnostics -Directory $ReportDirectory
        throw "Windows 阶段 0 探针冒烟失败，退出码：$LASTEXITCODE"
    }

    foreach ($RequiredFile in @("summary.json", "errors.json", "workload.json", "timeline.ndjson")) {
        if (-not (Test-Path (Join-Path $ReportDirectory $RequiredFile))) {
            throw "Windows 阶段 0 报告缺少文件：$RequiredFile"
        }
    }
    $SummaryPath = Join-Path $ReportDirectory "summary.json"
    $SummaryText = [System.IO.File]::ReadAllText($SummaryPath, [System.Text.Encoding]::UTF8)
    $Summary = $SummaryText | ConvertFrom-Json
    if ($Summary.schemaVersion -ne 1) {
        throw "Windows 阶段 0 报告 schemaVersion 不匹配"
    }
    if ($Summary.environment.architecture -ne "x86_64") {
        throw "Windows 阶段 0 探针不是 x64 构建"
    }
    if (-not $Summary.etw.sessionStarted -or -not $Summary.etw.consumerStarted) {
        Write-ProbeDiagnostics -Directory $ReportDirectory
        throw "Windows 阶段 0 ETW 会话没有成功启动：startStatus=$($Summary.etw.startStatus) openStatus=$($Summary.etw.openStatus)"
    }
    if ($SummaryText -match 'userName|commandLine|filePath|fileContent|processName') {
        throw "Windows 阶段 0 报告出现禁止持久化的字段"
    }
    Write-Host "Windows 阶段 0 编译、测试和结构化日志冒烟通过。"
}
finally {
    Pop-Location
}
