# vLLM ROCm for AMD Strix (gfx1150/gfx1151), repackaged from the upstream
# lemonade-sdk/vllm-rocm prebuilt. We relocate their portable TheRock ROCm +
# torch + vLLM bundle rather than build vLLM from source: nixpkgs rocmPackages
# is far behind ROCm 7.15 and lacks the Strix gfx targets. Lemonade launches the
# resulting `vllm-server` via the `vllm.rocm_bin` config override wired in the
# NixOS module. See noamsto/nix-amd-ai#63.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  zlib,
  zstd,
  xz,
  numactl,
  libdrm,
  ncurses,
  elfutils,
  openssl,
  libxml2,
  libGL,
  gpuTarget ? "gfx1150",
}: let
  sources = import ./sources.nix;
  src =
    sources.${gpuTarget}
    or (throw "vllm-rocm: no prebuilt for gpuTarget '${gpuTarget}' (have: ${lib.concatStringsSep ", " (lib.attrNames sources)})");
  parts = map (p: fetchurl {inherit (p) url hash;}) src.parts;
in
  stdenv.mkDerivation {
    pname = "vllm-rocm";
    inherit (src) version;

    # Two <2 GB GitHub assets that concatenate into one .tar.gz.
    srcs = parts;

    nativeBuildInputs = [autoPatchelfHook makeWrapper];

    # External libs the bundled ELFs need; the ROCm/torch .so ship inside the
    # bundle and resolve intra-tree once its own lib dirs are on the runpath.
    buildInputs = [
      zlib
      zstd
      xz
      numactl
      libdrm
      ncurses
      elfutils
      openssl
      libxml2
      libGL
      stdenv.cc.cc.lib
    ];

    # The bundle carries CUDA/other-vendor stubs it never dlopens on this path;
    # don't fail the build over their absent deps.
    autoPatchelfIgnoreMissingDeps = ["*"];

    unpackPhase = ''
      runHook preUnpack
      cat ${lib.concatStringsSep " " parts} | tar xz
      runHook postUnpack
    '';

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/opt/vllm-rocm
      cp -r ./* $out/opt/vllm-rocm/
      # Point lemonade's vllm.rocm_bin here. The bundle's own launcher sets the
      # ROCm LD_LIBRARY_PATH; wrap it to also expose the interpreter's lib dir.
      mkdir -p $out/bin
      makeWrapper $out/opt/vllm-rocm/bin/vllm-server $out/bin/vllm-server \
        --prefix LD_LIBRARY_PATH : "$out/opt/vllm-rocm/lib"
      runHook postInstall
    '';

    # Bundled ELFs already have long internal runpaths; keep them.
    dontStrip = true;

    meta = {
      description = "vLLM with ROCm backend for AMD Strix APUs (prebuilt, TheRock ROCm)";
      homepage = "https://github.com/lemonade-sdk/vllm-rocm";
      license = lib.licenses.asl20;
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      mainProgram = "vllm-server";
    };
  }
