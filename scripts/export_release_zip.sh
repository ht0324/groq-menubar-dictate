#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Bolt.app"
DIST_DIR="${GROQ_DICTATE_DIST_DIR:-${ROOT_DIR}/dist}"
METADATA_ENV_PATH="${DIST_DIR}/release-metadata.env"
BUILD_BUNDLE_TMP_DIR=""
VERIFY_DIR=""

cleanup() {
  if [[ -n "${BUILD_BUNDLE_TMP_DIR}" ]]; then
    rm -rf "${BUILD_BUNDLE_TMP_DIR}"
  fi
  if [[ -n "${VERIFY_DIR}" ]]; then
    rm -rf "${VERIFY_DIR}"
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

if [[ ! -f "${METADATA_ENV_PATH}" ]]; then
  echo "Release metadata not found: ${METADATA_ENV_PATH}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${METADATA_ENV_PATH}"

ZIP_NAME="${GROQ_DICTATE_ARTIFACT_STEM}-macos.zip"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"
rm -f "${ZIP_PATH}"

(
  cd "$(dirname "${BUNDLE_PATH}")"
  /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$(basename "${BUNDLE_PATH}")" "${ZIP_PATH}"
)

VERIFY_DIR="$(mktemp -d)"
/usr/bin/ditto -x -k "${ZIP_PATH}" "${VERIFY_DIR}"
codesign --verify --deep --strict "${VERIFY_DIR}/${APP_NAME}"

echo "Exported ${ZIP_PATH}"
echo "Version: ${GROQ_DICTATE_VERSION_DISPLAY}"
