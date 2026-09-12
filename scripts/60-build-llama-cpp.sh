#!/usr/bin/env bash
# 60-build-llama-cpp.sh — OPTIONAL. Build llama.cpp with the Vulkan backend
# against the turnip + vulkan-sdk stack. Not required for GPU functionality
# itself; this is the "real workload" example. Policy note from the operator:
# llama-server on this device is laggy and only ~1.5x faster than CPU for
# 1B models — use it as a workload, not as the GPU test. GPU verification is
# vulkaninfo + compute demo (stage 70), never llama inference.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gpu-env.sh
source "$HERE/gpu-env.sh"

SRC="$LLAMA_DIR/llama.cpp"
BUILD="$SRC/build-gpu"
JOBS="$LLAMA_JOBS"

echo "== building llama.cpp (Vulkan) =="
echo "  src:    $SRC"
echo "  build:  $BUILD"
echo "  jobs:   $JOBS"

if [ ! -d "$SRC/.git" ]; then
  echo "cloning llama.cpp..."
  mkdir -p "$LLAMA_DIR"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "$SRC"
fi

# Build environment: the shader compile step (vulkan-shaders-gen -> glslc)
# needs the shim; the found Vulkan must be our SDK, not jammy's.
export CMAKE_PREFIX_PATH="$VULKAN_SDK_DIR"
export Vulkan_INCLUDE_DIR="$VULKAN_SDK_DIR/include"
export LD_PRELOAD="$TURNIP_DIR/shim.so"
GPUPATH="$(dirname "$GLSLC_SHIM")"   # shim glslc wins over PATH
export PATH="$GPUPATH:$PATH"

cmake -S "$SRC" -B "$BUILD" \
  -DGGML_VULKAN=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CURL=OFF \
  -DCMAKE_PREFIX_PATH="$VULKAN_SDK_DIR" \
  -DVulkan_INCLUDE_DIR="$VULKAN_SDK_DIR/include"
cmake --build "$BUILD" -j "$JOBS"

echo
echo "== build complete =="
ls -la "$BUILD/bin/llama-server" "$BUILD/bin/llama-cli" 2>/dev/null || true
echo
echo "Run a model on the GPU (env is mandatory — see scripts/gpu-env.sh):"
echo "  source $HERE/gpu-env.sh"
echo "  $BUILD/bin/llama-server -m /path/to/model.gguf -ngl 99 --host 127.0.0.1 --port 8080"
echo
echo "Operator policy: verify the GPU with stage 70 (vulkaninfo + compute demo),"
echo "not with llama inference."
