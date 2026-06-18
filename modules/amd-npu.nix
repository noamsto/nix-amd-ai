{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf mkDefault types optionalString optional optionals optionalAttrs makeBinPath versionAtLeast concatStringsSep;
  cfg = config.hardware.amd-npu;

  # The Tauri desktop app is the only part of lemonade that pulls a Rust/npm
  # build (and a crates.io cargo-vendor fetch). Headless/server hosts can drop
  # it via withDesktopApp = false so `enableLemonade` doesn't drag in that
  # build path. See noamsto/nix-amd-ai#28.
  lemonadePackage = pkgs.lemonade.override {withDesktopApp = cfg.lemonade.desktopApp.enable;};

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
    // optionalAttrs (cfg.enableLemonade && cfg.enableVulkan) {
      "lemonade/backends/llamacpp-vulkan".source = "${pkgs.llama-cpp-vulkan}/bin/llama-server";
      "lemonade/backends/whispercpp-vulkan".source = "${pkgs.whisper-cpp-vulkan}/bin/whisper-server";
    };

  # defaults.json seed that lemonade's get_defaults() merges over its packaged
  # defaults (via the LEMONADE_DEFAULTS_PATH patch in pkgs/lemonade). Carries
  # the backend bin paths plus global_timeout / flash-attn, all of which lost
  # their env hook when v10.7.0 removed migrate_from_env.
  lemonadeDefaults =
    {
      global_timeout = 0;
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
    // optionalAttrs cfg.enableImageGen {
      sdcpp =
        {cpu_bin = lemonadeBackendBin "sdcpp-cpu";}
        // optionalAttrs cfg.enableROCm {rocm_bin = lemonadeBackendBin "sdcpp-rocm";};
    };
  lemonadeDefaultsFile = (pkgs.formats.json {}).generate "lemonade-defaults.json" lemonadeDefaults;
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
        Whether to wire stable-diffusion.cpp recipes (sd-cpp:cpu and, when
        enableROCm is true, sd-cpp:rocm) into lemonade. Disable to drop
        ~150 MB CPU-only / ~1.5 GB with ROCm from the closure if you only
        use lemonade for LLM inference.
      '';
    };

    lemonade = {
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
        assertion = cfg.gpuMemory.pagePoolSizeGiB == null || cfg.gpuMemory.ttmSizeGiB != null;
        message = "hardware.amd-npu.gpuMemory.pagePoolSizeGiB requires ttmSizeGiB to be set.";
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

    # Kernel configuration (NPU-only)
    boot.kernelParams = optionals cfg.enableNPU ["iommu.passthrough=0"];
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

    # Lemonade systemd service
    systemd.services.lemond = mkIf cfg.enableLemonade {
      description = "Lemonade AI Server";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
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
        };
      serviceConfig = {
        Type = "simple";
        User = cfg.lemonade.user;
        ExecStart = "${lemonadePackage}/bin/lemond --port ${toString cfg.lemonade.port} --host ${cfg.lemonade.host}";
        Restart = "on-failure";
        RestartSec = "5s";
        KillSignal = "SIGINT";
        LimitMEMLOCK = "infinity";
        # WhisperServer resolves its writable runtime dir from RUNTIME_DIRECTORY.
        RuntimeDirectory = "lemond";
      };
    };
  };
}
