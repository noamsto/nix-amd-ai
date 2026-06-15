# benchmark

A Go + [Charm](https://charm.sh) (bubbletea/lipgloss/bubbles) TUI for benchmarking
AMD AI backends through a running [lemonade](https://github.com/lemonade-sdk/lemonade)
server. It measures real decode throughput over the HTTP API, compares it against a
hardware-derived ceiling, and gates against silent CPU fallback.

Packaged as `.#benchmark`. The compiled binary is portable — it runs off-Nix on any
machine with lemonade installed; just put it on `$PATH`.

## Running

```bash
nix run .#benchmark          # interactive TUI (default)
nix run .#benchmark -- --no-tui Gemma-4-26B-A4B-it-GGUF   # headless / scripted
```

Prerequisites:

- **lemonade running** — `lemond` reachable at `http://localhost:13305` (the picker
  and HTTP bench both read from it). The preflight check offers to start it if it's down.
- **amdgpu present** — the hardware panel and the live GPU% rail read AMD sysfs.

For trustworthy numbers, run with an **idle GPU on AC power**. The preflight guard warns
when either condition isn't met.

## Wizard flow

The TUI walks through seven steps; `Esc` goes back, `Enter` advances.

```
Hardware → Preflight → Mode → Model → Params → Run → Results
```

1. **Hardware** — CPU, GPU (gfx arch), RAM type/speed, driver, kernel.
2. **Preflight** — detects interference (competing GPU processes, battery power, lemond
   down) and offers consent-gated fixers (see [Preflight fixers](#preflight-fixers)).
3. **Mode** — HTTP, MTP A/B, or backend (see [Modes](#modes)).
4. **Model** — searchable/scrollable picker of lemonade models, annotated with VRAM fit
   and predicted throughput (see [Model picker](#model-picker)).
5. **Params** — prompt/gen tokens, context size, repeat, warmup, backends.
   `Tab`/`↑↓` move between fields, `←`/`→` change a value, `Enter` runs.
6. **Run** — live streaming progress with the GPU% utilisation rail.
7. **Results** — measured vs predicted, markdown export, log to disk (see
   [Results columns](#results-columns)).

A persistent [status rail](#status-rail) sits above every screen.

## Modes

| Mode | What it measures | Notes |
|------|------------------|-------|
| **HTTP** | Decode t/s of one or more models against the **already-running** `lemond`. | No restart, no sudo — the simplest, lowest-overhead path. Whatever backend lemond is currently configured for. |
| **MTP A/B** | Multi-Token Prediction speedup (MTP on vs off) for one model. | The bench manages its own `llama-server` lifecycle and sweeps the backends in `--mtp-ab-backends`. Honors `--ctx-size`. Only models carrying the `mtp` label are offered. |
| **backend** | Decode t/s under a **forced** llama.cpp backend (`rocm`/`vulkan`/`auto`). | Rewrites `llamacpp.backend` in `~/.cache/lemonade/config.json`, restarts `lemond.service` via sudo, runs, then restores the original config on exit. |

## Model picker

Lists models from the lemonade API, each row showing a fit glyph, the id, predicted
throughput ceiling, and trailing status markers.

**Keys**

| Key | Action |
|-----|--------|
| `/` | open the filter input |
| `↑`/`↓` | move selection (the list scrolls via viewport windowing, so it never overflows) |
| `Space` | toggle a model into the run set |
| `Enter` | continue → (on a not-downloaded model, prompts *download & continue*) |
| `Esc` | back (or *clear filter* when a filter is active) |

While the filter input has focus: `type` to filter, `Enter`/`↓` to apply, `Esc` to clear.

**Filtering** is case-insensitive and id-first: rows whose **id** contains the query
appear before rows that match only on a **label** (e.g. `mtp`, `hot`). So typing `mtp`
surfaces MTP-capable models even when "mtp" isn't in the id.

**Fit glyphs** (model size vs the GTT budget):

| Glyph | Meaning |
|-------|---------|
| ✅ | Fits — under 90% of budget |
| ⚠️ | Tight — ≥ 90% of budget but still within it |
| ❌ | Spills — larger than the budget |
| `?` | size unknown |

**Status markers** (trailing the row): `⚡ recommended · 🔥 hot · ⬇ downloadable`

- **⚡ recommended** — fits comfortably *and* its predicted ceiling clears the
  recommend threshold, i.e. a good pick for *this* hardware.
- **🔥 hot** — carries lemonade's `hot` label (community-featured). The API's
  `suggested` flag is true for nearly the whole catalog, so it's ignored as a marker.
- **⬇ downloadable** — not downloaded locally; selecting it triggers an on-demand pull
  before the run.

## Results columns

The results table reports, per model/backend:

| Column | Meaning |
|--------|---------|
| **Decode (t/s)** | Measured decode throughput, mean ± stdev over `--repeat` iterations. |
| **Predicted** | The memory-bandwidth decode ceiling for this model on this hardware. `~` prefix means part of the input was estimated; `—` means the model size is unknown. |
| **% ceil** | Measured ÷ Predicted, as a percentage of the ceiling. |

**Predicted** is `memory_bandwidth ÷ active_bytes_per_token`. The active size is
MoE-aware: for a model whose id encodes an active token like `A4B` alongside a total
like `26B` (e.g. `Gemma-4-26B-A4B`), only the active fraction
(`total × active/total`) is counted — a dense model uses its full size. The model size
comes from the **lemonade API**, the same source the picker uses; this is what fixed
models that previously showed `—`.

**Why % ceil can read > 100%**: the ceiling assumes one full weight read per generated
token. MTP / speculative-decoding models emit multiple accepted tokens per memory pass,
so their effective throughput can legitimately exceed the single-token bandwidth bound.

**Keys**

| Key | Action |
|-----|--------|
| `m` | toggle between the table and the raw markdown export |
| `w` | write the run log to `bench-logs-<topic>-<date>/` (cwd-relative) |
| `Esc` | back · `q` quit |

## Status rail

A one-line rail renders above every screen and refreshes ~1s:

```
gfx<arch> · <N>GB GTT · GPU <pct>% <glyph> · <power> · preflight <state>
```

- **arch / GTT** — gfx architecture and the GTT memory budget (the real usable GPU
  memory ceiling on Strix Point, not the UMA carveout).
- **GPU %** — live busy percent read from amdgpu sysfs `gpu_busy_percent` (this is what
  fixed the rail reading 0% under load). The glyph is **context-aware**:
  - during a run, a **busy** GPU is expected → `✓`; an idle one is a stall → `⚠`.
  - on idle screens it's reversed — a **busy** GPU means another workload is contending
    and will skew results → `⚠`.
- **power** — `AC perf ✓` when on AC in performance mode, `battery ⚠` otherwise.
- **preflight** — `preflight ✓ clean`, or `preflight ⚠ N` with the count of open issues.

Colors adapt to the terminal background (detected at startup), staying legible on both
light and dark themes.

## Preflight fixers

Preflight classifies each check as pass/warn and, where a fix is safe and actionable,
attaches a consent-gated key. The fixer runs via `tea.ExecProcess`, so any `sudo` auth
prompt is handled inline.

| Issue | Key | Fix |
|-------|-----|-----|
| lemond down | `s` | `start lemonade` (sudo `systemctl start`) — needed to list models and serve the HTTP bench |
| not in performance mode (on AC) | `p` | `set performance` power profile (sudo) |

No fixer is offered for **competing GPU processes** — the tool can't safely free
someone else's work. (When lemond itself is holding a model, the run's own evacuation
guardrail unloads it gently, no sudo required.)

## Headless mode

`--no-tui` prints the results table as markdown to stdout and is the path for CI and
scripts. It exits **non-zero** when any model falls below `--min-decode-tps` (default
5 t/s), which reliably signals CPU fallback rather than GPU execution.

```bash
nix run .#benchmark -- --no-tui --backend rocm   Phi-4-mini-instruct-GGUF
nix run .#benchmark -- --no-tui --backend vulkan Phi-4-mini-instruct-GGUF
nix run .#benchmark -- --no-tui --mtp-ab Qwen3.6B-GGUF
```

**Flags**

| Flag | Default | Purpose |
|------|---------|---------|
| `--base-url` | `http://localhost:13305` | lemonade server base URL |
| `--prompt-tokens` | `512` | approximate prompt token count |
| `--gen-tokens` | `128` | tokens requested per completion |
| `--warmup` | `1` | warmup iterations before measurement |
| `--repeat` | `3` | measurement iterations |
| `--min-decode-tps` | `5.0` | exit 1 if any model is below this (CPU-fallback gate) |
| `--backend` | `` | force `llamacpp.backend` (`rocm`/`vulkan`/`auto`) and restart lemond before benchmarking |
| `--config-path` | `~/.cache/lemonade/config.json` | lemonade config to rewrite when `--backend` is set |
| `--lemond-service` | `lemond.service` | systemd service to restart with `--backend` |
| `--no-restart` | `false` | skip the sudo restart after writing the config |
| `--mtp-ab` | `` | run MTP on/off A/B for one model (mutually exclusive with positional ids) |
| `--mtp-ab-backends` | `rocm,vulkan` | backends to sweep in `--mtp-ab` |
| `--ctx-size` | `2048` | `llama-server --ctx-size` for MTP A/B mode |
| `--no-tui` | `false` | disable the TUI; print markdown to stdout |

Positional `MODEL_ID` arguments select the models to benchmark in HTTP mode.

**Exit codes**

| Code | Meaning |
|------|---------|
| `0` | all models passed `--min-decode-tps` (or MTP A/B ok) |
| `1` | one or more models below `--min-decode-tps` |
| `2` | hard error (server unreachable, model not found/downloaded, device not ready, bad args) |

## Development

```bash
cd pkgs/benchmark-go
go test ./...
```
