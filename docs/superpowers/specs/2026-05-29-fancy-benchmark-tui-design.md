# Fancy Benchmark TUI — Design

**Date:** 2026-05-29
**Status:** Approved (design); implementation plan pending
**Supersedes:** the Python `pkgs/benchmark/benchmark.py` harness (replaced at feature parity)

## Problem

Running the repo's benchmarks — especially the MTP A/B run that justifies or kills
the `b9213` llama.cpp override — requires a clean GPU and AC/performance power, but
nothing enforces that. The current `benchmark.py` happily runs against a contended
GPU (lemond serving, the user's koko coding server on `:8001`), which deflated and
destabilized every "provisional" MTP number so far. The user also wants the tool to
be portable beyond this Nix host, to be interactive/fancy, and to suggest *what* to
benchmark based on the host's hardware.

## Goals

- **Preflight guard** — detect GPU/power interference, prompt to fix it, never act
  without consent.
- **System-aware advice** — given the host's RAM/GPU memory/bandwidth, suggest which
  models fit, predict the decode ceiling, and pre-fill run parameters.
- **Fancy interactive TUI** plus a headless flag mode for scripting.
- **Portable** — single static Go binary, runnable on any Linux with lemonade
  installed, no Python interpreter / Nix required to *run* it.

## Non-Goals (YAGNI)

- No historical results DB or trend charts.
- No remote/SSH orchestration.
- No auto-tuning parameter sweep.
- No non-AMD hardware paths.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | **Go + Charm** (bubbletea/lipgloss/bubbles) | Portable single binary; the "fancy" the user wants. |
| Migration | **Replace** `benchmark.py` at parity | One tool, no drift. `nix run .#benchmark` repoints. |
| Preflight | **Detect + interactive per-item prompt** | Nothing stopped without consent. |
| Run modes | **TUI default + headless flag mode** | Preserves scriptability + the CPU-fallback exit-code gate. |
| Suggestions | Model shortlist, bandwidth ceiling, recommended params, hardware panel | All four requested. |

## Architecture

Go module at `pkgs/benchmark-go/` (replacing `pkgs/benchmark/` once at parity),
built via `buildGoModule`. `apps.benchmark` and `nix run .#benchmark` repoint to it.

| Package | Responsibility | Depends on |
|---|---|---|
| `hw` | Detect APU/gfx arch, RAM GB, RAM type/speed (dmidecode best-effort), VRAM/GTT split, power/governor state. Pure data out. | sysfs, `amdgpu_top`, `dmidecode` |
| `preflight` | Run checks (lemond serving? competing GPU proc/port? GPU busy via GRBM? power=performance?), classify pass/warn/fail, expose fixers (stop lemond, set performance). | `hw`, `systemctl`, `ss` |
| `models` | Enumerate lemonade models (HTTP `/api/v1/models`), resolve GGUF path + size, fit-check against memory budget. | lemonade API, HF cache |
| `bench` | Measurement core: spawn `llama-server`, SSE decode loop, stats (mean±stdev), `--backend` switch, MTP A/B. Ported 1:1 from `benchmark.py`. | `llama-server`, lemonade config |
| `advise` | Pure functions: bandwidth→decode-ceiling math, fit-ranking, recommended params. | `hw`, `models` |
| `tui` | bubbletea models/views composing the above into the interactive flow. | all |
| `cli` | Flag parsing; routes to headless or TUI. | all |

`bench` and `advise` are pure/deterministic → unit-tested without hardware.
`hw`/`preflight` get tests via captured fixture files (sysfs/`amdgpu_top` JSON),
mirroring how `test_benchmark.py` feeds `parse_llama_devices` fixed strings.

## Hardware detection — what is actually readable

Verified on the target box (Strix Point, gfx1150, 64 GiB):

- **Without root:** total RAM (`/proc/meminfo`), VRAM carveout (8 GiB) + GTT total
  (~27 GiB) from amdgpu sysfs, gfx arch + **live GPU utilization (GRBM%)** via
  `amdgpu_top --json`.
- **Needs root:** RAM *type/speed* (DDR5-5600 vs LPDDR5X) — only `dmidecode -t memory`
  / `lshw` with sudo. `advise` must handle "type unknown" gracefully (offer one sudo
  read, else fall back to a configurable assumption and label predictions *estimated*).

The GRBM% signal doubles as the preflight "is the GPU actually busy right now?" check
and as the live "confirm GPU execution" indicator during a run.

## Interactive flow (bubbletea)

One screen per step, Esc backs up:

1. **Hardware panel** — APU/gfx arch, RAM GB + type/speed (or "unknown — sudo?"),
   VRAM/GTT split, power state. Informational.
2. **Preflight checklist** — each check ✓/⚠/✗ with a one-line reason. Fixable items
   get inline actions (`[s] stop lemond`, `[p] set performance`) that run the fixer
   (sudo where needed) and re-check live. "Proceed anyway" is always available but
   labels the run *provisional*.
3. **Mode picker** — `HTTP bench` · `Backend A/B (rocm vs vulkan)` · `MTP A/B (spec on/off)`.
4. **Model picker** — lemonade models, each annotated by `advise`: size, ✅fits /
   ⚠️tight / ❌spills, predicted decode ceiling. Multi-select.
5. **Params form** — pre-filled from `advise` (ctx, repeat, warmup, backends), editable.
6. **Live run** — per-model/iteration progress bars, running mean±stdev, live GRBM%.
7. **Results** — styled table + predicted-vs-measured, "copy as README markdown" view,
   optional write to `bench-logs-*/`.

## CLI / headless

`--no-tui` or non-TTY: `benchmark [--mtp-ab|--backend X] --model M --repeat N --ctx C ...`
→ preflight runs as **warnings only** (never blocks/prompts), prints the markdown
table, exits non-zero below `--min-decode-tps`. Same contract `benchmark.py` has today.

## `advise` math

- **Memory budget.** `fits` when GGUF size + KV-cache estimate ≤ usable GPU budget.
  Real ceiling on Strix Point is **GTT (~27 GiB)**, not the 8 GiB UMA carveout (same
  RAM, no perf delta). KV estimate from ctx × layers × heads at model precision;
  `--parallel 1` keeps it single-slot. Classify ✅fits / ⚠️tight (within ~10%) / ❌spills.
- **Decode ceiling.** Bandwidth-bound: `ceiling_t/s ≈ bandwidth_GB/s ÷ active_bytes_per_token`.
  Bandwidth from RAM type/speed (DDR5-5600 ≈ 89.6 GB/s dual-channel; LPDDR5X higher);
  unknown type → configurable assumption, prediction labeled *estimated*. Show predicted
  vs measured so a large gap flags CPU fallback or thermal throttle.
- **Recommended params.** gfx1150 defaults (below), scaled: drop `-b` to 256 first for
  large models (anti-hang), keep ctx tight for A/B, **never auto-enable rocWMMA**.

### Researched param baselines

Community data is almost all Strix **Halo** (gfx1151); flags transfer, absolute t/s do
not. One direct conflict: community recommends rocWMMA flash-attention, but local
testing found it a **net −42% regression on gfx1150** — `advise` prefers local measured
data over community defaults when they disagree.

| Flag | Community (Strix Halo) | gfx1150 default |
|---|---|---|
| `-ngl` | 99 / 999 | 999 |
| `-fa` / `--flash-attn` | on | on (lemonade serves with it) |
| `-b` batch | 256 (anti-hang) … 2048 | 256 to start |
| `-ub` ubatch | 256–512 | 256 |
| `-c` ctx | up to 131072 | 2048 (512+128 workload) |
| `--parallel`/`-np` | 16 (multi-user) | 1 (KV budget, single-user) |
| mmap | off | off |
| env | `ROCBLAS_USE_HIPBLASLT=1`, `HSA_OVERRIDE_GFX_VERSION` | note, don't auto-set |
| rocWMMA FA | recommended | disabled — local regression |

Sources: llama.cpp discussions [#15021](https://github.com/ggml-org/llama.cpp/discussions/15021),
[#10879](https://github.com/ggml-org/llama.cpp/discussions/10879),
[#20856](https://github.com/ggml-org/llama.cpp/discussions/20856);
[llm-tracker Strix Halo](https://llm-tracker.info/_TOORG/Strix-Halo);
[kryoz/llama-strix-halo](https://github.com/kryoz/llama-strix-halo).

## Measurement port (`bench`) — behavior-preserving 1:1 from `benchmark.py`

- `LlamaServer` spawn/ready-wait/teardown → `exec.Cmd` + readiness poll.
- SSE decode loop (`http_post_stream`) → `bufio.Scanner` over the body, same `data: ` parsing.
- **MTP A/B critical fixes stay:** `--flash-attn on`, ctx 2048, and **`ignore_eos: true`**
  on the MTP-path completions (the fix for phantom 1-token completions).
- `--backend` switch: rewrite `~/.cache/lemonade/config.json`, `systemctl restart lemond`
  via sudo, **restore on exit** (defer + signal handler so Ctrl-C never leaves a mutated config).
- Device pick / `parse_llama_devices`, GGUF resolution, model checks → ported with fixtures.

## Testing

- `advise`, stats, SSE parsing, device pick, config rewrite, GGUF resolution → pure unit
  tests (port `test_benchmark.py` cases; that's the parity bar).
- `hw`/`preflight` → table tests over captured fixtures (real `amdgpu_top --json`, sysfs,
  `ss`/`systemctl` snapshots) so they run in CI without hardware.
- `tui` → bubbletea `teatest` golden-path screen transitions (smoke-level).
- **Parity gate before deleting `benchmark.py`:** same model + flags → Go headless output
  matches Python within noise.
