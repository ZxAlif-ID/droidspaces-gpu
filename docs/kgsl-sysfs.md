# kgsl-sysfs.md — kernel-side GPU interface reference

KGSL (Qualcomm GPU kernel driver) exposes the GPU's state through sysfs.
These files are the *kernel's own* view — independent of Vulkan, the loader,
and userspace drivers — which makes them the honest source of truth for "is
the GPU doing anything".

Root: `/sys/class/kgsl/kgsl-3d0/`

## The essential files

| File | Example value | Meaning |
|---|---|---|
| `gpu_model` | `Adreno735` | GPU identity as the kernel sees it |
| `gpu_busy_percentage` | `47 %` | fraction of wall time the GPU executes work; `0 %` at idle is normal |
| `max_gpuclk` | `900000000` | maximum core clock in Hz (900 MHz on a735) |
| `clock_mhz` / `freq_table_mhz` | (build-dependent) | current/available clocks in MHz |
| `devfreq/cur_freq` | `270000000` | current clock via devfreq framework |
| `devfreq/governor` | `msm-adreno-tz` | DVFS governor |
| `temp` | `44900` | GPU temperature in **milli-celsius** (44.9 °C) |
| `min_clock_mhz` / `max_clock_mhz` | (build-dependent) | clock floor/ceiling |
| `force_clk_on`, `force_rail_on`, `force_bus_on`, `force_no_nap` | `0` | debug knobs to prevent power-collapse; leave at 0 |

## Reading the busy number correctly

`gpu_busy_percentage` is sampled by the kernel over a window (~100 ms) and
updates only when read... on some kernels it caches per-read. Two rules:

1. **A single `0 %` does not mean the GPU is broken** — sample while work
   runs. Under a sustained Vulkan workload (e.g. llama `-ngl 99`) the
   reference device shows **47-82 %**; short compute dispatches may finish
   between samples and still show idle.
2. **Sustained near-100 % while generation crawls** means thermal
   throttling or a CPU-bound driver path, not a fast GPU.

Quick sampler used in verification:

```bash
K=/sys/class/kgsl/kgsl-3d0
echo "before: $(cat $K/gpu_busy_percentage)"
demo/build/gpu-demo >/dev/null   # or any Vulkan work
echo "after:  $(cat $K/gpu_busy_percentage)"
```

## Identity cross-check

`/sys/class/kgsl/kgsl-3d0/gpu_model` must agree with what turnip reports:

```bash
cat /sys/class/kgsl/kgsl-3d0/gpu_model        # Adreno735 (kernel)
vulkaninfo --summary | grep deviceName        # Turnip Adreno (TM) 735 (userspace)
```

If the kernel says Adreno but Vulkan shows nothing, the problem is
userspace (env vars, ICD, permissions) — see
[troubleshooting.md](troubleshooting.md).

## Permissions

`/dev/kgsl-3d0` on the reference Droidspaces build:

```
crw-rw---- 1 root droidspaces-gpu 473, 0 /dev/kgsl-3d0
```

- root in the rootfs: always sufficient.
- non-root: the user needs the `droidspaces-gpu` group (check `id`) or the
  node's mode/group must be adjusted by the container operator.

## Device tree / hardware info

```
/sys/class/kgsl/kgsl-3d0/gpu_model        # Adreno735
cat /sys/class/kgsl/kgsl-3d0/gpuclk       # current clock in Hz (older builds)
cat /sys/class/kgsl/kgsl-3d0/idle_timer   # idle timeout (ms)
```

Some files are build-specific; enumerate with `ls /sys/class/kgsl/kgsl-3d0/`
rather than assuming this list is complete.
