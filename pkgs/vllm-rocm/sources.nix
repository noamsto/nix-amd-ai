# Per-GPU-target prebuilt bundles from lemonade-sdk/vllm-rocm. Each release is a
# relocatable Python 3.14 prefix bundling torch + vLLM + a full TheRock ROCm for
# one gfx target, split across two <2 GB GitHub assets. Auto-bumped by the
# weekly update workflow (scripts/check-updates.sh + bump-versions.sh).
{
  gfx1150 = {
    version = "0.25.2.dev0";
    releaseTag = "vllm0.25.2.dev0+rocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1150";
    parts = [
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.25.2.dev0%2Brocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1150/vllm0.25.2.dev0%2Brocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1150-x64.part01-of-02.tar.gz";
        hash = "sha256-Gc+rpa0kSDLI5GAGJI8FTQ+1aN1Ys3FsQj5Xn2MTWJA=";
      }
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.25.2.dev0%2Brocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1150/vllm0.25.2.dev0%2Brocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1150-x64.part02-of-02.tar.gz";
        hash = "sha256-wpZPrWLClfFQvoyem3eDfkdKWQBtdqQSe7kT8S9Z4P0=";
      }
    ];
  };

  # Strix Halo. Packaging is verified: this bundle unpacks and its `vllm-server
  # --help` imports torch + vLLM, so the relocation covers gfx1151 too. No
  # gfx1151 kernel has ever executed though — we have no Halo host. Validate
  # inference before treating it as confirmed. See noamsto/nix-amd-ai#63, #68.
  gfx1151 = {
    version = "0.25.2.dev0";
    releaseTag = "vllm0.25.2.dev0+rocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1151";
    parts = [
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.25.2.dev0%2Brocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1151/vllm0.25.2.dev0%2Brocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1151-x64.part01-of-02.tar.gz";
        hash = "sha256-wN0UWdhmu4Bhu4/df6q0RFLCz1Z/e7m1W3NWzD+62Og=";
      }
      {
        url = "https://github.com/lemonade-sdk/vllm-rocm/releases/download/vllm0.25.2.dev0%2Brocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1151/vllm0.25.2.dev0%2Brocm7.15.0a20260724.g752a3a504.d20260724-rocm7.15.0-gfx1151-x64.part02-of-02.tar.gz";
        hash = "sha256-5Sj3OKEQuDqtGgehzC/qbeZcznBT6zAphTWYze2NZpM=";
      }
    ];
  };
}
