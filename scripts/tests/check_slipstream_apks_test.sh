#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/../check_slipstream_apks.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-slipstream-apks.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 -I - "$WORK_DIR" <<'PY'
from pathlib import Path
import sys
import warnings
from zipfile import ZipFile

root = Path(sys.argv[1])
abis = ("armeabi-v7a", "arm64-v8a", "x86_64")
scenarios = (
    "missing-entry", "duplicate-entry", "wrong-abi", "wrong-abi-only",
    "missing-apk", "malformed-archive", "corrupt-archive",
)


def write_apks(directory, scenario="valid", target=None):
    directory.mkdir(parents=True)
    for abi in abis:
        apk = directory / f"app-{abi}-release.apk"
        if abi == target and scenario == "missing-apk":
            continue
        expected = f"lib/{abi}/libslipstream_client.so"
        with ZipFile(apk, "w") as archive:
            archive.writestr(f"lib/{abi}/libflutter.so", b"ordinary native library")
            archive.writestr(f"lib/{abi}/libslipstream_client.so.debug", b"debug fixture")
            archive.writestr(f"lib/{abi}/not_libslipstream_client.so", b"unrelated fixture")
            archive.writestr("assets/libslipstream_client.so", b"asset fixture")
            if abi != target or scenario not in ("missing-entry", "wrong-abi-only"):
                archive.writestr(expected, b"slipstream fixture")
            if abi == target and scenario == "duplicate-entry":
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(expected, b"duplicate fixture")
            if abi == target and scenario in ("wrong-abi", "wrong-abi-only"):
                other_abi = abis[(abis.index(abi) + 1) % len(abis)]
                archive.writestr(f"lib/{other_abi}/libslipstream_client.so", b"wrong ABI fixture")
        if abi == target and scenario == "malformed-archive":
            apk.write_bytes(b"not a ZIP archive\n")
        if abi == target and scenario == "corrupt-archive":
            data = bytearray(apk.read_bytes())
            data[data.index(b"slipstream fixture")] ^= 1
            apk.write_bytes(data)


write_apks(root / "valid APKs")
for scenario in scenarios:
    for target in abis:
        write_apks(root / scenario / target, scenario, target)
PY

"$CHECKER" "$WORK_DIR/valid APKs"

expect_failure() {
    local scenario="$1" abi="$2" diagnostic="$3"
    if "$CHECKER" "$WORK_DIR/$scenario/$abi" > "$WORK_DIR/output" 2>&1; then
        echo "FAIL: checker accepted $scenario for $abi" >&2
        exit 1
    fi
    if ! grep -Fq -- "$diagnostic" "$WORK_DIR/output"; then
        cat "$WORK_DIR/output" >&2
        echo "FAIL: unexpected diagnostic for $scenario ($abi)" >&2
        exit 1
    fi
    echo "ok: rejected $scenario for $abi"
}

for abi in armeabi-v7a arm64-v8a x86_64; do
    expect_failure missing-entry "$abi" "exactly one lib/$abi/libslipstream_client.so entry (found 0)"
    expect_failure duplicate-entry "$abi" "exactly one lib/$abi/libslipstream_client.so entry (found 2)"
    expect_failure wrong-abi "$abi" "unexpected Slipstream entry"
    expect_failure wrong-abi-only "$abi" "unexpected Slipstream entry"
    expect_failure missing-apk "$abi" "app-$abi-release.apk does not exist"
    expect_failure malformed-archive "$abi" "app-$abi-release.apk is not a valid ZIP archive"
    expect_failure corrupt-archive "$abi" "app-$abi-release.apk is not a valid ZIP archive"
done

echo "All Slipstream APK checker fixtures passed"
