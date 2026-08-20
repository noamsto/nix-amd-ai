# Per-GPU-target prebuilt bundles from lemonade-sdk/vllm-rocm. Each release is a
# relocatable Python 3.14 prefix bundling torch + vLLM + a full TheRock ROCm for
# one gfx target, split across two <2 GB GitHub assets. Auto-bumped by the
# weekly update workflow (scripts/check-updates.sh + bump-versions.sh).
{
  gfx1150 = {
    version = "-omni0.25.0rc1-rocm7.15.0";
    releaseTag = "vllm-omni0.25.0rc1-rocm7.15.0-gfx1150";
    parts = [
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm-omni0.25.0rc1-rocm7.15.0-gfx1150/vllm-omni0.25.0rc1-rocm7.15.0-gfx1150-x64.part01-of-02.tar.gz";
        hash = "sha256-u//73yU/m1yzHGezQ052mrAnqhTxaTXQxzbMCYjQx70=";
      }
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm-omni0.25.0rc1-rocm7.15.0-gfx1150/vllm-omni0.25.0rc1-rocm7.15.0-gfx1150-x64.part02-of-02.tar.gz";
        hash = "sha256-4McKgPoXgqC3OGBl6g6B5B9TUxifpK0haDORx7JWS9U=";
      }
    ];
  };

  # Strix Halo. Packaging is verified: this bundle unpacks and its `vllm-server
  # --help` imports torch + vLLM, so the relocation covers gfx1151 too. No
  # gfx1151 kernel has ever executed though — we have no Halo host. Validate
  # inference before treating it as confirmed. See noamsto/nix-amd-ai#63, #68.
  gfx1151 = {
    version = "-omni0.25.0rc1-rocm7.15.0";
    releaseTag = "vllm-omni0.25.0rc1-rocm7.15.0-gfx1151";
    parts = [
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm-omni0.25.0rc1-rocm7.15.0-gfx1151/vllm-omni0.25.0rc1-rocm7.15.0-gfx1151-x64.part01-of-02.tar.gz";
        hash = "";
      }
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm-omni0.25.0rc1-rocm7.15.0-gfx1151/vllm-omni0.25.0rc1-rocm7.15.0-gfx1151-x64.part02-of-02.tar.gz";
        hash = "";
      }
    ];
  };
}
