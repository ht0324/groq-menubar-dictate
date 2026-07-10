#!/bin/bash
# Deploy a Ting firmware profile and its marker assets to TINGDISK.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
    cat <<'EOF'
Usage: ./deploy.sh [--profile current|stop-only] [--main]

  --profile current    Deploy user.py (v13 start+stop markers; default).
  --profile stop-only  Deploy user_v12.py as user.py (Mac-side start detection).
  --main               Also deploy main_tingdisk.py as main.py; requires a power cycle.
  -h, --help           Show this help.

Without --main, ejecting TINGDISK hot-reloads the selected user profile.
EOF
}

profile="current"
deploy_main=0
while (( $# > 0 )); do
    case "$1" in
        --profile)
            if (( $# < 2 )) || [[ "$2" == -* ]]; then
                echo "--profile requires current or stop-only" >&2
                usage >&2
                exit 2
            fi
            profile="$2"
            shift 2
            ;;
        --main)
            deploy_main=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${profile}" in
    current)
        profile_source="user.py"
        ;;
    stop-only)
        profile_source="user_v12.py"
        ;;
    *)
        echo "invalid profile: ${profile} (expected current or stop-only)" >&2
        usage >&2
        exit 2
        ;;
esac

if [ ! -d /Volumes/TINGDISK ]; then
    echo "TINGDISK not mounted — replug the ting's USB-C cable" >&2
    exit 1
fi

cp "${profile_source}" /Volumes/TINGDISK/user.py
cp marker_start.wav marker_stop.wav /Volumes/TINGDISK/
if (( deploy_main )); then
    cp main_tingdisk.py /Volumes/TINGDISK/main.py
    echo "Profile '${profile}', main.py, and marker assets copied. Power-cycle the ting to load them."
    exit 0
fi

# Eject signals the device to re-read the disk and re-exec user.py.
diskutil eject TINGDISK >/dev/null
echo "Profile '${profile}' and marker assets deployed; TINGDISK ejected — listen for the factory confirmation beep (sample 0)."
echo "Replug USB-C when you next want to edit files."
