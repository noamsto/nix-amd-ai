# Model Picker: API-driven sizes, downloadable models, suggested/MTP labels — Design

**Date:** 2026-05-30
**Status:** Approved (design); plan pending
**Builds on:** the benchmark TUI model picker (`internal/tui/modelpick.go`)

## Problem

The picker showed `?? GiB` for every model (size came from on-disk GGUF resolution, which breaks under `sudo` — `$HOME=/root` — and on id/repo case mismatches). It also hid all not-downloaded models and had no reliable "suggested"/MTP signal (a name heuristic was considered and rejected as unsolid).

## Key insight

`/api/v1/models` already returns, per model: **`size`** (GB, present even when not downloaded), **`suggested`** (bool), and **`labels`** (including `"mtp"`). So the picker should use the API as the source of truth for size/suggestion/MTP — no filesystem hunting, no heuristics.

## Design

### models.Model (internal/models)
Add `Size float64` (`json:"size"`, GB) and `Suggested bool` (`json:"suggested"`). `Labels []string` is already captured (contains `"mtp"` for MTP-capable models).

### Picker display (internal/tui/modelpick.go)
- **Size/fit/ceiling from the API**, not the filesystem: `totalGiB = model.Size / 1.073741824` (GB→GiB). `sizeKnown = model.Size > 0`. Fit = `FitClass(totalGiB, BudgetGiB(GTT))`. Ceiling = `DecodeCeilingTPS(bw, EstimateActiveGiB(id, totalGiB))` (active-size logic unchanged). This fixes `??` for ALL models regardless of sudo/download state.
- **Show downloadable models:** drop the `!Downloaded` skip. List every `recipe=="llamacpp"` model; downloaded rows render normally, not-downloaded rows get a `⬇` tag; downloaded sorted before not-downloaded.
- **Suggested tag:** render `★` when `model.Suggested` (lemonade's own flag).
- **MTP A/B mode:** filter to models whose `labels` contain `"mtp"` (solid, lemonade-provided) — only models with a real draft head appear. HTTP / Backend A/B modes show all llamacpp models. (The picker therefore needs to know the selected mode; thread it in.)
- Column layout unchanged (fixed-width); add the `⬇`/`★` markers without breaking alignment (account via `lipgloss.Width`).

### Unchanged / still needed
The checkpoint-based GGUF resolver + sudo-aware `defaultHFCacheRoot` stay — the **actual run** (`RunMTPAB` → `llama-server --model <path>`) still needs the local file path. Only the picker *display* switches to API size.

## Out of scope (deferred follow-up)

Download-on-select with a progress bar. `POST /api/v1/pull` exists but it's unconfirmed whether it streams progress over HTTP. Not-downloaded models are selectable; wiring an actual pull (spinner or progress) is a separate task to be scoped only if the pull API supports streaming. For now, selecting a not-downloaded model is allowed and the existing run path will surface whatever lemonade does on load.

## Testing

- `models.ParseModels`: captures `size` + `suggested`.
- `buildModelRows`: uses `model.Size` (sizeKnown from it); not-downloaded llamacpp models are INCLUDED with the `⬇` marker; non-llamacpp still filtered; `★` rendered when suggested; in MTP mode only `mtp`-labeled models survive; downloaded sorted first.
- `formatModelRow`: `⬇`/`★` markers present, columns stay aligned (lipgloss.Width).
- No regression to MoE fit=total / ceiling=active.
