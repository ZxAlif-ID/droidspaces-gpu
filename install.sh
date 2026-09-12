#!/usr/bin/env bash
# droidspaces-gpu — entrypoint installer
#
# Turns a stock Droidspaces / Ubuntu 22.04 (jammy) aarch64 rootfs into an
# environment where the mobile Adreno GPU (/dev/kgsl-3d0) is usable from
# userspace through Mesa's turnip Vulkan driver.
#
# Stages (run in order, each idempotent, each skippable):
#   00  preflight        — sanity-check the environment we are running on
#   10  install-deps     — apt packages needed by every later stage
#   20  install-turnip   — fetch the noble turnip tarball into /opt/turnip
#   30  patch-glibc      — make the noble-built driver load on glibc 2.35
#   40  build-vulkan-sdk — modern Vulkan-Headers/Hpp + glslang into /opt/vulkan-sdk
#   50  glslc-shim       — /usr/local/bin/glslc wrapper around glslangValidator
#   60  build-llama-cpp  — OPTIONAL llama.cpp Vulkan build (not needed for GPU itself)
#   70  verify           — full verification pass incl. a real compute dispatch
#
# Usage:
#   sudo ./install.sh                 # everything except llama.cpp
#   sudo ./install.sh --with-llama    # also build llama.cpp Vulkan
#   sudo ./install.sh --start-at 40   # re-run from a given stage
#   sudo ./install.sh --dry-run      # list stages without executing
#
# Safe to re-run: every stage detects prior work and skips or redoes it.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$REPO_ROOT/scripts"

# Load shared defaults (OVERWRITE with env vars to customise).
# shellcheck source=scripts/gpu-env.sh
source "$SCRIPTS/gpu-env.sh"

WITH_LLAMA=0
START_AT="00"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with-llama) WITH_LLAMA=1; shift ;;
    --start-at)   START_AT="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

run_stage() {
  local n="$1" script="$2" desc="$3"
  if (( DRY_RUN )); then
    echo "[$n] $desc  (script: $script)"
    return 0
  fi
  log "[$n] $desc"
  bash "$SCRIPTS/$script" || fail "stage $n ($script) failed — see output above"
}

log "droidspaces-gpu installer"
echo "  repo:        $REPO_ROOT"
echo "  turnip dir:  $TURNIP_DIR"
echo "  vulkan-sdk:  $VULKAN_SDK_DIR"
echo "  with llama:  $WITH_LLAMA"
echo "  start at:    $START_AT"

declare -a NUM=(00 10 20 30 40 50 60 70)
declare -a SCR=(00-preflight.sh 10-install-deps.sh 20-install-turnip.sh \
                30-patch-glibc.sh 40-build-vulkan-sdk.sh 50-glslc-shim.sh \
                60-build-llama-cpp.sh 70-verify.sh)
declare -a DSC=("preflight environment check"
                "install apt dependencies"
                "fetch and unpack turnip driver"
                "patch driver for glibc 2.35 (shim + ELF edits)"
                "build Vulkan-Headers / Vulkan-Hpp / glslang"
                "install glslc shim wrapper"
                "build llama.cpp with Vulkan backend"
                "full verification (vulkaninfo + compute demo)")

started=0
for i in "${!NUM[@]}"; do
  n="${NUM[$i]}"
  # ${n#0} strips the leading zero so 10#$n parses (10#00 is invalid in bash).
  if (( 10#${n#0} < 10#${START_AT#0} )); then
    continue
  fi
  started=1
  # Stage 60 is optional.
  if [ "$n" = "60" ] && (( ! WITH_LLAMA )); then
    echo "[$n] skipped ($WITH_LLAMA=0 — pass --with-llama to include llama.cpp)"
    continue
  fi
  run_stage "$n" "${SCR[$i]}" "${DSC[$i]}"
done

(( started )) || fail "START_AT=$START_AT matches no stage"

if (( DRY_RUN )); then
  log "dry run complete — no changes were made"
else
  log "ALL STAGES COMPLETE"
  echo "Load the GPU environment in any future shell with:"
  echo "  source $SCRIPTS/gpu-env.sh"
  echo "Then confirm with:  vulkaninfo --summary | grep deviceName"
fi
