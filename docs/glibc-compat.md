# glibc-compat.md — making a noble-built turnip run on jammy (glibc 2.35)

The turnip 26.3 tarball we use is built on Ubuntu noble against glibc 2.38.
Loading it on jammy (glibc 2.35) fails at `dlopen`. This document records
every mechanism of the compatibility layer, at byte level where it matters,
so the patch can be re-derived for future Mesa versions.

## Failure mode

```
$ dlopen libvulkan_freedreno.so
version 'GLIBC_2.38' not found (required by libvulkan_freedreno.so)
```

glibc refuses to load an ELF whose `.gnu.version_r` requires a version
newer than itself — and even if the *name* matched, unresolved versioned
symbols would fail one by one.

Two categories of problem, both fixed:

| Category | Cause | Fix |
|---|---|---|
| New symbols | glibc 2.38 added `__isoc23_sscanf/scanf/fscanf/strtol/strtoll/strtoul/strtoull` | shim library (LD_PRELOAD) + patchelf symbol-version clearing |
| Version metadata | `.gnu.version_r` demands `GLIBC_2.38` | string rename + verneed hash rewrite |

## Step 1 — shim.so (the symbols)

`scripts/shim.c` exports the seven `__isoc23_*` entry points. Semantics are
identical to the classic functions (C23 only changed obscure hex-float
parsing cases no driver path exercises):

```c
int  __isoc23_sscanf(const char *s, const char *fmt, ...) { ... vsscanf ... }
long __isoc23_strtol(const char *n, char **e, int b) { return strtol(n, e, b); }
/* ... etc */
```

Build: `cc -shared -fPIC -O2 -o shim.so shim.c`
Use:  `LD_PRELOAD=/opt/turnip/shim.so`

Why LD_PRELOAD and not `-l`: the driver's DT_NEEDED already lists libc;
the shim must simply win symbol resolution *before* glibc is consulted.
Preloading a tiny shared object achieves exactly that.

## Step 2 — clear the versioned symbol requirement

```
patchelf --clear-symbol-version __isoc23_sscanf   libvulkan_freedreno.so
patchelf --clear-symbol-version __isoc23_scanf    libvulkan_freedreno.so
patchelf --clear-symbol-version __isoc23_fscanf   libvulkan_freedreno.so
patchelf --clear-symbol-version __isoc23_strtol   libvulkan_freedreno.so
patchelf --clear-symbol-version __isoc23_strtoll  libvulkan_freedreno.so
patchelf --clear-symbol-version __isoc23_strtoul  libvulkan_freedreno.so
patchelf --clear-symbol-version __isoc23_strtoull libvulkan_freedreno.so
```

This removes the `GLIBC_2.38` version association from those dynamic
symbols; they become unversioned references, satisfiable by the shim.

## Step 3 — rename the version string in place

The version string `GLIBC_2.38` appears in the ELF (`.dynstr` /
`.gnu.version_r` name strings). Both strings are the same length (6 bytes
after `GLIBC_`), so a one-shot byte patch suffices:

```
find offset:      grep -aob 'GLIBC_2.38' libvulkan_freedreno.so | head -1
write:            printf 'GLIBC_2.35' | dd of=... bs=1 seek=$OFF conv=notrunc
```

On the 26.3.0-devel-20260824 noble build this string sits at file offset
`0x3c9bc` — the script locates it dynamically instead of hardcoding.

## Step 4 — fix the verneed hash

`.gnu.version_r` aux entries carry a **hash of the version string**. After
the rename the string reads `GLIBC_2.35` but the hash field still hashes
the old name; the loader verifies and rejects the mismatch. The hash is the
standard SysV ELF hash:

```python
def elf_hash(s: bytes) -> int:
    h = 0
    for c in s.encode():
        h = ((h << 4) + c) & 0xFFFFFFFF
        g = h & 0xF0000000
        if g: h ^= g >> 24
        h &= ~g & 0xFFFFFFFF
    return h
```

`elf_hash("GLIBC_2.35") = 0x69691b5`.

The script (`scripts/30-patch-glibc.sh`) parses section headers, finds
`.gnu.version_r`, walks `Verneed`/`Vernaux` entries, and — for every aux
entry whose name (resolved via **`.dynstr`**, note: `vna_name` is a
`.dynstr` offset, *not* section-relative) equals `GLIBC_2.35` — overwrites
`vna_hash` with the correct value.

Reference offsets on the 26.3 lib: verneed for libc.so.6 at file offset
`0x3dc28`, target aux entry at `0x3dcd8` — again, located dynamically.

## Verification that the patch took

```bash
# 1. no GLIBC_2.38 references remain
grep -ac 'GLIBC_2.38' libvulkan_freedreno.so   # -> 0

# 2. readelf shows a consistent 2.35 entry
readelf -V libvulkan_freedreno.so | grep -A3 GLIBC_2.35

# 3. the library actually loads (the real test)
LD_PRELOAD=shim.so python3 -c \
  "import ctypes; ctypes.CDLL('libvulkan_freedreno.so'); print('loads')"
```

## Porting notes for other glibc targets

- glibc >= 2.38 (noble, trixie): no patch needed; skip stage 30 and drop
  `LD_PRELOAD`.
- glibc 2.36/2.37: same procedure, rewrite to the matching string.
- glibc < 2.35 (e.g. focal 2.31): additionally audit which classic symbols
  the driver references (run `readelf -sW | grep UND` and diff against the
  target glibc); extend `shim.c` as needed.

Keep the pristine library (`libvulkan_freedreno.so.bak`) so patches can be
re-derived and diffed; stage 20 saves it automatically.
