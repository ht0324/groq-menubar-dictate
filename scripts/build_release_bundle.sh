#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Groq MenuBar Dictate.app"
BUNDLE_ID="com.huntae.groq-menubar-dictate"
EXECUTABLE_NAME="groq-menubar-dictate"
DIST_DIR="${GROQ_DICTATE_DIST_DIR:-${ROOT_DIR}/dist}"
BUNDLE_PATH="${GROQ_DICTATE_BUNDLE_PATH:-${DIST_DIR}/${APP_NAME}}"
SIGN_IDENTITY="${GROQ_DICTATE_SIGN_IDENTITY:-}"
SIGN_IDENTITY_HINT="${GROQ_DICTATE_SIGN_IDENTITY_HINT:-}"
LOCAL_SIGN_IDENTITY="${GROQ_DICTATE_LOCAL_SIGN_IDENTITY:-Groq MenuBar Dictate Local Code Signing}"
ALLOW_ADHOC_SIGNING="${GROQ_DICTATE_ALLOW_ADHOC:-0}"

# shellcheck source=scripts/release_metadata.sh
source "${ROOT_DIR}/scripts/release_metadata.sh"

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

  identity="$(printf '%s\n' "${identities}" | grep -F "\"${LOCAL_SIGN_IDENTITY}\"" | sed -n 's/.*"\(.*\)".*/\1/p' | head -n 1 || true)"
  if [[ -n "${identity}" ]]; then
    echo "${identity}"
    return 0
  fi

  if [[ "${ALLOW_ADHOC_SIGNING}" == "1" ]]; then
    echo "-"
    return 0
  fi

  echo "No usable code-signing identity found." >&2
  echo "For stable local permissions, run ./scripts/create_local_signing_identity.sh once." >&2
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

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "${value}"
}

if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign command not found." >&2
  exit 1
fi

if ! command -v security >/dev/null 2>&1; then
  echo "security command not found." >&2
  exit 1
fi

resolve_release_metadata "${ROOT_DIR}"

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

SIGNED_BUNDLE_PATH="${TMP_DIR}/${APP_NAME}"
CONTENTS_DIR="${SIGNED_BUNDLE_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
METADATA_ENV_PATH="${DIST_DIR}/release-metadata.env"

mkdir -p "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
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
  <string>$(xml_escape "${GROQ_DICTATE_SHORT_VERSION}")</string>
  <key>CFBundleVersion</key>
  <string>$(xml_escape "${GROQ_DICTATE_BUNDLE_VERSION}")</string>
  <key>GMDBuildDate</key>
  <string>$(xml_escape "${GROQ_DICTATE_BUILD_DATE_UTC}")</string>
  <key>GMDGitBranch</key>
  <string>$(xml_escape "${GROQ_DICTATE_GIT_BRANCH}")</string>
  <key>GMDGitCommit</key>
  <string>$(xml_escape "${GROQ_DICTATE_GIT_COMMIT}")</string>
  <key>GMDGitDirty</key>
  <${GROQ_DICTATE_GIT_DIRTY}/>
  <key>GMDVersionDisplay</key>
  <string>$(xml_escape "${GROQ_DICTATE_VERSION_DISPLAY}")</string>
  <key>GMDVersionSource</key>
  <string>$(xml_escape "${GROQ_DICTATE_VERSION_SOURCE}")</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Groq MenuBar Dictate records short audio clips when you tap Option to transcribe speech.</string>
</dict>
</plist>
PLIST

cat > "${RESOURCES_DIR}/release-metadata.txt" <<EOF
Groq MenuBar Dictate
Version: ${GROQ_DICTATE_VERSION_DISPLAY}
Short version: ${GROQ_DICTATE_SHORT_VERSION}
Build: ${GROQ_DICTATE_BUNDLE_VERSION}
Commit: ${GROQ_DICTATE_GIT_COMMIT}
Branch: ${GROQ_DICTATE_GIT_BRANCH}
Dirty: ${GROQ_DICTATE_GIT_DIRTY}
Built: ${GROQ_DICTATE_BUILD_DATE_UTC}
EOF

print_release_metadata_env > "${METADATA_ENV_PATH}"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "${SIGNED_BUNDLE_PATH}"
fi

codesign --force --sign "${SELECTED_SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" --deep "${SIGNED_BUNDLE_PATH}"
codesign --verify --deep --strict "${SIGNED_BUNDLE_PATH}"

rm -rf "${BUNDLE_PATH}"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "${SIGNED_BUNDLE_PATH}" "${BUNDLE_PATH}"

echo "Built ${BUNDLE_PATH}"
echo "Version: ${GROQ_DICTATE_VERSION_DISPLAY}"
echo "Metadata: ${METADATA_ENV_PATH}"
