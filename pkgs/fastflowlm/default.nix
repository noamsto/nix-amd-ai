{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  boost,
  curl,
  fftw,
  fftwFloat,
  fftwLongDouble,
  ffmpeg,
  readline,
  libuuid,
  libdrm,
  cargo,
  rustc,
  rustPlatform,
  autoPatchelfHook,
  xrt,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "fastflowlm";
  version = "1.0.6";

  src = fetchFromGitHub {
    owner = "ROCm";
    repo = "FastFlowLM";
    rev = "v${finalAttrs.version}";
    hash = "sha256-5w2mZApaudZEVP9sQujt/nf+u/P0mu2/tiMK3cq6FH4=";
    fetchSubmodules = true;
  };

  # server.cpp maps only error code 400 to an HTTP status, so handler errors
  # raised with code 500 (rest_handler.cpp) go out as HTTP 200. This ports the
  # numeric-code half of OpenFlowLM-Next 746f6ab (Vegard Berget) without its
  # openai_compat helpers. Still unfixed on ROCm/FastFlowLM main as of v1.0.6;
  # drop once upstream maps 4xx/5xx codes. A bump that breaks the patch fails
  # the build rather than silently losing the fix.
  patches = [ ./patches/http-error-status.patch ];

  cargoDeps = rustPlatform.importCargoLock {
    lockFile = ./Cargo.lock;
  };

  cargoRoot = "third_party/tokenizers-cpp/rust";

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    cargo
    rustc
    rustPlatform.cargoSetupHook
    autoPatchelfHook
  ];

  buildInputs = [
    boost
    curl
    fftw
    fftwFloat
    fftwLongDouble
    ffmpeg
    readline
    libuuid
    libdrm
    stdenv.cc.cc.lib
    xrt
  ];

  postPatch = ''
    # Cargo.lock is not committed upstream; inject our copy
    cp ${./Cargo.lock} third_party/tokenizers-cpp/rust/Cargo.lock
  '';

  dontUseCmakeConfigure = true;

  configurePhase = ''
    runHook preConfigure
    cmake -S src -B src/build \
      -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DFLM_VERSION="${finalAttrs.version}" \
      -DNPU_VERSION="32.0.203.304" \
      "-DXRT_INCLUDE_DIR=${xrt}/opt/xilinx/xrt/include" \
      "-DXRT_LIB_DIR=${xrt}/opt/xilinx/xrt/lib" \
      -DCMAKE_INSTALL_PREFIX=$out \
      -DCMAKE_XCLBIN_PREFIX=$out/share/flm
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -C src/build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    ninja -C src/build install
    runHook postInstall
  '';

  meta = {
    description = "NPU-optimized LLM runtime for AMD Ryzen AI";
    homepage = "https://github.com/ROCm/FastFlowLM";
    license = lib.licenses.mit;
    platforms = ["x86_64-linux"];
    mainProgram = "flm";
  };
})
