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
LLVM_LIB="${ROOT}/build/wasm32-wasip1/llvm/lib"

wasi_flags_only() {
  if [ ! -x "$WASM" ]; then
    echo "error: wasm LLVM not built at $WASM (run ./x.py build llvm)" >&2
    exit 1
  fi
  # Wasm llvm-config reports guest paths like /lib under wasmer; answer locally.
  for arg in "$@"; do
    case "$arg" in
    --libdir)
      echo "$LLVM_LIB"
      return
      ;;
    --ldflags)
      echo "-L$LLVM_LIB"
      return
      ;;
    esac
  done
  # Wasm LLVM is always built as static archives; ignore host link-shared settings.
  local args=()
  for arg in "$@"; do
    case "$arg" in
    --link-shared|--link-static) ;;
    *) args+=("$arg") ;;
    esac
  done
  args+=(--link-static)
  local out=""
  if "$WASM" --version >/dev/null 2>&1; then
    out="$("$WASM" "${args[@]}")"
  else
    if [ -z "$WASMER" ]; then
      echo "error: $WASM is a WASM binary and wasmer was not found in PATH" >&2
      exit 1
    fi
    # LLVM was built with CMAKE_INSTALL_PREFIX=/rust/... . When the checkout lives
    # elsewhere, map guest /rust (and /lib) into the repo. In CI/Docker the checkout
    # is mounted at /rust, so only a single --dir mount is needed.
    local -a wasmer_args=(run "$WASM")
    if [[ "$ROOT" == "/rust" ]]; then
      wasmer_args+=(--dir "$ROOT")
    else
      wasmer_args+=(
        --mapdir "/rust:$ROOT"
        --mapdir "/lib:$LLVM_LIB"
        --dir "$ROOT"
      )
    fi
    wasmer_args+=(-- "${args[@]}")
    out="$("$WASMER" "${wasmer_args[@]}")"
  fi
  # Normalize /rust/... paths from the wasm llvm-config to the local checkout.
  printf '%s\n' "$out" | sed "s|/rust/|$ROOT/|g; s|/lib/|$ROOT/build/wasm32-wasip1/llvm/lib/|g"
}

for arg in "$@"; do
  case "$arg" in
  --components|--libdir|--libfiles|--libs|--ldflags|--system-libs|--link-shared|--link-static)
    wasi_flags_only "$@"
    exit 0
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
