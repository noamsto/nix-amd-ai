# vLLM ROCm for AMD Strix (gfx1150/gfx1151), repackaged from the upstream
# lemonade-sdk/vllm-rocm prebuilt. We relocate their portable TheRock ROCm +
# torch + vLLM bundle rather than build vLLM from source: nixpkgs rocmPackages
# is far behind ROCm 7.15 and lacks the Strix gfx targets. Lemonade launches the
# resulting `vllm-server` via the `vllm.rocm_bin` config override wired in the
# NixOS module. See noamsto/nix-amd-ai#63.
#
# NOTE: deliberately NOT autoPatchelf'd. The bundle is self-contained — it ships
# its own `rocm_sysdeps` (numa/drm/elf/lzma) and resolves its .so via internal
# $ORIGIN runpaths. autoPatchelfHook rewrites those runpaths and injects nixpkgs
# libs (gcc-15 libstdc++/libatomic) that mismatch the Ubuntu-built torch, which
# segfaults on `import torch`. Instead we only repoint the ELF interpreter to the
# nix loader and supply the two genuinely-missing system libs (libstdc++, libz)
# via the launcher's LD_LIBRARY_PATH.
{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  makeWrapper,
  bash,
  coreutils,
  zlib,
  gpuTarget ? "gfx1150",
}: let
  sources = import ./sources.nix;
  src =
    sources.${gpuTarget}
    or (throw "vllm-rocm: no prebuilt for gpuTarget '${gpuTarget}' (have: ${lib.concatStringsSep ", " (lib.attrNames sources)})");
  parts = map (p: fetchurl {inherit (p) url hash;}) src.parts;
  # Ubuntu-built torch/ROCm want these from the system; the bundle omits them.
  runtimeLibs = lib.makeLibraryPath [stdenv.cc.cc.lib zlib];
in
  stdenv.mkDerivation {
    pname = "vllm-rocm";
    inherit (src) version;

    # Two <2 GB GitHub assets that concatenate into one .tar.gz.
    srcs = parts;

    nativeBuildInputs = [patchelf makeWrapper];

    unpackPhase = ''
      runHook preUnpack
      cat ${lib.concatStringsSep " " parts} | tar xz
      runHook postUnpack
    '';

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      prefix=$out/opt/vllm-rocm
      mkdir -p $prefix
      cp -r ./* $prefix/

      # Upstream tars the venv with no exec bits (everything is 0644), so the
      # interpreter and launchers can't run. Restore +x on the bundled binaries.
      # The bundled clang matters too: the launcher chmod +x's it at runtime,
      # which silently no-ops on the read-only store, so pre-mark it here.
      chmod -R u+x $prefix/bin
      for d in $prefix/lib/python3.*/site-packages/_rocm_sdk_*/bin \
               $prefix/lib/python3.*/site-packages/_rocm_sdk_*/lib/llvm/bin; do
        [ -d "$d" ] && chmod -R u+x "$d"
      done

      # Repoint the ELF interpreter (FHS /lib64/ld-linux-x86-64.so.2 -> nix
      # loader) on the executables the launcher actually execs — python3 and the
      # bundled clang (Triton JIT). Leave every runpath intact.
      loader=${stdenv.cc.bintools.dynamicLinker}
      for exe in $prefix/bin/python3 $prefix/bin/python3.* \
                 $prefix/lib/python3.*/site-packages/_rocm_sdk_*/lib/llvm/bin/clang; do
        if [ -f "$exe" ] && patchelf --print-interpreter "$exe" >/dev/null 2>&1; then
          patchelf --set-interpreter "$loader" "$exe"
        fi
      done

      # Launcher shebang is #!/bin/bash (FHS); rewrite to the nix bash.
      patchShebangs $prefix/bin/vllm-server

      # The torch/numpy/scipy/... wheels are auditwheel-repaired: each native ext
      # carries an $ORIGIN RUNPATH to a sibling *.libs dir. That $ORIGIN doesn't
      # resolve reliably once relocated into the store, so surface every *.libs
      # dir on LD_LIBRARY_PATH explicitly.
      auditLibs=""
      for d in $prefix/lib/python3.*/site-packages/*.libs; do
        [ -d "$d" ] && auditLibs="$auditLibs:$d"
      done

      # lemonade's vllm.rocm_bin points at $out/bin/vllm-server. The launcher
      # prepends the bundle's ROCm/torch lib dirs to LD_LIBRARY_PATH but relies
      # on the system for libstdc++/libz; supply those and the coreutils it calls.
      mkdir -p $out/bin
      makeWrapper $prefix/bin/vllm-server $out/bin/vllm-server \
        --prefix PATH : ${lib.makeBinPath [bash coreutils]} \
        --prefix LD_LIBRARY_PATH : "${runtimeLibs}$auditLibs"
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
