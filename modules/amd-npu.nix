{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf mkDefault types optionalString optional optionals optionalAttrs versionAtLeast concatStringsSep;
  cfg = config.hardware.amd-npu;

  # The Tauri desktop app is the only part of lemonade that pulls a Rust/npm
  # build (and a crates.io cargo-vendor fetch). Headless/server hosts can drop
  # it via withDesktopApp = false so `enableLemonade` doesn't drag in that
  # build path. See noamsto/nix-amd-ai#28.
  lemonadePackage = pkgs.lemonade.override {withDesktopApp = cfg.lemonade.desktopApp.enable;};

  vllmPkg = pkgs.vllm-rocm.override {gpuTarget = cfg.vllmGpuTarget;};

  # 4096-byte pages: pages = GiB * 1024^3 / 4096 = GiB * 262144.
  gttPages = gib: gib * 262144;

  # Optional " page_pool_size=…" clause appended to the ttm modprobe line.
  ttmPagePoolClause =
    optionalString (cfg.gpuMemory.pagePoolSizeGiB != null)
    " page_pool_size=${toString (gttPages cfg.gpuMemory.pagePoolSizeGiB)}";

  xrtPrefix = "${pkgs.xrt}/opt/xilinx/xrt";

  xrt-combined = pkgs.runCommand "xrt-combined" {} ''
    mkdir -p $out
    cp -rs ${xrtPrefix}/* $out/
    chmod -R u+w $out/lib
    ln -sf ${pkgs.xrt-plugin-amdxdna}/opt/xilinx/xrt/lib/libxrt_driver_xdna* $out/lib/
  '';

  # XRT (NPU) libs only present when enableNPU; ROCm libs trail them.
  ldLibraryPath = concatStringsSep ":" (
    optional cfg.enableNPU "${xrt-combined}/lib"
    ++ optional cfg.enableROCm "${pkgs.rocmPackages.clr}/lib"
  );

  pathList =
    optional cfg.enableNPU xrt-combined
    ++ optional cfg.enableFastFlowLM pkgs.fastflowlm;

  # Stable /etc indirection for lemonade's backend binaries. v10.7.0 reads bin
  # paths only from config.json (it dropped the LEMONADE_*_BIN env→config
  # migration), and a cached config.json overrides our seed — so a raw
  # /nix/store path would dangle after a backend bump + GC. These /etc symlinks
  # retarget each generation; config.json caches the stable path, the symlink
  # follows the store.
  lemonadeBackendBin = name: "/etc/lemonade/backends/${name}";
  lemonadeBackendEtc =
    optionalAttrs cfg.enableLemonade {
      "lemonade/backends/llamacpp-cpu".source = "${pkgs.llama-cpp}/bin/llama-server";
      "lemonade/backends/whispercpp-cpu".source = "${pkgs.whisper-cpp}/bin/whisper-server";
    }
    // optionalAttrs (cfg.enableLemonade && cfg.enableImageGen) {
      "lemonade/backends/sdcpp-cpu".source = "${pkgs.stable-diffusion-cpp}/bin/sd-server";
    }
    // optionalAttrs (cfg.enableLemonade && cfg.enableROCm) {
      "lemonade/backends/llamacpp-rocm".source = "${pkgs.llama-cpp-rocm}/bin/llama-server";
    }
    // optionalAttrs (cfg.enableLemonade && cfg.enableROCm && cfg.enableImageGen) {
      "lemonade/backends/sdcpp-rocm".source = "${pkgs.stable-diffusion-cpp-rocm}/bin/sd-server";
    }
    // optionalAttrs (cfg.enableLemonade && cfg.enableROCm && cfg.enableVllm) {
      "lemonade/backends/vllm-rocm".source = "${vllmPkg}/bin/vllm-server";
    }
    // optionalAttrs (cfg.enableLemonade && cfg.enableVulkan) {
      "lemonade/backends/llamacpp-vulkan".source = "${pkgs.llama-cpp-vulkan}/bin/llama-server";
      "lemonade/backends/whispercpp-vulkan".source = "${pkgs.whisper-cpp-vulkan}/bin/whisper-server";
    }
    // optionalAttrs (cfg.enableLemonade && cfg.enableVulkan && cfg.enableImageGen) {
      "lemonade/backends/sdcpp-vulkan".source = "${pkgs.stable-diffusion-cpp-vulkan}/bin/sd-server";
    };

  # defaults.json seed that lemonade's get_defaults() merges over its packaged
  # defaults (via the LEMONADE_DEFAULTS_PATH patch in pkgs/lemonade). Carries
  # the backend bin paths plus global_timeout / flash-attn, all of which lost
  # their env hook when v10.7.0 removed migrate_from_env.
  lemonadeDefaults =
    {
      # 0 disables lemond's 300s request cutoff for llama.cpp (lemonade#1364).
      # But vLLM passes this same value as its startup-readiness timeout, where
      # 0 means "0 attempts" and the server never gets time to boot — so give it
      # a large finite window instead. See noamsto/nix-amd-ai#63.
      global_timeout =
        if cfg.enableVllm
        then 3600
        else 0;
      llamacpp =
        {
          args = "--flash-attn ${cfg.lemonade.flashAttn}";
          cpu_bin = lemonadeBackendBin "llamacpp-cpu";
        }
        // optionalAttrs cfg.enableROCm {rocm_bin = lemonadeBackendBin "llamacpp-rocm";}
        // optionalAttrs cfg.enableVulkan {vulkan_bin = lemonadeBackendBin "llamacpp-vulkan";};
      whispercpp =
        {cpu_bin = lemonadeBackendBin "whispercpp-cpu";}
        // optionalAttrs cfg.enableVulkan {vulkan_bin = lemonadeBackendBin "whispercpp-vulkan";};
    }
    // optionalAttrs cfg.enableFastFlowLM {
      # v10.10.0 gates FLM-on-PATH discovery behind this flag; without it lemond
      # ignores the flm we put on its PATH and reports the NPU backend as "not
      # installed", so no FLM models list. See noamsto/nix-amd-ai#62.
      flm.prefer_system = true;
    }
    // optionalAttrs cfg.enableImageGen {
      sdcpp =
        {cpu_bin = lemonadeBackendBin "sdcpp-cpu";}
        // optionalAttrs cfg.enableROCm {rocm_bin = lemonadeBackendBin "sdcpp-rocm";}
        // optionalAttrs cfg.enableVulkan {vulkan_bin = lemonadeBackendBin "sdcpp-vulkan";};
    }
    // optionalAttrs (cfg.enableROCm && cfg.enableVllm) {
      vllm.rocm_bin = lemonadeBackendBin "vllm-rocm";
    };
  lemonadeDefaultsFile =
    (pkgs.formats.json {}).generate "lemonade-defaults.json"
    (lib.recursiveUpdate lemonadeDefaults cfg.lemonade.settings);

  lemonadeCustomModelsFile =
    (pkgs.formats.json {}).generate "lemonade-user-models.json"
    cfg.lemonade.customModels;

  # LEMONADE_DEFAULTS_PATH only seeds config.json on lemond's first run — after
  # that the persisted file wins for every key it holds, so module-declared
  # values rot. Re-apply ours each start. See noamsto/nix-amd-ai#67 and #68.
  lemonadeReconcile = pkgs.writeShellApplication {
    name = "lemond-reconcile-config";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      # 11.8.0 moved config.json out of the cache dir: ConfigFile::load reads it
      # only from config_dir, which lemond resolves as
      # $XDG_CONFIG_HOME/lemonade with a $HOME/.config fallback. Reconciling the
      # old cache path writes a file nothing reads, and module keys go inert the
      # moment lemond persists anything of its own.
      configDir="''${XDG_CONFIG_HOME:-''${HOME:-}/.config}/lemonade"

      config="$configDir/config.json"
      if [ -f "$config" ]; then
        tmp="$config.nix-reconcile"
        if jq -s '.[0] * .[1]' "$config" ${lemonadeDefaultsFile} >"$tmp"; then
          # lemond may have tightened the mode; rename would silently widen it back.
          chmod --reference="$config" "$tmp"
          mv "$tmp" "$config"
        else
          rm -f "$tmp"
          echo "lemond: $config is unreadable, leaving it untouched" >&2
        fi
      fi
    ''
    + optionalString (cfg.lemonade.customModels != {}) ''

      # Unlike config.json, this file is ours to create: lemond treats a missing
      # user_models.json as an empty registry rather than seeding one, so nothing
      # else makes it exist on a host that never opened the web UI.
      models="$configDir/user_models.json"
      mkdir -p "$configDir"
      [ -f "$models" ] || echo '{}' >"$models"

      tmp="$models.nix-reconcile"
      if jq -s '.[0] * .[1]' "$models" ${lemonadeCustomModelsFile} >"$tmp"; then
        chmod --reference="$models" "$tmp"
        mv "$tmp" "$models"
      else
        rm -f "$tmp"
        echo "lemond: $models is unreadable, leaving it untouched" >&2
      fi
    '';
  };

  # `lemonade pull` is an HTTP client for lemond, so models can only be
  # reconciled against a running server — an activation script can't do it.
  lemonadeModelSync = pkgs.writeShellApplication {
    name = "lemond-sync-models";
    runtimeInputs = [lemonadePackage pkgs.gawk pkgs.coreutils];
    text = ''
      declared=(${lib.escapeShellArgs cfg.lemonade.models})

      # Unit ordering only guarantees lemond's process started, not that its
      # port answers.
      for _ in $(seq 60); do
        if lemonade status >/dev/null 2>&1; then break; fi
        sleep 2
      done
      if ! lemonade status >/dev/null 2>&1; then
        echo "lemond unreachable after 120s; leaving models alone" >&2
        exit 1
      fi

      # Column 1 of the `list` table, minus its header and rule lines.
      downloaded() {
        lemonade list --downloaded \
          | awk 'NR > 2 && NF && $1 !~ /^-+$/ {print $1}'
      }

      have=$(downloaded)
      for model in "''${declared[@]}"; do
        if grep -qxF "$model" <<<"$have"; then
          continue
        fi
        echo "pulling $model"
        lemonade pull "$model" || echo "failed to pull $model" >&2
      done
    ''
    + optionalString cfg.lemonade.pruneUnlistedModels ''

      for model in $(downloaded); do
        keep=false
        for want in "''${declared[@]}"; do
          if [ "$model" = "$want" ]; then
            keep=true
            break
          fi
        done
        if [ "$keep" = true ]; then continue; fi
        echo "deleting unlisted $model"
        lemonade delete "$model" || echo "failed to delete $model" >&2
      done
    '';
  };
in {
  options.hardware.amd-npu = {
    enable = mkEnableOption "AMD NPU (AI Engine) support";

    enableNPU = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to wire the XDNA-2 NPU stack (amdxdna kernel module, XRT,
        IOMMU/udev/memlock). Set false for GPU-only hosts — e.g. RDNA3 iGPUs
        (Radeon 780M / Phoenix / Hawk Point) that lack an XDNA-2 NPU — to keep
        the Vulkan/ROCm backends without pulling in the XRT closure.
      '';
    };

    enableFastFlowLM = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to install FastFlowLM NPU inference runtime.";
    };

    enableLemonade = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to enable the Lemonade AI server. Also enables nix-ld
        (overridable via `programs.nix-ld.enable`) so runtime-downloaded omni
        backends — e.g. the kokoro TTS ELF — can find a dynamic loader.
      '';
    };

    enableROCm = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to add ROCm libraries for GPU offload.";
    };

    enableVulkan = mkEnableOption "declarative Vulkan backend wiring for lemonade";

    enableImageGen = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to wire stable-diffusion.cpp recipes (sd-cpp:cpu, plus
        sd-cpp:rocm when enableROCm and sd-cpp:vulkan when enableVulkan) into
        lemonade. Disable to drop ~150 MB CPU-only / ~1.5 GB with ROCm from
        the closure if you only use lemonade for LLM inference.
      '';
    };

    enableVllm = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to wire the vLLM ROCm backend (vllm:rocm) into lemonade,
        repackaged from the upstream lemonade-sdk/vllm-rocm prebuilt. Requires
        enableROCm. Experimental — see noamsto/nix-amd-ai#63.
      '';
    };

    gpuTarget = mkOption {
      type = types.enum ["gfx1150" "gfx1151"];
      default = "gfx1150";
      description = ''
        The host's actual iGPU: gfx1150 (Strix Point) or gfx1151 (Strix
        Halo). Drives the gfx1151 CWSR-kernel warning and the default for
        vllmGpuTarget, so a llamacpp/sd-cpp-only host still declares its
        chip without touching a vLLM option.
      '';
    };

    vllmGpuTarget = mkOption {
      type = types.enum ["gfx1150" "gfx1151"];
      default = cfg.gpuTarget;
      defaultText = lib.literalExpression "config.hardware.amd-npu.gpuTarget";
      description = ''
        Which lemonade-sdk/vllm-rocm prebuilt to install: gfx1150 (Strix Point)
        or gfx1151 (Strix Halo). Each bundles a TheRock ROCm built for that
        exact target. Defaults to gpuTarget; override only if vLLM needs a
        different target than the host's real chip (e.g. testing). gfx1151
        needs a kernel with the CWSR fix, backported or not, or ROCm can
        crash any ROCm backend, not just vLLM (see the eval-time warning
        this module emits when enableROCm is also set).
      '';
    };

    exclusiveInference = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Make `lemond` and `ds4-server` mutually exclusive: starting either one
        stops the other, via systemd `Conflicts=`. No-op unless both are
        enabled.

        Off by default, because whether the two fit side by side is a property
        of the host rather than of the module — the sum of their resident models
        against physical RAM and the GTT pool they both draw from. Turn it on
        where they do not fit. Measured on a 128 GB Strix Halo at
        `ttmSizeGiB = 104`: an 80.76 GiB DeepSeek-V4-Flash under ds4 answers in
        1.3 s on its own, but with a 4B model also resident under lemond there
        is nothing left for page cache — lemond fell from 53 tok/s to 0.11, and
        then both endpoints stopped answering. Stopping either restores the
        other immediately.

        Pair it with `autoStart` to choose which server owns the box at boot.
      '';
    };

    lemonade = {
      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether `lemond` (and the `lemond-models` puller, which requires it)
          start at boot.

          Set false to leave lemond built and available but idle, started on
          demand with `systemctl start lemond`. Useful with
          `exclusiveInference`, where only one server can own the box.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 13305;
        description = "Port for the Lemonade server.";
      };

      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "Host address for the Lemonade server to bind to.";
      };

      user = mkOption {
        type = types.str;
        description = "User account to run the Lemonade server as.";
      };

      cacheDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/var/lib/models";
        description = ''
          Root for lemond's two model caches, relocating them off the service
          user's home: `HF_HOME` becomes `''${cacheDir}/hf` (weights land in
          `hf/hub`, per the Hugging Face convention lemonade's `models_dir =
          "auto"` follows) and `LEMONADE_CACHE_DIR` becomes
          `''${cacheDir}/lemonade`.

          Worth setting on any host with storage tuned for weights, because
          both caches get large — 147 GB and 9.9 GB respectively on a host that
          has been serving for a while — and `$HOME` is rarely the subvolume you
          want them on.

          A runtime path, deliberately a string so it is not copied into the Nix
          store. The `hf` and `lemonade` subdirectories must exist and be
          writable by `user`; the unit does not create them, since this is
          typically a mountpoint the host manages.

          Setting `settings.models_dir` explicitly overrides the `HF_HOME` half.
        '';
      };

      desktopApp.enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to build and install the Lemonade desktop app (the Tauri
          shell around the web UI). This is the only part of lemonade that
          requires a Rust + npm build and a crates.io cargo-vendor fetch.
          Set false on headless/server hosts to skip that build path entirely
          and ship only the `lemond` server + CLI.
        '';
      };

      flashAttn = mkOption {
        type = types.enum ["auto" "on" "off"];
        default = "on";
        description = ''
          Value passed as `--flash-attn` to lemond-spawned llama-server. Defaults to "on"
          because upstream lemonade doesn't enable FA for llama-cpp despite enabling it
          for vLLM (see vllm_server.cpp:202); measured ~5% decode / ~10% prefill gain on
          gfx1150 + Gemma. Set "auto" or "off" to override.
        '';
      };

      settings = mkOption {
        type = (pkgs.formats.json {}).type;
        default = {};
        example = lib.literalExpression ''
          {
            max_loaded_models = -1;
            auto_evict = true;
          }
        '';
        description = ''
          Extra keys merged into lemond's runtime config, overriding the values
          this module computes. Accepts anything `RuntimeConfig` validates —
          e.g. `max_loaded_models` (-1 for unlimited, so a small NPU model and a
          large GPU model can stay resident together instead of taking turns),
          and `auto_evict` (opt-in idle/VRAM-pressure eviction, off by default)
          with its `auto_evict_threshold_pct`.

          These keys are re-applied on every `lemond` start, so they stay
          declarative; keys not listed here are left to whatever the web UI
          persisted in `''${XDG_CONFIG_HOME:-~/.config}/lemonade/config.json`.
        '';
      };

      allowedOrigins = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["https://app.example.com" "http://192.168.1.10:3000"];
        description = ''
          Origins allowed to make cross-origin browser requests, emitted as
          `LEMONADE_ALLOWED_ORIGINS`. Env-only upstream — there is no
          config.json key, so `lemonade.settings` cannot reach it.

          Loopback and non-http(s) desktop schemes (tauri://, file://) are
          always allowed, so this is only needed for browsers on other
          machines reaching a non-loopback `lemonade.host`. `["*"]` allows
          any origin, which without an API key leaves the server open to any
          site the browser visits.
        '';
      };

      customModels = mkOption {
        type = (pkgs.formats.json {}).type;
        default = {};
        example = lib.literalExpression ''
          {
            "gpt-oss-120b-MXFP4-GGUF" = {
              checkpoints.main = "ggml-org/gpt-oss-120b-GGUF:gpt-oss-120b-MXFP4.gguf";
              recipe = "llamacpp";
              recipe_options.ctx_size = 131072;
              labels = ["chat" "reasoning" "tool-calling"];
              size = 63.4;
            };
          }
        '';
        description = ''
          Models registered by checkpoint rather than by registry name, merged
          into `''${XDG_CONFIG_HOME:-~/.config}/lemonade/user_models.json`.
          Reaches quantizations and repos the built-in registry doesn't carry.

          Re-applied on every `lemond` start, so these stay declarative; models
          registered through the web UI are left alone. An entry's
          `recipe_options` block is that model's default — `recipe_options.json`
          still layers the UI's per-model overrides on top of it.

          A built-in of the same name is not replaced: lemond keys built-ins
          bare and these as `user.<name>`, so both show in `lemonade list`.
        '';
      };

      models = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["Qwen3.5-4B-MTP-GGUF" "llama3.2-1b-FLM"];
        description = ''
          Models to keep downloaded, named as `lemonade list` reports them.
          Missing ones are pulled by a `lemond-models` unit; models already on
          disk are left alone, so re-activating costs nothing.

          The pull runs in the background — the unit is `Type=simple`, so
          systemd calls it started the moment it forks and `nixos-rebuild
          switch` returns without waiting on multi-GiB downloads. Follow it
          with `journalctl -fu lemond-models`. A model that fails to pull is
          logged and skipped rather than failing the unit, so one bad name
          can't block the rest.
        '';
      };

      pruneUnlistedModels = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Also delete downloaded models that `lemonade.models` does not list,
          making the set on disk exactly the declared one.

          Off by default: models are large and slow to re-fetch, and anything
          pulled by hand for an experiment would disappear on the next
          activation. Requires a non-empty `lemonade.models`.
        '';
      };
    };

    ds4 = {
      enable = mkEnableOption "the ds4-server DeepSeek V4 inference server as a systemd unit";

      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether `ds4-server` starts at boot.

          Set false on a host where ds4 serves a model too large to keep
          resident all the time — the unit stays built and startable with
          `systemctl start ds4-server`, but the machine comes up without 80+
          GiB of weights loaded. See `exclusiveInference`.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.ds4;
        defaultText = lib.literalExpression "pkgs.ds4";
        description = ''
          ds4 package providing `ds4-server`. Override to retarget the ROCm
          backend, e.g. `pkgs.ds4.override { gpuTarget = "gfx1103"; }`.
        '';
      };

      model = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/var/lib/ds4/DeepSeek-V4-Flash.gguf";
        description = ''
          Path to the DeepSeek V4 GGUF served by ds4-server. A runtime path,
          deliberately a string so it is not copied into the Nix store.
          Required when `ds4.enable` is set.
        '';
      };

      ctx = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Allocated context tokens (`--ctx`). null leaves the ds4-server default.";
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Bind address for ds4-server (`--host`).";
      };

      port = mkOption {
        type = types.port;
        default = 8000;
        description = "Bind port for ds4-server (`--port`).";
      };

      user = mkOption {
        type = types.str;
        description = ''
          User account to run ds4-server as. Needs no group setup: the unit
          grants `render` and `video` itself via `SupplementaryGroups`, unlike
          lemond, whose `user` must be in them already.
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["--ssd-streaming" "--kv-disk-dir" "/var/lib/ds4/server-kv"];
        description = ''
          Extra arguments appended to the ds4-server command line — e.g.
          `--ssd-streaming` with its `--kv-disk-*` flags, or `--threads`. The
          unit provides a writable `/var/lib/ds4` via StateDirectory.
        '';
      };
    };

    gpuMemory = {
      ttmSizeGiB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          GTT pool ceiling in GiB, emitted as the `ttm` `pages_limit` modprobe
          option (page count is computed for you: GiB * 262144).

          null (default) leaves the kernel default untouched. No-op on Strix
          Point / 64 GB — the default (~27 GB addressable) already covers
          17-22 GB models. This is the lever a Strix Halo / 128 GB host needs
          to expose its large unified pool. See the README "GPU memory
          headroom" section for recommended Halo values.
        '';
      };

      pagePoolSizeGiB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = ''
          Pre-cached GTT pool size in GiB, emitted as the `ttm` `page_pool_size`
          modprobe option (pages kept warm rather than freed back). Requires
          ttmSizeGiB and must be <= it. null (default) leaves the kernel
          default untouched.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.enableNPU || versionAtLeast config.boot.kernelPackages.kernel.version "6.14";
        message = "AMD NPU (amdxdna) requires kernel >= 6.14.";
      }
      {
        assertion = !cfg.enableFastFlowLM || cfg.enableNPU;
        message = "hardware.amd-npu.enableFastFlowLM requires enableNPU = true (FastFlowLM runs on the NPU).";
      }
      {
        assertion = !cfg.enableVllm || (cfg.enableROCm && cfg.enableLemonade);
        message = "hardware.amd-npu.enableVllm requires enableROCm and enableLemonade = true (vLLM runs on the ROCm GPU under lemonade).";
      }
      {
        assertion = cfg.gpuMemory.pagePoolSizeGiB == null || cfg.gpuMemory.ttmSizeGiB != null;
        message = "hardware.amd-npu.gpuMemory.pagePoolSizeGiB requires ttmSizeGiB to be set.";
      }
      {
        assertion = !cfg.ds4.enable || cfg.ds4.model != null;
        message = "hardware.amd-npu.ds4.enable requires hardware.amd-npu.ds4.model (path to a DeepSeek V4 GGUF).";
      }
      {
        assertion = cfg.lemonade.models == [] || cfg.enableLemonade;
        message = "hardware.amd-npu.lemonade.models requires enableLemonade = true (models are pulled through a running lemond).";
      }
      {
        assertion = !cfg.lemonade.pruneUnlistedModels || cfg.lemonade.models != [];
        message = "hardware.amd-npu.lemonade.pruneUnlistedModels requires a non-empty lemonade.models; against an empty list it would delete every downloaded model.";
      }
      {
        assertion =
          cfg.gpuMemory.pagePoolSizeGiB
          == null
          || cfg.gpuMemory.ttmSizeGiB == null
          || cfg.gpuMemory.pagePoolSizeGiB <= cfg.gpuMemory.ttmSizeGiB;
        message = "hardware.amd-npu.gpuMemory.pagePoolSizeGiB must be <= ttmSizeGiB.";
      }
    ];

    warnings =
      optional
      (cfg.enableLemonade && cfg.lemonade.allowedOrigins == [] && !builtins.elem cfg.lemonade.host ["localhost" "127.0.0.1" "::1"])
      "hardware.amd-npu.lemonade.host is non-loopback but lemonade.allowedOrigins is empty; browsers on other machines will get a 403 'Origin not allowed' error. Set lemonade.allowedOrigins to the origins that should reach it."
      # Checks gpuTarget as well as vllmGpuTarget: the CWSR bug crashes every
      # ROCm backend, so a llamacpp-only gfx1151 host must warn too.
      # A warning rather than an assertion — the fix can be backported to an
      # older kernel, which a version check cannot detect.
      ++ optional
      (cfg.enableLemonade
        && cfg.enableROCm
        && (cfg.gpuTarget == "gfx1151" || cfg.vllmGpuTarget == "gfx1151")
        && !versionAtLeast config.boot.kernelPackages.kernel.version "6.18.4")
      "A gfx1151 target is selected (hardware.amd-npu.gpuTarget / vllmGpuTarget), which needs Linux kernel >= 6.18.4 (or the CWSR fix backported) or ROCm can miscalculate VGPR counts and crash llamacpp:rocm, sd-cpp:rocm, and vllm:rocm. Kernel ${config.boot.kernelPackages.kernel.version} is below that; if it carries a backported fix, verify on the host with: grep -E \"cwsr_size|ctl_stack_size\" /sys/class/kfd/kfd/topology/nodes/*/properties";

    # Kernel configuration (NPU-only)
    boot.kernelModules = optionals cfg.enableNPU ["amdxdna"];

    # GTT pool sizing (opt-in). Raises what's *addressable*, not consumed — no
    # power cost. Needed on Strix Halo / 128 GB for large models; no-op on
    # Strix Point / 64 GB. modprobe.d form matches the Strix Halo wiki verbatim.
    boot.extraModprobeConfig = mkIf (cfg.gpuMemory.ttmSizeGiB != null) ''
      options ttm pages_limit=${toString (gttPages cfg.gpuMemory.ttmSizeGiB)}${ttmPagePoolClause}
    '';

    # Udev rules for NPU device access
    services.udev.extraRules = optionalString cfg.enableNPU ''
      # AMD NPU (amdxdna) — accel subsystem
      SUBSYSTEM=="accel", DRIVERS=="amdxdna", GROUP="video", MODE="0660"
      # AMD NPU — misc device fallback
      KERNEL=="accel*", SUBSYSTEM=="misc", ATTRS{driver}=="amdxdna", GROUP="video", MODE="0660"
    '';

    # PAM limits — unlimited memlock for NPU buffer allocation (video/render groups)
    security.pam.loginLimits = optionals cfg.enableNPU [
      {
        domain = "@video";
        type = "-";
        item = "memlock";
        value = "unlimited";
      }
      {
        domain = "@render";
        type = "-";
        item = "memlock";
        value = "unlimited";
      }
    ];

    # Environment variables for XRT plugin discovery
    environment.sessionVariables =
      optionalAttrs cfg.enableNPU {
        XILINX_XRT = "${xrt-combined}";
        XRT_PATH = "${xrt-combined}";
      }
      // optionalAttrs cfg.enableFastFlowLM {
        # nix manages the version; FLM's auto-update probe on every run/serve
        # is noise on a read-only nix-store binary. New in FLM 0.9.41.
        FLM_DISABLE_UPDATE_CHECK = "1";
      }
      // optionalAttrs cfg.enableLemonade {
        # v10.7.0 reads backend bin paths + tuning only from config.json; point
        # the lemonade CLI / desktop app at our generated seed via the
        # LEMONADE_DEFAULTS_PATH patch in pkgs/lemonade.
        LEMONADE_DEFAULTS_PATH = lemonadeDefaultsFile;
      }
      // optionalAttrs (cfg.enableLemonade && cfg.enableROCm) {
        # Keeps the ROCm llamacpp backend offered: read directly by
        # is_ggml_hip_plugin_available()'s env probe (upstreamed in #2044).
        LEMONADE_GGML_HIP_PATH = "${pkgs.llama-cpp-rocm}/lib/libggml-hip.so";
      };

    # Stable indirection symlinks lemonade's config.json bin paths point at.
    environment.etc = lemonadeBackendEtc;

    # System packages.
    #
    # The llama-cpp / whisper-cpp / stable-diffusion-cpp engines are deliberately
    # NOT installed here. Each ships its ggml backend .so files in $out/bin, and
    # putting those on the system PATH makes glib's GIO module loader dlopen them
    # as plugins and spam "Failed to load module" on every glib app. Nothing needs
    # them on PATH: lemond reads its backends from the /etc/lemonade/backends/*
    # symlinks below, and other consumers reference them by store path directly.
    environment.systemPackages =
      [
        pkgs.pciutils
        pkgs.lshw
      ]
      ++ optional cfg.enableNPU xrt-combined
      ++ optional cfg.enableFastFlowLM pkgs.fastflowlm
      ++ optional cfg.enableLemonade lemonadePackage
      ++ optional cfg.enableROCm pkgs.rocmPackages.clr;

    # koko (kokoro TTS) is a runtime-downloaded prebuilt ELF that asks for
    # /lib64/ld-linux-x86-64.so.2; nix-ld swaps the stub for a real loader, and
    # its default libraries already cover koko's needs (openssl, gcc-libs).
    # mkDefault so hosts managing nix-ld themselves can still opt out.
    programs.nix-ld.enable = mkIf cfg.enableLemonade (mkDefault true);

    # The openmoss TTS backends need more than that base set. Both moss-tts-server
    # builds exit 127 without these, and lemond reports "openmoss-server failed to
    # start or become ready". Seen by running the binaries directly: the vulkan
    # build stops at libvulkan.so.1, rocm-stable at libomp.so and then
    # libhipblas.so.3. ldd is not a usable check here -- it does not go through
    # nix-ld, so it prints "not found" for libraries that do resolve at runtime.
    #
    # libraries is a listOf, so definitions from every module concatenate: this
    # adds to the nixpkgs base set rather than replacing it.
    programs.nix-ld.libraries = mkIf cfg.enableLemonade (
      [pkgs.vulkan-loader]
      ++ optionals cfg.enableROCm (with pkgs.rocmPackages; [llvm.openmp clr rocblas hipblas])
    );

    # Lemonade systemd service
    systemd.services.lemond = mkIf cfg.enableLemonade {
      description = "Lemonade AI Server";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = optional cfg.lemonade.autoStart "multi-user.target";
      path = pathList ++ ["/run/current-system/sw"];
      environment =
        {
          # Backend bin paths plus global_timeout (0 disables lemond's 300s
          # upstream timeout — see lemonade-sdk/lemonade#1364) and the
          # flash-attn arg now live in the generated defaults.json; v10.7.0
          # dropped their env hooks. See the LEMONADE_DEFAULTS_PATH patch in
          # pkgs/lemonade.
          LEMONADE_DEFAULTS_PATH = lemonadeDefaultsFile;
        }
        // optionalAttrs cfg.enableNPU {
          XILINX_XRT = "${xrt-combined}";
          XRT_PATH = "${xrt-combined}";
        }
        // optionalAttrs (ldLibraryPath != "") {
          LD_LIBRARY_PATH = ldLibraryPath;
        }
        // optionalAttrs cfg.enableROCm {
          LEMONADE_GGML_HIP_PATH = "${pkgs.llama-cpp-rocm}/lib/libggml-hip.so";
        }
        // optionalAttrs cfg.enableFastFlowLM {
          # Suppress FLM's auto-update probe in the lemond-spawned subprocess.
          # New in FLM 0.9.41.
          FLM_DISABLE_UPDATE_CHECK = "1";
        }
        // optionalAttrs config.programs.nix-ld.enable {
          # nix-ld exports these only as session vars; the unit doesn't inherit
          # them, so koko's loader can't find them without re-exporting here.
          NIX_LD = config.environment.sessionVariables.NIX_LD;
          NIX_LD_LIBRARY_PATH = config.environment.sessionVariables.NIX_LD_LIBRARY_PATH;
        }
        // optionalAttrs (cfg.lemonade.cacheDir != null) {
          HF_HOME = "${cfg.lemonade.cacheDir}/hf";
          LEMONADE_CACHE_DIR = "${cfg.lemonade.cacheDir}/lemonade";
        }
        // optionalAttrs (cfg.lemonade.allowedOrigins != []) {
          # env-only in lemonade >=11.5.0 — no config.json key to route this
          # through lemonade.settings.
          LEMONADE_ALLOWED_ORIGINS = concatStringsSep "," cfg.lemonade.allowedOrigins;
        };
      serviceConfig = {
        Type = "simple";
        User = cfg.lemonade.user;
        ExecStartPre = "${lemonadeReconcile}/bin/lemond-reconcile-config";
        ExecStart = "${lemonadePackage}/bin/lemond --port ${toString cfg.lemonade.port} --host ${cfg.lemonade.host}";
        Restart = "on-failure";
        RestartSec = "5s";
        KillSignal = "SIGINT";
        LimitMEMLOCK = "infinity";
        # WhisperServer resolves its writable runtime dir from RUNTIME_DIRECTORY.
        RuntimeDirectory = "lemond";
      };
    };

    # systemd calls a Type=simple unit started as soon as it forks, so
    # `nixos-rebuild switch` returns instead of waiting out multi-GiB pulls.
    # A oneshot would make activation block on them.
    systemd.services.lemond-models = mkIf (cfg.enableLemonade && cfg.lemonade.models != []) {
      description = "Reconcile downloaded lemonade models";
      after = ["lemond.service"];
      requires = ["lemond.service"];
      # Requires= would otherwise pull lemond back up at boot behind autoStart.
      wantedBy = optional cfg.lemonade.autoStart "multi-user.target";
      serviceConfig = {
        Type = "simple";
        User = cfg.lemonade.user;
        ExecStart = "${lemonadeModelSync}/bin/lemond-sync-models";
        Restart = "no";
      };
    };

    # ds4-server: OpenAI-compatible DeepSeek V4 server. The package is
    # self-contained (rpath covers the ROCm libs), so it needs no LD_LIBRARY_PATH
    # like lemond — only GPU device access (render/video) and a writable state
    # dir for the optional SSD-streaming KV cache.
    systemd.services.ds4-server = mkIf cfg.ds4.enable {
      description = "ds4 DeepSeek V4 inference server";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = optional cfg.ds4.autoStart "multi-user.target";
      # Declared on one side only: systemd derives the inverse, so starting
      # either unit stops the other.
      conflicts = optional (cfg.exclusiveInference && cfg.enableLemonade) "lemond.service";
      # Nothing provisions ds4.model - lemonade.models has its reconcile units,
      # this has no equivalent - so an absent GGUF is the expected first-boot
      # state on a new host. Without this the unit retries forever: RestartSec=5s
      # against systemd's default 5-starts-per-10s limiter never trips it, so it
      # spins silently rather than failing. The condition makes systemd skip it
      # and say why.
      unitConfig.ConditionPathExists = cfg.ds4.model;
      serviceConfig = {
        Type = "simple";
        User = cfg.ds4.user;
        SupplementaryGroups = ["video" "render"];
        ExecStart = concatStringsSep " " (
          [
            "${cfg.ds4.package}/bin/ds4-server"
            "--model ${cfg.ds4.model}"
            "--host ${cfg.ds4.host}"
            "--port ${toString cfg.ds4.port}"
          ]
          ++ optional (cfg.ds4.ctx != null) "--ctx ${toString cfg.ds4.ctx}"
          ++ cfg.ds4.extraArgs
        );
        Restart = "on-failure";
        RestartSec = "5s";
        KillSignal = "SIGINT";
        LimitMEMLOCK = "infinity";
        StateDirectory = "ds4";
      };
    };
  };
}
