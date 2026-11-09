#!/bin/bash

# Usage: scripts/check_slipstream_apks.sh APK_DIR
# Check ZIP contents of the three release splits, including duplicate entries.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 APK_DIR" >&2
    exit 2
fi

apk_dir="$(cd "$1" && pwd)"

for abi in armeabi-v7a arm64-v8a x86_64; do
    apk="$apk_dir/app-$abi-release.apk"
    if [ ! -f "$apk" ]; then
        echo "FAIL: $apk does not exist" >&2
        exit 1
    fi
    if ! unzip -tqq "$apk" > /dev/null 2>&1; then
        echo "FAIL: $apk is not a valid ZIP archive" >&2
        exit 1
    fi
    if ! entries="$(unzip -Z1 "$apk")"; then
        echo "FAIL: cannot list ZIP entries in $apk" >&2
        exit 1
    fi

    expected="lib/$abi/libslipstream_client.so"
    count=0
    while IFS= read -r entry; do
        case "$entry" in
            "$expected")
                count=$((count + 1))
                ;;
            lib/*/libslipstream_client.so)
                echo "FAIL: $apk contains unexpected Slipstream entry: $entry" >&2
                exit 1
                ;;
        esac
    done <<< "$entries"
    if [ "$count" -ne 1 ]; then
        echo "FAIL: $apk must contain exactly one $expected entry (found $count)" >&2
        exit 1
    fi
    echo "ok: $apk contains exactly one $expected entry"
done
