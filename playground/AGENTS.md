## Goal

I want to compile `rustc` to WASM. The `rustc` compiler binary itself should be compiled to `wasm32-wasip1`, and it should be able to compile `.rs` files to `wasm32-wasip1`.

You are currently on a branch of the `rustc` source that has had some tweaks applied to it. These tweaks may be complete, or they may not be. You may be required to modify the compiler source to complete these changes. Please try to simply compile at first, and then make changes conservatively as necessary, since re-compiling takes a long time.

## Deliverable

Ultimately, you should produce:

-   A `rustc` compiler binary at `playground/rustc.wasm`.
-   A `wasm32-wasip1` sysroot at `playground/sysroot`.
-   A `GUIDE.md` file that describes the steps used to produce the above files, so that it is reproducible.

## Evaluation

> You have **three goals.** See below for a full description.
>
> 1. Run `rustc.wasm` to compile `example/example.rs`.
> 2. Link the resulting object files into a functional `wasm` binary.
> 3. Ensure the final binary has reasonable debug output.

To test whether or not you've succeeded, you should be able to compile `example/example.rs` with `playground/rustc.wasm` to produce an output `.o` file with debug symbols. Specifically, you should be able to run (from the `playground/` directory):

```sh
wasmer run bin/rustc.wasm \
  --disable-threads \
  --volume ./sysroot:/sysroot \
  --volume ./example:/example \
  -- \
  /example/example.rs \
  --sysroot /sysroot \
  --target wasm32-wasip1 \
  -Cpanic=abort \
  -Ccodegen-units=1 \
  --emit=obj \
  -o /example/example.o \
  -g
```

to produce an `example/example.o` file.

You should then be able link (using `wasm-ld`) the output object files (including any generated Rust shims and any standard libraries) to produce an `example/example.wasm`. Then run this file in `wasmer` to see if the final output binary prints the expected result to standard output. The linker command used should also be written to `GUIDE.md`.

You should finally be able to run:

```sh
llvm-dwarfdump example/example.wasm
```

and ensure that the output is reasonable DWARF debug info output.
