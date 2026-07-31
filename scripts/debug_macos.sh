#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/debug_signing.sh"

DEBUG_DIR="${ROOT_DIR}/.codex-tmp/debug-macos"
CARGO_TARGET_DIR="${DEBUG_DIR}/cargo-target"
SWIFT_SCRATCH_DIR="${DEBUG_DIR}/swift"
MODULE_CACHE_DIR="${DEBUG_DIR}/module-cache"
ENGINE_LIBRARY="${CARGO_TARGET_DIR}/debug/libstorpulse_ffi.dylib"
APP_BUNDLE="${DEBUG_DIR}/StorPulse Debug.app"
APP_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/storpulse-mac"
SIGNING_CONFIG="${ROOT_DIR}/Config.local.xcconfig"
BUNDLE_IDENTIFIER="com.HongXunPan.StorPulse.Debug"

USE_DEBUGGER=0
CLEAN_FIRST=0
PREPARE_ONLY=0
SIGNING_MODE="development"
SIGNING_CONTEXT=""

usage() {
  cat <<'EOF'
用法：bash scripts/debug_macos.sh [选项]

编译 Rust 共享引擎和 SwiftPM Debug 产品，组装签名的 .app 并启动 StorPulse。

选项：
  --lldb    使用 LLDB 启动 .app 内的可执行文件
  --clean   启动前清理本脚本的 Debug 临时目录
  --adhoc   显式改用本机 ad-hoc 签名，不使用开发证书
  --prepare-only
            只组装 .app，不启动应用
  -h, --help
            显示帮助

说明：
  - 仅支持当前已验证的 macOS Intel 开发者预览环境。
  - 默认读取 Config.local.xcconfig，并使用匹配团队的 Apple Development 身份。
  - 不会静默从 Development 签名降级为 ad-hoc。
  - 不执行 archive、发布签名、发布打包、公证或发布。
  - 编译产物和模块缓存只写入源码仓 .codex-tmp/debug-macos/。
  - 历史仍默认关闭；启用后数据库使用应用支持目录。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lldb)
      USE_DEBUGGER=1
      ;;
    --clean)
      CLEAN_FIRST=1
      ;;
    --adhoc)
      SIGNING_MODE="adhoc"
      ;;
    --prepare-only)
      PREPARE_ONLY=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "未知选项：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "StorPulse macOS Debug 只能在 macOS 宿主执行。" >&2
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "当前只验证 macOS Intel；此脚本拒绝在未验证架构上启动。" >&2
  exit 1
fi

if [[ "${SIGNING_MODE}" == "development" ]]; then
  SIGNING_CONTEXT="$(storpulse_resolve_development_signing "${SIGNING_CONFIG}")"
fi

if [[ "${CLEAN_FIRST}" -eq 1 ]]; then
  rm -rf "${DEBUG_DIR}"
fi

mkdir -p "${CARGO_TARGET_DIR}" "${SWIFT_SCRATCH_DIR}" "${MODULE_CACHE_DIR}"

RUST_BIN="${STORPULSE_RUST_BIN:-}"
if [[ -z "${RUST_BIN}" ]]; then
  DIRECT_RUST_BIN="${HOME}/.rustup/toolchains/stable-x86_64-apple-darwin/bin"
  if [[ -x "${DIRECT_RUST_BIN}/cargo" && -x "${DIRECT_RUST_BIN}/rustc" ]]; then
    RUST_BIN="${DIRECT_RUST_BIN}"
  elif command -v rustup >/dev/null 2>&1; then
    RUST_BIN="$(dirname "$(rustup which --toolchain stable cargo)")"
  else
    echo "未找到 Rust stable 工具链；请先安装 rustup 或设置 STORPULSE_RUST_BIN。" >&2
    exit 1
  fi
fi

if [[ ! -x "${RUST_BIN}/cargo" || ! -x "${RUST_BIN}/rustc" ]]; then
  echo "STORPULSE_RUST_BIN 无效：${RUST_BIN}" >&2
  exit 1
fi

export PATH="${RUST_BIN}:${PATH}"
export CARGO_HOME="${ROOT_DIR}/.codex-tmp/cargo-home"
export CARGO_TARGET_DIR

echo "[1/3] 编译 Rust 共享引擎（Debug）"
(
  cd "${ROOT_DIR}"
  cargo build --locked --package storpulse-ffi
)

if [[ ! -f "${ENGINE_LIBRARY}" ]]; then
  echo "Rust 动态库未生成：${ENGINE_LIBRARY}" >&2
  exit 1
fi

export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE_DIR}"
export SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE_DIR}"

SWIFT_BUILD_ARGUMENTS=(
  build
  --disable-sandbox
  --skip-update
  --configuration debug
  --package-path "${ROOT_DIR}/platform/macos"
  --scratch-path "${SWIFT_SCRATCH_DIR}"
  --product storpulse-mac
)

echo "[2/3] 编译 SwiftPM Debug 产品"
swift "${SWIFT_BUILD_ARGUMENTS[@]}"

SWIFT_BIN_DIR="$(swift "${SWIFT_BUILD_ARGUMENTS[@]}" --show-bin-path)"
SWIFT_EXECUTABLE="${SWIFT_BIN_DIR}/storpulse-mac"
if [[ ! -x "${SWIFT_EXECUTABLE}" ]]; then
  echo "Swift 可执行文件未生成：${SWIFT_EXECUTABLE}" >&2
  exit 1
fi

echo "[3/3] 组装并签名本地 Debug .app"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${SWIFT_EXECUTABLE}" "${APP_EXECUTABLE}"
cat >"${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>StorPulse Debug</string>
    <key>CFBundleExecutable</key>
    <string>storpulse-mac</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_IDENTIFIER}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>StorPulse</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
plutil -lint "${APP_BUNDLE}/Contents/Info.plist" >/dev/null
storpulse_sign_debug_app \
  "${SIGNING_MODE}" \
  "${SIGNING_CONTEXT}" \
  "${APP_BUNDLE}" \
  "${BUNDLE_IDENTIFIER}" \
  "${DEBUG_DIR}"

echo "Rust 引擎：${ENGINE_LIBRARY}"
echo "应用目录：${APP_BUNDLE}"

if [[ "${PREPARE_ONLY}" -eq 1 ]]; then
  echo "已完成组装；按 --prepare-only 要求不启动应用。"
  exit 0
fi

echo "启动 StorPulse macOS Debug"
echo "退出方式：从 StorPulse 状态栏 Popover 点击“退出”。"

if [[ "${USE_DEBUGGER}" -eq 1 ]]; then
  exec env \
    STORPULSE_ENGINE_LIBRARY="${ENGINE_LIBRARY}" \
    lldb -- "${APP_EXECUTABLE}"
fi

exec env \
  STORPULSE_ENGINE_LIBRARY="${ENGINE_LIBRARY}" \
  "${APP_EXECUTABLE}"
