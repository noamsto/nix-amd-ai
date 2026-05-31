{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf types optionalString optional optionals optionalAttrs makeBinPath versionAtLeast concatStringsSep;
  cfg = config.hardware.amd-npu;

  # 4096-byte pages: pages = GiB * 1024^3 / 4096 = GiB * 262144.
  gttPages = gib: gib * 262144;

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
      description = "Whether to enable the Lemonade AI server.";
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
          cfg.gpuMemory.pagePoolSizeGiB == null
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
      options ttm pages_limit=${toString (gttPages cfg.gpuMemory.ttmSizeGiB)}${optionalString (cfg.gpuMemory.pagePoolSizeGiB != null) " page_pool_size=${toString (gttPages cfg.gpuMemory.pagePoolSizeGiB)}"}
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
        # CPU recipes work on every host, no GPU enable flag needed.
        LEMONADE_LLAMACPP_CPU_BIN = "${pkgs.llama-cpp}/bin/llama-server";
        LEMONADE_WHISPERCPP_CPU_BIN = "${pkgs.whisper-cpp}/bin/whisper-server";
        # Force-set FA because upstream lemonade defaults to no flag at all.
        LEMONADE_LLAMACPP_ARGS = "--flash-attn ${cfg.lemonade.flashAttn}";
      }
      // optionalAttrs (cfg.enableLemonade && cfg.enableImageGen) {
        LEMONADE_SDCPP_CPU_BIN = "${pkgs.stable-diffusion-cpp}/bin/sd-server";
      }
      // optionalAttrs cfg.enableROCm {
        LEMONADE_LLAMACPP_ROCM_BIN = "${pkgs.llama-cpp-rocm}/bin/llama-server";
        # Activates the "system" llamacpp recipe via our nix-amd-ai
        # is_ggml_hip_plugin_available() patch in pkgs/lemonade.
        LEMONADE_GGML_HIP_PATH = "${pkgs.llama-cpp-rocm}/lib/libggml-hip.so";
      }
      // optionalAttrs (cfg.enableROCm && cfg.enableImageGen) {
        LEMONADE_SDCPP_ROCM_BIN = "${pkgs.stable-diffusion-cpp-rocm}/bin/sd-server";
      }
      // optionalAttrs cfg.enableVulkan {
        LEMONADE_LLAMACPP_VULKAN_BIN = "${pkgs.llama-cpp-vulkan}/bin/llama-server";
        # whispercpp.vulkan_bin works thanks to our config_file.cpp env-mapping
        # patch in pkgs/lemonade — upstream v10.3.0 doesn't ship the mapping.
        LEMONADE_WHISPERCPP_VULKAN_BIN = "${pkgs.whisper-cpp-vulkan}/bin/whisper-server";
      };

    # System packages.
    #
    # The GPU-enabled llama-cpp / whisper-cpp variants are listed BEFORE the
    # CPU variants so that `llama-server` / `whisper-server` resolved through
    # PATH (e.g. by the lemonade "system" recipe, which has no env-var hook
    # and just does a PATH lookup) point at the GPU build. nixpkgs buildEnv
    # merges packages in declaration order, and the first package providing a
    # given relative path wins; declaring CPU first would shadow the GPU
    # binaries.
    environment.systemPackages =
      [
        pkgs.pciutils
        pkgs.lshw
      ]
      ++ optional cfg.enableNPU xrt-combined
      ++ optional cfg.enableFastFlowLM pkgs.fastflowlm
      ++ optional cfg.enableLemonade pkgs.lemonade
      ++ optional cfg.enableROCm pkgs.rocmPackages.clr
      ++ optional cfg.enableROCm pkgs.llama-cpp-rocm
      ++ optional (cfg.enableROCm && cfg.enableImageGen) pkgs.stable-diffusion-cpp-rocm
      ++ optionals cfg.enableVulkan [
        pkgs.llama-cpp-vulkan
        pkgs.whisper-cpp-vulkan
      ]
      ++ optionals cfg.enableLemonade [
        pkgs.llama-cpp
        pkgs.whisper-cpp
      ]
      ++ optional (cfg.enableLemonade && cfg.enableImageGen) pkgs.stable-diffusion-cpp;

    # Lemonade systemd service
    systemd.services.lemond = mkIf cfg.enableLemonade {
      description = "Lemonade AI Server";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      path = pathList ++ ["/run/current-system/sw"];
      environment =
        {
          # Disable lemond's 300s upstream timeout so long prompt-processing
          # phases (common with large agent system prompts on iGPU) don't
          # abort before the first token. See lemonade-sdk/lemonade#1364.
          LEMONADE_GLOBAL_TIMEOUT = "0";
          LEMONADE_LLAMACPP_CPU_BIN = "${pkgs.llama-cpp}/bin/llama-server";
          LEMONADE_WHISPERCPP_CPU_BIN = "${pkgs.whisper-cpp}/bin/whisper-server";
          LEMONADE_LLAMACPP_ARGS = "--flash-attn ${cfg.lemonade.flashAttn}";
        }
        // optionalAttrs cfg.enableNPU {
          XILINX_XRT = "${xrt-combined}";
          XRT_PATH = "${xrt-combined}";
        }
        // optionalAttrs (ldLibraryPath != "") {
          LD_LIBRARY_PATH = ldLibraryPath;
        }
        // optionalAttrs cfg.enableImageGen {
          LEMONADE_SDCPP_CPU_BIN = "${pkgs.stable-diffusion-cpp}/bin/sd-server";
        }
        // optionalAttrs cfg.enableROCm {
          LEMONADE_LLAMACPP_ROCM_BIN = "${pkgs.llama-cpp-rocm}/bin/llama-server";
          LEMONADE_GGML_HIP_PATH = "${pkgs.llama-cpp-rocm}/lib/libggml-hip.so";
        }
        // optionalAttrs (cfg.enableROCm && cfg.enableImageGen) {
          LEMONADE_SDCPP_ROCM_BIN = "${pkgs.stable-diffusion-cpp-rocm}/bin/sd-server";
        }
        // optionalAttrs cfg.enableVulkan {
          LEMONADE_LLAMACPP_VULKAN_BIN = "${pkgs.llama-cpp-vulkan}/bin/llama-server";
          LEMONADE_WHISPERCPP_VULKAN_BIN = "${pkgs.whisper-cpp-vulkan}/bin/whisper-server";
        }
        // optionalAttrs cfg.enableFastFlowLM {
          # Suppress FLM's auto-update probe in the lemond-spawned subprocess.
          # New in FLM 0.9.41.
          FLM_DISABLE_UPDATE_CHECK = "1";
        };
      serviceConfig = {
        Type = "simple";
        User = cfg.lemonade.user;
        ExecStart = "${pkgs.lemonade}/bin/lemond --port ${toString cfg.lemonade.port} --host ${cfg.lemonade.host}";
        Restart = "on-failure";
        RestartSec = "5s";
        KillSignal = "SIGINT";
        LimitMEMLOCK = "infinity";
      };
    };
  };
}
