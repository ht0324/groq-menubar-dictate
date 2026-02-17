#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Groq MenuBar Dictate.app"
BUNDLE_ID="com.huntae.groq-menubar-dictate"
EXECUTABLE_NAME="groq-menubar-dictate"
INSTALL_DIR="/Applications"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}"

cd "${ROOT_DIR}"
swift build -c release

BINARY_PATH="${ROOT_DIR}/.build/release/${EXECUTABLE_NAME}"
if [[ ! -x "${BINARY_PATH}" ]]; then
  echo "Release binary not found: ${BINARY_PATH}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BUNDLE_PATH="${TMP_DIR}/${APP_NAME}"
CONTENTS_DIR="${BUNDLE_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

mkdir -p "${MACOS_DIR}"
cp "${BINARY_PATH}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Groq MenuBar Dictate</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Groq MenuBar Dictate records short audio clips when you tap Option to transcribe speech.</string>
</dict>
</plist>
PLIST

rm -rf "${INSTALL_PATH}"
cp -R "${BUNDLE_PATH}" "${INSTALL_DIR}/"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --identifier "${BUNDLE_ID}" --deep "${INSTALL_PATH}" >/dev/null 2>&1 || true
fi

echo "Installed to ${INSTALL_PATH}"
