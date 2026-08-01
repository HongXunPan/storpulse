#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.codex-tmp/validation"
ORIGINAL_HOME="${HOME}"

mkdir -p "${TMP_DIR}/home" "${TMP_DIR}/module-cache" "${TMP_DIR}/swift"

python3 - "${ROOT_DIR}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
missing_bom = []
for script in sorted((root / "scripts").rglob("*.ps1")):
    if not script.read_bytes().startswith(b"\xef\xbb\xbf"):
        missing_bom.append(str(script.relative_to(root)))
if missing_bom:
    raise SystemExit(
        "以下 PowerShell 脚本缺少 Windows PowerShell 5.1 所需的 UTF-8 BOM：\n"
        + "\n".join(missing_bom)
    )
print("PowerShell UTF-8 BOM 校验通过")
PY

python3 - "${ROOT_DIR}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
entry_stages = {
    "collect-standard.cmd": "standard-collection",
    "collect-performance-log-user.cmd": "performance-log-user-collection",
    "collect-service.cmd": "service-collection",
    "collect-service-disconnect.cmd": "service-disconnect-validation",
}
for filename, stage in entry_stages.items():
    text = (root / "scripts" / "windows-stage0" / filename).read_text(encoding="utf-8-sig")
    if f"-StageName {stage}" not in text:
        raise SystemExit(f"Windows 采集入口缺少稳定阶段名：{filename} -> {stage}")

admin_text = (root / "scripts" / "windows-stage0" / "launch-admin.ps1").read_text(
    encoding="utf-8-sig"
)
if '"-StageName"' not in admin_text or '"administrator-collection"' not in admin_text:
    raise SystemExit("Windows 管理员采集入口缺少稳定阶段名")

validator_text = (root / "scripts" / "validate_stage0_windows_package.ps1").read_text(
    encoding="utf-8-sig"
)
if '-StageName "package-validation"' not in validator_text:
    raise SystemExit("Windows 成品包验证入口缺少稳定阶段名")

collector_text = (root / "scripts" / "windows-stage0" / "collect.ps1").read_text(
    encoding="utf-8-sig"
)
if 'storpulse-diagnostics-{0}-{1}.zip' not in collector_text:
    raise SystemExit("Windows 诊断 ZIP 文件名没有包含脚本阶段")

preview_entries = {
    "validate-continuous.cmd": "windows-stage1-continuous-validation",
    "collect-disconnect.cmd": "windows-stage1-disconnect-cleanup",
    "collect-connect-timeout.cmd": "windows-stage1-connect-timeout-cleanup",
    "collect-client-termination.cmd": "windows-stage1-client-termination-cleanup",
}
for filename, stage in preview_entries.items():
    text = (root / "scripts" / "windows-preview" / filename).read_text(encoding="utf-8-sig")
    if f"-StageName {stage}" not in text or "pause" not in text.splitlines():
        raise SystemExit(f"Windows 持续采集入口不完整：{filename} -> {stage}")

preview_collector = (root / "scripts" / "windows-preview" / "collect.ps1").read_text(
    encoding="utf-8-sig"
)
preview_environment = (
    root / "scripts" / "windows-preview" / "collect-environment.ps1"
).read_text(encoding="utf-8-sig")
preview_export = (
    root / "scripts" / "windows-preview" / "diagnostic-export.ps1"
).read_text(encoding="utf-8-sig")
preview_lifecycle = (
    root / "scripts" / "windows-preview" / "lifecycle-gates.ps1"
).read_text(encoding="utf-8-sig")
preview_invoke_client = (
    root / "scripts" / "windows-preview" / "invoke-client.ps1"
).read_text(encoding="utf-8-sig")
preview_privacy = (
    root / "scripts" / "windows-preview" / "privacy.ps1"
).read_text(encoding="utf-8-sig")
preview_package_validator = (
    root / "scripts" / "validate_windows_preview_package.ps1"
).read_text(encoding="utf-8-sig")
if (
    'storpulse-diagnostics-{0}-{1}.zip' not in preview_collector
    or "Test-DiagnosticArchivePrivacy" not in preview_export
    or "standard_user_required" not in preview_collector
    or "unexpected_diagnostic_content" not in preview_export
    or "[AllowEmptyString()]" not in preview_privacy
    or "empty_diagnostic_export_validation_failed" not in preview_package_validator
):
    raise SystemExit("Windows 持续采集入口缺少阶段命名、标准用户或归档白名单门禁")

preview_installer = (
    root / "scripts" / "windows-preview" / "install-service.ps1"
).read_text(encoding="utf-8-sig")
if (
    "New-Service @ServiceParameters" not in preview_installer
    or '"create", $ServiceName' in preview_installer
    or '$ServiceSddl = "D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCRPLCLORC;;;IU)"'
    not in preview_installer
):
    raise SystemExit("Windows 持续采集安装脚本没有使用 PowerShell 原生服务入口")

if (
    "service_config_query_unavailable" not in preview_collector
    or "serviceConfigReadable = $ServiceConfigReadable" not in preview_collector
    or "function Get-InstalledServiceState" not in preview_environment
    or "function Complete-ClientTerminationGate" not in preview_lifecycle
    or "$ExpectedTerminationExitCode = 197" not in preview_lifecycle
    or "snapshotCount -ge 3" not in preview_lifecycle
    or '$Summary.status -ne "completed"' not in preview_collector
    or "--connect-timeout-validation" not in preview_invoke_client
    or "--terminate-after-collection-started" not in preview_invoke_client
):
    raise SystemExit("Windows 持续采集诊断缺少服务配置可读性结果")

preview_packager = (root / "scripts" / "package_windows_preview.ps1").read_text(
    encoding="utf-8-sig"
)
if "https://github.com/HongXunPan/storpulse/issues/new" not in preview_packager:
    raise SystemExit("Windows 持续采集包缺少显式反馈渠道")
print("Windows 诊断 ZIP 阶段命名校验通过")
PY

if [[ -f "${ROOT_DIR}/Cargo.toml" ]]; then
  RUST_BIN="${STORPULSE_RUST_BIN:-}"
  if [[ -z "${RUST_BIN}" ]]; then
    RUST_BIN="$(dirname "$(rustup which --toolchain stable cargo)")"
  fi
  export PATH="${RUST_BIN}:${PATH}"
  export CARGO_HOME="${ROOT_DIR}/.codex-tmp/cargo-home"
  export CARGO_TARGET_DIR="${ROOT_DIR}/.codex-tmp/cargo-target"
  (
    cd "${ROOT_DIR}"
    cargo fmt --all -- --check
    cargo check --locked --workspace --all-targets
    cargo test --locked --workspace
    cargo clippy --locked --workspace --all-targets -- -D warnings
  )
else
  echo "Rust 工作区尚未建立，跳过 Rust 校验。"
fi

env \
  HOME="${TMP_DIR}/home" \
  CLANG_MODULE_CACHE_PATH="${TMP_DIR}/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="${TMP_DIR}/module-cache" \
  swift test \
    --disable-sandbox \
    --package-path "${ROOT_DIR}/platform/macos" \
    --scratch-path "${TMP_DIR}/swift"

BUDGET_SCRIPT="${CODEX_HOME:-${ORIGINAL_HOME}/.codex}/skills/file-governance/scripts/check_file_budget.py"
if [[ -f "${BUDGET_SCRIPT}" ]]; then
  BUDGET_TARGETS=(
    "${ROOT_DIR}/AGENTS.md"
    "${ROOT_DIR}/README.md"
    "${ROOT_DIR}/CONTRIBUTING.md"
    "${ROOT_DIR}/docs"
    "${ROOT_DIR}/scripts"
    "${ROOT_DIR}/platform/macos/Package.swift"
    "${ROOT_DIR}/platform/macos/Sources"
    "${ROOT_DIR}/platform/macos/Tests"
  )
  if [[ -d "${ROOT_DIR}/platform/windows" ]]; then
    BUDGET_TARGETS+=("${ROOT_DIR}/platform/windows")
  fi
  if [[ -d "${ROOT_DIR}/crates" ]]; then
    BUDGET_TARGETS+=("${ROOT_DIR}/crates")
  fi
  for target in "${BUDGET_TARGETS[@]}"; do
    python3 "${BUDGET_SCRIPT}" "${target}" --brief
  done
else
  echo "未找到 Codex 文件预算脚本，跳过本机专项预算检查。"
fi

python3 - "${ROOT_DIR}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
missing = []
for document in root.rglob("*.md"):
    if any(part.startswith(".") for part in document.relative_to(root).parts):
        continue
    text = document.read_text(encoding="utf-8")
    for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
        if "://" in target or target.startswith("#"):
            continue
        path = target.split("#", 1)[0]
        if path and not (document.parent / path).exists():
            missing.append(f"{document.relative_to(root)} -> {target}")
if missing:
    raise SystemExit("Markdown 链接失效：\n" + "\n".join(missing))
print("Markdown 链接校验通过")
PY

(
  cd "${ROOT_DIR}"
  git diff --check
)

echo "StorPulse 最小校验通过。"
