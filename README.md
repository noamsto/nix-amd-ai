# nix-amd-ai

AMD AI inference stack for NixOS — packages XRT, XDNA driver plugin, FastFlowLM, and Lemonade with a NixOS module for NPU + ROCm GPU support.

## Packages

| Package | Description | Source |
|---------|-------------|--------|
| `xrt` | Xilinx Runtime for AMD NPU | Built from [Xilinx/XRT](https://github.com/Xilinx/XRT) |
| `xrt-plugin-amdxdna` | XDNA userspace driver plugin | Built from [amd/xdna-driver](https://github.com/amd/xdna-driver) branch `1.7` |
| `fastflowlm` | NPU-optimized LLM runtime | Built from [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) |
| `lemonade` | OpenAI-compatible local AI server | [lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade) RPM |

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
    enableROCm = false;       # ROCm GPU backends for Lemonade
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
- Lemonade systemd service with XRT/FLM/ROCm environment
- Environment variables (`XILINX_XRT`, `XRT_PATH`)

## CI

- **Build**: All packages built and cached on every push to `main`
- **Update**: Weekly check for upstream releases, auto-creates PR with version bumps
