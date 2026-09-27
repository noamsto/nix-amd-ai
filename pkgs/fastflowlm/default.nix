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

  # flm serve's request handling has three bugs found by running
  # OpenFlowLM-Next's server-api conformance suite against it (#164, #171):
  #   - server-error-handling.patch: a malformed request body could throw
  #     twice while the server built its own error response, escaping every
  #     catch before the NPU lock was released and wedging it permanently
  #     (fixed with an RAII guard); and error.code was mapped to an HTTP
  #     status only for an object with a numeric code, so a bare-string
  #     error (or an object with a string code, from
  #     request-validation.patch) stayed HTTP 200 -- supersedes #157, whose
  #     numeric-code mapping this keeps, plus a 400 default for other shapes.
  #   - request-validation.patch: rest_handler.cpp read required fields with
  #     `request["field"]` on a const json&, undefined behavior for a missing
  #     key (JSON_ASSERT is compiled out in release builds) that segfaults or
  #     returns garbage instead of throwing. Checks presence and type first.
  # Neither patch carries attribution: require_field and safe_dump are ported
  # from OpenFlowLM-Next (Vegard Berget) -- the Co-authored-by trailer for
  # that is on the branch commit per this repo's CLAUDE.md, not here. Still
  # unfixed on ROCm/FastFlowLM main as of v1.0.6; drop once upstream fixes
  # request validation, the NPU-lock leak, and the status mapping. A bump
  # that breaks either patch fails the build rather than silently losing it.
  patches = [
    ./patches/server-error-handling.patch
    ./patches/request-validation.patch
  ];

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
    # Source is MIT; the NPU kernels in share/flm are proprietary (see TERMS.md).
    license = [lib.licenses.mit lib.licenses.unfree];
    platforms = ["x86_64-linux"];
    mainProgram = "flm";
  };
})
