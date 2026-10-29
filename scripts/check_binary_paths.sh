#!/bin/bash

# Checks binaries for file system paths of the build machine (see AGENTS.md).
#
# Usage: scripts/check_binary_paths.sh [--allow REGEX]... FILE...
#
# Archives (.aar, .apk, .jar, .zip) are unpacked and every native library
# inside them (.so, .dylib, .dll) is checked. Other files are checked as is.
# Exits with 1 and prints the offending strings if any file contains a path.
#
# --allow REGEX accepts strings matching REGEX (extended regex) and lists them
# as notes. Use it only for known neutral paths, such as the CI checkout.

set -e

PATTERN='/home/|/Users/|/root/|C:\\Users'
ALLOW=''

while [ $# -gt 0 ]; do
    case "$1" in
        --allow)
            ALLOW="${ALLOW:+$ALLOW|}$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "Usage: $0 [--allow REGEX]... FILE..." >&2
    exit 2
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failed=0

# check_file NAME PATH: NAME is what gets reported, PATH is what gets read
check_file() {
    local matches allowed=''
    matches="$(strings -a "$2" | LC_ALL=C grep -E "$PATTERN" | sort -u || true)"
    if [ -n "$ALLOW" ] && [ -n "$matches" ]; then
        allowed="$(echo "$matches" | LC_ALL=C grep -E "$ALLOW" || true)"
        matches="$(echo "$matches" | LC_ALL=C grep -v -E "$ALLOW" || true)"
    fi
    if [ -n "$allowed" ]; then
        echo "note: $1 contains allowed paths:"
        echo "$allowed" | head -20 | sed 's/^/    /'
    fi
    if [ -n "$matches" ]; then
        echo "FAIL: $1 contains machine paths:"
        echo "$matches" | head -20 | sed 's/^/    /'
        failed=1
    else
        echo "ok:   $1"
    fi
}

for file in "$@"; do
    if [ ! -f "$file" ]; then
        echo "FAIL: $file does not exist"
        failed=1
        continue
    fi
    case "$file" in
        *.aar|*.apk|*.jar|*.zip)
            dir="$WORK_DIR/$(basename "$file")"
            mkdir -p "$dir"
            unzip -q -o "$file" -d "$dir"
            libs="$(find "$dir" -type f \( -name '*.so' -o -name '*.dylib' -o -name '*.dll' \) | sort)"
            if [ -z "$libs" ]; then
                echo "ok:   $file (no native libraries)"
                continue
            fi
            while IFS= read -r lib; do
                check_file "$file!${lib#"$dir"/}" "$lib"
            done <<< "$libs"
            ;;
        *)
            check_file "$file" "$file"
            ;;
    esac
done

exit $failed
