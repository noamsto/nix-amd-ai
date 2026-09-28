# Build shape (tokenizers-cpp Cargo.lock, SPM_ABSL_PROVIDER=package) adapted
# from @eyduh's packaging:
# https://github.com/eyduh/OpenFlowLM-Next/blob/62653a0bdca21264303bb347f66423b44f3e56c3/nix/package.nix
# Not self-wrapped: like pkgs.fastflowlm, the XRT LD_LIBRARY_PATH comes from
# hardware.amd-npu.fastflowlm.package's wrapper.
{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  patchelf,
  abseil-cpp,
  boost,
  curl,
  ffmpeg,
  fftw,
  fftwFloat,
  fftwLongDouble,
  libdrm,
  libuuid,
  readline,
  ncurses,
  cargo,
  rustc,
  rustPlatform,
  autoPatchelfHook,
  xrt,
  mlir-aie,
  llvm-aie,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "openflowlm";
  # Upstream has no tags or releases (checked 2026-09-28), so this pins main;
  # the binary reports upstream's own 0.1.0.
  version = "0.1.0-unstable-2026-09-27";

  src = fetchFromGitHub {
    owner = "Atomic-Germ";
    repo = "OpenFlowLM-Next";
    rev = "8c837120d25d18bfbae9d7aa79572ccbb785e2f3";
    hash = "sha256-NkxTT0pYDxql7JtQYEVzcfIWrnjisoqqbFrSmyq5u60=";
    fetchSubmodules = true;
  };

  patches = [
    # The BERT exporter allocated device="npu" tensors and ran each GEMM
    # once, needing /dev/accel and pyxrt at build time; compile-only is
    # byte-identical in insts. Drop when Atomic-Germ/OpenFlowLM-Next#126
    # merges.
    ./patches/device-free-bert-export.patch
    # A size-mismatched model file printed a [WARNING] to stdout ahead of
    # `list --json`, and lemonade's strict json::parse of that output then
    # drops every FLM model. Drop when upstream prints it to stderr.
    ./patches/list-json-warning-to-stderr.patch
  ];

  # Kernels get ONLY the device-free patch, so changing the engine-only
  # list-json patch never invalidates the ~50 min kernels build.
  passthru.kernels = callPackage ./kernels.nix {
    inherit (finalAttrs) src version;
    patches = [./patches/device-free-bert-export.patch];
    inherit mlir-aie llvm-aie xrt;
  };

  cargoDeps = rustPlatform.importCargoLock {lockFile = ./Cargo.lock;};
  cargoRoot = "third_party/tokenizers-cpp/rust";

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    # Upstream CMake does find_program(patchelf REQUIRED).
    patchelf
    cargo
    rustc
    rustPlatform.cargoSetupHook
    autoPatchelfHook
  ];

  buildInputs = [
    xrt
    abseil-cpp
    boost
    curl
    ffmpeg
    fftw
    fftwFloat
    fftwLongDouble
    libdrm
    libuuid
    readline
    ncurses
    stdenv.cc.cc.lib
  ];

  postPatch = ''
    # Upstream commits no Cargo.lock.
    cp ${./Cargo.lock} third_party/tokenizers-cpp/rust/Cargo.lock
  '';

  cmakeDir = "../src";
  cmakeFlags = [
    "-DOFLM_VERSION=0.1.0"
    "-DNPU_VERSION=32.0.203.304"
    # Built as passthru.kernels.
    "-DOFLM_BUILD_KERNELS=OFF"
    # Would write /usr/bin and /etc/profile.d.
    "-DOFLM_INSTALL_PATH_PLUMBING=OFF"
    # oflm-test/q4nx-build need Python deps not packaged here.
    "-DOFLM_BUILD_UTILITIES=OFF"
    # sentencepiece would otherwise FetchContent abseil.
    "-DSPM_ABSL_PROVIDER=package"
    "-DCMAKE_BUILD_TYPE=Release"
  ];

  preConfigure = ''
    export PKG_CONFIG_PATH="${xrt}/opt/xilinx/xrt/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    # Upstream's OFLM_BUILD_KERNELS=ON exports into src/xclbins for
    # cmake --install to ship next to the tree's closed sets.
    cp -r ${finalAttrs.passthru.kernels}/xclbins/. src/xclbins/
    chmod -R u+w src/xclbins
  '';

  doCheck = true;
  preCheck = ''
    export HOME=$TMPDIR/home
    mkdir -p $HOME
  '';

  meta = {
    description = "Open-kernel fork of FastFlowLM: NPU LLM runtime for AMD Ryzen AI";
    homepage = "https://github.com/Atomic-Germ/OpenFlowLM-Next";
    # The tree still tracks and installs FastFlowLM's closed engine libraries
    # (src/lib/xrt/*.so) and kernels (src/xclbins/*-NPU2), loaded for every
    # model without an open recipe. #158
    license = [lib.licenses.mit lib.licenses.unfree];
    platforms = ["x86_64-linux"];
    mainProgram = "oflm";
  };
})
