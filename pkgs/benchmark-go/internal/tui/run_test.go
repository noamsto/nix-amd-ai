package tui

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/exp/teatest/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

// startAndPump sends Enter (which starts the run) and then synchronously pumps
// the runner's channel through Update — reading one message via waitForRunMsg,
// feeding it to Update, and repeating until the runResultMsg transitions to
// screenResults. The GRBM Tick command returned by startRun is intentionally
// NOT executed (it would block on a real timer); grbm behaviour is covered by
// dedicated tick tests. This mirrors how bubbletea's loop drains the channel,
// without spinning the real event loop.
func startAndPump(t *testing.T, m model) model {
	t.Helper()
	tm, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m = tm.(model)
	if m.run.ch == nil {
		t.Fatal("startRun did not create a channel")
	}
	for range 1000 {
		if m.current == screenResults {
			return m
		}
		msg := waitForRunMsg(m.run.ch)()
		tm, _ := m.Update(msg)
		m = tm.(model)
	}
	t.Fatal("run did not reach screenResults after 1000 messages")
	return m
}

// TestRenderRunningStat covers the pure formatting helper.
func TestRenderRunningStat(t *testing.T) {
	if got := renderRunningStat(nil); got != "…" {
		t.Errorf("empty samples = %q, want …", got)
	}
	if got := renderRunningStat([]float64{12.0}); got != "12.0 +/- 0.0" {
		t.Errorf("single sample = %q, want 12.0 +/- 0.0", got)
	}
	// mean of {12,13} = 12.5; sample stdev = ~0.707 → "0.7".
	if got := renderRunningStat([]float64{12.0, 13.0}); got != "12.5 +/- 0.7" {
		t.Errorf("two samples = %q, want 12.5 +/- 0.7", got)
	}
}

// fakeRunBench returns a runner that emits the given progress messages then a
// terminal result, all via the channel. It never touches hardware/network.
func fakeRunBench(prog []runProgressMsg, result runResults, runErr error) func(context.Context, runRequest, chan<- tea.Msg) tea.Msg {
	return func(_ context.Context, _ runRequest, ch chan<- tea.Msg) tea.Msg {
		for _, p := range prog {
			ch <- p
		}
		return runResultMsg{results: result, err: runErr}
	}
}

// newRunModel builds a model parked on screenParams with an injected fake
// runner and grbm seam, ready for Enter to start the run.
func newRunModel(runner func(context.Context, runRequest, chan<- tea.Msg) tea.Msg, grbm func() float64) model {
	m := New(testHWInfo(), Config{}).(model)
	m.current = screenParams
	m.selectedMode = ModeHTTP
	m.selectedModels = []string{"modelA"}
	m.paramsForm = defaultParamsForm()
	m.runBench = runner
	m.grbmFunc = grbm
	return m
}

// TestRunScreenStreamsAndTransitions drives a fake run end-to-end: progress
// updates the running stats, and the terminal result transitions to results.
func TestRunScreenStreamsAndTransitions(t *testing.T) {
	prog := []runProgressMsg{
		{specKey: "modelA", label: "modelA", iter: 1, total: 2, decodeTPS: 10},
		{specKey: "modelA", label: "modelA", iter: 2, total: 2, decodeTPS: 12},
	}
	mean := 11.0
	want := runResults{Mode: ModeHTTP, Units: []runUnitResult{{Model: "modelA", MeanTPS: &mean}}}

	m := newRunModel(fakeRunBench(prog, want, nil), func() float64 { return 0 })

	// Enter starts the run; drive consumes all channel messages synchronously.
	m = startAndPump(t, m)

	if m.current != screenResults {
		t.Fatalf("current = %v, want screenResults", m.current)
	}
	if len(m.run.results.Units) != 1 {
		t.Fatalf("stored %d units, want 1", len(m.run.results.Units))
	}
	if m.run.results.Units[0].Model != "modelA" {
		t.Errorf("stored model = %q, want modelA", m.run.results.Units[0].Model)
	}
	// The unit accumulated both samples → running mean 11.0.
	u := m.run.units["modelA"]
	if u == nil || len(u.samples) != 2 {
		t.Fatalf("unit samples = %v, want 2 samples", u)
	}
	if got := renderRunningStat(u.samples); got != "11.0 +/- 1.4" {
		t.Errorf("running stat = %q, want 11.0 +/- 1.4", got)
	}
}

// TestRunScreenStoresError ensures a runner error still transitions and is kept.
func TestRunScreenStoresError(t *testing.T) {
	boom := errContext{"boom"}
	m := newRunModel(fakeRunBench(nil, runResults{}, boom), func() float64 { return 0 })
	m = startAndPump(t, m)

	if m.current != screenResults {
		t.Fatalf("current = %v, want screenResults", m.current)
	}
	if m.run.err == nil {
		t.Error("expected run.err to be set")
	}
}

// errContext is a tiny error type to avoid importing errors in the test.
type errContext struct{ s string }

func (e errContext) Error() string { return e.s }

// TestGRBMTickUpdatesReadout asserts the grbmFunc seam feeds the GPU% readout.
func TestGRBMTickUpdatesReadout(t *testing.T) {
	m := newRunModel(fakeRunBench(nil, runResults{}, nil), func() float64 { return 73 })
	// Start the run but don't drive the result yet: mark active and inject a tick.
	m.run = runState{active: true, units: map[string]*runUnitProgress{}}
	m.grbmFunc = func() float64 { return 73 }

	tm, _, handled := m.handleRunMsg(grbmTickMsg{pct: 73})
	if !handled {
		t.Fatal("grbmTickMsg not handled")
	}
	updated := tm.(model)
	if updated.run.grbmPct != 73 {
		t.Errorf("grbmPct = %v, want 73", updated.run.grbmPct)
	}
	// The rendered run screen shows the GPU readout.
	if got := renderRunScreen(updated.run); !strings.Contains(got, "GPU: 73%") {
		t.Errorf("render missing GPU readout; got:\n%s", got)
	}
}

// TestGRBMTickStopsAfterDone verifies the tick does not re-arm once the run is
// done (no goroutine/timer leak after completion).
func TestGRBMTickStopsAfterDone(t *testing.T) {
	m := newRunModel(fakeRunBench(nil, runResults{}, nil), func() float64 { return 5 })
	m.run = runState{done: true, active: false, units: map[string]*runUnitProgress{}}
	_, cmd, handled := m.handleRunMsg(grbmTickMsg{pct: 5})
	if !handled {
		t.Fatal("tick not handled")
	}
	if cmd != nil {
		t.Error("tick re-armed after run done; expected nil cmd")
	}
}

// TestRunScreenHeaderRenders is a teatest integration check: with an injected
// fake runner that emits one slow-ish progress message, the run screen renders
// its header and the live GPU readout before completing.
func TestRunScreenHeaderRenders(t *testing.T) {
	runner := func(_ context.Context, _ runRequest, ch chan<- tea.Msg) tea.Msg {
		ch <- runProgressMsg{specKey: "modelA", label: "modelA", iter: 1, total: 3, decodeTPS: 9}
		// Hold the run open briefly so the run screen is observable before the
		// terminal result transitions to the results screen.
		time.Sleep(150 * time.Millisecond)
		return runResultMsg{results: runResults{Units: []runUnitResult{{Model: "modelA"}}}}
	}
	m := newRunModel(runner, func() float64 { return 0 })

	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(120, 40))
	t.Cleanup(func() { _ = tm.Quit() })

	tm.Send(tea.KeyPressMsg{Code: tea.KeyEnter})

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Running Benchmark")) && bytes.Contains(out, []byte("GPU:"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}

// testHWInfo is a minimal hw.Info for white-box tests.
func testHWInfo() hw.Info { return hw.Info{GfxArch: "gfx1150"} }
