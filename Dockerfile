# Custom image: toolchain + build deps baked in once. After the first `docker build`,
# Docker's layer cache makes rebuilding this image near-instant (no re-download, no re-apt-install)
# unless this Dockerfile changes.
FROM --platform=linux/amd64 ubuntu:22.04

RUN apt-get update -qq && apt-get install -y -qq build-essential cmake git wget xz-utils ccache file && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt && \
    wget -q https://github.com/spacemit-com/toolchain/releases/download/v1.2.4/spacemit-toolchain-linux-glibc-x86_64-v1.2.4.tar.xz -O /tmp/toolchain.tar.xz && \
    tar -xf /tmp/toolchain.tar.xz -C /tmp && \
    mv /tmp/spacemit-toolchain-linux-glibc-x86_64-v1.2.4 /opt/spacemit-toolchain && \
    rm /tmp/toolchain.tar.xz

ENV RISCV_ROOT_PATH=/opt/spacemit-toolchain
ENV PATH="${RISCV_ROOT_PATH}/bin:${PATH}"

WORKDIR /root
COPY build-inside.sh /build-inside.sh
RUN chmod +x /build-inside.sh
