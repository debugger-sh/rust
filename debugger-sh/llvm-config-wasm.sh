#!/bin/bash
# Cross-compiling rustc_llvm for wasm32-wasip1:
# - Headers from the host LLVM build (or CI LLVM).
# - Libraries from the wasm32-wasip1 LLVM build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="${ROOT}/build/x86_64-unknown-linux-gnu/llvm/bin/llvm-config"
if [ ! -x "$CI" ]; then
  CI="${ROOT}/build/x86_64-unknown-linux-gnu/ci-llvm/bin/llvm-config"
fi
WASM=""
for candidate in \
  "${ROOT}/build/wasm32-wasip1-threads/llvm/bin/llvm-config" \
  "${ROOT}/build/wasm32-wasip1/llvm/bin/llvm-config"; do
  if [ -x "$candidate" ]; then
    WASM="$candidate"
    break
  fi
done
WASMER="${WASMER_BIN:-$(command -v wasmer || true)}"

wasi_flags_only() {
  if [ ! -x "$WASM" ]; then
    echo "error: wasm LLVM not built at $WASM (run ./x.py build llvm)" >&2
    exit 1
  fi
  # Wasm LLVM is always built as static archives; ignore host link-shared settings.
  local args=()
  for arg in "$@"; do
    case "$arg" in
    --link-shared|--link-static) ;;
    *) args+=("$arg") ;;
    esac
  done
  args+=(--link-static)
  if "$WASM" --version >/dev/null 2>&1; then
    exec "$WASM" "${args[@]}"
  fi
  if [ -z "$WASMER" ]; then
    echo "error: $WASM is a WASM binary and wasmer was not found in PATH" >&2
    exit 1
  fi
  exec "$WASMER" run "$WASM" --dir "$ROOT" -- "${args[@]}"
}

for arg in "$@"; do
  case "$arg" in
  --components|--libdir|--libfiles|--libs|--ldflags|--system-libs|--link-shared|--link-static)
    wasi_flags_only "$@"
    ;;
  esac
done

case "$1" in
--includedir|--bindir|--cmakedir|--cxxflags|--cflags|--targets|--host-target|--version|--has-rust-patches)
  exec "$CI" "$@"
  ;;
*)
  exec "$CI" "$@"
  ;;
esac
