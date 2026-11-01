# SPDX-License-Identifier: GPL-2.0-only
# Build container for turing-unlock on Unraid.
#
# Unraid builds without CONFIG_MODVERSIONS and without module signing; an out-of-tree module only
# has to match the kernel release (vermagic), not the compiler. gcc 15 is used anyway because
# Unraid 7.3.2's kernel was built with gcc 15.3.0. Override with --build-arg BASE_IMAGE=debian:trixie-slim.
ARG BASE_IMAGE=gcc:15
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bc bison flex libelf-dev libssl-dev kmod \
      xz-utils zstd cpio unzip squashfs-tools curl ca-certificates git python3 \
    && rm -rf /var/lib/apt/lists/*

COPY build/build.sh build/unraid-kernel-config.sh build/rc.modules.turing-unlock /opt/turing-unlock-build/build/
COPY firmware /opt/turing-unlock-build/firmware
RUN chmod +x /opt/turing-unlock-build/build/*.sh /opt/turing-unlock-build/firmware/build-firmware.sh

ENV OUT=/out CACHE=/cache
VOLUME ["/out", "/cache"]
WORKDIR /opt/turing-unlock-build
ENTRYPOINT ["/opt/turing-unlock-build/build/build.sh"]
