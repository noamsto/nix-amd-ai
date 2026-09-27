# llvm-aie (Peano) compiler toolchain, repackaged from the upstream wheel.
#
# Pinned to the pair upstream mlir-aie 1.4.2 tests against (21.0.0.2026080301);
# the `nightly` release tag rotates, so the URL is not durable and the wheel is
# mirrored into our Cachix cache by .github/workflows/build.yml.
# See docs/research/openflowlm.md §3.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  zlib,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "llvm-aie";
  version = "21.0.0.2026080301+c9c5ecb7";

  src = fetchurl {
    url = "https://github.com/Xilinx/llvm-aie/releases/download/nightly/llvm_aie-${finalAttrs.version}-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
    hash = "sha256-WmwnxVFyRAQKTcNODB+pdvK9tuFLKaNVQiNvZuibE3U=";
  };

  nativeBuildInputs = [
    unzip
    autoPatchelfHook
  ];

  buildInputs = [
    zlib
    stdenv.cc.cc.lib
  ];

  unpackPhase = ''
    runHook preUnpack
    unzip -q "$src" -d .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    # bin/ and lib/ stay siblings so clang finds its resource dir at
    # $out/lib/clang/21 and its shared LLVM libs via $ORIGIN/../lib.
    cp -r llvm-aie/bin llvm-aie/lib llvm-aie/include llvm-aie/share $out/

    runHook postInstall
  '';

  dontConfigure = true;
  dontBuild = true;
  # Prebuilt release binaries; stripping buys little and risks the .so set.
  dontStrip = true;

  meta = with lib; {
    description = "Peano AI Engine compiler toolchain (AMD llvm-aie), for IRON kernels";
    homepage = "https://github.com/Xilinx/llvm-aie";
    license = licenses.asl20;
    platforms = ["x86_64-linux"];
    mainProgram = "clang";
  };
})
