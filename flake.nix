{
  description = "AMD AI inference stack for NixOS (XRT, xrt-plugin-amdxdna, FastFlowLM, Lemonade)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}: let
    # Bump libwebsockets from 4.4.1 to 4.5.8: 4.4.1 emits a malformed HTTP/101
    # upgrade response (missing the empty CRLF after the last header) for
    # lemonade's /realtime endpoint, which strict clients (Firefox, aiohttp,
    # python-websockets) reject with code 1006.
    libwebsocketsOverride = pkgs:
      pkgs.libwebsockets.overrideAttrs (old: rec {
        version = "4.5.8";
        src = pkgs.fetchFromGitHub {
          owner = "warmcat";
          repo = "libwebsockets";
          rev = "v${version}";
          hash = "sha256-0pLBxOSKaxboHd9L27RKKqSJ9lVH4wPgKSyXEoJMal4=";
        };
        # 4.5.8 already contains upstream's fix for CVE-2025-11677; the
        # nixpkgs back-port patch fails to apply on top.
        patches = [];
        # 4.5.8's .pc.in uses CMAKE_INSTALL_FULL_LIBDIR (absolute), so the
        # nixpkgs pc-fix substitute leaves a `${exec_prefix}//nix/store/.../lib`
        # artifact that the pkg-config-broken-path check rejects. Rewrite to
        # absolute paths.
        postInstall = (old.postInstall or "") + ''
          for pc in "$out"/lib/pkgconfig/*.pc "$dev"/lib/pkgconfig/*.pc; do
            [ -f "$pc" ] || continue
            sed -i \
              -e "s|^libdir=.*$|libdir=$out/lib|" \
              -e "s|^includedir=.*$|includedir=$dev/include|" \
              "$pc"
          done
        '';
      });
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];

      flake = {
        overlays.default = final: prev: let
          # Build everything against our own nixpkgs input rather than the
          # consumer's `final`, so the input closure matches CI's and Cachix
          # substitution works regardless of which channel the consumer is on.
          pinned = import inputs.nixpkgs {inherit (final.stdenv.hostPlatform) system;};
          libwebsockets = libwebsocketsOverride pinned;
          xrt = pinned.callPackage ./pkgs/xrt {};
          fastflowlm = pinned.callPackage ./pkgs/fastflowlm {inherit xrt;};
          llama-cpp-vulkan = pinned.llama-cpp.override {vulkanSupport = true;};
          whisper-cpp-vulkan = pinned.whisper-cpp.override {vulkanSupport = true;};
          stable-diffusion-cpp-rocm = pinned.stable-diffusion-cpp.override {rocmSupport = true;};
        in {
          inherit xrt fastflowlm llama-cpp-vulkan libwebsockets;
          inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm;
          inherit (pinned) llama-cpp-rocm;
          xrt-plugin-amdxdna = pinned.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pinned.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm;
            inherit (pinned) llama-cpp-rocm whisper-cpp stable-diffusion-cpp;
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
        whisper-cpp-vulkan = pkgs.whisper-cpp.override {vulkanSupport = true;};
        stable-diffusion-cpp-rocm = pkgs.stable-diffusion-cpp.override {rocmSupport = true;};
        libwebsockets = libwebsocketsOverride pkgs;
      in {
        packages = {
          inherit xrt fastflowlm llama-cpp-vulkan libwebsockets;
          inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm;
          inherit (pkgs) llama-cpp-rocm;
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pkgs.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm;
            llama-cpp-rocm = pkgs.llama-cpp-rocm;
            whisper-cpp = pkgs.whisper-cpp;
            stable-diffusion-cpp = pkgs.stable-diffusion-cpp;
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
