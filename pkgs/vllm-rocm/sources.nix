# Per-GPU-target prebuilt bundles from lemonade-sdk/vllm-rocm. Each release is a
# relocatable Python 3.14 prefix bundling torch + vLLM + a full TheRock ROCm for
# one gfx target, split across two <2 GB GitHub assets. Refresh with
# scripts/bump-versions.sh (TODO: wire it in) or `nix store prefetch-file`.
{
  gfx1150 = {
    version = "0.23.1.dev0";
    releaseTag = "vllm0.23.1.dev0+rocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1150";
    parts = [
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1150/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1150-x64.part01-of-02.tar.gz";
        hash = "sha256-aS8oZUecBTiod1lPoFpy9QfC+T9GXZnHeQc86zmdHbk=";
      }
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1150/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1150-x64.part02-of-02.tar.gz";
        hash = "sha256-tIXcYaMcpPOnVCx64id6+Lpiv9Qzsu5M09smYSDV2gM=";
      }
    ];
  };

  # Strix Halo. Hashes pinned; buildable, but not yet run on a Halo host — the
  # gfx1150 recipe transfers, so this is expected to work. Validate inference on
  # a gfx1151 machine before treating it as confirmed. See noamsto/nix-amd-ai#63.
  gfx1151 = {
    version = "0.23.1.dev0";
    releaseTag = "vllm0.23.1.dev0+rocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151";
    parts = [
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151-x64.part01-of-02.tar.gz";
        hash = "sha256-sFPe3SEB46FJWZ03ukzYfUeZQ+J/S52tDk1rrKKIh78=";
      }
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151-x64.part02-of-02.tar.gz";
        hash = "sha256-w/J1I0X1RZon+vBBkAIqQELEl1tphS6t+nBuCJ9W+2w=";
      }
    ];
  };
}
