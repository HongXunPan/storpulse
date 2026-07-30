#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.codex-tmp/stage0-macos"
REPORT_PATH="${TMP_DIR}/evidence.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "阶段 0 macOS 校验只能在 macOS 宿主执行。" >&2
  exit 1
fi

mkdir -p "${TMP_DIR}/home" "${TMP_DIR}/module-cache" "${TMP_DIR}/swift" "${TMP_DIR}/workload"

env \
  HOME="${TMP_DIR}/home" \
  CLANG_MODULE_CACHE_PATH="${TMP_DIR}/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="${TMP_DIR}/module-cache" \
  STORPULSE_STAGE0_REPORT="${REPORT_PATH}" \
  STORPULSE_STAGE0_WORKDIR="${TMP_DIR}/workload" \
  swift test \
    --disable-sandbox \
    --package-path "${ROOT_DIR}/platform/macos" \
    --scratch-path "${TMP_DIR}/swift" \
    --filter controlledWorkloadProducesEvidence

python3 - "${REPORT_PATH}" <<'PY'
import json
from pathlib import Path
import sys

report_path = Path(sys.argv[1])
report = json.loads(report_path.read_text(encoding="utf-8"))
measurements = report["measurements"]
checks = {
    "证据版本": report["schemaVersion"] == 1,
    "标准用户": report["environment"]["standardUser"] is True,
    "进程可读取": measurements["readableProcesses"] > 0,
    "设备可读取": measurements["deviceCount"] > 0,
    "空闲无主动写入": measurements["idleWriteDeltaBytes"] == 0,
    "进程写入方向": measurements["workloadWriteDeltaBytes"] > 0,
    "设备写入方向": measurements["deviceWriteDeltaBytes"] > 0,
    "iostat 对照": measurements["iostatExitCode"] == 0
        and (measurements["iostatIntervalMegabytes"] or 0) > 0,
    "采样耗时": measurements["maximumCollectionMilliseconds"] < 1000,
}
failed = [name for name, passed in checks.items() if not passed]
if failed:
    raise SystemExit("阶段 0 门禁失败：" + "、".join(failed))

print("阶段 0 macOS 证据校验通过")
print(f"证据级别：{report['evidenceLevel']}")
print(
    "进程覆盖："
    f"{measurements['readableProcesses']}/{measurements['discoveredProcesses']}，"
    f"受限 {measurements['restrictedProcesses']}"
)
print(
    "受控负载增量："
    f"进程写入 {measurements['workloadWriteDeltaBytes']} B，"
    f"设备写入 {measurements['deviceWriteDeltaBytes']} B"
)
print(f"证据文件：{report_path}")
PY
