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

    # Pin llama-cpp to b9253 (the build lemonade v10.6.0 ships against) so
    # the `mtp` recipe lights up — MTP support merged in ggml-org/llama.cpp#22673
    # at b9175. The posix_spawnp patch works around upstream issue #20868: at
    # b9175+, mul_mm.comp's shader-variant explosion makes shader-gen's
    # fork()+std::async pattern accumulate enough thread-stack VM that
    # heuristic overcommit rejects further fork()s with ENOMEM.
    llamaCppMtpSrc = pkgs: pkgs.fetchFromGitHub {
      owner = "ggml-org";
      repo = "llama.cpp";
      rev = "29f1482221b68fdbf5bd9b762c9e3e350e21f1ec";
      hash = "sha256-EehegfVuh3Y88bjCzMU5Mgkc+ZqhPwBVrRR2oaYwCaw=";
    };
    llamaCppMtpOverride = pkgs: pkg:
      pkg.overrideAttrs (_old: {
        # LLAMA_BUILD_NUMBER is stamped into a C int literal.
        version = "9253";
        pname = "llama-cpp-mtp";
        src = llamaCppMtpSrc pkgs;
        patches = [./pkgs/llama-cpp-vulkan-shaders-gen-posix-spawn.patch];
        postPatch = "";
        npmRoot = "tools/ui";
        npmDepsHash = "sha256-Iyg8FpcTKf2UYHuK7mA3cTAqVaLcQPcS0YCa5Qf01Gc=";
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
          llama-cpp = llamaCppMtpOverride pinned pinned.llama-cpp;
          llama-cpp-vulkan = llamaCppMtpOverride pinned (pinned.llama-cpp.override {vulkanSupport = true;});
          llama-cpp-rocm = llamaCppMtpOverride pinned pinned.llama-cpp-rocm;
          whisper-cpp-vulkan = pinned.whisper-cpp.override {vulkanSupport = true;};
          stable-diffusion-cpp-rocm = pinned.stable-diffusion-cpp.override {rocmSupport = true;};
        in {
          inherit xrt fastflowlm llama-cpp llama-cpp-vulkan llama-cpp-rocm libwebsockets;
          inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm;
          xrt-plugin-amdxdna = pinned.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pinned.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan llama-cpp-rocm libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm;
            inherit (pinned) whisper-cpp stable-diffusion-cpp;
          };
          gaia = pinned.callPackage ./pkgs/gaia {};
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
        llama-cpp = llamaCppMtpOverride pkgs pkgs.llama-cpp;
        llama-cpp-vulkan = llamaCppMtpOverride pkgs (pkgs.llama-cpp.override {vulkanSupport = true;});
        llama-cpp-rocm = llamaCppMtpOverride pkgs pkgs.llama-cpp-rocm;
        whisper-cpp-vulkan = pkgs.whisper-cpp.override {vulkanSupport = true;};
        stable-diffusion-cpp-rocm = pkgs.stable-diffusion-cpp.override {rocmSupport = true;};
        libwebsockets = libwebsocketsOverride pkgs;
      in {
        packages = {
          inherit xrt fastflowlm llama-cpp llama-cpp-vulkan llama-cpp-rocm libwebsockets;
          inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm;
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pkgs.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan llama-cpp-rocm libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm;
            whisper-cpp = pkgs.whisper-cpp;
            stable-diffusion-cpp = pkgs.stable-diffusion-cpp;
          };
          gaia = pkgs.callPackage ./pkgs/gaia {};
          benchmark = pkgs.callPackage ./pkgs/benchmark-go {};
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

          # GTT headroom: configured system emits the ttm modprobe line with
          # GiB→page conversion; default system emits no ttm line.
          module-eval-gtt = let
            mkSys = extra: (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                inputs.self.nixosModules.default
                {
                  boot.loader.grub.enable = false;
                  fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
                  hardware.amd-npu = {
                    enable = true;
                    lemonade.user = "testuser";
                  } // extra;
                  users.users.testuser = {
                    isNormalUser = true;
                    extraGroups = ["video" "render"];
                  };
                }
              ];
            }).config.boot.extraModprobeConfig;
            configured = mkSys {
              gpuMemory = { ttmSizeGiB = 120; pagePoolSizeGiB = 60; };
            };
            ttmOnly = mkSys {
              gpuMemory = { ttmSizeGiB = 10; };
            };
            default = mkSys {};
          in
            pkgs.runCommand "module-eval-gtt" {
              inherit configured ttmOnly default;
            } ''
              echo "$configured" | grep -F 'options ttm pages_limit=31457280 page_pool_size=15728640'
              echo "$ttmOnly" | grep -F 'options ttm pages_limit=2621440'
              echo "$ttmOnly" | grep -vq 'page_pool_size' || { echo "ttm-only must not set page_pool_size"; exit 1; }
              echo "$default" | grep -vq 'pages_limit' || { echo "default must not set pages_limit"; exit 1; }
              touch $out
            '';
        };

        apps.benchmark = {
          type = "app";
          program = "${pkgs.callPackage ./pkgs/benchmark-go {}}/bin/benchmark";
          meta = {description = "Benchmark lemonade backends — interactive TUI or headless (ROCm, Vulkan, FLM)";};
        };
      };
    };
}
