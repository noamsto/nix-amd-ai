# Pinned inputs for the Strata engine (Niko1221/Strata, MIT). Strata changes daily and its CMake fetches ggml at
# configure time, so every input is fixed here: the engine commit, the llama.cpp commit its third_party/ggml/VERSION.txt
# names (passed as STRATA_GGML_DIR so the build is offline), and the TheRock ROCm tarball its docs/STRIX_HALO.md names.
{
  strata = {
    rev = "e8ca9afd03d839d4f8dbbe82dffce7f8a3bafd7a";
    hash = "sha256-NCOHJF8L32g67h8S4XY9uOABAKEoqapGqYLUEoiVHME=";
  };
  ggml = {
    rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
  };
  # The Flash-Next GGUF `strata.model` defaults to: a snapshot inside lemond's Hugging Face cache, never copied into
  # the store (the experts are read from the shards in place). Each quant is one `strata.quant` value; only quants
  # that have been packed and benched with Strata belong here.
  model = {
    repo = "unsloth/Qwen3.8-Flash-Next-GGUF";
    rev = "38bb39ee97821de2c9009abb7e93950eec396e66";
    quants."UD-IQ4_XS" = "UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf";
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
