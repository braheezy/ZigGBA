#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIGLANG_DIR="$ROOT_DIR/ziglang"
BUILD_DIR="$ZIGLANG_DIR/build-release"
INSTALL_DIR="$ZIGLANG_DIR/zig-out"
REPRO_OUT_DIR="$ROOT_DIR/zig-cache-repros/local-build"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT_DIR/zig-cache-local-global}"
ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$ROOT_DIR/zig-cache-local-local}"

LLVM_PREFIX="/opt/homebrew/opt/llvm@20"
LLD_PREFIX="/opt/homebrew/opt/lld@20"
ZSTD_PREFIX="/opt/homebrew/opt/zstd"

mkdir -p "$REPRO_OUT_DIR"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
export ZIG_GLOBAL_CACHE_DIR
export ZIG_LOCAL_CACHE_DIR

if [ ! -d "$BUILD_DIR" ]; then
  /opt/homebrew/bin/cmake -G Ninja \
    -B "$BUILD_DIR" \
    -S "$ZIGLANG_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_PREFIX_PATH="${LLVM_PREFIX};${LLD_PREFIX};${ZSTD_PREFIX}" \
    -DCMAKE_EXE_LINKER_FLAGS="-L/opt/homebrew/lib"
fi

/opt/homebrew/bin/ninja -C "$BUILD_DIR" install

# zig's CMake files currently inject /opt/homebrew/opt/zstd/lib into LC_RPATH twice,
# which makes dyld refuse to launch the binary. Strip the duplicates after install.
/usr/bin/install_name_tool -delete_rpath /opt/homebrew/opt/zstd/lib "$INSTALL_DIR/bin/zig" 2>/dev/null || true
/usr/bin/install_name_tool -delete_rpath /opt/homebrew/opt/zstd/lib "$INSTALL_DIR/bin/zig" 2>/dev/null || true
/usr/bin/install_name_tool -add_rpath /opt/homebrew/opt/zstd/lib "$INSTALL_DIR/bin/zig"

"$INSTALL_DIR/bin/zig" build-obj "$ROOT_DIR/repro.zig" \
  -target thumb-freestanding -mcpu=arm7tdmi -OReleaseSmall \
  -femit-asm="$REPRO_OUT_DIR/repro-local.s" \
  -femit-llvm-ir="$REPRO_OUT_DIR/repro-local.ll" \
  -femit-bin="$REPRO_OUT_DIR/repro-local.o"
