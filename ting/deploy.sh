#!/bin/bash
# Deploy ting firmware files to TINGDISK and trigger the device-side hot reload.
# Usage: ./deploy.sh            (deploys user.py only — hot reload, no reboot)
#        ./deploy.sh --main     (also deploys main.py — needs a power cycle)
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d /Volumes/TINGDISK ]; then
    echo "TINGDISK not mounted — replug the ting's USB-C cable" >&2
    exit 1
fi

cp user.py /Volumes/TINGDISK/user.py
if [ "${1:-}" = "--main" ]; then
    cp main_tingdisk.py /Volumes/TINGDISK/main.py
    echo "main.py + user.py copied. Power-cycle the ting to load the new main.py."
    exit 0
fi

# Eject signals the device to re-read the disk and re-exec user.py.
diskutil eject TINGDISK >/dev/null
echo "user.py deployed and TINGDISK ejected — listen for the load beep (sample 2)."
echo "Replug USB-C when you next want to edit files."
