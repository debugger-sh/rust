This project builds a reproducible `wasm32-wasip1` `rustc` (LLVM backend) from source and packages `rustc.wasm` plus `sysroot.tar.gz` under `debugger-sh/build/`. The build is containerized for GitHub Actions. End-to-end:

0. Create a Linux container to run the build pipeline.
1. Checkout this repository, and pull the *relevant* submodules (e.g. `llvm-project`).
2. Build `rustc`, including and dependencies needed for the build to succeed, to get an output `rustc.wasm` and `sysroot.tar.gz`.
3. Test the binaries/sysroot by running an evaluation pipeline under `wasmer`, described below.
4. If tests pass, create a new GitHub release with the `rustc.wasm` and `sysroot.tar.gz` binaries.

See below for further description of these steps.

## Guidelines

1. All build and test scripts live under `debugger-sh/` (`build.sh`, `test.sh`, `llvm-config-wasm.sh`).
2. Test the build locally end-to-end (Docker recommended) before pushing CI changes.
3. Bootstrap references `debugger-sh/llvm-config-wasm.sh` when cross-compiling `rustc_llvm` for WASI hosts.
4. Do not make commits for this repo unless asked; LLVM fork commits on `debugger-sh/llvm` are fine.

## Steps

### Step 0: Container

Create a standard x86_64 Linux container for the action. Note that as a result of creating the container from scratch, common utilities like `llvm-dwarfdump` and `wasmer` may not be present and will (at some point, not necessarily this step) need to be installed.

### Step 1: Checkout

You should checkout this fork and any *relevant* submodules. Right now, this project pulls the `llvm-project` directly from its upstream source. This is not ideal, as we have applied many `wasi` specific patches to ensure that the build works. To address this, you should create a `debugger-sh/llvm` repository to contain the latest patches for WASI compatitibility. Currently, the WASI patches seemed to have been removed from the source tree, so you may need to re-apply them again. **I recommend using this specific commit from YoWasp as the basis for `llvm-project`**: https://github.com/YoWASP/llvm-project/tree/97196c8eeb1d495fa43bb8af2fb26af5ef5b89fb: start with this commit and then apply additional patches on top if the build does not succeed. Make sure, however, that the repository on GitHub is listed as a fork of the main `llvm-project` mirror at `https://github.com/llvm/llvm-project`. Update the submodule point to our new `debugger-sh/llvm-project`.

### Step 2: Build

Once all dependencies have been fetched, build `rustc` from source via `debugger-sh/build.sh` (submodules, wasm LLVM, `x.py install`). Produce `rustc.wasm` and `sysroot.tar.gz` in `debugger-sh/build/`.

### Step 3: Test

You should test only from the final outputs, e.g. `rustc.wasm` and `sysroot.tar.gz`, not any intermediate, to simulate a user consuming the library themselves.

Tests should run under Wasmer with an example program. Use the existing `example.rs` (but moved to the `debugger-sh/` dir) to do so. The tests should all live in a `debugger-sh/test.sh` file, and should do the following:

0. Unzip `sysroot` into `build/sandbox/sysroot` (use the `build/sandbox` folder as a temp directory).
1. Compile `example.rs` into an `example.o` (and any additional Rust allocator shims, libraries, etc.). Make sure to run it in Wasmer using `--disable-threads`.
2. Link into an `example.wasm`. For the linker, use the `wasm-ld` binary at `https://fabioibanez.github.io/website/llvm.core.wasm` (which is itself a wasm binary) and run it under Wasmer.
3. Use `llvm-dwarfdump` to inspect the resulting `example.wasm`. Confirm that it contains a `DW_AT_subprogram` entry for `main` like the following (might not exactly match):

```
DW_TAG_subprogram
    DW_AT_low_pc  (0x000005df)
    DW_AT_high_pc (0x00000751)
    DW_AT_frame_base      (DW_OP_WASM_location 0x0 0x0, DW_OP_stack_value)
    DW_AT_linkage_name    ("_RNvCshHd9RfolKlg_7example4main")
    DW_AT_name    ("main")
    DW_AT_decl_file       ("/example/example.rs")
    DW_AT_decl_line       (1)
    DW_AT_main_subprogram (true)
```

### Step 4: Release

You should create a `.github/workflows/debugger-sh.yml` to run all of the above steps and, assuming they all succeed, finally package the `rustc.wasm` and `sysroot.tar.gz` into a GitHub release and publish it!


