#!/usr/bin/env bash
# Usage: ./record.sh [--serial /dev/cu.usbmodem…] [session-name] <expected-squeezes>
# Captures serial telemetry, app logs, a session-owned raw WAV, and provenance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SESSION_ROOT="${SCRIPT_DIR}/sessions"
APP_DOMAIN="com.huntae.groq-menubar-dictate"
APP_BUNDLE="/Applications/Bolt.app"
APP_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/Bolt"
APP_INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
TRIGGER_KEY="settings.audioActivityTriggerEnabled"
RAW_DUMP_KEY="settings.audioTriggerRawDumpEnabled"
DIAGNOSTICS_KEY="settings.performanceDiagnosticsEnabled"

usage() {
    cat <<EOF
Usage: $0 [--serial /dev/cu.usbmodem…] [session-name] <expected-squeezes>

  session-name       Optional label used in the local session directory name.
  expected-squeezes  Required positive integer used by acceptance analysis.
  --serial PATH      Select one attached /dev/cu.usbmodem* device explicitly.
                     Without this option, exactly one matching device is required.
  -h, --help         Show this help.

The recorder never changes app preferences or deploys Ting firmware. After
preflight succeeds, it restarts the installed app to create a session-owned
raw WAV, then leaves the installed app running when capture finishes.
EOF
}

fail() {
    echo "preflight failed: $*" >&2
    exit 1
}

epoch_now() {
    python3 - <<'PY'
import time
print("{:.9f}".format(time.time()))
PY
}

local_log_time() {
    python3 - "$1" <<'PY'
from datetime import datetime
import sys
print(datetime.fromtimestamp(float(sys.argv[1])).strftime("%Y-%m-%d %H:%M:%S"))
PY
}

setting_value() {
    defaults read "${APP_DOMAIN}" "$1" 2>/dev/null || true
}

require_enabled_setting() {
    local key="$1"
    local label="$2"
    local value
    value="$(setting_value "${key}")"
    if [[ "${value}" != "1" ]]; then
        echo "${label} is not enabled (${key}=${value:-unset})." >&2
        echo "Enable it in Bolt settings, restart the app, and retry." >&2
        exit 1
    fi
    printf '%s' "${value}"
}

running_app_pids() {
    /usr/bin/pgrep -f -x "${APP_EXECUTABLE}" 2>/dev/null || true
}

single_running_app_pid() {
    local pids
    local count
    pids="$(running_app_pids)"
    count="$(printf '%s\n' "${pids}" | awk 'NF { count += 1 } END { print count + 0 }')"
    if [[ "${count}" != "1" ]]; then
        return 1
    fi
    printf '%s\n' "${pids}"
}

wait_for_single_running_app() {
    local attempt=0
    local pid
    while (( attempt < 50 )); do
        if pid="$(single_running_app_pid)"; then
            printf '%s\n' "${pid}"
            return 0
        fi
        sleep 0.2
        attempt=$((attempt + 1))
    done
    return 1
}

stop_installed_app() {
    local attempt=0
    if ! osascript -e "tell application id \"${APP_DOMAIN}\" to quit" >/dev/null 2>&1; then
        return 1
    fi
    while (( attempt < 50 )); do
        if [[ -z "$(running_app_pids)" ]]; then
            return 0
        fi
        sleep 0.2
        attempt=$((attempt + 1))
    done
    return 1
}

launch_installed_app() {
    open "${APP_BUNDLE}" >/dev/null 2>&1 || return 1
    wait_for_single_running_app
}

raw_wavs_for_pid() {
    local pid="$1"
    /usr/sbin/lsof -a -p "${pid}" -Fn 2>/dev/null \
        | sed -n 's/^n//p' \
        | awk '/\/ting-raw\/ting-raw-[^\/]*\.wav$/ && !seen[$0]++ { print }'
}

file_size() {
    stat -f '%z' "$1"
}

explicit_serial=""
positionals=()
while (( $# > 0 )); do
    case "$1" in
        --serial)
            if (( $# < 2 )) || [[ "$2" == -* ]]; then
                echo "--serial requires a /dev/cu.usbmodem* path" >&2
                usage >&2
                exit 2
            fi
            explicit_serial="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while (( $# > 0 )); do
                positionals+=("$1")
                shift
            done
            ;;
        -*)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            positionals+=("$1")
            shift
            ;;
    esac
done

session_name=""
expected_squeezes=""
case "${#positionals[@]}" in
    1)
        expected_squeezes="${positionals[0]}"
        ;;
    2)
        session_name="${positionals[0]}"
        expected_squeezes="${positionals[1]}"
        ;;
    *)
        echo "a positive expected squeeze count is required" >&2
        usage >&2
        exit 2
        ;;
esac

if [[ ! "${expected_squeezes}" =~ ^[0-9]+$ ]]; then
    echo "expected squeeze count must be a positive integer" >&2
    usage >&2
    exit 2
fi
expected_squeezes=$((10#${expected_squeezes}))
if (( expected_squeezes <= 0 )); then
    echo "expected squeeze count must be a positive integer" >&2
    usage >&2
    exit 2
fi

safe_name=""
if [[ -n "${session_name}" ]]; then
    safe_name="$(printf '%s' "${session_name}" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//')"
    if [[ -z "${safe_name}" ]]; then
        echo "session name must contain at least one letter, number, dot, underscore, or hyphen" >&2
        exit 2
    fi
fi

shopt -s nullglob
serial_devices=(/dev/cu.usbmodem*)
shopt -u nullglob

serial_selection="automatic"
if [[ -n "${explicit_serial}" ]]; then
    case "${explicit_serial}" in
        /dev/cu.usbmodem*) ;;
        *) fail "--serial must select an attached /dev/cu.usbmodem* device" ;;
    esac
    serial_found=0
    for candidate in "${serial_devices[@]}"; do
        if [[ "${candidate}" == "${explicit_serial}" ]]; then
            serial_found=1
            break
        fi
    done
    if [[ "${serial_found}" != "1" ]]; then
        fail "selected serial device is not attached: ${explicit_serial}"
    fi
    serial_device="${explicit_serial}"
    serial_selection="explicit"
else
    if (( ${#serial_devices[@]} == 0 )); then
        fail "no /dev/cu.usbmodem* device found; replug the Ting USB-C cable"
    fi
    if (( ${#serial_devices[@]} != 1 )); then
        printf 'preflight failed: found %d serial devices:\n' "${#serial_devices[@]}" >&2
        printf '  %s\n' "${serial_devices[@]}" >&2
        echo "Retry with --serial /dev/cu.usbmodem… to select the Ting explicitly." >&2
        exit 1
    fi
    serial_device="${serial_devices[0]}"
fi

serial_owners="$(/usr/sbin/lsof -t "${serial_device}" 2>/dev/null | sort -u || true)"
if [[ -n "${serial_owners}" ]]; then
    echo "preflight failed: serial device is already open: ${serial_device}" >&2
    ps -p "$(printf '%s' "${serial_owners}" | paste -sd, -)" -o pid=,command= >&2 || true
    echo "Stop the existing serial monitor and retry so marker telemetry is not split between readers." >&2
    exit 1
fi

trigger_enabled="$(require_enabled_setting "${TRIGGER_KEY}" "Ting audio trigger")"
raw_dump_enabled="$(require_enabled_setting "${RAW_DUMP_KEY}" "Ting raw dumps")"
diagnostics_enabled="$(require_enabled_setting "${DIAGNOSTICS_KEY}" "Performance diagnostics")"

repo_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null)" \
    || fail "cannot read repository HEAD at ${REPO_ROOT}"
repo_status="$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=normal)"
if [[ -n "${repo_status}" ]]; then
    echo "preflight failed: repository must be clean so capture provenance is reproducible:" >&2
    printf '%s\n' "${repo_status}" >&2
    echo "Commit or remove the listed changes, reinstall that commit, and retry." >&2
    exit 1
fi

if [[ ! -f "${APP_INFO_PLIST}" || ! -x "${APP_EXECUTABLE}" ]]; then
    fail "installed app is missing or incomplete at ${APP_BUNDLE}"
fi

installed_fields="$(python3 - "${APP_INFO_PLIST}" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
dirty = info.get("GMDGitDirty")
print(str(info.get("GMDGitCommit") or ""))
print("1" if dirty in (True, 1, "1", "true", "YES") else "0")
print(str(info.get("CFBundleVersion") or ""))
PY
)" || fail "cannot read installed app build metadata"
installed_commit="$(printf '%s\n' "${installed_fields}" | sed -n '1p')"
installed_dirty="$(printf '%s\n' "${installed_fields}" | sed -n '2p')"
installed_build="$(printf '%s\n' "${installed_fields}" | sed -n '3p')"
if [[ -z "${installed_commit}" || "${installed_commit}" != "${repo_commit}" ]]; then
    fail "installed app commit ${installed_commit:-missing} does not match clean repository HEAD ${repo_commit}; reinstall first"
fi
if [[ "${installed_dirty}" != "0" ]]; then
    fail "installed app build ${installed_build:-unknown} was produced from a dirty tree; reinstall the clean HEAD first"
fi
if ! original_app_pid="$(single_running_app_pid)"; then
    fail "exactly one installed app process must be running from ${APP_EXECUTABLE}"
fi

cable_input_json="$(system_profiler SPAudioDataType -json 2>/dev/null | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (ValueError, OSError):
    raise SystemExit(2)

matches = []
for section in payload.get("SPAudioDataType", []):
    for item in section.get("_items", []):
        name = str(item.get("_name") or "")
        try:
            inputs = int(item.get("coreaudio_device_input") or 0)
        except (TypeError, ValueError):
            inputs = 0
        if "cable creation" in name.lower() and inputs > 0:
            matches.append({
                "name": name,
                "input_channels": inputs,
                "sample_rate": item.get("coreaudio_device_srate"),
                "transport": item.get("coreaudio_device_transport"),
                "input_source": item.get("coreaudio_input_source"),
            })
if len(matches) != 1:
    raise SystemExit(1)
print(json.dumps(matches[0], sort_keys=True))
')" || fail "exactly one Cable Creation audio input must be connected and visible to CoreAudio"

if [[ ! -d /Volumes/TINGDISK ]]; then
    fail "TINGDISK is not mounted; replug the Ting USB-C cable so deployed firmware and marker assets can be verified"
fi
ting_mounted=1
firmware_profile="current"
firmware_main_mode="frozen-firmware-no-main-file"
for required_file in user.py marker_start.wav marker_stop.wav; do
    if [[ ! -f "/Volumes/TINGDISK/${required_file}" ]]; then
        fail "TINGDISK is mounted but ${required_file} is missing; inspect or redeploy before capture"
    fi
done
if ! cmp -s "${REPO_ROOT}/ting/user.py" /Volumes/TINGDISK/user.py; then
    if cmp -s "${REPO_ROOT}/ting/user_v12.py" /Volumes/TINGDISK/user.py; then
        fail "TINGDISK has the stop-only profile; deploy the current v13 START+STOP profile before acceptance"
    fi
    fail "TINGDISK/user.py does not match the tracked current v13 profile"
fi
if ! cmp -s "${REPO_ROOT}/ting/marker_start.wav" /Volumes/TINGDISK/marker_start.wav; then
    fail "TINGDISK/marker_start.wav does not match the tracked marker asset"
fi
if ! cmp -s "${REPO_ROOT}/ting/marker_stop.wav" /Volumes/TINGDISK/marker_stop.wav; then
    fail "TINGDISK/marker_stop.wav does not match the tracked marker asset"
fi
if [[ -f /Volumes/TINGDISK/main.py ]]; then
    if ! cmp -s "${REPO_ROOT}/ting/main_tingdisk.py" /Volumes/TINGDISK/main.py; then
        fail "TINGDISK/main.py is present but does not match tracked main_tingdisk.py"
    fi
    firmware_main_mode="tracked-override"
fi

utc_stamp="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
PY
)"
session_dir="${SESSION_ROOT}/${utc_stamp}"
if [[ -n "${safe_name}" ]]; then
    session_dir="${session_dir}-${safe_name}"
fi
if [[ -e "${session_dir}" ]]; then
    fail "session directory already exists: ${session_dir}"
fi
mkdir -p "${session_dir}"

meta_path="${session_dir}/meta.json"
raw_paths_file="${session_dir}/.raw-dump-paths.txt"
copied_paths_file="${session_dir}/.copied-wavs.tsv"
: > "${raw_paths_file}"
: > "${copied_paths_file}"
: > "${session_dir}/serial.log"

preflight_start_epoch="$(epoch_now)"
setup_active=1
setup_failure_message="capture setup was interrupted"
serial_pid=""
setup_cleanup() {
    local status="$?"
    trap - EXIT INT TERM
    if [[ "${setup_active}" == "1" ]]; then
        if [[ -n "${serial_pid}" ]] && kill -0 "${serial_pid}" 2>/dev/null; then
            kill "${serial_pid}" 2>/dev/null || true
            wait "${serial_pid}" 2>/dev/null || true
        fi
        if ! single_running_app_pid >/dev/null 2>&1; then
            launch_installed_app >/dev/null 2>&1 || true
        fi
        if [[ -f "${meta_path}" ]]; then
            python3 - "${meta_path}" "${setup_failure_message}" <<'PY' || true
import json
import sys

path, message = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as handle:
        meta = json.load(handle)
except (OSError, ValueError):
    meta = {}
meta["status"] = "preflight_failed"
meta["preflight_failure"] = message
with open(path, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
        fi
    fi
    exit "${status}"
}
trap setup_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

setup_failure_message="installed app did not quit cleanly during session-owned WAV setup"
if ! stop_installed_app; then
    echo "preflight failed: ${setup_failure_message}" >&2
    exit 1
fi

# Ensure the second-resolution raw filename cannot collide with the file owned
# by the just-closed process.
sleep 1
setup_failure_message="installed app did not relaunch cleanly from ${APP_BUNDLE}"
if ! app_pid="$(launch_installed_app)"; then
    echo "preflight failed: ${setup_failure_message}" >&2
    exit 1
fi
if [[ "${app_pid}" == "${original_app_pid}" ]]; then
    setup_failure_message="app relaunch reused the old process instead of creating a session-owned stream"
    echo "preflight failed: ${setup_failure_message}" >&2
    exit 1
fi

trigger_after_restart="$(setting_value "${TRIGGER_KEY}")"
raw_dump_after_restart="$(setting_value "${RAW_DUMP_KEY}")"
diagnostics_after_restart="$(setting_value "${DIAGNOSTICS_KEY}")"
if [[ "${trigger_after_restart}" != "${trigger_enabled}" || \
      "${raw_dump_after_restart}" != "${raw_dump_enabled}" || \
      "${diagnostics_after_restart}" != "${diagnostics_enabled}" ]]; then
    setup_failure_message="required preferences changed across app restart"
    echo "preflight failed: ${setup_failure_message}; no preferences were modified by the recorder" >&2
    exit 1
fi

active_raw_path=""
attempt=0
while (( attempt < 50 )); do
    raw_candidates="$(raw_wavs_for_pid "${app_pid}")"
    raw_candidate_count="$(printf '%s\n' "${raw_candidates}" | awk 'NF { count += 1 } END { print count + 0 }')"
    if [[ "${raw_candidate_count}" == "1" ]]; then
        active_raw_path="${raw_candidates}"
        break
    fi
    if (( raw_candidate_count > 1 )); then
        setup_failure_message="restarted app has multiple open Ting raw WAVs"
        printf 'preflight failed: %s:\n%s\n' "${setup_failure_message}" "${raw_candidates}" >&2
        exit 1
    fi
    sleep 0.2
    attempt=$((attempt + 1))
done
if [[ -z "${active_raw_path}" || ! -f "${active_raw_path}" ]]; then
    setup_failure_message="restarted app has no open Ting raw WAV; confirm Cable Creation access and raw dumps"
    echo "preflight failed: ${setup_failure_message}" >&2
    exit 1
fi

raw_growth_start_size="$(file_size "${active_raw_path}")"
raw_growth_end_size="${raw_growth_start_size}"
attempt=0
while (( attempt < 10 )); do
    sleep 0.5
    if [[ ! -f "${active_raw_path}" ]]; then
        setup_failure_message="active Ting raw WAV disappeared during growth verification"
        echo "preflight failed: ${setup_failure_message}" >&2
        exit 1
    fi
    raw_growth_end_size="$(file_size "${active_raw_path}")"
    if (( raw_growth_end_size > raw_growth_start_size )); then
        break
    fi
    attempt=$((attempt + 1))
done
if (( raw_growth_end_size <= raw_growth_start_size )); then
    setup_failure_message="active Ting raw WAV is not growing: ${active_raw_path}"
    echo "preflight failed: ${setup_failure_message}" >&2
    exit 1
fi

session_start_epoch="$(epoch_now)"
raw_capture_start_size="$(file_size "${active_raw_path}")"

python3 - \
    "${meta_path}" \
    "${preflight_start_epoch}" \
    "${session_start_epoch}" \
    "${serial_device}" \
    "${serial_selection}" \
    "${session_name}" \
    "${expected_squeezes}" \
    "${REPO_ROOT}" \
    "${APP_DOMAIN}" \
    "${cable_input_json}" \
    "${active_raw_path}" \
    "${raw_growth_start_size}" \
    "${raw_growth_end_size}" \
    "${raw_capture_start_size}" \
    "${app_pid}" \
    "${original_app_pid}" \
    "${ting_mounted}" \
    "${firmware_profile}" \
    "${firmware_main_mode}" <<'PY'
import glob
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path

(
    meta_path,
    preflight_start_epoch,
    session_start_epoch,
    serial_device,
    serial_selection,
    session_name,
    expected_squeezes,
    repo_root,
    app_domain,
    cable_input_json,
    active_raw_path,
    raw_growth_start_size,
    raw_growth_end_size,
    raw_capture_start_size,
    app_pid,
    original_app_pid,
    ting_mounted,
    firmware_profile,
    firmware_main_mode,
) = sys.argv[1:20]
repo_root = Path(repo_root)


def command_output(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def defaults_value(key):
    return command_output(["defaults", "read", app_domain, key])


def file_details(path):
    path = Path(path)
    if not path.is_file():
        return {"path": str(path), "present": False}
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "path": str(path),
        "present": True,
        "size_bytes": path.stat().st_size,
        "sha256": digest.hexdigest(),
    }


def installed_app_details():
    info_path = Path("/Applications/Bolt.app/Contents/Info.plist")
    details = {"path": str(info_path.parent.parent), "present": info_path.is_file()}
    if not info_path.is_file():
        return details
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    details.update({
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "git_commit": info.get("GMDGitCommit"),
        "git_branch": info.get("GMDGitBranch"),
        "git_dirty": info.get("GMDGitDirty"),
        "build_date": info.get("GMDBuildDate"),
    })
    return details


trigger_keys = [
    "settings.audioActivityTriggerEnabled",
    "settings.audioTriggerStartThresholdDBFS",
    "settings.audioTriggerStopThresholdDBFS",
    "settings.audioTriggerStopHoldSeconds",
    "settings.audioTriggerPreRollSeconds",
    "settings.audioTriggerRawDumpEnabled",
    "settings.microphoneInputMode",
    "settings.performanceDiagnosticsEnabled",
]
local_files = {
    "current_profile": file_details(repo_root / "ting" / "user.py"),
    "stop_only_profile": file_details(repo_root / "ting" / "user_v12.py"),
    "main_override": file_details(repo_root / "ting" / "main_tingdisk.py"),
    "start_marker": file_details(repo_root / "ting" / "marker_start.wav"),
    "stop_marker": file_details(repo_root / "ting" / "marker_stop.wav"),
}
deployed_files = None
if ting_mounted == "1":
    deployed_files = {
        "user": file_details("/Volumes/TINGDISK/user.py"),
        "main": file_details("/Volumes/TINGDISK/main.py"),
        "start_marker": file_details("/Volumes/TINGDISK/marker_start.wav"),
        "stop_marker": file_details("/Volumes/TINGDISK/marker_stop.wav"),
        "info_uf2": file_details("/Volumes/TINGDISK/INFO_UF2.TXT"),
        "current_uf2": file_details("/Volumes/TINGDISK/CURRENT.UF2"),
    }

settings = {key: defaults_value(key) for key in trigger_keys}
meta = {
    "session_start_epoch": float(session_start_epoch),
    "preflight_start_epoch": float(preflight_start_epoch),
    "serial_device": serial_device,
    "session_name": session_name,
    "expected_squeezes": int(expected_squeezes),
    "effective_settings": settings,
    "preflight": {
        "expected_squeeze_count": {"result": "pass", "value": int(expected_squeezes)},
        "serial": {
            "result": "pass",
            "selection": serial_selection,
            "selected": serial_device,
            "candidates": sorted(glob.glob("/dev/cu.usbmodem*")),
        },
        "required_settings": {"result": "pass", "values": settings},
        "repository": {
            "result": "pass",
            "clean": True,
            "commit": command_output(["git", "-C", str(repo_root), "rev-parse", "HEAD"]),
        },
        "installed_app": {
            "result": "pass",
            "original_pid": int(original_app_pid),
            "session_pid": int(app_pid),
            "restarted_for_session_owned_wav": True,
        },
        "cable_creation_input": {"result": "pass", "device": json.loads(cable_input_json)},
        "firmware": {
            "result": "pass",
            "tingdisk_mounted": ting_mounted == "1",
            "matched_profile": firmware_profile,
            "main_mode": firmware_main_mode,
        },
        "raw_wav": {
            "result": "pass",
            "path": active_raw_path,
            "growth_start_size_bytes": int(raw_growth_start_size),
            "growth_end_size_bytes": int(raw_growth_end_size),
            "capture_start_size_bytes": int(raw_capture_start_size),
        },
    },
    "provenance": {
        "repo_commit": command_output(["git", "-C", str(repo_root), "rev-parse", "HEAD"]),
        "repo_dirty": command_output(["git", "-C", str(repo_root), "status", "--porcelain"]) not in (None, ""),
        "installed_app": installed_app_details(),
        "local_firmware": local_files,
        "deployed_firmware": deployed_files,
        "app_domain": app_domain,
    },
    "active_raw_wav": active_raw_path,
    "status": "recording",
}
with open(meta_path, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

setup_failure_message="could not configure Ting serial telemetry at 115200 baud"
if ! stty -f "${serial_device}" 115200 raw -echo; then
    echo "preflight failed: ${setup_failure_message}: ${serial_device}" >&2
    exit 1
fi

python3 - "${serial_device}" "${session_dir}/serial.log" <<'PY' &
import sys
import time

device_path, output_path = sys.argv[1:3]


def stamp():
    return "{:.9f}".format(time.time())


def write_line(output, payload):
    output.write("{} {}\n".format(stamp(), payload))
    output.flush()


with open(output_path, "a", encoding="utf-8", buffering=1) as output:
    try:
        with open(device_path, "rb", buffering=0) as device:
            while True:
                try:
                    line = device.readline()
                except OSError as exc:
                    write_line(output, "SERIAL_READ_ERROR {}".format(exc))
                    raise SystemExit(1)
                if not line:
                    write_line(output, "SERIAL_EOF device disappeared")
                    raise SystemExit(1)
                text = line.decode("utf-8", errors="replace").strip()
                if text:
                    write_line(output, text)
    except OSError as exc:
        write_line(output, "SERIAL_OPEN_ERROR {}".format(exc))
        raise SystemExit(1)
PY
serial_pid="$!"

sleep 0.2
if ! kill -0 "${serial_pid}" 2>/dev/null; then
    setup_failure_message="serial telemetry reader could not stay open on ${serial_device}"
    wait "${serial_pid}" 2>/dev/null || true
    echo "preflight failed: ${setup_failure_message}" >&2
    exit 1
fi

setup_active=0
trap - EXIT INT TERM

finalized=0
completion_reason="unexpected_exit"
finish() {
    local original_status="${1:-0}"
    local integrity_status=0
    local analyzer_status=0
    local relaunch_status=0
    local app_stop_status=0
    local log_status=0
    local final_status=0
    local session_end_epoch
    local duration_seconds
    local log_start
    local raw_final_size=0
    local relaunched_app_pid=""

    trap '' INT TERM
    trap - EXIT
    set +e
    if [[ "${finalized}" == "1" ]]; then
        exit "${original_status}"
    fi
    finalized=1

    if [[ -n "${serial_pid:-}" ]] && kill -0 "${serial_pid}" 2>/dev/null; then
        kill "${serial_pid}" 2>/dev/null
        wait "${serial_pid}" 2>/dev/null
    fi

    session_end_epoch="$(epoch_now)"
    duration_seconds="$(python3 - "${session_start_epoch}" "${session_end_epoch}" <<'PY'
import sys
print("{:.3f}".format(max(0.0, float(sys.argv[2]) - float(sys.argv[1]))))
PY
)"

    # Closing the session app bounds the WAV before it is copied. The same
    # installed app is relaunched below, with all preference values untouched.
    if ! stop_installed_app; then
        app_stop_status=1
        echo "error: installed app did not stop cleanly; raw WAV may be unbounded" >&2
    fi
    if [[ -f "${active_raw_path}" ]]; then
        raw_final_size="$(file_size "${active_raw_path}")"
    fi

    sleep 0.5
    log_start="$(local_log_time "${preflight_start_epoch}")"
    /usr/bin/log show \
        --start "${log_start}" \
        --predicate 'subsystem == "com.huntae.groq-menubar-dictate"' \
        --style ndjson \
        > "${session_dir}/app-log.ndjson"
    log_status="$?"
    if [[ "${log_status}" != "0" ]]; then
        echo "error: could not collect app OSLog records" >&2
    fi

    python3 - \
        "${session_dir}/app-log.ndjson" \
        "${preflight_start_epoch}" \
        "${session_end_epoch}" \
        "${active_raw_path}" > "${raw_paths_file}" <<'PY'
import json
import re
import sys
from datetime import datetime

log_path, start_epoch, end_epoch, active_path = sys.argv[1:5]
start_epoch = float(start_epoch)
end_epoch = float(end_epoch)
prefix = "ting raw dump path="


def parse_timestamp(value):
    if not value:
        return None
    text = str(value).strip()
    text = re.sub(r"(\.\d{6})\d+([+-]\d{2}:?\d{2})$", r"\1\2", text)
    for fmt in ("%Y-%m-%d %H:%M:%S.%f%z", "%Y-%m-%d %H:%M:%S%z"):
        try:
            return datetime.strptime(text, fmt).timestamp()
        except ValueError:
            pass
    return None


seen = set()
if active_path:
    seen.add(active_path)
    print(active_path)
try:
    handle = open(log_path, "r", encoding="utf-8", errors="replace")
except OSError:
    raise SystemExit(0)
with handle:
    for raw in handle:
        try:
            record = json.loads(raw)
        except ValueError:
            continue
        message = str(record.get("eventMessage") or record.get("message") or "")
        if prefix not in message:
            continue
        timestamp = parse_timestamp(record.get("timestamp") or record.get("date"))
        if timestamp is not None and not (start_epoch - 0.5 <= timestamp <= end_epoch + 2.0):
            continue
        path = message.split(prefix, 1)[1].strip().split()[0]
        if path and path not in seen:
            seen.add(path)
            print(path)
PY

    while IFS= read -r raw_path; do
        [[ -z "${raw_path}" ]] && continue
        if [[ ! -f "${raw_path}" ]]; then
            echo "error: raw dump WAV missing: ${raw_path}" >&2
            continue
        fi
        dest="${session_dir}/$(basename "${raw_path}")"
        if [[ -e "${dest}" && "${dest}" != "${raw_path}" ]]; then
            stem="${dest%.*}"
            ext=""
            if [[ "${dest}" == *.* ]]; then
                ext=".${dest##*.}"
                stem="${dest%.*}"
            fi
            counter=2
            while [[ -e "${stem}-${counter}${ext}" ]]; do
                counter=$((counter + 1))
            done
            dest="${stem}-${counter}${ext}"
        fi
        if cp -p "${raw_path}" "${dest}"; then
            printf '%s\t%s\n' "${raw_path}" "${dest}" >> "${copied_paths_file}"
        else
            echo "error: failed to copy raw dump WAV: ${raw_path}" >&2
        fi
    done < "${raw_paths_file}"

    python3 - \
        "${meta_path}" \
        "${session_start_epoch}" \
        "${session_end_epoch}" \
        "${duration_seconds}" \
        "${completion_reason}" \
        "${raw_paths_file}" \
        "${copied_paths_file}" \
        "${session_dir}/app-log.ndjson" \
        "${active_raw_path}" \
        "${raw_capture_start_size}" \
        "${raw_final_size}" \
        "${app_stop_status}" \
        "${log_status}" <<'PY'
import json
import re
import sys
import wave
from datetime import datetime
from pathlib import Path

(
    meta_path,
    start_epoch,
    end_epoch,
    duration_seconds,
    completion_reason,
    raw_paths_file,
    copied_paths_file,
    app_log_path,
    active_raw_path,
    capture_start_size,
    raw_final_size,
    app_stop_status,
    log_status,
) = sys.argv[1:14]
start_epoch = float(start_epoch)
end_epoch = float(end_epoch)
capture_start_size = int(capture_start_size)
raw_final_size = int(raw_final_size)
errors = []


def parse_timestamp(value):
    if not value:
        return None
    text = str(value).strip()
    text = re.sub(r"(\.\d{6})\d+([+-]\d{2}:?\d{2})$", r"\1\2", text)
    for fmt in ("%Y-%m-%d %H:%M:%S.%f%z", "%Y-%m-%d %H:%M:%S%z"):
        try:
            return datetime.strptime(text, fmt).timestamp()
        except ValueError:
            pass
    return None


with open(raw_paths_file, "r", encoding="utf-8") as handle:
    raw_paths = [line.strip() for line in handle if line.strip()]
copy_map = {}
with open(copied_paths_file, "r", encoding="utf-8") as handle:
    for line in handle:
        fields = line.rstrip("\n").split("\t", 1)
        if len(fields) == 2:
            copy_map[fields[0]] = fields[1]

if int(app_stop_status) != 0:
    errors.append("installed app did not stop cleanly before artifact copy")
if int(log_status) != 0:
    errors.append("app OSLog collection failed")
if active_raw_path not in raw_paths:
    errors.append("active raw WAV is absent from the source path manifest")
if active_raw_path not in copy_map:
    errors.append("active raw WAV was not copied into the session")
if raw_final_size <= capture_start_size:
    errors.append("active raw WAV did not grow during the capture interval")

copied_path = Path(copy_map.get(active_raw_path, ""))
wav_details = {
    "source_path": active_raw_path,
    "copied_path": str(copied_path) if str(copied_path) != "." else None,
    "capture_start_size_bytes": capture_start_size,
    "final_size_bytes": raw_final_size,
}
if not copied_path.is_file():
    errors.append("copied active raw WAV is missing")
else:
    copied_size = copied_path.stat().st_size
    wav_details["copied_size_bytes"] = copied_size
    if copied_size != raw_final_size:
        errors.append("copied active raw WAV size does not match the closed source")
    try:
        with wave.open(str(copied_path), "rb") as wav_file:
            channels = wav_file.getnchannels()
            sample_width = wav_file.getsampwidth()
            sample_rate = wav_file.getframerate()
            frame_count = wav_file.getnframes()
        header_sizes_recovered = False
        bytes_per_frame = channels * sample_width
        if frame_count == 0 and copied_size > 44 and bytes_per_frame > 0:
            # Process termination has historically left raw dumps with zero
            # RIFF/data lengths even though all PCM bytes are present. Mirror
            # the analyzer's safe payload fallback for coverage validation.
            payload_size = copied_size - 44
            frame_count = payload_size // bytes_per_frame
            header_sizes_recovered = True
        duration = frame_count / float(sample_rate)
        wav_details.update({
            "channels": channels,
            "sample_width_bytes": sample_width,
            "sample_rate": sample_rate,
            "frame_count": frame_count,
            "duration_seconds": duration,
            "header_sizes_recovered_from_payload": header_sizes_recovered,
        })
        if (channels, sample_width, sample_rate) != (1, 2, 16000):
            errors.append("active raw WAV is not 16 kHz mono PCM16")
    except (OSError, EOFError, wave.Error) as exc:
        duration = None
        errors.append("copied active raw WAV is unreadable: {}".format(exc))

anchors = []
prefix = "ting raw dump path="
try:
    with open(app_log_path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            message = str(record.get("eventMessage") or record.get("message") or "")
            if prefix not in message:
                continue
            source = message.split(prefix, 1)[1].strip().split()[0]
            if source != active_raw_path:
                continue
            timestamp = parse_timestamp(record.get("timestamp") or record.get("date"))
            if timestamp is not None:
                anchors.append(timestamp)
except OSError as exc:
    errors.append("cannot read app OSLog artifact: {}".format(exc))

if not anchors:
    errors.append("active raw WAV sample-zero OSLog anchor is missing")
elif duration is not None:
    anchor = min(anchors)
    coverage_end = anchor + duration
    wav_details["sample_zero_epoch"] = anchor
    wav_details["coverage_end_epoch"] = coverage_end
    wav_details["capture_start_covered"] = anchor <= start_epoch + 0.25
    wav_details["capture_end_covered"] = coverage_end >= end_epoch - 0.25
    if anchor > start_epoch + 0.25:
        errors.append("active raw WAV starts after the capture interval")
    if coverage_end < end_epoch - 0.25:
        errors.append("active raw WAV ends before the capture interval")

try:
    with open(meta_path, "r", encoding="utf-8") as handle:
        meta = json.load(handle)
except (OSError, ValueError):
    meta = {}
meta.update({
    "session_start_epoch": start_epoch,
    "session_end_epoch": end_epoch,
    "duration_seconds": float(duration_seconds),
    "completion_reason": completion_reason,
    "raw_dump_source_paths": raw_paths,
    "copied_wavs": list(copy_map.values()),
    "raw_dump_copy_map": copy_map,
    "artifact_integrity": {
        "result": "pass" if not errors else "fail",
        "errors": errors,
        "active_wav": wav_details,
    },
    "status": "captured" if not errors else "artifact_failed",
})
with open(meta_path, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
    handle.write("\n")
raise SystemExit(0 if not errors else 3)
PY
    integrity_status="$?"

    if ! relaunched_app_pid="$(launch_installed_app)"; then
        relaunch_status=1
        echo "error: failed to relaunch the installed app after capture" >&2
    fi
    final_trigger="$(setting_value "${TRIGGER_KEY}")"
    final_raw_dump="$(setting_value "${RAW_DUMP_KEY}")"
    final_diagnostics="$(setting_value "${DIAGNOSTICS_KEY}")"
    if [[ "${final_trigger}" != "${trigger_enabled}" || \
          "${final_raw_dump}" != "${raw_dump_enabled}" || \
          "${final_diagnostics}" != "${diagnostics_enabled}" ]]; then
        relaunch_status=1
        echo "error: required preferences changed during capture" >&2
    fi

    python3 "${SCRIPT_DIR}/analyze.py" "${session_dir}"
    analyzer_status="$?"

    if [[ "${completion_reason}" == "serial_reader_exited" || \
          "${completion_reason}" == "unexpected_exit" || \
          "${completion_reason}" == "termination_signal" ]]; then
        original_status=1
    else
        original_status=0
    fi
    if [[ "${integrity_status}" != "0" || "${analyzer_status}" != "0" || \
          "${relaunch_status}" != "0" || "${original_status}" != "0" ]]; then
        final_status=1
    fi

    python3 - \
        "${meta_path}" \
        "${analyzer_status}" \
        "${integrity_status}" \
        "${relaunch_status}" \
        "${relaunched_app_pid}" \
        "${final_status}" <<'PY'
import json
import sys

meta_path, analyzer_status, integrity_status, relaunch_status, app_pid, final_status = sys.argv[1:7]
with open(meta_path, "r", encoding="utf-8") as handle:
    meta = json.load(handle)
meta["analysis_exit_status"] = int(analyzer_status)
meta["artifact_integrity_exit_status"] = int(integrity_status)
meta["post_capture_app"] = {
    "result": "pass" if int(relaunch_status) == 0 else "fail",
    "pid": int(app_pid) if app_pid else None,
    "required_preferences_preserved": int(relaunch_status) == 0,
}
meta["status"] = "finished" if int(final_status) == 0 else "failed"
with open(meta_path, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
    echo "session: ${session_dir}"
    exit "${final_status}"
}

trap 'completion_reason="user_interrupt"; finish 0' INT
trap 'completion_reason="termination_signal"; finish 143' TERM
trap 'finish $?' EXIT

echo "session: ${session_dir}"
echo "serial: ${serial_device} (${serial_selection})"
echo "expected squeezes: ${expected_squeezes}"
echo "app build: ${installed_build} commit ${repo_commit}"
echo "raw WAV: ${active_raw_path} (session-owned and growing)"
echo "firmware: ${firmware_profile}, main: ${firmware_main_mode}, markers: verified"
echo "recording — do exactly ${expected_squeezes} test squeezes; after the last capture finalizes, press Ctrl-C"

while kill -0 "${serial_pid}" 2>/dev/null; do
    sleep 1
done
completion_reason="serial_reader_exited"
echo "capture failed: serial telemetry reader exited unexpectedly" >&2
exit 1
