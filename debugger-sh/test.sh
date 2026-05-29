#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SANDBOX="$BUILD_DIR/sandbox"
SYSROOT="$SANDBOX/sysroot"
EXAMPLE_DIR="$SANDBOX/example"
RUSTC_WASM="$BUILD_DIR/rustc.wasm"
SYSROOT_TAR="$BUILD_DIR/sysroot.tar.gz"
WASM_LD_WASM="${WASM_LD_WASM:-$BUILD_DIR/llvm.core.wasm}"
WASM_LD_URL="${WASM_LD_URL:-https://fabioibanez.github.io/website/llvm.core.wasm}"

log() { echo "[test] $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }; }

need_cmd wasmer
need_cmd llvm-dwarfdump
need_cmd curl
need_cmd tar

[[ -f "$RUSTC_WASM" ]] || { echo "error: missing $RUSTC_WASM (run build.sh first)" >&2; exit 1; }
[[ -f "$SYSROOT_TAR" ]] || { echo "error: missing $SYSROOT_TAR (run build.sh first)" >&2; exit 1; }

if [[ ! -f "$WASM_LD_WASM" ]]; then
  log "Downloading wasm linker ($WASM_LD_URL)"
  curl -fsSL -o "$WASM_LD_WASM" "$WASM_LD_URL"
fi

rm -rf "$SANDBOX"
mkdir -p "$SYSROOT" "$EXAMPLE_DIR"
tar -xzf "$SYSROOT_TAR" -C "$SYSROOT"
cp -f "$SCRIPT_DIR/example.rs" "$EXAMPLE_DIR/example.rs"

log "Compile example.rs with rustc.wasm"
wasmer run "$RUSTC_WASM" --disable-threads \
  --mapdir "/sysroot:$SYSROOT" --mapdir "/example:$EXAMPLE_DIR" -- \
  /example/example.rs --sysroot /sysroot --target wasm32-wasip1 \
  -Cpanic=abort -Ccodegen-units=1 -Zthreads=1 --emit=obj -o /example/example.o -g

test -f "$EXAMPLE_DIR/example.o"
shopt -s nullglob
rcgu=("$EXAMPLE_DIR"/example.*.rcgu.o)
((${#rcgu[@]} > 0)) || { echo "error: missing allocator .rcgu.o from rustc codegen" >&2; exit 1; }

RUSTLIB="$SYSROOT/lib/rustlib/wasm32-wasip1/lib"
GUEST_RUSTLIB="/sysroot/lib/rustlib/wasm32-wasip1/lib"
GUEST_WASI_LIB="$GUEST_RUSTLIB/self-contained"
GUEST_OBJS=(/example/example.o)
for o in "${rcgu[@]}"; do GUEST_OBJS+=(/example/"$(basename "$o")"); done

link_rlibs=(
  "$RUSTLIB"/libpanic_abort-*.rlib "$RUSTLIB"/libstd-*.rlib "$RUSTLIB"/libwasi-*.rlib
  "$RUSTLIB"/libcfg_if-*.rlib "$RUSTLIB"/librustc_demangle-*.rlib "$RUSTLIB"/libstd_detect-*.rlib
  "$RUSTLIB"/libhashbrown-*.rlib "$RUSTLIB"/librustc_std_workspace_alloc-*.rlib "$RUSTLIB"/libminiz_oxide-*.rlib
  "$RUSTLIB"/libadler2-*.rlib "$RUSTLIB"/libunwind-*.rlib "$RUSTLIB"/liblibc-*.rlib
  "$RUSTLIB"/librustc_std_workspace_core-*.rlib "$RUSTLIB"/liballoc-*.rlib "$RUSTLIB"/libcore-*.rlib
  "$RUSTLIB"/libcompiler_builtins-*.rlib
)
GUEST_RLIBS=()
for f in "${link_rlibs[@]}"; do GUEST_RLIBS+=("$GUEST_RUSTLIB/$(basename "$f")"); done

log "Link example.wasm with wasm-ld (Wasmer-hosted)"
wasmer run "$WASM_LD_WASM" --disable-threads \
  --mapdir "/sysroot:$SYSROOT" --mapdir "/example:$EXAMPLE_DIR" -- \
  wasm-ld --export=__main_void -z stack-size=1048576 --stack-first --no-demangle \
  "$GUEST_WASI_LIB/crt1-command.o" "${GUEST_OBJS[@]}" "${GUEST_RLIBS[@]}" \
  -L"$GUEST_WASI_LIB" -lc -o /example/example.wasm --gc-sections -O0

log "Run example.wasm"
OUT="$(wasmer run "$EXAMPLE_DIR/example.wasm" 2>&1)"
echo "$OUT"
[[ "$OUT" == $'10\n20\n30\n40\n50' ]] || { echo "error: unexpected stdout" >&2; exit 1; }

log "Check DWARF for main"
DWARF_FILE="$SANDBOX/example.wasm.dwarf.txt"
llvm-dwarfdump "$EXAMPLE_DIR/example.wasm" >"$DWARF_FILE" 2>&1
head -80 "$DWARF_FILE"
grep -q 'DW_TAG_subprogram' "$DWARF_FILE"
grep -q 'DW_AT_name.*("main")' "$DWARF_FILE"
grep -q 'DW_AT_main_subprogram' "$DWARF_FILE"
grep -q 'example\.rs' "$DWARF_FILE"

log "All tests passed"
