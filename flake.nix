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
        in {
          inherit xrt fastflowlm;
          xrt-plugin-amdxdna = final.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = final.callPackage ./pkgs/lemonade {inherit fastflowlm;};
          llama-cpp-rocm = prev.llama-cpp-rocm;
          llama-cpp-vulkan = prev.llama-cpp.override {vulkanSupport = true;};
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
      in {
        packages = {
          inherit xrt fastflowlm;
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pkgs.callPackage ./pkgs/lemonade {inherit fastflowlm;};
          llama-cpp-rocm = pkgs.llama-cpp-rocm;
          llama-cpp-vulkan = pkgs.llama-cpp.override {vulkanSupport = true;};
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
