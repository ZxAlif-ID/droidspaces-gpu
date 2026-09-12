#!/usr/bin/env bash
# 00-preflight.sh — fail fast if this host can never use an Adreno GPU
# through turnip+kgsl. Read-only: changes nothing.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gpu-env.sh
source "$HERE/gpu-env.sh"

ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; }
bad()  { echo "  FAIL  $*"; FAILURES=$((FAILURES+1)); }
FAILURES=0

echo "== droidspaces-gpu preflight =="

# --- architecture -------------------------------------------------------
case "$(uname -m)" in
  aarch64|arm64) ok "architecture: $(uname -m)" ;;
  *) bad "architecture $(uname -m) — turnip tarballs are aarch64 only" ;;
esac

# --- OS / glibc ---------------------------------------------------------
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}${VERSION_ID:-}" in
    ubuntu22.04) ok "OS: Ubuntu 22.04 (the fully documented base)" ;;
    ubuntu24.04) warn "Ubuntu 24.04: turnip noble packages load unpatched —
              skip stage 30, set LD_PRELOAD only if needed" ;;
    ubuntu*)     warn "Ubuntu ${VERSION_ID:-?}: untested; 22.04 path is the verified one" ;;
    debian*)     warn "Debian ${VERSION_ID:-?}: untested; jammy path may work" ;;
    *)           warn "OS ${PRETTY_NAME:-unknown}: untested" ;;
  esac
else
  warn "/etc/os-release unreadable"
fi

GLIBC_VER="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
case "${GLIBC_VER:-0}" in
  2.35)        ok "glibc $GLIBC_VER — matches the patched-driver target" ;;
  2.3[6-9]|2.4*) ok "glibc $GLIBC_VER — modern; noble driver may load as-is" ;;
  0)           warn "could not detect glibc version" ;;
  *)           bad "glibc $GLIBC_VER — shim targets 2.35; other minors unverified" ;;
esac

# --- Android kernel (KGSL) ----------------------------------------------
KREL="$(uname -r)"
case "$KREL" in
  *android*) ok "kernel: $KREL (Android GKI) — KGSL expected" ;;
  *)         warn "kernel $KREL is not an Android kernel — /dev/kgsl-3d0 will not exist" ;;
esac

# --- GPU device node ----------------------------------------------------
if [ -e /dev/kgsl-3d0 ]; then
  ok "/dev/kgsl-3d0 present ($(ls -l /dev/kgsl-3d0 | awk '{print $1, $4}') )"
  if [ -r "/sys/class/kgsl/kgsl-3d0/gpu_model" ]; then
    ok "GPU model: $(cat /sys/class/kgsl/kgsl-3d0/gpu_model)"
  else
    warn "kgsl sysfs missing — GPU node exists but sysfs API differs"
  fi
else
  bad "/dev/kgsl-3d0 missing — this container has no GPU access.
        Ask the Droidspaces operator to expose it (device allowlist)."
fi

# --- display controller trap --------------------------------------------
if ls /dev/dri/renderD* >/dev/null 2>&1; then
  for n in /dev/dri/renderD*; do
    drv="$(cat "$n/device/uevent" 2>/dev/null | grep '^DRIVER=' || true)"
    case "$drv" in
      *msm_drm*) warn "$n is a display controller ($drv), NOT a GPU render node
              (this is the trap this repo exists to document)" ;;
      *) warn "$n present ($drv)" ;;
    esac
  done
else
  ok "no /dev/dri/renderD* (expected on Android hosts — kgsl path is the way)"
fi

# --- tools needed later --------------------------------------------------
for t in curl tar cmake gcc patchelf python3 git; do
  command -v "$t" >/dev/null 2>&1 && ok "tool: $t" \
    || bad "tool missing: $t (stage 10 installs it)"
done

# --- verdict -------------------------------------------------------------
echo
if (( FAILURES )); then
  echo "preflight: $FAILURES blocking failure(s) — fix above, then re-run."
  exit 1
fi
echo "preflight: no blockers. Environment is a valid droidspaces-gpu target."
