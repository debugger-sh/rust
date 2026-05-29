#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_OUT="$SCRIPT_DIR/build"
export WASI_SDK_PATH="${WASI_SDK_PATH:-$ROOT/wasi-sdk-32.0-x86_64-linux}"

log() { echo "[build] $*"; }

ensure_wasi_sdk() {
  if [[ -x "$WASI_SDK_PATH/bin/clang" ]]; then
    return
  fi
  local ver="32.0"
  local dest="$ROOT/wasi-sdk-${ver}-x86_64-linux"
  if [[ -x "$dest/bin/clang" ]]; then
    export WASI_SDK_PATH="$dest"
    return
  fi
  log "Downloading WASI SDK ${ver}"
  curl -fsSL \
    "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-32/wasi-sdk-${ver}-x86_64-linux.tar.gz" \
    | tar -xz -C "$ROOT"
  export WASI_SDK_PATH="$dest"
}

ensure_submodules() {
  cd "$ROOT"
  find "$ROOT/.git" -name index.lock -delete 2>/dev/null || true
  git config --global --add safe.directory "*" 2>/dev/null || true
  git config --global --add safe.directory "$ROOT" 2>/dev/null || true
  git config --global --add safe.directory "$ROOT/src/llvm-project" 2>/dev/null || true
  git config --global --add safe.directory "$ROOT/src/tools/enzyme" 2>/dev/null || true
  git config --global --add safe.directory "$ROOT/src/tools/enzyme/enzyme" 2>/dev/null || true
  log "Updating required submodules"
  git submodule sync src/llvm-project src/tools/enzyme
  if [[ -d "$ROOT/src/llvm-project" ]]; then
    git -C "$ROOT/src/llvm-project" clean -fdx
  fi
  git submodule update --init --recursive src/tools/enzyme src/llvm-project
  git -C "$ROOT/src/llvm-project" fetch origin main --depth=1
  git -C "$ROOT/src/llvm-project" reset --hard FETCH_HEAD
}

install_wasm_llvm_config() {
  local src="$ROOT/build/wasm32-wasip1/llvm/build/bin/llvm-config"
  local dst="$ROOT/build/wasm32-wasip1/llvm/bin/llvm-config"
  if [[ -f "$src" && ! -x "$dst" ]]; then
    log "Installing wasm llvm-config (bootstrap copy step)"
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    chmod +x "$dst"
  fi
}

build_llvm_wasm() {
  cd "$ROOT"
  if [[ -x build/wasm32-wasip1/llvm/bin/llvm-config ]]; then
    log "wasm LLVM already built; skipping ./x.py build llvm"
    return
  fi
  log "Building LLVM for wasm32-wasip1 host (WebAssembly-only backend)"
  ./x.py build llvm --host wasm32-wasip1 -j "$(nproc)" \
    --set llvm.download-ci-llvm=false \
    --set llvm.targets=WebAssembly \
    --set llvm.experimental-targets=
  install_wasm_llvm_config
  test -x build/wasm32-wasip1/llvm/bin/llvm-config
}

link_ci_llvm() {
  cd "$ROOT"
  if [[ -d build/x86_64-unknown-linux-gnu/ci-llvm ]]; then
    log "Linking ci-llvm for wasm host codegen"
    ln -sfn "$ROOT/build/x86_64-unknown-linux-gnu/ci-llvm" \
      "$ROOT/build/wasm32-wasip1/ci-llvm"
  fi
}

install_rustc() {
  cd "$ROOT"
  log "Installing rustc (wasm32-wasip1 host, LLVM codegen)"
  ./x.py install -j $(nproc)
}

package_artifacts() {
  cd "$ROOT"
  mkdir -p "$BUILD_OUT"
  local rustc_src=""
  for cand in dist/bin/rustc.wasm dist/bin/rustc build/wasm32-wasip1/stage2/bin/rustc.wasm build/wasm32-wasip1/stage2/bin/rustc; do
    if [[ -f "$cand" ]]; then
      rustc_src="$cand"
      break
    fi
  done
  if [[ -z "$rustc_src" ]]; then
    echo "error: rustc wasm binary not found after install" >&2
    exit 1
  fi
  if [[ ! -d dist/lib/rustlib ]]; then
    echo "error: dist/lib/rustlib missing after install" >&2
    exit 1
  fi

  log "Packaging $BUILD_OUT/rustc.wasm and sysroot.tar.gz"
  cp -f "$rustc_src" "$BUILD_OUT/rustc.wasm"

  log "Optimizing rustc.wasm... before=$(awk "BEGIN {printf \"%.1f\", $(stat -c%s "$BUILD_OUT/rustc.wasm")/1048576}") MiB"
  wasm-opt -Os "$BUILD_OUT/rustc.wasm" -o "$BUILD_OUT/rustc.wasm.opt" && mv "$BUILD_OUT/rustc.wasm.opt" "$BUILD_OUT/rustc.wasm"
  log "Finished optimizing... after=$(awk "BEGIN {printf \"%.1f\", $(stat -c%s "$BUILD_OUT/rustc.wasm")/1048576}") MiB"
  
  local staging
  staging="$(mktemp -d)"
  mkdir -p "$staging/sysroot/lib"
  cp -a dist/lib/rustlib "$staging/sysroot/lib/rustlib"
  if [[ -d dist/etc ]]; then
    mkdir -p "$staging/sysroot/etc"
    cp -a dist/etc "$staging/sysroot/etc"
  fi
  tar -czf "$BUILD_OUT/sysroot.tar.gz" -C "$staging/sysroot" lib etc 2>/dev/null || tar -czf "$BUILD_OUT/sysroot.tar.gz" -C "$staging/sysroot" lib
  rm -rf "$staging"
  ls -lh "$BUILD_OUT/rustc.wasm" "$BUILD_OUT/sysroot.tar.gz"
}

main() {
  ensure_wasi_sdk
  ensure_submodules
  build_llvm_wasm
  link_ci_llvm
  install_rustc
  package_artifacts
  log "Build complete. Run debugger-sh/test.sh to validate artifacts."
}

main "$@"
