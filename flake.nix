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
          #   - libwebsockets: lemonade >= 10.3 links libwebsockets.so.21,
          #     which requires upstream 4.5.x; nixpkgs unstable still ships
          #     4.4.1 (.so.20), so we overlay a 4.5.8 build.
          #   - llama-cpp-{rocm,vulkan}: older nixpkgs channels build without
          #     gfx1150 in AMDGPU_TARGETS and predate recent Vulkan perf work.
          # `prev` / `final` are the consumer's pkgs, so we import our input
          # explicitly.
          pinned = import inputs.nixpkgs {inherit (final.stdenv.hostPlatform) system;};
          libwebsockets-4_5 = pinned.libwebsockets.overrideAttrs (old: {
            version = "4.5.8";
            src = pinned.fetchurl {
              url = "https://github.com/warmcat/libwebsockets/archive/v4.5.8.tar.gz";
              hash = "sha256-tq3mWPSvOoI9DcgGrl7wYj8PT14q64laD3fEeDhAww4=";
            };
            # nixpkgs carries CVE-2025-11677/11678 patches against 4.4.x; both
            # fixes are upstream in 4.5.x, so reverse-applying them fails.
            patches = [];
            # 4.5.x's CMakeLists writes libwebsockets.pc with
            #   libdir=${exec_prefix}/${LWS_INSTALL_LIB_DIR}
            # and defaults LWS_INSTALL_LIB_DIR to ${CMAKE_INSTALL_LIBDIR}, which
            # Nix's setup hook sets to an absolute path. The generated .pc then
            # contains `libdir=${exec_prefix}//nix/store/.../lib`, tripping
            # nixpkgs's broken-pc-paths check. Forcing LWS_INSTALL_LIB_DIR=lib
            # via CMake breaks evlib_uv's install path; instead, fix the .pc
            # file in-place after install.
            postInstall = (old.postInstall or "") + ''
              for pc in "$out"/lib/pkgconfig/*.pc "$dev"/lib/pkgconfig/*.pc; do
                [ -f "$pc" ] || continue
                substituteInPlace "$pc" \
                  --replace-quiet 'libdir=''${exec_prefix}/'"$out"'/lib' 'libdir='"$out"'/lib'
              done
            '';
          });
        in {
          inherit xrt fastflowlm;
          xrt-plugin-amdxdna = final.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = final.callPackage ./pkgs/lemonade {
            inherit fastflowlm;
            libwebsockets = libwebsockets-4_5;
          };
          inherit (pinned) llama-cpp-rocm;
          llama-cpp-vulkan = pinned.llama-cpp.override {vulkanSupport = true;};
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
        # See overlay: lemonade >= 10.3 needs libwebsockets.so.21 (4.5.x).
        libwebsockets-4_5 = pkgs.libwebsockets.overrideAttrs (old: {
          version = "4.5.8";
          src = pkgs.fetchurl {
            url = "https://github.com/warmcat/libwebsockets/archive/v4.5.8.tar.gz";
            hash = "sha256-tq3mWPSvOoI9DcgGrl7wYj8PT14q64laD3fEeDhAww4=";
          };
          patches = [];
          postInstall = (old.postInstall or "") + ''
            for pc in "$out"/lib/pkgconfig/*.pc "$dev"/lib/pkgconfig/*.pc; do
              [ -f "$pc" ] || continue
              substituteInPlace "$pc" \
                --replace-quiet 'libdir=''${exec_prefix}/'"$out"'/lib' 'libdir='"$out"'/lib'
            done
          '';
        });
      in {
        packages = {
          inherit xrt fastflowlm;
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pkgs.callPackage ./pkgs/lemonade {
            inherit fastflowlm;
            libwebsockets = libwebsockets-4_5;
          };
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
