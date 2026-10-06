# Strata (Niko1221/Strata, MIT): a Qwen3.8-Flash-Next inference server with its own HIP kernels for gfx11 / gfx1151.
# Built against the pinned TheRock ROCm (./therock-sdk.nix) and a pinned ggml (STRATA_GGML_DIR, so CMake fetches
# nothing). Ships the `strata` engine, the CPU image encoder `strata-vision` (Strata has no GPU encoder on AMD) and
# `strata-server`, the Python HTTP server that spawns the engine. Builds with -march=native like upstream, so the
# result is specific to the building host's CPU. See bench-logs/qwen38-flash-next-strata-2026-10-06 (#257).
{
  lib,
  stdenv,
  fetchFromGitHub,
  callPackage,
  cmake,
  ninja,
  makeWrapper,
  python3,
  glibc,
  gpuTarget ? "gfx1151",
}: let
  sources = import ./sources.nix;
  therock = callPackage ./therock-sdk.nix {};
  ggml = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    inherit (sources.ggml) rev hash;
  };
  python = python3.withPackages (ps: [ps.jinja2 ps.pyyaml ps.numpy ps.regex ps.requests ps.psutil ps.pillow]);
  gcc = stdenv.cc.cc;
  # TheRock's clang is not the Nix cc wrapper: it needs the host C++ and C library locations spelled out.
  hipHostFlags = lib.concatStringsSep " " [
    "--gcc-toolchain=${gcc}"
    "-idirafter ${lib.getDev glibc}/include"
    "-B${glibc}/lib"
    "-L${glibc}/lib"
    "-L${gcc.lib}/lib"
    "-Wl,-rpath,${glibc}/lib:${gcc.lib}/lib"
    "-Wl,--dynamic-linker=${stdenv.cc.bintools.dynamicLinker}"
  ];
in
  stdenv.mkDerivation {
    pname = "strata";
    version = "0-unstable-2026-10-06";

    src = fetchFromGitHub {
      owner = "Niko1221";
      repo = "Strata";
      inherit (sources.strata) rev hash;
    };

    nativeBuildInputs = [cmake ninja makeWrapper];

    # gfx1151's hipBLASLt tuning table is for ROCm 7.14.1's hipBLASLt (version 100401); the engine refuses any other.
    cmakeFlags = [
      "-DCMAKE_BUILD_TYPE=Release"
      "-DSTRATA_ENABLE_HIP=ON"
      "-DSTRATA_ENABLE_CUDA=OFF"
      "-DSTRATA_PREFILL_MMQ=ON"
      "-DSTRATA_BUILD_TESTS=OFF"
      "-DCMAKE_HIP_ARCHITECTURES=${gpuTarget}"
      "-DSTRATA_GGML_DIR=${ggml}"
      "-DCMAKE_HIP_COMPILER=${therock}/lib/llvm/bin/clang++"
      "-DCMAKE_HIP_COMPILER_ROCM_ROOT=${therock}"
      "-DCMAKE_PREFIX_PATH=${therock};${therock}/lib/rocm_sysdeps;${therock}/lib/llvm"
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath,${therock}/lib:${therock}/lib/rocm_sysdeps/lib"
    ];

    env = {
      ROCM_PATH = "${therock}";
      HIP_PATH = "${therock}";
      HIP_PLATFORM = "amd";
    };
    preConfigure = ''
      # One word per flag would split this value; cmakeFlagsArray keeps it whole.
      cmakeFlagsArray+=("-DCMAKE_HIP_FLAGS=--rocm-path=${therock} --rocm-device-lib-path=${therock}/lib/llvm/amdgcn/bitcode ${hipHostFlags}")
      export PATH=${therock}/bin:${therock}/lib/llvm/bin:$PATH
      export LD_LIBRARY_PATH=${therock}/lib:${therock}/lib/rocm_sysdeps/lib:${therock}/lib/llvm/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    '';

    # cmakeConfigurePhase builds the whole `all` target, which includes the engine's helper executables; only these two
    # are used.
    ninjaFlags = ["strata"];

    postBuild = ''
      cmake -S ../tools/vision -B ../build-vision -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_DIR=${ggml} -DSTRATA_VISION_CUDA=OFF
      cmake --build ../build-vision --target strata-vision -j $NIX_BUILD_CORES
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 strata $out/bin/strata
      install -Dm755 ../build-vision/bin/strata-vision $out/bin/strata-vision
      mkdir -p $out/share/strata
      cp -r ../serve ../tools ../data $out/share/strata/
      # serve/ is imported as a package; the server and the engine's tuning table travel with it.
      makeWrapper ${python}/bin/python $out/bin/strata-server \
        --add-flags "-m serve.server" \
        --chdir $out/share/strata \
        --set STRATA_HIPBLASLT_TUNING $out/share/strata/tools/hip/gfx1151-hipblaslt-100401.txt \
        --prefix PATH : $out/bin
      runHook postInstall
    '';

    passthru = {inherit therock ggml;};

    meta = {
      description = "Strata: Qwen3.8-Flash-Next inference engine with gfx1151 HIP kernels (pinned, ROCm 7.14.1)";
      homepage = "https://github.com/Niko1221/Strata";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux"];
      mainProgram = "strata-server";
    };
  }
