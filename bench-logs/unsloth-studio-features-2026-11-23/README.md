# unsloth-studio feature verification on Strix Halo (gfx1151)

Question (#371): which everyday Unsloth Studio features work through the `unsloth-studio` wrapper on AMD ROCm?
One host, one GPU target (Strix Halo, gfx1151, Radeon 8060S); nothing was measured on gfx1150. Every GPU step ran under the
trial's `gpu-gate.sh`, with the host loaded (loadavg 3 to 4), so timings are not speed figures. Model: `unsloth/Llama-3.2-1B-Instruct`,
Studio `unsloth` 2026.11.9, torch `2.11.0+rocm7.13.0`, bitsandbytes `0.50.3.dev0` (installed by upstream's installer).
Each GPU step was run once, so the 20-step losses are one sample each.

## Results

| Feature | Result |
| --- | --- |
| GGUF export | **Works** after two wrapper fixes (below). 20-step LoRA, then `unsloth-studio export <adapter> <name> --format gguf --quantization q4_k_m` produced a 807,694,240-byte Q4_K_M GGUF in about 60 s. Loaded in the flake's `llama-server` (`-c 512 -ngl 0`, loopback), it answered "Name the capital of France in one short sentence." with "Paris is the capital of France." One prompt, no quality evaluation. |
| Web-UI training | **Works.** `POST /api/train/start` (the endpoint the UI calls), polled via `/api/train/status`: loading 6 s, training 31 s, completed 66 s. 20 finite losses, 1.39 down to 0.92 (mean of first 5 = 1.37, last 5 = 1.24: falling but noisy). Driven through the HTTP API, not through a browser. |
| GGUF chat | **Works.** `/api/inference/load` with the exported GGUF reported `is_gguf: true`; `/v1/chat/completions` gave the same reply. Studio's child process ran `<state dir>/llama.cpp/llama-server`; `/proc/<pid>/exe` is exactly the flake's `llama-cpp-vulkan` unwrapped output (the wrapper's `llama-server` is a bash wrapper, so the process name is `.llama-server-wrapped`). Nothing was downloaded: the log says "llama.cpp found in the system. Skipping installation." |
| 4-bit QLoRA | **Works, no workaround needed.** `--load-in-4bit`, 20 steps, rc 0 in 60 s, sampled peak GPU memory +2.6 GiB (bf16 LoRA: +4.0 GiB). It is genuinely 4-bit: the log loads `Llama-3.2-1B-Instruct-unsloth-bnb-4bit` and the adapter records `unsloth_training_method='qlora'`. 20 finite losses, 1.75 down to 1.07 (mean of first 5 = 1.97, last 5 = 1.26), no NaN. bitsandbytes logged "No prebuilt binary for ROCm 7.13, loading ROCm 7.2 instead" and still worked; `BNB_ROCM_VERSION` was not tried and bitsandbytes <= 0.49.2 (the known 4-bit NaN bug) was not tested. |
| Listen address | **Loopback by default**; no wrapper change. `studio -p 8899` (no `-H`): `LISTEN 0 2048 127.0.0.1:8899 0.0.0.0:* users:(("unsloth",pid=...,fd=25))`. Upstream's `--host/-H` defaults to `127.0.0.1`; pass `-H 0.0.0.0` to expose it. |
| llama-server child | `ss -ltnp` for Studio's chat server: `LISTEN 0 512 127.0.0.1:46663 0.0.0.0:* users:((".llama-server-w",pid=...,fd=3))`. Loopback. |

## Wrapper fixes found by the export run

1. `llama-quantize`, `convert_hf_to_gguf.py`, `convert_lora_to_gguf.py`, `conversion/` and `gguf-py/` were missing from the llama.cpp directory. They now come from the flake's llama.cpp (the scripts from its source, because the package's `bin/` entries are wrapper scripts).
2. Export patches the converter and `gguf-py/` in place and failed with "Read-only file system" on a store path. The wrapper now builds a writable directory under the state dir: binaries are symlinks, the Python sources are copied, and a marker file records which store path they came from so a flake bump refreshes them. A directory without the marker is never touched.
3. Unsloth resolved its llama.cpp directory from the real home even with `UNSLOTH_STUDIO_HOME` set, and rejected the old layout as corrupted. The wrapper now sets `UNSLOTH_LLAMA_CPP_PATH`.

## Not covered

gfx1150, models above 1B, runs longer than 20 steps, held-out quality of the exported GGUF, export formats other than Q4_K_M GGUF, driving the UI in a browser, throughput.

## Scripts

`export.sh`, `ui-train.sh`, `chat.sh` and `qlora.sh` (sharing `studio-session.sh` for the scratch-home login), run under `../unsloth-studio-trial-2026-11-23/gpu-gate.sh` against a scratch `UNSLOTH_STUDIO_HOME`. The 20-step bf16 LoRA that feeds `export.sh` is `../unsloth-studio-trial-2026-11-23/lora.sh` with `STEPS=20`.
