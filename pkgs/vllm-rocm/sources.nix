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
        hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      }
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1150/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1150-x64.part02-of-02.tar.gz";
        hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
      }
    ];
  };

  # Strix Halo (incoming host). Fill hashes when validated on gfx1151.
  gfx1151 = {
    version = "0.23.1.dev0";
    releaseTag = "vllm0.23.1.dev0+rocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151";
    parts = [
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151-x64.part01-of-02.tar.gz";
        hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      }
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151/vllm0.23.1.dev0%2Brocm7.15.0a20260710.g0fc695fc6.d20260710-rocm7.15.0-gfx1151-x64.part02-of-02.tar.gz";
        hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
      }
    ];
  };
}
