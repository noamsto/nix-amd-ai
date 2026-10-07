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
    # MIT source, so nixpkgs marks the package unfree. OpenFlowLM-Next ships
    # FastFlowLM's closed kernels too (#158). Allow exactly those packages
    # where this repo instantiates nixpkgs.
    allowFastFlowLMUnfree = pkg:
      builtins.elem (inputs.nixpkgs.lib.getName pkg) ["fastflowlm" "openflowlm"];

    # This repo's own NixOS eval checks and unit renders opt in to fastflowlm's
    # unfree licence the same way a consumer must. #158
    fastFlowLMUnfreeConfig = {
      nixpkgs.config.allowUnfreePredicate = allowFastFlowLMUnfree;
    };

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

    # These backends run against the pinned nixpkgs, which never matches the
    # host's (the README forbids `.follows`). The Vulkan loader otherwise takes
    # the host's driver and implicit layers from /run/opengl-driver, and once the
    # host's glibc is newer than the pin they fail to load and llama.cpp silently
    # runs on CPU (#215). So point the loader at this nixpkgs' own RADV and skip
    # implicit layers; `--set-default` leaves an operator override in charge. A
    # symlinkJoin, so the backends themselves aren't rebuilt. The unwrapped
    # package is `.unwrapped`, for `.override`/`.overrideAttrs`.
    withOwnVulkanDriver = pkgs: pkg:
      pkgs.symlinkJoin {
        inherit (pkg) pname version meta;
        passthru =
          pkg.passthru
          // {
            unwrapped = pkg;
            inherit (pkg) src;
          }
          // pkgs.lib.optionalAttrs (pkg ? dev) {inherit (pkg) dev;};
        paths = [pkg];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          for f in $out/bin/*; do
            case $f in *.so) continue ;; esac
            wrapProgram "$f" \
              --set-default VK_DRIVER_FILES ${pkgs.mesa}/share/vulkan/icd.d/radeon_icd.${pkgs.stdenv.hostPlatform.parsed.cpu.name}.json \
              --set-default VK_LOADER_LAYERS_DISABLE '~implicit~'
          done
        '';
      };

    # Pin llama.cpp to a specific upstream tag instead of nixpkgs' own version,
    # so we can pick up a fix (or a newer ggml/CUDA-backend feature) ahead of
    # nixpkgs' llama-cpp update. `__intentionallyOverridingVersion` silences
    # nixpkgs' "you changed version without changing src" warning -- we're
    # changing both together, deliberately. `pinBuildNumber`/`pinCommit` must
    # move together with `pinTag` on the next bump -- there is no single
    # source of truth to derive them from (fetchFromGitHub's `src.rev` here is
    # just the tag we passed in, not the resolved commit).
    llamaCppPin = pkgs: pkg: let
      pinTag = "b11382";
      pinBuildNumber = "11382";
      pinCommit = "11fe021";
    in
      pkg.overrideAttrs (old: {
        version = pinBuildNumber;
        __intentionallyOverridingVersion = true;
        src = pkgs.fetchFromGitHub {
          owner = "ggml-org";
          repo = "llama.cpp";
          tag = pinTag;
          hash = "sha256-km1Ze5KyHX7BCRbPd/Goo3j0PnNX0lFkgoqJaO3Wp1s=";
        };
        # nixpkgs bakes its own pin's build number/commit into `--version` and
        # `/props` as plain -D flags (the release tarball carries no .git for
        # llama.cpp to read them from); replace them so ours doesn't lie. The
        # asserts catch a future nixpkgs reformatting these flags silently
        # leaving the stale build number/commit in place instead of erroring.
        cmakeFlags = assert pkgs.lib.any (pkgs.lib.hasPrefix "-DLLAMA_BUILD_NUMBER:STRING=") old.cmakeFlags;
          assert pkgs.lib.any (pkgs.lib.hasPrefix "-DLLAMA_BUILD_COMMIT:STRING=") old.cmakeFlags;
            builtins.map (
              flag:
                if pkgs.lib.hasPrefix "-DLLAMA_BUILD_NUMBER:STRING=" flag
                then "-DLLAMA_BUILD_NUMBER:STRING=${pinBuildNumber}"
                else if pkgs.lib.hasPrefix "-DLLAMA_BUILD_COMMIT:STRING=" flag
                then "-DLLAMA_BUILD_COMMIT:STRING=${pinCommit}"
                else flag
            )
            old.cmakeFlags;
      });

    # Aristo94/GSQHalo.cpp, a llama.cpp fork for Strix Halo, as a source swap
    # on a llama-cpp-rocm build: same ROCm toolchain, `rocmGpuTargets` and
    # `.override` surface, so the module can re-target it like the stock one.
    # Opt-in via `hardware.amd-npu.llamaCppRocmPackage`.
    llamaCppRocmGsqhalo = pkgs: pkg: let
      rev = "5fc881b114c1ea130f5df6a30a98be2f8d397de6";
      shortRev = builtins.substring 0 7 rev;
    in
      pkg.overrideAttrs (old: {
        version = "GSQHalo.cpp-${shortRev}";
        __intentionallyOverridingVersion = true;
        src = pkgs.fetchFromGitHub {
          owner = "Aristo94";
          repo = "GSQHalo.cpp";
          inherit rev;
          hash = "sha256-f3aoiICLmkSAY2wqfc1g3YznfhtRfeMOCvkMx561n1k=";
        };
        # The fork has no upstream build number; `--version` reports the rev.
        cmakeFlags =
          builtins.map (
            flag:
              if pkgs.lib.hasPrefix "-DLLAMA_BUILD_NUMBER:STRING=" flag
              then "-DLLAMA_BUILD_NUMBER:STRING=0"
              else if pkgs.lib.hasPrefix "-DLLAMA_BUILD_COMMIT:STRING=" flag
              then "-DLLAMA_BUILD_COMMIT:STRING=${shortRev}"
              else flag
          )
          old.cmakeFlags;
      });

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
            llvm-aie = pinned.callPackage ./pkgs/llvm-aie {};
            mlir-aie = pinned.callPackage ./pkgs/mlir-aie {inherit llvm-aie;};
            openflowlm = pinned.callPackage ./pkgs/openflowlm {inherit xrt mlir-aie llvm-aie;};
            llama-cpp-base = llamaCppPin pinned pinned.llama-cpp;
            llama-cpp = llamaCppNoWebUi pinned llama-cpp-base;
            llama-cpp-vulkan = withOwnVulkanDriver pinned (llamaCppNoWebUi pinned (llama-cpp-base.override {vulkanSupport = true;}));
            llama-cpp-rocm = llamaCppNoWebUi pinned (pinned.llama-cpp-rocm.override {
              llama-cpp = llama-cpp-base.override {inherit rocmGpuTargets;};
            });
            llama-cpp-rocm-gsqhalo = llamaCppRocmGsqhalo pinned llama-cpp-rocm;
            whisper-cpp-vulkan = withOwnVulkanDriver pinned (pinned.whisper-cpp.override {vulkanSupport = true;});
            stable-diffusion-cpp-rocm = pinned.stable-diffusion-cpp.override {
              rocmSupport = true;
              inherit rocmGpuTargets;
            };
            stable-diffusion-cpp-vulkan = withOwnVulkanDriver pinned (pinned.stable-diffusion-cpp.override {vulkanSupport = true;});
          in {
            inherit xrt fastflowlm llama-cpp llama-cpp-vulkan llama-cpp-rocm llama-cpp-rocm-gsqhalo libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
            inherit mlir-aie llvm-aie openflowlm;
            ds4 = pinned.callPackage ./pkgs/ds4 {};
            strata = pinned.callPackage ./pkgs/strata {};
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

        # Go correctness gate for the repo's one Go module (pkgs/benchmark-go):
        # golangci-lint + nilaway + `go test -race`, run by `nix flake check`.
        # Same vendorHash as the `benchmark` package, so deps are fetched once.
        benchmarkGate = pkgs.buildGoModule {
          pname = "benchmark-go-gate";
          version = "0.1.0";
          src = ./pkgs/benchmark-go;
          vendorHash = "sha256-CBmwAVno6OqFdKcUk66MuP5+nI4Z3aQI4kcmT+YbqYY=";
          subPackages = ["cmd/benchmark"];
          nativeCheckInputs = with pkgs; [golangci-lint nilaway];
          checkPhase = ''
            runHook preCheck

            # -race needs cgo; the stdenv provides the C toolchain.
            export CGO_ENABLED=1
            export GOLANGCI_LINT_CACHE=$TMPDIR/golangci-lint-cache

            echo "==> golangci-lint"
            golangci-lint run ./...

            echo "==> nilaway"
            nilaway -include-pkgs=github.com/noamsto/nix-amd-ai/pkgs/benchmark-go ./...

            echo "==> go test -race"
            # Drop -trimpath for the same reason buildGoModule's own
            # checkPhase does: tests may reference on-disk assets.
            export GOFLAGS=''${GOFLAGS//-trimpath/}
            # -short skips TestDetect_Smoke, which asserts on the real host's
            # AMD GPU (absent in the build sandbox); the test documents this.
            go test -race -short ./...

            runHook postCheck
          '';
        };

        # AMD NPU/XRT/ROCm/Vulkan stack — Linux + AMD-hardware only.
        linuxPackages = let
          xrt = pkgs.callPackage ./pkgs/xrt {};
          fastflowlm = pkgs.callPackage ./pkgs/fastflowlm {inherit xrt;};
          llvm-aie = pkgs.callPackage ./pkgs/llvm-aie {};
          mlir-aie = pkgs.callPackage ./pkgs/mlir-aie {inherit llvm-aie;};
          openflowlm = pkgs.callPackage ./pkgs/openflowlm {inherit xrt mlir-aie llvm-aie;};
          llama-cpp-base = llamaCppPin pkgs pkgs.llama-cpp;
          llama-cpp = llamaCppNoWebUi pkgs llama-cpp-base;
          llama-cpp-vulkan = withOwnVulkanDriver pkgs (llamaCppNoWebUi pkgs (llama-cpp-base.override {vulkanSupport = true;}));
          llama-cpp-rocm = llamaCppNoWebUi pkgs (pkgs.llama-cpp-rocm.override {
            llama-cpp = llama-cpp-base.override {inherit rocmGpuTargets;};
          });
          llama-cpp-rocm-gsqhalo = llamaCppRocmGsqhalo pkgs llama-cpp-rocm;
          whisper-cpp-vulkan = withOwnVulkanDriver pkgs (pkgs.whisper-cpp.override {vulkanSupport = true;});
          stable-diffusion-cpp-rocm = pkgs.stable-diffusion-cpp.override {
            rocmSupport = true;
            inherit rocmGpuTargets;
          };
          stable-diffusion-cpp-vulkan = withOwnVulkanDriver pkgs (pkgs.stable-diffusion-cpp.override {vulkanSupport = true;});
          libwebsockets = libwebsocketsOverride pkgs;
          lemonade = pkgs.callPackage ./pkgs/lemonade {
            inherit fastflowlm llama-cpp-vulkan llama-cpp-rocm libwebsockets;
            inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
            whisper-cpp = pkgs.whisper-cpp;
            stable-diffusion-cpp = pkgs.stable-diffusion-cpp;
          };
        in {
          inherit xrt fastflowlm llama-cpp llama-cpp-vulkan llama-cpp-rocm llama-cpp-rocm-gsqhalo libwebsockets lemonade;
          inherit whisper-cpp-vulkan stable-diffusion-cpp-rocm stable-diffusion-cpp-vulkan;
          inherit mlir-aie llvm-aie openflowlm;
          ds4 = pkgs.callPackage ./pkgs/ds4 {};
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          # What `hardware.amd-npu.lemonade.desktopApp.enable = false` selects;
          # built here so headless hosts substitute it rather than compile it.
          lemonade-headless = lemonade.override {withDesktopApp = false;};
          gaia = pkgs.callPackage ./pkgs/gaia {};
          vllm-rocm = pkgs.callPackage ./pkgs/vllm-rocm {};
          # Opt-in through `hardware.amd-npu.strata`; not built by CI.
          strata = pkgs.callPackage ./pkgs/strata {};
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

        # Option-on Strata host for the module-eval-strata check. `extra` is a
        # module-system fragment merged into hardware.amd-npu.strata.
        strataEvalHost = extra:
          inputs.nixpkgs.lib.nixosSystem {
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
                  enableROCm = true;
                  gpuTarget = "gfx1151";
                  lemonade.user = "testuser";
                  strata = {
                    enable = true;
                    model = "/var/lib/models/strata/model-00001-of-00003.gguf";
                    pack = "/var/lib/models/strata/pack";
                    mtp = "/var/lib/models/strata/mtp/rt";
                    vision.mmproj = "/var/lib/models/strata/mmproj.gguf";
                  };
                };
                users.users.testuser = {
                  isNormalUser = true;
                  extraGroups = ["video" "render"];
                };
              }
              {hardware.amd-npu.strata = extra;}
            ];
          };

        # Context-free, so the check never builds pkgs.strata or the host.
        strataEvalJson = host:
          builtins.unsafeDiscardStringContext
          (builtins.toJSON host.config.hardware.amd-npu.strata.runConfig);
        strataRejected = extra:
          if (builtins.tryEval (strataEvalHost extra).config.system.build.toplevel.drvPath).success
          then ""
          else "1";

        strataFakeServer = pkgs.writeShellScript "fake-strata-server" ''
          set -eu
          trap "" TERM
          ${pkgs.jq}/bin/jq -cn '$ARGS.positional' --args -- "$@" > "$SEEN_DIR/argv.json"
          while [ "$#" -gt 0 ]; do
            if [ "$1" = --config ]; then cp "$2" "$SEEN_DIR/config.json"; fi
            shift
          done
          if [ -n "''${LD_LIBRARY_PATH+x}" ]; then echo set; else echo unset; fi > "$SEEN_DIR/ld"
          ${pkgs.bash}/bin/bash -c 'trap "" TERM; exec ${pkgs.coreutils}/bin/sleep 987654' &
          echo "$!" > "$SEEN_DIR/child.pid"
          wait
        '';
        strataTestShim =
          pkgs.callPackage ./pkgs/strata/lemond-shim.nix {} {
            server = "${strataFakeServer}";
            settings = {
              model = "/nonexistent/strata-test/model.gguf";
              context = 131072;
              config = {
                exe = "x";
                args = ["--expert-cache" "20000" "--mmap-experts"];
              };
            };
          };
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
            benchmark-go-gate = benchmarkGate;
            # Smoke checks for the IRON toolchain packages: prove the CLI tools
            # run, the Python module imports with the package on PYTHONPATH, and
            # the Peano clang still carries the AIE targets. No NPU needed.
            mlir-aie-smoke =
              pkgs.runCommand "mlir-aie-smoke" {
                nativeBuildInputs = [linuxPackages.mlir-aie.passthru.python];
                MLIR_AIE = linuxPackages.mlir-aie;
              } ''
                "$MLIR_AIE/bin/aie-opt" --version | grep -q 'aie-opt'
                "$MLIR_AIE/bin/aiecc" --version | grep -q 'aiecc'
                export PYTHONPATH="$MLIR_AIE/lib/python3.12/site-packages"
                python3.12 -c 'import aie; assert aie.__version__ == "1.4.2", aie.__version__'
                # IRON is the package's purpose; it needs the passthru.python runtime deps.
                python3.12 -c 'import aie.iron'
                # The peano symlink makes the sibling llvm-aie findable.
                python3.12 -c 'import os; assert os.path.isdir(os.path.join(os.environ["MLIR_AIE"],"lib/python3.12/peano/bin")), "peano symlink missing"'
                # aie/utils/config.py finds aiecc via realpath(<site-packages>/aie/utils/../../..);
                # assert the repackaged layout still satisfies that.
                python3.12 -c 'import os; p=os.path.join(os.environ["MLIR_AIE"],"lib/python3.12/site-packages/aie/utils"); root=os.path.realpath(os.path.join(p,"..","..","..")); assert os.path.isfile(os.path.join(root,"bin","aiecc")), root'
                touch $out
              '';

            llvm-aie-smoke =
              pkgs.runCommand "llvm-aie-smoke" {
                LLVM_AIE = linuxPackages.llvm-aie;
              } ''
                "$LLVM_AIE/bin/clang" --version | grep -q 'llvm-aie'
                # --version prints the host triple; the AIE targets are what prove this
                # is the Peano backend rather than a stock clang.
                "$LLVM_AIE/bin/clang" -print-targets | grep -q 'aie2'
                "$LLVM_AIE/bin/clang" --target=aie2-none-unknown-elf -print-target-triple | grep -qx 'aie2-none-unknown-elf'
                touch $out
              '';

            # Device-free: the kernel sets shipped, and a size-mismatched model
            # file keeps its warning off the stdout lemonade parses as JSON.
            openflowlm-smoke =
              pkgs.runCommand "openflowlm-smoke" {
                nativeBuildInputs = [pkgs.jq];
                OFLM = linuxPackages.openflowlm;
              } ''
                export HOME=$TMPDIR/home # oflm creates ~/.config/oflm on start
                mkdir -p "$HOME"

                "$OFLM/bin/oflm" version --json | jq -e '.version == "0.1.0"'

                store=$TMPDIR/store
                mkdir -p "$store/models/Llama-3.2-1B-NPU2"
                echo x > "$store/models/Llama-3.2-1B-NPU2/config.json"
                OFLM_MODEL_PATH=$store "$OFLM/bin/oflm" list --filter installed --quiet --json 2>/dev/null | jq -e '.models | type == "array"'
                OFLM_MODEL_PATH=$store "$OFLM/bin/oflm" list --json 2>/dev/null | jq -e '.models | length > 0'

                test "$(find "$OFLM/share/oflm/xclbins" -path '*/open_kernels/manifest.json' | wc -l)" -eq 11
                test "$(find "$OFLM/share/oflm/xclbins" -path '*/gemm_rtp/design.json' | wc -l)" -eq 5
                test -d "$OFLM/share/oflm/xclbins/Llama-3.2-1B-NPU2"

                touch $out
              '';

            # Cheap (no kernel build): exercises the same src-vs-list plan the
            # kernels join executes, in both drift directions, with a doctored
            # list. Drift is recoverable, so this only proves the plan reports
            # it instead of failing or silently dropping a set.
            openflowlm-kernel-sets-drift =
              pkgs.runCommand "openflowlm-kernel-sets-drift" {
                nativeBuildInputs = [pkgs.jq];
                SRC = linuxPackages.openflowlm.passthru.src;
                PLAN = ./pkgs/openflowlm/kernel-sets-plan.sh;
                SETS = ./pkgs/openflowlm/kernel-sets.json;
              } ''
                run() { bash "$PLAN" "$SRC" "$1"; }

                # The committed list matches the pinned source: nothing to build
                # inline and nothing to skip.
                run "$SETS" > plan.txt
                if grep -qE '^(BUILD|SKIP)-' plan.txt; then
                  echo "kernel-sets.json is out of date with the pinned source:" >&2
                  cat plan.txt >&2
                  exit 1
                fi

                # src has a set the list lacks; the list has one src lacks.
                jq '.llmSpecs -= ["gemma3-4b"] | .bertFamilies += ["Phantom-Family"]' "$SETS" > d1.json
                run d1.json > plan1.txt
                grep -qx 'BUILD-LLM gemma3-4b' plan1.txt
                grep -qx 'SKIP-BERT Phantom-Family' plan1.txt

                # The other direction: the list names a set src lacks, and misses
                # one src has.
                jq '.llmSpecs += ["Phantom-Llm"] | (.bertFamilies -= ["BERT-h384-bf16"])' "$SETS" > d2.json
                run d2.json > plan2.txt
                grep -qx 'SKIP-LLM Phantom-Llm' plan2.txt
                grep -qx 'BUILD-BERT BERT-h384-bf16' plan2.txt

                touch $out
              '';

            # Cheap (no kernel build): runs the join's plan executor with stub
            # sets. gemma3-12b and gemma3-4b both export into Gemma3-4B-NPU2;
            # with gemma3-12b and a later set built inline, the serial order
            # still leaves gemma3-4b's files in that directory.
            openflowlm-kernel-sets-join =
              pkgs.runCommand "openflowlm-kernel-sets-join" {
                nativeBuildInputs = [pkgs.jq];
                SRC = linuxPackages.openflowlm.passthru.src;
                PLAN = ./pkgs/openflowlm/kernel-sets-plan.sh;
                JOIN = ./pkgs/openflowlm/kernel-sets-join.sh;
                SETS = ./pkgs/openflowlm/kernel-sets.json;
              } ''
                jq '.llmSpecs -= ["gemma3-12b", "qwen36-35b-a3b"]' "$SETS" > d.json
                bash "$PLAN" "$SRC" d.json > plan.txt
                grep -qx 'BUILD-LLM gemma3-12b' plan.txt
                grep -qx 'BUILD-LLM qwen36-35b-a3b' plan.txt

                # Stub sets write a marker naming the set, into the shared
                # directory when the set has one.
                dir() { case "$1" in gemma3-12b | gemma3-4b) echo Gemma3-4B-NPU2 ;; *) echo "$1" ;; esac; }
                stage() { mkdir -p "src/xclbins/$(dir "$1")"; echo "$1" > "src/xclbins/$(dir "$1")/marker"; }
                copy() { chmod -R u+w "$out_x"; mkdir -p "$out_x/$(dir "$1")"; echo "$1" > "$out_x/$(dir "$1")/marker"; }
                copy_llm() { copy "$1"; }
                copy_bert() { copy "$1"; }
                build_LLM() { stage "$1"; }
                build_BERT() { stage "$1"; }

                out_x=$PWD/out/xclbins
                mkdir -p "$out_x" src/xclbins
                source "$JOIN"
                execute_plan plan.txt "$out_x" 2>/dev/null

                test "$(cat "$out_x/Gemma3-4B-NPU2/marker")" = gemma3-4b
                test "$(cat "$out_x/qwen36-35b-a3b/marker")" = qwen36-35b-a3b

                touch $out
              '';

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

            module-eval-rocm-gsqhalo =
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
                      llamaCppRocmPackage = inputs.self.packages.${system}.llama-cpp-rocm-gsqhalo;
                      lemonade.user = "testuser";
                    };
                    users.users.testuser = {
                      isNormalUser = true;
                      extraGroups = ["video" "render"];
                    };
                  }
                ];
              }).config.system.build.etc;

            module-eval-strata = pkgs.runCommand "module-eval-strata" {
              nativeBuildInputs = [pkgs.jq];
              CONFIG = strataEvalJson (strataEvalHost {});
              FAST_CONFIG = strataEvalJson (strataEvalHost {profile = "fast";});
              TOPLEVEL = builtins.unsafeDiscardStringContext (strataEvalHost {}).config.system.build.toplevel.drvPath;
              AUTO_REJECTED = strataRejected {expertCache = "auto";};
              EXTRA_REJECTED = strataRejected {extraArgs = ["--expert-cache" "auto"];};
              NO_MMPROJ_REJECTED = strataRejected {vision.mmproj = null;};
            } ''
              check() {
                printf '%s' "$1" | jq -e "$2" >/dev/null \
                  || { echo "FAILED: $2"; exit 1; }
              }
              check "$CONFIG" '.config.args | index("--mmap-experts") != null'
              check "$CONFIG" '.config.args | index("--expert-cache") as $i | .[$i + 1] == "20000" and (.[$i + 1] | test("^[0-9]+$"))'
              check "$CONFIG" '.config.args | index("--vision") != null'
              check "$CONFIG" '.config.vision.mmproj == "/var/lib/models/strata/mmproj.gguf"'
              check "$CONFIG" '.context == 131072'
              check "$FAST_CONFIG" '.config.args | index("--mtp-q4") != null'
              check "$FAST_CONFIG" '.config.env.STRATA_PF_FUSED == "1"'
              [ "$AUTO_REJECTED" = 1 ] || { echo "expertCache = auto was accepted"; exit 1; }
              [ "$EXTRA_REJECTED" = 1 ] || { echo "extraArgs --expert-cache was accepted"; exit 1; }
              [ "$NO_MMPROJ_REJECTED" = 1 ] || { echo "vision without mmproj was accepted"; exit 1; }
              [ -n "$TOPLEVEL" ] || { echo "option-on host did not evaluate"; exit 1; }
              touch $out
            '';

            strata-shim = pkgs.runCommand "strata-shim" {
              nativeBuildInputs = [pkgs.jq pkgs.procps pkgs.coreutils];
            } ''
              shim=${strataTestShim}/bin/strata-lemond-shim
              model=/nonexistent/strata-test/model.gguf
              fail() { echo "FAILED: $*"; exit 1; }

              wait_for() {
                for _ in $(seq 100); do
                  [ -e "$1" ] && return 0
                  sleep 0.1
                done
                return 1
              }

              # Anchored on the whole command line so the test shell's own does not match.
              marker_alive() { pgrep -f '/sleep 987654$' >/dev/null; }

              new_seen() {
                SEEN_DIR="$TMPDIR/seen-$1"
                export SEEN_DIR
                mkdir -p "$SEEN_DIR"
              }

              # Model mismatch is refused before the server starts.
              new_seen mismatch
              rc=0
              "$shim" -m /nonexistent/other.gguf --host 127.0.0.1 --port 1 || rc=$?
              [ "$rc" = 2 ] || fail "model mismatch exited $rc, wanted 2"
              [ ! -e "$SEEN_DIR/argv.json" ] || fail "server started on model mismatch"

              # A caller cannot override the module's expert cache.
              new_seen cache
              rc=0
              "$shim" -m "$model" --host 127.0.0.1 --port 1 --expert-cache 5 || rc=$?
              [ "$rc" = 2 ] || fail "--expert-cache exited $rc, wanted 2"
              [ ! -e "$SEEN_DIR/argv.json" ] || fail "server started with --expert-cache"

              # Happy path, then SIGTERM.
              new_seen happy
              LD_LIBRARY_PATH=/x "$shim" -m "$model" --host 127.0.0.1 --port 1 \
                -c 4096 --ssd-streaming --foo &
              shim_pid=$!
              wait_for "$SEEN_DIR/child.pid" || fail "server never spawned its child"
              child=$(cat "$SEEN_DIR/child.pid")
              for _ in $(seq 50); do marker_alive && break; sleep 0.1; done
              marker_alive || fail "marker process is not running"

              jq -e '.args | .[-3:] == ["--max-context", "4096", "--foo"]' \
                "$SEEN_DIR/config.json" >/dev/null || fail "config args tail"
              jq -e '.args | index("--ssd-streaming") == null' \
                "$SEEN_DIR/config.json" >/dev/null || fail "--ssd-streaming leaked into config"
              jq -e '.args | index("--expert-cache") as $i | .[$i + 1] == "20000"' \
                "$SEEN_DIR/config.json" >/dev/null || fail "expert cache changed"
              for pair in "--engine strata" "--host 127.0.0.1" "--port 1"; do
                # shellcheck disable=SC2086
                set -- $pair
                jq -e --arg k "$1" --arg v "$2" 'index($k) as $i | .[$i + 1] == $v' \
                  "$SEEN_DIR/argv.json" >/dev/null || fail "server argv lacks $pair"
              done
              [ "$(cat "$SEEN_DIR/ld")" = unset ] || fail "LD_LIBRARY_PATH reached the server"

              start=$(date +%s%N)
              kill -TERM "$shim_pid"
              rc=0
              wait "$shim_pid" || rc=$?
              elapsed_ms=$((($(date +%s%N) - start) / 1000000))
              echo "shim stopped in $elapsed_ms ms (exit $rc)"
              [ "$rc" = 0 ] || fail "shim exited $rc after SIGTERM"
              [ "$elapsed_ms" -lt 5000 ] || fail "shim took $elapsed_ms ms to stop"
              ! kill -0 "$child" 2>/dev/null || fail "child $child survived the shim"
              ! marker_alive || fail "marker process survived the shim"

              # Without -c the configured context applies.
              new_seen ctx
              "$shim" -m "$model" --host 127.0.0.1 --port 1 &
              shim_pid=$!
              wait_for "$SEEN_DIR/child.pid" || fail "server never spawned its child"
              jq -e '.args | .[-2:] == ["--max-context", "131072"]' \
                "$SEEN_DIR/config.json" >/dev/null || fail "default context"
              kill -TERM "$shim_pid"
              wait "$shim_pid" || true
              ! marker_alive || fail "marker process survived the second shim"

              touch $out
            '';

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

            # fastflowlm.package feeds both the wrapped system package and
            # lemonade's flm.npu_bin (via the stable /etc symlink). Eval-only: the
            # asserted strings are store paths whose contexts are discarded so the
            # check never builds fastflowlm or the XRT closure.
            module-eval-fastflowlm-package = let
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
                    extra
                  ];
                }).config;
              stub = pkgs.writeShellScriptBin "oflm" "exit 0" // {meta.mainProgram = "oflm";};
              flmNpu = c: builtins.unsafeDiscardStringContext c.environment.etc."lemonade/backends/flm-npu".source;
              defaultsOf = c: c.systemd.services.lemond.environment.LEMONADE_DEFAULTS_PATH;
              def = mkSys {};
              swapped = mkSys {hardware.amd-npu.fastflowlm.package = stub;};
              real = mkSys {hardware.amd-npu.fastflowlm.package = linuxPackages.openflowlm;};
              off = mkSys {hardware.amd-npu.enableFastFlowLM = false;};
            in
              pkgs.runCommand "module-eval-fastflowlm-package" {
                nativeBuildInputs = [pkgs.jq];
                defaultBin = flmNpu def;
                swappedBin = flmNpu swapped;
                realBin = flmNpu real;
                defaultDefaults = defaultsOf def;
                swappedDefaults = defaultsOf swapped;
                realDefaults = defaultsOf real;
                offDefaults = defaultsOf off;
                offHasLink = builtins.toJSON (off.environment.etc ? "lemonade/backends/flm-npu");
                realLemondNoUpdate = real.systemd.services.lemond.environment.OFLM_DISABLE_UPDATE_CHECK or "";
                realSessionNoUpdate = real.environment.sessionVariables.OFLM_DISABLE_UPDATE_CHECK or "";
              } ''
                case "$defaultBin" in *-fastflowlm-wrapped/bin/flm) ;; *) echo "default: $defaultBin" >&2; exit 1 ;; esac
                case "$swappedBin" in *-fastflowlm-wrapped/bin/oflm) ;; *) echo "swapped: $swappedBin" >&2; exit 1 ;; esac
                case "$realBin" in *-fastflowlm-wrapped/bin/oflm) ;; *) echo "real: $realBin" >&2; exit 1 ;; esac
                for f in "$defaultDefaults" "$swappedDefaults" "$realDefaults"; do
                  jq -e '.flm.npu_bin == "/etc/lemonade/backends/flm-npu"' "$f" >/dev/null
                  jq -e '.flm.prefer_system == true' "$f" >/dev/null
                done
                test "$realLemondNoUpdate" = 1 || { echo "real: lemond service missing OFLM_DISABLE_UPDATE_CHECK" >&2; exit 1; }
                test "$realSessionNoUpdate" = 1 || { echo "real: sessionVariables missing OFLM_DISABLE_UPDATE_CHECK" >&2; exit 1; }
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

            # recipeOptions must reach recipe_options.json on every lemond start,
            # per-key so a UI-set ctx_size/args for the same model survives, and
            # must leave the file alone entirely when the option is unset.
            module-eval-lemonade-recipe-options = let
              mkSys = recipeOptions:
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
                          inherit recipeOptions;
                        };
                      };
                      users.users.testuser = {
                        isNormalUser = true;
                        extraGroups = ["video" "render"];
                      };
                    }
                  ];
                }).config;
              configured = mkSys {
                "builtin.Gemma4-2B-FLM" = {pinned = true;};
                "builtin.Qwen3.6-30B-GGUF" = {evict_idle_timeout = 900;};
              };
              plain = mkSys {};
            in
              pkgs.runCommand "module-eval-lemonade-recipe-options" {
                nativeBuildInputs = [pkgs.jq];
                configuredUnit = configured.systemd.units."lemond.service".unit;
                plainUnit = plain.systemd.units."lemond.service".unit;
              } ''
                # Grep the script file the ExecStartPre path points at, not the
                # path string (same idiom as the other module-eval checks).
                configuredScript=$(sed -n 's/^ExecStartPre=//p' "$configuredUnit"/lemond.service)
                plainScript=$(sed -n 's/^ExecStartPre=//p' "$plainUnit"/lemond.service)

                # Option unset: the reconcile hook must not touch recipe_options.json
                # at all -- not even create it.
                if grep -qF 'recipe_options.json' "$plainScript"; then
                  echo "recipe_options step emitted with recipeOptions unset" >&2
                  exit 1
                fi
                export HOME=$TMPDIR/home-plain
                unset XDG_CONFIG_HOME
                "$plainScript"
                [ ! -e "$HOME/.config/lemonade/recipe_options.json" ] \
                  || { echo "unset recipeOptions still created recipe_options.json" >&2; exit 1; }

                # Option set: the step is present.
                grep -qF 'recipe_options.json' "$configuredScript" \
                  || { echo "missing recipe_options step" >&2; exit 1; }

                # Exercise the generated script directly against temp files.
                export HOME=$TMPDIR/home
                unset XDG_CONFIG_HOME
                mkdir -p "$HOME/.config/lemonade"
                ro=$HOME/.config/lemonade/recipe_options.json

                # Missing file -> created with exactly the module's entries.
                # Exact-object assertions also pin the null pruning: an unset
                # typed key serialized as null would shadow a lower layer.
                "$configuredScript"
                jq -e '."builtin.Gemma4-2B-FLM" == {"pinned": true}' "$ro" >/dev/null
                jq -e '."builtin.Qwen3.6-30B-GGUF" == {"evict_idle_timeout": 900}' "$ro" >/dev/null

                # A UI-set ctx_size on the same model survives alongside the
                # module's pinned, and a model the module never names is left
                # alone. Mode is preserved.
                echo '{"builtin.Gemma4-2B-FLM":{"ctx_size":8192},"user.Other":{"ctx_size":4096}}' >"$ro"
                chmod 600 "$ro"
                "$configuredScript"
                jq -e '."builtin.Gemma4-2B-FLM" == {"ctx_size": 8192, "pinned": true}' "$ro" >/dev/null
                jq -e '."user.Other" == {"ctx_size": 4096}' "$ro" >/dev/null
                [ "$(stat -c %a "$ro")" = 600 ]

                # An unreadable file is left untouched. The nix build sandbox is
                # unprivileged, so chmod 000 denies this reader.
                cp "$ro" "$ro.before"
                chmod 000 "$ro"
                "$configuredScript" 2>/dev/null || true
                chmod 600 "$ro"
                cmp -s "$ro" "$ro.before" \
                  || { echo "unreadable recipe_options.json was modified" >&2; exit 1; }

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

            # An allowlist, not a blacklist: lemond's LD_LIBRARY_PATH is exactly
            # xrt-combined/lib or unset, so no host library dir can return (#215).
            module-eval-lemond-ld-library-path = let
              mkEnv = extra:
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
                }).config.systemd.services.lemond.environment;
              withNpu = mkEnv {
                enableNPU = true;
                enableROCm = true;
                enableVulkan = true;
                enableFastFlowLM = true;
              };
              noNpu = mkEnv {
                enableNPU = false;
                enableFastFlowLM = false;
                enableROCm = true;
                enableVulkan = true;
              };
              actual = builtins.unsafeDiscardStringContext (withNpu.LD_LIBRARY_PATH or "<unset>");
              expected = builtins.unsafeDiscardStringContext (withNpu.XILINX_XRT + "/lib");
              noNpuLd = builtins.unsafeDiscardStringContext (noNpu.LD_LIBRARY_PATH or "<unset>");
            in
              pkgs.runCommand "module-eval-lemond-ld-library-path" {
                inherit actual expected noNpuLd;
              } ''
                [ "$actual" = "$expected" ] \
                  || { echo "lemond LD_LIBRARY_PATH is '$actual', expected '$expected'"; exit 1; }
                [ "$noNpuLd" = "<unset>" ] \
                  || { echo "lemond LD_LIBRARY_PATH is '$noNpuLd' without the NPU, expected unset"; exit 1; }
                touch $out
              '';

            # Guards withOwnVulkanDriver on both the perSystem and overlay builds.
            # It cannot reproduce the host glibc split itself: CI's nixpkgs is the pin.
            vulkan-backends-own-driver = let
              overlaid = import inputs.nixpkgs {
                inherit system;
                overlays = [inputs.self.overlays.default];
                config.allowUnfreePredicate = allowFastFlowLMUnfree;
              };
              llamas = [linuxPackages.llama-cpp-vulkan overlaid.llama-cpp-vulkan];
              backends =
                llamas
                ++ [
                  linuxPackages.whisper-cpp-vulkan
                  linuxPackages.stable-diffusion-cpp-vulkan
                  overlaid.whisper-cpp-vulkan
                  overlaid.stable-diffusion-cpp-vulkan
                ];
            in
              pkgs.runCommand "vulkan-backends-own-driver" {
                ICD = "${pkgs.mesa}/share/vulkan/icd.d/radeon_icd.x86_64.json";
                RADV = "${pkgs.mesa}/lib/libvulkan_radeon.so";
              } ''
                for pkg in ${builtins.concatStringsSep " " backends}; do
                  for f in "$pkg"/bin/*; do
                    case "$f" in *.so) continue ;; esac
                    grep -qF "$ICD" "$f" \
                      || { echo "$f does not pin the nixpkgs RADV ICD"; exit 1; }
                    grep -q VK_LOADER_LAYERS_DISABLE "$f" \
                      || { echo "$f does not disable implicit Vulkan layers"; exit 1; }
                  done
                done

                export HOME=$TMPDIR
                for pkg in ${builtins.concatStringsSep " " llamas}; do
                  VK_LOADER_DEBUG=driver,error "$pkg/bin/llama-server" --list-devices > "$TMPDIR/log" 2>&1 || true
                  grep -qF "Searching for ICD drivers named $RADV" "$TMPDIR/log" \
                    || { tail -n 40 "$TMPDIR/log"; echo "$pkg/bin/llama-server did not search for the nixpkgs RADV driver"; exit 1; }
                  ! grep -q "Failed loading library" "$TMPDIR/log" \
                    || { tail -n 40 "$TMPDIR/log"; echo "$pkg/bin/llama-server failed loading a Vulkan library"; exit 1; }
                done
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
            benchmark-go-gate = benchmarkGate;
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
