# droidspaces-gpu

[![CI](https://github.com/ZxAlif-ID/droidspaces-gpu/actions/workflows/ci.yml/badge.svg)](https://github.com/ZxAlif-ID/droidspaces-gpu/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%2B%20Ubuntu%20arm64-blue)](docs/architecture.md)
[![GPU](https://img.shields.io/badge/GPU-Adreno%20735%20%28a7xx%29-green)](docs/architecture.md)

**Use the real mobile Adreno GPU inside a Droidspaces / proot-Ubuntu rootfs —
not llvmpipe, not emulation — through Mesa's turnip Vulkan driver talking
directly to the kernel KGSL device (`/dev/kgsl-3d0`).**

Everything in this repository was executed and verified on the target device.
No step is theoretical.

## Verified on

| Item | Value |
|---|---|
| Host kernel | Android GKI `6.1.138-android14` (aarch64) |
| Rootfs | Ubuntu 22.04.5 LTS (jammy), glibc 2.35 |
| GPU | Qualcomm Adreno 735 (SM8635-class, max clock 900 MHz) |
| Driver | turnip 26.3.0-devel (Mesa), backend **kgsl** |
| Vulkan API | 1.4.359 (loader 1.3.204 from apt works fine) |
| Verification | `vulkaninfo --summary` + a real compute dispatch, 256/256 values correct |

```
deviceName  = Turnip Adreno (TM) 735
deviceType  = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
driverID    = DRIVER_ID_MESA_TURNIP
driverInfo  = Mesa 26.3.0-devel (git-c6b1aa3428)
apiVersion  = 1.4.359
```

## Table of contents

- [What problem this solves](#what-problem-this-solves)
- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Using the GPU from any program](#using-the-gpu-from-any-program)
- [Verification](#verification)
- [Repository structure](#repository-structure)
- [Results measured on the reference device](#results-measured-on-the-reference-device)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)
- [Citing this project](#citing-this-project)

## What problem this solves

A stock Droidspaces Ubuntu rootfs **cannot use the phone's GPU**. Five
independent walls stand in the way (details in
[docs/architecture.md](docs/architecture.md)):

1. **`vulkaninfo` only shows llvmpipe** — Ubuntu 22.04 ships Mesa 23.2.1,
   whose turnip predates Adreno a7xx support and has no kgsl backend.
2. **`/dev/dri/renderD128` is not a GPU** — on Android hosts it is the
   display controller (MSM/DPU). There is no DRM render node for the GPU;
   kgsl is the only door.
3. **The proprietary Adreno driver is unreachable** — `/vendor` is not
   mounted in the rootfs, and `libvulkan_adreno.so` needs Android bionic
   libraries that do not exist here.
4. **Modern turnip builds don't load on jammy** — upstream publishes only
   noble/trixie/fedora/arch/alpine packages; the noble build requires
   `GLIBC_2.38` symbols that glibc 2.35 does not have.
5. **The Vulkan shader toolchain from apt is too old** — glslang 11.8 and
   Vulkan-Hpp 1.3.204 cannot compile modern compute shaders (missing
   `GL_GOOGLE_include_directive`, `vk::LayerSettingEXT`, …).

This repository removes all five walls with an idempotent, staged installer
and documents every mechanism so the next port is trivial.

## How it works

The stack, bottom to top:

```
+----------------------------------------------------------+
|  your program (Vulkan app / llama.cpp / own compute)     |
+----------------------------------------------------------+
|  Vulkan loader (apt libvulkan1, driver-independent)      |
+----------------------------------------------------------+
|  turnip 26.3 (noble build, glibc-patched)  ICD json      |
|  + shim.so (__isoc23_* symbols)  via LD_PRELOAD          |
+----------------------------------------------------------+
|  TU_DEBUG=startkgsl  ->  /dev/kgsl-3d0 (KGSL kernel API) |
+----------------------------------------------------------+
|  Android GKI kernel, Adreno 735                          |
+----------------------------------------------------------+
```

Three environment variables make it all work — they are the entire contract:

```bash
export LD_PRELOAD=/opt/turnip/shim.so                 # glibc 2.38 -> 2.35 symbol shim
export VK_ICD_FILENAMES=/opt/turnip/turnip-local.json # loader -> patched turnip
export TU_DEBUG=startkgsl                             # turnip -> /dev/kgsl-3d0
```

`scripts/gpu-env.sh` sets them (and more) in one `source`.

## Quick start

Requirements: a Droidspaces (or Termux-proot) Ubuntu **22.04** aarch64 rootfs
with `/dev/kgsl-3d0` exposed, root in the rootfs, internet for the first run.

```bash
git clone https://github.com/ZxAlif-ID/droidspaces-gpu.git
cd droidspaces-gpu

# 0. sanity-check the environment (read-only)
sudo bash scripts/00-preflight.sh

# 1. full install (stages 00-50 + 70; llama.cpp excluded)
sudo ./install.sh

# 2. verify: enumeration + a real compute dispatch on the GPU
source scripts/gpu-env.sh
bash scripts/70-verify.sh
```

Expected verification output ends with:

```
  PASS  turnip exposes the Adreno physical device
  PASS  driverID is MESA_TURNIP (not llvmpipe/lvp, not zink)
  PASS  compute demo executed on the GPU and returned correct results
  PASS  kgsl sysfs reachable (kernel sees the GPU)
verification: ALL PASS — Adreno GPU is enumerated, usable, and computing.
```

Optional: build llama.cpp against the stack (the installer treats it as a
workload, not as a GPU test):

```bash
sudo ./install.sh --with-llama
```

Stages can be re-run individually (`--start-at 40`) and are idempotent.

## Using the GPU from any program

Any Vulkan program works once `scripts/gpu-env.sh` is sourced:

```bash
source scripts/gpu-env.sh

vulkaninfo --summary                 # enumerate: expect Turnip Adreno (TM) 7xx

# the bundled demo: real compute, CPU-verified result
DEMO_SHADER=const demo/build/gpu-demo   # write-path probe (42.0 everywhere)
demo/build/gpu-demo                  # math kernel: v[i] = v[i]^2 + i
```

Build the demo yourself (needs `cmake`, `gcc`, `libvulkan-dev`, and
`demo/gen_header.sh` run once to embed SPIR-V):

```bash
cd demo && ./gen_header.sh && cmake -S . -B build && cmake --build build
```

Build your own Vulkan compute app against the loader as usual — the driver
is selected at runtime by the ICD, the loader never needs to know.

llama.cpp users: see [docs/llama-workload.md](docs/llama-workload.md). Policy
on the reference device: llama is a **workload**, not a GPU test —
`vulkaninfo` + the compute demo are the test (see that document for why).

## Verification

| # | Proof | Command |
|---|---|---|
| 1 | Physical device is the real Adreno via turnip | `vulkaninfo --summary` |
| 2 | A compute pipeline dispatches and computes correctly (result checked element-by-element against a CPU reference) | `demo/build/gpu-demo` |
| 3 | Kernel-side GPU state is live (model, clock, busy %, temperature) | `cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage` |
| 4 | Optional: real workload consumes the GPU at 40-90% busy | llama.cpp `-ngl 99` (see docs/llama-workload.md) |

## Repository structure

```
.
├── install.sh                  # staged, idempotent entrypoint
├── scripts/
│   ├── gpu-env.sh              # canonical environment (source me)
│   ├── 00-preflight.sh         # fail-fast environment sanity check
│   ├── 10-install-deps.sh      # apt bootstrap packages
│   ├── 20-install-turnip.sh    # fetch + unpack turnip (noble build)
│   ├── 30-patch-glibc.sh       # shim + patchelf + string/verneed patch
│   ├── 40-build-vulkan-sdk.sh  # Vulkan-Headers/Hpp + glslang 16.5 from source
│   ├── 50-glslc-shim.sh        # glslc -> glslangValidator wrapper
│   ├── 60-build-llama-cpp.sh   # OPTIONAL llama.cpp Vulkan build
│   ├── 70-verify.sh            # full verification pass
│   └── shim.c                  # __isoc23_* shim source
├── demo/                       # minimal Vulkan compute demo (C, no deps beyond loader)
│   ├── gpu_demo.c              # instance -> device -> buffer -> dispatch -> verify
│   ├── shader.comp             # v[i] = v[i]^2 + i
│   ├── shader_const.comp       # v[i] = 42.0 (write-path probe)
│   └── gen_header.sh           # compile shaders -> SPIR-V -> C header
├── docs/
│   ├── architecture.md         # the 5 walls + full stack explanation
│   ├── glibc-compat.md         # every patch step, byte-level
│   ├── kgsl-sysfs.md           # kernel GPU interface reference
│   ├── llama-workload.md       # llama.cpp on Adreno: config + policy
│   └── troubleshooting.md      # every failure mode we have hit
├── .github/workflows/ci.yml    # shellcheck + syntax + demo build
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── SECURITY.md
├── CITATION.cff
└── LICENSE
```

## Results measured on the reference device

Reference hardware: Xiaomi POCO F6-class (SM8635), Adreno 735, 8 GB RAM
shared with the GPU, 8-core CPU.

| Workload | GPU (Vulkan) | CPU (8 threads) | Notes |
|---|---|---|---|
| llama.cpp Gemma-3-1B Q4, generate | ~12 tok/s | ~8 tok/s | `-ngl 99`; GPU busy 47-82% during generation |
| llama.cpp Gemma-3-1B Q4, prompt eval | ~10 tok/s | ~30 tok/s | GPU loses on short prompts — normal for Vulkan on small models |

Compute demo (bundled): 256/256 values correct, ~20 ms wall including
device init.

Measured limitations (also documented in docs/llama-workload.md):

- GPU advantage on 1B models is ~1.5x, not dramatic — CPU<->GPU transfer
  overhead eats part of the win. Larger models (3B-8B) gain more.
- The GPU test must be `vulkaninfo` + compute demo, **not** llama
  inference — on this device llama-server adds interactive lag far beyond
  its compute value for small models.

## Known limitations

- **aarch64 only** — turnip tarballs from upstream are aarch64-only.
- **glibc 2.35 is the verified target** — the shim + ELF patch target
  exactly 2.35 (jammy). On 24.04+ the noble package loads unpatched (skip
  stage 30); other glibc versions are unverified.
- **No graphics paths tested** — everything here is compute-only
  (`TU_DEBUG=startkgsl`, no windowing system). GLES/Wayland are out of
  scope.
- **The GPU is shared with Android** — the phone's own compositor and apps
  compete for the same Adreno; expect latency spikes during screen
  interaction.
- **kgsl sysfs availability varies** — some Android builds restrict
  `/sys/class/kgsl/*`; verification stage 3 degrades gracefully.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) — it catalogs every
failure mode encountered while building this stack, including the two
Vulkan API pitfalls that silently no-op a compute demo (passing `&handle`
instead of `handle`, and missing descriptor updates) and the
`vulkan-shaders-gen` stderr quirk that makes glslc builds fail at exit 0.

## Contributing

PRs welcome — read [CONTRIBUTING.md](CONTRIBUTING.md) first. Good first
issues: newer Mesa/turnip version bumps, additional glibc targets, a
porting guide for Debian trixie rootfs.

## License

[MIT](LICENSE) — the code in this repository. Upstream components
(turnip/Mesa, glslang, llama.cpp, Vulkan samples) keep their own licenses;
this repository only ships glue, patches described in text, and a
self-written demo.

## Citing this project

See [CITATION.cff](CITATION.cff) or:

```bibtex
@software{droidspaces_gpu_2026,
  author  = {ZxAlif-ID},
  title   = {droidspaces-gpu: real Adreno GPU access from Droidspaces Ubuntu rootfs},
  year    = {2026},
  url     = {https://github.com/ZxAlif-ID/droidspaces-gpu}
}
```

## Acknowledgments

- [lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container) — prebuilt turnip tarballs for Android-container rootfs
- [Mesa turnip](https://gitlab.freedesktop.org/mesa/mesa) — the open Adreno Vulkan driver and its kgsl backend
- [KhronosGroup](https://github.com/KhronosGroup) — Vulkan-Headers, Vulkan-Hpp, glslang
- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) — the practical workload that proved the stack
