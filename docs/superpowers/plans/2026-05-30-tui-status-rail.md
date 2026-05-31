# TUI Status Rail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent, live top-bar status rail (gfx arch, GTT budget, live GPU%, power, preflight summary) above every wizard screen, and unify GPU polling into a single app-wide ticker.

**Architecture:** A pure `renderRail` + segment helpers in a new `internal/tui/rail.go`, driven by a `railState` on the root model. One `tea.Tick` (~1s) ticker started in `Init`, re-armed on every `railTickMsg`, feeds `railState.gpuPct` app-wide. The run screen's separate GRBM tick and its `GPU: NN%` line are removed — the always-visible rail covers GPU% during runs too.

**Tech Stack:** Go, Charm v2 (`charm.land/bubbletea/v2`, `charm.land/lipgloss/v2`), `internal/hw` (`GRBMBusyPct`), `internal/preflight` (`Result`/`Status`). Tests via `teatest` + pure unit tests.

---

## File Structure

```
internal/tui/
  rail.go        NEW  — railState, railPreflightSummary, summarizePreflight,
                        segment builders (railArch/railBudget/railGPU/railPower/railPreflight),
                        joinFit, renderRail, railTickMsg, railTickCmd, defaultRailGRBM
  rail_test.go   NEW  — pure tests for the above
  app.go         MOD  — add rail railState + width int + railGRBM seam to model;
                        Init starts railTickCmd; Update handles railTickMsg +
                        tea.WindowSizeMsg + refreshes rail.preflight on results/fix;
                        View prepends renderRail
  run.go         MOD  — remove grbmTickInterval/grbmTickMsg/grbmTickCmd/defaultGRBM,
                        runState.grbmPct, grbmFunc seam, the GPU line; run readout gone (rail covers it)
  run_test.go    MOD  — drop/replace the run-specific GRBM tick tests
```

Env for all tasks (Go needs gcc): `cd pkgs/benchmark-go; nix shell nixpkgs#go nixpkgs#gcc --command <go cmd>`. Fish shell. Commits pre-authorized. Charm v2: keys are `tea.KeyPressMsg` via `msg.String()`; `View()` returns `tea.View` (`tea.NewView`, `v.AltScreen = true`). Do NOT run `go mod vendor`.

---

## Task 1: Pure rail rendering (rail.go)

**Files:**
- Create: `pkgs/benchmark-go/internal/tui/rail.go`
- Test: `pkgs/benchmark-go/internal/tui/rail_test.go`

- [ ] **Step 1: Write the failing test**

`rail_test.go`:
```go
package tui

import (
	"strings"
	"testing"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
)

func TestSummarizePreflight(t *testing.T) {
	if got := summarizePreflight(nil); got.ran {
		t.Fatalf("nil results should be not-ran, got %+v", got)
	}
	res := []preflight.Result{
		{Status: preflight.Pass}, {Status: preflight.Warn}, {Status: preflight.Fail},
	}
	got := summarizePreflight(res)
	if !got.ran || got.issues != 2 {
		t.Fatalf("got %+v want ran=true issues=2", got)
	}
}

func TestRailSegments(t *testing.T) {
	if s := railGPU(0); !strings.Contains(s, "GPU 0%") || !strings.Contains(s, "✓") {
		t.Fatalf("idle gpu seg = %q", s)
	}
	if s := railGPU(42); !strings.Contains(s, "42%") || !strings.Contains(s, "⚠") {
		t.Fatalf("busy gpu seg = %q", s)
	}
	if s := railPower(hw.Info{OnAC: true, Performance: true}); !strings.Contains(s, "AC") || !strings.Contains(s, "✓") {
		t.Fatalf("ac+perf seg = %q", s)
	}
	if s := railPower(hw.Info{OnAC: false}); !strings.Contains(s, "battery") {
		t.Fatalf("battery seg = %q", s)
	}
	if s := railPreflight(railPreflightSummary{ran: true, issues: 0}); !strings.Contains(s, "clean") {
		t.Fatalf("clean seg = %q", s)
	}
	if s := railPreflight(railPreflightSummary{ran: true, issues: 3}); !strings.Contains(s, "3") {
		t.Fatalf("issues seg = %q", s)
	}
	if s := railPreflight(railPreflightSummary{ran: false}); !strings.Contains(s, "…") {
		t.Fatalf("not-run seg = %q", s)
	}
}

func TestJoinFitTruncates(t *testing.T) {
	segs := []string{"aaaa", "bbbb", "cccc", "dddd"}
	full := joinFit(segs, " · ", 100)
	if !strings.Contains(full, "dddd") {
		t.Fatalf("wide should keep all: %q", full)
	}
	narrow := joinFit(segs, " · ", 12)
	if strings.Contains(narrow, "dddd") {
		t.Fatalf("narrow should drop trailing segs: %q", narrow)
	}
	if !strings.Contains(narrow, "…") {
		t.Fatalf("narrow should mark truncation: %q", narrow)
	}
}

func TestRenderRailContainsArchNoPanic(t *testing.T) {
	out := renderRail(hw.Info{GfxArch: "gfx1150", GTTBytes: 27 << 30, OnAC: true, Performance: true},
		railState{gpuPct: 0, preflight: railPreflightSummary{ran: true, issues: 0}}, 120)
	if !strings.Contains(out, "gfx1150") {
		t.Fatalf("rail missing arch: %q", out)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix shell nixpkgs#go nixpkgs#gcc --command go test ./internal/tui/ -run 'Rail|JoinFit|SummarizePreflight' -v`
Expected: FAIL — undefined `summarizePreflight`/`railGPU`/etc.

- [ ] **Step 3: Implement**

`rail.go`:
```go
package tui

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
)

// railTickInterval is how often the rail re-reads live GPU busy%.
const railTickInterval = time.Second

// gpuBusyThreshold mirrors preflight's GPU-busy cutoff.
const gpuBusyThreshold = 5.0

// railState is the live data shown in the top status bar.
type railState struct {
	gpuPct    float64
	preflight railPreflightSummary
}

// railPreflightSummary is a one-glance digest of the last preflight run.
// ran=false means preflight hasn't run yet this session.
type railPreflightSummary struct {
	ran    bool
	issues int // count of Warn+Fail
}

func summarizePreflight(results []preflight.Result) railPreflightSummary {
	if len(results) == 0 {
		return railPreflightSummary{}
	}
	n := 0
	for _, r := range results {
		if r.Status == preflight.Warn || r.Status == preflight.Fail {
			n++
		}
	}
	return railPreflightSummary{ran: true, issues: n}
}

func railArch(info hw.Info) string {
	if info.GfxArch == "" {
		return "gpu unknown"
	}
	return info.GfxArch
}

func railBudget(info hw.Info) string {
	return fmt.Sprintf("%.0fGB GTT", float64(info.GTTBytes)/(1<<30))
}

func railGPU(pct float64) string {
	glyph := "✓"
	if pct > gpuBusyThreshold {
		glyph = "⚠"
	}
	return fmt.Sprintf("GPU %.0f%% %s", pct, glyph)
}

func railPower(info hw.Info) string {
	if !info.OnAC {
		return "battery ⚠"
	}
	if info.Performance {
		return "AC perf ✓"
	}
	return "AC perf ✗"
}

func railPreflight(s railPreflightSummary) string {
	switch {
	case !s.ran:
		return "preflight …"
	case s.issues == 0:
		return "preflight ✓ clean"
	default:
		return fmt.Sprintf("preflight ⚠ %d", s.issues)
	}
}

// joinFit joins segments with sep, greedily including from the front while the
// running display width fits in width; if any are dropped it appends "…".
func joinFit(segs []string, sep string, width int) string {
	if width <= 0 {
		width = 80
	}
	var b strings.Builder
	dropped := false
	for i, seg := range segs {
		candidate := seg
		if i > 0 {
			candidate = sep + seg
		}
		if lipgloss.Width(b.String()+candidate) > width {
			dropped = true
			break
		}
		b.WriteString(candidate)
	}
	out := b.String()
	if dropped {
		ell := sep + "…"
		if lipgloss.Width(out+ell) <= width {
			out += ell
		}
	}
	return out
}

var railStyle = lipgloss.NewStyle().Faint(true)

// renderRail renders the one-line status bar shown above every screen.
func renderRail(info hw.Info, st railState, width int) string {
	if width <= 0 {
		width = 80
	}
	segs := []string{
		railArch(info),
		railBudget(info),
		railGPU(st.gpuPct),
		railPower(info),
		railPreflight(st.preflight),
	}
	return railStyle.Render(joinFit(segs, " · ", width))
}

// railTickMsg carries a fresh GPU GRBM% reading for the rail.
type railTickMsg struct{ pct float64 }

// defaultRailGRBM reads live GPU busy% (amdgpu_top only — no dmidecode/sysfs).
func defaultRailGRBM() float64 { return hw.GRBMBusyPct() }

// railTickCmd schedules the next rail GPU% poll. grbm defaults to defaultRailGRBM.
func railTickCmd(grbm func() float64) tea.Cmd {
	read := grbm
	if read == nil {
		read = defaultRailGRBM
	}
	return tea.Tick(railTickInterval, func(time.Time) tea.Msg {
		return railTickMsg{pct: read()}
	})
}
```

> NOTE: confirm `preflight.Pass/Warn/Fail` and `hw.Info` field names (`GfxArch`, `GTTBytes`, `OnAC`, `Performance`) compile — they are the existing exported names.

- [ ] **Step 4: Run to verify it passes**

Run: `nix shell nixpkgs#go nixpkgs#gcc --command go test ./internal/tui/ -run 'Rail|JoinFit|SummarizePreflight' -v`
Expected: PASS.

- [ ] **Step 5: gofmt + commit**

```bash
nix shell nixpkgs#go --command gofmt -w internal/tui/rail.go internal/tui/rail_test.go
git add pkgs/benchmark-go/internal/tui/rail.go pkgs/benchmark-go/internal/tui/rail_test.go
git commit -m "feat(tui): pure status-rail rendering + GPU tick cmd"
```

---

## Task 2: Wire the rail into the model (app.go)

**Files:**
- Modify: `pkgs/benchmark-go/internal/tui/app.go` (model struct ~37, `New` ~78, `Init` ~83, `Update` ~110/121, `View` ~255)

- [ ] **Step 1: Write the failing test**

Append to `rail_test.go`:
```go
import (
	tea "charm.land/bubbletea/v2"
)

func TestInitStartsRailTick(t *testing.T) {
	m := New(hw.Info{GfxArch: "gfx1150"}, Config{})
	if m.Init() == nil {
		t.Fatal("Init should start the rail ticker (non-nil Cmd)")
	}
}

func TestRailTickUpdatesAndRearms(t *testing.T) {
	m := New(hw.Info{GfxArch: "gfx1150"}, Config{}).(model)
	m.railGRBM = func() float64 { return 73 }
	next, cmd := m.Update(railTickMsg{pct: 73})
	nm := next.(model)
	if nm.rail.gpuPct != 73 {
		t.Fatalf("gpuPct=%v want 73", nm.rail.gpuPct)
	}
	if cmd == nil {
		t.Fatal("railTickMsg should re-arm the ticker")
	}
}

func TestPreflightResultsRefreshRailSummary(t *testing.T) {
	m := New(hw.Info{}, Config{}).(model)
	next, _ := m.Update(preflightResultsMsg{results: []preflight.Result{
		{Status: preflight.Warn}, {Status: preflight.Pass},
	}})
	nm := next.(model)
	if !nm.rail.preflight.ran || nm.rail.preflight.issues != 1 {
		t.Fatalf("rail.preflight=%+v want ran=true issues=1", nm.rail.preflight)
	}
}
```

> If `New` returns `tea.Model` (interface), the `.(model)` type assertion is needed; confirm the concrete type name is `model`.

- [ ] **Step 2: Run to verify it fails**

Run: `nix shell nixpkgs#go nixpkgs#gcc --command go test ./internal/tui/ -run 'InitStarts|RailTick|PreflightResultsRefresh' -v`
Expected: FAIL — `m.rail`/`m.railGRBM` undefined; `Init` returns nil.

- [ ] **Step 3: Implement the model wiring**

In `app.go`:

1. Add fields to the `model` struct (near the other state fields):
```go
	rail     railState
	width    int                // last known terminal width (tea.WindowSizeMsg); 0 = unknown
	railGRBM func() float64      // test seam; nil → defaultRailGRBM
```

2. Change `Init` to start the ticker:
```go
func (m model) Init() tea.Cmd { return railTickCmd(m.railGRBM) }
```

3. In `Update`, add cases (place alongside the existing `preflightResultsMsg` case):
```go
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil
	case railTickMsg:
		m.rail.gpuPct = msg.pct
		return m, railTickCmd(m.railGRBM)
```

4. In the existing `preflightResultsMsg` case (currently sets `m.preflightResults = msg.results`), also refresh the summary:
```go
	case preflightResultsMsg:
		m.preflightResults = msg.results
		m.rail.preflight = summarizePreflight(m.preflightResults)
		// ... keep any existing follow-up (e.g. preflightLoaded handling) ...
```
And wherever `fixDoneMsg` re-runs preflight / updates results, ensure `m.rail.preflight = summarizePreflight(m.preflightResults)` runs after results change. (If the fix path re-issues `runPreflightCmd` and the refresh happens in `preflightResultsMsg`, no extra change is needed — verify.)

5. In `View`, prepend the rail to the existing body string. The current `View` builds a body string `s` via the screen switch, then `tea.NewView(s)` with `v.AltScreen = true`. Change so the rail is joined above `s`:
```go
	rail := renderRail(m.info, m.rail, m.width)
	v := tea.NewView(lipgloss.JoinVertical(lipgloss.Left, rail, s))
	v.AltScreen = true
	return v
```
Add the `charm.land/lipgloss/v2` import to app.go if not already present.

- [ ] **Step 4: Run to verify it passes**

Run: `nix shell nixpkgs#go nixpkgs#gcc --command go test ./internal/tui/ -run 'InitStarts|RailTick|PreflightResultsRefresh' -v`
Expected: PASS.

- [ ] **Step 5: Full tui tests + gofmt + commit**

```bash
nix shell nixpkgs#go nixpkgs#gcc --command go test ./internal/tui/
nix shell nixpkgs#go --command gofmt -w internal/tui/app.go internal/tui/rail_test.go
git add pkgs/benchmark-go/internal/tui/app.go pkgs/benchmark-go/internal/tui/rail_test.go
git commit -m "feat(tui): render rail above every screen + app-wide GPU ticker"
```

---

## Task 3: Unify the ticker — remove the run-screen GRBM tick (run.go)

**Files:**
- Modify: `pkgs/benchmark-go/internal/tui/run.go` (remove `grbmTickInterval` ~18, `grbmTickMsg` ~64, `runState.grbmPct` ~106, `startRun`'s `tea.Batch(..., grbmTickCmd(...))` ~170, `grbmTickCmd`/`defaultGRBM` ~195-210, the `case grbmTickMsg` ~285-289, the `GPU: NN%` render line ~538, and the `grbmFunc` model seam)
- Modify: `pkgs/benchmark-go/internal/tui/run_test.go` (the GRBM-tick tests)

> Rationale: the rail (Task 2) shows GPU% on every screen including the run, via one app-wide ticker. The run screen's own tick + readout are now redundant and would double-poll.

- [ ] **Step 1: Update the run-screen tests first (they encode the change)**

In `run_test.go`: DELETE `TestGRBMTickStopsAfterDone` (the app-wide rail ticker intentionally never stops). REPLACE `TestGRBMTickUpdatesReadout` (which drove the run-specific tick) — the GPU readout is no longer part of the run screen; that behavior is covered by `TestRailTickUpdatesAndRearms` in Task 2. If any other run test references `grbmFunc`, `grbmTickMsg`, or `s.grbmPct`, remove those references.

- [ ] **Step 2: Run to verify they fail to compile**

Run: `nix shell nixpkgs#go nixpkgs#gcc --command go test ./internal/tui/ -run Run -v`
Expected: compile error (still references removed symbols) OR the deleted-test references are gone — proceed to implement.

- [ ] **Step 3: Remove the run-screen GRBM machinery**

In `run.go`:
- Delete `grbmTickInterval`, `grbmTickMsg`, `grbmTickCmd`, `defaultGRBM`.
- Delete `grbmPct` from the `runState` struct.
- Delete the `grbmFunc func() float64` seam from the `model` struct (it now lives as `railGRBM` on the model from Task 2 — if any code referenced `m.grbmFunc`, repoint to nothing; the rail owns polling).
- In `startRun`, change the returned batch from `tea.Batch(waitForRunMsg(ch), grbmTickCmd(m.grbmFunc))` to just `waitForRunMsg(ch)`.
- Delete the `case grbmTickMsg:` block in the run Update handler.
- Delete the `GPU: %.0f%%` line from `renderRunScreen` (run.go ~538) — the rail shows it.
- Remove now-unused imports (`time` may still be used elsewhere; check).

- [ ] **Step 4: Run full tui + build**

Run:
```
nix shell nixpkgs#go nixpkgs#gcc --command go test -race ./internal/tui/
nix shell nixpkgs#go nixpkgs#gcc --command go vet ./...
nix shell nixpkgs#go --command gofmt -l internal/tui/
nix shell nixpkgs#go nixpkgs#gcc --command go build ./...
```
Expected: tests PASS (incl. the consent-invariant and streaming tests), vet clean, gofmt empty, build clean.

- [ ] **Step 5: Commit**

```bash
git add pkgs/benchmark-go/internal/tui/run.go pkgs/benchmark-go/internal/tui/run_test.go
git commit -m "refactor(tui): drop run-screen GRBM tick — rail is the single GPU poller"
```

---

## Task 4: Adaptive light/dark theming (legible on both terminal backgrounds)

Detect the terminal background (Charm v2: `tea.RequestBackgroundColor` → `tea.BackgroundColorMsg.IsDark()`) and resolve all TUI colors through `lipgloss.LightDark(isDark)` so nothing washes out on a light terminal (today `value` is `Color("255")` near-white — invisible on white). Model-held `styles` struct, per Charm's own documented pattern.

**Files:**
- Create: `pkgs/benchmark-go/internal/tui/theme.go`, `theme_test.go`
- Modify: `app.go` (model `styles` field; `New` defaults; `Init` also requests bg; `Update` handles `BackgroundColorMsg`; thread `m.styles` into render calls in `View`)
- Modify: `hwpanel.go`, `preflight.go`, `rail.go`, `run.go`, `results.go`, `mode.go`, `modelpick.go`, `params.go` — replace the package-level style vars with the passed-in `styles`, then DELETE the old vars.

- [ ] **Step 1: Write the failing test**

`theme_test.go`:
```go
package tui

import "testing"

func TestNewStylesLightDarkDiffer(t *testing.T) {
	light := newStyles(false)
	dark := newStyles(true)
	// Same input must render differently (different color codes) on light vs dark.
	if light.value.Render("x") == dark.value.Render("x") {
		t.Fatal("value style should differ between light and dark")
	}
	if light.pass.Render("ok") == dark.pass.Render("ok") {
		t.Fatal("pass style should differ between light and dark")
	}
}

func TestBackgroundColorMsgSetsStyles(t *testing.T) {
	m := New(hwInfoForTest(), Config{}).(model)
	// dark bg → dark styles; assert Update stores a styles set that renders like newStyles(true)
	next, _ := m.Update(darkBackgroundMsg())
	if next.(model).styles.value.Render("x") != newStyles(true).value.Render("x") {
		t.Fatal("dark background should select dark styles")
	}
}
```
Provide `hwInfoForTest()` (any `hw.Info`) and `darkBackgroundMsg()` returning a `tea.BackgroundColorMsg` whose `IsDark()` is true — construct it from a dark `color.Color` (e.g. black). Confirm how to build one via `go doc charm.land/bubbletea/v2 BackgroundColorMsg` (it embeds `color.Color`); if constructing a dark msg is awkward, instead unit-test only `TestNewStylesLightDarkDiffer` and test the Update wiring by directly asserting `newStyles(true)` vs `newStyles(false)` selection logic in a small helper. Don't force a brittle construction.

- [ ] **Step 2: Run to verify it fails**

Run: `nix shell nixpkgs#go nixpkgs#gcc --command go test ./internal/tui/ -run 'NewStyles|BackgroundColor' -v`
Expected: FAIL — `newStyles`/`styles` undefined.

- [ ] **Step 3: Implement `theme.go`**

```go
package tui

import "charm.land/lipgloss/v2"

// styles holds every themed style, resolved for the detected terminal background.
type styles struct {
	panel, heading, label, value, warnValue, pass, warn, fail, hint, rail lipgloss.Style
}

// newStyles resolves colors for a light or dark terminal. Light variants are
// darker (contrast on white); dark variants keep the original bright values.
func newStyles(isDark bool) styles {
	ld := lipgloss.LightDark(isDark)
	c := func(light, dark string) lipgloss.Style {
		return lipgloss.NewStyle().Foreground(ld(lipgloss.Color(light), lipgloss.Color(dark)))
	}
	return styles{
		panel: lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).
			BorderForeground(ld(lipgloss.Color("61"), lipgloss.Color("62"))).Padding(0, 1),
		heading:   lipgloss.NewStyle().Bold(true).Foreground(ld(lipgloss.Color("90"), lipgloss.Color("212"))),
		label:     c("240", "241"),
		value:     c("236", "255"),
		warnValue: c("130", "214"),
		pass:      c("28", "46"),
		warn:      c("130", "214"),
		fail:      c("160", "196"),
		hint:      c("244", "245"),
		rail:      lipgloss.NewStyle().Faint(true),
	}
}
```
> IMPORTANT: copy each EXISTING style's non-color attributes verbatim (e.g. `panelStyle`'s real border type/padding, any `Bold`) — only the COLORS become `ld(light, dark)` pairs. Inspect the current `hwpanel.go`/`preflight.go`/`rail.go` definitions and preserve their structure.

- [ ] **Step 4: Wire detection + thread styles (app.go + render funcs)**

In `app.go`: add `styles styles` to `model`; in `New` set `styles: newStyles(true)` (dark default until detected); change `Init` to `return tea.Batch(railTickCmd(m.railGRBM), tea.RequestBackgroundColor())`; add `Update` case `tea.BackgroundColorMsg` → `m.styles = newStyles(msg.IsDark()); return m, nil`.

Thread `m.styles` into every render function that uses a themed style. Each such render func gains a `st styles` parameter (passed from `View`); replace `passStyle`→`st.pass`, `valueStyle`→`st.value`, `railStyle`→`st.rail`, `headingStyle`→`st.heading`, etc. across `hwpanel.go`/`preflight.go`/`rail.go`/`run.go`/`results.go`/`mode.go`/`modelpick.go`/`params.go`. Then DELETE the old package-level style vars. Update `renderRail`'s signature to take `st styles` (use `st.rail`) and update its Task-2 call site + rail tests (pass `newStyles(true)`).

- [ ] **Step 5: Fix up tests + run**

Update any render tests that referenced removed package-level vars or now-changed signatures (pass `newStyles(true)`). Then:
```
nix shell nixpkgs#go nixpkgs#gcc --command go test -race ./internal/tui/
nix shell nixpkgs#go nixpkgs#gcc --command go vet ./...
nix shell nixpkgs#go --command gofmt -l internal/tui/
nix shell nixpkgs#go nixpkgs#gcc --command go build ./...
```
Expected: all green, no remaining package-level style vars, gofmt clean.

- [ ] **Step 6: Commit**

```bash
git add pkgs/benchmark-go/internal/tui/
git commit -m "feat(tui): adaptive light/dark theming via terminal background detection"
```

---

## Task 5: Whole-flake verification + manual smoke

**Files:** none (verification)

- [ ] **Step 1: Full module + race**

Run: `cd pkgs/benchmark-go; nix shell nixpkgs#go nixpkgs#gcc --command go test -race ./...`
Expected: all 8 packages PASS.

- [ ] **Step 2: Flake build + check**

Run (from worktree root): `nix build .#benchmark && nix flake check`
Expected: binary builds; flake checks pass.

- [ ] **Step 3: Manual smoke (rail visible)**

Run: `nix run .#benchmark` in an interactive terminal. Confirm the status rail (e.g. `gfx1150 · …GB GTT · GPU N% … · AC perf … · preflight …`) shows at the top of the hardware panel AND remains visible after pressing Enter to the preflight screen. Press `q` to quit. (Can't be fully automated; eyeball it.) **Then run it once in a LIGHT-background terminal and once in a DARK one** and confirm every element (rail, panel values, preflight ✓/⚠/✗ glyphs) stays legible on both — this validates Task 4's adaptive theming.

- [ ] **Step 4: Commit any final fmt nits** (if `gofmt -l .` non-empty, fix + commit).

---

## Self-Review

**Spec coverage:**
- Top-bar rail rendered above every screen → Task 2 (View) + Task 1 (`renderRail`). ✓
- Content: arch, GTT budget, live GPU%+glyph, power, preflight summary → Task 1 segment builders. ✓
- Live ~1s ticker, app-wide → Task 1 (`railTickCmd`) + Task 2 (`Init`/`railTickMsg`). ✓
- Ticker unification (remove run-screen tick; run reads rail) → Task 3. ✓
- Preflight summary derived from stored results, refreshed on results/fix → Task 2 (step 3.4). ✓
- Narrow-terminal truncation → Task 1 (`joinFit`) + test. ✓
- `hw.GRBMBusyPct` lightweight reader as the poll → Task 1 (`defaultRailGRBM`). ✓
- Tests: pure render/segments/truncation, tick update+rearm, preflight refresh, teatest on ≥2 screens, adjusted run tests → Tasks 1–3. (teatest "rail on ≥2 screens": covered functionally by `TestRenderRailContainsArch` + the View join; add an explicit teatest only if desired — the View change guarantees the rail prefixes every screen.)
- Consent invariant unaffected → Task 3 step 4 reruns the consent tests. ✓

**Placeholder scan:** Task 1 carries a "confirm field names compile" note and Task 2/3 have "confirm/verify" notes for the exact `Update`/`View`/`fixDoneMsg` shapes — these are adapt-to-actual-code instructions for an existing file the engineer can read, with the concrete edits given, not vague placeholders. All code steps include runnable code.

**Type consistency:** `railState{gpuPct, preflight}`, `railPreflightSummary{ran, issues}`, `summarizePreflight`, `railTickMsg{pct}`, `railTickCmd(func() float64)`, `m.rail`/`m.width`/`m.railGRBM`, `renderRail(hw.Info, railState, int)` are used consistently across Tasks 1–3. The model's new `railGRBM` seam replaces run.go's removed `grbmFunc` (Task 3 repoints).
