# llama.cpp on Adreno — configuration, results, and workload policy

llama.cpp with the Vulkan backend is the practical "real workload" that
exercises the whole turnip+kgsl stack end to end: shader compilation at
build time (via the glslc shim), device memory allocation, multi-gigabyte
model upload, and sustained compute.

## Status on the reference device

Installed and verified: llama.cpp 0.4.0-dev (build 28ff095) with
`-DGGML_VULKAN=ON`, model Gemma-3-1B-Instruct Q4_K_M (769 MB), `-ngl 99`
(all layers on GPU).

Measured (end-to-end, non-streaming, Indonesian prompts, max_tokens 120-200):

| Backend | Generate | Prompt eval | GPU busy |
|---|---|---|---|
| Vulkan (Adreno 735, turnip+kgsl) | ~12 tok/s | ~10 tok/s | 47-82% while generating |
| CPU (8 threads) | ~8 tok/s | ~30 tok/s | n/a |

Honest interpretation:

- **~1.5x generate speedup** for a 1B model — real but not dramatic;
  host<->device transfer overhead dominates at this model size. Gains grow
  with 3B-8B models (Qwen3-4B and Llama-3.2-3B are the sweet spots on 8 GB
  shared RAM).
- **Prompt eval is slower on GPU** for short prompts — normal for Vulkan on
  small models; the GPU's win is in the generate phase.
- Model size ceiling: 8 GB total RAM shared with the GPU fits up to an 8B
  Q4 (~4.9 GB) at 2-3 tok/s; 12B+ does not fit.

## Operator policy (learned the hard way)

> **llama-server is NOT the GPU test.** On this device the server feels
> visibly laggy and its GPU speedup is only 1.5x on the 1B model — as a
> *GPU test* it is slow, noisy, and adds no verification value.

GPU verification is therefore defined as (see `scripts/70-verify.sh`):

1. `vulkaninfo --summary` — device enumeration, and
2. the bundled compute demo — dispatch + element-by-element correctness.

llama.cpp is run when you actually want an offline LLM, not as a test tool.

## Building (stage 60)

```bash
sudo ./install.sh --with-llama
# or manually:
source scripts/gpu-env.sh
cmake -S /data/llamacpp/llama.cpp -B /data/llamacpp/llama.cpp/build-gpu \
  -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF \
  -DCMAKE_PREFIX_PATH=/opt/vulkan-sdk \
  -DVulkan_INCLUDE_DIR=/opt/vulkan-sdk/include
cmake --build /data/llamacpp/llama.cpp/build-gpu -j8   # ~7 min on 8 cores
```

Requirements met by earlier stages: Vulkan-Headers 1.4.361 +
Vulkan-Hpp 1.4.361 + glslang 16.5 in `/opt/vulkan-sdk`, `glslc` shim in
`/usr/local/bin`, turnip 26.3 with the glibc patch.

## Running

```bash
source scripts/gpu-env.sh     # the three env vars are mandatory
/data/llamacpp/llama.cpp/build-gpu/bin/llama-server \
    -m /data/llamacpp/gemma-3-1b-it-Q4_K_M.gguf \
    --host 127.0.0.1 --port 8080 -ngl 99
```

Keep the bind on 127.0.0.1 — the server has no auth by default.

Model fitting on 8 GB RAM + Adreno (GPU memory = shared RAM):

| Model | Q4 size | Verdict |
|---|---|---|
| Llama-3.2-1B / 3B | 0.8 / 2.0 GB | good (3B ~4-5 tok/s) |
| Gemma-3-4B / Qwen3-4B | ~2.5 GB | good |
| Llama-3.1-8B | ~4.9 GB | fits, slow (~2-3 tok/s) |
| Gemma-3-12B / 27B | 7+ / 16 GB | does not fit |

## Troubleshooting pointers

- Server slow + Vulkan warnings in log → env vars missing; check
  `cat /proc/$(pidof llama-server)/environ`.
- Build fails in `vulkan-shaders-gen` with "cannot compile X (exit code 0)"
  → the glslc shim (stage 50) is missing; it silences glslangValidator's
  always-printed filename on success.
- Shader errors mentioning `GL_GOOGLE_include_directive` → jammy's
  glslang 11.8 is being found instead of the 16.5 build; check PATH order
  and `/opt/vulkan-sdk/bin/glslangValidator --version`.
