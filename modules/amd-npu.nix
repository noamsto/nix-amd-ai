{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf types optionalString optional optionals optionalAttrs makeBinPath versionAtLeast;
  cfg = config.hardware.amd-npu;

  xrtPrefix = "${pkgs.xrt}/opt/xilinx/xrt";

  xrt-combined = pkgs.runCommand "xrt-combined" {} ''
    mkdir -p $out
    cp -rs ${xrtPrefix}/* $out/
    chmod -R u+w $out/lib
    ln -sf ${pkgs.xrt-plugin-amdxdna}/opt/xilinx/xrt/lib/libxrt_driver_xdna* $out/lib/
  '';

  optionalROCmLibs =
    optionalString cfg.enableROCm
    ":${pkgs.rocmPackages.clr}/lib";

  pathList =
    [xrt-combined]
    ++ optional cfg.enableFastFlowLM pkgs.fastflowlm;
in {
  options.hardware.amd-npu = {
    enable = mkEnableOption "AMD NPU (AI Engine) support";

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
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = versionAtLeast config.boot.kernelPackages.kernel.version "6.14";
        message = "AMD NPU (amdxdna) requires kernel >= 6.14.";
      }
    ];

    # Kernel configuration
    boot.kernelParams = ["iommu.passthrough=0"];
    boot.kernelModules = ["amdxdna"];

    # Udev rules for NPU device access
    services.udev.extraRules = ''
      # AMD NPU (amdxdna) — accel subsystem
      SUBSYSTEM=="accel", DRIVERS=="amdxdna", GROUP="video", MODE="0660"
      # AMD NPU — misc device fallback
      KERNEL=="accel*", SUBSYSTEM=="misc", ATTRS{driver}=="amdxdna", GROUP="video", MODE="0660"
    '';

    # PAM limits — unlimited memlock for video and render groups
    security.pam.loginLimits = [
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
      {
        XILINX_XRT = "${xrt-combined}";
        XRT_PATH = "${xrt-combined}";
      }
      // optionalAttrs cfg.enableLemonade {
        # CPU recipes work on every host, no GPU enable flag needed.
        LEMONADE_LLAMACPP_CPU_BIN = "${pkgs.llama-cpp}/bin/llama-server";
        LEMONADE_WHISPERCPP_CPU_BIN = "${pkgs.whisper-cpp}/bin/whisper-server";
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
        xrt-combined
        pkgs.pciutils
        pkgs.lshw
      ]
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
      serviceConfig = {
        Type = "simple";
        User = cfg.lemonade.user;
        ExecStart = "${pkgs.lemonade}/bin/lemond --port ${toString cfg.lemonade.port} --host ${cfg.lemonade.host}";
        Restart = "on-failure";
        RestartSec = "5s";
        KillSignal = "SIGINT";
        LimitMEMLOCK = "infinity";
        Environment =
          [
            "XILINX_XRT=${xrt-combined}"
            "XRT_PATH=${xrt-combined}"
            "LD_LIBRARY_PATH=${xrt-combined}/lib${optionalROCmLibs}"
            "PATH=${makeBinPath pathList}:/run/current-system/sw/bin"
            # Disable lemond's 300s upstream timeout so long prompt-processing
            # phases (common with large agent system prompts on iGPU) don't
            # abort before the first token. See lemonade-sdk/lemonade#1364.
            "LEMONADE_GLOBAL_TIMEOUT=0"
            "LEMONADE_LLAMACPP_CPU_BIN=${pkgs.llama-cpp}/bin/llama-server"
            "LEMONADE_WHISPERCPP_CPU_BIN=${pkgs.whisper-cpp}/bin/whisper-server"
          ]
          ++ optional cfg.enableImageGen "LEMONADE_SDCPP_CPU_BIN=${pkgs.stable-diffusion-cpp}/bin/sd-server"
          ++ optionals cfg.enableROCm [
            "LEMONADE_LLAMACPP_ROCM_BIN=${pkgs.llama-cpp-rocm}/bin/llama-server"
            "LEMONADE_GGML_HIP_PATH=${pkgs.llama-cpp-rocm}/lib/libggml-hip.so"
          ]
          ++ optional (cfg.enableROCm && cfg.enableImageGen) "LEMONADE_SDCPP_ROCM_BIN=${pkgs.stable-diffusion-cpp-rocm}/bin/sd-server"
          ++ optionals cfg.enableVulkan [
            "LEMONADE_LLAMACPP_VULKAN_BIN=${pkgs.llama-cpp-vulkan}/bin/llama-server"
            "LEMONADE_WHISPERCPP_VULKAN_BIN=${pkgs.whisper-cpp-vulkan}/bin/whisper-server"
          ];
      };
    };
  };
}
