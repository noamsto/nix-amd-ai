# MTP benchmarks: design

**Date:** 2026-05-19
**Status:** Approved (brainstorming phase complete; ready for implementation plan)

## Motivation

Lemonade v10.5.1 added a built-in `mtp` label for models with a trained
multi-token-prediction head, backed by llama.cpp b9213 (`--spec-type
draft-mtp`). The expected decode speedup is ~1.85x on the prior MTP merge
commit; we want published numbers on Strix Point (gfx1150, Radeon 890M)
to land in the README "Which backend should I use?" section alongside
the existing Gemma-4-26B and Qwen3.5-9B rows.

The "Large" row currently uses `llama-bench` for ROCm vs. Vulkan, but
`llama-bench` has no `--spec-type` flag — MTP only runs through
`llama-server` / `llama-cli`. The methodology therefore has to change.

## Scope

In:
- Two MTP-labeled models from lemonade v10.5.1's `server_models.json`:
  - `Qwen3.6-27B-MTP-GGUF` (dense 27B, Q4_K_XL, ~17 GB)
  - `Qwen3.6-35B-A3B-MTP-GGUF` (MoE 35B with 3B active, Q4_K_XL, ~20 GB)
- Backends: ROCm and Vulkan (the two Strix Point GPU paths).
- A/B: same GGUF, same prompt, only `--spec-type` toggles between
  `none` and `draft-mtp`.
- New `--mtp-ab <model-id>` mode in `pkgs/benchmark/benchmark.py` that
  drives the A/B by spawning `llama-server` directly twice per backend.
- README update: new "MTP speedup: Qwen3.6 family" subsection plus a
  bullet in the existing Recommendation list.

Out:
- `Qwen3.5-122B-A10B-MTP-GGUF` — ~70 GB doesn't fit cleanly in 64 GiB.
- NPU / FLM comparison — FLM has no MTP path, not comparable.
- Quality benchmarks (perplexity, MMLU) — README readers want t/s.
- Multi-context-length sweeps — keep one canonical pp256/tg128 to match
  existing rows.
- Lemonade HTTP-driven A/B — MTP-on is automatic for labeled models;
  toggling MTP-off would require patching `server_models.json` inside
  the nix store. Bypassing lemonade is cleaner and decouples the
  numbers from lemonade plumbing.

## Architecture

Single tool: extend the existing `pkgs/benchmark/benchmark.py` with a
new `--mtp-ab <model-id>` mode. The existing default mode (driving
lemonade via HTTP) is untouched.

```
┌─────────────────────────────────────────────────────────────────┐
│ benchmark.py --mtp-ab <model-id> [--backends rocm,vulkan]       │
├─────────────────────────────────────────────────────────────────┤
│  for backend in backends:                                       │
│    for spec in [none, draft-mtp]:                               │
│       spawn llama-server (LlamaServer context manager)          │
│           --model <gguf>  --port <free>                         │
│           --device <Vulkan0|ROCm0>  --spec-type <spec>          │
│           --n-gpu-layers 99  --ctx-size 4096                    │
│       wait /health                                              │
│       1 warmup + 3 measured completions via /v1/completions     │
│           (reuse run_completion() / http_post_stream() helpers) │
│       capture predicted_per_second from final SSE timings       │
│       SIGTERM, wait for exit                                    │
│    print markdown row: model | backend | off | on | speedup     │
└─────────────────────────────────────────────────────────────────┘
```

Shared with the existing harness: `run_completion()`, `build_prompt()`,
`http_post_stream()`, `http_get()`, argparse skeleton.

New: a `LlamaServer` context manager that spawns + reaps the
subprocess and exposes a base_url. No sudo, no `lemond` interaction
from the harness itself.

## GGUF resolution

`--mtp-ab` takes a lemonade model ID. The harness looks up the GGUF
path in lemonade's cache (`~/.cache/lemonade/models/<id>/...`). If the
model is not present, exit 2 with a `lemonade pull <id>` hint. No
silent downloads.

If the model is pulled but has no MTP head (e.g. `Qwen3.5-9B-GGUF`),
the `--spec-type draft-mtp` server-spawn step will fail at startup.
Surface that as **exit 1** — `--mtp-ab` is explicitly for A/B; a
non-MTP model is a usage error, not a partial-success case.

## Benchmark protocol

Matches existing README rows where applicable:

- Prompt: 256 tokens (via `build_prompt(256)`).
- Generation: 128 tokens.
- Warmup: 1 iteration.
- Measured: 3 iterations.
- t/s source: `predicted_per_second` from llama.cpp's server-reported
  `timings` block in the final SSE chunk — excludes HTTP/SSE overhead,
  matches what `benchmark.py` already prefers.
- Fresh `llama-server` for each `--spec-type` value (no shared KV bleed
  between MTP-off and MTP-on runs).

## Pre-flight (operator steps before generating published numbers)

1. `lemonade pull Qwen3.6-27B-MTP-GGUF` (~17 GB)
2. `lemonade pull Qwen3.6-35B-A3B-MTP-GGUF` (~20 GB)
3. `llama-server --help | grep -- '--spec-type'` — must list
   `draft-mtp` (confirms b9213 binary).
4. `sudo systemctl stop lemond` — free VRAM and avoid contention.
5. **Quality gate (must pass before publishing):** run the same
   `llama-cli --temp 0 -n 64` prompt with `--spec-type none` and
   `--spec-type draft-mtp` on each MTP model. Speculative decoding is
   lossless w.r.t. the target model's sampling distribution, so under
   greedy decoding the outputs must be **byte-identical**. If they
   diverge, abort and file a bug against llama.cpp's MTP
   implementation; do not publish numbers.
6. `nix run .#benchmark -- --mtp-ab Qwen3.6-27B-MTP-GGUF`
7. `nix run .#benchmark -- --mtp-ab Qwen3.6-35B-A3B-MTP-GGUF`
8. `sudo systemctl start lemond`

## README change

New subsection inserted between "Mid-size, chat-shaped: Qwen3.5-9B"
and "Recommendation:".

Header:

> ### MTP speedup: Qwen3.6 family (Q4_K_XL, llama.cpp b9213, lemonade v10.5.1)
>
> Same GGUF, same prompt, only `--spec-type` flag changes. Prompt 256
> tokens, gen 128 tokens, 3 iterations after 1 warmup. `llama-server`
> spawned directly (bypassing `lemond`) via
> `nix run .#benchmark -- --mtp-ab <model-id>`.

Table:

> | Model | Backend | MTP off (t/s) | MTP on (t/s) | Speedup |
> | ----- | ------- | ------------: | -----------: | ------: |
> | Qwen3.6-27B (dense)         | Vulkan | ... | ... | ...x |
> | Qwen3.6-27B (dense)         | ROCm   | ... | ... | ...x |
> | Qwen3.6-35B-A3B (MoE, 3B)   | Vulkan | ... | ... | ...x |
> | Qwen3.6-35B-A3B (MoE, 3B)   | ROCm   | ... | ... | ...x |

Plus a one-line note linking llama.cpp PR #22673 and lemonade PR #1944
for context.

"Recommendation" gets one new bullet:

> **MTP-labeled models (Qwen3.6 family):** pull the `-MTP-GGUF`
> variants and let lemonade pick `llamacpp:<backend>` — the `mtp`
> label auto-enables `--spec-type draft-mtp`, giving the speedup
> documented above. The non-MTP siblings will not use the draft head.

## Test plan (proves the harness change before trusting its numbers)

1. **Bogus model ID** → exit 2 with `lemonade pull` hint, no spawn.
2. **Valid but unpulled model** → exit 2, no spawn.
3. **Pulled non-MTP model** (`Qwen3.5-9B-GGUF`) → exit 1 with a clear
   "model has no MTP head" message; no orphan `llama-server`.
4. **Happy path on `Qwen3.6-27B-MTP-GGUF`** → both rows print; harness
   exits 0 regardless of speedup magnitude.
5. **SIGINT mid-sweep** → `LlamaServer.__exit__` reaps the subprocess;
   `pgrep llama-server` after Ctrl-C returns nothing.
6. **Regression on the existing default mode** →
   `nix run .#benchmark -- Qwen3.5-9B-GGUF` behaves exactly as before;
   no shared-state side effects.

If any shell helpers get added, run `shellcheck` per the global rule
(the harness itself is pure Python). Manual walkthrough of all six
cases on this host before opening the PR.

## Risks and unknowns

- **MTP draft acceptance rate on Strix Point is unknown.** The
  upstream ~1.85x figure was measured elsewhere. If acceptance is low
  on gfx1150, the speedup could be modest or even negative. Either
  outcome is publishable as data.
- **VRAM headroom for 35B-A3B with the draft head.** 20 GB base + MTP
  draft allocation may push close to the 28 GiB the iGPU exposes. If
  `--spec-type draft-mtp` OOMs at startup, the harness should surface
  the llama-server error cleanly and exit 1.
- **`lemond.service` interference if accidentally left running.** The
  pre-flight stop step handles this; the harness does not enforce it
  (kept simple, no sudo).
- **`--device Vulkan0` / `--device ROCm0` naming.** llama-server's
  `--list-devices` output drives the exact strings; verify on this
  host before hardcoding.
- **Lemonade cache layout.** The harness assumes the GGUF lives under
  `~/.cache/lemonade/models/<model-id>/...`. The exact filename and
  subpath need to be verified during implementation against a freshly
  pulled MTP model (cache layout may differ for unsloth repos).
