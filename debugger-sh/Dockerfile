FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG WASI_SDK_VERSION=32.0
ARG WASMER_VERSION=5.0.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash binaryen bzip2 ca-certificates curl file g++ gcc git llvm-14 llvm-14-tools \
    make ninja-build patch pkg-config python3 python3-pip python3-venv sudo wabt xz-utils zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/llvm-dwarfdump-14 /usr/local/bin/llvm-dwarfdump \
    && pip3 install --no-cache-dir 'cmake>=3.26'

RUN curl -fsSL \
    "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION%%.*}/wasi-sdk-${WASI_SDK_VERSION}-x86_64-linux.tar.gz" \
    | tar -xz -C /opt \
    && ln -sfn "/opt/wasi-sdk-${WASI_SDK_VERSION}-x86_64-linux" /opt/wasi-sdk

ENV WASI_SDK_PATH=/opt/wasi-sdk

RUN curl -fsSL "https://get.wasmer.io" | sh -s "v${WASMER_VERSION}" \
    && ln -sf /root/.wasmer/bin/wasmer /usr/local/bin/wasmer

WORKDIR /rust
ENV RUST_SRC=/rust
CMD ["/bin/bash"]
