package tui

import (
	"bytes"
	"context"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/exp/teatest/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

// startAndPump sends Enter (which starts the run) and then synchronously pumps
// the runner's channel through Update — reading one message via waitForRunMsg,
// feeding it to Update, and repeating until the runResultMsg transitions to
// screenResults. This mirrors how bubbletea's loop drains the channel, without
// spinning the real event loop.
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
// runner, ready for Enter to start the run.
func newRunModel(runner func(context.Context, runRequest, chan<- tea.Msg) tea.Msg) model {
	m := New(testHWInfo(), Config{}).(model)
	m.current = screenParams
	m.selectedMode = ModeHTTP
	m.selectedModels = []string{"modelA"}
	m.paramsForm = defaultParamsForm()
	m.runBench = runner
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

	m := newRunModel(fakeRunBench(prog, want, nil))

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
	m := newRunModel(fakeRunBench(nil, runResults{}, boom))
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
	m := newRunModel(runner)

	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(120, 40))
	t.Cleanup(func() { _ = tm.Quit() })

	tm.Send(tea.KeyPressMsg{Code: tea.KeyEnter})

	// GPU% is now in the rail bar above the run screen (format: "GPU 0%"), not in
	// the run panel itself.
	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Running Benchmark")) && bytes.Contains(out, []byte("GPU "))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}

// TestAbortDropsLateProgress verifies that once a run is aborted, a late
// runProgressMsg is dropped: it must not mutate m.run.units.
func TestAbortDropsLateProgress(t *testing.T) {
	m := newRunModel(fakeRunBench(nil, runResults{}, nil))
	m.run = runState{active: true, aborted: true, units: map[string]*runUnitProgress{}}

	tm, _, handled := m.handleRunMsg(runProgressMsg{specKey: "x", iter: 1, total: 3, decodeTPS: 9})
	if !handled {
		t.Fatal("runProgressMsg not handled")
	}
	if got := tm.(model); len(got.run.units) != 0 {
		t.Errorf("aborted run recorded %d units; want 0 (late progress dropped)", len(got.run.units))
	}
}

// TestAbortDropsLateResult verifies that a late runResultMsg after abort does
// not navigate to screenResults or store the cancelled result.
func TestAbortDropsLateResult(t *testing.T) {
	m := newRunModel(fakeRunBench(nil, runResults{}, nil))
	m.current = screenParams // user already went back via Esc
	m.run = runState{aborted: true, units: map[string]*runUnitProgress{}}

	tm, cmd, handled := m.handleRunMsg(runResultMsg{results: runResults{Units: []runUnitResult{{Model: "m"}}}})
	if !handled {
		t.Fatal("runResultMsg not handled")
	}
	got := tm.(model)
	if got.current != screenParams {
		t.Errorf("aborted late result navigated to %v; want it to stay on screenParams", got.current)
	}
	if len(got.run.results.Units) != 0 {
		t.Errorf("aborted late result stored %d units; want 0", len(got.run.results.Units))
	}
	if cmd != nil {
		t.Error("aborted late result re-issued a read Cmd; want nil")
	}
}

// TestEscAbortsRun verifies Esc mid-run cancels the context, marks aborted, and
// returns to the params screen.
func TestEscAbortsRun(t *testing.T) {
	m := newRunModel(fakeRunBench(nil, runResults{}, nil))
	canceled := false
	m.run = runState{active: true, cancel: func() { canceled = true }, units: map[string]*runUnitProgress{}}

	tm, _ := m.handleRunKey(tea.KeyPressMsg{Code: tea.KeyEscape})
	got := tm.(model)
	if !canceled {
		t.Error("Esc did not cancel the run context")
	}
	if !got.run.aborted {
		t.Error("Esc did not set aborted")
	}
	if got.current != screenParams {
		t.Errorf("Esc left current = %v; want screenParams", got.current)
	}
}

// TestSendMsgDropsOnCancel verifies the goroutine's send cannot block when the
// reader is gone and the channel buffer is full, once ctx is cancelled.
func TestSendMsgDropsOnCancel(t *testing.T) {
	ch := make(chan tea.Msg) // unbuffered, no reader → a plain send would block
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	done := make(chan struct{})
	go func() {
		sendMsg(ctx, ch, runProgressMsg{specKey: "x"})
		close(done)
	}()
	select {
	case <-done:
		// Took the ctx.Done() branch — no block.
	case <-time.After(2 * time.Second):
		t.Fatal("sendMsg blocked on a full channel after ctx cancel")
	}
}

// TestBackendABDispatch verifies ModeBackend routes to runBackendABLive (not the
// HTTP default). With an empty backend list it returns an error result without
// touching any system command, proving the dispatch reached the A/B path.
func TestBackendABDispatch(t *testing.T) {
	req := runRequest{mode: ModeBackend, models: []string{"m"}, params: RunParams{}}
	ch := make(chan tea.Msg, 1)
	msg := defaultRunBench(context.Background(), req, ch)
	res, ok := msg.(runResultMsg)
	if !ok {
		t.Fatalf("got %T, want runResultMsg", msg)
	}
	if res.err == nil {
		t.Error("expected error from runBackendABLive with empty backend list")
	}
}

// TestHTTPKey covers the per-unit progress key builder.
func TestHTTPKey(t *testing.T) {
	if got := httpKey("m", ""); got != "m" {
		t.Errorf("httpKey(m, '') = %q, want m", got)
	}
	if got := httpKey("m", "rocm"); got != "m|rocm" {
		t.Errorf("httpKey(m, rocm) = %q, want m|rocm", got)
	}
}

// testHWInfo is a minimal hw.Info for white-box tests.
func testHWInfo() hw.Info { return hw.Info{GfxArch: "gfx1150"} }
