#!/bin/bash

# Build the pinned Slipstream client for macOS with the build machine paths
# removed.
#
# Two independent sources embed the checkout path:
#   - picoquic C sources keep __FILE__ in DBG_PRINTF messages, so the C and
#     C++ compilers need -ffile-prefix-map in addition to the Rust remap;
#   - the vendored OpenSSL Configure writes its install prefix into the
#     ENGINESDIR and MODULESDIR string macros, which no compile-time path map
#     can rewrite.
#
# Prerequisites:
#   - macOS with Xcode command line tools, CMake, make and Perl
#   - Rust and cargo from rustup
#   - git submodule update --init --recursive vendor/slipstream-rust
#
# Usage: ./scripts/build_slipstream_macos.sh
#
# The built binary replaces macos/Runner/Libraries/slipstream-client only after
# scripts/check_binary_paths.sh finds no machine paths in it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SLIPSTREAM_SRC_REL="$PROJECT_DIR/vendor/slipstream-rust"
OUTPUT="$PROJECT_DIR/macos/Runner/Libraries/slipstream-client"

fail() {
    echo "Error: $*" >&2
    exit 1
}

for tool in cargo rustc git cmake make perl cc c++ ar uname strings grep sort head mktemp cp chmod; do
    command -v "$tool" > /dev/null || fail "Required tool not found: $tool"
done
test -n "${HOME:-}" || fail "HOME must be set for path remapping"
test -x "$SCRIPT_DIR/check_binary_paths.sh" || fail "Binary path checker is missing"
[ "$(uname -s)" = Darwin ] || fail "This script stages a macOS binary and runs on Darwin only"

for source_file in Cargo.toml vendor/picoquic/CMakeLists.txt; do
    test -s "$SLIPSTREAM_SRC_REL/$source_file" || \
        fail "Missing source: vendor/slipstream-rust/$source_file; run git submodule update --init --recursive vendor/slipstream-rust"
done
SLIPSTREAM_SRC="$(cd "$SLIPSTREAM_SRC_REL" && pwd -P)" || fail "Slipstream source directory not found"

# The encoded form keeps both remaps in one value and takes precedence over an
# inherited RUSTFLAGS.
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$SLIPSTREAM_SRC=/build/s"$'\x1f'"--remap-path-prefix=$HOME=/_"
# CMake initializes CMAKE_C_FLAGS/CMAKE_CXX_FLAGS from these variables, so the
# picoquic build receives the same maps; CC_SHELL_ESCAPED_FLAGS marks the
# values as already shell-escaped by printf.
printf -v CFLAGS '%q %q' "-ffile-prefix-map=$SLIPSTREAM_SRC=/build/s" "-ffile-prefix-map=$HOME=/_"
export CFLAGS
export CXXFLAGS="$CFLAGS"
export CC_SHELL_ESCAPED_FLAGS=1
# OpenSSL defines these macros from its install prefix; compiler path maps do
# not rewrite them. This build is static and has no external modules, so the
# neutral values are never read at run time.
export CPPFLAGS='-UENGINESDIR -DENGINESDIR=\"/build/s/openssl/engines\" -UMODULESDIR -DMODULESDIR=\"/build/s/openssl/modules\"'
# A preinstalled library would be linked with paths the remaps do not cover.
unset PICOQUIC_INCLUDE_DIR PICOQUIC_LIB_DIR PICOTLS_INCLUDE_DIR OPENSSL_NO_VENDOR

cd "$SLIPSTREAM_SRC"
echo "=== Building Slipstream for macOS ==="
cargo build -p slipstream-client --release --features openssl-vendored

binary="$SLIPSTREAM_SRC/target/release/slipstream-client"
test -s "$binary" || fail "Missing build output: $binary"
"$SCRIPT_DIR/check_binary_paths.sh" "$binary" || \
    fail "Built slipstream-client contains machine paths; not staged"
test -d "$PROJECT_DIR/macos/Runner/Libraries" || fail "Missing macOS libraries directory"
test ! -L "$OUTPUT" || fail "Refusing a symlinked output: $OUTPUT"
cp "$binary" "$OUTPUT"
chmod 0755 "$OUTPUT"

echo "=== Build complete: checked $OUTPUT ==="
