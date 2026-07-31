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
