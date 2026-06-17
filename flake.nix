{
  description = "AMD AI inference stack for NixOS (XRT, xrt-plugin-amdxdna, FastFlowLM, Lemonade)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
        postInstall =
          (old.postInstall or "")
          + ''
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
      systems = ["x86_64-linux" "aarch64-darwin"];

      flake = {
        overlays.default = final: prev: let
          # Build everything against our own nixpkgs input rather than the
          # consumer's `final`, so the input closure matches CI's and Cachix
          # substitution works regardless of which channel the consumer is on.
          pinned = import inputs.nixpkgs {inherit (prev.stdenv.hostPlatform) system;};
        in
          # Branch on `prev` (not `final`): making the overlay's key set depend
          # on `final.stdenv` would force the fixpoint and recurse infinitely.
          if !prev.stdenv.hostPlatform.isLinux
          then {
            # macOS: only the cross-platform Lemonade server (Metal backend).
            # The AMD/XRT/ROCm stack below is Linux + AMD-hardware only.
            lemonade = pinned.callPackage ./pkgs/lemonade/darwin.nix {};
          }
          else let
            libwebsockets = libwebsocketsOverride pinned;
            xrt = pinned.callPackage ./pkgs/xrt {};
            fastflowlm = pinned.callPackage ./pkgs/fastflowlm {inherit xrt;};
            llama-cpp = pinned.llama-cpp;
            llama-cpp-vulkan = pinned.llama-cpp.override {vulkanSupport = true;};
            llama-cpp-rocm = pinned.llama-cpp-rocm;
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

        darwinModules.default = {
          imports = [./modules/lemonade-darwin.nix];
          nixpkgs.overlays = [inputs.self.overlays.default];
        };
      };

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        isLinux = inputs.nixpkgs.lib.hasSuffix "linux" system;

        # AMD NPU/XRT/ROCm/Vulkan stack — Linux + AMD-hardware only.
        linuxPackages = let
          xrt = pkgs.callPackage ./pkgs/xrt {};
          fastflowlm = pkgs.callPackage ./pkgs/fastflowlm {inherit xrt;};
          llama-cpp = pkgs.llama-cpp;
          llama-cpp-vulkan = pkgs.llama-cpp.override {vulkanSupport = true;};
          llama-cpp-rocm = pkgs.llama-cpp-rocm;
          whisper-cpp-vulkan = pkgs.whisper-cpp.override {vulkanSupport = true;};
          stable-diffusion-cpp-rocm = pkgs.stable-diffusion-cpp.override {rocmSupport = true;};
          libwebsockets = libwebsocketsOverride pkgs;
        in {
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
          lemond-unit = lemondUnit;
        };

        # macOS: server-only Lemonade wrap (Metal backend, fetched at runtime).
        darwinPackages = {
          lemonade = pkgs.callPackage ./pkgs/lemonade/darwin.nix {};
        };

        # Rendered lemond.service for a minimal enableLemonade host — consumed by
        # the lemond-unit-render check and the CI systemd-analyze step.
        lemondUnit =
          (inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              inputs.self.nixosModules.default
              {
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "/dev/sda1";
                  fsType = "ext4";
                };
                hardware.amd-npu = {
                  enable = true;
                  enableLemonade = true;
                  lemonade.user = "testuser";
                };
                users.users.testuser = {
                  isNormalUser = true;
                  extraGroups = ["video" "render"];
                };
              }
            ];
          }).config.systemd.units."lemond.service".unit;
      in {
        packages =
          (
            if isLinux
            then linuxPackages
            else darwinPackages
          )
          // {
            # Pure Go — builds on every system.
            benchmark = pkgs.callPackage ./pkgs/benchmark-go {};
          };

        # Module eval checks: NixOS module on Linux, nix-darwin module on macOS.
        checks =
          if isLinux
          then {
            module-eval-rocm-false =
              (inputs.nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  inputs.self.nixosModules.default
                  {
                    boot.loader.grub.enable = false;
                    fileSystems."/" = {
                      device = "/dev/sda1";
                      fsType = "ext4";
                    };
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

            module-eval-rocm-true =
              (inputs.nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  inputs.self.nixosModules.default
                  {
                    boot.loader.grub.enable = false;
                    fileSystems."/" = {
                      device = "/dev/sda1";
                      fsType = "ext4";
                    };
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

            module-eval-vulkan-true =
              (inputs.nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  inputs.self.nixosModules.default
                  {
                    boot.loader.grub.enable = false;
                    fileSystems."/" = {
                      device = "/dev/sda1";
                      fsType = "ext4";
                    };
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
              mkSys = extra:
                (inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.default
                    {
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "/dev/sda1";
                        fsType = "ext4";
                      };
                      hardware.amd-npu =
                        {
                          enable = true;
                          lemonade.user = "testuser";
                        }
                        // extra;
                      users.users.testuser = {
                        isNormalUser = true;
                        extraGroups = ["video" "render"];
                      };
                    }
                  ];
                }).config.boot.extraModprobeConfig;
              configured = mkSys {
                gpuMemory = {
                  ttmSizeGiB = 120;
                  pagePoolSizeGiB = 60;
                };
              };
              ttmOnly = mkSys {
                gpuMemory = {ttmSizeGiB = 10;};
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

            # The lemond unit must keep its writable runtime dir + nix-ld loader
            # env, else omni backends (WhisperServer, koko TTS) fail to load. The
            # NIX_LD paths track the values nix-ld exports as session vars.
            # (Semantic `systemd-analyze verify` runs in CI — it can't create
            # /run/systemd inside nix's build sandbox.)
            lemond-unit-render = pkgs.runCommand "lemond-unit-render" {} ''
              unit=${lemondUnit}/lemond.service
              grep -q 'RuntimeDirectory=lemond' "$unit" || { echo "missing RuntimeDirectory"; exit 1; }
              grep -q 'NIX_LD=/run/current-system/sw/share/nix-ld/lib/ld.so' "$unit" \
                || { echo "missing/changed NIX_LD"; exit 1; }
              grep -q 'NIX_LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib' "$unit" \
                || { echo "missing/changed NIX_LD_LIBRARY_PATH"; exit 1; }
              touch $out
            '';
          }
          else {
            # Force the nix-darwin module to evaluate and assert the launchd
            # agent wires lemond with the configured port.
            module-eval-darwin = let
              cfg =
                (inputs.nix-darwin.lib.darwinSystem {
                  inherit system;
                  modules = [
                    inputs.self.darwinModules.default
                    {
                      services.lemonade = {
                        enable = true;
                        port = 13305;
                      };
                      system.stateVersion = 6;
                      system.primaryUser = "testuser";
                      users.users.testuser.home = "/Users/testuser";
                    }
                  ];
                }).config;
              cmdline = builtins.concatStringsSep " " cfg.launchd.user.agents.lemonade.serviceConfig.ProgramArguments;
            in
              pkgs.runCommand "module-eval-darwin" {inherit cmdline;} ''
                echo "$cmdline" | grep -F -- '--port 13305'
                echo "$cmdline" | grep -F 'bin/lemond'
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
