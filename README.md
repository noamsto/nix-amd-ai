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
| `llama-cpp-rocm` | ROCm-accelerated llama.cpp backend | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `llama-cpp-rocm-gsqhalo` | `llama-cpp-rocm` built from the GSQHalo.cpp fork, opt-in via `llamaCppRocmPackage` | Built from [Aristo94/GSQHalo.cpp](https://github.com/Aristo94/GSQHalo.cpp) |
| `llama-cpp-vulkan` | Vulkan-accelerated llama.cpp backend, wrapped to use its own RADV driver ([#215](https://github.com/noamsto/nix-amd-ai/issues/215)); `.unwrapped` is the plain build | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `whisper-cpp-vulkan` | Vulkan-accelerated whisper.cpp backend, wrapped to use its own RADV driver ([#215](https://github.com/noamsto/nix-amd-ai/issues/215)); `.unwrapped` is the plain build | `pkgs.whisper-cpp.override { vulkanSupport = true; }` |
| `stable-diffusion-cpp-rocm` | ROCm-accelerated stable-diffusion.cpp backend | `pkgs.stable-diffusion-cpp.override { rocmSupport = true; }` |
| `ds4` | DeepSeek V4 inference engine, Strix Halo (`gfx1151`) ROCm backend (`ds4`, `ds4-server`, `ds4-bench`, `ds4-eval`, `ds4-agent`) | Built from [antirez/ds4](https://github.com/antirez/ds4) |
| `strata` | Qwen3.8-Flash-Next engine on TheRock ROCm 7.14.1, Strix Halo (`gfx1151`); opt-in lemond backend via `hardware.amd-npu.strata` ([section](#opt-in-strata-backend-strix-halo)) | Built from [Niko1221/Strata](https://github.com/Niko1221/Strata) |
| `gaia` | AMD GAIA agent framework launcher (`gaia`, `gaia-cli`, `gaia-mcp`) | `uvx` wrapper around [amd/gaia](https://github.com/amd/gaia) |
| `benchmark` | Multi-backend benchmark harness | `nix run .#benchmark` |

CPU backends for llamacpp / whispercpp / sd-cpp use vanilla nixpkgs packages (`pkgs.llama-cpp`, `pkgs.whisper-cpp`, `pkgs.stable-diffusion-cpp`) and are wired automatically when `enableLemonade = true`. The GPU backends track nixpkgs too; the `mtp` recipe — built-in MTP support added by lemonade [#1944](https://github.com/lemonade-sdk/lemonade/pull/1944) — fires on any nixpkgs llama.cpp past `b9175`. llama.cpp is pinned to **b11382**, which carries [ggml-org/llama.cpp#29761](https://github.com/ggml-org/llama.cpp/pull/29761)'s Qwen3.8-Flash-Next MTP sidecar support; on halo it gives **1.51× (Vulkan) / 1.74× (ROCm)** decode over MTP-off — see [`bench-logs/qwen38-flash-next-mtp-2026-10-04`](bench-logs/qwen38-flash-next-mtp-2026-10-04/).

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

## What the module configures

- Kernel modules (`amdxdna`)
- Udev rules for NPU device access
- PAM limits (unlimited memlock for NPU buffer allocation)
- XRT + plugin merged tree for runtime plugin discovery
- Lemonade systemd service with XRT/FLM/ROCm/Vulkan environment
- Environment variables (`XILINX_XRT`, `XRT_PATH`)
- Declarative backend wiring (both the `lemond` service and direct CLI usage receive the ROCm/Vulkan backend paths automatically)

### Why the module flags matter on NixOS

The lemonade source build deliberately doesn't bundle backend `llama-server` / `whisper-server` / `sd-server` binaries — it expects host-provided paths. The module exports the matching env vars from the `lemond` service `Environment` and the user session, then lemonade migrates them into `~/.config/lemonade/config.json`:

| Flag | What gets wired |
|---|---|
| `enableLemonade` | CPU recipes always-on: `llamacpp:cpu`, `whispercpp:cpu`, `sd-cpp:cpu` (when `enableImageGen`) |
| `enableROCm` | `llamacpp:rocm`, `llamacpp:system` (via `LEMONADE_GGML_HIP_PATH`), `sd-cpp:rocm` (when `enableImageGen`) |
| `enableVulkan` | `llamacpp:vulkan`, `whispercpp:vulkan`, `sd-cpp:vulkan` (when `enableImageGen`) |
| `enableVllm` (default false) | `vllm:rocm` from the `lemonade-sdk/vllm-rocm` prebuilt (requires `enableROCm`); pick the GPU target with `vllmGpuTarget` (`gfx1150`/`gfx1151`). Experimental, ~7.6 GB closure — see below |
| `enableImageGen` (default true) | Gates all `sd-cpp:*` packages; turn off for ~150 MB CPU / ~1.5 GB ROCm savings on headless LLM-only hosts |

Omni models (e.g. `LMX-Omni-*`) pull in two backends that need extra host plumbing the module wires automatically with `enableLemonade` ([#33](https://github.com/noamsto/nix-amd-ai/issues/33)): `whispercpp` resolves its writable runtime dir from the unit's `RuntimeDirectory`, and the runtime-downloaded kokoro TTS binary is a foreign prebuilt ELF, so the module enables `nix-ld` (its default libraries already cover koko's openssl + gcc-libs) and re-exports `NIX_LD*` into the `lemond` service. nix-ld is set via `mkDefault`, so hosts managing it themselves can opt out.

`enableVllm` wires the experimental `vllm:rocm` backend, repackaged from the
upstream `lemonade-sdk/vllm-rocm` prebuilt ([#63](https://github.com/noamsto/nix-amd-ai/issues/63)).
Building vLLM + ROCm from source isn't viable here — nixpkgs `rocmPackages`
trails ROCm 7.15 and lacks the Strix gfx targets — so we relocate their portable
Python + torch + TheRock-ROCm bundle instead (interpreter-patched, not
autoPatchelf'd, which would inject mismatched nixpkgs libs and segfault torch).
It's off by default and adds a ~7.6 GB closure with no binary-cache substituter.

Validated on gfx1150 (standalone and through lemonade's OpenAI API). The
`gfx1151` (Strix Halo) target builds and its `vllm-server` launches — torch and
vLLM import cleanly, so the packaging carries over — but no gfx1151 kernel has
run, because there is no Halo host to run it on. On gfx1150 our benchmarks
still put Vulkan ahead of ROCm and vLLM's batching doesn't help single-user
workloads, so `enableVllm` mainly matters on gfx1151 (where the
Vulkan-fills-VRAM-first freeze on X11 makes the ROCm path worthwhile) or for
vLLM-specific features.

Vanilla v10.5.0 ignores these env vars on NixOS for several reasons that this flake patches in-tree (see `pkgs/lemonade/default.nix:postPatch`, [issue #5](https://github.com/noamsto/nix-amd-ai/issues/5), upstream [lemonade-sdk/lemonade#1791](https://github.com/lemonade-sdk/lemonade/issues/1791)):

- `install_backend` short-circuits on `find_external_backend_binary` *before* the `no_fetch_executables` throw and the rocm-stable / TheRock runtime fetches, so user-supplied `*_bin` paths actually skip the entire download flow.
- The Linux ROCm `LD_LIBRARY_PATH` block is gated on the same check, so a nix-store `llama-server` keeps its RPATH-resolved libs instead of being shadowed by `~/.cache/lemonade/bin/.../lib`.
- `is_ggml_hip_plugin_available()` honors `LEMONADE_GGML_HIP_PATH` so the `system` llamacpp recipe stops being permanently `unsupported` on NixOS.
- `LEMONADE_WHISPERCPP_VULKAN_BIN` is added to the env-var migration table (upstream only mapped CPU/NPU for whispercpp).
- `ConfigFile::get_defaults` honors `LEMONADE_DEFAULTS_PATH`, so the module can seed backend bin paths from a store path instead of the hardcoded `/usr/share/lemonade/defaults.json` that NixOS can't populate (v10.7.0 dropped the env→config migration this replaced).
- The download SSE handler treats `sink.write` failure as a transient client disconnect rather than a cancel signal, so a backgrounded Tauri window doesn't kill an in-flight multi-GB download.

If `lemonade backends` reports a backend as `installed` but benchmarks report <5 t/s decode on a small model, you're on CPU — check that the matching `enable*` option is set and the host has been rebuilt.

### Runtime config: `lemonade.settings`

`LEMONADE_DEFAULTS_PATH` only seeds `~/.config/lemonade/config.json` on lemond's
**first** run — afterwards `ConfigFile::load` merges the packaged defaults
*under* the persisted file, so every key the module declares goes inert. Backend
bin paths survived that because they point at stable `/etc/lemonade/backends/*`
symlinks, but scalars did not: a host that first started lemond before enabling
`enableVllm` kept `global_timeout = 0`, which vLLM reads as its startup-readiness
budget and turns into zero poll attempts ([#68](https://github.com/noamsto/nix-amd-ai/issues/68)).

The lemond unit therefore re-applies the module-declared keys on every start,
leaving everything else to whatever the web UI persisted. `lemonade.settings`
rides the same path for keys the module has no dedicated option for:

> **Moved in lemonade 11.8.0:** `config.json` lives in the *config* dir
> (`$XDG_CONFIG_HOME/lemonade`, falling back to `~/.config/lemonade`), not the
> cache dir. lemond migrates an existing `~/.cache/lemonade/config.json` on
> first start — content is preserved and the old copy removed — so nothing is
> lost on upgrade. The cache dir still holds downloaded backends and models.

```nix
hardware.amd-npu.lemonade.settings = {
  max_loaded_models = -1;   # keep a small NPU model and a big GPU model resident together
  auto_evict = true;        # then let lemond reclaim on idle / VRAM pressure
};
```

`max_loaded_models` (default `1`) is what makes models take turns — raise or
unset it (`-1`) to keep several resident. `auto_evict` is a *separate*,
opt-in background reclaimer (default **off**) that unloads idle models and
sheds them once VRAM crosses `auto_evict_threshold_pct` (default `0.90`); it
pairs naturally with an unlimited `max_loaded_models`. Anything lemond's
`RuntimeConfig` validates is accepted. Values merge recursively over the
module's computed defaults, so overriding `llamacpp.args` does not drop the
sibling `llamacpp.*_bin` paths.

Per-*model* eviction knobs (`pinned`, `evict_idle_timeout`,
`downsize_idle_timeout`, `evict_weight_factor`, and a per-recipe `auto_evict`
override) live in lemond's separate `recipe_options.json`; set them with
[`lemonade.recipeOptions`](#per-model-recipe-options-lemonaderecipeoptions)
below.

Reconciliation only ever writes keys, never deletes them: dropping a key from
`settings` stops it being re-applied but leaves the last value in the persisted
config. Set it back to the value you want rather than removing the line.

Two keys are *not* reachable this way. `lemond` persists `--port` and `--host`
into `config.json` itself on every start, after the reconcile hook has run, so
`settings.host` / `settings.port` are silently overwritten — use the dedicated
`lemonade.host` and `lemonade.port` options instead. That same write also
rewrites the file through a fresh `ofstream` + rename, which resets its mode to
`0644` on every start; the hook preserves whatever mode it finds, but it cannot
hold the file tighter than lemond leaves it.

Lemonade >=11.5.0 stopped sending `Access-Control-Allow-Origin: *` by
default, so non-loopback browsers get a 403 `Origin not allowed` unless their
origin is listed in `LEMONADE_ALLOWED_ORIGINS`. Like host/port, this is env-only
— there is no config.json key, so `lemonade.settings` cannot reach it; set
`lemonade.allowedOrigins` instead. Loopback origins and non-http(s) desktop
schemes are always allowed, so this only matters once `lemonade.host` is
bound to something a LAN or remote browser can reach; the module warns if
you set the former without the latter.

### Per-model recipe options: `lemonade.recipeOptions`

`lemonade.settings` reaches lemond's global runtime config; the per-model
knobs — most usefully `pinned`, which exempts a model from auto-eviction — live
in a different file, `recipe_options.json`, keyed by canonical model ID. That
file has no packaged defaults layer: lemond reads it as bare user state, so the
module merges its entries into it on every `lemond` start rather than seeding
it once.

```nix
hardware.amd-npu.lemonade.recipeOptions = {
  "builtin.Gemma4-2B-FLM" = { pinned = true; };
  "builtin.Qwen3.6-30B-GGUF" = { evict_idle_timeout = 900; };
};
```

Keys are canonical IDs, not the bare names `lemonade list` prints: prefix a
listed name with `builtin.` for the built-in registry or `user.` for a model
registered through the web UI or `lemonade.customModels`. A bare key silently
matches nothing. `pinned = true` is the mixed NPU + GPU case from
[#67](https://github.com/noamsto/nix-amd-ai/issues/67): it keeps the small NPU
model resident without having to raise the global `max_loaded_models` cap.

The five eviction keys — `pinned`, `auto_evict`, `evict_idle_timeout`,
`downsize_idle_timeout`, `evict_weight_factor` — are typed, so a wrong type
fails at eval. Every other recipe option (`ctx_size`, `llamacpp_args`, …)
passes through unchanged, which is also why a typo of a known key is treated as
an unknown option and ignored by lemonade rather than rejected.

The merge is per key and module keys win on conflict, so a `ctx_size` or args
value the web UI set for the same model survives alongside the declared pin.
For `user.<name>` models, `customModels.<name>.recipe_options` already supplies
a lower-precedence default; this option is the higher layer and also the only
declarative path for built-ins.

As with `lemonade.settings`, the merge only ever writes keys, never deletes
them: dropping a key stops it being re-applied but leaves the last value in
the persisted file. A key explicitly set to `null` is pruned rather than
written.

### Declarative models: `lemonade.models`

Models to keep downloaded, named as `lemonade list` reports them:

```nix
hardware.amd-npu.lemonade.models = [
  "Qwen3.5-4B-MTP-GGUF"
  "llama3.2-1b-FLM"
];
```

A `lemond-models` unit pulls whatever is missing. Models already on disk are
skipped, so re-activating an unchanged list costs nothing.

**Activation does not block.** The unit is `Type=simple`, so systemd calls it
started the moment it forks and `nixos-rebuild switch` returns immediately
rather than sitting on multi-GiB downloads. Follow the pull with:

```bash
journalctl -fu lemond-models
```

It has to be a unit rather than an activation script because `lemonade pull` is
an HTTP client — it needs `lemond` already answering, which is also why the
unit waits for `lemonade status` before doing anything. A model that fails to
pull is logged and skipped, so one bad name can't block the rest of the list.

To make the set on disk *exactly* the declared one, add:

```nix
hardware.amd-npu.lemonade.pruneUnlistedModels = true;
```

This deletes downloaded models the list doesn't mention. It's off by default —
models are large and slow to re-fetch, and anything pulled by hand for an
experiment would vanish on the next activation. It requires a non-empty
`lemonade.models`, so an empty list can never be read as "delete everything".

### Speculative MTP: `lemonade.customModels`

The `mtp` label makes lemond pass `--spec-type draft-mtp`, which needs the model
to carry an MTP draft head. For Qwen3.8-Flash-Next the head is a **separate**
self-contained GGUF, declared as the `draft` checkpoint alongside `main`:

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

The `draft` head must be the **ggml-org** one, not unsloth's `MTP/` copy — the
latter was built for the superseded fork and aborts stock b11382 (see the
bench-logs README). `--spec-draft-n-max 3` is the best setting measured here;
4 is slower than 3 (best of {2,3,4} on halo, gfx1151, Vulkan; this exact
q8_0-KV / 131K-ctx config was not benchmarked).

The example is deliberately unchanged by the #237 tuning pass. On halo (gfx1151,
Vulkan, 2026-10-04) a `--spec-draft-p-min` of 0.6–0.85 raised draft acceptance
(0.42 → 0.75–0.92 at n-max 3) but not decode t/s, and n-max 4 and 5 did not beat
3. Those rows were taken on a loaded host, so the result is provisional; see
[`bench-logs/qwen38-flash-next-mtp-tuning-2026-10-04`](bench-logs/qwen38-flash-next-mtp-tuning-2026-10-04/README.md).

### Tauri desktop app: download progress is fragile when backgrounded

WebKitGTK suspends the network process for windows that are minimized, hidden, or moved to another workspace. That kills the SSE progress stream lemond uses for downloads at ~60–90 s. Without our patch, that nuked the whole download mid-flight. With the patch, the download keeps running server-side and finishes regardless — but the UI stops seeing progress until you refocus the window (and may need a refresh to pick up the result). For very large pulls, prefer the regular browser at `http://localhost:13305` or `lemonade pull <model>` from the CLI; both survive backgrounding cleanly.

The desktop app is the only part of lemonade that pulls a Rust + npm build (and a crates.io cargo-vendor fetch). Headless/server hosts that only need the `lemond` API + CLI can skip it entirely with `lemonade.desktopApp.enable = false;` — this drops the Tauri build path from the closure. (The pre-built app is also on the [binary cache](#binary-cache), so configuring the substituter avoids building it from source in the first place.)

## Opt-in GSQHalo.cpp ROCm backend

`pkgs.llama-cpp-rocm-gsqhalo` is [Aristo94/GSQHalo.cpp](https://github.com/Aristo94/GSQHalo.cpp) (`5fc881b`) built through this flake's `llama-cpp-rocm`. To serve the `llamacpp-rocm` backend with it instead of stock llama.cpp:

```nix
hardware.amd-npu.llamaCppRocmPackage = pkgs.llama-cpp-rocm-gsqhalo;
```

The default is the stock `llama-cpp-rocm`, so existing hosts are unchanged; `rocmGpuTargets` applies to either. On one Strix Halo (gfx1151) host the fork with `-lzm on-direct -ub 8192 -b 8192 --spec-draft-p-min 0.3 -ctk f16 -ctv f16` cut agent-replay time 35 % against stock Vulkan llama.cpp on Qwen3.8-Flash-Next (Vulkan ran at `-ub 2048`; [`bench-logs/qwen38-flash-next-gsq-tuning-2026-10-06`](bench-logs/qwen38-flash-next-gsq-tuning-2026-10-06)). Those flags are what was measured, not defaults the module sets. `-lzm` is fork-only: stock llama.cpp rejects it, so don't pass it to a model served by the stock backend.

## Opt-in Strata backend (Strix Halo)

[Strata](https://github.com/Niko1221/Strata) (pinned v0.1.40.2 `e8ca9af`, built against TheRock ROCm 7.14.1) is a Qwen3.8-Flash-Next engine for Strix Halo. The module serves it behind lemond through a native `strata` recipe carried as a small patch in `pkgs/lemonade`: lemond starts a small shim instead of `ds4-server`, so clients use lemond's normal API and load/unload. The model is listed as `user.Qwen3.8-Flash-Next-Strata` (option `modelName`) under lemond's "Strata (experimental)" recipe name. Because the recipe is its own, the `ds4` recipe stays free for a real DeepSeek V4 model. Measurements and the build are in [`bench-logs/qwen38-flash-next-strata-2026-10-06`](bench-logs/qwen38-flash-next-strata-2026-10-06/README.md).

```nix
hardware.amd-npu = {
  gpuTarget = "gfx1151";
  strata = {
    enable = true;
    model = "/var/lib/models/…/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf";
    profile = "defaults"; # or "fast"
  };
};
```

With only `enable` and `model`, the module provisions the rest. `strata.prepare` renders a oneshot `strata-prepare` unit that builds `pack` and the MTP runtime in `/var/lib/strata` with the pinned Strata's own tools, and `vision.mmproj` defaults to a pinned `mmproj-Qwen3.8-Flash-Next-BF16.gguf` fixed-output fetch. Each derived output has a stamp recording the pinned Strata and ggml revisions, the model path and the sibling shard sizes: an unchanged run is a no-op, a changed model path rebuilds the pack, and a Strata or ggml revision bump rebuilds both (the pinned-revision bump leaves the literal `version` alone, so the stamps key on the pins, not the version). The pack tool is CPU-only and reads the shards in place; the first run downloads 4.9 GiB of BF16 tensors for the MTP draft. The shim refuses a load until both stamps exist, so a load that races the unit gets a clear message instead of an engine that cannot open its pack.

Setting `pack`, `mtp` and `vision.mmproj` explicitly keeps your own artifacts; the module then renders no unit and passes those paths through as before. `strata.prepare.enable` is `null` (the default: run the unit only when `pack` and `mtp` are at their defaults), `true` (force it on; then `pack`/`mtp` must stay at defaults) or `false` (disable it; then set both paths explicitly). `strata.prepare.user` defaults to `lemonade.user`, so the engine can read the outputs.

`sampling` sets the decoding defaults for requests that send none: strata-server decodes greedily otherwise. The default is Qwen's recommended thinking set (`temperature` 0.6, `top_p` 0.95, `top_k` 20), because strata-server takes one set rather than one per thinking mode and lemond serves the model with thinking on. A request's own fields win, so `temperature: 0` stays greedy. For a non-thinking deployment set `temperature = 0.7; top_p = 0.8; top_k = 20; presence_penalty = 1.5;`; setting every key to `null` restores greedy. Keys merge individually, so `sampling.top_k = 40;` keeps the other defaults.

`profile = "defaults"` is Strata's setup defaults. `"fast"` is the maintainers' fast configuration: it turns on bit-changing switches, and its quality has not been checked (no KL or perplexity). The bench README has the measured speed difference between the two, on halo only.

**Costs.** An 8.9 GiB Nix closure (the pinned SDK), built with `-march=native` so the output is specific to the building host's CPU. It is `gfx1151` only and experimental upstream. CI does not build it, so enabling it compiles it locally.

The `strata-prepare` pack step is CPU-only. Measured on halo on 2026-10-08 over the same UD-IQ4_XS shards: `iq_pack.py --compat-bf16` took 8 s wall and about 1.2 GiB peak RSS for a 1.4 GiB pack, reading the three GGUF shards in place. The MTP step is the slow part of the first run: 4.9 GiB of tensors downloaded (SHA-256-checked against the pinned checkpoint revision), then a 0.8 GiB runtime directory; the raw tensors are removed after packing, so they are downloaded again only if the pinned revision changes.

**Memory.** About 67 GiB of GTT at 131072 context on halo (bench README). lemond counts loaded models per slot, not memory, so it will load Strata next to another large model if a slot is free: keep one LLM slot (`lemonade.settings.max_loaded_models`) or unload the resident model first. If a load fails, lemond evicts every loaded model, pinned ones included, and retries once.

**Limits behind lemond.** Images must be sent as `data:` URLs; file paths, `file://` URLs and http(s) URLs are refused (a request using one fails with a 400), since lemond forwards client requests as-is. Engine arguments set per model through lemond are limited to tuning flags (`--prefill`, `--spec`, `--spec-min-p`, `--mtp-q4`, `--kv`, `--lookup-chain`, `--vram-reserve-mib`).

**Timeout.** The `strata` backend carries its own fixed 1 h readiness timeout, so enabling Strata leaves lemond's `global_timeout` at 0 (no request cutoff) and `global_timeout` no longer changes the strata startup wait. vLLM still raises `global_timeout` to 3600 for its own startup wait.

Unloading the model or stopping lemond ends the engine's whole process group within lemond's stop window.

## GPU memory headroom

The iGPU draws GPU memory from the GTT pool. By default the kernel exposes
~27 GB addressable, which covers the 17–22 GB models this flake targets on a
64 GB Strix Point host — so **leave these options unset there; they're a no-op.**

On a **128 GB Strix Halo** host you need to raise the ceiling to expose the
large unified pool for big models. The module takes sizes in **GiB** and
computes the `ttm` page counts for you (`pages = GiB × 262144`):

```nix
hardware.amd-npu.gpuMemory = {
  ttmSizeGiB = 96;        # GTT pool ceiling  → ttm pages_limit
  pagePoolSizeGiB = 96;   # pre-cached pool   → ttm page_pool_size
};
```

This emits `options ttm pages_limit=25165824 page_pool_size=25165824` via
`boot.extraModprobeConfig`, and is the pair the measurements below were taken
on — the Halo host runs `page_pool_size` equal to `pages_limit`, not a fraction
of it.

**`ttmSizeGiB` alone sets the ceiling, and the arithmetic is exact.** Measured
on a 128 GB Halo host (ASUS ROG Flow Z13 GZ302EA, Ryzen AI MAX+ 395, NixOS
26.11, kernel 7.1.0) running `ttm.pages_limit=25165824`:

```
$ cat /sys/class/drm/card1/device/mem_info_gtt_total
103079215104        # 96.00 GiB exactly = 25165824 × 4096
```

ROCm agrees — llama.cpp's HIP backend reports `Total VRAM: 98304 MiB`. Nothing
else is needed to reach the ceiling.

> **Do not also set `amdgpu.gttsize`.** Several third-party Halo guides tell you
> to — including [`antirez/ds4`'s `STRIXHALO.md`](https://github.com/antirez/ds4/blob/main/STRIXHALO.md),
> which the ds4 section below links — but ROCm#5595 warns against setting
> `gttsize` and `pages_limit` together, and the measurement above shows
> `pages_limit` is sufficient on its own.

Pick `ttmSizeGiB` by the largest model you actually intend to load:

| `ttmSizeGiB` (128 GB host) | When it's right |
| ---: | --- |
| ~96 | General use. Leaves ~32 GB for CPU/OS. Comfortable to ~70 GB models — a 67 GB Q4_K_M sat at `mem_info_gtt_used` ≈ 66 GB. |
| ~120 | Models of 75 GiB+. The OS margin gets thin, but the alternative is a kernel fallback or a failed load. |

The 120 row is not theoretical: at a 96 GiB ceiling, loading the 80.76 GiB
DeepSeek-V4-Flash GGUF through `ds4` still ran, but fell back from fp16 to q8
kernels for want of room —

```
ds4: ROCm q8 fp16 cache budget exhausted; using q8 kernels
     (request=64.00 MiB cached=3.34 GiB free=4.80 GiB reserve=4.80 GiB total=96.00 GiB)
```

**Leave RAM headroom** — don't set `ttmSizeGiB` to your full physical RAM; the
CPU and OS still need their share.

**`pagePoolSizeGiB` is unmeasured.** `page_pool_size` only pre-allocates inside
the ceiling, and three sources say `pages_limit` alone is sufficient — the Strix
Halo wiki ("in theory you could set this to 0"), `hellas-ai/nix-strix-halo`,
and AMD's `amd-ttm` utility. None of that is an A/B on this hardware, so the
option stays documented rather than deprecated, and the example above sets it
equal to `ttmSizeGiB` because that is the configuration the numbers came from —
not because the ratio has been shown to matter. See #42.

Halo measurements above contributed by [@expelledboy](https://github.com/expelledboy) (#42).

## Tuning tradeoffs we don't automate

### `amd_iommu=off` would kill the NPU

The Strix Halo wiki suggests `amd_iommu=off` for a small memory-read speedup.
It is not small, and on a compute-bound prefill it is not a memory-read effect:
peonist-ai measured the IOMMU costing 13-16% of prefill on their gfx1151 host,
by way of a power budget the translation machinery spends and the shaders then
do not get. Their numbers, mechanism, and caveats are in
[halogen-flash-teardown.md](docs/halogen-flash-teardown.md); none of it is
reproduced here, and they never measured Translated mode, which is what our
hosts run.

**Do not do this on a host that uses the NPU.** amdxdna needs the IOMMU present
for PASID; with `amd_iommu=off` there is no IOMMU at all and the NPU dies.
`amd_iommu=off` is only viable on a GPU-only host that has given up XDNA.

`enableNPU` asserts on this, because the param does not always come from the
line you wrote: any module in the closure can contribute to `boot.kernelParams`,
and Jovian-NixOS ships `amd_iommu=off` in the SteamOS cmdline defaults that
`jovian.steamos.useSteamOSConfig` turns on. Enabling Steam Gaming Mode on an NPU
host is enough to do it. To see the merged list:

```console
$ nix eval --json .#nixosConfigurations.<host>.config.boot.kernelParams
```

You also don't need it for large-model headroom, which is the usual reason
people reach for it. The 128 GB Halo host measured above boots
`iommu.passthrough=0` — full IOMMU translation, the demanding case — with the
NPU driver loaded, and still loads both a 67 GB llama.cpp model and an 80.76 GiB
`ds4` model into the GTT pool.

The IOMMU default-domain *mode* is a separate knob. amdxdna historically
required *Translated* mode (SVA/PASID), so the module used to pin
`iommu.passthrough=0`. Since the June 2026 amdxdna fix (upstream `5b96159`,
"skip PASID tag in non-SVA mode") the driver no longer tags DMA with an invalid
PASID under an identity default domain, so the NPU works with `iommu=pt` too.
The module no longer forces the mode — it leaves the kernel default (Translated
on NixOS), and hosts that want passthrough can set `iommu=pt` themselves.

> **Don't expect a prefill win from `iommu=pt`.** peonist-ai's A/B makes
> passthrough the *slow* arm: it measured `iommu=pt` at 385 tok/s against 460
> with the IOMMU off entirely, on more package power and lower shader clocks.
> If that generalises, passthrough keeps the NPU alive without recovering the
> prefill that `amd_iommu=off` buys. Unmeasured here, and unmeasured against
> Translated anywhere.

### CPU performance tuning (not implemented — pending A/B)

The wiki recommends biasing the CPU to `performance` (governor + HWP boost) for
+3% memory bandwidth / +5–8% `pp512`. We don't wire this, because on a
shared-TDP APU the tradeoff is murky:

- There's **no direct CPU-governor → GPU-clock link** — the iGPU has its own
  clock domain. Pinning CPU cores to `performance` doesn't raise GPU clocks.
- On shared package power, forcing the CPU to max frequency **steals TDP from
  the iGPU** during bandwidth-bound decode — a bounded, possibly net-negative
  lever.
- The knob actually aimed at decode is the **C-state latency floor**
  (`/dev/cpu_dma_latency`), which keeps the fabric/memory subsystem clocked;
  the governor is not.
- Prefill (`pp512`) does have a CPU component, so the wiki's prefill claim is
  plausible — for prefill, not decode.

It's left out until an A/B on an idle/AC host (governor pinned `performance`)
confirms whether the wiki's numbers reproduce on Strix Point. Tracked in
[#19](https://github.com/noamsto/nix-amd-ai/issues/19).

## Troubleshooting

### Using an flm-compatible runtime

`hardware.amd-npu.fastflowlm.package` (default `pkgs.fastflowlm`) selects the
runtime that `enableFastFlowLM` installs and lemonade drives. The module wraps it
with the XRT `LD_LIBRARY_PATH`, links its main program (`meta.mainProgram`, which
need not be `flm`) at `/etc/lemonade/backends/flm-npu`, and seeds
`flm.npu_bin = "/etc/lemonade/backends/flm-npu"`. Lemonade resolves FLM through
`flm.npu_bin` first (or the `LEMONADE_FLM_NPU_BIN` environment variable), and only
then looks for a literal `flm` on `PATH`. A path-valued `npu_bin` also drops
lemonade's expected-version check, so the `backend_versions.json` pin to
`pkgs.fastflowlm` does not flag another runtime as needing an update.

`flm.flm_bin` is **not** a config key: `lemonade config set flm.flm_bin ...` is
accepted silently and has no effect. Use `flm.npu_bin`.

The wiring is verified by an eval check only. `pkgs.openflowlm` is the one
alternative tested on hardware; see
[OpenFlowLM-Next](#openflowlm-next-oflm).

### OpenFlowLM-Next (`oflm`)

[OpenFlowLM-Next](https://github.com/Atomic-Germ/OpenFlowLM-Next) is a
community fork of FastFlowLM that replaces some of its closed NPU kernels with
kernels built from source. Use it in place of `pkgs.fastflowlm`:

```nix
hardware.amd-npu.fastflowlm.package = pkgs.openflowlm;
```

plus `"openflowlm"` in the unfree predicate (see [Usage](#usage)). Lemonade
drives `oflm` through its `flm` recipe exactly as it drives `flm` itself;
models still show as `*-FLM`.

Upstream has no tags or releases, so the package pins `main` at `3621edf`
(2026-10-03). It is pre-alpha: `oflm version` reports `0.1.0`, and upstream
says anything may change before a 1.0.

**What is open and what is not.** The package builds OFLM's open kernel sets
from source in the Nix sandbox with this flake's `mlir-aie` 1.4.2 and
`llvm-aie` Peano (upstream's pinned pair), no NPU needed: the dense/MoE sets
for 11 models (12 recipe specs; `gemma3-12b`'s set is overwritten by
`gemma3-4b`'s, an upstream naming quirk) and the 5 BERT embedding design sets.
The BERT export is device-free upstream, merged as
[Atomic-Germ/OpenFlowLM-Next#126](https://github.com/Atomic-Germ/OpenFlowLM-Next/pull/126),
so the package carries no patch for it.
Every other model, including `llama3.2:1b`, still runs on FastFlowLM's closed
engine libraries and kernels, which OFLM's tree ships alongside its own —
that is why `pkgs.openflowlm` is unfree. Each kernel set is its own derivation
(`openflowlm.kernels.passthru.sets`) and `openflowlm.kernels` is a cheap join
over them, built in parallel locally and as a per-set CI matrix
(`kernel-sets.json`), cached in this flake's Cachix.

A model file whose size differs from OFLM's manifest is treated as missing;
upstream prints that warning to stderr, keeping the `oflm list --json` stdout a
single JSON document for lemonade to parse (upstream
[#133](https://github.com/Atomic-Germ/OpenFlowLM-Next/issues/133)).

**Shared model store caveat.** With no `~/.config/oflm` and no
`OFLM_MODEL_PATH`, `oflm` falls back to FastFlowLM's `~/.config/flm` store, so
FLM models it recognizes are reused without re-downloading. But OFLM treats a
file whose size differs from its own manifest as missing and re-pulls it in
place: on halo, FLM's `Qwen3.6-35B-A3B-NPU2/model.q4nx` (21.0 GB) differs from
OFLM's manifest (23.2 GB), so pulling that model through lemonade would
overwrite FLM's copy. To keep the stores separate, point `oflm` at its own
directory the way lemonade itself understands, by setting `FLM_MODEL_PATH`
(the name `oflm` also honours, as a legacy alias for `OFLM_MODEL_PATH`) for
both `lemond` and your shell:

```nix
# StateDirectory creates /var/lib/oflm owned by lemonade.user when lemond
# starts; oflm itself does not create its store root.
systemd.services.lemond.serviceConfig.StateDirectory = "oflm";
systemd.services.lemond.environment.FLM_MODEL_PATH = "/var/lib/oflm";
environment.sessionVariables.FLM_MODEL_PATH = "/var/lib/oflm";
```

Models are then downloaded again. Without the session variable, an
interactive `oflm pull`/`oflm run` still uses `~/.config/flm`. Creating
`~/.config/oflm` or setting `OFLM_MODEL_PATH` instead also separates the
stores, but lemonade reads a FLM model's `config.json` only from
`FLM_MODEL_PATH` or FastFlowLM's own directories, so it can no longer find
each model's max context length (measured on halo, for `lfm2-1.2b-FLM` and
`llama3.2-1b-FLM`) and falls back to its 32768-token auto context cap (from
lemonade's source).

Measured on halo only (Ryzen AI MAX+ 395, XDNA2 NPU, 8 columns), 2026-09-28,
with the module-wrapped binary:

| check | result |
|---|---|
| `oflm validate` | ready, 8 columns, firmware OK |
| `llama3.2:1b` chat (closed kernels) | 63.5 tok/s decode, 100 tok/s prefill (43-token prompt, 128 tokens out) |
| `lfm2:1.2b` chat on sandbox-built open kernels | packaged `LFM2-1.2B-NPU2/open_kernels` set selected; coherent output; 35.9 tok/s decode, 40.6 tok/s prefill (17-token prompt, 128 tokens out) |
| `all-minilm:l6-v2` embeddings on sandbox-built BERT set | 384-dim, unit-norm, finite; cosine 0.70 for two paraphrases vs −0.03 for an unrelated pair |
| lemonade 11.9.0 via `LEMONADE_FLM_NPU_BIN` | flm backend `installed` at `v0.1.0` (not flagged for update), 44 FLM models listed, `llama3.2-1b-FLM` chat served by `oflm serve` |

These are single runs, not a benchmark, and are not comparable to the
FastFlowLM numbers elsewhere in this README.

**Not tested:** the other 10 open-kernel models and 4 BERT sets on hardware;
any host other than halo (Strix Point, Krackan); `oflm add` / `q4nx-build` and
OFLM's Python utilities (not built here: `OFLM_BUILD_UTILITIES=OFF`);
lemonade's embeddings route with OFLM's BERT models.

Packaging adapted from [@eyduh](https://github.com/eyduh)'s
[fork](https://github.com/eyduh/OpenFlowLM-Next), who first reported the
NPU-at-build-time blocker in [#147](https://github.com/noamsto/nix-amd-ai/issues/147).

### FLM models don't appear / `flm:npu` reports "not installed" after enabling FastFlowLM

Lemonade v10.10.0 stopped auto-discovering a `flm` on `PATH`; it now only looks
there when `flm.prefer_system` is set in `config.json`. Without it, `lemond`
ignores the nix-provided `flm`, marks the NPU backend `installable`/"not
installed", and lists no FLM models even after `flm pull`. The module now seeds
`flm.prefer_system = true` (with `enableFastFlowLM`), so fresh installs work.

A **cached `~/.config/lemonade/config.json` wins over that seed** (lemonade merges
user config over defaults), so hosts that ran an older lemonade keep the stale
`prefer_system: false`. Fix an existing host once, after rebuilding, by deleting
the cached config so the module's defaults reseed it:

```bash
rm ~/.config/lemonade/config.json
sudo systemctl restart lemond
```

See [#62](https://github.com/noamsto/nix-amd-ai/issues/62).

### `amdxdna ... aie2_get_info: Not supported request parameter N` in dmesg/journald

Harmless. `aie2_get_info` handles the NPU's `GET_INFO` ioctl, and the mainline `amdxdna` driver implements only a subset of query types (AIE status/version/metadata, clock, hw-contexts). When userspace (`xrt-smi`, a system monitor, or the lemonade/FastFlowLM init path) probes a power/sensor/telemetry param the driver doesn't implement yet, it returns `-EOPNOTSUPP` and logs that `*ERROR*` line — often on a timer, so it repeats. NPU inference is unaffected. Upstream is filling in the missing queries (power reporting ~Linux 7.1, hwmon exposure tracked in [xdna-driver#323](https://github.com/amd/xdna-driver/issues/323)); a newer kernel makes the line disappear.

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

## ds4 (DeepSeek V4 on Strix Halo)

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

All numbers measured on Strix Point (gfx1150, Radeon 890M iGPU, 64 GiB DDR5-5600). Prompt 256 tokens, generation 128 tokens, 3 iterations after 1 warmup.

> **⚠️ The ROCm rows below were measured on a numerically broken backend.** gfx1150 is hit by the same RDNA3.5 host-access bug as gfx1151: on this host, ROCm reads perplexity 250,459 against a CPU reference of 385 for the very Gemma-4-26B-A4B model benchmarked here (and 1,638 vs 6.79 for Qwen3.5-4B), while CPU and Vulkan are correct. The throughput figures are real, but they time a backend producing garbage, so the ROCm-vs-Vulkan comparison is not a choice worth making from these numbers. Upstream has since fixed the underlying regression (`d4389a4d`, [ggml-org/llama.cpp#28604](https://github.com/ggml-org/llama.cpp/issues/28604)), and this flake's llama.cpp pin (b11382) is past that revert, so no patch is carried anymore. The rows below are left in place, unrevised, until they can be re-measured on the fixed build. Vulkan and FLM rows are unaffected. See [docs/rocm-gfx1151-numerics.md](docs/rocm-gfx1151-numerics.md).

### Large: Gemma-4-26B-A4B-it-GGUF (~15.7 GB, via `llama-bench`, llama.cpp b8770)

| Metric | ROCm | Vulkan | Winner |
| ------ | ---- | ------ | ------ |
| Prefill (pp512) | 360 ± 18 t/s | 370 ± 3 t/s | Vulkan (+3%, within noise) |
| Decode (tg128)  | 13.86 ± 0.18 t/s | 17.52 ± 0.33 t/s | Vulkan (+26%) |

### Mid-size, chat-shaped: Qwen3.5-9B (same family on all three backends)

| Backend | Model | TTFT (s) | Decode (t/s) |
| ------- | ----- | -------: | -----------: |
| Vulkan (llamacpp:vulkan) | `Qwen3.5-9B-GGUF` (UD-Q4_K_XL) | 1.36 | 12.9 +/- 0.1 |
| ROCm (llamacpp:rocm)     | `Qwen3.5-9B-GGUF` (UD-Q4_K_XL) | 1.69 | 10.8 +/- 0.1 |
| FLM (flm:npu)            | `qwen3.5-9b-FLM`               | 4.17 | 11.9 +/- 4.5 |

Notes: FLM's TTFT is dominated by a one-off NPU compile-to-cache; steady-state decode is the useful number. FLM's GGUF-vs-proprietary format means quantization isn't bit-identical to the llamacpp row, so treat these as same-family, not same-weights.

### Strix Halo (gfx1151 / XDNA2 NPU5): NPU measured

The tables above are Strix Point. These rows are from a Strix Halo host: ASUS ROG Flow Z13 (GZ302EA), Ryzen AI MAX+ 395, 128 GB, NixOS 26.11, kernel 7.1.0 with in-tree `amdxdna` 0.8, NPU firmware 1.1.2.65, `fastflowlm` 0.9.43. These figures run ahead of community Strix Point numbers for the same model, but the cause is not established here and nothing below depends on it. (It is not the column count: Strix Point, Krackan and Halo are all XDNA2 with the same 8-column array, as noted above for Krackan.)

| Test | Result |
| ---- | ------ |
| `flm validate` | rc=0, 8-column NPU, FW 1.1.2.65, `Memlock Limit: infinity` |
| Llama-3.2-1B (q4nx, `--pmode performance`) | **~49–50 t/s** decode |
| Llama-3.1-8B | ~8 t/s decode |
| Package power (RAPL), idle → 1B inference | 5.1 W → 19.5 W (**+14.4 W**, includes CPU serving overhead) |
| **NPU 1B + iGPU ROCm 7B concurrently** | NPU ~40 t/s, **iGPU 37.1 t/s (full speed, no degradation)**, 36.2 W total |

The concurrency row is the interesting one: an NPU workload running alongside an iGPU ROCm workload costs the iGPU nothing measurable and costs the NPU about 20%. That is a genuine low-power co-processor for small models while the iGPU handles 7B and up — not a way to make one model faster.

**The NPU niche on Halo is genuinely small models (1–3B).** At 8B the NPU manages ~8 t/s while the iGPU runs the same class of model several times faster, so the NPU is a power and concurrency play, never a throughput win. Route big models to Vulkan/ROCm and keep the NPU for the small resident one.

**Firmware on kernel ≥7.0 needs no DKMS.** In-tree `amdxdna` prefers `amdnpu/17f0_11/npu_7.sbin` (→ `1.1.2.65`) over the default `npu.sbin` (→ `1.0.0.166`), so FastFlowLM's ≥1.1.0.0 requirement is met out of the box. Check with `cat /sys/class/accel/accel0/device/fw_version`.

**Recommendation:**

- **General LLM inference (7B–26B Q4):** use **Vulkan**. On Strix Point 890M with llama.cpp b8770, Vulkan wins decode at every size tested and ties or wins prefill. The previous "ROCm for prefill-heavy" advice no longer holds now that ROCm targets gfx1150 natively (the gfx1102 Tensile arch-logic was apparently more tuned than gfx1150's is today).
- **Power-budget / idle-GPU scenarios:** use **FLM/NPU** — decode is competitive with Vulkan and offloads the GPU, but the compile-on-first-load TTFT is noticeable.
- **ROCm** is kept installed as a fallback and for ecosystem tooling (`rocminfo`, profiling, HIP apps); re-evaluate when newer rocBLAS/Tensile logic for gfx1150 lands.
- **RDNA3.5 iGPUs needed a patch to be numerically correct, until upstream
  fixed it.** Stock `llamacpp:rocm` returned near-random tokens on both
  chips — perplexity 1334 on gfx1151 and 1638 on gfx1150, where CPU and Vulkan
  both give 6.81. Cause: RDNA3.5 parts report as integrated GPUs, so ggml let
  tensors live in host memory for the GPU to read directly, which hands back
  wrong data on them. This flake used to carry a widened form of
  [llama.cpp#28211](https://github.com/ggml-org/llama.cpp/issues/28211)'s
  `865374bb` fix (gfx1151-only upstream at the time) covering the whole
  RDNA3.5 family, via a `llamaCppRocmOverride` in `flake.nix`. Upstream has
  since landed the real fix unconditionally (`d4389a4d`,
  [ggml-org/llama.cpp#28604](https://github.com/ggml-org/llama.cpp/issues/28604)),
  which covers gfx1150 too, and this flake's llama.cpp pin (`llamaCppPin` in
  `flake.nix`, b11382) is past that revert — so the override and its patch are
  gone. Full diagnosis and history:
  [docs/rocm-gfx1151-numerics.md](docs/rocm-gfx1151-numerics.md).

  Still open, tracked in that doc: this README's gfx1150 ROCm benchmark rows
  (Large: Gemma-4-26B-A4B, Qwen3.5-9B) were all measured through the old,
  broken host-memory path and want re-running against the unpatched
  b11382 build.

Enable all three and let lemonade pick the recipe per model.

### Running ds4 beside lemond

Both servers draw from the same GTT pool, and a DeepSeek-V4-Flash-sized model leaves no room for a second resident one. Measured on a 128 GB Strix Halo (gfx1151) at `ttmSizeGiB = 104`: the 80.76 GiB `IQ2XXS-w2Q2K` quant answers in 1.3 s with ds4 alone, but with a 4B model also loaded under lemond there is nothing left for page cache — lemond fell from 53 tok/s to 0.11 (71 s to process 8 prompt tokens), and shortly after that *both* endpoints stopped answering. Stopping either one restores the other immediately.

Why *both* died, rather than the second one failing to load, was never
established. Contiguous-memory exhaustion is a candidate: peonist-ai report that
a host with plenty of free bytes and few free 2 MiB blocks stalls for minutes at
100% of one core with no disk activity, which is the signature we saw. See
[halogen-flash-teardown.md](docs/halogen-flash-teardown.md). The original event
was not instrumented, so this is a hypothesis rather than a diagnosis.

`exclusiveInference` makes that explicit instead of leaving the machine to thrash, and `autoStart` picks which server the host boots with:

```nix
hardware.amd-npu = {
  exclusiveInference = true;   # Conflicts=: starting either stops the other
  ds4.autoStart = false;       # boot into lemond, run ds4 on demand
};
```

`systemctl start ds4-server` then stops lemond, and `systemctl start lemond` stops ds4. Both options default to the previous behaviour — every server autostarts, nothing conflicts — so this is opt-in for hosts where the models genuinely don't fit together. On a box with headroom for both, leave it off.

## Coding agents and client timeouts

Coding agents (Claude Code, opencode) ship large system prompts — 10k+ tokens once MCP servers, skills, and tool schemas are loaded. On a Strix Point iGPU, prompt processing runs at ~350 t/s, so the agent's first turn spends 25–35 s before the first token is emitted. Neither lemonade nor the agents send SSE keep-alive events during that silent window, and most clients close the socket after ~30 s, yielding:

```
[Info] (Process) srv  log_server_r: done request: POST /v1/chat/completions 127.0.0.1 200
[Error] (HttpClient) CURL error: Failed writing received data to disk/application
[Error] (WrappedServer) Streaming request failed: ...
```

Tracked upstream as [lemonade-sdk/lemonade#1364](https://github.com/lemonade-sdk/lemonade/issues/1364). Until that lands, this module sets `LEMONADE_GLOBAL_TIMEOUT=0` on the `lemond` service to disable its own 300 s upstream cap, which covers the variant where lemonade gives up on llama-server. The downstream client timeout remains a separate problem — best addressed by shortening the prompt or choosing a leaner agent.

**Practical guidance:**

- **Vulkan for short-prompt workloads.** Decode is ~26 % faster than ROCm; safe for chat UIs and ad-hoc prompts that stay roughly under 10k tokens, where prompt processing finishes well before the ~30 s client cutoff.
- **ROCm for large-prompt workloads.** Its ~15 % faster prefill shaves 10k-token prompts from ~33 s (Vulkan) to ~28 s — just enough to land under most clients' silence timeout. Coding agents like Claude Code and opencode fall in this bucket.
- **[pi](https://github.com/badlogic/pi-mono)** (Hugging Face's recommended local coding agent — see the [official docs](https://huggingface.co/docs/hub/en/agents-local)) is the best fit for this hardware. Its prompt is a fraction of Claude Code's and it's designed around llama.cpp-served local models.
- **Claude Code / opencode** are usable — strip down MCP servers, skills, and plugins to shrink the startup prompt, and prefer ROCm while #1364 is unresolved.

## Validation

You can verify that backends are correctly wired by running:

```bash
lemonade backends
```

All AMD-applicable recipes should report `installed` (kokoro is intentionally skipped — Rust port, narrower use case):

```
Recipe              Backend     Status          Message/Version
flm                 npu         installed       v0.9.40
llamacpp            cpu         installed       b8983
                    rocm        installed       b8770
                    system      installed       -
                    vulkan      installed       b8770
sd-cpp              cpu         installed       master-558-8afbeb6
                    rocm        installed       master-558-8afbeb6
whispercpp          cpu         installed       v1.8.4
                    vulkan      installed       v1.8.4
```

Quick image-gen smoke test:

```bash
lemonade pull SD-Turbo
curl -s -X POST http://localhost:13305/api/v1/images/generations \
  -H 'Content-Type: application/json' \
  -d '{"model":"SD-Turbo","prompt":"a red apple on a wooden table","size":"512x512"}' \
  | jq -r '.data[0].b64_json' | base64 -d > out.png
```

With both `enableROCm` and `enableVulkan` set, lemond logs should show `Starting server on port 8001 (backend: vulkan)` and *no* `Installing sd-server` line — sd-server is invoked directly from the nix store. sd-cpp's `auto` backend selection prefers Vulkan whenever both variants are already installed: 11.5.1 made that the case for every engine (llamacpp, sd-cpp, whispercpp), matching llamacpp's pre-existing Vulkan-first preference order. To exercise the ROCm path specifically, pin it with `hardware.amd-npu.lemonade.settings.sdcpp.backend = "rocm";` (the runtime config section is `sdcpp`, not `sd-cpp`).

### Benchmarking

The `.#benchmark` harness measures real decode throughput through a running `lemond`,
compares it against a hardware-derived ceiling, and gates against silent CPU fallback:

```bash
nix run .#benchmark                                        # interactive TUI
nix run .#benchmark -- --no-tui --backend rocm Gemma-4-26B-A4B-it-GGUF   # headless / CI
```

The TUI walks Hardware → Preflight → Mode → Model → Params → Run → Results, with a live
status rail (gfx arch · GTT budget · GPU% · power · preflight) above every screen.
`--no-tui` prints markdown and exits non-zero when a model falls below `--min-decode-tps`
(default 5 t/s), reliably signalling CPU fallback.

See **[`pkgs/benchmark-go/README.md`](pkgs/benchmark-go/README.md)** for the full
reference: wizard flow, modes (HTTP / MTP A/B / backend), the model picker
(search, fit glyphs, markers), the results columns (Decode, Predicted, % ceil), the
status rail, preflight fixers, and every headless flag.

Authoritative MTP A/B numbers (idle GPU; host load not recorded) for
Qwen3.8-Flash-Next on halo are in
[`bench-logs/qwen38-flash-next-mtp-2026-10-04`](bench-logs/qwen38-flash-next-mtp-2026-10-04/).
The older `bench-logs/mtp-2026-05-*` rows (Qwen3.6 on Strix Point) stay
provisional.

## CI

- **Build**: All packages built and cached on every push to `main`
- **Update**: Weekly check for upstream releases, auto-creates PR with version bumps
