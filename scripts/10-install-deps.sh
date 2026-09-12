#!/usr/bin/env bash
# 10-install-deps.sh — apt packages used by later stages.
# Safe on a fresh rootfs; apt is idempotent by nature.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gpu-env.sh
source "$HERE/gpu-env.sh"

SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"

echo "== installing apt dependencies =="
$SUDO apt-get update -qq
DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends \
  build-essential \
  cmake \
  ninja-build \
  git \
  curl \
  ca-certificates \
  tar \
  xz-utils \
  patchelf \
  python3 \
  python3-pip \
  vulkan-tools \
  libvulkan-dev \
  glslang-tools \
  unzip \
  pkg-config

echo "== versions on record =="
gcc --version | head -1
cmake --version | head -1
patchelf --version
python3 --version
vulkaninfo --version 2>/dev/null || /usr/bin/vulkaninfo --summary >/dev/null 2>&1 || true

# NOTE: vulkan-tools / libvulkan-dev / glslang-tools from jammy are OLD
# (loader 1.3.204, glslang 11.8). We keep them only as bootstrap:
#   - libvulkan1       = the Vulkan *loader* (driver-independent, fine)
#   - vulkan-tools     = vulkaninfo for baseline checks (with fallback ICD)
#   - glslang-tools    = replaced by our 16.5 build in stage 40; the jammy
#     glslangValidator cannot compile llama.cpp's shaders (missing
#     GL_GOOGLE_include_directive), which is exactly why stage 40 exists.
# The GPU driver itself comes from the noble turnip tarball, never from apt.
echo "bootstrap packages installed (system Mesa/turnip from apt is NOT used)"
