#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Bolt.app"
INSTALL_DIR="${GROQ_DICTATE_INSTALL_DIR:-/Applications}"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}"
METADATA_ENV_PATH="${ROOT_DIR}/dist/release-metadata.env"
BUILD_BUNDLE_TMP_DIR=""

cleanup() {
  if [[ -n "${BUILD_BUNDLE_TMP_DIR}" ]]; then
    rm -rf "${BUILD_BUNDLE_TMP_DIR}"
  fi
}
trap cleanup EXIT

if [[ -z "${GROQ_DICTATE_BUNDLE_PATH:-}" ]]; then
  BUILD_BUNDLE_TMP_DIR="$(mktemp -d)"
  export GROQ_DICTATE_BUNDLE_PATH="${BUILD_BUNDLE_TMP_DIR}/${APP_NAME}"
fi
BUNDLE_PATH="${GROQ_DICTATE_BUNDLE_PATH}"

cd "${ROOT_DIR}"
"${ROOT_DIR}/scripts/build_release_bundle.sh"

if [[ ! -d "${BUNDLE_PATH}" ]]; then
  echo "Release bundle not found: ${BUNDLE_PATH}" >&2
  exit 1
fi

if [[ -f "${METADATA_ENV_PATH}" ]]; then
  # shellcheck source=/dev/null
  source "${METADATA_ENV_PATH}"
fi

rm -rf "${INSTALL_PATH}"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "${BUNDLE_PATH}" "${INSTALL_PATH}"
codesign --verify --deep --strict "${INSTALL_PATH}"

echo "Installed to ${INSTALL_PATH}"
if [[ -n "${GROQ_DICTATE_VERSION_DISPLAY:-}" ]]; then
  echo "Version: ${GROQ_DICTATE_VERSION_DISPLAY}"
fi
codesign -dv --verbose=2 "${INSTALL_PATH}" 2>&1 | sed -n '/Identifier=/p;/TeamIdentifier=/p;/Authority=/p;/Signature=/p'
