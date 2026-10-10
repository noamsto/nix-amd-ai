# nix-amd-ai

AMD AI inference stack for NixOS — packages XRT, XDNA driver plugin, FastFlowLM, and Lemonade with a NixOS module for NPU + ROCm GPU support.

On Apple Silicon (`aarch64-darwin`) the same flake also serves the cross-platform Lemonade server (llama.cpp Metal backend) via a nix-darwin module — see [macOS (nix-darwin)](#macos-nix-darwin). The AMD/NPU/ROCm stack is Linux-only.

## Packages

| Package | Description | Source |
|---------|-------------|--------|
| `xrt` | Xilinx Runtime for AMD NPU | Built from [Xilinx/XRT](https://github.com/Xilinx/XRT) |
| `xrt-plugin-amdxdna` | XDNA userspace driver plugin | Built from [amd/xdna-driver](https://github.com/amd/xdna-driver) branch `1.9` |
| `fastflowlm` | NPU-optimized LLM runtime | Built from [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) |
| `openflowlm` | [OpenFlowLM-Next](https://github.com/Atomic-Germ/OpenFlowLM-Next) (`oflm`), the open-kernel fork of FastFlowLM; its open NPU kernels are built from source in the Nix sandbox | Built from [Atomic-Germ/OpenFlowLM-Next](https://github.com/Atomic-Germ/OpenFlowLM-Next) at a pinned commit (no releases yet) |
| `mlir-aie` | MLIR-based AI Engine compiler toolchain (`aiecc`, `aie-opt`, `aie-translate`, `bootgen`) | Built from the [Xilinx/mlir-aie](https://github.com/Xilinx/mlir-aie) 1.4.2 wheel |
| `llvm-aie` | Peano AI Engine LLVM/Clang backend (`clang`, `lld`, `llc`) | Built from a [Xilinx/llvm-aie](https://github.com/Xilinx/llvm-aie) nightly wheel |
| `lemonade` | OpenAI-compatible local AI server (`lemond` + CLI + web UI + Tauri desktop app) | Built from [lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade) |
| `lemonade-headless` | `lemonade` without the Tauri desktop shell — what `lemonade.desktopApp.enable = false` selects, cached so headless hosts substitute it | `lemonade.override { withDesktopApp = false; }` |
| `llama-cpp` | CPU llama.cpp backend, at the pinned build (b11382) | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `llama-cpp-rocm` | ROCm-accelerated llama.cpp backend | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `llama-cpp-rocm-gsqhalo` | `llama-cpp-rocm` built from the GSQHalo.cpp fork, opt-in via `llamaCppRocmPackage` | Built from [Aristo94/GSQHalo.cpp](https://github.com/Aristo94/GSQHalo.cpp) |
| `llama-cpp-vulkan` | Vulkan-accelerated llama.cpp backend, wrapped to use its own RADV driver ([#215](https://github.com/noamsto/nix-amd-ai/issues/215)); `.unwrapped` is the plain build | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `whisper-cpp-vulkan` | Vulkan-accelerated whisper.cpp backend, wrapped to use its own RADV driver ([#215](https://github.com/noamsto/nix-amd-ai/issues/215)); `.unwrapped` is the plain build | `pkgs.whisper-cpp.override { vulkanSupport = true; }` |
| `stable-diffusion-cpp-rocm` | ROCm-accelerated stable-diffusion.cpp backend | `pkgs.stable-diffusion-cpp.override { rocmSupport = true; }` |
| `stable-diffusion-cpp-vulkan` | Vulkan-accelerated stable-diffusion.cpp backend, wrapped to use its own RADV driver | `pkgs.stable-diffusion-cpp.override { vulkanSupport = true; }` |
| `vllm-rocm` | Experimental vLLM ROCm backend, relocated from a prebuilt bundle; opt-in via `enableVllm` (see [vLLM](#opt-in-vllm-rocm-backend)) | Repackaged from the [lemonade-sdk/vllm-rocm](https://github.com/lemonade-sdk/vllm-rocm) prebuilt |
| `ds4` | DeepSeek V4 inference engine, Strix Halo (`gfx1151`) ROCm backend (`ds4`, `ds4-server`, `ds4-bench`, `ds4-eval`, `ds4-agent`) | Built from [antirez/ds4](https://github.com/antirez/ds4) |
| `strata` | Qwen3.8-Flash-Next engine on TheRock ROCm 7.14.1, Strix Halo (`gfx1151`); opt-in lemond backend via `hardware.amd-npu.strata` ([section](#opt-in-strata-backend-strix-halo)) | Built from [Niko1221/Strata](https://github.com/Niko1221/Strata) |
| `gaia` | AMD GAIA agent framework launcher (`gaia`, `gaia-cli`, `gaia-mcp`) | `uvx` wrapper around [amd/gaia](https://github.com/amd/gaia) |
| `benchmark` | Multi-backend benchmark harness | `nix run .#benchmark` |

CPU backends for llamacpp / whispercpp / sd-cpp are wired automatically when `enableLemonade = true`. `llama-cpp` and the Vulkan and ROCm variants are built from this flake's pin, **b11382** (the opt-in GSQHalo fork aside); only `whisper-cpp` and `stable-diffusion-cpp` are the pinned nixpkgs builds. b11382 carries [ggml-org/llama.cpp#29761](https://github.com/ggml-org/llama.cpp/pull/29761)'s Qwen3.8-Flash-Next MTP sidecar support; on halo it gives **1.51× (Vulkan) / 1.74× (ROCm)** decode over MTP-off — see [`bench-logs/qwen38-flash-next-mtp-2026-10-04`](bench-logs/qwen38-flash-next-mtp-2026-10-04/).

The `lemonade` package composes three derivations:

- `lemonade.passthru.web-app` — React web UI (`buildNpmPackage`, served by `lemond` at `/`)
- `lemonade.passthru.tauri-frontend` — desktop-shell renderer bundle (`buildNpmPackage`)
- `lemonade.passthru.tauri-app` — Tauri desktop binary (`rustPlatform.buildRustPackage` against webkit2gtk-4.1)

Both UIs are built by default. Headless / server-only consumers can opt out:

```nix
nix-amd-ai.overlays.default = final: prev: {
  lemonade = (prev.lemonade.override {
    withWebApp = true;        # default — web UI served by lemond
    withDesktopApp = false;   # skip Rust + webkit2gtk closure
  });
};
```

## Usage

```nix
# flake.nix
inputs.nix-amd-ai.url = "github:noamsto/nix-amd-ai";

# host configuration
{inputs, ...}: {
  imports = [inputs.nix-amd-ai.nixosModules.default];

  hardware.amd-npu = {
    enable = true;
    enableNPU = true;         # default; set false for GPU-only hosts (see "Other hardware")
    enableFastFlowLM = true;  # LLM inference on NPU (requires enableNPU)
    # fastflowlm.package = pkgs.fastflowlm;  # swap in an flm-compatible runtime (see below)
    enableLemonade = true;    # OpenAI-compatible API server
    enableROCm = true;        # ROCm GPU backends (llamacpp + sd-cpp)
    enableVulkan = true;      # Vulkan GPU backends (llamacpp + whispercpp)
    enableImageGen = true;    # default true; set false to drop sd-cpp from closure
    # rocmGpuTargets = ["gfx1103"];  # only to reach a GPU the shipped
    #                                # gfx1150+gfx1151 build doesn't cover
    lemonade.user = "youruser";
  };

  users.users.youruser.extraGroups = ["video" "render"];
}
```

On Strix Halo, also set `gpuTarget = "gfx1151"`; the default is `gfx1150` (Strix Point).

> [!IMPORTANT]
> **FastFlowLM's NPU kernels are proprietary.** The package's source is MIT,
> but the `.xclbin` kernels it installs are governed by
> [FastFlowLM's TERMS.md](https://github.com/ROCm/FastFlowLM/blob/1a40ad9ade3d4714d48974a974a114441a5bd786/TERMS.md):
> free only for non-commercial use or for companies with annual revenue
> ≤ USD 10M; a commercial licence is required above that. nixpkgs therefore
> treats `fastflowlm` as unfree, and applying this overlay/module on a host
> with `allowUnfree = false` fails evaluation. `openflowlm` is unfree for the
> same reason: it still ships and loads FastFlowLM's closed engine libraries
> and kernels for every model without an open recipe. Allow the package(s)
> you use:
>
> ```nix
> nixpkgs.config.allowUnfreePredicate =
>   pkg: builtins.elem (lib.getName pkg) ["fastflowlm" "openflowlm"];
> ```
>
> `"openflowlm"` is only needed if you set `fastflowlm.package = pkgs.openflowlm`.

### macOS (nix-darwin)

On Apple Silicon the flake ships a `darwinModules.default` exposing `services.lemonade`. It installs the Lemonade server and runs it as a per-user LaunchAgent (the llama.cpp Metal backend needs a GUI login session, so it cannot run as a root daemon). The Metal/sd.cpp backends are fetched into `~/.cache/lemonade` on first run, exactly as the upstream `.pkg` does — there is no NPU/ROCm wiring on macOS.

```nix
# flake.nix
inputs.nix-amd-ai.url = "github:noamsto/nix-amd-ai";

# darwin configuration
{inputs, ...}: {
  imports = [inputs.nix-amd-ai.darwinModules.default];

  services.lemonade = {
    enable = true;
    port = 13305;          # default
    host = "localhost";    # default
  };
}
```

The package alone (no service) is also available: `nix build github:noamsto/nix-amd-ai#lemonade` on `aarch64-darwin` produces `bin/lemond` + `bin/lemonade` serving the OpenAI-compatible API at `http://localhost:13305/api/v1`. It wraps upstream's prebuilt, server-only `lemonade-embeddable-*-macos-arm64` release (no web UI / Tauri app — those ship only in the `.pkg`).

## Binary cache

Pre-built packages are available via Cachix:

```nix
# nix.settings in your NixOS config (see caveat below for flake nixConfig)
substituters = ["https://nix-amd-ai.cachix.org"];
trusted-public-keys = ["nix-amd-ai.cachix.org-1:F4OU4vw/lV2oiG6SBHZ+nqjl4EFJuqI4X9A7pvaBmhQ="];
```

> [!IMPORTANT]
> Put this in `nix.settings` (NixOS) or your daemon's `nix.conf`. A substituter added only via flake `nixConfig` takes effect **only for trusted users** — otherwise Nix silently ignores it and rebuilds everything from source, including the Tauri app's crates.io cargo-vendor fetch (the failure in [#28](https://github.com/noamsto/nix-amd-ai/issues/28)).

> [!WARNING]
> **Do not `.follows` our `nixpkgs` input.** The overlay is intentionally built against this flake's pinned `nixpkgs` (see `flake.nix` `pinned`) so the input closure hash matches both `cache.nixos.org` (Hydra-cached `pkgs.llama-cpp.override`, etc.) and our Cachix. If you add `inputs.nix-amd-ai.inputs.nixpkgs.follows = "nixpkgs"`, the overrides re-hash against your `nixpkgs` and every backend rebuilds from source. Just leave this input pinned:

```nix
# good — let nix-amd-ai keep its own pinned nixpkgs
inputs.nix-amd-ai.url = "github:noamsto/nix-amd-ai";

# bad — forces rebuilds of llama-cpp / whisper-cpp / stable-diffusion-cpp
# inputs.nix-amd-ai.inputs.nixpkgs.follows = "nixpkgs";
```

Because the backends run against this flake's pinned `nixpkgs`, the module never hands them your system's ROCm or mesa libraries, and the Vulkan backends carry their own driver. A system `nixpkgs` with a newer glibc makes those libraries unloadable, and llama.cpp then silently falls back to the CPU ([#215](https://github.com/noamsto/nix-amd-ai/issues/215)).

To use a different Vulkan driver (another GPU, AMDVLK), set `VK_DRIVER_FILES` yourself, e.g. `systemd.services.lemond.environment.VK_DRIVER_FILES = "...";` — the wrappers only set it when it is unset.

## Requirements

- NixOS with kernel >= 6.14 (has `amdxdna` driver built-in) — only required when `enableNPU = true`
- AMD Ryzen AI processor with XDNA 2 NPU (Strix Point / Strix Halo; Krackan Point untested) for the NPU path; the GPU backends run on any supported AMD GPU with `enableNPU = false` (see "Other hardware")
- User in `video` and `render` groups

## Other hardware (RDNA3 iGPUs / Hawk Point)

The module splits into an NPU half and a GPU half. The NPU half (XRT + `amdxdna` + FastFlowLM) is built and tested for **XDNA 2** (Strix Point / Strix Halo) — that's what FastFlowLM targets. The GPU backends are independent and run on other AMD GPUs.

**Krackan Point** (Ryzen AI 7 350 / 5 340, PCI `1022:17f0` rev `0x20`) is XDNA 2 with the same 8-column AIE array, but `amdxdna` gives it its own device profile (`dev_npu6_info`, vs `dev_npu4_info` for Strix Point) and nothing here has been tested on it. Reported failing at model load with `DRM_IOCTL_AMDXDNA_CREATE_HWCTX` — see #79.

Set `enableNPU = false` to drop the XRT/`amdxdna` closure (kernel module, udev rules, memlock limits) and run GPU-only. Example for a **Hawk Point** APU (Ryzen 9 8945HS, Radeon 780M / `gfx1103`):

```nix
hardware.amd-npu = {
  enable = true;
  enableNPU = false;        # no XDNA-2 NPU on Hawk Point
  enableVulkan = true;      # 780M via RADV — works, and fastest on these iGPUs
  enableLemonade = true;
  lemonade.user = "youruser";
};
```

- **Vulkan** is the recommended path: RADV is arch-agnostic, so llama.cpp / whisper.cpp run on any RDNA3 iGPU including the Radeon 780M (Phoenix / Hawk Point).
- **NPU** (`enableFastFlowLM`) is XDNA-2 only; the assertion blocks it unless `enableNPU = true`.
- **ROCm** (`enableROCm`): the shipped `llama-cpp-rocm` and `sd-cpp-rocm` are compiled for `gfx1150` and `gfx1151` only, so they carry **no 780M kernels** and the backend will fail to load on one. Name your own target to get them:

  ```nix
  hardware.amd-npu.rocmGpuTargets = ["gfx1103"];
  ```

  This is **untested on actual Hawk Point hardware**, and rocBLAS coverage for `gfx1103` APUs can be uneven, so Vulkan remains the recommended path. If ROCm misbehaves, the usual fallback is to alias the arch to `gfx1100`:

  ```nix
  systemd.services.lemond.environment.HSA_OVERRIDE_GFX_VERSION = "11.0.0";
  ```

  The value is part of the derivation, so naming a target means a store path no substituter has: native kernels for your chip, bought with a local llama.cpp and sd.cpp build. The cache carries the gfx1150+gfx1151 pair and nothing else, which is also what `#llama-cpp-rocm` and `#stable-diffusion-cpp-rocm` build.

> [!WARNING]
> Never boot an NPU host with `amd_iommu=off` (or `iommu=off`): `amdxdna` needs the IOMMU for PASID, so the NPU dies, and `enableNPU` asserts on it. Another module can contribute the parameter, e.g. Jovian-NixOS's SteamOS defaults. Rationale and the IOMMU-mode notes: [docs/tuning-tradeoffs.md](docs/tuning-tradeoffs.md).

## Module reference

- Kernel modules (`amdxdna`)
- Udev rules for NPU device access
- PAM limits (unlimited memlock for NPU buffer allocation)
- XRT + plugin merged tree for runtime plugin discovery
- Lemonade systemd service with XRT/FLM/ROCm/Vulkan environment
- Environment variables (`XILINX_XRT`, `XRT_PATH`)
- Declarative backend wiring (both the `lemond` service and direct CLI usage receive the ROCm/Vulkan backend paths automatically)

### Backend wiring and in-tree patches

The lemonade source build deliberately doesn't bundle backend `llama-server` / `whisper-server` / `sd-server` binaries — it expects host-provided paths. The module seeds a `defaults.json` carrying those paths (plus `global_timeout` and flash-attn) that lemonade merges over its packaged defaults, via the `LEMONADE_DEFAULTS_PATH` patch below. Lemonade v10.7.0 removed the env-var migration into `~/.config/lemonade/config.json` that this replaced:

| Flag | What gets wired |
|---|---|
| `enableLemonade` | CPU recipes always-on: `llamacpp:cpu`, `whispercpp:cpu`, `sd-cpp:cpu` (when `enableImageGen`) |
| `enableROCm` | `llamacpp:rocm`, `llamacpp:system` (via `LEMONADE_GGML_HIP_PATH`), `sd-cpp:rocm` (when `enableImageGen`) |
| `enableVulkan` | `llamacpp:vulkan`, `whispercpp:vulkan`, `sd-cpp:vulkan` (when `enableImageGen`) |
| `enableVllm` (default false) | `vllm:rocm` from the `lemonade-sdk/vllm-rocm` prebuilt (requires `enableROCm`); pick the GPU target with `vllmGpuTarget` (`gfx1150`/`gfx1151`). Experimental, ~7.6 GB closure — see [vLLM](#opt-in-vllm-rocm-backend) |
| `enableImageGen` (default true) | Gates all `sd-cpp:*` packages; turn off for ~150 MB CPU / ~1.5 GB ROCm savings on headless LLM-only hosts |

Omni models (e.g. `LMX-Omni-*`) pull in two backends that need extra host plumbing the module wires automatically with `enableLemonade` ([#33](https://github.com/noamsto/nix-amd-ai/issues/33)): `whispercpp` resolves its writable runtime dir from the unit's `RuntimeDirectory`, and the runtime-downloaded kokoro TTS binary is a foreign prebuilt ELF, so the module enables `nix-ld` (its default libraries already cover koko's openssl + gcc-libs) and re-exports `NIX_LD*` into the `lemond` service. nix-ld is set via `mkDefault`, so hosts managing it themselves can opt out.

Vanilla lemonade doesn't fit NixOS, so this flake patches it in-tree (see `pkgs/lemonade/default.nix` and `pkgs/lemonade/patches/`, [issue #5](https://github.com/noamsto/nix-amd-ai/issues/5), upstream [lemonade-sdk/lemonade#1791](https://github.com/lemonade-sdk/lemonade/issues/1791)):

- `ConfigFile::get_defaults` honors `LEMONADE_DEFAULTS_PATH`, so the module can seed backend bin paths from a store path instead of the hardcoded `/usr/share/lemonade/defaults.json` that NixOS can't populate.
- The download SSE handler treats `sink.write` failure as a transient client disconnect rather than a cancel signal, so a backgrounded Tauri window doesn't kill an in-flight multi-GB download.
- `will_install_therock()` returns false, so lemonade never fetches its TheRock ROCm runtime, whose libraries would shadow the Nix-built backends' own ([#57](https://github.com/noamsto/nix-amd-ai/issues/57)).
- `strata-recipe.patch` adds a native `strata` recipe that starts the Strata shim backend ([#285](https://github.com/noamsto/nix-amd-ai/issues/285)).

If `lemonade backends` reports a backend as `installed` but benchmarks report <5 t/s decode on a small model, you're on CPU — check that the matching `enable*` option is set and the host has been rebuilt.

Two lemonade options have no section of their own: `lemonade.flashAttn` (`"auto"`, `"on"` or `"off"`, default `"on"`) is passed as `--flash-attn` to lemond-spawned llama-server, and `lemonade.autoStart` (default `true`) controls whether `lemond` and the `lemond-models` puller start at boot; set it false to start lemond on demand, e.g. with [`exclusiveInference`](#running-ds4-beside-lemond).

### Runtime config: `lemonade.settings`

`LEMONADE_DEFAULTS_PATH` only seeds `~/.config/lemonade/config.json` on lemond's
**first** run — afterwards `ConfigFile::load` merges the packaged defaults
*under* the persisted file, so every key the module declares goes inert. Backend
bin paths survived that because they point at stable `/etc/lemonade/backends/*` symlinks, but scalars did not: a host that first started lemond before enabling `enableVllm` kept `global_timeout = 0`, which vLLM reads as its startup-readiness budget and turns into zero poll attempts ([#68](https://github.com/noamsto/nix-amd-ai/issues/68)).

The lemond unit therefore re-applies the module-declared keys on every start, leaving everything else to whatever the web UI persisted. `lemonade.settings` rides the same path for keys the module has no dedicated option for:

```nix
hardware.amd-npu.lemonade.settings = {
  max_loaded_models = -1;   # keep a small NPU model and a big GPU model resident together
  auto_evict = true;        # then let lemond reclaim on idle / VRAM pressure
};
```

`max_loaded_models` (default `1`) is what makes models take turns — raise or unset it (`-1`) to keep several resident. `auto_evict` is a *separate*, opt-in background reclaimer (default **off**) that unloads idle models and sheds them once VRAM crosses `auto_evict_threshold_pct` (default `0.90`); it pairs naturally with an unlimited `max_loaded_models`. Anything lemond's `RuntimeConfig` validates is accepted. Values merge recursively over the module's computed defaults, so overriding `llamacpp.args` does not drop the sibling `llamacpp.*_bin` paths.

Per-*model* eviction knobs (`pinned`, `evict_idle_timeout`, `downsize_idle_timeout`, `evict_weight_factor`, and a per-recipe `auto_evict` override) live in lemond's separate `recipe_options.json`; set them with [`lemonade.recipeOptions`](#per-model-recipe-options-lemonaderecipeoptions) below.

Reconciliation only ever writes keys, never deletes them: dropping a key from `settings` stops it being re-applied but leaves the last value in the persisted config, so set it back to the value you want rather than removing the line.

`settings.host` / `settings.port` are silently overwritten (`lemond` persists `--port` and `--host` itself after the reconcile hook runs, which also resets the file's mode to `0644` on every start); use `lemonade.host` and `lemonade.port`. Lemonade >=11.5.0 stopped sending `Access-Control-Allow-Origin: *`, so non-loopback browsers get a 403 `Origin not allowed` unless their origin is in `LEMONADE_ALLOWED_ORIGINS`. That is env-only too, so set `lemonade.allowedOrigins` (loopback origins and non-http(s) desktop schemes are always allowed); the module warns if you bind `lemonade.host` beyond loopback without it.

### Per-model recipe options: `lemonade.recipeOptions`

`lemonade.settings` reaches lemond's global runtime config; the per-model knobs — most usefully `pinned`, which exempts a model from auto-eviction — live in a different file, `recipe_options.json`, keyed by canonical model ID. That file has no packaged defaults layer: lemond reads it as bare user state, so the module merges its entries into it on every `lemond` start rather than seeding it once.

```nix
hardware.amd-npu.lemonade.recipeOptions = {
  "builtin.Gemma4-2B-FLM" = { pinned = true; };
  "builtin.Qwen3.6-30B-GGUF" = { evict_idle_timeout = 900; };
};
```

Keys are canonical IDs, not the bare names `lemonade list` prints: prefix a listed name with `builtin.` for the built-in registry or `user.` for a model registered through the web UI or `lemonade.customModels`. A bare key silently matches nothing. `pinned = true` is the mixed NPU + GPU case from [#67](https://github.com/noamsto/nix-amd-ai/issues/67): it keeps the small NPU model resident without having to raise the global `max_loaded_models` cap.

The five eviction keys — `pinned`, `auto_evict`, `evict_idle_timeout`, `downsize_idle_timeout`, `evict_weight_factor` — are typed, so a wrong type fails at eval. Every other recipe option (`ctx_size`, `llamacpp_args`, …) passes through unchanged, which is also why a typo of a known key is treated as an unknown option and ignored by lemonade rather than rejected.

The merge is per key and module keys win on conflict, so a `ctx_size` or args value the web UI set for the same model survives alongside the declared pin. For `user.<name>` models, `customModels.<name>.recipe_options` supplies a lower-precedence default; this option is the higher layer and the only declarative path for built-ins. As with `lemonade.settings`, the merge only writes keys, never deletes them, and a key set to `null` is pruned rather than written.

### Declarative models: `lemonade.models`

Models to keep downloaded, named as `lemonade list` reports them:

```nix
hardware.amd-npu.lemonade.models = [
  "Qwen3.5-4B-MTP-GGUF"
  "llama3.2-1b-FLM"
];
```

A `lemond-models` unit pulls whatever is missing. Models already on disk are skipped, so re-activating an unchanged list costs nothing.

**Activation does not block.** The unit is `Type=simple`, so systemd calls it
started the moment it forks and `nixos-rebuild switch` returns immediately rather than sitting on multi-GiB downloads. Follow the pull with:

```bash
journalctl -fu lemond-models
```

It has to be a unit rather than an activation script because `lemonade pull` is an HTTP client — it needs `lemond` already answering, which is also why the unit waits for `lemonade status` before doing anything. A model that fails to pull is logged and skipped, so one bad name can't block the rest of the list.

To make the set on disk *exactly* the declared one, add:

```nix
hardware.amd-npu.lemonade.pruneUnlistedModels = true;
```

This deletes downloaded models the list doesn't mention. It's off by default — models are large and slow to re-fetch, and anything pulled by hand for an experiment would vanish on the next activation. It requires a non-empty `lemonade.models`, so an empty list can never be read as "delete everything".

### Speculative MTP: `lemonade.customModels`

The `mtp` label makes lemond pass `--spec-type draft-mtp`, which needs the model to carry an MTP draft head. For Qwen3.8-Flash-Next the head is a **separate** self-contained GGUF, declared as the `draft` checkpoint alongside `main`:

```nix
hardware.amd-npu.lemonade.customModels."Qwen3.8-Flash-Next-MTP" = {
  checkpoints = {
    main  = "unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ4_XS";
    draft = "ggml-org/Qwen3.8-Flash-Next-GGUF:mtp-Qwen3.8-Flash-Next-Q8_0.gguf";
  };
  recipe = "llamacpp";
  recipe_options = {
    ctx_size = 131072;
    llamacpp_args = "-ctk q8_0 -ctv q8_0 --spec-draft-n-max 3";
  };
  labels = ["chat" "reasoning" "tool-calling" "mtp"];
};
```

The `draft` head must be the **ggml-org** one, not unsloth's `MTP/` copy — the latter was built for the superseded fork and aborts stock b11382. `--spec-draft-n-max 3` is the best setting measured (best of {2,3,4} on halo, gfx1151, Vulkan; this exact q8_0-KV / 131K-ctx config was not benchmarked), and the example is unchanged by the
#237 tuning pass, which found no clear winner among the `--spec-draft-n-max` and
`--spec-draft-p-min` values it tried. Tuning results and their load caveats: [bench-logs index](bench-logs/README.md) (`qwen38-flash-next-mtp-*`).

### GPU memory headroom

The iGPU draws GPU memory from the GTT pool. By default the kernel exposes ~27 GB addressable, which covers the 17–22 GB models this flake targets on a 64 GB Strix Point host — so **leave these options unset there; they're a no-op.**

On a **128 GB Strix Halo** host you need to raise the ceiling to expose the large unified pool for big models. The module takes sizes in **GiB** and computes the `ttm` page counts for you (`pages = GiB × 262144`):

```nix
hardware.amd-npu.gpuMemory = {
  ttmSizeGiB = 96;        # GTT pool ceiling  → ttm pages_limit
  pagePoolSizeGiB = 96;   # pre-cached pool   → ttm page_pool_size
};
```

This emits `options ttm pages_limit=25165824 page_pool_size=25165824` via `boot.extraModprobeConfig`, and is the pair the measurements in docs/gpu-memory.md were taken on — the Halo host runs `page_pool_size` equal to `pages_limit`, not a fraction of it.

Pick `ttmSizeGiB` by the largest model you actually intend to load, and don't set it to your full physical RAM — the CPU and OS still need their share:

| `ttmSizeGiB` (128 GB host) | When it's right |
| ---: | --- |
| ~96 | General use. Leaves ~32 GB for CPU/OS. Comfortable to ~70 GB models — a 67 GB Q4_K_M sat at `mem_info_gtt_used` ≈ 66 GB. |
| ~120 | Models of 75 GiB+. The OS margin gets thin, but the alternative is a kernel fallback or a failed load. |

`ttmSizeGiB` alone sets the ceiling (the arithmetic is exact), so don't also set `amdgpu.gttsize`; `pagePoolSizeGiB` is unmeasured. The measurements, the `gttsize` warning and the `pagePoolSizeGiB` discussion are in [docs/gpu-memory.md](docs/gpu-memory.md). Halo measurements contributed by [@expelledboy](https://github.com/expelledboy) (#42).
## Opt-in engines

### Opt-in Strata backend (Strix Halo)

[Strata](https://github.com/Niko1221/Strata) (pinned v0.1.40.2 `e8ca9af`, built against TheRock ROCm 7.14.1) is a Qwen3.8-Flash-Next engine for Strix Halo. The module serves it behind lemond through a native `strata` recipe carried as a small patch in `pkgs/lemonade`: lemond starts a small shim instead of `ds4-server`, so clients use lemond's normal API and load/unload. The model is listed as `user.Qwen3.8-Flash-Next-Strata` (option `modelName`) under lemond's "Strata (experimental)" recipe name; the recipe is its own, so the `ds4` recipe stays free for a real DeepSeek V4 model. Measurements: [first run and build](bench-logs/qwen38-flash-next-strata-2026-10-06/README.md), [quality](bench-logs/qwen38-flash-next-strata-quality-2026-10-07/README.md) and the [soak](bench-logs/qwen38-flash-next-strata-soak-2026-10-08/README.md).

```nix
hardware.amd-npu = {
  gpuTarget = "gfx1151";
  lemonade.cacheDir = "/var/lib/models";
  strata = {
    enable = true;
    profile = "defaults"; # or "fast"
  };
};
```

- `model` defaults to the Flash-Next GGUF pinned in `pkgs/strata/sources.nix` (quant chosen by `strata.quant`; `UD-IQ4_XS` is the only one packed and benched so far), read from lemond's Hugging Face cache under `lemonade.cacheDir`, so it shares shards with a llamacpp `customModels` entry. Without `cacheDir`, or for a GGUF kept elsewhere, set `model` to the first shard's path.
- With only `enable` and a model, the `strata-prepare` oneshot unit builds the pack and MTP runtime in `/var/lib/strata` and `vision.mmproj` defaults to a pinned fetch. Set `pack`, `mtp` and `vision.mmproj` explicitly to keep your own artifacts; `strata.prepare.enable` forces it on or off. Details and stamps: [docs/strata.md](docs/strata.md).
- `profile = "defaults"` is Strata's setup defaults; `"fast"` is the maintainers' fast configuration and turns on bit-changing switches. Its quality was measured on one Strix Halo host (gfx1151, UD-IQ4_XS) against a Q8_0 reference: mean KLD 0.0897 for `fast` versus 0.0920 for `defaults`, so `fast` was not worse there; the [quality bench](bench-logs/qwen38-flash-next-strata-quality-2026-10-07/) also has the measured speed difference, on that host only.
- `contextSize` (default `131072`) is passed as `--max-context`; lemond's `ctx_size` for the model overrides it per load. `expertCache` (default `20000`) is an explicit expert-cache count, always paired with `--mmap-experts`; Strata's `auto` is rejected as unsafe on unified memory. `extraArgs` (default `[]`) is appended to the Strata command line; `--expert-cache` and `--max-context` are rejected there, so use the two options above. `vision.enable` (default `true`) serves image input and requires `vision.mmproj`; behind lemond, images must be sent as `data:` URLs.
- `sampling` sets decoding defaults for requests that send none (Qwen's recommended thinking set by default); a request's own fields win. See [docs/strata.md](docs/strata.md).

**Costs.** An 8.9 GiB Nix closure (the pinned SDK), built with `-march=native` so the output is specific to the building host's CPU. It is `gfx1151` only and experimental upstream. CI does not build it, so enabling it compiles it locally.

**Memory.** About 67 GiB of GTT at 131072 context on halo. lemond counts loaded models per slot, not memory, so keep one LLM slot (`lemonade.settings.max_loaded_models`) or unload the resident model first. First-run pack and MTP build timings, the behind-lemond limits and the timeout behaviour are in [docs/strata.md](docs/strata.md).

### Opt-in GSQHalo.cpp ROCm backend

`pkgs.llama-cpp-rocm-gsqhalo` is [Aristo94/GSQHalo.cpp](https://github.com/Aristo94/GSQHalo.cpp) (`5fc881b`) built through this flake's `llama-cpp-rocm`. Opt in with `hardware.amd-npu.llamaCppRocmPackage = pkgs.llama-cpp-rocm-gsqhalo;`; the default is the stock `llama-cpp-rocm`, and `rocmGpuTargets` applies to either. On one Strix Halo (gfx1151) host it cut agent-replay time 35 % against stock Vulkan llama.cpp on Qwen3.8-Flash-Next with f16 KV and the flags in the [tuning bench](bench-logs/qwen38-flash-next-gsq-tuning-2026-10-06/README.md) (flags measured, not module defaults; `-lzm` is fork-only and stock llama.cpp rejects it). The [Strata soak bench](bench-logs/qwen38-flash-next-strata-soak-2026-10-08/README.md) concluded Strata is the preferred Flash-Next engine.

### Opt-in vLLM ROCm backend

`enableVllm` wires the experimental `vllm:rocm` backend, repackaged from the upstream `lemonade-sdk/vllm-rocm` prebuilt ([#63](https://github.com/noamsto/nix-amd-ai/issues/63)). Building vLLM + ROCm from source isn't viable here — nixpkgs `rocmPackages` trails ROCm 7.15 and lacks the Strix gfx targets — so we relocate their portable Python + torch + TheRock-ROCm bundle instead (interpreter-patched, not autoPatchelf'd, which would inject mismatched nixpkgs libs and segfault torch). It's off by default and adds a ~7.6 GB closure with no binary-cache substituter. It sets `global_timeout` to 3600 for vLLM's startup wait.

Validated on gfx1150 (standalone and through lemonade's OpenAI API). The `gfx1151` (Strix Halo) target builds and its `vllm-server` launches — torch and vLLM import cleanly. On a Strix Halo host, a standalone `vllm-server` run of `facebook/opt-125m` returned a coherent completion (2026-09-05, not through lemonade); a larger model (Qwen3.5-9B) has not been run yet, see [docs/halo-bringup-checklist.md](docs/halo-bringup-checklist.md). On gfx1150 our benchmarks still put Vulkan ahead of ROCm and vLLM's batching doesn't help single-user workloads, so `enableVllm` mainly matters on gfx1151 (where the Vulkan-fills-VRAM-first freeze on X11 makes the ROCm path worthwhile) or for vLLM-specific features.

### ds4 (DeepSeek V4 on Strix Halo)

[ds4](https://github.com/antirez/ds4) is antirez's self-contained native inference engine for DeepSeek V4. It is deliberately narrow — not a generic GGUF runner — and its ROCm backend targets Strix Halo (`gfx1151`) only, so the package is `x86_64-linux` + AMD-hardware specific and pins `gfx1151` via the `gpuTarget` argument.

```bash
nix run .#ds4 -- -m /path/to/DeepSeek-V4-Flash.gguf   # interactive chat
nix shell .#ds4 -c ds4-server --ctx 100000            # OpenAI-compatible server
```

The engine only; bring your own GGUF (see upstream [`STRIXHALO.md`](https://github.com/antirez/ds4/blob/main/STRIXHALO.md) for the recommended `DeepSeek-V4-Flash` quant and the host GTT/`ttm.pages_limit` kernel tuning). Upstream ships no releases, so `pkgs/ds4/default.nix` pins a commit and is bumped manually — CI builds it but `scripts/check-updates.sh` doesn't track it.

To run `ds4-server` as a managed systemd unit, enable it via the module:

```nix
hardware.amd-npu.ds4 = {
  enable = true;
  user = "youruser";                                  # must be in render + video
  model = "/var/lib/ds4/DeepSeek-V4-Flash.gguf";       # runtime path, not store-copied
  ctx = 100000;
  extraArgs = ["--ssd-streaming" "--kv-disk-dir" "/var/lib/ds4/server-kv"];
};
```

Binds `127.0.0.1:8000` by default (`host`/`port`); the unit runs with `render`/`video` GPU access, `LimitMEMLOCK=infinity`, and a writable `/var/lib/ds4` (StateDirectory) for the optional SSD-streaming KV cache. Retarget another AMD GPU with `package = pkgs.ds4.override { gpuTarget = "gfx1103"; }` (experimental — upstream only validates gfx1151).

Benchmark tables that used to sit here are in [docs/performance.md](docs/performance.md).

### Running ds4 beside lemond

Both servers draw from the same GTT pool, and a DeepSeek-V4-Flash-sized model leaves no room for a second resident one. `exclusiveInference` makes the two mutually exclusive (`Conflicts=`: starting either stops the other) instead of leaving the machine to thrash, and `autoStart` options pick which server the host boots with:

```nix
hardware.amd-npu = {
  exclusiveInference = true;   # no-op unless both servers are enabled
  ds4.autoStart = false;       # boot into lemond, run ds4 on demand
  # lemonade.autoStart = false;  # or the reverse
};
```

`systemctl start ds4-server` then stops lemond, and `systemctl start lemond` stops ds4. Both default to the previous behaviour (every server autostarts, nothing conflicts); turn this on only where the models genuinely don't fit together. The measured thrash and the open question of why both servers died are in [docs/gpu-memory.md](docs/gpu-memory.md).
### flm-compatible runtimes

`hardware.amd-npu.fastflowlm.package` (default `pkgs.fastflowlm`) selects the runtime that `enableFastFlowLM` installs and lemonade drives. The module wraps it with the XRT `LD_LIBRARY_PATH`, links its main program (`meta.mainProgram`, which need not be `flm`) at `/etc/lemonade/backends/flm-npu`, and seeds `flm.npu_bin = "/etc/lemonade/backends/flm-npu"`. Lemonade resolves FLM through `flm.npu_bin` first (or the `LEMONADE_FLM_NPU_BIN` environment variable), and only then looks for a literal `flm` on `PATH`. A path-valued `npu_bin` also drops lemonade's expected-version check, so the `backend_versions.json` pin to `pkgs.fastflowlm` does not flag another runtime as needing an update.

`flm.flm_bin` is **not** a config key: `lemonade config set flm.flm_bin ...` is accepted silently and has no effect. Use `flm.npu_bin`.

The wiring is verified by an eval check only. `pkgs.openflowlm` is the one alternative tested on hardware; see [OpenFlowLM-Next](#openflowlm-next-oflm).

### OpenFlowLM-Next (`oflm`)

[OpenFlowLM-Next](https://github.com/Atomic-Germ/OpenFlowLM-Next) is a community fork of FastFlowLM that replaces some of its closed NPU kernels with kernels built from source. Use it in place of `pkgs.fastflowlm`:

```nix
hardware.amd-npu.fastflowlm.package = pkgs.openflowlm;
```

plus `"openflowlm"` in the unfree predicate (see [Usage](#usage)). Lemonade drives `oflm` through its `flm` recipe exactly as it drives `flm` itself; models still show as `*-FLM`.

Upstream has no tags or releases, so the package pins `main` at `3621edf` (2026-10-03). It is pre-alpha: `oflm version` reports `0.1.0`, and upstream says anything may change before a 1.0.

**What is open and what is not.** The package builds OFLM's open kernel sets from source in the Nix sandbox with this flake's `mlir-aie` 1.4.2 and `llvm-aie` Peano (upstream's pinned pair), no NPU needed: the dense/MoE sets for 11 models (12 recipe specs) and the 5 BERT embedding design sets ([Atomic-Germ/OpenFlowLM-Next#126](https://github.com/Atomic-Germ/OpenFlowLM-Next/pull/126) made the BERT export device-free upstream, so the package carries no patch for it). Every other model, including `llama3.2:1b`, still runs on FastFlowLM's closed engine libraries and kernels, which OFLM's tree ships alongside its own — that is why `pkgs.openflowlm` is unfree. Each kernel set is its own derivation (`openflowlm.kernels.passthru.sets`), built as a per-set CI matrix and cached in this flake's Cachix.

**Shared model store caveat.** With no `~/.config/oflm` and no
`OFLM_MODEL_PATH`, `oflm` falls back to FastFlowLM's `~/.config/flm` store, so FLM models it recognizes are reused without re-downloading. But OFLM treats a file whose size differs from its own manifest as missing and re-pulls it in place: on halo, FLM's `Qwen3.6-35B-A3B-NPU2/model.q4nx` (21.0 GB) differs from OFLM's manifest (23.2 GB), so pulling that model through lemonade would overwrite FLM's copy. To keep the stores separate, point `oflm` at its own directory the way lemonade itself understands, by setting `FLM_MODEL_PATH` (the name `oflm` also honours, as a legacy alias for `OFLM_MODEL_PATH`) for both `lemond` and your shell:

```nix
# StateDirectory creates /var/lib/oflm owned by lemonade.user when lemond
# starts; oflm itself does not create its store root.
systemd.services.lemond.serviceConfig.StateDirectory = "oflm";
systemd.services.lemond.environment.FLM_MODEL_PATH = "/var/lib/oflm";
environment.sessionVariables.FLM_MODEL_PATH = "/var/lib/oflm";
```

Models are then downloaded again. Without the session variable, an interactive `oflm pull`/`oflm run` still uses `~/.config/flm`. Creating `~/.config/oflm` or setting `OFLM_MODEL_PATH` also separates the stores, but lemonade reads a FLM model's `config.json` only from `FLM_MODEL_PATH` or FastFlowLM's own directories, so it can no longer find the model's max context length (measured on halo, for `lfm2-1.2b-FLM` and `llama3.2-1b-FLM`) and falls back to its 32768-token auto context cap (from lemonade's source).

Measured on halo only (single runs, not a benchmark) and what is untested: [docs/performance.md](docs/performance.md#openflowlm-next-oflm-on-strix-halo).

Packaging adapted from [@eyduh](https://github.com/eyduh)'s [fork](https://github.com/eyduh/OpenFlowLM-Next), who first reported the NPU-at-build-time blocker in [#147](https://github.com/noamsto/nix-amd-ai/issues/147).

## GAIA agent framework

[AMD GAIA](https://github.com/amd/gaia) is a Python agent framework that uses lemond as its inference backend, plus a built-in web UI. Upstream targets pip / electron installers, neither of which fits a NixOS host cleanly, and the Python dependency tree is large and fast-moving (weekly-ish releases, torch + transformers; the `[ui]` extra resolves to ~120 packages on x86_64-linux). The flake therefore ships a thin `uvx` wrapper rather than a from-source Nix build:

```bash
nix run .#gaia                     # launch the Agent UI (the default experience)
nix run .#gaia -- --cli            # interactive CLI chat
nix shell .#gaia -c gaia-mcp       # MCP bridge server
```

It exports the three console scripts the wheel declares — `gaia`, `gaia-cli`, `gaia-mcp`. 0.24.0 deleted the thirteen per-task agents (`analyst`, `blender`, `browser`, `code`, `doc-search`, `docker`, `docqa`, `emr`, `fileio`, `jira`, `routing`, `sd`, `summarize`), so there is no per-task command left to invoke: install the flagship agent with `gaia hub install gaia --trust` and it loads the matching `SKILL.md`.

The wrapper pre-sets `LEMONADE_BASE_URL=http://localhost:13305/api/v1` (matching the module's default `lemonade.port`); override the env var to point at a different host. Behind the scenes it runs `uvx --from "amd-gaia[ui]==<version>" <entry>` — so the first invocation downloads the wheel and ~120 packages into `~/.cache/uv` (~30 s, with progress visible) and subsequent runs reuse it.

Bump the pinned version in `pkgs/gaia/default.nix` by hand when a new GAIA release lands — that is by design, not an oversight. `scripts/check-updates.sh` reads the version from PyPI and the console scripts out of the published wheel's `entry_points.txt` (a version-only bump would otherwise ship wrappers for entry points upstream removed), reports both in the weekly update PR, and withholds that PR from auto-merge so the edit stays a human's.

## Validation and benchmarking

Verify that backends are correctly wired with `lemonade backends`; all AMD-applicable recipes should report `installed` (kokoro is intentionally skipped — Rust port, narrower use case). Illustrative output, not a captured run; versions follow the pins in this flake, and the `strata` row appears only with `hardware.amd-npu.strata.enable`:

```
Recipe              Backend     Status          Message/Version
flm                 npu         installed       <fastflowlm pin>
llamacpp            cpu         installed       <lemonade's bundled value>
                    rocm        installed       b11382
                    system      installed       -
                    vulkan      installed       b11382
sd-cpp              cpu         installed       <sd.cpp pin>
                    rocm        installed       <sd.cpp pin>
whispercpp          cpu         installed       <whisper.cpp pin>
                    vulkan      installed       <whisper.cpp pin>
strata              rocm        installed       -
```

Quick image-gen smoke test:

```bash
lemonade pull SD-Turbo
curl -s -X POST http://localhost:13305/api/v1/images/generations \
  -H 'Content-Type: application/json' \
  -d '{"model":"SD-Turbo","prompt":"a red apple on a wooden table","size":"512x512"}' \
  | jq -r '.data[0].b64_json' | base64 -d > out.png
```

With both `enableROCm` and `enableVulkan` set, sd-cpp's `auto` backend prefers Vulkan (as llamacpp and whispercpp do since 11.5.1), and lemond logs show no `Installing sd-server` line — sd-server runs directly from the nix store. To exercise ROCm, set `hardware.amd-npu.lemonade.settings.sdcpp.backend = "rocm";` (the config section is `sdcpp`, not `sd-cpp`).

The `.#benchmark` harness measures real decode throughput through a running `lemond`, compares it against a hardware-derived ceiling, and gates against silent CPU fallback:

```bash
nix run .#benchmark                                        # interactive TUI
nix run .#benchmark -- --no-tui --backend rocm Gemma-4-26B-A4B-it-GGUF   # headless / CI
```

`--no-tui` prints markdown and exits non-zero when a model falls below `--min-decode-tps` (default 5 t/s), reliably signalling CPU fallback. Full reference — wizard flow, modes (HTTP / MTP A/B / backend), the model picker, results columns and every headless flag: **[`pkgs/benchmark-go/README.md`](pkgs/benchmark-go/README.md)**. Recorded runs and their hosts: [`bench-logs/README.md`](bench-logs/README.md).

## Troubleshooting

### `amdxdna ... aie2_get_info: Not supported request parameter N` in dmesg/journald

Harmless. `aie2_get_info` handles the NPU's `GET_INFO` ioctl, and the mainline `amdxdna` driver implements only a subset of query types (AIE status/version/metadata, clock, hw-contexts). When userspace (`xrt-smi`, a system monitor, or the lemonade/FastFlowLM init path) probes a power/sensor/telemetry param the driver doesn't implement yet, it returns `-EOPNOTSUPP` and logs that `*ERROR*` line — often on a timer, so it repeats. NPU inference is unaffected. Upstream is filling in the missing queries (power reporting ~Linux 7.1, hwmon exposure tracked in [xdna-driver#323](https://github.com/amd/xdna-driver/issues/323)); a newer kernel makes the line disappear.

### Tauri desktop app: download progress is fragile when backgrounded

WebKitGTK suspends the network process for minimized, hidden or other-workspace windows, killing the SSE progress stream lemond uses for downloads at ~60–90 s. With our patch the download keeps running server-side and finishes, but the UI stops seeing progress until you refocus the window (and may need a refresh). For very large pulls, use the browser at `http://localhost:13305` or `lemonade pull <model>`; both survive backgrounding.

The desktop app is the only part of lemonade that pulls a Rust + npm build (and a crates.io cargo-vendor fetch). Headless hosts can skip it with `lemonade.desktopApp.enable = false;`; the pre-built app is also on the [binary cache](#binary-cache).

### Coding agents and client timeouts

Coding agents (Claude Code, opencode) ship large system prompts — 10k+ tokens once MCP servers, skills, and tool schemas are loaded. On a Strix Point iGPU, prompt processing runs at ~350 t/s, so the agent's first turn spends 25–35 s before the first token is emitted. Neither lemonade nor the agents send SSE keep-alive events during that silent window, and most clients close the socket after ~30 s, yielding:

```
[Info] (Process) srv  log_server_r: done request: POST /v1/chat/completions 127.0.0.1 200
[Error] (HttpClient) CURL error: Failed writing received data to disk/application
[Error] (WrappedServer) Streaming request failed: ...
```

Tracked upstream as [lemonade-sdk/lemonade#1364](https://github.com/lemonade-sdk/lemonade/issues/1364). Until that lands, this module sets `global_timeout` to 0 in the `defaults.json` it seeds for lemond (3600 with `enableVllm`) to disable its own 300 s upstream cap, which covers the variant where lemonade gives up on llama-server. The downstream client timeout remains a separate problem — best addressed by shortening the prompt or choosing a leaner agent.

**Practical guidance:**

- **Vulkan for short-prompt workloads.** Decode is ~26 % faster than ROCm; safe for chat UIs and ad-hoc prompts that stay roughly under 10k tokens, where prompt processing finishes well before the ~30 s client cutoff.
- **[pi](https://github.com/badlogic/pi-mono)** (Hugging Face's recommended local coding agent — see the [official docs](https://huggingface.co/docs/hub/en/agents-local)) is the best fit for this hardware. Its prompt is a fraction of Claude Code's and it's designed around llama.cpp-served local models.
- **Claude Code / opencode** are usable — strip down MCP servers, skills, and plugins to shrink the startup prompt.
- **Set an explicit output cap for thinking-on models.** With thinking on, reasoning tokens count against the client's output cap. A turn that reasons long ends with `finish_reason: "length"` mid-answer or mid-tool-call; the agent sees a truncated turn and nothing reports a server error. For pi, set `maxTokens` in `models.json` (pi defaults a custom model to 16,384 when unset). Qwen's guidance is 32,768 for general use; 32k–64k leaves headroom without letting a runaway turn hold a slot for long.
- **Field data (one Strix Halo host, Strata recipe through lemond, two concurrent pi sessions):** over 5,369 turns, output tokens were p50 316 / p95 2,823 / p99 6,775, and one turn hit exactly 16,384 — pi's default cap, not a server limit. The tail is rare but costs the whole turn. These numbers are specific to that host and workload.
- The Strata recipe does not currently report `reasoning_tokens` (#299), so a client cannot see how much of the cap thinking used.

## Performance notes

- Strix Point (gfx1150) Vulkan / ROCm / FLM tables, the Strix Halo NPU numbers and the backend recommendation: [docs/performance.md](docs/performance.md).
- `amd_iommu=off`, `iommu=pt` and CPU performance-governor tradeoffs: [docs/tuning-tradeoffs.md](docs/tuning-tradeoffs.md).
- GPU memory ceiling measurements: [docs/gpu-memory.md](docs/gpu-memory.md). ROCm numerics on RDNA3.5: [docs/rocm-gfx1151-numerics.md](docs/rocm-gfx1151-numerics.md).

## CI

- **Build**: On every push to `main` and every pull request, CI builds and caches the core packages (lemonade, the NPU stack, `ds4`, the ROCm backends) and the flake checks; every other package, including `strata` and `vllm-rocm`, is only evaluated, so enabling those compiles them locally
- **Update**: Weekly check for upstream releases, auto-creates PR with version bumps