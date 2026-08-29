{
  description = "AMD AI inference stack for NixOS (XRT, xrt-plugin-amdxdna, FastFlowLM, Lemonade)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
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
            stable-diffusion-cpp-vulkan = pinned.stable-diffusion-cpp.override {vulkanSupport = true;};
          in {
            inherit xrt fastflowlm llama-cpp llama-cpp-vulkan llama-cpp-rocm libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
            ds4 = pinned.callPackage ./pkgs/ds4 {};
            xrt-plugin-amdxdna = pinned.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
            lemonade = pinned.callPackage ./pkgs/lemonade {
              inherit fastflowlm llama-cpp-vulkan llama-cpp-rocm libwebsockets;
              inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
              inherit (pinned) whisper-cpp stable-diffusion-cpp;
            };
            gaia = pinned.callPackage ./pkgs/gaia {};
            vllm-rocm = pinned.callPackage ./pkgs/vllm-rocm {};
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
          stable-diffusion-cpp-vulkan = pkgs.stable-diffusion-cpp.override {vulkanSupport = true;};
          libwebsockets = libwebsocketsOverride pkgs;
        in {
          inherit xrt fastflowlm llama-cpp llama-cpp-vulkan llama-cpp-rocm libwebsockets;
          inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
          ds4 = pkgs.callPackage ./pkgs/ds4 {};
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pkgs.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan llama-cpp-rocm libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
            whisper-cpp = pkgs.whisper-cpp;
            stable-diffusion-cpp = pkgs.stable-diffusion-cpp;
          };
          gaia = pkgs.callPackage ./pkgs/gaia {};
          vllm-rocm = pkgs.callPackage ./pkgs/vllm-rocm {};
          lemond-unit = lemondUnit;
          ds4-server-unit = ds4ServerUnit;
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

        # Rendered ds4-server.service for a minimal ds4.enable host — consumed by
        # the ds4-server-unit-render check.
        ds4ServerUnit =
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
                  ds4 = {
                    enable = true;
                    user = "testuser";
                    model = "/var/lib/ds4/DeepSeek-V4-Flash.gguf";
                    ctx = 100000;
                    extraArgs = ["--ssd-streaming"];
                  };
                };
                users.users.testuser = {
                  isNormalUser = true;
                  extraGroups = ["video" "render"];
                };
              }
            ];
          }).config.systemd.units."ds4-server.service".unit;
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

            # enableVllm wiring: evaluate the module and build the generated
            # lemonade defaults (asserts pass, vllm.rocm_bin seeded, global_timeout
            # bumped off 0). Targets the defaults JSON rather than system.build.etc
            # on purpose — the latter would realize the 7.6 GB vllm-rocm bundle,
            # which no substituter serves.
            module-eval-vllm =
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
                      enableNPU = false;
                      enableFastFlowLM = false;
                      enableLemonade = true;
                      enableROCm = true;
                      enableVllm = true;
                      lemonade.user = "testuser";
                    };
                    users.users.testuser = {
                      isNormalUser = true;
                      extraGroups = ["video" "render"];
                    };
                  }
                ];
              }).config.systemd.services.lemond.environment.LEMONADE_DEFAULTS_PATH;

            # The warning must fire on gfx1151 below the CWSR-fix kernel whether
            # the signal is gpuTarget or the older vllmGpuTarget, and stay silent
            # on gfx1150 or a new-enough kernel.
            module-eval-cwsr-warning = let
              mkSys = extraModule:
                (inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.default
                    (pkgs.lib.recursiveUpdate {
                        boot.loader.grub.enable = false;
                        fileSystems."/" = {
                          device = "/dev/sda1";
                          fsType = "ext4";
                        };
                        hardware.amd-npu = {
                          enable = true;
                          enableNPU = false;
                          enableFastFlowLM = false;
                          enableLemonade = true;
                          enableROCm = true;
                          lemonade.user = "testuser";
                        };
                        users.users.testuser = {
                          isNormalUser = true;
                          extraGroups = ["video" "render"];
                        };
                      }
                      extraModule)
                  ];
                }).config.warnings;
              # The bug this check guards: an llamacpp-only gfx1151 host that
              # never touches vllmGpuTarget used to get no warning at all.
              oldKernelGfx1151NoVllm = mkSys {
                hardware.amd-npu.gpuTarget = "gfx1151";
                boot.kernelPackages = pkgs.linuxPackages_6_12;
              };
              oldKernelGfx1151VllmOn = mkSys {
                hardware.amd-npu = {
                  gpuTarget = "gfx1151";
                  enableVllm = true;
                  vllmGpuTarget = "gfx1151";
                };
                boot.kernelPackages = pkgs.linuxPackages_6_12;
              };
              # Back-compat: an existing config that only ever set the legacy
              # vLLM-only knob must keep warning, even though gpuTarget defaults
              # to gfx1150.
              oldKernelExplicitVllmTargetOnly = mkSys {
                hardware.amd-npu.vllmGpuTarget = "gfx1151";
                boot.kernelPackages = pkgs.linuxPackages_6_12;
              };
              oldKernelGfx1150 = mkSys {
                hardware.amd-npu.gpuTarget = "gfx1150";
                boot.kernelPackages = pkgs.linuxPackages_6_12;
              };
              newKernelGfx1151 = mkSys {
                hardware.amd-npu.gpuTarget = "gfx1151";
              };
            in
              pkgs.runCommand "module-eval-cwsr-warning" {
                old1151NoVllm = builtins.toJSON oldKernelGfx1151NoVllm;
                old1151VllmOn = builtins.toJSON oldKernelGfx1151VllmOn;
                oldExplicitVllmTargetOnly = builtins.toJSON oldKernelExplicitVllmTargetOnly;
                old1150 = builtins.toJSON oldKernelGfx1150;
                new1151 = builtins.toJSON newKernelGfx1151;
                passAsFile = ["old1151NoVllm" "old1151VllmOn" "oldExplicitVllmTargetOnly" "old1150" "new1151"];
              } ''
                grep -q cwsr_size "$old1151NoVllmPath" || { echo "gfx1151 + old kernel, vLLM off, via gpuTarget must warn"; exit 1; }
                grep -q cwsr_size "$old1151VllmOnPath" || { echo "gfx1151 + old kernel + vLLM on must warn"; exit 1; }
                grep -q cwsr_size "$oldExplicitVllmTargetOnlyPath" || { echo "legacy vllmGpuTarget-only config must still warn"; exit 1; }
                grep -q cwsr_size "$old1150Path" && { echo "gfx1150 must not warn"; exit 1; }
                grep -q cwsr_size "$new1151Path" && { echo "gfx1151 + new kernel must not warn"; exit 1; }
                touch $out
              '';

            # lemonade.settings must deep-merge over the module's computed
            # defaults — overriding one key without dropping its siblings — and
            # the unit must re-apply them on every start, else the option is
            # inert on any host that already persisted a config.json.
            module-eval-lemonade-settings = let
              sys =
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
                        lemonade = {
                          user = "testuser";
                          settings = {
                            max_loaded_models = -1;
                            llamacpp.args = "--custom";
                          };
                        };
                      };
                      users.users.testuser = {
                        isNormalUser = true;
                        extraGroups = ["video" "render"];
                      };
                    }
                  ];
                }).config;
            in
              pkgs.runCommand "module-eval-lemonade-settings" {
                nativeBuildInputs = [pkgs.jq];
                defaults = sys.systemd.services.lemond.environment.LEMONADE_DEFAULTS_PATH;
                unit = sys.systemd.units."lemond.service".unit;
              } ''
                jq -e '.max_loaded_models == -1' "$defaults" >/dev/null
                jq -e '.llamacpp.args == "--custom"' "$defaults" >/dev/null
                jq -e '.llamacpp.cpu_bin | startswith("/etc/lemonade/backends/")' "$defaults" >/dev/null

                # Run the unit's own ExecStartPre against a config that has both a
                # stale module-managed key and a user-only key, and assert the merge
                # direction — a broken jq expression would otherwise ship green.
                reconcile=$(sed -n 's/^ExecStartPre=//p' "$unit"/lemond.service)
                export HOME=$TMPDIR/home
                mkdir -p "$HOME/.config/lemonade"
                cfg=$HOME/.config/lemonade/config.json
                echo '{"host":"0.0.0.0","max_loaded_models":1,"llamacpp":{"args":"--stale"}}' >"$cfg"
                chmod 600 "$cfg"
                "$reconcile"

                jq -e '.max_loaded_models == -1' "$cfg" >/dev/null   # module key re-applied
                jq -e '.llamacpp.args == "--custom"' "$cfg" >/dev/null
                jq -e '.host == "0.0.0.0"' "$cfg" >/dev/null         # user-only key preserved
                [ "$(stat -c %a "$cfg")" = 600 ]                     # mode not widened

                touch $out
              '';

            module-eval-lemonade-allowed-origins = let
              sys =
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
                        lemonade = {
                          user = "testuser";
                          host = "0.0.0.0";
                          allowedOrigins = ["https://app.example.com" "http://192.168.1.10:3000"];
                        };
                      };
                      users.users.testuser = {
                        isNormalUser = true;
                        extraGroups = ["video" "render"];
                      };
                    }
                  ];
                }).config;
            in
              pkgs.runCommand "module-eval-lemonade-allowed-origins" {
                unit = sys.systemd.units."lemond.service".unit;
              } ''
                grep -qF 'Environment="LEMONADE_ALLOWED_ORIGINS=https://app.example.com,http://192.168.1.10:3000"' "$unit"/lemond.service

                touch $out
              '';

            # The checks above prove the unit renders and that the hook behaves
            # when invoked by hand. This one boots it: lemond must actually reach
            # active with the ExecStartPre in front of it. That is the failure
            # class eval checks structurally cannot see — a hook that aborts
            # takes the whole service down with it.
            lemond-vm =
              # Driven from an already-overlaid pkgs, importing the bare module:
              # nixosModules.default bundles nixpkgs.overlays for consumers, and
              # the test framework pins nixpkgs read-only.
              (import inputs.nixpkgs {
                inherit system;
                overlays = [inputs.self.overlays.default];
              })
            .testers.runNixOSTest {
                name = "lemond-reconcile";
                nodes.machine = {
                  lib,
                  pkgs,
                  ...
                }: {
                  imports = [./modules/amd-npu.nix];
                  environment.systemPackages = [pkgs.jq];
                  hardware.amd-npu = {
                    enable = true;
                    enableNPU = false;
                    enableFastFlowLM = false;
                    enableROCm = false;
                    enableVulkan = false;
                    enableImageGen = false;
                    lemonade = {
                      user = "tester";
                      settings.max_loaded_models = -1;
                    };
                  };
                  users.users.tester.isNormalUser = true;
                  # Hold lemond back so the stale config is in place before its
                  # first start; left to boot it would seed a fresh config, the one
                  # path that never exercises reconciliation.
                  systemd.services.lemond.wantedBy = lib.mkForce [];
                };
                testScript = ''
                  cfg = "/home/tester/.config/lemonade/config.json"

                  machine.wait_for_unit("multi-user.target")

                  # A config as a pre-existing host holds it: one module-managed key
                  # gone stale, one key only the user or web UI ever sets. The
                  # user-only key is ctx_size rather than host/port because lemond
                  # persists those two from its own flags after the hook has run
                  # (main.cpp:82-99), so they would prove nothing here.
                  machine.succeed("mkdir -p /home/tester/.config/lemonade")
                  machine.succeed(
                      "printf '%s' "
                      "'{\"ctx_size\":8192,\"max_loaded_models\":1,\"llamacpp\":{\"args\":\"--stale\"}}'"
                      " > " + cfg
                  )
                  machine.succeed("chown -R tester:users /home/tester/.config")

                  machine.succeed("systemctl start lemond")
                  machine.wait_for_unit("lemond.service")

                  machine.succeed("jq -e '.max_loaded_models == -1' " + cfg)
                  machine.succeed("jq -e '.llamacpp.args == \"--flash-attn on\"' " + cfg)
                  machine.succeed("jq -e '.llamacpp.cpu_bin | startswith(\"/etc/lemonade/backends/\")' " + cfg)
                  machine.succeed("jq -e '.ctx_size == 8192' " + cfg)
                  machine.succeed("test $(stat -c %U " + cfg + ") = tester")

                  # No mode assertion: the same CLI-override save rewrites the file
                  # through a fresh ofstream + rename, resetting it to 0644 on every
                  # start. module-eval-lemonade-settings covers the hook's own
                  # mode handling, which is the part we control.
                '';
              };

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
              ! grep -q 'LEMONADE_ALLOWED_ORIGINS' "$unit" \
                || { echo "LEMONADE_ALLOWED_ORIGINS set on a host that never listed origins"; exit 1; }
              touch $out
            '';

            # ds4-server assembles its argv from the ds4.* options: the model
            # path, ctx, host/port, and passthrough extraArgs must all land on
            # the ExecStart line, and the unit must grant render/video GPU
            # access plus a writable state dir.
            ds4-server-unit-render = pkgs.runCommand "ds4-server-unit-render" {} ''
              unit=${ds4ServerUnit}/ds4-server.service
              grep -q -- '--model /var/lib/ds4/DeepSeek-V4-Flash.gguf' "$unit" || { echo "missing/changed --model"; exit 1; }
              grep -q -- '--ctx 100000' "$unit" || { echo "missing/changed --ctx"; exit 1; }
              grep -q -- '--port 8000' "$unit" || { echo "missing/changed --port"; exit 1; }
              grep -q -- '--ssd-streaming' "$unit" || { echo "missing extraArgs passthrough"; exit 1; }
              grep -q 'SupplementaryGroups=video' "$unit" || { echo "missing video group"; exit 1; }
              grep -q 'SupplementaryGroups=render' "$unit" || { echo "missing render group"; exit 1; }
              grep -q 'StateDirectory=ds4' "$unit" || { echo "missing StateDirectory"; exit 1; }
              touch $out
            '';

            # The /etc/lemonade/backends/* symlinks exist only to feed lemond, so
            # they must not appear when enableLemonade is off — even with ROCm and
            # Vulkan on. Reads environment.etc attr names only, so it skips the
            # bootloader/root-fs stubs (and engine builds) the other checks force
            # via system.build.etc.
            module-eval-lemonade-false = let
              etcNames =
                builtins.concatStringsSep "\n"
                (builtins.attrNames
                  (inputs.nixpkgs.lib.nixosSystem {
                    inherit system;
                    modules = [
                      inputs.self.nixosModules.default
                      {
                        hardware.amd-npu = {
                          enable = true;
                          enableLemonade = false;
                          enableROCm = true;
                          enableVulkan = true;
                          lemonade.user = "testuser";
                        };
                      }
                    ];
                  }).config.environment.etc);
            in
              pkgs.runCommand "module-eval-lemonade-false" {inherit etcNames;} ''
                if echo "$etcNames" | grep -q 'lemonade/backends'; then
                  echo "enableLemonade=false must not create lemonade/backends symlinks"
                  exit 1
                fi
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
