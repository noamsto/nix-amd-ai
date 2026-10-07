# Pinned inputs for the Strata engine (Niko1221/Strata, MIT). Strata changes daily and its CMake fetches ggml at
# configure time, so every input is fixed here: the engine commit, the llama.cpp commit its third_party/ggml/VERSION.txt
# names (passed as STRATA_GGML_DIR so the build is offline), and the TheRock ROCm tarball its docs/STRIX_HALO.md names.
{
  strata = {
    rev = "82f46a8c8f475f001ad76d92f58f4a4f8ffb0253";
    hash = "sha256-y+0Qn2KhyVFfQrZi1L9BzR7iqQoRHjkXO9W48VJO2QQ=";
  };
  ggml = {
    rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
  };
  therock = {
    version = "7.14.1";
    url = "https://repo.amd.com/rocm/tarball-multi-arch/therock-dist-linux-gfx1151-7.14.1.tar.gz";
    hash = "sha256-xA6PK9ZjCn0RVXx2K5nG+or7BMm9DlHtFnXuHKJK+wA=";
  };
}
