# Troubleshooting — every failure mode, its cause, and its fix

All entries below were actually hit while building this stack on the
reference device. Symptoms first, causes second.

## Enumeration problems

### `vulkaninfo --summary` shows only llvmpipe/lavapipe

**Cause:** the loader did not get the ICD — `VK_ICD_FILENAMES` unset or
pointing at the jammy freedreno ICD.

**Fix:**
```bash
export VK_ICD_FILENAMES=/opt/turnip/turnip-local.json   # absolute path
vulkaninfo --summary | grep deviceName                  # expect Turnip Adreno (TM) 735
```

### `version 'GLIBC_2.38' not found` (dlopen error in vulkaninfo/log)

**Cause:** the noble turnip build needs glibc 2.38 symbols.
**Fix:** stage 30 (`shim.so` + patchelf + string/verneed patch). Verify:

```bash
LD_PRELOAD=/opt/turnip/shim.so python3 -c \
  "import ctypes; ctypes.CDLL('/opt/turnip/usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so')"
```

### Adreno absent even with env set; turnip logs "no render node"

**Cause:** without `TU_DEBUG=startkgsl` turnip probes `/dev/dri/renderD*`,
which on Android is the *display controller*, not a GPU.
**Fix:** `export TU_DEBUG=startkgsl`.

### `/dev/kgsl-3d0: Permission denied`

**Cause:** not root and not in the owning group.
**Fix:** `id` to check; the node is `root:droidspaces-gpu` — the container
user needs that group, or run as root.

### After a device reboot the GPU is "gone"

**Cause:** `/dev/kgsl-3d0` re-created with different perms, or the
container's device allowlist changed.
**Fix:** check `ls -la /dev/kgsl-3d0`; if missing, re-ask the Droidspaces
operator to expose it. Then `scripts/70-verify.sh`.

## Compute demo problems

### `vkAllocateMemory` returns `-2` (VK_ERROR_OUT_OF_DEVICE_MEMORY) for a 1 KB allocation

**Cause:** in C, `vkGetBufferMemoryRequirements(dev, &buf, &mreq)` — passing
the *address* of the `VkBuffer` variable instead of the handle. The loader
reads garbage requirements and allocation goes off the rails. (Passing the
address by accident often *seems* to work until a stack layout shifts.)
**Fix:** pass the handle: `vkGetBufferMemoryRequirements(dev, buf, &mreq)`.
Same discipline for `vkBindBufferMemory` — one of these two bugs made the
first demo run read back values the shader never touched.

### Demo runs "successfully" but output equals the input

**Cause:** the compute pipeline ran but the descriptor was never bound to
the memory you mapped — e.g. `vkBindBufferMemory` called with `&buf`, or
`vkUpdateDescriptorSets` skipped, so the shader wrote to nothing and the
readback shows your own host-written input.
**Fix:** check the chain: create buffer → get requirements → allocate →
**bind** → write descriptor (`pBufferInfo.buffer = buf`) → dispatch. The
bundled `DEMO_SHADER=const` mode isolates this: 256×42.0 means the write
path works end to end.

### Only element [0] correct, all others stale

Classic symptom of the above — index 0 of the host-written pattern matches
its own transform by coincidence (`v[0] = 1*1+0 = 1`). If element 0 alone
passes, suspect binding, not math.

## Build problems (llama.cpp / shaders)

### `'#include' : required extension not requested: GL_GOOGLE_include_directive`

**Cause:** jammy's glslang 11.8 compiled the shader (or glslangValidator was
invoked without the extension).
**Fix:** ensure `/opt/vulkan-sdk/bin/glslangValidator` (16.5) is first in
PATH; the glslc shim (stage 50) auto-injects the extension declaration.

### `cannot compile X (exit code 0)` in `vulkan-shaders-gen`

**Cause:** `vulkan-shaders-gen` treats *any* non-empty stderr as failure —
glslangValidator always echoes the input filename to stdout/stderr, so a
successful compile is reported as an error (the .spv was actually written).
**Fix:** the glslc shim (stage 50) silences stderr when the exit code is 0.

### `glslc: command not found`

**Cause:** shaderc is not packaged for jammy arm64.
**Fix:** stage 50 installs `/usr/local/bin/glslc` (a wrapper around
glslangValidator). Verify with `glslc --version` → it is a wrapper script.

### `vk::LayerSettingEXT` / `vk::DriverId::eMesaDozen` compile errors

**Cause:** jammy's Vulkan-Hpp (1.3.204) is too old for modern
ggml-vulkan.cpp.
**Fix:** stage 40 installs Vulkan-Hpp 1.4.361 into `/opt/vulkan-sdk`; build
with `-DCMAKE_PREFIX_PATH=/opt/vulkan-sdk -DVulkan_INCLUDE_DIR=/opt/vulkan-sdk/include`.

### `patchelf: cannot find symbol` during stage 30

**Benign** when the symbol genuinely is not in the driver build (versions
vary); stage 30 prints "not present" and continues. A hard failure here
means the tarball is not the noble build — check stage 20.

## Runtime problems

### Everything works until the screen turns on / an app animates

**Cause:** the GPU is shared with Android's compositor; heavy UI activity
steals time slices and can drop the Vulkan device into contention.
**Workaround:** avoid interactive UI on the host during long GPU jobs, or
accept variable latency. This is inherent to the device, not fixable here.

### Sustained `gpu_busy_percentage` near 100% but throughput low

**Cause:** usually power/thermal throttling (check `devfreq/cur_freq` and
`temp`) or CPU-bound driver spin. 47-82% busy with steady tok/s is the
healthy signature on the reference device.

### Server API behaves oddly behind 9Router-style gateways

Not this stack's problem — llama.cpp returns plain OpenAI-format responses;
health is `{"status":"ok"}`. Gateways that wrap responses in
`{"data": ...}` or expect `{"ok": true}` must adapt on their side.

## Nuclear option

If the stack is in an unknown state:

```bash
sudo rm -rf /opt/turnip /opt/vulkan-sdk /usr/local/bin/glslc
sudo ./install.sh                # full reinstall, ~30-40 min on the reference device
source scripts/gpu-env.sh && bash scripts/70-verify.sh
```

`/opt` is outside `$HOME`, so it survives rootfs restore/backup scripts
that only overwrite `$HOME` + `/etc` (the common pattern for proot
backup tooling).
