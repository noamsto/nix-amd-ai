# nix-amd-ai

AMD AI inference stack for NixOS — packages XRT, XDNA driver plugin, FastFlowLM, and Lemonade with a NixOS module for NPU + ROCm GPU support.

## Packages

| Package | Description | Source |
|---------|-------------|--------|
| `xrt` | Xilinx Runtime for AMD NPU | Built from [Xilinx/XRT](https://github.com/Xilinx/XRT) |
| `xrt-plugin-amdxdna` | XDNA userspace driver plugin | Built from [amd/xdna-driver](https://github.com/amd/xdna-driver) branch `1.7` |
| `fastflowlm` | NPU-optimized LLM runtime | Built from [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) |
| `lemonade` | OpenAI-compatible local AI server | [lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade) RPM |
| `llama-cpp-rocm` | ROCm-accelerated llama.cpp backend | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `llama-cpp-vulkan` | Vulkan-accelerated llama.cpp backend | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `benchmark` | Multi-backend benchmark harness | `nix run .#benchmark` |

## Usage

```nix
# flake.nix
inputs.nix-amd-ai.url = "github:noamsto/nix-amd-ai";

# host configuration
{inputs, ...}: {
  imports = [inputs.nix-amd-ai.nixosModules.default];

  hardware.amd-npu = {
    enable = true;
    enableFastFlowLM = true;  # LLM inference on NPU
    enableLemonade = true;    # OpenAI-compatible API server
    enableROCm = true;        # Declaratively wires ROCm GPU backends for Lemonade
    enableVulkan = true;      # Declaratively wires Vulkan GPU backends for Lemonade
    lemonade.user = "youruser";
  };

  users.users.youruser.extraGroups = ["video" "render"];
}
```

## Binary cache

Pre-built packages are available via Cachix:

```nix
# flake.nix nixConfig (or nix.settings in your NixOS config)
substituters = ["https://nix-amd-ai.cachix.org"];
trusted-public-keys = ["nix-amd-ai.cachix.org-1:F4OU4vw/lV2oiG6SBHZ+nqjl4EFJuqI4X9A7pvaBmhQ="];
```

## Requirements

- NixOS with kernel >= 6.14 (has `amdxdna` driver built-in)
- AMD Ryzen AI processor with XDNA 2 NPU (Strix Point / Strix Halo)
- User in `video` and `render` groups

## What the module configures

- Kernel params (`iommu.passthrough=0`) and modules (`amdxdna`)
- Udev rules for NPU device access
- PAM limits (unlimited memlock for NPU buffer allocation)
- XRT + plugin merged tree for runtime plugin discovery
- Lemonade systemd service with XRT/FLM/ROCm/Vulkan environment
- Environment variables (`XILINX_XRT`, `XRT_PATH`)
- Declarative backend wiring (both the `lemond` service and direct CLI usage receive the ROCm/Vulkan backend paths automatically)

### Why `enableROCm` / `enableVulkan` matter on NixOS

Lemonade's RPM ships its own `llama-server` binaries for each backend, but they're linked against Linux FHS paths (`/usr/lib`) for `libvulkan.so.1`, `libstdc++.so.6`, etc. On NixOS those libraries are not on the default loader path, so the bundled binaries fail to dlopen and **lemonade silently falls back to CPU** — the server still responds, it just does so at a fraction of GPU speed.

`enableROCm = true` and `enableVulkan = true` replace the bundled binaries with the `llama-cpp-rocm` / `llama-cpp-vulkan` packages built in this flake (correct RPATH via `autoPatchelfHook`) by exporting `LEMONADE_LLAMACPP_{ROCM,VULKAN}_BIN`. The lemonade wrapper persists those paths into `~/.cache/lemonade/config.json` on every launch so both the `lemond` service and ad-hoc CLI invocations pick them up.

If you see `lemonade backends` reporting a backend as `installed` but benchmarks report <5 t/s decode on a small model, you're on CPU — check that the matching `enable*` option is set and the host has been rebuilt.

## Which backend should I use?

All numbers measured on Strix Point (gfx1150, Radeon 890M iGPU, 64 GiB DDR5-5600). Prompt 256 tokens, generation 128 tokens, 3 iterations after 1 warmup.

### Large: Gemma-4-26B-A4B-it-GGUF (~15.7 GB, via `llama-bench`, llama.cpp b8770)

| Metric | ROCm | Vulkan | Winner |
| ------ | ---- | ------ | ------ |
| Prefill (pp512) | 360 ± 18 t/s | 370 ± 3 t/s | Vulkan (+3%, within noise) |
| Decode (tg128)  | 13.86 ± 0.18 t/s | 17.52 ± 0.33 t/s | Vulkan (+26%) |

### Mid-size, chat-shaped: Qwen3.5-9B (same family on all three backends)

| Backend | Model | TTFT (s) | Decode (t/s) |
| ------- | ----- | -------: | -----------: |
| Vulkan (llamacpp:vulkan) | `Qwen3.5-9B-GGUF` (UD-Q4_K_XL) | 1.36 | 12.9 +/- 0.1 |
| ROCm (llamacpp:rocm)     | `Qwen3.5-9B-GGUF` (UD-Q4_K_XL) | 1.69 | 10.8 +/- 0.1 |
| FLM (flm:npu)            | `qwen3.5-9b-FLM`               | 4.17 | 11.9 +/- 4.5 |

Notes: FLM's TTFT is dominated by a one-off NPU compile-to-cache; steady-state decode is the useful number. FLM's GGUF-vs-proprietary format means quantization isn't bit-identical to the llamacpp row, so treat these as same-family, not same-weights.

**Recommendation:**

- **General LLM inference (7B–26B Q4):** use **Vulkan**. On Strix Point 890M with llama.cpp b8770, Vulkan wins decode at every size tested and ties or wins prefill. The previous "ROCm for prefill-heavy" advice no longer holds now that ROCm targets gfx1150 natively (the gfx1102 Tensile arch-logic was apparently more tuned than gfx1150's is today).
- **Power-budget / idle-GPU scenarios:** use **FLM/NPU** — decode is competitive with Vulkan and offloads the GPU, but the compile-on-first-load TTFT is noticeable.
- **ROCm** is kept installed as a fallback and for ecosystem tooling (`rocminfo`, profiling, HIP apps); re-evaluate when newer rocBLAS/Tensile logic for gfx1150 lands.

Enable all three and let lemonade pick the recipe per model.

## Coding agents and client timeouts

Coding agents (Claude Code, opencode) ship large system prompts — 10k+ tokens once MCP servers, skills, and tool schemas are loaded. On a Strix Point iGPU, prompt processing runs at ~350 t/s, so the agent's first turn spends 25–35 s before the first token is emitted. Neither lemonade nor the agents send SSE keep-alive events during that silent window, and most clients close the socket after ~30 s, yielding:

```
[Info] (Process) srv  log_server_r: done request: POST /v1/chat/completions 127.0.0.1 200
[Error] (HttpClient) CURL error: Failed writing received data to disk/application
[Error] (WrappedServer) Streaming request failed: ...
```

Tracked upstream as [lemonade-sdk/lemonade#1364](https://github.com/lemonade-sdk/lemonade/issues/1364). Until that lands, this module sets `LEMONADE_GLOBAL_TIMEOUT=0` on the `lemond` service to disable its own 300 s upstream cap, which covers the variant where lemonade gives up on llama-server. The downstream client timeout remains a separate problem — best addressed by shortening the prompt or choosing a leaner agent.

**Practical guidance:**

- **Vulkan for chat and short prompts.** Decode is ~26 % faster than ROCm; for interactive conversations the prompt fits under the timeout easily.
- **ROCm for heavy coding agents.** Prefill is marginally faster and often just enough to land under the ~30 s client cutoff with 10k-token prompts.
- **[pi](https://github.com/badlogic/pi-mono)** (Hugging Face's recommended local coding agent — see the [official docs](https://huggingface.co/docs/hub/en/agents-local)) is the best fit for this hardware. Its prompt is a fraction of Claude Code's and it's designed around llama.cpp-served local models.
- **Claude Code / opencode** are usable — strip down MCP servers, skills, and plugins to shrink the startup prompt, and prefer ROCm while #1364 is unresolved.

## Validation

You can verify that backends are correctly wired by running:

```bash
lemonade backends
```

The output should include both backends as `ready`:

```
+------------------+-------------------------------------------------------+---------+
|     BACKEND      |                         PATH                          | STATUS  |
+------------------+-------------------------------------------------------+---------+
| llamacpp:rocm    | /nix/store/...-llama-cpp-rocm-.../bin/llama-server    | ready   |
| llamacpp:vulkan  | /nix/store/...-llama-cpp-vulkan-.../bin/llama-server  | ready   |
+------------------+-------------------------------------------------------+---------+
```

To run a multi-backend benchmark and detect silent CPU fallbacks:

```bash
nix run .#benchmark -- Gemma-4-26B-A4B-it-GGUF
```

The benchmark exits non-zero if any backend falls below `--min-decode-tps` (default 5 t/s), which reliably indicates a CPU fallback rather than GPU execution.

To directly compare ROCm vs Vulkan on the same model, pass `--backend`. This rewrites `llamacpp.backend` in `~/.cache/lemonade/config.json`, restarts `lemond.service` (via sudo), runs the benchmark, and restores the original config on exit:

```bash
nix run .#benchmark -- --backend rocm   Phi-4-mini-instruct-GGUF
nix run .#benchmark -- --backend vulkan Phi-4-mini-instruct-GGUF
```

If you've already set the backend manually, pass `--no-restart` to skip the sudo restart step.

## CI

- **Build**: All packages built and cached on every push to `main`
- **Update**: Weekly check for upstream releases, auto-creates PR with version bumps
