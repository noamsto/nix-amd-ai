{
  description = "AMD AI inference stack for NixOS (XRT, xrt-plugin-amdxdna, FastFlowLM, Lemonade)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];

      flake = {
        overlays.default = final: prev: let
          xrt = final.callPackage ./pkgs/xrt {};
          fastflowlm = final.callPackage ./pkgs/fastflowlm {inherit xrt;};
          # Reach into nix-amd-ai's own nixpkgs input for packages whose
          # version / build config needs to be stable regardless of the
          # consumer's channel:
          #   - libwebsockets: lemonade needs .so.20 (>= 4.4); nixos-25.11
          #     still ships 4.3.5 (.so.19).
          #   - llama-cpp-{rocm,vulkan}: older nixpkgs channels build without
          #     gfx1150 in AMDGPU_TARGETS and predate recent Vulkan perf work.
          # `prev` / `final` are the consumer's pkgs, so we import our input
          # explicitly.
          pinned = import inputs.nixpkgs {inherit (final.stdenv.hostPlatform) system;};
          llama-cpp-vulkan = pinned.llama-cpp.override {vulkanSupport = true;};
        in {
          inherit xrt fastflowlm llama-cpp-vulkan;
          inherit (pinned) llama-cpp-rocm libwebsockets;
          xrt-plugin-amdxdna = final.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = final.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan;
            inherit (pinned) libwebsockets llama-cpp-rocm;
          };
        };

        nixosModules.default = {
          imports = [./modules/amd-npu.nix];
          nixpkgs.overlays = [inputs.self.overlays.default];
        };
      };

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        xrt = pkgs.callPackage ./pkgs/xrt {};
        fastflowlm = pkgs.callPackage ./pkgs/fastflowlm {inherit xrt;};
        llama-cpp-vulkan = pkgs.llama-cpp.override {vulkanSupport = true;};
      in {
        packages = {
          inherit xrt fastflowlm llama-cpp-vulkan;
          inherit (pkgs) llama-cpp-rocm;
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pkgs.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan;
            llama-cpp-rocm = pkgs.llama-cpp-rocm;
          };
          benchmark = pkgs.callPackage ./pkgs/benchmark {};
        };

        checks = {
          module-eval-rocm-false = (inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              inputs.self.nixosModules.default
              {
                boot.loader.grub.enable = false;
                fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
                hardware.amd-npu = {
                  enable = true;
                  enableFastFlowLM = true;
                  enableLemonade = true;
                  enableROCm = false;
                  lemonade.user = "testuser";
                };
                users.users.testuser = {
                  isNormalUser = true;
                  extraGroups = ["video" "render"];
                };
              }
            ];
          }).config.system.build.etc;

          module-eval-rocm-true = (inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              inputs.self.nixosModules.default
              {
                boot.loader.grub.enable = false;
                fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
                hardware.amd-npu = {
                  enable = true;
                  enableFastFlowLM = true;
                  enableLemonade = true;
                  enableROCm = true;
                  lemonade.user = "testuser";
                };
                users.users.testuser = {
                  isNormalUser = true;
                  extraGroups = ["video" "render"];
                };
              }
            ];
          }).config.system.build.etc;

          module-eval-vulkan-true = (inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              inputs.self.nixosModules.default
              {
                boot.loader.grub.enable = false;
                fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
                hardware.amd-npu = {
                  enable = true;
                  enableFastFlowLM = true;
                  enableLemonade = true;
                  enableROCm = false;
                  enableVulkan = true;
                  lemonade.user = "noams";
                };
                users.users.noams = {
                  isNormalUser = true;
                  extraGroups = ["video" "render"];
                };
              }
            ];
          }).config.system.build.etc;
        };

        apps.benchmark = {
          type = "app";
          program = "${pkgs.callPackage ./pkgs/benchmark {}}/bin/benchmark";
          meta = {description = "Benchmark lemonade backends (ROCm, Vulkan, FLM)";};
        };
      };
    };
}
