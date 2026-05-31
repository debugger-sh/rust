#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_OUT="$SCRIPT_DIR/build"
RUST_UPSTREAM="${RUST_UPSTREAM:-https://github.com/rust-lang/rust.git}"

log() { echo "[build] $*"; }

ensure_submodules() {
  cd "$ROOT"
  find "$ROOT/.git" \( -name index.lock -o -name config.lock -o -name shallow.lock \) -delete 2>/dev/null || true
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
  local src="$ROOT/build/wasm32-wasip1/llvm/build/bin/llvm-config"
  local dst="$ROOT/build/wasm32-wasip1/llvm/bin/llvm-config"
  if [[ -f "$src" && ! -x "$dst" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst" && chmod +x "$dst"
  fi
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
  local stage0="$(grep '^compiler_git_commit_hash=' src/stage0 | cut -d= -f2)"
  git cat-file -e "${stage0}^{commit}" 2>/dev/null || git fetch "$RUST_UPSTREAM" "$stage0" --depth=1
  git fetch origin --deepen=256 --no-recurse-submodules
  log "Installing rustc (wasm32-wasip1 host, LLVM codegen)"
  ./x.py install -j "$(nproc)"
}

prune_sysroot() {
  local sysroot="$1"
  local self_contained="$sysroot/lib/rustlib/wasm32-wasip1/lib/self-contained"
  local objcopy=""
  for cand in llvm-objcopy llvm-objcopy-14 /usr/bin/llvm-objcopy; do
    command -v "$cand" >/dev/null 2>&1 || continue
    objcopy="$cand"
    break
  done

  if [[ -d "$self_contained" && -n "$objcopy" ]]; then
    log "Stripping debug info from self-contained sysroot objects"
    shopt -s nullglob
    for f in "$self_contained"/*; do
      "$objcopy" --strip-debug "$f" "$f"
    done
    shopt -u nullglob
  fi

  log "Removing .rmeta files from sysroot"
  find "$sysroot/lib/rustlib" -name '*.rmeta' -delete
}

package_artifacts() {
  cd "$ROOT"
  mkdir -p "$BUILD_OUT"
  local rustc_src=""
  for cand in dist/bin/rustc.wasm dist/bin/rustc build/wasm32-wasip1/stage2/bin/rustc.wasm build/wasm32-wasip1/stage2/bin/rustc; do
    [[ -f "$cand" ]] || continue
    rustc_src="$cand"
    break
  done
  [[ -n "$rustc_src" ]] || { echo "error: rustc wasm binary not found after install" >&2; exit 1; }
  [[ -d dist/lib/rustlib ]] || { echo "error: dist/lib/rustlib missing after install" >&2; exit 1; }

  log "Packaging $BUILD_OUT/rustc.wasm and sysroot.tar.gz"
  cp -f "$rustc_src" "$BUILD_OUT/rustc.wasm"

  log "Optimizing rustc.wasm... before=$(awk "BEGIN {printf \"%.1f\", $(stat -c%s "$BUILD_OUT/rustc.wasm")/1048576}") MiB"
  wasm-opt -Os "$BUILD_OUT/rustc.wasm" -o "$BUILD_OUT/rustc.wasm.opt" && mv "$BUILD_OUT/rustc.wasm.opt" "$BUILD_OUT/rustc.wasm"
  log "Finished optimizing... after=$(awk "BEGIN {printf \"%.1f\", $(stat -c%s "$BUILD_OUT/rustc.wasm")/1048576}") MiB"

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
  ls -lh "$BUILD_OUT/rustc.wasm" "$BUILD_OUT/sysroot.tar.gz"
}

main() {
  # bootstrap.toml uses repo-relative wasi-sdk paths; Dockerfile installs at /opt/wasi-sdk.
  [[ -e "$ROOT/wasi-sdk-32.0-x86_64-linux" ]] || ln -sfn /opt/wasi-sdk "$ROOT/wasi-sdk-32.0-x86_64-linux"
  ensure_submodules
  build_llvm_wasm
  link_ci_llvm
  install_rustc
  package_artifacts
  log "Build complete. Run debugger-sh/test.sh to validate artifacts."
}

main "$@"
