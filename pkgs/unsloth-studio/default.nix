{
  lib,
  buildFHSEnv,
  writeShellScript,
  runCommand,
  fetchurl,
  uv,
  git,
  curl,
  cmake,
  gcc,
  gnumake,
  zlib,
  libdrm,
  numactl,
  openssl,
  cacert,
  stdenv,
  llama-cpp-vulkan,
  gpuTarget ? "gfx1151",
}: let
  version = "2026.11.9";

  supportedTargets = ["gfx1150" "gfx1151"];
  target =
    if lib.elem gpuTarget supportedTargets
    then gpuTarget
    else throw "unsloth-studio: no AMD torch index for gpuTarget '${gpuTarget}' (have: ${lib.concatStringsSep ", " supportedTargets})";

  torchIndex = "https://repo.amd.com/rocm/whl/${target}/";

  # Upstream's installer is served unpinned and its --package flag takes a
  # name only, so fetch it by commit: the commit fixes the unsloth floor
  # (version) and the torch routing; PyPI still supplies the newest release.
  installer = fetchurl {
    url = "https://raw.githubusercontent.com/unslothai/unsloth/078b962742873cf5dcf2b33cb1aee806f4152afe/install.sh";
    hash = "sha256-NepeusGNaGDEbra05Dq/YFKDRIcFMHEyHqXYLl4KeFU=";
  };

  # The installer wants a directory holding `llama-server` at its root.
  llamaDir = runCommand "unsloth-studio-llama-server" {} ''
    mkdir -p $out
    ln -s ${llama-cpp-vulkan}/bin/llama-server $out/llama-server
  '';

  pin = ".pin-${version}-${target}";

  runScript = writeShellScript "unsloth-studio-run" ''
    set -euo pipefail
    state="''${UNSLOTH_STUDIO_HOME:-$HOME/.unsloth/studio}"
    mkdir -p "$state"

    export UNSLOTH_STUDIO_HOME="$state"
    export UNSLOTH_ROCM_GFX_ARCH=${target}
    export UNSLOTH_TORCH_INDEX_URL=${torchIndex}
    export UNSLOTH_SKIP_AUTOSTART=1
    export UNSLOTH_MOE_BACKEND=native_torch
    export UNSLOTH_COMPILE_LOCATION="$state/compile-cache"
    export HF_HUB_DISABLE_XET=1
    # The host's nix Python has no Python.h, which Triton needs to compile its
    # HIP launcher; a uv-managed CPython ships its headers.
    export UV_PYTHON_PREFERENCE=only-managed
    # Python's urllib reads no system store in the FHS env: Studio's own
    # Hugging Face config/tokenizer fetches fail certificate verification.
    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt

    if [ ! -e "$state/${pin}" ]; then
      bash ${installer} \
        --with-llama-cpp-dir ${llamaDir}
      touch "$state/${pin}"
    fi

    if [ "$#" -eq 0 ]; then
      set -- studio -p 8888
    fi
    exec "$state/unsloth_studio/bin/unsloth" "$@"
  '';
in
  buildFHSEnv {
    name = "unsloth-studio";
    inherit runScript;
    targetPkgs = _: [
      uv
      git
      curl
      cmake
      gcc
      gnumake
      zlib
      libdrm
      numactl
      openssl
      cacert
      stdenv.cc.cc.lib
    ];
    meta = {
      description = "Unsloth Studio fine-tuning UI in an FHS env with AMD ROCm torch (AGPL-3.0)";
      homepage = "https://github.com/unslothai/unsloth";
      license = lib.licenses.agpl3Only;
      platforms = ["x86_64-linux"];
      mainProgram = "unsloth-studio";
    };
  }
