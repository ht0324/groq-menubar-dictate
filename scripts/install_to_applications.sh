#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Groq MenuBar Dictate.app"
BUNDLE_ID="com.huntae.groq-menubar-dictate"
EXECUTABLE_NAME="groq-menubar-dictate"
INSTALL_DIR="/Applications"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}"
SIGN_IDENTITY="${GROQ_DICTATE_SIGN_IDENTITY:-}"
SIGN_IDENTITY_HINT="${GROQ_DICTATE_SIGN_IDENTITY_HINT:-}"
ALLOW_ADHOC_SIGNING="${GROQ_DICTATE_ALLOW_ADHOC:-0}"

resolve_sign_identity() {
  local identities
  local identity

  if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "${SIGN_IDENTITY}"
    return 0
  fi

  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  if [[ -n "${SIGN_IDENTITY_HINT}" ]]; then
    identity="$(printf '%s\n' "${identities}" | grep -Fi "${SIGN_IDENTITY_HINT}" | sed -n 's/.*"\(.*\)".*/\1/p' | head -n 1 || true)"
    if [[ -n "${identity}" ]]; then
      echo "${identity}"
      return 0
    fi
  fi

  identity="$(printf '%s\n' "${identities}" | grep -F "Developer ID Application:" | sed -n 's/.*"\(.*\)".*/\1/p' | head -n 1 || true)"
  if [[ -n "${identity}" ]]; then
    echo "${identity}"
    return 0
  fi

  identity="$(printf '%s\n' "${identities}" | grep -F "Apple Development:" | sed -n 's/.*"\(.*\)".*/\1/p' | head -n 1 || true)"
  if [[ -n "${identity}" ]]; then
    echo "${identity}"
    return 0
  fi

  if [[ "${ALLOW_ADHOC_SIGNING}" == "1" ]]; then
    echo "-"
    return 0
  fi

  echo "No usable code-signing identity found." >&2
  echo "Install an Apple Development or Developer ID Application certificate." >&2
  echo "Then rerun with GROQ_DICTATE_SIGN_IDENTITY=\"<certificate common name>\"." >&2
  if [[ -n "${SIGN_IDENTITY_HINT}" ]]; then
    echo "Hint GROQ_DICTATE_SIGN_IDENTITY_HINT=\"${SIGN_IDENTITY_HINT}\" did not match any identity." >&2
  fi
  echo "Use GROQ_DICTATE_ALLOW_ADHOC=1 only if you accept permission resets on update." >&2
  echo >&2
  echo "${identities}" >&2
  exit 1
}

if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign command not found." >&2
  exit 1
fi

if ! command -v security >/dev/null 2>&1; then
  echo "security command not found." >&2
  exit 1
fi

SELECTED_SIGN_IDENTITY="$(resolve_sign_identity)"
if [[ "${SELECTED_SIGN_IDENTITY}" == "-" ]]; then
  echo "Signing with ad-hoc identity (permissions may reset on updates)."
else
  echo "Signing with identity: ${SELECTED_SIGN_IDENTITY}"
fi

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

codesign --force --sign "${SELECTED_SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" --deep "${BUNDLE_PATH}"
codesign --verify --deep --strict "${BUNDLE_PATH}"

rm -rf "${INSTALL_PATH}"
cp -R "${BUNDLE_PATH}" "${INSTALL_DIR}/"
codesign --verify --deep --strict "${INSTALL_PATH}"

echo "Installed to ${INSTALL_PATH}"
codesign -dv --verbose=2 "${INSTALL_PATH}" 2>&1 | sed -n '/Identifier=/p;/TeamIdentifier=/p;/Authority=/p;/Signature=/p'
