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
    # The chips this repo supports, as one derivation rather than one each, so
    # both kinds of host substitute the single entry CI pushes. nixpkgs' own
    # default is every target clr advertises -- 16 in the pinned nixpkgs.
    rocmGpuTargets = ["gfx1150" "gfx1151"];

    # FastFlowLM's NPU kernels (.xclbin, share/flm) are proprietary beside its
    # MIT source, so nixpkgs marks the package unfree. Allow exactly that
    # package where this repo instantiates nixpkgs. #158
    allowFastFlowLMUnfree = pkg:
      builtins.elem (inputs.nixpkgs.lib.getName pkg) ["fastflowlm"];

    # This repo's own NixOS eval checks and unit renders opt in to fastflowlm's
    # unfree licence the same way a consumer must. #158
    fastFlowLMUnfreeConfig = {
      nixpkgs.config.allowUnfreePredicate = allowFastFlowLMUnfree;
    };

    # Bump libwebsockets from 4.4.1 to 4.5.8: 4.4.1 emits a malformed HTTP/101
    # upgrade response (missing the empty CRLF after the last header) for
    # lemonade's /realtime endpoint, which strict clients (Firefox, aiohttp,
    # python-websockets) reject with code 1006.
    # RDNA3.5 iGPUs report as integrated, so ggml lets tensors sit in host
    # memory for the GPU to read directly -- and that returns wrong data on
    # them. Measured, CPU reference vs ROCm, same corpus and flags:
    #
    #   gfx1151 Halo,        Qwen3.5-4B:      6.79 vs 1334      -> 6.8182 patched
    #   gfx1150 Strix Point, Qwen3.5-4B:      6.79 vs 1638      -> 6.8182 patched
    #   gfx1150 Strix Point, Gemma-4-26B-A4B: 385  vs 250459    (deployed build)
    #
    # Vulkan and CPU are correct on both chips throughout, and AMD's own gfx1151
    # prebuilt reproduces it, so this is neither our packaging nor ROCm version.
    #
    # ggml-org/llama.cpp#28211 carries 865374bb for this, but that patch gates on
    # gfx1151 alone (`cc == GGML_CUDA_CC_RDNA3_5 + 1`) and gfx1150 is equally
    # affected. We widen it to the whole family via GGML_CUDA_CC_IS_RDNA3_5.
    #
    # The prePatch guard retires this by itself: `direct_host_access` is the
    # variable both our patch and upstream's introduce, so when the pinned
    # nixpkgs carries either form of the fix the build fails telling you to
    # delete the override, rather than silently double-applying it.
    llamaCppRocmOverride = pkgs:
      (pkgs.llama-cpp-rocm.override {
        llama-cpp = pkgs.llama-cpp.override {inherit rocmGpuTargets;};
      })
      .overrideAttrs (old: {
        patches = (old.patches or []) ++ [./patches/llamacpp-rdna35-host-access.patch];
        prePatch =
          (old.prePatch or "")
          + ''
            if grep -q direct_host_access ggml/src/ggml-cuda/ggml-cuda.cu; then
              echo "llama-cpp-rocm: upstream now carries the host-access fix." >&2
              echo "Drop llamaCppRocmOverride and patches/llamacpp-rdna35-host-access.patch." >&2
              echo "Check it covers gfx1150 too, not just gfx1151:" >&2
              echo "  https://github.com/ggml-org/llama.cpp/issues/28211" >&2
              exit 1
            fi
          '';
      });

    # nixpkgs builds llama.cpp's embedded server UI (tools/ui) with npm, which
    # pulls `nodejs_latest` -- the newest Node by definition, hence the
    # attribute least likely to be on cache.nixos.org. A nixpkgs bump whose
    # Node Hydra hasn't finished then costs a ~40 min V8 compile, and Node's
    # check phase fails in this sandbox regardless (parallel/
    # test-fs-cp-async-file-modes chmods a setuid file, which the sandbox
    # refuses). We use lemond's web UI, not llama.cpp's, so build without it:
    # tools/ui/CMakeLists.txt documents this as "building without an embedded
    # UI", emitting empty ui.cpp/ui.h. A later overlay can put it back.
    llamaCppNoWebUi = pkgs: pkg:
      pkg.overrideAttrs (old: {
        nativeBuildInputs = builtins.filter
          (d: d != pkgs.nodejs_latest && d != pkgs.npmHooks.npmConfigHook)
          old.nativeBuildInputs;
        # npmDeps is only read by the hook above; left in place it stays a
        # derivation input and is fetched for nothing.
        npmDeps = null;
        preConfigure = "";
        cmakeFlags = (old.cmakeFlags or []) ++ [
          "-DLLAMA_BUILD_UI=OFF"
          "-DLLAMA_USE_PREBUILT_UI=OFF"
        ];
      });

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
          # Build against our own nixpkgs input for closure/Cachix stability,
          # but inherit the consumer's unfree policy so fastflowlm is refused
          # under allowUnfree = false. Mirror only the unfree keys. #158
          pinned = import inputs.nixpkgs {
            inherit (prev.stdenv.hostPlatform) system;
            config = builtins.intersectAttrs {
              allowUnfree = null;
              allowUnfreePredicate = null;
              allowUnfreePackages = null;
            } (prev.config or {});
          };
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
            llama-cpp = llamaCppNoWebUi pinned pinned.llama-cpp;
            llama-cpp-vulkan = llamaCppNoWebUi pinned (pinned.llama-cpp.override {vulkanSupport = true;});
            llama-cpp-rocm = llamaCppNoWebUi pinned (llamaCppRocmOverride pinned);
            whisper-cpp-vulkan = pinned.whisper-cpp.override {vulkanSupport = true;};
            stable-diffusion-cpp-rocm = pinned.stable-diffusion-cpp.override {
              rocmSupport = true;
              inherit rocmGpuTargets;
            };
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
        system,
        ...
      }: let
        # flake-parts' default pkgs is a bare nixpkgs import, which rejects
        # unfree; configure it for fastflowlm. #158
        pkgs = import inputs.nixpkgs {
          inherit system;
          config.allowUnfreePredicate = allowFastFlowLMUnfree;
        };

        isLinux = inputs.nixpkgs.lib.hasSuffix "linux" system;

        # AMD NPU/XRT/ROCm/Vulkan stack — Linux + AMD-hardware only.
        linuxPackages = let
          xrt = pkgs.callPackage ./pkgs/xrt {};
          fastflowlm = pkgs.callPackage ./pkgs/fastflowlm {inherit xrt;};
          llama-cpp = llamaCppNoWebUi pkgs pkgs.llama-cpp;
          llama-cpp-vulkan = llamaCppNoWebUi pkgs (pkgs.llama-cpp.override {vulkanSupport = true;});
          llama-cpp-rocm = llamaCppNoWebUi pkgs (llamaCppRocmOverride pkgs);
          whisper-cpp-vulkan = pkgs.whisper-cpp.override {vulkanSupport = true;};
          stable-diffusion-cpp-rocm = pkgs.stable-diffusion-cpp.override {
            rocmSupport = true;
            inherit rocmGpuTargets;
          };
          stable-diffusion-cpp-vulkan = pkgs.stable-diffusion-cpp.override {vulkanSupport = true;};
          libwebsockets = libwebsocketsOverride pkgs;
          lemonade = pkgs.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan llama-cpp-rocm libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
            whisper-cpp = pkgs.whisper-cpp;
            stable-diffusion-cpp = pkgs.stable-diffusion-cpp;
          };
        in {
          inherit xrt fastflowlm llama-cpp llama-cpp-vulkan llama-cpp-rocm libwebsockets lemonade;
          inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
          ds4 = pkgs.callPackage ./pkgs/ds4 {};
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          # What `hardware.amd-npu.lemonade.desktopApp.enable = false` selects;
          # built here so headless hosts substitute it rather than compile it.
          lemonade-headless = lemonade.override {withDesktopApp = false;};
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
              fastFlowLMUnfreeConfig
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

        # Same host as lemondUnit but with lemonade.cacheDir set — consumed by
        # the lemond-cachedir-unit-render check.
        lemondCacheDirUnit =
          (inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              inputs.self.nixosModules.default
              fastFlowLMUnfreeConfig
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
                  lemonade.cacheDir = "/var/lib/models";
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
              fastFlowLMUnfreeConfig
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
                  fastFlowLMUnfreeConfig
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
                  fastFlowLMUnfreeConfig
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

            # cacheDir must put both caches on the given root: HF_HOME gains the
            # /hf suffix (lemonade appends hub/ itself) and LEMONADE_CACHE_DIR the
            # /lemonade one. The absence case is asserted in lemond-unit-render.
            lemond-cachedir-unit-render = pkgs.runCommand "lemond-cachedir-unit-render" {} ''
              unit=${lemondCacheDirUnit}/lemond.service
              grep -q 'HF_HOME=/var/lib/models/hf' "$unit" \
                || { echo "missing/changed HF_HOME"; exit 1; }
              grep -q 'LEMONADE_CACHE_DIR=/var/lib/models/lemonade' "$unit" \
                || { echo "missing/changed LEMONADE_CACHE_DIR"; exit 1; }
              touch $out
            '';

            module-eval-vulkan-true =
              (inputs.nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  inputs.self.nixosModules.default
                  fastFlowLMUnfreeConfig
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
                  fastFlowLMUnfreeConfig
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
                    fastFlowLMUnfreeConfig
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
                    fastFlowLMUnfreeConfig
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

            # customModels must reach user_models.json even on a host that has no
            # config.json (nothing else creates that file), must not clobber a
            # model the web UI registered, and must re-apply a stale entry --
            # otherwise a declared checkpoint silently rots to whatever lemond
            # last persisted.
            module-eval-lemonade-custom-models = let
              sys =
                (inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.default
                    fastFlowLMUnfreeConfig
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
                          customModels."Declared-GGUF" = {
                            checkpoints.main = "org/repo:declared.gguf";
                            recipe = "llamacpp";
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
              pkgs.runCommand "module-eval-lemonade-custom-models" {
                nativeBuildInputs = [pkgs.jq];
                unit = sys.systemd.units."lemond.service".unit;
              } ''
                reconcile=$(sed -n 's/^ExecStartPre=//p' "$unit"/lemond.service)
                export HOME=$TMPDIR/home
                mkdir -p "$HOME/.config/lemonade"
                models=$HOME/.config/lemonade/user_models.json

                # No config.json and no user_models.json: the reconcile must still
                # create the latter rather than bailing out early.
                "$reconcile"
                jq -e '."Declared-GGUF".checkpoints.main == "org/repo:declared.gguf"' "$models" >/dev/null

                # A UI-registered model survives, and a drifted declared entry is restored.
                echo '{"UI-GGUF":{"recipe":"llamacpp"},"Declared-GGUF":{"checkpoints":{"main":"org/repo:stale.gguf"}}}' >"$models"
                chmod 600 "$models"
                "$reconcile"

                jq -e '."Declared-GGUF".checkpoints.main == "org/repo:declared.gguf"' "$models" >/dev/null
                jq -e '."UI-GGUF".recipe == "llamacpp"' "$models" >/dev/null
                [ "$(stat -c %a "$models")" = 600 ]

                touch $out
              '';

            module-eval-lemonade-models = let
              mkSys = lemonadeExtra:
                (inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.default
                    fastFlowLMUnfreeConfig
                    {
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "/dev/sda1";
                        fsType = "ext4";
                      };
                      hardware.amd-npu = {
                        enable = true;
                        enableLemonade = true;
                        lemonade = {user = "testuser";} // lemonadeExtra;
                      };
                      users.users.testuser = {
                        isNormalUser = true;
                        extraGroups = ["video" "render"];
                      };
                    }
                  ];
                }).config;
              declared = mkSys {models = ["Qwen3.5-4B-MTP-GGUF" "llama3.2-1b-FLM"];};
              pruning = mkSys {
                models = ["Qwen3.5-4B-MTP-GGUF"];
                pruneUnlistedModels = true;
              };
              none = mkSys {};
            in
              pkgs.runCommand "module-eval-lemonade-models" {
                unit = declared.systemd.units."lemond-models.service".unit;
                pruneUnit = pruning.systemd.units."lemond-models.service".unit;
                noneUnits = builtins.toJSON (builtins.attrNames none.systemd.units);
              } ''
                sync=$(sed -n 's/^ExecStart=//p' "$unit"/lemond-models.service)

                # The pull must not block activation on multi-GiB downloads.
                grep -qF 'Type=simple' "$unit"/lemond-models.service
                grep -qF 'After=lemond.service' "$unit"/lemond-models.service

                grep -qF 'Qwen3.5-4B-MTP-GGUF' "$sync"
                grep -qF 'llama3.2-1b-FLM' "$sync"

                # Deleting models is opt-in, so the prune branch must be absent
                # unless pruneUnlistedModels asked for it.
                ! grep -qF 'lemonade delete' "$sync"
                grep -qF 'lemonade delete' "$(sed -n 's/^ExecStart=//p' "$pruneUnit"/lemond-models.service)"

                # An empty models list generates no unit at all.
                if grep -qF 'lemond-models.service' <<<"$noneUnits"; then
                  echo "lemond-models.service generated with an empty lemonade.models" >&2
                  exit 1
                fi

                touch $out
              '';

            module-eval-lemonade-allowed-origins = let
              sys =
                (inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.default
                    fastFlowLMUnfreeConfig
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

            module-eval-server-autostart = let
              mkSys = npuExtra:
                (inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.default
                    fastFlowLMUnfreeConfig
                    {
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "/dev/sda1";
                        fsType = "ext4";
                      };
                      # recursiveUpdate, not //: npuExtra overrides a single
                      # nested key like ds4.autoStart without dropping the
                      # enable/user/model siblings beside it.
                      hardware.amd-npu = inputs.nixpkgs.lib.recursiveUpdate {
                        enable = true;
                        enableLemonade = true;
                        lemonade = {
                          user = "testuser";
                          models = ["Qwen3.5-4B-MTP-GGUF"];
                        };
                        ds4 = {
                          enable = true;
                          user = "testuser";
                          model = "/var/lib/ds4/model.gguf";
                        };
                      }
                      npuExtra;
                      users.users.testuser = {
                        isNormalUser = true;
                        extraGroups = ["video" "render"];
                      };
                    }
                  ];
                }).config;
              defaults = mkSys {};
              exclusive = mkSys {
                exclusiveInference = true;
                ds4.autoStart = false;
              };
              lemonadeOff = mkSys {lemonade.autoStart = false;};
            in
              pkgs.runCommand "module-eval-server-autostart" {
                dsDefault = defaults.systemd.units."ds4-server.service".unit;
                dsExclusive = exclusive.systemd.units."ds4-server.service".unit;
                lemondDefault = defaults.systemd.units."lemond.service".unit;
                lemondOff = lemonadeOff.systemd.units."lemond.service".unit;
                modelsOff = lemonadeOff.systemd.units."lemond-models.service".unit;
              } ''
                # Defaults unchanged: both servers still come up at boot and
                # nothing conflicts, so existing hosts see no behaviour change.
                grep -qF 'WantedBy=multi-user.target' "$dsDefault"/ds4-server.service
                grep -qF 'WantedBy=multi-user.target' "$lemondDefault"/lemond.service
                ! grep -qF 'Conflicts=lemond.service' "$dsDefault"/ds4-server.service

                # autoStart=false leaves the unit built but out of every target.
                ! grep -qF 'WantedBy=multi-user.target' "$dsExclusive"/ds4-server.service
                grep -qF 'Conflicts=lemond.service' "$dsExclusive"/ds4-server.service

                # lemond-models has Requires=lemond, so it has to leave the boot
                # target too — otherwise it drags lemond back up behind autoStart.
                ! grep -qF 'WantedBy=multi-user.target' "$lemondOff"/lemond.service
                ! grep -qF 'WantedBy=multi-user.target' "$modelsOff"/lemond-models.service

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
                config.allowUnfreePredicate = allowFastFlowLMUnfree;
              })
            .testers.runNixOSTest {
                name = "lemond-reconcile";
                nodes.machine = {
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
                      # Hold lemond back so the stale config is in place before
                      # its first start; left to boot it would seed a fresh
                      # config, the one path that never exercises reconciliation.
                      autoStart = false;
                    };
                  };
                  users.users.tester.isNormalUser = true;
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
                    fastFlowLMUnfreeConfig
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

            # The openmoss TTS backends are runtime-downloaded foreign ELFs, so
            # they resolve through nix-ld like koko does -- but they need more
            # than koko: without libvulkan (and libomp/hipblas under enableROCm)
            # moss-tts-server exits 127 and lemond reports "openmoss-server
            # failed to start or become ready".
            #
            # The base set must survive too. programs.nix-ld.libraries is a
            # listOf, so definitions concatenate; a definition that replaced the
            # nixpkgs one instead of extending it would strip zlib/openssl/
            # systemd and take koko down with it. Hence the zlib/openssl/systemd
            # assertions below, which fail loudly on that regression.
            module-eval-nix-ld-libraries = let
              mkSys = extra:
                (inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    inputs.self.nixosModules.default
                    fastFlowLMUnfreeConfig
                    {
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "/dev/sda1";
                        fsType = "ext4";
                      };
                      hardware.amd-npu =
                        {
                          enable = true;
                          enableLemonade = true;
                          lemonade.user = "testuser";
                        }
                        // extra;
                      users.users.testuser = {
                        isNormalUser = true;
                        extraGroups = ["video" "render"];
                      };
                    }
                  ];
                }).config.programs.nix-ld.libraries;
              names = extra:
                builtins.concatStringsSep " "
                (map (p: p.pname or p.name) (mkSys extra));
              plain = names {};
              withRocm = names {enableROCm = true;};
              lemonadeOff = names {enableLemonade = false;};
            in
              pkgs.runCommand "module-eval-nix-ld-libraries" {
                inherit plain withRocm lemonadeOff;
              } ''
                for lib in vulkan-loader zlib openssl systemd; do
                  echo "$plain" | grep -qw "$lib"                     || { echo "$lib missing from the lemonade nix-ld set"; exit 1; }
                done
                for lib in openmp clr rocblas hipblas; do
                  echo "$withRocm" | grep -qw "$lib"                     || { echo "$lib missing under enableROCm"; exit 1; }
                  ! echo "$plain" | grep -qw "$lib"                     || { echo "$lib pulled in without enableROCm"; exit 1; }
                done
                ! echo "$lemonadeOff" | grep -qw vulkan-loader                   || { echo "vulkan-loader added on a host with lemonade off"; exit 1; }
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
              ! grep -qE 'HF_HOME|LEMONADE_CACHE_DIR' "$unit" \
                || { echo "cache env set on a host that never set cacheDir"; exit 1; }
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
              grep -q 'ConditionPathExists=/var/lib/ds4/DeepSeek-V4-Flash.gguf' "$unit" \
                || { echo "missing ConditionPathExists on the model"; exit 1; }
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
                      fastFlowLMUnfreeConfig
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
