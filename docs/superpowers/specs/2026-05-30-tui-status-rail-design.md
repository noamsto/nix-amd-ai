# TUI Status Rail — Design

**Date:** 2026-05-30
**Status:** Approved (design); implementation plan pending
**Builds on:** the Charm-v2 benchmark TUI (`pkgs/benchmark-go/internal/tui/`)

## Problem

The benchmark TUI is a wizard: one full-screen step at a time (hardware → preflight →
mode → model → params → run → results). The flow fits the task (the steps are
inherently sequential), but you lose context between steps — while picking a model or
setting params you can't see your memory budget, the power state, or whether the GPU is
still clean. The "is the GPU idle yet?" question (e.g. another session loading a model
mid-wizard) is invisible unless you backtrack to the preflight screen.

## Goal

Add a persistent top-bar **status rail** rendered above every wizard screen, with a
**live** GPU/preflight readout, so the operator always sees hardware budget, power state,
and live interference without leaving the current step. Keep the wizard flow unchanged.

## Non-Goals (YAGNI)

- No full multi-pane dashboard / sidebar layout — the wizard stays a wizard.
- No new interactivity in the rail (it's informational; fixers stay on the preflight screen).
- No historical/graphing of GPU% — just the current value.

## Approach

A single-line lipgloss bar prepended to each screen's `View()` output. Chosen over a
left sidebar because the bar preserves full-width wizard screens, works on narrow
terminals, and is a modest addition rather than a per-screen layout rewrite.

Example:
```
 gfx1150 · 27GB GTT · GPU 0% ✓ · AC perf ✓ · preflight ✓ clean
```

## Components

### `internal/tui/rail.go`
- `railState` struct: `gpuPct float64`, `preflight railPreflightSummary` (a derived
  count: clean vs N issues, or "not yet run").
- `renderRail(info hw.Info, st railState, width int) string` — pure function. Renders one
  bar: gfx arch; usable budget (`<GTT GiB>GB GTT`); live `GPU NN%` with an idle/busy glyph
  (busy when `gpuPct > 5`, matching the preflight GPU threshold); power (`AC perf ✓` /
  `battery ⚠` / `perf ✗` from `info.OnAC` + `info.Performance`); and a preflight summary
  (`preflight ✓ clean` / `preflight ⚠ N` / `preflight …` when not yet run). Truncates to
  `width` so a narrow terminal degrades gracefully (drop trailing segments rather than wrap).
- `summarizePreflight([]preflight.Result) railPreflightSummary` — pure; counts Warn+Fail.

### Model changes (`internal/tui/app.go`)
- Add `rail railState` to the model.
- `Init()` starts the rail ticker (`railTickCmd`).
- `Update()` handles `railTickMsg`: set `m.rail.gpuPct`, re-arm `railTickCmd`. Also refresh
  `m.rail.preflight` from `m.preflightResults` whenever those change (on `preflightResultsMsg`
  / `fixDoneMsg`).
- `View()` becomes `lipgloss.JoinVertical(lipgloss.Left, renderRail(m.info, m.rail, width), body)`
  where `body` is the existing per-screen render. Width from the last `tea.WindowSizeMsg`
  (store it; default 80 if unset).

### Ticker unification (`internal/tui/run.go`)
- The single rail ticker becomes the **only** GPU poller. Remove the run-screen-specific
  GRBM tick (`grbmTickCmd`/`grbmTickMsg`/`grbmFunc`); the run readout now displays
  `m.rail.gpuPct`. One ticker, one seam (`railGRBM func() float64`, default
  `hw.GRBMBusyPct`), app-wide — avoids two concurrent GPU polls perturbing a measurement.

## Data Flow

`tea.Tick(~1s)` → `railTickMsg` → `Update` reads `railGRBM()` → `m.rail.gpuPct` → re-arm.
Preflight results already flow into the model on `preflightResultsMsg`/`fixDoneMsg`;
`Update` additionally recomputes `m.rail.preflight` from them. `View()` renders the rail
from `m.rail` + `m.info` on every frame. No change to step routing, key handling, or the
consent-gated fixer invariant.

## Error Handling

`railGRBM`/`hw.GRBMBusyPct` already returns 0 on any error (never panics), so a failed poll
shows `GPU 0%`. The ticker always re-arms regardless. Width 0/unknown → default 80.

## Testing

- `renderRail` pure unit tests: idle vs busy glyph (gpuPct 0 vs 42), power variants
  (AC+perf / battery / AC+!perf), preflight summary (clean / N issues / not-run), and
  narrow-width truncation (drops trailing segments, no wrap, never panics).
- `summarizePreflight` unit test (counts Warn+Fail; empty → not-run).
- `railTickMsg` handling: updates `gpuPct` from the injected `railGRBM` seam and re-arms.
- Preflight-summary refresh: `preflightResultsMsg`/`fixDoneMsg` update `m.rail.preflight`.
- teatest: the rail bar (arch + GPU readout) appears on ≥2 different screens (e.g. hardware
  and model picker).
- Adjust the existing run-screen tests: the run readout now reflects `m.rail.gpuPct`
  (unified ticker) rather than the removed run-specific tick; the consent-invariant and
  streaming tests stay green.

## Out of Scope / Follow-ups

- None planned. The rail is self-contained; nothing else in the wizard changes.
