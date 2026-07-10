#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_ROOT="${SCRIPT_DIR}/sessions"
APP_DOMAIN="com.huntae.groq-menubar-dictate"
RAW_DUMP_KEY="settings.audioTriggerRawDumpEnabled"

session_name="${1:-}"
safe_name=""
if [[ -n "${session_name}" ]]; then
    safe_name="$(printf '%s' "${session_name}" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//')"
fi

serial_devices=(/dev/cu.usbmodem*)
if [[ ! -e "${serial_devices[0]}" ]]; then
    echo "no /dev/cu.usbmodem* device found; replug the ting USB-C cable" >&2
    exit 1
fi
serial_device="${serial_devices[0]}"

raw_dump_enabled="$(defaults read "${APP_DOMAIN}" "${RAW_DUMP_KEY}" 2>/dev/null || true)"
if [[ "${raw_dump_enabled}" != "1" ]]; then
    echo "defaults write ${APP_DOMAIN} ${RAW_DUMP_KEY} -bool true"
    echo "then restart the app"
    exit 1
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
mkdir -p "${session_dir}"

session_start_epoch="$(python3 - <<'PY'
import time
print("{:.9f}".format(time.time()))
PY
)"
meta_path="${session_dir}/meta.json"
raw_paths_file="${session_dir}/.raw-dump-paths.txt"
copied_paths_file="${session_dir}/.copied-wavs.txt"
: > "${raw_paths_file}"
: > "${copied_paths_file}"
: > "${session_dir}/serial.log"

python3 - "${meta_path}" "${session_start_epoch}" "${serial_device}" "${session_name}" <<'PY'
import json
import sys

meta_path, start_epoch, serial_device, session_name = sys.argv[1:5]
meta = {
    "session_start_epoch": float(start_epoch),
    "serial_device": serial_device,
    "session_name": session_name,
    "status": "recording",
}
with open(meta_path, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

stty -f "${serial_device}" 115200 raw -echo

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
                    raise SystemExit(0)
                if not line:
                    write_line(output, "SERIAL_EOF device disappeared")
                    raise SystemExit(0)
                text = line.decode("utf-8", errors="replace").strip()
                if text:
                    write_line(output, text)
    except OSError as exc:
        write_line(output, "SERIAL_OPEN_ERROR {}".format(exc))
        raise SystemExit(0)
PY
serial_pid="$!"

finalized=0
finish() {
    local status="$?"
    trap - INT TERM EXIT
    set +e
    if [[ "${finalized}" == "1" ]]; then
        exit "${status}"
    fi
    finalized=1

    if [[ -n "${serial_pid:-}" ]] && kill -0 "${serial_pid}" 2>/dev/null; then
        kill "${serial_pid}" 2>/dev/null
        wait "${serial_pid}" 2>/dev/null
    fi

    session_end_epoch="$(python3 - <<'PY'
import time
print("{:.9f}".format(time.time()))
PY
)"
    duration_seconds="$(python3 - "${session_start_epoch}" "${session_end_epoch}" <<'PY'
import sys
start = float(sys.argv[1])
end = float(sys.argv[2])
print("{:.3f}".format(max(0.0, end - start)))
PY
)"
    log_start="$(python3 - "${session_start_epoch}" <<'PY'
from datetime import datetime
import sys
print(datetime.fromtimestamp(float(sys.argv[1])).strftime("%Y-%m-%d %H:%M:%S"))
PY
)"

    /usr/bin/log show \
        --start "${log_start}" \
        --predicate 'subsystem == "com.huntae.groq-menubar-dictate"' \
        --style ndjson \
        > "${session_dir}/app-log.ndjson"

    python3 - "${session_dir}/app-log.ndjson" "${session_start_epoch}" "${session_end_epoch}" > "${raw_paths_file}" <<'PY'
import json
import re
import sys
from datetime import datetime

log_path, start_epoch, end_epoch = sys.argv[1:4]
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
with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue
        message = str(record.get("eventMessage") or record.get("message") or "")
        if prefix not in message:
            continue
        timestamp = parse_timestamp(record.get("timestamp") or record.get("date"))
        if timestamp is not None and not (start_epoch - 0.5 <= timestamp <= end_epoch + 0.5):
            continue
        path = message.split(prefix, 1)[1].strip().split()[0]
        if path and path not in seen:
            seen.add(path)
            print(path)
PY

    while IFS= read -r raw_path; do
        [[ -z "${raw_path}" ]] && continue
        if [[ -f "${raw_path}" ]]; then
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
            cp -p "${raw_path}" "${dest}"
            printf '%s\n' "${dest}" >> "${copied_paths_file}"
        else
            echo "warning: raw dump WAV missing: ${raw_path}" >&2
        fi
    done < "${raw_paths_file}"

    python3 - \
        "${meta_path}" \
        "${session_start_epoch}" \
        "${session_end_epoch}" \
        "${duration_seconds}" \
        "${serial_device}" \
        "${session_name}" \
        "${raw_paths_file}" \
        "${copied_paths_file}" <<'PY'
import json
import sys

(
    meta_path,
    start_epoch,
    end_epoch,
    duration_seconds,
    serial_device,
    session_name,
    raw_paths_file,
    copied_paths_file,
) = sys.argv[1:9]

with open(raw_paths_file, "r", encoding="utf-8") as handle:
    raw_paths = [line.strip() for line in handle if line.strip()]
with open(copied_paths_file, "r", encoding="utf-8") as handle:
    copied_wavs = [line.strip() for line in handle if line.strip()]

meta = {
    "session_start_epoch": float(start_epoch),
    "session_end_epoch": float(end_epoch),
    "duration_seconds": float(duration_seconds),
    "serial_device": serial_device,
    "session_name": session_name,
    "raw_dump_source_paths": raw_paths,
    "copied_wavs": copied_wavs,
    "status": "finished",
}
with open(meta_path, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

    python3 "${SCRIPT_DIR}/analyze.py" "${session_dir}"
    analyze_status="$?"
    exit "${analyze_status}"
}

trap finish INT TERM EXIT

echo "session: ${session_dir}"
echo "serial: ${serial_device}"
echo "recording — do your test squeezes, Ctrl-C to finish"

while kill -0 "${serial_pid}" 2>/dev/null; do
    sleep 1
done
