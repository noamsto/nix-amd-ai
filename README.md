# nix-amd-ai

AMD AI inference stack for NixOS — packages XRT, XDNA driver plugin, FastFlowLM, and Lemonade with a NixOS module for NPU + ROCm GPU support.

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
| `benchmark` | Multi-backend benchmark harness | `nix run .#benchmark` |

CPU backends for llamacpp / whispercpp / sd-cpp use vanilla nixpkgs packages (`pkgs.llama-cpp`, `pkgs.whisper-cpp`, `pkgs.stable-diffusion-cpp`) and are wired automatically when `enableLemonade = true`.

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
    enableFastFlowLM = true;  # LLM inference on NPU
    enableLemonade = true;    # OpenAI-compatible API server
    enableROCm = true;        # ROCm GPU backends (llamacpp + sd-cpp)
    enableVulkan = true;      # Vulkan GPU backends (llamacpp + whispercpp)
    enableImageGen = true;    # default true; set false to drop sd-cpp from closure
    lemonade.user = "youruser";
  };

  users.users.youruser.extraGroups = ["video" "render"];
}
```

## Binary cache

Pre-built packages are available via Cachix:

```nix
# flake.nix nixConfig (or nix.settings in your NixOS config)
substituters = ["https://nix-amd-ai.cachix.org"];
trusted-public-keys = ["nix-amd-ai.cachix.org-1:F4OU4vw/lV2oiG6SBHZ+nqjl4EFJuqI4X9A7pvaBmhQ="];
```

**Do not `.follows` our `nixpkgs` input.** The overlay is intentionally built against this flake's pinned `nixpkgs` (see `flake.nix` `pinned`) so the input closure hash matches both `cache.nixos.org` (Hydra-cached `pkgs.llama-cpp.override`, etc.) and our Cachix. If you add `inputs.nix-amd-ai.inputs.nixpkgs.follows = "nixpkgs"`, the overrides re-hash against your `nixpkgs` and every backend rebuilds from source. Just leave this input pinned:

```nix
# good — let nix-amd-ai keep its own pinned nixpkgs
inputs.nix-amd-ai.url = "github:noamsto/nix-amd-ai";

# bad — forces rebuilds of llama-cpp / whisper-cpp / stable-diffusion-cpp
# inputs.nix-amd-ai.inputs.nixpkgs.follows = "nixpkgs";
```

## Requirements

- NixOS with kernel >= 6.14 (has `amdxdna` driver built-in)
- AMD Ryzen AI processor with XDNA 2 NPU (Strix Point / Strix Halo)
- User in `video` and `render` groups

## What the module configures

- Kernel params (`iommu.passthrough=0`) and modules (`amdxdna`)
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
| `enableVulkan` | `llamacpp:vulkan`, `whispercpp:vulkan` |
| `enableImageGen` (default true) | Gates all `sd-cpp:*` packages; turn off for ~150 MB CPU / ~1.5 GB ROCm savings on headless LLM-only hosts |

Vanilla v10.3.0 ignores these env vars on NixOS for several reasons that this flake patches in-tree (see `pkgs/lemonade/default.nix:postPatch`, [issue #5](https://github.com/noamsto/nix-amd-ai/issues/5), upstream [lemonade-sdk/lemonade#1791](https://github.com/lemonade-sdk/lemonade/issues/1791)):

- `install_backend` short-circuits on `find_external_backend_binary` *before* the `no_fetch_executables` throw and the rocm-stable / TheRock runtime fetches, so user-supplied `*_bin` paths actually skip the entire download flow.
- The Linux ROCm `LD_LIBRARY_PATH` block is gated on the same check, so a nix-store `llama-server` keeps its RPATH-resolved libs instead of being shadowed by `~/.cache/lemonade/bin/.../lib`.
- `is_ggml_hip_plugin_available()` honors `LEMONADE_GGML_HIP_PATH` so the `system` llamacpp recipe stops being permanently `unsupported` on NixOS.
- `LEMONADE_WHISPERCPP_VULKAN_BIN` is added to the env-var migration table (upstream only mapped CPU/NPU for whispercpp).
- `ConfigFile::load` re-applies the env overlay on every startup, not just first run, so bumping `pkgs.*` propagates without users having to delete `~/.cache/lemonade/config.json`.
- The download SSE handler treats `sink.write` failure as a transient client disconnect rather than a cancel signal, so a backgrounded Tauri window doesn't kill an in-flight multi-GB download.

If `lemonade backends` reports a backend as `installed` but benchmarks report <5 t/s decode on a small model, you're on CPU — check that the matching `enable*` option is set and the host has been rebuilt.

### Tauri desktop app: download progress is fragile when backgrounded

WebKitGTK suspends the network process for windows that are minimized, hidden, or moved to another workspace. That kills the SSE progress stream lemond uses for downloads at ~60–90 s. Without our patch, that nuked the whole download mid-flight. With the patch, the download keeps running server-side and finishes regardless — but the UI stops seeing progress until you refocus the window (and may need a refresh to pick up the result). For very large pulls, prefer the regular browser at `http://localhost:13305` or `lemonade pull <model>` from the CLI; both survive backgrounding cleanly.

## Which backend should I use?

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

Quick image-gen smoke test (ROCm path):

```bash
lemonade pull SD-Turbo
curl -s -X POST http://localhost:13305/api/v1/images/generations \
  -H 'Content-Type: application/json' \
  -d '{"model":"SD-Turbo","prompt":"a red apple on a wooden table","size":"512x512"}' \
  | jq -r '.data[0].b64_json' | base64 -d > out.png
```

Lemond logs should show `Starting server on port 8001 (backend: rocm)` and *no* `Installing sd-server` line — sd-server is invoked directly from the nix store.

To run a multi-backend benchmark and detect silent CPU fallbacks:

```bash
nix run .#benchmark -- Gemma-4-26B-A4B-it-GGUF
```

The benchmark exits non-zero if any backend falls below `--min-decode-tps` (default 5 t/s), which reliably indicates a CPU fallback rather than GPU execution.

To directly compare ROCm vs Vulkan on the same model, pass `--backend`. This rewrites `llamacpp.backend` in `~/.cache/lemonade/config.json`, restarts `lemond.service` (via sudo), runs the benchmark, and restores the original config on exit:

```bash
nix run .#benchmark -- --backend rocm   Phi-4-mini-instruct-GGUF
nix run .#benchmark -- --backend vulkan Phi-4-mini-instruct-GGUF
```

If you've already set the backend manually, pass `--no-restart` to skip the sudo restart step.

## CI

- **Build**: All packages built and cached on every push to `main`
- **Update**: Weekly check for upstream releases, auto-creates PR with version bumps
