# unsloth-studio trial on Strix Halo (gfx1151)

Question (#368): does Unsloth Studio, wrapped in an FHS env, install and fine-tune on a Strix Halo (gfx1151) GPU?
Answer: yes for a small bf16 LoRA. Everything below is one host, one GPU target (gfx1151, Radeon 8060S); nothing
was measured on gfx1150.

## Setup

- `nix build .#unsloth-studio` wrapper (`buildFHSEnv`), installer pinned at upstream commit `078b962`; first run installed
  `unsloth` 2026.11.9 with torch `2.11.0+rocm7.13.0` from `https://repo.amd.com/rocm/whl/gfx1151/`.
- Installer linked the flake's `llama-cpp-vulkan` through `--with-llama-cpp-dir` ("linked local directory"). Studio never
  launched it in this trial: GGUF chat is **unmeasured**.
- Three wrapper bugs found and fixed by the trial: the installer's venv used the host's headerless nix Python (Triton's HIP
  launcher failed on `Python.h`; fixed with `UV_PYTHON_PREFERENCE=only-managed`); Python's urllib had no CA bundle in the
  FHS env (Hugging Face config/tokenizer fetches failed; fixed with `cacert` + `SSL_CERT_FILE`); `--package` cannot carry a
  version, so the installer commit, not the flag, is the pin.

## Results

| Check | Result |
| --- | --- |
| `unsloth doctor` | torch 2.11.0+rocm7.13.0, HIP 7.13, 1 GPU (Radeon 8060S, 104 GiB addressable), verdict OK |
| `/api/health` | `chat_only: true` until hardware detection runs; after an authenticated `?detect_hardware=true` it reports `chat_only: false` (`health-probe.sh`). Detection is deferred by design until a request asks for it. |
| LoRA | `unsloth/Llama-3.2-1B-Instruct`, bf16 (not 4-bit), r=16, seq 512, batch 2 x accum 4, 40 steps, `yahma/alpaca-cleaned`, `lora.sh` |
| Loss | 40 logged values, none NaN; mean of first 5 = 1.95, mean of last 5 = 1.14; run mean 1.31 |
| Step time | 50.7 s trainer runtime for 40 steps (~1.3 s/step), **measured under ~15 loadavg from parallel builds, not a speed figure** (loadavg 14.0 at start, 15.8 at end) |
| Peak GPU memory | +3.9 GiB (4.2 GB) over the idle baseline (sampled amdgpu GTT+VRAM, 1 s interval; a resident model server on the same GPU is in the baseline, not the delta) |
| Attention backend | the log reports `Xformers = None. FA2 = False`, so transformers' default path was used; which SDPA kernel ran was not instrumented. Related: flash and memory-efficient SDPA are known to fail silently on TheRock's gfx1151 torch (see `docs/therock-eval-results.md`), so the math backend is the likely one, but that is not confirmed here. |

## Not covered

Training started from the web UI, 4-bit (QLoRA) training, models above 1B, runs longer than 40 steps, held-out quality
(only training loss was inspected), GGUF chat through the external `llama-server`, gfx1150.

## Scripts

- `gpu-gate.sh` runs a command while holding the shared GPU signal file (atomic claim, removed on exit); `GATE_ALLOW_LOAD=1`
  skips the loadavg wait, used here because the host stayed above loadavg 4 for the whole 15-minute cap.
- `lora.sh` runs the fine-tune with memory sampling and writes a summary.
- `health-probe.sh` launches Studio, completes the first-login password change on a throwaway instance and polls health.
