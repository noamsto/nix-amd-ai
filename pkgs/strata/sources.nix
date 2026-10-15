# Pinned inputs for the Strata engine (Niko1221/Strata, MIT). Strata changes daily and its CMake fetches ggml at
# configure time, so every input is fixed here: the engine commit, the llama.cpp commit its third_party/ggml/VERSION.txt
# names (passed as STRATA_GGML_DIR so the build is offline), and the TheRock ROCm tarball its docs/STRIX_HALO.md names.
{
  strata = {
    rev = "296b59d2f73c8f04a805df29c2fa97655adace78";
    hash = "sha256-Jfo2uldtyXW8Y/wQxA7WcYwtmzCGAOaXgnlMSo7K9LE=";
  };
  ggml = {
    rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
  };
  # The Flash-Next GGUFs `strata.model` defaults to: a snapshot inside lemond's Hugging Face cache, never copied into
  # the store (the experts are read from the shards in place). Each quant is one `strata.quant` value with its own
  # repository snapshot and first shard; only files Strata's setup.py lists as runnable (SUPPORTED_GGUFS) belong here.
  # UD-IQ4_XS is the one benched on Strata. GSQ-RCO-IQ3_S is upstream's recommended size since 0.1.44 (64 GB RAM) and
  # has not been benched on Strix Halo (gfx1151).
  model.quants = {
    "UD-IQ4_XS" = {
      repo = "unsloth/Qwen3.8-Flash-Next-GGUF";
      rev = "38bb39ee97821de2c9009abb7e93950eec396e66";
      file = "UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf";
    };
    "GSQ-RCO-IQ3_S" = {
      repo = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
      rev = "ed59f92082b1e93c0e96d60a8b11aab089b52f09";
      file = "IQ3_S/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf";
    };
  };
  # The vision projector the module fetches for `strata.vision.mmproj`. Strata's own setup pins the same repository
  # revision and file; the SRI below is that file's SHA-256. A fixed output, since it is a plain 0.9 GiB download and
  # small enough beside the engine closure to keep in the store.
  mmproj = {
    repo = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
    rev = "ed59f92082b1e93c0e96d60a8b11aab089b52f09";
    file = "mmproj-Qwen3.8-Flash-Next-BF16.gguf";
    hash = "sha256-sagiWXAoFqUzDXvXYHzZZ2sReA55/3NIwhED/zzkm9A=";
  };
  therock = {
    version = "7.14.1";
    url = "https://repo.amd.com/rocm/tarball-multi-arch/therock-dist-linux-gfx1151-7.14.1.tar.gz";
    hash = "sha256-xA6PK9ZjCn0RVXx2K5nG+or7BMm9DlHtFnXuHKJK+wA=";
  };
}
