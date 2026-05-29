# debugger-sh: reproducible wasm32-wasip1 rustc build

Containerized pipeline to build `rustc.wasm` and `sysroot.tar.gz`, test them under Wasmer, and publish GitHub releases.

## Layout

- `build.sh` — full build pipeline (submodules, wasm LLVM, `x.py install`, packaging)
- `test.sh` — Wasmer-based validation of `rustc.wasm` + `sysroot.tar.gz`
- `llvm-config-wasm.sh` — bootstrap helper: CI LLVM headers + wasm LLVM static libs for `rustc_llvm`
- `example.rs` — sample program used by `test.sh`

```bash
chmod +x debugger-sh/build.sh debugger-sh/test.sh debugger-sh/llvm-config-wasm.sh
./debugger-sh/build.sh
./debugger-sh/test.sh
```

Artifacts land in `debugger-sh/build/`:

- `rustc.wasm`
- `sysroot.tar.gz`
- `llvm.core.wasm` (downloaded by `test.sh`)

## Docker

```bash
docker build -f debugger-sh/Dockerfile -t debugger-sh-build .
docker run --rm -v "$PWD:/rust" -w /rust debugger-sh-build /rust/debugger-sh/build.sh
docker run --rm -v "$PWD:/rust" -w /rust debugger-sh-build /rust/debugger-sh/test.sh
```

## LLVM fork (`debugger-sh/llvm`)

The `src/llvm-project` submodule points at [debugger-sh/llvm](https://github.com/debugger-sh/llvm) (fork of [llvm/llvm-project](https://github.com/llvm/llvm-project)). `main` is rust-lang LLVM at `1cb4e3833` plus YoWASP-style WASI patches (adapted for rustc 22.1). `build.sh` checks out `debugger-sh/llvm` `main` directly.

## CI

`.github/workflows/debugger-sh.yml` builds in Docker, runs `test.sh`, and uploads release assets on success.
