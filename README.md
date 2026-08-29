# nix-amd-ai

AMD AI inference stack for NixOS — packages XRT, XDNA driver plugin, FastFlowLM, and Lemonade with a NixOS module for NPU + ROCm GPU support.

On Apple Silicon (`aarch64-darwin`) the same flake also serves the cross-platform Lemonade server (llama.cpp Metal backend) via a nix-darwin module — see [macOS (nix-darwin)](#macos-nix-darwin). The AMD/NPU/ROCm stack is Linux-only.

## Packages

| Package | Description | Source |
|---------|-------------|--------|
| `xrt` | Xilinx Runtime for AMD NPU | Built from [Xilinx/XRT](https://github.com/Xilinx/XRT) |
| `xrt-plugin-amdxdna` | XDNA userspace driver plugin | Built from [amd/xdna-driver](https://github.com/amd/xdna-driver) branch `1.7` |
| `fastflowlm` | NPU-optimized LLM runtime | Built from [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) |
| `lemonade` | OpenAI-compatible local AI server (`lemond` + CLI + web UI + Tauri desktop app) | Built from [lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade) |
| `llama-cpp-rocm` | ROCm-accelerated llama.cpp backend | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `llama-cpp-vulkan` | Vulkan-accelerated llama.cpp backend | Built from [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| `whisper-cpp-vulkan` | Vulkan-accelerated whisper.cpp backend | `pkgs.whisper-cpp.override { vulkanSupport = true; }` |
| `stable-diffusion-cpp-rocm` | ROCm-accelerated stable-diffusion.cpp backend | `pkgs.stable-diffusion-cpp.override { rocmSupport = true; }` |
| `ds4` | DeepSeek V4 inference engine, Strix Halo (`gfx1151`) ROCm backend (`ds4`, `ds4-server`, `ds4-bench`, `ds4-eval`, `ds4-agent`) | Built from [antirez/ds4](https://github.com/antirez/ds4) |
| `gaia` | AMD GAIA agent framework launcher (`gaia`, `gaia-cli`, `gaia-mcp`, `gaia-emr`, `gaia-code`) | `uvx` wrapper around [amd/gaia](https://github.com/amd/gaia) |
| `benchmark` | Multi-backend benchmark harness | `nix run .#benchmark` |

CPU backends for llamacpp / whispercpp / sd-cpp use vanilla nixpkgs packages (`pkgs.llama-cpp`, `pkgs.whisper-cpp`, `pkgs.stable-diffusion-cpp`) and are wired automatically when `enableLemonade = true`. The GPU backends track nixpkgs too; the `mtp` recipe — built-in MTP support added by lemonade [#1944](https://github.com/lemonade-sdk/lemonade/pull/1944), backed by llama.cpp [#22673](https://github.com/ggml-org/llama.cpp/pull/22673) — fires on any nixpkgs llama.cpp past `b9175`.

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
    enableLemonade = true;    # OpenAI-compatible API server
    enableROCm = true;        # ROCm GPU backends (llamacpp + sd-cpp)
    enableVulkan = true;      # Vulkan GPU backends (llamacpp + whispercpp)
    enableImageGen = true;    # default true; set false to drop sd-cpp from closure
    lemonade.user = "youruser";
  };

  users.users.youruser.extraGroups = ["video" "render"];
}
```

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

## Requirements

- NixOS with kernel >= 6.14 (has `amdxdna` driver built-in) — only required when `enableNPU = true`
- AMD Ryzen AI processor with XDNA 2 NPU (Strix Point / Strix Halo; Krackan Point untested) for the NPU path; the GPU backends run on any supported AMD GPU with `enableNPU = false` (see "Other hardware")
- User in `video` and `render` groups

## Other hardware (RDNA3 iGPUs / Hawk Point)

The module splits into an NPU half and a GPU half. The NPU half (XRT + `amdxdna` + FastFlowLM) is built and tested for **XDNA 2** (Strix Point / Strix Halo) — that's what FastFlowLM targets. The GPU backends are independent and run on other AMD GPUs.

**Krackan Point** (Ryzen AI 7 350 / 5 340, PCI `1022:17f0` rev `0x20`) is XDNA 2 with the same 8-column AIE array, but `amdxdna` gives it its own device profile (`dev_npu6_info`, vs `dev_npu4_info` for Strix Point) and nothing here has been tested on it. Reported failing at model load with `DRM_IOCTL_AMDXDNA_CREATE_HWCTX` — see #79.

Set `enableNPU = false` to drop the XRT/`amdxdna` closure (kernel module, IOMMU param, udev rules, memlock limits) and run GPU-only. Example for a **Hawk Point** APU (Ryzen 9 8945HS, Radeon 780M / `gfx1103`):

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
- **ROCm** (`enableROCm`): the shipped `llama-cpp-rocm` is compiled with `gfx1103` in its `CMAKE_HIP_ARCHITECTURES` list, so it carries native 780M kernels — no `HSA_OVERRIDE_GFX_VERSION` workaround should be needed. This is **untested on actual Hawk Point hardware**, and rocBLAS coverage for `gfx1103` APUs can be uneven, so Vulkan remains the recommended path. If ROCm misbehaves, the usual fallback is to alias the arch to `gfx1100`:

  ```nix
  systemd.services.lemond.environment.HSA_OVERRIDE_GFX_VERSION = "11.0.0";
  ```

## What the module configures

- Kernel modules (`amdxdna`)
- Udev rules for NPU device access
- PAM limits (unlimited memlock for NPU buffer allocation)
- XRT + plugin merged tree for runtime plugin discovery
- Lemonade systemd service with XRT/FLM/ROCm/Vulkan environment
- Environment variables (`XILINX_XRT`, `XRT_PATH`)
- Declarative backend wiring (both the `lemond` service and direct CLI usage receive the ROCm/Vulkan backend paths automatically)

### Why the module flags matter on NixOS

The lemonade source build deliberately doesn't bundle backend `llama-server` / `whisper-server` / `sd-server` binaries — it expects host-provided paths. The module exports the matching env vars from the `lemond` service `Environment` and the user session, then lemonade migrates them into `~/.cache/lemonade/config.json`:

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

`LEMONADE_DEFAULTS_PATH` only seeds `~/.cache/lemonade/config.json` on lemond's
**first** run — afterwards `ConfigFile::load` merges the packaged defaults
*under* the persisted file, so every key the module declares goes inert. Backend
bin paths survived that because they point at stable `/etc/lemonade/backends/*`
symlinks, but scalars did not: a host that first started lemond before enabling
`enableVllm` kept `global_timeout = 0`, which vLLM reads as its startup-readiness
budget and turns into zero poll attempts ([#68](https://github.com/noamsto/nix-amd-ai/issues/68)).

The lemond unit therefore re-applies the module-declared keys on every start,
leaving everything else to whatever the web UI persisted. `lemonade.settings`
rides the same path for keys the module has no dedicated option for:

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
override) live in lemond's separate `recipe_options.json` and are set through
lemonade itself, not through this option.

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

### Tauri desktop app: download progress is fragile when backgrounded

WebKitGTK suspends the network process for windows that are minimized, hidden, or moved to another workspace. That kills the SSE progress stream lemond uses for downloads at ~60–90 s. Without our patch, that nuked the whole download mid-flight. With the patch, the download keeps running server-side and finishes regardless — but the UI stops seeing progress until you refocus the window (and may need a refresh to pick up the result). For very large pulls, prefer the regular browser at `http://localhost:13305` or `lemonade pull <model>` from the CLI; both survive backgrounding cleanly.

The desktop app is the only part of lemonade that pulls a Rust + npm build (and a crates.io cargo-vendor fetch). Headless/server hosts that only need the `lemond` API + CLI can skip it entirely with `lemonade.desktopApp.enable = false;` — this drops the Tauri build path from the closure. (The pre-built app is also on the [binary cache](#binary-cache), so configuring the substituter avoids building it from source in the first place.)

## GPU memory headroom

The iGPU draws GPU memory from the GTT pool. By default the kernel exposes
~27 GB addressable, which covers the 17–22 GB models this flake targets on a
64 GB Strix Point host — so **leave these options unset there; they're a no-op.**

On a **128 GB Strix Halo** host you need to raise the ceiling to expose the
large unified pool for big models. The module takes sizes in **GiB** and
computes the `ttm` page counts for you (`pages = GiB × 262144`):

```nix
hardware.amd-npu.gpuMemory = {
  ttmSizeGiB = 120;       # GTT pool ceiling  → ttm pages_limit
  pagePoolSizeGiB = 60;   # pre-cached pool   → ttm page_pool_size
};
```

This emits `options ttm pages_limit=31457280 page_pool_size=15728640` via
`boot.extraModprobeConfig`. Recommended starting point for 128 GB:

| Option | Value (128 GB) | Meaning |
|---|---|---|
| `ttmSizeGiB` | 120 | Hard ceiling on the GTT pool; leaves ~8 GiB for the OS/CPU. |
| `pagePoolSizeGiB` | 60 | Pre-cached pool inside that ceiling. |

> **Note:** these Halo values are guidance from the [Strix Halo wiki](https://strixhalo.wiki/AI/AI_Capabilities_Overview),
> **not measured on a Halo host by this flake** (the development target is a
> 64 GB Strix Point P14s). Treat them as a starting point, not a validated tune.

**Leave RAM headroom** — don't set `ttmSizeGiB` to your full physical RAM; the
CPU and OS still need their share (the 120/128 example keeps a margin).

## Tuning tradeoffs we don't automate

### `amd_iommu=off` would kill the NPU

The Strix Halo wiki suggests `amd_iommu=off` for a small memory-read speedup.
**Do not do this on a host that uses the NPU.** amdxdna needs the IOMMU present
for PASID; with `amd_iommu=off` there is no IOMMU at all and the NPU dies.
`amd_iommu=off` is only viable on a GPU-only host that has given up XDNA.

The IOMMU default-domain *mode* is a separate knob. amdxdna historically
required *Translated* mode (SVA/PASID), so the module used to pin
`iommu.passthrough=0`. Since the June 2026 amdxdna fix (upstream `5b96159`,
"skip PASID tag in non-SVA mode") the driver no longer tags DMA with an invalid
PASID under an identity default domain, so the NPU works with `iommu=pt` too.
The module no longer forces the mode — it leaves the kernel default (Translated
on NixOS), and hosts that want passthrough for a memory-read win can set
`iommu=pt` themselves.

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

### FLM models don't appear / `flm:npu` reports "not installed" after enabling FastFlowLM

Lemonade v10.10.0 stopped auto-discovering a `flm` on `PATH`; it now only looks
there when `flm.prefer_system` is set in `config.json`. Without it, `lemond`
ignores the nix-provided `flm`, marks the NPU backend `installable`/"not
installed", and lists no FLM models even after `flm pull`. The module now seeds
`flm.prefer_system = true` (with `enableFastFlowLM`), so fresh installs work.

A **cached `~/.cache/lemonade/config.json` wins over that seed** (lemonade merges
user config over defaults), so hosts that ran an older lemonade keep the stale
`prefer_system: false`. Fix an existing host once, after rebuilding, by deleting
the cached config so the module's defaults reseed it:

```bash
rm ~/.cache/lemonade/config.json
sudo systemctl restart lemond
```

See [#62](https://github.com/noamsto/nix-amd-ai/issues/62).

### `amdxdna ... aie2_get_info: Not supported request parameter N` in dmesg/journald

Harmless. `aie2_get_info` handles the NPU's `GET_INFO` ioctl, and the mainline `amdxdna` driver implements only a subset of query types (AIE status/version/metadata, clock, hw-contexts). When userspace (`xrt-smi`, a system monitor, or the lemonade/FastFlowLM init path) probes a power/sensor/telemetry param the driver doesn't implement yet, it returns `-EOPNOTSUPP` and logs that `*ERROR*` line — often on a timer, so it repeats. NPU inference is unaffected. Upstream is filling in the missing queries (power reporting ~Linux 7.1, hwmon exposure tracked in [xdna-driver#323](https://github.com/amd/xdna-driver/issues/323)); a newer kernel makes the line disappear.

## GAIA agent framework

[AMD GAIA](https://github.com/amd/gaia) is a Python agent framework that uses lemond as its inference backend (Email Triage / Code / Jira / Blender / RAG / MCP agents, plus a built-in web UI). Upstream targets pip / electron installers, neither of which fits a NixOS host cleanly, and the Python dependency tree is large and fast-moving (weekly-ish releases, torch + transformers + ~60 transitive deps). The flake therefore ships a thin `uvx` wrapper rather than a from-source Nix build:

```bash
nix run .#gaia                     # interactive CLI; falls back to printing help
nix run .#gaia -- ui               # launch the web UI (FastAPI + bundled SPA)
nix shell .#gaia -c gaia-mcp       # MCP bridge server
nix shell .#gaia -c gaia-code      # code-agent CLI
```

The wrapper pre-sets `LEMONADE_BASE_URL=http://localhost:13305/api/v1` (matching the module's default `lemonade.port`); override the env var to point at a different host. Behind the scenes it runs `uvx --from "amd-gaia[ui]==<version>" <entry>` — so the first invocation downloads the wheel and ~60 transitive deps into `~/.cache/uv` (~30 s, with progress visible) and subsequent runs reuse it.

Bump the pinned version in `pkgs/gaia/default.nix` when a new GAIA release lands and you want it. CI doesn't auto-bump GAIA today (only lemonade / fastflowlm / xdna are wired into `scripts/check-updates.sh`).

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

Enable all three and let lemonade pick the recipe per model.

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

Authoritative MTP A/B numbers (idle GPU + AC + performance power profile) are **pending**
— the methodology is stable but no clean reference run has been committed yet.

## CI

- **Build**: All packages built and cached on every push to `main`
- **Update**: Weekly check for upstream releases, auto-creates PR with version bumps
