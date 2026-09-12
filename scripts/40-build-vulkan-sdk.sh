#!/usr/bin/env bash
# 40-build-vulkan-sdk.sh — build modern Vulkan-Headers, Vulkan-Hpp and
# glslang 16.5 into $VULKAN_SDK_DIR (never overwriting apt packages).
#
# Jammy's glslang-tools (11.8) cannot compile modern compute shaders
# (gejeta: '#include' : required extension not requested:
# GL_GOOGLE_include_directive) and jammy's Vulkan-Hpp (1.3.204) lacks
# vk::LayerSettingEXT / vk::DriverId::eMesaDozen required by modern
# ggml-vulkan.cpp — this stage builds the versions that work.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gpu-env.sh
source "$HERE/gpu-env.sh"

JOBS="$(nproc)"
mkdir -p "$VULKAN_SDK_DIR"
WORK="$(mktemp -d /tmp/vulkan-sdk.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "== building Vulkan SDK components into $VULKAN_SDK_DIR =="
echo "  workdir: $WORK (removed on exit)"

# --------------------------------------------------- Vulkan-Headers
if [ -d "$VULKAN_SDK_DIR/include/vulkan" ]; then
  echo "-- Vulkan-Headers: already present, skipping"
else
  echo "-- Vulkan-Headers $VULKAN_HEADERS_REF"
  git clone --depth 1 --branch "$VULKAN_HEADERS_REF" \
    https://github.com/KhronosGroup/Vulkan-Headers "$WORK/Vulkan-Headers"
  cmake -S "$WORK/Vulkan-Headers" -B "$WORK/Vulkan-Headers/build" \
        -DCMAKE_INSTALL_PREFIX="$VULKAN_SDK_DIR" -G Ninja
  cmake --build "$WORK/Vulkan-Headers/build" --target install
fi

# --------------------------------------------------- Vulkan-Hpp
if [ -f "$VULKAN_SDK_DIR/include/vulkan/vulkan.hpp" ]; then
  echo "-- Vulkan-Hpp: already present, skipping"
else
  echo "-- Vulkan-Hpp $VULKAN_HPP_REF"
  git clone --depth 1 --branch "$VULKAN_HPP_REF" \
    https://github.com/KhronosGroup/Vulkan-Hpp "$WORK/Vulkan-Hpp"
  # header-only: copy the single header into the include tree
  cp "$WORK/Vulkan-Hpp/vulkan/vulkan.hpp" "$VULKAN_SDK_DIR/include/vulkan/vulkan.hpp"
  echo "   installed: $VULKAN_SDK_DIR/include/vulkan/vulkan.hpp"
fi

# --------------------------------------------------- glslang (+ SPIRV-Tools)
if [ -x "$VULKAN_SDK_DIR/bin/glslangValidator" ] \
   && "$VULKAN_SDK_DIR/bin/glslangValidator" --version 2>/dev/null | grep -q '1[4-9]\.'; then
  echo "-- glslang >= 14 already installed, skipping"
else
  echo "-- glslang $GLSLANG_REF (with SPIRV-Tools submodule)"
  git clone --depth 1 --branch "$GLSLANG_REF" --recurse-submodules \
    https://github.com/KhronosGroup/glslang "$WORK/glslang"
  cmake -S "$WORK/glslang" -B "$WORK/glslang/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$VULKAN_SDK_DIR" \
        -DALLOW_EXTERNAL_SPIRV_TOOLS=OFF \
        -G Ninja
  cmake --build "$WORK/glslang/build" -j "$JOBS"
  cmake --install "$WORK/glslang/build"
fi

# --------------------------------------------------- verdict
echo
echo "== vulkan-sdk ready =="
"$VULKAN_SDK_DIR/bin/glslangValidator" --version | head -2
ls "$VULKAN_SDK_DIR/include/vulkan/vulkan.hpp" >/dev/null && echo "  vulkan.hpp present"
ls "$VULKAN_SDK_DIR/lib" | head -6 | sed 's/^/  lib\//;s/^/  /'
echo
echo "Stage 40 done. glslang 16.x at $VULKAN_SDK_DIR/bin/glslangValidator"
