#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="BoCollector.app"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}"
INSTALL_MODE=1

for arg in "$@"; do
  case "$arg" in
    --no-install)
      INSTALL_MODE=0
      ;;
    --install)
      INSTALL_MODE=1
      ;;
    *)
      echo "未知参数: $arg (支持 --install / --no-install)" >&2
      exit 2
      ;;
  esac
done

echo "==> [1/4] 编译 Release 原生二进制 (BoCollectorApp + bo-collect)..."
cd "${ROOT_DIR}"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> [2/4] 组装 macOS App Bundle: ${APP_BUNDLE}..."
if [[ ! -f "${ROOT_DIR}/Resources/AppIcon.icns" ]]; then
  echo "    生成 AppIcon.icns..."
  swift "${ROOT_DIR}/scripts/generate_icon.swift"
fi

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>BoCollector</string>
  <key>CFBundleExecutable</key>
  <string>BoCollectorApp</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.bo.collector.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>BoCollector</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0.0</string>
  <key>CFBundleVersion</key>
  <string>200</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

cp "${BIN_DIR}/BoCollectorApp" "${APP_BUNDLE}/Contents/MacOS/BoCollectorApp"
cp "${BIN_DIR}/bo-collect" "${APP_BUNDLE}/Contents/MacOS/bo-collect"
chmod 755 "${APP_BUNDLE}/Contents/MacOS/BoCollectorApp" "${APP_BUNDLE}/Contents/MacOS/bo-collect"

echo "==> [3/4] 执行本地 Ad-hoc 代码签名..."
codesign --force --deep --sign - "${APP_BUNDLE}"

if [[ "${INSTALL_MODE}" -eq 1 ]]; then
  USER_APPS="${HOME}/Applications"
  INSTALLED_APP="${USER_APPS}/${APP_NAME}"
  LOCAL_BIN="${HOME}/.local/bin"

  echo "==> [4/4] 安装到 ${INSTALLED_APP} 并链接 ~/.local/bin/bo-collect..."
  mkdir -p "${USER_APPS}" "${LOCAL_BIN}"
  rm -rf "${INSTALLED_APP}"
  cp -R "${APP_BUNDLE}" "${INSTALLED_APP}"
  codesign --force --deep --sign - "${INSTALLED_APP}"
  touch "${INSTALLED_APP}"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "${LSREGISTER}" ]]; then
    "${LSREGISTER}" -f "${INSTALLED_APP}" >/dev/null 2>&1 || true
  fi
  ln -sf "${INSTALLED_APP}/Contents/MacOS/bo-collect" "${LOCAL_BIN}/bo-collect"

  echo "构建与安装完成:"
  echo "  App Bundle : ${INSTALLED_APP}"
  echo "  CLI Binary : ${LOCAL_BIN}/bo-collect -> ${INSTALLED_APP}/Contents/MacOS/bo-collect"
else
  echo "==> [4/4] 跳过安装 (--no-install)，产物位于: ${APP_BUNDLE}"
fi
