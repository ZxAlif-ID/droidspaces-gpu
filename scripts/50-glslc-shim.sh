#!/usr/bin/env bash
# 50-glslc-shim.sh — install /usr/local/bin/glslc, a wrapper translating
# glslc (shaderc) flags to glslangValidator >= 14.
#
# Why: Vulkan SDK's glslc is not published for jammy arm64, but build systems
# that compile Vulkan compute shaders (llama.cpp's vulkan-shaders-gen) call
# `glslc`. This wrapper bridges the gap:
#   -fshader-stage=X      -> -S X (and stage inferred from extension)
#   --target-env=vulkanN  -> --target-env vulkanN
#   -O / -MD / -MF        -> ignored (glslangValidator has no equivalent)
#   #include in shader    -> auto-inject '#extension GL_GOOGLE_include_directive
#                            : enable' after #version (glslc enables this
#                            implicitly, glslangValidator does not)
#   -I<dir>               -> -I<dir of input file> (implicit include dir)
# Critical: on SUCCESS, stderr is silenced — glslangValidator echoes the
# input filename to stdout, and vulkan-shaders-gen treats any non-empty
# stderr as failure ("cannot compile X (exit code 0)"). On failure stderr
# is passed through untouched.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gpu-env.sh
source "$HERE/gpu-env.sh"

if [ -x "$GLSLC_SHIM" ]; then
  echo "glslc shim already installed: $GLSLC_SHIM"
  head -3 "$GLSLC_SHIM"
  exit 0
fi

echo "== installing glslc shim -> $GLSLC_SHIM =="
SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"

$SUDO tee "$GLSLC_SHIM" > /dev/null <<'WRAPPER'
#!/bin/bash
# glslc shim — translate glslc flags to glslangValidator (>=14).
# Installed by droidspaces-gpu stage 50. See scripts/50-glslc-shim.sh.
G=/opt/vulkan-sdk/bin/glslangValidator
[ -x "$G" ] || G=glslangValidator
args=()
prev=""
stage="comp"
in_file=""
for a in "$@"; do
  if [ "$prev" = "MF" ]; then prev=""; continue; fi
  case "$a" in
    -fshader-stage=*) stage="${a#-fshader-stage=}" ;;
    --target-env=*)   args+=( "--target-env" "${a#--target-env=}" ) ;;
    -MD)              : ;;
    -MF)              prev="MF" ;;
    -MF*)             : ;;
    -O)               : ;;
    -o)               args+=( "-o" ) ;;
    *.comp)           stage="comp"; in_file="$a" ;;
    *.vert)           stage="vert"; in_file="$a" ;;
    *.frag)           stage="frag"; in_file="$a" ;;
    *)                args+=( "$a" ) ;;
  esac
done
shdir=$(dirname "$(readlink -f "$in_file")")
if grep -q '#include' "$in_file" && ! grep -q 'GL_GOOGLE_include_directive' "$in_file"; then
    tmp=$(mktemp /tmp/glslc-XXXXXX."${in_file##*.}")
    { head -1 "$in_file"; echo '#extension GL_GOOGLE_include_directive : enable'; tail -n +2 "$in_file"; } > "$tmp"
    in_file="$tmp"
fi
errf=$(mktemp /tmp/glslc-err-XXXXXX)
"$G" --target-env vulkan1.2 -S "$stage" -I"$shdir" "$in_file" "${args[@]}" 2> "$errf"
rc=$?
if [ $rc -ne 0 ]; then cat "$errf" >&2; fi
rm -f "$errf" "$tmp" 2>/dev/null
exit $rc
WRAPPER

$SUDO chmod +x "$GLSLC_SHIM"
echo "installed: $GLSLC_SHIM"
echo
echo "smoke test (compile a trivial shader):"
TMPD="$(mktemp -d)"
printf '#version 450\nlayout(local_size_x=1) in;\nvoid main(){}\n' > "$TMPD/t.comp"
if "$GLSLC_SHIM" "$TMPD/t.comp" -o "$TMPD/t.spv"; then
  echo "  OK — glslc shim works ($(du -h "$TMPD/t.spv" | cut -f1) SPIR-V)"
else
  echo "  FAILED — shim could not compile a trivial compute shader" >&2
  exit 1
fi
rm -rf "$TMPD"
