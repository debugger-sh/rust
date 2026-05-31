#!/usr/bin/env bash
# Build wasm32-wasip1 rustc.wasm + sysroot.tar.gz for debugger-sh.
#
# Size strategy (bootstrap.toml):
#   - opt-level=z, fat LTO, codegen-units=1, strip=true
#   - debug-assertions/logging/frame-pointers off
# This removes the ~50 MiB WASM "name" section at link time; post-link wasm-opt
# is best-effort only (often skipped when the module uses bulk-memory/sign-ext).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_OUT="$SCRIPT_DIR/build"
RUST_UPSTREAM="${RUST_UPSTREAM:-https://github.com/rust-lang/rust.git}"

log() { echo "[build] $*"; }

ensure_wasi_sdk() {
  # bootstrap.toml uses repo-relative wasi-sdk paths; Dockerfile installs at /opt/wasi-sdk.
  if [[ ! -x "$ROOT/wasi-sdk-32.0-x86_64-linux/bin/clang++" ]]; then
    if [[ -x /opt/wasi-sdk/bin/clang++ ]]; then
      ln -sfn /opt/wasi-sdk "$ROOT/wasi-sdk-32.0-x86_64-linux"
    else
      echo "error: wasi-sdk not found (expected $ROOT/wasi-sdk-32.0-x86_64-linux or /opt/wasi-sdk)" >&2
      exit 1
    fi
  fi
  export WASI_SDK_PATH="$ROOT/wasi-sdk-32.0-x86_64-linux"
}

ensure_submodules() {
  cd "$ROOT"
  find "$ROOT/.git" "$ROOT/.git/modules" \
    \( -name index.lock -o -name config.lock -o -name shallow.lock \) \
    -delete 2>/dev/null || true
  git config --global --add safe.directory "$ROOT" 2>/dev/null || true
  git config --global --add safe.directory "$ROOT/src/llvm-project" 2>/dev/null || true
  git config --global --add safe.directory "$ROOT/src/tools/enzyme" 2>/dev/null || true
  git config --global --add safe.directory "$ROOT/src/tools/enzyme/enzyme" 2>/dev/null || true
  log "Updating required submodules"
  git submodule sync src/llvm-project src/tools/enzyme
  git -C "$ROOT/src/llvm-project" clean -fdx 2>/dev/null || true
  git submodule update --init --recursive src/tools/enzyme src/llvm-project
  git -C "$ROOT/src/llvm-project" fetch origin main --depth=1
  git -C "$ROOT/src/llvm-project" reset --hard FETCH_HEAD
}

install_wasm_llvm_libs() {
  local llvm_lib="$ROOT/build/wasm32-wasip1/llvm/lib/libLLVMCore.a"
  local llvm_build_lib="$ROOT/build/wasm32-wasip1/llvm/build/lib/libLLVMCore.a"
  [[ -f "$llvm_lib" ]] && return 0
  [[ -f "$llvm_build_lib" ]] || return 1
  log "Installing wasm LLVM static libraries into lib/"
  mkdir -p "$ROOT/build/wasm32-wasip1/llvm/lib"
  cp -a "$ROOT/build/wasm32-wasip1/llvm/build/lib/"*.a "$ROOT/build/wasm32-wasip1/llvm/lib/"
}

ensure_llvm_config() {
  local src="$ROOT/build/wasm32-wasip1/llvm/build/bin/llvm-config"
  local dst="$ROOT/build/wasm32-wasip1/llvm/bin/llvm-config"
  [[ -f "$src" && ! -x "$dst" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst" && chmod +x "$dst"
}

build_llvm_wasm() {
  cd "$ROOT"
  local llvm_lib="$ROOT/build/wasm32-wasip1/llvm/lib/libLLVMCore.a"
  if [[ -x build/wasm32-wasip1/llvm/bin/llvm-config && -f "$llvm_lib" ]]; then
    log "wasm LLVM already built; skipping ./x.py build llvm"
    return
  fi
  if install_wasm_llvm_libs; then
    ensure_llvm_config
    log "wasm LLVM libraries installed from build tree; skipping ./x.py build llvm"
    return
  fi
  log "Building LLVM for wasm32-wasip1 host (WebAssembly-only backend)"
  ./x.py build llvm --host wasm32-wasip1 -j "$(nproc)" \
    --set llvm.download-ci-llvm=false \
    --set llvm.targets=WebAssembly \
    --set llvm.experimental-targets=
  ensure_llvm_config
  install_wasm_llvm_libs
  test -x build/wasm32-wasip1/llvm/bin/llvm-config
  test -f "$llvm_lib"
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
  local stage0
  stage0="$(grep '^compiler_git_commit_hash=' src/stage0 | cut -d= -f2)"
  git cat-file -e "${stage0}^{commit}" 2>/dev/null \
    || git fetch "$RUST_UPSTREAM" "$stage0" --depth=1
  git fetch origin --deepen=256 --no-recurse-submodules 2>/dev/null || true
  log "Installing rustc (wasm32-wasip1 host, LLVM codegen)"
  ./x.py install -j "$(nproc)"
}

prune_sysroot() {
  # Keep .rmeta files: rustc.wasm needs them when compiling user crates (see test.sh).
  :
}

optimize_rustc_wasm() {
  local wasm="$1"
  log "Optimizing rustc.wasm... before=$(awk "BEGIN {printf \"%.1f\", $(stat -c%s "$wasm")/1048576}") MiB"
  # Use -Os (not -Oz): -Oz has produced invalid modules in the past.
  if wasm-opt -Os --strip-debug "$wasm" -o "${wasm}.opt" 2>/dev/null; then
    mv "${wasm}.opt" "$wasm"
  else
    log "wasm-opt skipped (binary uses WASM features wasm-opt cannot validate)"
  fi
  if command -v wasm-strip >/dev/null 2>&1; then
    wasm-strip "$wasm" -o "${wasm}.strip" 2>/dev/null \
      && mv "${wasm}.strip" "$wasm" \
      || true
  fi
  log "Finished optimizing... after=$(awk "BEGIN {printf \"%.1f\", $(stat -c%s "$wasm")/1048576}") MiB"
}

package_artifacts() {
  cd "$ROOT"
  mkdir -p "$BUILD_OUT"
  local rustc_src=""
  for cand in dist/bin/rustc.wasm dist/bin/rustc \
    build/wasm32-wasip1/stage2/bin/rustc.wasm build/wasm32-wasip1/stage2/bin/rustc; do
    [[ -f "$cand" ]] || continue
    rustc_src="$cand"
    break
  done
  [[ -n "$rustc_src" ]] || { echo "error: rustc wasm binary not found after install" >&2; exit 1; }
  [[ -d dist/lib/rustlib ]] || { echo "error: dist/lib/rustlib missing after install" >&2; exit 1; }

  log "Packaging $BUILD_OUT/rustc.wasm and sysroot.tar.gz"
  cp -f "$rustc_src" "$BUILD_OUT/rustc.wasm"
  optimize_rustc_wasm "$BUILD_OUT/rustc.wasm"

  local staging
  staging="$(mktemp -d)"
  mkdir -p "$staging/sysroot/lib"
  cp -a dist/lib/rustlib "$staging/sysroot/lib/rustlib"
  prune_sysroot "$staging/sysroot"
  if [[ -d dist/etc ]]; then
    mkdir -p "$staging/sysroot/etc"
    cp -a dist/etc "$staging/sysroot/etc"
  fi
  tar -czf "$BUILD_OUT/sysroot.tar.gz" -C "$staging/sysroot" lib etc 2>/dev/null \
    || tar -czf "$BUILD_OUT/sysroot.tar.gz" -C "$staging/sysroot" lib
  rm -rf "$staging"

  gzip -t "$BUILD_OUT/sysroot.tar.gz"
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
