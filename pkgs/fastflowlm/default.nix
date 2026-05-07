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
  version = "0.9.41";

  src = fetchFromGitHub {
    owner = "FastFlowLM";
    repo = "FastFlowLM";
    rev = "v${finalAttrs.version}";
    hash = "sha256-PUbNi+rTdPvUyrfRMETBYDzVXqIzFkhYkla7ijdt/dg=";
    fetchSubmodules = true;
  };

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

    # Remove the attempt to create /usr/local/bin symlink at install time
    substituteInPlace src/CMakeLists.txt \
      --replace-fail \
        'NOT CMAKE_INSTALL_PREFIX STREQUAL "/usr" AND NOT CMAKE_INSTALL_PREFIX STREQUAL "/usr/local"' \
        'FALSE'
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
    homepage = "https://github.com/FastFlowLM/FastFlowLM";
    license = lib.licenses.asl20;
    platforms = ["x86_64-linux"];
    mainProgram = "flm";
  };
})
