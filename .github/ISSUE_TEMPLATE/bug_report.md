---
name: Bug report
about: Something in the GPU stack does not work as documented
title: "[bug] "
labels: bug
assignees: ''
---

## Environment (required)

- Output of `bash scripts/00-preflight.sh`:
```
(paste here)
```
- `uname -a`:
- `/etc/os-release` PRETTY_NAME:
- `ldd --version | head -1`:
- GPU model from sysfs: `cat /sys/class/kgsl/kgsl-3d0/gpu_model`:

## What happened

A clear description of the failure.

## Command that failed

```bash
(the exact command, with all environment variables)
```

## Full output

```
(full output, not a summary)
```

## `vulkaninfo --summary` (with gpu-env sourced)

```
(paste; if vulkaninfo itself fails, paste its error)
```
