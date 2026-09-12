#!/usr/bin/env bash
# 20-install-turnip.sh — fetch the noble turnip Vulkan driver tarball and
# unpack it into $TURNIP_DIR. Does NOT touch system Mesa.
#
# Why the noble tarball: Mesa's turnip gained Adreno a7xx support (a735
# included) and the kgsl backend (direct /dev/kgsl-3d0 access, no DRI3
# render node needed) only after the versions Ubuntu 22.04 ships (Mesa
# 23.2.1). Upstream publishes jammy packages for none of these, so we take
# the noble (glibc 2.38) build and patch it for jammy (glibc 2.35) in stage 30.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gpu-env.sh
source "$HERE/gpu-env.sh"

LIB="$TURNIP_DIR/$TURNIP_LIB_REL"

if [ -f "$LIB" ]; then
  echo "turnip already installed: $LIB"
  echo "  size: $(du -h "$LIB" | cut -f1)"
  echo "  (delete $TURNIP_DIR to force a re-download)"
  exit 0
fi

echo "== downloading turnip =="
echo "  tag:    $TURNIP_TAG"
echo "  asset:  $TURNIP_ASSET"
echo "  url:    $TURNIP_URL"

TMP="$(mktemp -d /tmp/turnip.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

curl -fSL --retry 3 -o "$TMP/$TURNIP_ASSET" "$TURNIP_URL"
echo "  downloaded: $(du -h "$TMP/$TURNIP_ASSET" | cut -f1)"

# Verify it is a real gzip tarball (catches HTML error pages from proxies).
if ! tar -tzf "$TMP/$TURNIP_ASSET" >/dev/null 2>&1; then
  echo "ERROR: downloaded file is not a tar.gz — aborting" >&2
  head -c 300 "$TMP/$TURNIP_ASSET" >&2 || true
  exit 1
fi

mkdir -p "$TURNIP_DIR"
tar -xzf "$TMP/$TURNIP_ASSET" -C "$TURNIP_DIR"

# Keep a pristine copy — stage 30 patches the .so in place and having the
# original around makes the patch diffable / re-runnable.
if [ -f "$LIB" ] && [ ! -f "$LIB.bak" ]; then
  cp -a "$LIB" "$LIB.bak"
  echo "  pristine copy saved: $LIB.bak"
fi

echo "== turnip installed =="
ls -la "$LIB" "$TURNIP_DIR/$TURNIP_LIB_REL.bak" 2>/dev/null || ls -la "$LIB"
echo
echo "Next: stage 30 patches this library for glibc 2.35."
