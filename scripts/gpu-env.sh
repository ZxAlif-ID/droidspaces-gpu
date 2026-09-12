# shellcheck shell=bash
# gpu-env.sh — shared environment for every droidspaces-gpu script
#
# Source this file (or `install.sh` which sources it for you) to get the
# canonical environment variables that make the Adreno GPU reachable through
# turnip + kgsl. Every path can be overridden before sourcing.

# --- install locations (all outside $HOME on purpose: a rootfs $HOME
# --- restore/backup will not wipe /opt) -------------------------------
TURNIP_DIR="${TURNIP_DIR:-/opt/turnip}"              # patched turnip driver
VULKAN_SDK_DIR="${VULKAN_SDK_DIR:-/opt/vulkan-sdk}"  # headers + glslang
GLSLC_SHIM="${GLSLC_SHIM:-/usr/local/bin/glslc}"     # glslc wrapper

# --- turnip tarball (noble build, then glibc-patched for jammy) --------
# Upstream releases: https://github.com/lfdevs/mesa-for-android-container/releases
TURNIP_TAG="${TURNIP_TAG:-turnip-26.3.0-devel-20260824}"
TURNIP_ASSET="${TURNIP_ASSET:-turnip_26.3.0-devel-20260824_ubuntu_noble_arm64.tar.gz}"
TURNIP_URL="${TURNIP_URL:-https://github.com/lfdevs/mesa-for-android-container/releases/download/${TURNIP_TAG}/${TURNIP_ASSET}}"
TURNIP_LIB_REL="${TURNIP_LIB_REL:-usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so}"

# --- versions of the SDK components built from source ------------------
VULKAN_HEADERS_REF="${VULKAN_HEADERS_REF:-v1.4.361}"
VULKAN_HPP_REF="${VULKAN_HPP_REF:-v1.4.361}"
GLSLANG_REF="${GLSLANG_REF:-16.5.0}"

# --- llama.cpp (optional stage 60) --------------------------------------
LLAMA_DIR="${LLAMA_DIR:-/data/llamacpp}"
LLAMA_JOBS="${LLAMA_JOBS:-$(nproc)}"

# --- the three mandatory runtime environment variables -----------------
# These are THE magic. Without them the loader falls back to llvmpipe (CPU):
#   LD_PRELOAD        — satisfies __isoc23_* symbols (noble build, jammy glibc)
#   VK_ICD_FILENAMES  — points the loader at the patched turnip ICD
#   TU_DEBUG=startkgsl— tells turnip to talk to /dev/kgsl-3d0 directly
#                       instead of probing /dev/dri/renderD* (which is the
#                       display controller, not a GPU, on Android hosts)
export LD_PRELOAD="${LD_PRELOAD:-$TURNIP_DIR/shim.so}"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-$TURNIP_DIR/turnip-local.json}"
export TU_DEBUG="${TU_DEBUG:-startkgsl}"

# Derived: the driver library itself
TURNIP_LIB="$TURNIP_DIR/$TURNIP_LIB_REL"
export TURNIP_LIB

# --- KGSL sysfs paths (docs/docs/kgsl-sysfs.md documents each file) -----
KGSL_SYSFS="${KGSL_SYSFS:-/sys/class/kgsl/kgsl-3d0}"

# Helper: run a command with the GPU environment, printing it first.
with_gpu_env() {
  echo "[gpu-env] LD_PRELOAD=$LD_PRELOAD"
  echo "[gpu-env] VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
  echo "[gpu-env] TU_DEBUG=$TU_DEBUG"
  "$@"
}

# Summary line used by several scripts.
gpu_env_summary() {
  echo "LD_PRELOAD=$LD_PRELOAD"
  echo "VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
  echo "TU_DEBUG=$TU_DEBUG"
}
