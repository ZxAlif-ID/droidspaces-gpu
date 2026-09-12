# Architecture: how an Android GPU becomes usable from an Ubuntu rootfs

This document explains the full causal chain — every wall between a stock
Droidspaces rootfs and the Adreno GPU, and exactly how this project removes
each one.

## The hardware/kernel side

The phone's GPU (here: Adreno 735, a7xx family) is driven by Qualcomm's
**KGSL** kernel driver (GPU Sleep/Command Subsystem, `/dev/kgsl-3d0`).
Userspace talks to it via ioctls on that character device. Two sysfs trees
expose its state: `/sys/class/kgsl/kgsl-3d0/` (clocks, busy %, temperature —
see [kgsl-sysfs.md](kgsl-sysfs.md)) and `/sys/class/kgsl/kgsl-gpu-0/` on
some builds (devfreq).

On a **normal Android** system, apps use the GPU through the proprietary
driver `libvulkan_adreno.so` (from `/vendor`) or GLES via the Android
graphics stack. Both are bionic-linked and unavailable in a glibc rootfs.

## Wall 1: `vulkaninfo` only shows llvmpipe

Ubuntu 22.04 ships **Mesa 23.2.1**. Turnip (Mesa's open Adreno Vulkan
driver) in that version:

- has **no Adreno a7xx support** — the a735 appeared in Mesa 24.x;
- has **no kgsl backend** — old turnip only probes DRM render nodes.

The llvmpipe (lavapipe) ICD *does* enumerate — that is the CPU renderer
faking a GPU. Anything measuring "GPU speed" against llvmpipe measures the
CPU twice.

**Fix:** turnip 26.3.0-devel from
[lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)
(stage 20), which has a7xx support and the kgsl backend.

## Wall 2: `/dev/dri/renderD128` is not a GPU

On desktop Linux, GPU apps open `/dev/dri/renderD128`. On this host that
node belongs to the **display controller**:

```
/sys/class/drm/renderD128/device/uevent:
  DRIVER=msm_drm
  OF_FULLNAME=/soc/qcom,mdss_mdp@ae00000    <- MDSS/DPU, not a GPU
```

There is **no** GPU render node on Android GKI. The only door to the GPU is
`/dev/kgsl-3d0`.

**Fix:** `TU_DEBUG=startkgsl` makes turnip skip DRI3 probing entirely and
talk to kgsl directly (stage env, set in `scripts/gpu-env.sh`).

## Wall 3: the proprietary driver is unreachable

`/vendor` is not mounted in the rootfs, and even if it were,
`libvulkan_adreno.so` dlopens bionic (`libc.so`, `libbase.so`, …) and
Android linker namespaces that do not exist under glibc. Not a config
problem — an ecosystem gap. (torch has the same gap: official torch has no
Vulkan backend, so PyTorch cannot use this GPU either.)

**Fix:** none needed — turnip replaces the proprietary driver entirely.

## Wall 4: modern turnip does not load on jammy's glibc

Upstream publishes jammy packages **for nothing**. The noble (Ubuntu 24.04)
build is compiled against **glibc 2.38** and fails on jammy (glibc 2.35)
with:

```
version 'GLIBC_2.38' not found (required by libvulkan_freedreno.so)
```

**Fix:** a four-part compat layer, applied by `scripts/30-patch-glibc.sh`
(byte-level details in [glibc-compat.md](glibc-compat.md)):

1. `shim.so` (LD_PRELOAD) exports the new `__isoc23_*` symbols with classic
   semantics;
2. `patchelf --clear-symbol-version` removes versioned requirements on the
   same symbols;
3. the version string `GLIBC_2.38` is rewritten to `GLIBC_2.35` in place
   (same length — 6 bytes);
4. the `.gnu.version_r` aux-entry hash for the renamed version is set to the
   ELF SysV hash of `GLIBC_2.35` so the loader accepts the entry.

## Wall 5: the apt shader toolchain is too old

- glslang-tools (jammy) = 11.8 — modern compute shaders fail with
  `'#include' : required extension not requested: GL_GOOGLE_include_directive`.
- libvulkan-dev (jammy) = 1.3.204 — its Vulkan-Hpp lacks
  `vk::LayerSettingEXT`, `vk::DriverId::eMesaDozen`, needed by modern
  `ggml-vulkan.cpp`.
- `glslc` (shaderc) is **not packaged** for jammy arm64 at all.
- `vulkan-shaders-gen` (llama.cpp's shader compiler driver) rejects any
  non-empty stderr even on exit 0 — and glslangValidator always echoes the
  input filename.

**Fix:** stage 40 builds Vulkan-Headers 1.4.361 + Vulkan-Hpp 1.4.361 +
glslang 16.5 (with SPIRV-Tools) into `/opt/vulkan-sdk`; stage 50 installs a
`glslc` wrapper at `/usr/local/bin/glslc` that translates glslc flags to
glslangValidator, auto-injects the include-extension, and **silences stderr
on success** (the vulkan-shaders-gen quirk).

## The kgsl door: `TU_DEBUG=startkgsl`

With the env var set, turnip opens `/dev/kgsl-3d0` directly, negotiates
ioctls with KGSL, and uses GPU virtual addressing through the kgsl
allocator. Without it, turnip probes `/dev/dri/renderD*`, finds only the
display controller, and fails. Verified on this stack: the flag is the
difference between "no Adreno device" and full Vulkan 1.4 on the GPU.

Node permissions matter: `/dev/kgsl-3d0` is `crw-rw---- root:droidspaces-gpu`
on the reference Droidspaces build. The container user must be in that group
(or be root).

## What the loader does at runtime

```
vkCreateInstance
  └─ loader reads VK_ICD_FILENAMES=/opt/turnip/turnip-local.json
       └─ dlopen /opt/turnip/usr/lib/.../libvulkan_freedreno.so
            ├─ LD_PRELOAD shim.so satisfies __isoc23_* lookups
            ├─ ELF verneed claims GLIBC_2.35 (string + hash patched)
            └─ turnip initializes: TU_DEBUG=startkgsl -> open /dev/kgsl-3d0
                 └─ KGSL ioctl handshake, Adreno 735 a7xx firmware path
```

Note the loader itself (apt `libvulkan1` 1.3.204) is *old but fine* — the
loader ABI is stable and driver-side API 1.4 works through it.

## Why an ICD with an absolute path

The jammy package `freedreno_icd.aarch64.json` points at the jammy turnip
library (old, a6xx-only). Our ICD file uses an **absolute** `library_path`
to the patched 26.3 library — no `LD_LIBRARY_PATH` games, no collision with
the apt ICD.

## Proof of real work

Enumeration alone can be faked by llvmpipe; the repo therefore requires a
**correctness-checked compute dispatch** (`demo/gpu_demo.c`): a storage
buffer is filled on the host, a compute kernel transforms it on the device,
and every element is verified against a CPU reference
(`v[i] = v[i]^2 + i`). `ALL CHECKS PASSED` only prints when the GPU
actually computed. `scripts/70-verify.sh` chains enumeration + dispatch +
kernel-side sysfs into one gate.
