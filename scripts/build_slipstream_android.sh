#!/bin/bash

# Cross-compile the pinned Slipstream client command for Android API 21.
# Android extracts this executable from jniLibs because of its lib*.so name.
#
# Prerequisites:
#   - Rust, cargo-ndk, CMake, make, Perl and Git
#   - Rust targets: aarch64-linux-android, armv7-linux-androideabi,
#     x86_64-linux-android
#   - NDK 28.2.13676358 (ANDROID_NDK_HOME/ANDROID_NDK_ROOT, or the pinned
#     version under ANDROID_HOME/ANDROID_SDK_ROOT/sdk.dir from local.properties)
#   - git submodule update --init --recursive vendor/slipstream-rust
#
# Usage: ./scripts/build_slipstream_android.sh [path_to_slipstream_src]
# The optional path must resolve to the pinned vendor/slipstream-rust checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SLIPSTREAM_SRC="$PROJECT_DIR/vendor/slipstream-rust"
JNILIBS_DIR="$PROJECT_DIR/android/app/src/main/jniLibs"
NDK_VERSION=28.2.13676358
ANDROID_API=21
ABIS=(arm64-v8a armeabi-v7a x86_64)
TARGETS=(aarch64-linux-android armv7-linux-androideabi x86_64-linux-android)
CLANG_TARGETS=(aarch64-linux-android armv7a-linux-androideabi x86_64-linux-android)
MACHINES=(AArch64 ARM 'Advanced Micro Devices X86-64')

fail() {
    echo "Error: $*" >&2
    exit 1
}

for tool in cargo cargo-ndk rustc rustup git cmake make perl pkg-config strings grep sed sort head mktemp uname cp chmod rm rmdir cat mv; do
    command -v "$tool" > /dev/null || fail "Required tool not found: $tool"
done
test -x "$SCRIPT_DIR/check_binary_paths.sh" || fail "Binary path checker is missing"
test -n "${HOME:-}" || fail "HOME must be set for path remapping"

if [ "$#" -gt 1 ]; then
    fail "Usage: $0 [path_to_slipstream_src]"
fi
if [ "$#" -eq 1 ]; then
    requested_src="$(cd "$1" && pwd -P)" || fail "Slipstream source directory not found"
    pinned_src="$(cd "$SLIPSTREAM_SRC" && pwd -P)" || fail "Pinned Slipstream source not found"
    [ "$requested_src" = "$pinned_src" ] || fail "Use the pinned vendor/slipstream-rust source"
fi

for source_file in Cargo.toml Cargo.lock crates/slipstream-client/Cargo.toml \
    crates/slipstream-ffi/build.rs scripts/build_picoquic.sh \
    vendor/picoquic/CMakeLists.txt vendor/picoquic/picoquic/picoquic_internal.h; do
    test -s "$SLIPSTREAM_SRC/$source_file" || \
        fail "Missing source: $source_file; run git submodule update --init --recursive vendor/slipstream-rust"
done
expected_revision="$(git -C "$PROJECT_DIR" rev-parse HEAD:vendor/slipstream-rust)"
[ "$(git -C "$SLIPSTREAM_SRC" rev-parse HEAD)" = "$expected_revision" ] || \
    fail "Slipstream checkout does not match its pinned gitlink"
submodule_status="$(git -C "$PROJECT_DIR" submodule status --recursive -- vendor/slipstream-rust)"
if grep -Eq '^[-+U]' <<< "$submodule_status"; then
    fail "Slipstream child submodules are missing or do not match their pinned gitlinks"
fi
source_status="$(git -C "$SLIPSTREAM_SRC" status --porcelain --untracked-files=normal)"
[ -z "$source_status" ] || \
    fail "Slipstream source or its child submodules have local changes"

# Use the project as the working directory, not the downloaded source directory.
cd "$PROJECT_DIR"
installed_targets="$(rustup target list --installed)"
for target in "${TARGETS[@]}"; do
    grep -Fxq "$target" <<< "$installed_targets" || fail "Rust target is not installed: $target"
done

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    if [ -n "${ANDROID_NDK_ROOT:-}" ]; then
        ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
    else
        sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
        if [ -z "$sdk_dir" ] && [ -f "$PROJECT_DIR/android/local.properties" ]; then
            sdk_dir="$(sed -n 's/^sdk\.dir=//p' "$PROJECT_DIR/android/local.properties")"
        fi
        [ -n "$sdk_dir" ] || fail "Android SDK not found; set ANDROID_HOME or ANDROID_NDK_HOME"
        ANDROID_NDK_HOME="$sdk_dir/ndk/$NDK_VERSION"
    fi
fi
test -f "$ANDROID_NDK_HOME/source.properties" || fail "NDK source.properties is missing"
ndk_revision="$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$ANDROID_NDK_HOME/source.properties")"
[ "$ndk_revision" = "$NDK_VERSION" ] || fail "NDK $NDK_VERSION is required; found '$ndk_revision'"
ANDROID_NDK_HOME="$(cd "$ANDROID_NDK_HOME" && pwd -P)"
export ANDROID_NDK_HOME
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"

case "$(uname -s)" in
    Linux) ndk_host=linux-x86_64 ;;
    Darwin) ndk_host=darwin-x86_64 ;;
    *) fail "Unsupported NDK host" ;;
esac
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ndk_host/bin"
READELF="$NDK_BIN/llvm-readelf"
test -s "$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" || fail "NDK CMake toolchain is missing"
for tool in llvm-readelf llvm-ar llvm-ranlib clang clang++; do
    test -x "$NDK_BIN/$tool" || fail "NDK tool is missing: $tool"
done
for target in "${CLANG_TARGETS[@]}"; do
    test -x "$NDK_BIN/$target$ANDROID_API-clang" || fail "NDK compiler is missing: $target$ANDROID_API-clang"
done

elf_machine() {
    LC_ALL=C "$READELF" -h "$1" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p'
}

verify_executable() {
    if [ ! -f "$1" ] || [ ! -s "$1" ] || [ ! -x "$1" ]; then
        fail "Missing, empty or non-executable output: $1"
    fi
    local machine
    machine="$(elf_machine "$1")" || fail "Output is not an ELF executable: $1"
    [ "$machine" = "$2" ] || fail "Wrong ELF machine for $1: expected '$2', found '$machine'"
}

require_directory() {
    test ! -L "$1" || fail "Refusing a symlinked output directory: $1"
    if [ -e "$1" ]; then
        test -d "$1" || fail "Output directory is not a directory: $1"
    fi
}

require_directory "$JNILIBS_DIR"
require_directory "$SLIPSTREAM_SRC/target"
require_directory "$SLIPSTREAM_SRC/.picoquic-build"
for abi in "${ABIS[@]}"; do
    require_directory "$JNILIBS_DIR/$abi"
    output="$JNILIBS_DIR/$abi/libslipstream_client.so"
    test ! -L "$output" || fail "Refusing a symlinked output: $output"
    if [ -e "$output" ]; then
        test -f "$output" || fail "Output is not a regular file: $output"
    fi
done

# The FFI build script can fall back to this shared directory. Do not let an
# old desktop/Android build bypass the per-target CMake directories below.
for lib_dir in "$SLIPSTREAM_SRC/.picoquic-build" "$SLIPSTREAM_SRC/.picoquic-build/picoquic"; do
    for library in libpicoquic-core.a libpicoquic_core.a; do
        test ! -e "$lib_dir/$library" || fail "Shared picoquic artifacts found; preserve them outside .picoquic-build before building"
    done
done

# FFI skips CMake when it finds archives. Only reuse caches produced and
# verified by this script with the same source, toolchain and native settings.
builder_identity="$(git hash-object "$SCRIPT_DIR/build_slipstream_android.sh")"
lock_identity="$(git hash-object "$SLIPSTREAM_SRC/Cargo.lock")"
picoquic_revision="$(git -C "$SLIPSTREAM_SRC" rev-parse HEAD:vendor/picoquic)"
native_context="$(printf '%s\n' "$SLIPSTREAM_SRC" "$HOME" "$ANDROID_NDK_HOME" \
    "$(rustc --version)" "$(cmake --version)" "${CMAKE_GENERATOR:-}" | git hash-object --stdin)"

native_cache_metadata() {
    printf '%s\n' 'schema=1' "abi=$1" "target=$2" "api=$ANDROID_API" "ndk=$NDK_VERSION" \
        "source=$expected_revision" "picoquic=$picoquic_revision" "lock=$lock_identity" \
        "builder=$builder_identity" "context=$native_context"
}

directory_is_empty() {
    local entry
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        if [ -e "$entry" ] || [ -L "$entry" ]; then
            return 1
        fi
    done
    return 0
}

verify_native_cache() {
    local cache_dir="$1" abi="$2" machine="$3" native_file machines setting actual
    for native_file in CMakeCache.txt _deps/picotls-src/include/picotls.h \
        libpicoquic-core.a _deps/picotls-build/libpicotls-core.a \
        _deps/picotls-build/libpicotls-openssl.a _deps/picotls-build/libpicotls-minicrypto.a; do
        if [ ! -f "$cache_dir/$native_file" ] || [ ! -s "$cache_dir/$native_file" ]; then
            fail "Incomplete native cache; preserve it before rebuilding: $cache_dir ($native_file)"
        fi
    done
    for setting in "ANDROID_ABI=$abi" "ANDROID_PLATFORM=$ANDROID_API" "CMAKE_BUILD_TYPE=Release" \
        "CMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"; do
        actual="$(sed -n "s/^${setting%%=*}:[^=]*=//p" "$cache_dir/CMakeCache.txt")"
        [ "$actual" = "${setting#*=}" ] || fail "Native cache setting mismatch: $cache_dir (${setting%%=*})"
    done
    for native_file in libpicoquic-core.a _deps/picotls-build/libpicotls-core.a \
        _deps/picotls-build/libpicotls-openssl.a _deps/picotls-build/libpicotls-minicrypto.a; do
        machines="$(elf_machine "$cache_dir/$native_file" | sort -u)" || fail "Invalid native archive: $cache_dir/$native_file"
        [ "$machines" = "$machine" ] || fail "Wrong ELF machine in native cache: $cache_dir/$native_file"
    done
}

cache_states=(cold cold cold)
for i in "${!ABIS[@]}"; do
    cache_dir="$SLIPSTREAM_SRC/.picoquic-build/${TARGETS[$i]}"
    require_directory "$cache_dir"
    if [ -d "$cache_dir" ] && ! directory_is_empty "$cache_dir"; then
        stamp="$cache_dir/.android-build-stamp"
        if [ ! -f "$stamp" ] || [ -L "$stamp" ]; then
            fail "Unstamped native cache; preserve it outside the target directory before rebuilding: $cache_dir"
        fi
        [ "$(cat "$stamp")" = "$(native_cache_metadata "${ABIS[$i]}" "${TARGETS[$i]}")" ] || \
            fail "Native cache metadata mismatch; preserve it outside the target directory before rebuilding: $cache_dir"
        verify_native_cache "$cache_dir" "${ABIS[$i]}" "${MACHINES[$i]}"
        cache_states[i]=warm
    fi
done

# Remove only recognized, generated x86 Slipstream files. Unknown entries must
# survive, and make the build fail rather than silently package an extra ABI.
stale_dir="$JNILIBS_DIR/x86"
require_directory "$stale_dir"
if [ -d "$stale_dir" ]; then
    shopt -s nullglob dotglob
    stale_files=("$stale_dir"/*)
    shopt -u nullglob dotglob
    for output in ${stale_files[@]+"${stale_files[@]}"}; do
        case "${output##*/}" in
            libslipstream.so|libslipstream_client.so) ;;
            *) fail "Unrecognized x86 output; preserving it: $output" ;;
        esac
        if [ ! -f "$output" ] || [ -L "$output" ]; then
            fail "Unrecognized x86 output; preserving it: $output"
        fi
        [ "$(elf_machine "$output")" = 'Intel 80386' ] || fail "Not a generated x86 ELF; preserving it: $output"
        strings -a "$output" | LC_ALL=C grep -F 'slipstream' > /dev/null || \
            fail "Not a recognized Slipstream output; preserving it: $output"
    done
    for output in ${stale_files[@]+"${stale_files[@]}"}; do
        rm -- "$output"
    done
    rmdir "$stale_dir"
fi

export CARGO_TARGET_DIR="$SLIPSTREAM_SRC/target"
export CARGO_BUILD_BUILD_DIR="$CARGO_TARGET_DIR"
# Encoded flags preserve paths containing spaces and cannot be bypassed by an
# inherited CARGO_ENCODED_RUSTFLAGS taking precedence over RUSTFLAGS.
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$SLIPSTREAM_SRC=/build/s"$'\x1f'"--remap-path-prefix=$HOME=/_"
printf -v CFLAGS '%q %q' "-ffile-prefix-map=$SLIPSTREAM_SRC=/build/s" "-ffile-prefix-map=$HOME=/_"
export CFLAGS
export CXXFLAGS="$CFLAGS"
export CC_SHELL_ESCAPED_FLAGS=1
# OpenSSL also embeds its install prefix as string-valued macros; compiler
# path maps do not rewrite those. This static build has no external modules.
export CPPFLAGS='-UENGINESDIR -DENGINESDIR=\"/build/s/openssl/engines\" -UMODULESDIR -DMODULESDIR=\"/build/s/openssl/modules\"'
export BUILD_TYPE=Release
export PICOQUIC_DIR="$SLIPSTREAM_SRC/vendor/picoquic"
export PICOQUIC_AUTO_BUILD=1
export PICOQUIC_FETCH_PTLS=ON
unset PICOQUIC_INCLUDE_DIR PICOQUIC_LIB_DIR PICOTLS_INCLUDE_DIR OPENSSL_NO_VENDOR CARGO_NDK_OUTPUT_PATH

mkdir -p "$CARGO_TARGET_DIR"
# cargo-ndk 4.1.2 probes the current workspace before reading --manifest-path.
# Give that probe an empty, generated workspace rather than running the build
# from inside the downloaded source tree.
driver_dir="$(mktemp -d "$CARGO_TARGET_DIR/android-driver.XXXXXX")"
printf '[workspace]\n' > "$driver_dir/Cargo.toml"
# The FFI build script invokes CC directly, without CFLAGS or cargo-ndk's
# target-specific CC variable. Its wrapper supplies both the target and remaps.
native_cc="$driver_dir/cc"
native_cmake="$driver_dir/cmake"
trap 'cd "$PROJECT_DIR"; rm -f "$native_cc" "$native_cmake" "$driver_dir/native-cache" "$driver_dir/Cargo.toml" "$driver_dir/Cargo.lock"; rmdir "$driver_dir"' EXIT
export RUST_ANDROID_GRADLE_CC="$native_cc"
export RUST_ANDROID_GRADLE_AR="$NDK_BIN/llvm-ar"
# The NDK toolchain does not initialize CMake flags from CFLAGS, and its rooted
# library search misses Cargo's vendored OpenSSL. Supply both explicitly when
# the FFI helper configures CMake; build only the native libraries it links.
printf '#!/bin/bash\nset -euo pipefail\ncmake=%q\nnative_flags=%q\n' \
    "$(command -v cmake)" "$CFLAGS" > "$native_cmake"
cat >> "$native_cmake" <<'CMAKE'
if [ "${1:-}" = --build ]; then
    exec "$cmake" "$@" --target picoquic-core picotls-core picotls-openssl picotls-minicrypto
fi
test -s "${OPENSSL_ROOT_DIR:?}/lib/libcrypto.a"
test -s "$OPENSSL_ROOT_DIR/lib/libssl.a"
exec "$cmake" "$@" -U '*BROTLI*' \
    "-DCMAKE_C_FLAGS=$native_flags" "-DCMAKE_CXX_FLAGS=$native_flags" \
    "-DOPENSSL_INCLUDE_DIR=$OPENSSL_ROOT_DIR/include" \
    "-DOPENSSL_CRYPTO_LIBRARY=$OPENSSL_ROOT_DIR/lib/libcrypto.a" \
    "-DOPENSSL_SSL_LIBRARY=$OPENSSL_ROOT_DIR/lib/libssl.a"
CMAKE
chmod +x "$native_cmake"
export PATH="$driver_dir:$PATH"
# Do not discover optional host libraries while configuring an Android target.
export PKG_CONFIG_LIBDIR="$driver_dir"
export PKG_CONFIG_PATH="$driver_dir"
cd "$driver_dir"

echo "=== Building Slipstream for Android (NDK $NDK_VERSION, API $ANDROID_API) ==="
for i in "${!ABIS[@]}"; do
    abi="${ABIS[$i]}"
    target="${TARGETS[$i]}"
    export PICOQUIC_BUILD_DIR="$SLIPSTREAM_SRC/.picoquic-build/$target"
    require_directory "$PICOQUIC_BUILD_DIR"
    printf '#!/bin/bash\nexec %q %q %q "$@"\n' \
        "$NDK_BIN/${CLANG_TARGETS[$i]}$ANDROID_API-clang" \
        "-ffile-prefix-map=$SLIPSTREAM_SRC=/build/s" "-ffile-prefix-map=$HOME=/_" > "$native_cc"
    chmod +x "$native_cc"

    echo "=== Building $abi ($target) ==="
    echo "Native cache: ${cache_states[$i]} ($PICOQUIC_BUILD_DIR)"
    cargo ndk --manifest-path "$SLIPSTREAM_SRC/Cargo.toml" -t "$target" -P "$ANDROID_API" \
        build --locked --release -p slipstream-client --features openssl-vendored

    binary="$CARGO_TARGET_DIR/$target/release/slipstream-client"
    verify_executable "$binary" "${MACHINES[$i]}"
    verify_native_cache "$PICOQUIC_BUILD_DIR" "$abi" "${MACHINES[$i]}"
    "$SCRIPT_DIR/check_binary_paths.sh" "$binary"
    if [ "${cache_states[$i]}" = cold ]; then
        native_cache_metadata "$abi" "$target" > "$driver_dir/native-cache"
        mv "$driver_dir/native-cache" "$PICOQUIC_BUILD_DIR/.android-build-stamp"
    fi
done

# Stage only after every target has built and passed its checks. cargo-ndk's
# shared-library copying does not stage a standalone command executable.
for i in "${!ABIS[@]}"; do
    abi="${ABIS[$i]}"
    output="$JNILIBS_DIR/$abi/libslipstream_client.so"
    mkdir -p "$JNILIBS_DIR/$abi"
    cp -p "$CARGO_TARGET_DIR/${TARGETS[$i]}/release/slipstream-client" "$output"
    verify_executable "$output" "${MACHINES[$i]}"
    "$SCRIPT_DIR/check_binary_paths.sh" "$output"
done

echo "=== Build complete: three checked executables in $JNILIBS_DIR ==="
