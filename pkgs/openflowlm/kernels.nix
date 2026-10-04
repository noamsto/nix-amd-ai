# Builds OFLM's open NPU kernel sets (12 open_kernels recipe specs + 5 BERT
# embedding design sets) with no NPU and no pyxrt, thanks to upstream's
# device-free BERT export (Atomic-Germ/OpenFlowLM-Next#126, merged as 457ddfd);
# one derivation per set so Nix builds them in parallel, joined into the same
# $out/xclbins tree the previous monolithic derivation produced.
#
# The set list lives in ./kernel-sets.json (regenerate with
# ./update-kernel-sets.sh after a src bump); ./kernel-sets-plan.sh turns
# (src, list) into the serial execution order the join follows and reports
# drift in either direction, which the join recovers from rather than failing
# (see that script's header).
#
# Upstream quirk preserved exactly: gemma3-12b.json and gemma3-4b.json both
# carry extra.model = "Gemma3-4B-NPU2", so they export into the same directory.
# The serial build runs the specs in sorted order, so gemma3-12b's output is
# overwritten by gemma3-4b's; the join copies/builds in that same order, so the
# joined tree is what the serial build produces.
#
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
  jq,
}:
let
  kernelSets = builtins.fromJSON (builtins.readFile ./kernel-sets.json);

  # Every set derivation and the join need the same setup; it lives here once.
  setup = ''
    # export_gemm_rtp.py hard-codes ~/.npu/cache and fails if it is absent.
    export HOME=$TMPDIR/home
    mkdir -p $HOME/.npu/cache
    export PEANO_INSTALL_DIR=${llvm-aie}
    export PATH=${xrt}/opt/xilinx/xrt/bin:$PATH

    # The tree tracks FastFlowLM's closed sets under src/xclbins; clearing it
    # leaves each derivation holding only the sets it generates.
    rm -rf src/xclbins
    mkdir src/xclbins

    # The script's "best-effort" git clone of mlir-aie raises FileNotFoundError
    # when git is absent; the clone only feeds a mlir_aie_git_head provenance
    # string, so a pre-existing (empty) directory is enough to skip it.
    mkdir -p third_party/mlir-aie
    export MLIR_AIE_ROOT=$PWD/third_party/mlir-aie

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

    # One BERT family's export command, args read from families.json (the same
    # source export_bert_sets reads). $1 is the family name.
    bert_args() {
      # Assigned first: a jq failure inside < <(...) is invisible to errexit.
      local args common
      args=$(jq -r --arg n "$1" '.families[] | select(.name == $n) | .args[]' npu_offload/gemm_rtp/families.json)
      common=$(jq -r '.common[]' npu_offload/gemm_rtp/families.json)
      if [ -z "$args" ] || [ -z "$common" ]; then
        echo "error: no args/common for BERT family $1 in families.json" >&2
        return 1
      fi
      readarray -t _args <<<"$args"
      readarray -t _common <<<"$common"
      ./ironvenv/bin/python npu_offload/gemm_rtp/export_gemm_rtp.py "''${_args[@]}" "''${_common[@]}" --out "src/xclbins/$1"
    }
  '';

  meta = {
    description = "OpenFlowLM-Next open NPU kernel sets, built from source";
    # open_kernels and gemm_rtp are MIT; the xclbins embed mlir-aie's mm.cc
    # (Apache-2.0 WITH LLVM-exception).
    license = [lib.licenses.mit lib.licenses.asl20];
    platforms = ["x86_64-linux"];
  };

  mkSet = name: body: stdenv.mkDerivation {
    pname = "openflowlm-kernels-${name}";
    inherit version src;

    nativeBuildInputs = [mlir-aie.passthru.python jq];

    dontConfigure = true;

    # The set's own build time, so the critical path is visible in `nix build
    # -L` output.
    buildPhase = ''
      runHook preBuild
      ${setup}
      SECONDS=0
      ${body}
      echo "openflowlm-kernels: ${name} set build took ''${SECONDS}s"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a src/xclbins $out/
      runHook postInstall
    '';

    meta = meta // {
      description = "OpenFlowLM-Next open NPU kernel set ${name}";
    };
  };

  # A set listed in kernel-sets.json but absent from src still evaluates: it
  # warns and produces an empty output rather than failing.
  absent = name: kind: ''
    echo "WARNING: ${kind} '${name}' is listed in kernel-sets.json but absent from src; producing an empty per-set output. Run pkgs/openflowlm/update-kernel-sets.sh to refresh the list." >&2
  '';

  mkLlm = name: mkSet name ''
    spec=open_kernels/recipes/specs/${name}.json
    if [ -f "$spec" ]; then
      ./ironvenv/bin/python open_kernels/export_qwen36_kernels.py --spec "$spec" --force
    else
      ${absent name "kernel set"}
    fi
  '';

  mkBert = name: mkSet name ''
    if jq -e --arg n "${name}" '.families[] | select(.name == $n)' npu_offload/gemm_rtp/families.json >/dev/null; then
      bert_args ${name}
    else
      ${absent name "BERT family"}
    fi
  '';

  join = stdenv.mkDerivation {
    pname = "openflowlm-kernels";
    inherit version src;

    nativeBuildInputs = [mlir-aie.passthru.python jq];

    dontConfigure = true;

    # Flake-evaluable per-set derivations, for the CI matrix and tooling.
    passthru.sets = lib.listToAttrs (
      map (n: lib.nameValuePair n (mkLlm n)) kernelSets.llmSpecs
      ++ map (n: lib.nameValuePair n (mkBert n)) kernelSets.bertFamilies
    );

    buildPhase = ''
      runHook preBuild
      ${setup}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/xclbins

      # A copied store path is read-only; the later gemma3-4b copy writes into
      # gemma3-12b's already-copied Gemma3-4B-NPU2 dir, so re-open the tree
      # before each copy (Nix makes the final $out read-only again).
      copy_llm() {
        case "$1" in
      ${lib.concatMapStrings (n: ''
          ${n}) chmod -R u+w $out/xclbins; cp -a ${mkLlm n}/xclbins/. $out/xclbins/ ;;
      '') kernelSets.llmSpecs}
          *) return 1 ;;
        esac
      }
      copy_bert() {
        case "$1" in
      ${lib.concatMapStrings (n: ''
          ${n}) chmod -R u+w $out/xclbins; cp -a ${mkBert n}/xclbins/. $out/xclbins/ ;;
      '') kernelSets.bertFamilies}
          *) return 1 ;;
        esac
      }

      bash ${./kernel-sets-plan.sh} . ${./kernel-sets.json} > plan.txt

      build_LLM() {
        ./ironvenv/bin/python open_kernels/export_qwen36_kernels.py --spec "open_kernels/recipes/specs/$1.json" --force
      }
      build_BERT() { bert_args "$1"; }

      source ${./kernel-sets-join.sh}
      execute_plan plan.txt $out/xclbins

      # Same validation the monolithic export ran after the BERT sets.
      python3.12 npu_offload/gemm_rtp/check_design_sets.py --xclbins $out/xclbins

      runHook postInstall
    '';

    meta = meta;
  };
in
join