#!/bin/bash

# Builds the DNSTT Go library for Android (android/app/libs/dnstt.aar) from go_src/.
#
# Requirements: Go (the toolchain pinned in go_src/go.mod is downloaded if needed),
# a JDK (gomobile compiles Java classes), the Android SDK with a platform and the NDK.
#
# Environment:
#   ANDROID_HOME       Android SDK (default: ANDROID_SDK_ROOT, then sdk.dir from
#                      android/local.properties)
#   NDK_VERSION        default: the version Flutter uses; taken from
#                      $ANDROID_HOME/ndk/$NDK_VERSION
#   ANDROID_NDK_HOME   used only if that directory is missing and this NDK has
#                      exactly NDK_VERSION (another NDK gives different binaries)
#   TARGETS            gomobile targets (default: the ABIs Flutter builds)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT="$PROJECT_DIR/android/app/libs/dnstt.aar"

NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
TARGETS="${TARGETS:-android/arm,android/arm64,android/amd64}"

# The source copy is built from a fixed directory: gomobile records its path in the
# Go build info (-trimpath does not remove it), so it must not be a user path and
# must not change between builds.
BUILD_DIR=/tmp/dnstt_build

if ! command -v go > /dev/null; then
    echo "Error: Go is not installed" >&2
    exit 1
fi
if ! command -v javac > /dev/null; then
    echo "Error: javac not found; gomobile needs a JDK" >&2
    exit 1
fi

if [ -z "${ANDROID_HOME:-}" ]; then
    if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
        ANDROID_HOME="$ANDROID_SDK_ROOT"
    elif [ -f "$PROJECT_DIR/android/local.properties" ]; then
        ANDROID_HOME="$(sed -n 's/^sdk\.dir=//p' "$PROJECT_DIR/android/local.properties")"
    fi
fi
if [ -z "${ANDROID_HOME:-}" ] || [ ! -d "$ANDROID_HOME" ]; then
    echo "Error: Android SDK not found; set ANDROID_HOME" >&2
    exit 1
fi
export ANDROID_HOME

ndk_revision() {
    sed -n 's/^Pkg\.Revision *= *//p' "$1/source.properties" 2>/dev/null
}

# The NDK version is part of the build: another NDK gives different binaries. A global
# ANDROID_NDK_HOME (CI runners set one) is used only if it has the pinned version.
if [ -f "$ANDROID_HOME/ndk/$NDK_VERSION/source.properties" ]; then
    ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$NDK_VERSION"
elif [ -n "${ANDROID_NDK_HOME:-}" ] && [ "$(ndk_revision "$ANDROID_NDK_HOME")" = "$NDK_VERSION" ]; then
    :
else
    echo "Error: NDK $NDK_VERSION not found in $ANDROID_HOME/ndk" >&2
    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        echo "ANDROID_NDK_HOME has NDK $(ndk_revision "$ANDROID_NDK_HOME"); set NDK_VERSION to build with it" >&2
    fi
    echo "Install it with: sdkmanager \"ndk;$NDK_VERSION\"" >&2
    exit 1
fi
export ANDROID_NDK_HOME

echo "=== Building dnstt.aar ==="
echo "Targets: $TARGETS"
echo "NDK: $(ndk_revision "$ANDROID_NDK_HOME") ($ANDROID_NDK_HOME)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp -R "$PROJECT_DIR/go_src/." "$BUILD_DIR/"
rm -f "$BUILD_DIR"/*.aar "$BUILD_DIR"/*.jar "$BUILD_DIR"/*.dylib "$BUILD_DIR"/*.so "$BUILD_DIR"/*.dll "$BUILD_DIR"/*.h

TOOLS_DIR="$(mktemp -d)"
trap 'rm -rf "$TOOLS_DIR"' EXIT

cd "$BUILD_DIR"

# Use the toolchain pinned in go.mod for every go command, including the ones gomobile
# runs in its own work directory (otherwise an older local go picks another release)
GOROOT_PINNED="$(go env GOROOT)"
export PATH="$GOROOT_PINNED/bin:$PATH"
export GOTOOLCHAIN=local
echo "Go: $(go version)"

# gomobile and gobind at the version pinned in go.mod (golang.org/x/mobile)
GOBIN="$TOOLS_DIR" go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
export PATH="$TOOLS_DIR:$PATH"

# -trimpath removes file system paths, -s -w strip symbols and debug info.
# -buildid= drops the Go build ID (and the GNU build ID derived from it): it hashes
# the NDK compiler's path, so the same sources gave different files on other machines.
GOFLAGS="-trimpath" gomobile bind \
    -ldflags="-s -w -buildid=" \
    -androidapi 21 \
    -target="$TARGETS" \
    -o "$BUILD_DIR/dnstt.aar" \
    ./mobile

mkdir -p "$(dirname "$OUTPUT")"
cp "$BUILD_DIR/dnstt.aar" "$OUTPUT"
echo "Wrote $OUTPUT"

"$SCRIPT_DIR/check_binary_paths.sh" "$OUTPUT"
