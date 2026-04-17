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
    # rocmGfxOverride = "11.0.2";  # Strix Point gfx1150 → gfx1102 fallback (see below)
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
- `rocmGfxOverride`: set to `"11.0.2"` on Strix Point (gfx1150) to override the GFX version to gfx1102, enabling ROCm support on hardware not yet natively supported by ROCm. Example: `rocmGfxOverride = "11.0.2";`

## Which backend should I use?

Measured on Strix Point (gfx1150) with Gemma-4-26B-A4B-it-GGUF:

| Metric | ROCm | Vulkan | Winner |
| ------ | ---- | ------ | ------ |
| Prefill (pp) | 395 t/s | 265 t/s | ROCm (+49%) |
| Decode (tg)  | 10.4 t/s | 13.6 t/s | Vulkan (+31%) |

**Recommendation:**

- Use **ROCm** for prefill-heavy workloads (long-context, RAG, batch processing).
- Use **Vulkan** for interactive chat (decode-heavy).
- ROCm numbers will improve when ROCm ≥ 7.1 ships native gfx1150 kernels (currently requires gfx1102 override via `rocmGfxOverride`).

Enable both and let lemonade pick the right recipe per model.

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

## CI

- **Build**: All packages built and cached on every push to `main`
- **Update**: Weekly check for upstream releases, auto-creates PR with version bumps
