#!/usr/bin/env bash
set -euo pipefail

strip_version_prefix() {
  local raw_version="$1"
  printf '%s' "${raw_version#v}"
}

first_semver_tag() {
  local root_dir="$1"
  shift

  git -C "${root_dir}" tag --sort=-version:refname "$@" 2>/dev/null \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -n 1 || true
}

sanitize_artifact_component() {
  printf '%s' "$1" \
    | tr -c 'A-Za-z0-9._-' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

print_release_metadata_env() {
  local key
  for key in \
    GROQ_DICTATE_SHORT_VERSION \
    GROQ_DICTATE_BUNDLE_VERSION \
    GROQ_DICTATE_VERSION_SOURCE \
    GROQ_DICTATE_GIT_COMMIT \
    GROQ_DICTATE_GIT_SHORT_COMMIT \
    GROQ_DICTATE_GIT_BRANCH \
    GROQ_DICTATE_GIT_DIRTY \
    GROQ_DICTATE_BUILD_DATE_UTC \
    GROQ_DICTATE_VERSION_DISPLAY \
    GROQ_DICTATE_ARTIFACT_STEM
  do
    printf '%s=%q\n' "${key}" "${!key}"
  done
}

resolve_release_metadata() {
  local root_dir="$1"
  local exact_tag=""
  local latest_tag=""
  local default_short_version="0.0.0"
  local commit_count="1"
  local commit="unknown"
  local short_commit="unknown"
  local branch="unknown"
  local dirty="false"
  local version_source="no-git"

  if git -C "${root_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exact_tag="$(first_semver_tag "${root_dir}" --points-at HEAD)"
    latest_tag="$(first_semver_tag "${root_dir}" --merged HEAD)"
    commit_count="$(git -C "${root_dir}" rev-list --count HEAD)"
    commit="$(git -C "${root_dir}" rev-parse HEAD)"
    short_commit="$(git -C "${root_dir}" rev-parse --short=10 HEAD)"
    branch="$(git -C "${root_dir}" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"

    if [[ -n "$(git -C "${root_dir}" status --porcelain --untracked-files=normal)" ]]; then
      dirty="true"
    fi

    if [[ -n "${exact_tag}" ]]; then
      default_short_version="$(strip_version_prefix "${exact_tag}")"
      version_source="exact-tag"
    elif [[ -n "${latest_tag}" ]]; then
      default_short_version="$(strip_version_prefix "${latest_tag}")"
      version_source="latest-tag"
    else
      version_source="no-tag"
    fi
  fi

  GROQ_DICTATE_SHORT_VERSION="${GROQ_DICTATE_SHORT_VERSION:-${default_short_version}}"
  GROQ_DICTATE_BUNDLE_VERSION="${GROQ_DICTATE_BUNDLE_VERSION:-${commit_count}}"
  GROQ_DICTATE_VERSION_SOURCE="${GROQ_DICTATE_VERSION_SOURCE:-${version_source}}"
  GROQ_DICTATE_GIT_COMMIT="${GROQ_DICTATE_GIT_COMMIT:-${commit}}"
  GROQ_DICTATE_GIT_SHORT_COMMIT="${GROQ_DICTATE_GIT_SHORT_COMMIT:-${short_commit}}"
  GROQ_DICTATE_GIT_BRANCH="${GROQ_DICTATE_GIT_BRANCH:-${branch}}"
  GROQ_DICTATE_GIT_DIRTY="${GROQ_DICTATE_GIT_DIRTY:-${dirty}}"
  GROQ_DICTATE_BUILD_DATE_UTC="${GROQ_DICTATE_BUILD_DATE_UTC:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

  if ! [[ "${GROQ_DICTATE_SHORT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "GROQ_DICTATE_SHORT_VERSION must look like 1.2.3." >&2
    exit 1
  fi

  if ! [[ "${GROQ_DICTATE_BUNDLE_VERSION}" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    echo "GROQ_DICTATE_BUNDLE_VERSION must be one to three dot-separated integers." >&2
    exit 1
  fi

  local dirty_label=""
  local artifact_dirty_label=""
  if [[ "${GROQ_DICTATE_GIT_DIRTY}" == "true" ]]; then
    dirty_label=", dirty"
    artifact_dirty_label="-dirty"
  fi

  GROQ_DICTATE_VERSION_DISPLAY="${GROQ_DICTATE_VERSION_DISPLAY:-v${GROQ_DICTATE_SHORT_VERSION} build ${GROQ_DICTATE_BUNDLE_VERSION} (${GROQ_DICTATE_GIT_SHORT_COMMIT}${dirty_label})}"
  GROQ_DICTATE_ARTIFACT_STEM="${GROQ_DICTATE_ARTIFACT_STEM:-Bolt-$(sanitize_artifact_component "${GROQ_DICTATE_SHORT_VERSION}-build.${GROQ_DICTATE_BUNDLE_VERSION}-${GROQ_DICTATE_GIT_SHORT_COMMIT}${artifact_dirty_label}")}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  resolve_release_metadata "${ROOT_DIR}"
  print_release_metadata_env
fi
