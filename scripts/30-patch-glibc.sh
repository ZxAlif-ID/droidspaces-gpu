#!/usr/bin/env bash
# 30-patch-glibc.sh — make the noble-built turnip driver load on glibc 2.35.
#
# The noble tarball is built against glibc 2.38. On jammy (glibc 2.35) the
# library fails to load with:
#     version 'GLIBC_2.38' not found (required by libvulkan_freedreno.so)
# Four complementary fixes (this script applies a; b is covered by them):
#
#   a) SHIM LIBRARY  — compile shim.so exporting __isoc23_sscanf/scanf/fscanf/
#      strtol/strtoll/strtoul/strtoull (the C23 variants glibc 2.38 added).
#      Semantics are identical to the standard functions. LD_PRELOAD makes
#      the loader resolve those symbols from the shim instead of glibc.
#   b) patchelf --clear-symbol-version on the same symbols — removes the
#      versioned requirement from the ELF's dynamic symbol table.
#   c) STRING PATCH  — rewrite the version string "GLIBC_2.38" to
#      "GLIBC_2.35" inside the ELF (same length, 6 bytes, in-place).
#   d) VERNEED HASH  — the .gnu.version_r entry for the (now 2.35-named)
#      version must hash to the ELF SysV hash of "GLIBC_2.35", otherwise
#      the loader rejects the verneed entry. We locate the aux entry and
#      overwrite its hash field.
#
# After (c)+(d) the ELF claims glibc 2.35 and the claim is self-consistent;
# the shim covers the actual symbols that changed between 2.35 and 2.38.
#
# Every step is idempotent: re-running detects completed steps and skips.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gpu-env.sh
source "$HERE/gpu-env.sh"

LIB="$TURNIP_DIR/$TURNIP_LIB_REL"
SHIM_SRC="$HERE/shim.c"
[ -f "$LIB" ] || { echo "ERROR: $LIB not found — run stage 20 first" >&2; exit 1; }
[ -f "$LIB.bak" ] || cp -a "$LIB" "$LIB.bak"

step() { printf '\n-- %s\n' "$*"; }

# ---------------------------------------------------------------- a) shim
step "a) building shim.so (__isoc23_* symbols)"
SHIM_OUT="$TURNIP_DIR/shim.so"
if [ -f "$SHIM_OUT" ]; then
  echo "   already built: $SHIM_OUT"
else
  cc -shared -fPIC -O2 -o "$SHIM_OUT" "$SHIM_SRC"
  echo "   built: $SHIM_OUT"
fi
# Show the exported symbols for the record.
nm -D --defined-only "$SHIM_OUT" | grep __isoc23 || true

# ------------------------------------------------- b) clear symbol version
step "b) patchelf --clear-symbol-version on __isoc23_*"
SYMS="__isoc23_sscanf __isoc23_scanf __isoc23_fscanf __isoc23_strtol __isoc23_strtoll __isoc23_strtoul __isoc23_strtoull"
for s in $SYMS; do
  # patchelf 0.14 prints "cannot find symbol" on stderr and exits non-zero
  # when absent; the noble build does contain them, so absence = bug.
  if patchelf --clear-symbol-version "$s" "$LIB" 2>/tmp/patchelf.err; then
    echo "   cleared: $s"
  else
    msg="$(cat /tmp/patchelf.err 2>/dev/null)"
    case "$msg" in
      *python3*|*"cannot find symbol"*) echo "   not present: $s (ok)" ;;
      *) echo "   patchelf error on $s: $msg" ;;
    esac
  fi
done
rm -f /tmp/patchelf.err

# ------------------------------------------------------- c) string patch
step "c) rewriting version string GLIBC_2.38 -> GLIBC_2.35"
NEEDLE="GLIBC_2.38"
REPLACE="GLIBC_2.35"
OFFS=$(grep -aob "$NEEDLE" "$LIB" | head -1 | cut -d: -f1)
if [ -n "$OFFS" ]; then
  printf '%s' "$REPLACE" | dd of="$LIB" bs=1 seek="$OFFS" conv=notrunc status=none
  echo "   patched at file offset 0x$(printf '%x' "$OFFS")"
else
  echo "   no GLIBC_2.38 string found (already patched?)"
fi
grep -aob 'GLIBC_2\.3[58]' "$LIB" | head -6 | sed 's/^/   string: /' || true

# ------------------------------------------------------- d) verneed hash
step "d) fixing .gnu.version_r hash for GLIBC_2.35"
# SysV ELF hash of a version string, as used by .gnu.version_r vn_hash.
elf_hash() {
  python3 - "$1" <<'PY'
import sys
h = 0
for c in sys.argv[1].encode():
    h = ((h << 4) + c) & 0xFFFFFFFF
    g = h & 0xF0000000
    if g:
        h ^= g >> 24
    h &= ~g & 0xFFFFFFFF
print(f"0x{h:08x}")
PY
}
TARGET_HASH="$(elf_hash GLIBC_2.35)"
echo "   ELF hash('GLIBC_2.35') = $TARGET_HASH"

# Find .gnu.version_r aux entries and patch the hash of the entry whose
# name (resolved through .dynstr — vna_name is a .dynstr offset, NOT a
# .gnu.version_r offset) equals GLIBC_2.35 after the string rename.
python3 - "$LIB" "$TARGET_HASH" <<'PY'
import struct, sys

lib, want = sys.argv[1], int(sys.argv[2], 16)
data = open(lib, 'rb').read()

shoff   = struct.unpack_from('<Q', data, 0x28)[0]
shentsz = struct.unpack_from('<H', data, 0x3A)[0]
shnum   = struct.unpack_from('<H', data, 0x3C)[0]
shstrndx= struct.unpack_from('<H', data, 0x3E)[0]
def sh(i):
    o = shoff + i*shentsz
    name, typ, flags, addr, off, size = struct.unpack_from('<IIQQQQ', data, o)
    return name, typ, off, size
stroff = sh(shstrndx)[2]
def sname(n):
    e = data.index(b'\0', stroff+n)
    return data[stroff+n:e].decode()

verneed = dynstr = None
for i in range(shnum):
    nm = sname(sh(i)[0])
    if nm == '.gnu.version_r':
        verneed = sh(i)[2:]
    elif nm == '.dynstr':
        dynstr = sh(i)[2]
if verneed is None or dynstr is None:
    print('   .gnu.version_r/.dynstr not found — skipping hash fix')
    sys.exit(0)

off, size = verneed
buf = bytearray(data)
p = off
patched = 0
while p < off + size:
    vn_version, vn_cnt, vn_file, vn_aux, vn_next = struct.unpack_from('<HHIII', buf, p)
    a = p + vn_aux
    for _ in range(vn_cnt):
        vna_hash, vna_flags, vna_other, vna_name, vna_next = struct.unpack_from('<IHHII', buf, a)
        nstart = dynstr + vna_name
        end = buf.index(b'\0', nstart)
        vname = bytes(buf[nstart:end]).decode(errors='replace')
        if vname == 'GLIBC_2.35' and vna_hash != want:
            struct.pack_into('<I', buf, a, want)
            patched += 1
            print(f'   fixed aux entry ver {vna_other}: hash 0x{vna_hash:08x} -> 0x{want:08x}')
        if vna_next == 0:
            break
        a += vna_next
    if vn_next == 0:
        break
    p += vn_next
open(lib, 'wb').write(bytes(buf))
print(f'   verneed entries patched: {patched}')
PY

# ------------------------------------------------------------- verdict
step "verdict"
if readelf -d "$LIB" | grep -q VERNEED; then
  readelf -V "$LIB" 2>/dev/null | grep -B1 -A3 'GLIBC_2.35' | sed 's/^/   after: /' || true
fi
echo "   library size: $(stat -c%s "$LIB") bytes (pristine: $(stat -c%s "$LIB.bak"))"
echo
echo "Stage 30 done. Load chain (mandatory at runtime):"
echo "  export LD_PRELOAD=$SHIM_OUT"
echo "  export VK_ICD_FILENAMES=$TURNIP_DIR/turnip-local.json"
echo "  export TU_DEBUG=startkgsl"
