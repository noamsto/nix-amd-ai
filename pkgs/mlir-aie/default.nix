# mlir-aie 1.4.2, repackaged from the upstream GitHub-release wheel.
#
# The wheel is a fixed-output derivation because mlir-aie is not on PyPI and
# building it from source needs ROCm's pinned LLVM fork plus eudsl-python-extras
# (see docs/research/openflowlm.md §3). `autoPatchelfHook` runs once here rather
# than per consumer build; the only libs missing from the wheel are libstdc++
# and zlib.
#
# Layout: the `aie` Python package derives its install root as
# `realpath(<site-packages>/aie/utils/../../..)` and then expects `bin/aiecc`,
# `include/`, `aie_runtime_lib/`, etc. as siblings of `site-packages`
# (`aie/utils/configure.py`), while `aie/tools/__init__.py` derives the same dir
# as `dirname(tools)/../../../bin`. Putting the wheel's bin/lib/include/runtime
# trees under `$out/lib/python3.12/` and `aie` under
# `$out/lib/python3.12/site-packages/aie` satisfies both, so
# `PYTHONPATH=$out/lib/python3.12/site-packages python3.12 -c 'import aie'`
# works with no `.pth` processing.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
  zlib,
  python312,
  bash,
  llvm-aie ? null,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "mlir-aie";
  version = "1.4.2";

  src = fetchurl {
    url = "https://github.com/Xilinx/mlir-aie/releases/download/v${finalAttrs.version}/mlir_aie-${finalAttrs.version}-cp312-cp312-manylinux_2_35_x86_64.whl";
    hash = "sha256-4yHG+WToIxDP97CrByvfLNvO2+NX7H3wUrgZPjDB6tA=";
  };

  nativeBuildInputs = [
    unzip
    autoPatchelfHook
    python312
    bash
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

    libpy=$out/lib/python3.12
    mkdir -p "$libpy/site-packages" "$out/bin" "$out/lib"

    cp -r mlir_aie/bin "$libpy/bin"
    cp -r mlir_aie/include "$libpy/include"
    cp -r mlir_aie/lib "$libpy/lib"
    cp -r mlir_aie/runtime_lib "$libpy/runtime_lib"
    cp -r mlir_aie/aie_runtime_lib "$libpy/aie_runtime_lib"
    cp -r mlir_aie/python/aie "$libpy/site-packages/aie"
    cp -r mlir_aie/python/eudsl_python_extras-*.dist-info "$libpy/site-packages/"
    # Keep the distribution metadata so importlib.metadata can resolve mlir-aie
    # and its declared Requires-Dist.
    cp -r mlir_aie-*.dist-info "$libpy/site-packages/"

    # aie/utils/configure.py resolves PEANO_INSTALL_DIR, then $aie_dir/peano; make
    # the sibling llvm-aie package findable there when it is passed in.
    ${lib.optionalString (llvm-aie != null) ''
      ln -s ${llvm-aie} "$libpy/peano"
    ''}

    # libcrypto-ee446395.so.3 is reached through the binaries' $ORIGIN/../../mlir_aie.libs
    # runpath; from $libpy/bin that resolves to $out/lib, so it must land here.
    cp -r mlir_aie.libs "$out/lib/mlir_aie.libs"

    for tool in "$libpy"/bin/*; do
      ln -s "$tool" "$out/bin/$(basename "$tool")"
    done
    patchShebangs "$libpy/bin"

    runHook postInstall
  '';

  dontConfigure = true;
  dontBuild = true;
  # Prebuilt release binaries; stripping buys little and risks the .so set.
  dontStrip = true;

  passthru = {
    pythonPath = "${finalAttrs.finalPackage}/lib/python3.12/site-packages";
    # The wheel's METADATA declares numpy, rich, aiofiles, ml_dtypes and
    # cloudpickle at runtime; no pip here, so the deps are carried by this env.
    # With the package on PYTHONPATH, e.g.
    #   PYTHONPATH=${mlir-aie.passthru.pythonPath} ${mlir-aie.passthru.python}/bin/python3.12 -c 'import aie.iron'
    # anyio's own test suite fails on this CPython (PurePosixPath._tail_cached,
    # TLS client-mode tests), and it is only a test-time dependency here.
    python = (python312.override {
      packageOverrides = _: prev: {
        anyio = prev.anyio.overridePythonAttrs {doCheck = false;};
      };
    }).withPackages (ps: [
      ps.numpy
      ps."ml-dtypes"
      ps.rich
      ps.aiofiles
      ps.cloudpickle
    ]);
  };

  meta = with lib; {
    description = "MLIR-based toolchain for AMD AI Engine (AIE) devices";
    homepage = "https://github.com/Xilinx/mlir-aie";
    license = licenses.asl20;
    platforms = ["x86_64-linux"];
    mainProgram = "aiecc";
  };
})
