# Builds OFLM's open NPU kernel sets (12 open_kernels recipe specs + 5 BERT
# embedding design sets) with no NPU and no pyxrt, thanks to upstream's
# device-free BERT export (Atomic-Germ/OpenFlowLM-Next#126, merged as 457ddfd);
# ~50 min on halo. Upstream quirk: gemma3-12b.json names
# no model, so its set lands under and is overwritten by Gemma3-4B-NPU2.
# xclbins are not bit-reproducible (UUID/timestamp fields); insts*.bin and
# design.json are.
{
  lib,
  stdenv,
  src,
  version,
  mlir-aie,
  llvm-aie,
  xrt,
}:
stdenv.mkDerivation {
  pname = "openflowlm-kernels";
  inherit version src;

  nativeBuildInputs = [mlir-aie.passthru.python];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # export_gemm_rtp.py hard-codes ~/.npu/cache and fails if it is absent.
    export HOME=$TMPDIR/home
    mkdir -p $HOME/.npu/cache
    export PEANO_INSTALL_DIR=${llvm-aie}
    export PATH=${xrt}/opt/xilinx/xrt/bin:$PATH

    # The tree tracks FastFlowLM's closed sets under src/xclbins; clearing it
    # leaves $out holding only the sets this derivation generates.
    rm -rf src/xclbins
    mkdir src/xclbins

    # The script's "best-effort" git clone of mlir-aie raises FileNotFoundError
    # when git is absent; the clone only feeds a mlir_aie_git_head provenance
    # string, so a pre-existing (empty) directory is enough to skip it.
    mkdir -p third_party/mlir-aie

    # export-kernels.py hard-codes REPO/ironvenv and looks for Peano under its
    # site-packages/llvm-aie/bin.
    mkdir -p ironvenv/bin ironvenv/lib/python3.12/site-packages
    ln -s ${llvm-aie} ironvenv/lib/python3.12/site-packages/llvm-aie

    # importlib.metadata.version("llvm-aie") needs a dist-info to resolve, so
    # toolchain.json records the real Peano version instead of failing.
    distinfo=ironvenv/lib/python3.12/site-packages/llvm_aie-${llvm-aie.version}.dist-info
    mkdir -p "$distinfo"
    cat > "$distinfo/METADATA" <<EOF
    Metadata-Version: 2.1
    Name: llvm-aie
    Version: ${llvm-aie.version}
    EOF

    site=$PWD/ironvenv/lib/python3.12/site-packages
    cat > ironvenv/bin/python <<EOF
    #!${stdenv.shell}
    export PYTHONPATH=${mlir-aie.passthru.pythonPath}:$site\''${PYTHONPATH:+:\$PYTHONPATH}
    exec ${mlir-aie.passthru.python}/bin/python3.12 "\$@"
    EOF
    chmod +x ironvenv/bin/python

    python3.12 utilities/export-kernels.py --force

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r src/xclbins $out/
    runHook postInstall
  '';

  meta = {
    description = "OpenFlowLM-Next open NPU kernel sets, built from source";
    # open_kernels and gemm_rtp are MIT; the xclbins embed mlir-aie's mm.cc
    # (Apache-2.0 WITH LLVM-exception).
    license = [lib.licenses.mit lib.licenses.asl20];
    platforms = ["x86_64-linux"];
  };
}
