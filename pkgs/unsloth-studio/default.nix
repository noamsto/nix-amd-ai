{
  lib,
  buildFHSEnv,
  writeShellScript,
  writeText,
  runCommand,
  fetchurl,
  uv,
  git,
  curl,
  util-linux,
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

  # Upstream's installer is served unpinned, so fetch it by commit: the commit
  # pins the installer itself and the torch routing. Its normal path still runs
  # an unversioned `uv pip install unsloth`; UV_CONSTRAINT (below) pins unsloth
  # and unsloth-zoo to `version`. Transitive wheels are not hash-pinned.
  installer = fetchurl {
    url = "https://raw.githubusercontent.com/unslothai/unsloth/078b962742873cf5dcf2b33cb1aee806f4152afe/install.sh";
    hash = "sha256-NepeusGNaGDEbra05Dq/YFKDRIcFMHEyHqXYLl4KeFU=";
  };

  # The installer wants a directory holding `llama-server` at its root. GGUF
  # export also reads `llama-quantize` and the converter scripts from there; the
  # scripts come from the source, because the package's bin/ entries are wrapper
  # scripts, and `gguf-py` and `conversion/` must sit beside the entrypoint.
  llamaDir = runCommand "unsloth-studio-llama-server" {} ''
    mkdir -p $out
    ln -s ${llama-cpp-vulkan}/bin/llama-server $out/llama-server
    ln -s ${llama-cpp-vulkan}/bin/llama-quantize $out/llama-quantize
    for f in convert_hf_to_gguf.py convert_lora_to_gguf.py conversion gguf-py; do
      ln -s ${llama-cpp-vulkan.src}/$f $out/$f
    done
  '';

  constraints = writeText "unsloth-constraints.txt" "unsloth==${version}\nunsloth-zoo==${version}\n";

  # The store path basename leads with the installer's content hash, so the
  # stamp changes whenever the installer does.
  pin = ".pin-${version}-${target}-${builtins.substring 0 12 (baseNameOf (toString installer))}";

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

    export UV_CONSTRAINT=${constraints}

    if [ ! -e "$state/${pin}" ]; then
      exec 9>"$state/.install.lock"
      flock -w 1800 9 || {
        echo "unsloth-studio: another instance has held the install lock for 30 min" >&2
        exit 1
      }
      if [ ! -e "$state/${pin}" ]; then
        bash ${installer} \
          --with-llama-cpp-dir ${llamaDir}
        touch "$state/${pin}"
      fi
      exec 9>&-
    fi

    # The installer links its llama.cpp dir under UNSLOTH_HOME if set, else
    # under the state dir when that is not the default, else ~/.unsloth;
    # refresh it so a GC or flake bump cannot leave it pointing at a deleted
    # store path. A user-set UNSLOTH_LLAMA_CPP_PATH is left alone.
    if [ -z "''${UNSLOTH_LLAMA_CPP_PATH:-}" ]; then
      if [ -n "''${UNSLOTH_HOME:-}" ]; then
        root="$UNSLOTH_HOME"
      elif [ "$state" != "$HOME/.unsloth/studio" ]; then
        root="$state"
      else
        root="$HOME/.unsloth"
      fi
      mkdir -p "$root"
      llama_link="$root/llama.cpp"
      # GGUF export patches the converter and its gguf-py in place, so the dir
      # must be writable: binaries stay store symlinks, the Python sources are
      # copied. The marker file identifies a dir this wrapper owns; a user's own
      # llama.cpp checkout is left alone.
      marker="$llama_link/.unsloth-studio-llamadir"
      exec 8>"$root/.llama.cpp.lock"
      flock 8
      if [ ! -e "$llama_link" ] || [ -L "$llama_link" ] || [ -f "$marker" ]; then
        if [ "$(cat "$marker" 2>/dev/null)" != ${llamaDir} ]; then
          # Built beside the target and swapped in, so a kill mid-rebuild never
          # leaves a half-deleted directory behind. The installer's own
          # ownership marker lets it replace this dir with its link on a pin bump.
          new="$root/.llama.cpp.new"
          rm -rf "$new" "$root/.llama.cpp.old"
          mkdir "$new"
          : >"$new/.unsloth-studio-owned"
          for f in llama-server llama-quantize; do
            ln -s ${llamaDir}/$f "$new/$f"
          done
          for f in convert_hf_to_gguf.py convert_lora_to_gguf.py conversion gguf-py; do
            cp -rL --no-preserve=mode ${llamaDir}/$f "$new/$f"
          done
          echo ${llamaDir} >"$new/.unsloth-studio-llamadir"
          if [ -e "$llama_link" ] || [ -L "$llama_link" ]; then
            mv -T "$llama_link" "$root/.llama.cpp.old"
          fi
          mv -T "$new" "$llama_link"
          rm -rf "$root/.llama.cpp.old"
        fi
      fi
      exec 8>&-
      # Unsloth resolves its llama.cpp dir from the real home otherwise, even
      # when the state dir is elsewhere.
      export UNSLOTH_LLAMA_CPP_PATH="$llama_link"
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
      util-linux
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
