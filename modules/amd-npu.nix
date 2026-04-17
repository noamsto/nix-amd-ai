{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf types optionalString optional optionalAttrs makeBinPath versionAtLeast;
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

    rocmGfxOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "HSA_OVERRIDE_GFX_VERSION value (e.g. \"11.0.2\" for Strix Point gfx1150 → gfx1102 fallback).";
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
    environment.sessionVariables = {
      XILINX_XRT = "${xrt-combined}";
      XRT_PATH = "${xrt-combined}";
    } // optionalAttrs cfg.enableROCm {
      LEMONADE_LLAMACPP_ROCM_BIN = "${pkgs.llama-cpp-rocm}/bin/llama-server";
    } // optionalAttrs cfg.enableVulkan {
      LEMONADE_LLAMACPP_VULKAN_BIN = "${pkgs.llama-cpp-vulkan}/bin/llama-server";
    } // optionalAttrs (cfg.enableROCm && cfg.rocmGfxOverride != null) {
      HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfxOverride;
    };

    # System packages
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
      ++ optional cfg.enableVulkan pkgs.llama-cpp-vulkan;

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
        Environment = [
          "XILINX_XRT=${xrt-combined}"
          "XRT_PATH=${xrt-combined}"
          "LD_LIBRARY_PATH=${xrt-combined}/lib${optionalROCmLibs}"
          "PATH=${makeBinPath pathList}:/run/current-system/sw/bin"
        ]
        ++ optional cfg.enableROCm "LEMONADE_LLAMACPP_ROCM_BIN=${pkgs.llama-cpp-rocm}/bin/llama-server"
        ++ optional cfg.enableVulkan "LEMONADE_LLAMACPP_VULKAN_BIN=${pkgs.llama-cpp-vulkan}/bin/llama-server"
        ++ optional (cfg.enableROCm && cfg.rocmGfxOverride != null) "HSA_OVERRIDE_GFX_VERSION=${cfg.rocmGfxOverride}";
      };
    };
  };
}
