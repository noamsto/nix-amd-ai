package tui

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"charm.land/bubbles/v2/progress"
	tea "charm.land/bubbletea/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/bench"
)

// lemondReadyTimeout bounds how long runBackendABLive waits for lemond to come
// back after a restart (matches the CLI's 60s).
const lemondReadyTimeout = 60 * time.Second

// stderrSink is where the runner goroutine logs best-effort config-restore
// failures (rare). A var so tests can redirect it and assert on the output.
var stderrSink io.Writer = os.Stderr

// --- request / progress / result message shapes (the goroutine→Cmd bridge) ---

// runRequest is the immutable description of the work to run, derived from the
// model's mode/selection/params when entering screenRun.
type runRequest struct {
	mode    BenchMode
	models  []string
	params  RunParams
	baseURL string
	// configPath / lemondService drive the Backend A/B switch
	// (mirrors the CLI's --config-path / --lemond-service).
	configPath    string
	lemondService string
	promptTk      int
	genTk         int
}

// runProgressMsg is pushed onto the progress channel after each measured
// iteration. specKey identifies the (model[,backend,spec]) unit; total is the
// expected number of measured iterations for that unit (params.Repeat).
type runProgressMsg struct {
	specKey   string
	label     string  // human-readable unit label for the bar
	iter      int     // 1-based measured-iteration index within the unit
	total     int     // expected measured iterations (Repeat)
	decodeTPS float64 // this iteration's decode t/s
}

// runResultMsg is the single terminal message: the run finished (or errored).
// It carries the completed results for the results screen to consume.
type runResultMsg struct {
	results runResults
	err     error
}

// --- completed-results shape ---

// runUnitResult holds the aggregated outcome of one measured unit. The unit is
// a (model, backend, spec) tuple that fits all three modes:
//   - HTTP: backend = "" (or forced), spec = ""
//   - Backend A/B: spec = "", backend in {rocm, vulkan}
//   - MTP A/B: spec in {off, on}, backend in {rocm, vulkan}
//
// Samples holds the per-iteration decode t/s so the results screen can recompute
// mean/stdev or show distributions. MeanTPS/StdevTPS/MeanTTFT are nil when no
// successful iterations were collected (matches bench's N/A contract).
type runUnitResult struct {
	Model    string
	Backend  string // "" for plain HTTP
	Spec     string // "", "off", "on"
	Samples  []float64
	MeanTPS  *float64
	StdevTPS *float64
	MeanTTFT *float64
}

// runResults is the full set of completed units, in stable display order.
type runResults struct {
	Mode  BenchMode
	Units []runUnitResult
}

// --- live run state on the root model ---

// runState holds everything the live run screen needs while a benchmark is in
// flight. It lives on the root model so Update can mutate it across messages.
type runState struct {
	active   bool
	done     bool
	aborted  bool // set on Esc/quit; makes handleRunMsg drop late goroutine output
	err      error
	results  runResults
	progress progress.Model

	// units tracks per-unit running samples for the live mean±stdev readout,
	// keyed by specKey, with insertion order preserved in order.
	units map[string]*runUnitProgress
	order []string

	// ch carries progress + the final result from the runner goroutine.
	ch chan tea.Msg
	// cancel cancels the runner's context on quit/abort.
	cancel context.CancelFunc
}

// runUnitProgress is the live accumulation for one measured unit.
type runUnitProgress struct {
	label   string
	iter    int
	total   int
	samples []float64
}

// startRun initialises run state and returns the command that kicks off the
// runner goroutine and starts listening. Called when entering screenRun.
func (m *model) startRun() tea.Cmd {
	req := runRequest{
		mode:          m.selectedMode,
		models:        m.selectedModels,
		params:        m.paramsForm.runParams(),
		baseURL:       m.baseURL(),
		configPath:    m.configPath(),
		lemondService: m.lemondService(),
		promptTk:      defaultPromptTokens,
		genTk:         defaultGenTokens,
	}

	ctx, cancel := context.WithCancel(context.Background())
	ch := make(chan tea.Msg, 64)

	m.run = runState{
		active:   true,
		progress: progress.New(progress.WithWidth(40), progress.WithoutPercentage()),
		units:    map[string]*runUnitProgress{},
		ch:       ch,
		cancel:   cancel,
	}

	runner := m.runBench
	if runner == nil {
		runner = defaultRunBench
	}

	// The goroutine sends progress messages on ch as they arrive, then sends a
	// single runResultMsg and returns. It never closes ch (the model holds the
	// only reader; closing would race a late progress send). It cannot block
	// forever: every send (progress and the final result) is a non-blocking
	// select against ctx.Done() (see sendMsg), so once we cancel ctx on abort —
	// even if the reader stopped on tea.Quit and the 64-deep buffer is full —
	// the goroutine takes the ctx.Done() branch and exits. No leak.
	go func() {
		sendMsg(ctx, ch, runner(ctx, req, ch))
	}()

	return waitForRunMsg(ch)
}

// waitForRunMsg returns a Cmd that blocks on the channel for the next message
// (progress or result) and returns it. The Update handler re-issues this Cmd
// after every runProgressMsg, so the channel is drained one message per Cmd
// until the runResultMsg arrives. This is the standard bubbletea "listen on a
// channel via repeated Cmd" pattern; bench is never called inline in Update.
func waitForRunMsg(ch <-chan tea.Msg) tea.Cmd {
	return func() tea.Msg {
		return <-ch
	}
}

// sendMsg delivers msg to ch unless ctx is already (or becomes) cancelled, in
// which case it drops the message and returns. This is what keeps the runner
// goroutine from blocking forever on a full channel after an abort: the UI may
// have stopped reading (tea.Quit), but cancelling ctx unblocks the send.
func sendMsg(ctx context.Context, ch chan<- tea.Msg, msg tea.Msg) {
	select {
	case ch <- msg:
	case <-ctx.Done():
	}
}

// applyProgress records one measured iteration into run state.
func (s *runState) applyProgress(msg runProgressMsg) {
	u, ok := s.units[msg.specKey]
	if !ok {
		u = &runUnitProgress{label: msg.label, total: msg.total}
		s.units[msg.specKey] = u
		s.order = append(s.order, msg.specKey)
	}
	u.iter = msg.iter
	u.total = msg.total
	if msg.label != "" {
		u.label = msg.label
	}
	u.samples = append(u.samples, msg.decodeTPS)
}

// handleRunKey processes key presses while on screenRun.
func (m model) handleRunKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		// Abort: cancel the runner's context (bench stops cleanly) and quit.
		// Mark aborted so any in-flight goroutine output is dropped.
		m.run.aborted = true
		m.run.active = false
		if m.run.cancel != nil {
			m.run.cancel()
		}
		return m, tea.Quit
	case "esc":
		// Esc aborts mid-run (cancel + back to params). After completion it's a
		// plain back-navigation (run already done).
		if m.run.active && !m.run.done {
			m.run.aborted = true
			if m.run.cancel != nil {
				m.run.cancel()
			}
		}
		m.run.active = false
		m.current = screenParams
		return m, nil
	}
	return m, nil
}

// handleRunMsg processes progress/result/tick messages while a run is in flight.
//
// Once a run is aborted, late goroutine output (progress that was already in
// flight, or the terminal result the cancelled runner still emits) is dropped:
// it must not re-navigate to screenResults or mutate m.run.units after the user
// has left the run screen.
func (m model) handleRunMsg(msg tea.Msg) (tea.Model, tea.Cmd, bool) {
	switch msg := msg.(type) {
	case runProgressMsg:
		if m.run.aborted {
			return m, nil, true
		}
		m.run.applyProgress(msg)
		// Re-issue the listen Cmd to read the next message off the channel.
		return m, waitForRunMsg(m.run.ch), true

	case runResultMsg:
		if m.run.aborted {
			// Stop reading; do not transition or store the cancelled result.
			return m, nil, true
		}
		m.run.done = true
		m.run.active = false
		m.run.err = msg.err
		m.run.results = msg.results
		m.current = screenResults
		return m, nil, true
	}
	return m, nil, false
}

// --- default real runner ---

// defaultPromptTokens / defaultGenTokens mirror the CLI defaults.
const (
	defaultPromptTokens = 512
	defaultGenTokens    = 128
)

// defaultRunBench is the production runner. It dispatches on mode and wires
// bench's OnIteration callback to push runProgressMsg onto progress. It returns
// the terminal runResultMsg. ctx cancellation aborts in-flight bench work.
func defaultRunBench(ctx context.Context, req runRequest, progress chan<- tea.Msg) tea.Msg {
	switch req.mode {
	case ModeMTP:
		return runMTPLive(ctx, req, progress)
	case ModeBackend:
		return runBackendABLive(ctx, req, progress)
	default:
		return runHTTPLive(ctx, req, progress)
	}
}

// runMTPLive runs the MTP A/B sweep for each selected model, streaming progress.
func runMTPLive(ctx context.Context, req runRequest, progress chan<- tea.Msg) tea.Msg {
	var res runResults
	res.Mode = req.mode

	for _, modelID := range req.models {
		if ctx.Err() != nil {
			return runResultMsg{results: res, err: ctx.Err()}
		}
		// Accumulate samples per (backend, spec) via OnIteration.
		acc := map[string][]float64{}
		opts := bench.MTPABOpts{
			ModelID:      modelID,
			Backends:     req.params.Backends,
			PromptTokens: req.promptTk,
			GenTokens:    req.genTk,
			Warmup:       req.params.Warmup,
			Repeat:       req.params.Repeat,
			CtxSize:      req.params.Ctx,
			OnIteration: func(backend, specType string, iter int, tps float64) {
				spec := specLabel(specType)
				key := mtpKey(modelID, backend, spec)
				acc[key] = append(acc[key], tps)
				sendMsg(ctx, progress, runProgressMsg{
					specKey:   key,
					label:     fmt.Sprintf("%s [%s] MTP %s", modelID, backend, spec),
					iter:      iter,
					total:     req.params.Repeat,
					decodeTPS: tps,
				})
			},
		}
		abResults, err := bench.RunMTPAB(ctx, opts)
		if err != nil {
			return runResultMsg{results: res, err: err}
		}
		for _, ab := range abResults {
			res.Units = append(res.Units, mtpUnit(modelID, ab.Backend, "off", ab.OffTPS, acc[mtpKey(modelID, ab.Backend, "off")]))
			res.Units = append(res.Units, mtpUnit(modelID, ab.Backend, "on", ab.OnTPS, acc[mtpKey(modelID, ab.Backend, "on")]))
		}
	}
	return runResultMsg{results: res}
}

// runHTTPLive benchmarks each model against the current server (no backend switch).
func runHTTPLive(ctx context.Context, req runRequest, progress chan<- tea.Msg) tea.Msg {
	var res runResults
	res.Mode = req.mode

	units, err := benchmarkModelsLive(ctx, req, "", progress)
	res.Units = units
	if err != nil {
		return runResultMsg{results: res, err: err}
	}
	return runResultMsg{results: res}
}

// runBackendABLive runs a real rocm-vs-vulkan A/B: for each backend it rewrites
// lemonade's config, restarts lemond, waits for it to come back, then
// benchmarks every selected model against that backend and tags the units with
// it. The original backend is restored (and lemond restarted) on every return
// path via the deferred cleanup. Mirrors cli.runHeadlessLemonade's backend
// loop, but sweeps multiple backends in one run.
func runBackendABLive(ctx context.Context, req runRequest, progress chan<- tea.Msg) tea.Msg {
	var res runResults
	res.Mode = req.mode

	backends := req.params.Backends
	if len(backends) == 0 {
		return runResultMsg{results: res, err: fmt.Errorf("backend A/B: empty backend list")}
	}

	// Capture the current backend once, before the first switch, so we restore
	// to the real pre-run value rather than the last backend we set.
	origBackend, err := bench.SetLlamacppBackend(req.configPath, backends[0])
	if err != nil {
		return runResultMsg{results: res, err: fmt.Errorf("writing lemonade config: %w", err)}
	}
	// Single restore site, armed the moment the config is first written: runs on
	// success, error, or abort. Restore is best-effort — its failure must not
	// mask the benchmark error/result, so we only log to stderr.
	defer func() {
		if rErr := bench.RestoreLlamacppBackend(req.configPath, origBackend); rErr != nil {
			fmt.Fprintf(stderrSink, "WARNING: failed to restore lemonade config: %v\n", rErr)
		}
		// TUI always restarts lemond on cleanup.
		if rErr := bench.RestartLemond(req.lemondService); rErr != nil {
			fmt.Fprintf(stderrSink, "WARNING: failed to restart lemond during cleanup: %v\n", rErr)
		}
	}()

	for i, backend := range backends {
		if ctx.Err() != nil {
			return runResultMsg{results: res, err: ctx.Err()}
		}
		// backends[0] is already written above; switch for the rest.
		if i > 0 {
			if _, sErr := bench.SetLlamacppBackend(req.configPath, backend); sErr != nil {
				return runResultMsg{results: res, err: fmt.Errorf("[%s] writing config: %w", backend, sErr)}
			}
		}
		// TUI always restarts lemond between backends.
		if rErr := bench.RestartLemond(req.lemondService); rErr != nil {
			return runResultMsg{results: res, err: fmt.Errorf("[%s] restart lemond: %w", backend, rErr)}
		}
		if wErr := bench.WaitForLemond(req.baseURL, lemondReadyTimeout); wErr != nil {
			return runResultMsg{results: res, err: fmt.Errorf("[%s] waiting for lemond: %w", backend, wErr)}
		}

		units, bErr := benchmarkModelsLive(ctx, req, backend, progress)
		res.Units = append(res.Units, units...)
		if bErr != nil {
			return runResultMsg{results: res, err: bErr}
		}
	}
	return runResultMsg{results: res}
}

// benchmarkModelsLive benchmarks every model against the current server, streaming
// progress. On error it returns units accumulated so far plus the error.
func benchmarkModelsLive(ctx context.Context, req runRequest, backend string, progress chan<- tea.Msg) ([]runUnitResult, error) {
	var units []runUnitResult
	for _, modelID := range req.models {
		if ctx.Err() != nil {
			return units, ctx.Err()
		}
		var samples []float64
		key := httpKey(modelID, backend)
		label := modelID
		if backend != "" {
			label = fmt.Sprintf("%s [%s]", modelID, backend)
		}
		opts := bench.BenchmarkModelOpts{
			BaseURL:      req.baseURL,
			ModelID:      modelID,
			PromptTokens: req.promptTk,
			GenTokens:    req.genTk,
			Warmup:       req.params.Warmup,
			Repeat:       req.params.Repeat,
			OnIteration: func(iter int, tps float64) {
				samples = append(samples, tps)
				sendMsg(ctx, progress, runProgressMsg{
					specKey:   key,
					label:     label,
					iter:      iter,
					total:     req.params.Repeat,
					decodeTPS: tps,
				})
			},
		}
		r, err := bench.BenchmarkModel(ctx, opts)
		if err != nil {
			return units, err
		}
		units = append(units, runUnitResult{
			Model:    modelID,
			Backend:  backend,
			Samples:  samples,
			MeanTPS:  r.MeanTPS,
			StdevTPS: r.StdevTPS,
			MeanTTFT: r.MeanTTFT,
		})
	}
	return units, nil
}

// httpKey builds the per-unit progress key for HTTP / Backend A/B modes.
func httpKey(model, backend string) string {
	if backend == "" {
		return model
	}
	return model + "|" + backend
}

// specLabel maps bench's spec-type to the compact UI label.
func specLabel(specType string) string {
	if specType == "draft-mtp" {
		return "on"
	}
	return "off"
}

// mtpKey builds the per-unit progress key for MTP mode.
func mtpKey(model, backend, spec string) string {
	return model + "|" + backend + "|" + spec
}

// mtpUnit builds a runUnitResult for one MTP (backend, spec) outcome.
func mtpUnit(model, backend, spec string, meanTPS *float64, samples []float64) runUnitResult {
	u := runUnitResult{
		Model:   model,
		Backend: backend,
		Spec:    spec,
		Samples: samples,
		MeanTPS: meanTPS,
	}
	if len(samples) > 0 {
		_, sd := bench.MeanStdev(samples)
		u.StdevTPS = &sd
	}
	return u
}

// --- render ---

// renderRunningStat formats the running mean±stdev for a sample slice. Empty →
// "…" (no samples yet). Single sample → "X.X +/- 0.0".
func renderRunningStat(samples []float64) string {
	if len(samples) == 0 {
		return "…"
	}
	mean, sd := bench.MeanStdev(samples)
	return fmt.Sprintf("%.1f +/- %.1f", mean, sd)
}

// renderRunScreen renders the live run panel.
func renderRunScreen(s runState) string {
	var b strings.Builder

	b.WriteString(headingStyle.Render("Running Benchmark") + "\n\n")

	if len(s.order) == 0 {
		b.WriteString(hintStyle.Render("Starting…") + "\n")
	}

	for _, key := range s.order {
		u := s.units[key]
		frac := 0.0
		if u.total > 0 {
			frac = float64(u.iter) / float64(u.total)
			if frac > 1 {
				frac = 1
			}
		}
		bar := s.progress.ViewAs(frac)
		b.WriteString(labelStyle.Render(u.label) + "\n")
		b.WriteString(fmt.Sprintf("  %s  %d/%d\n", bar, u.iter, u.total))
		b.WriteString("  " + hintStyle.Render(renderRunningStat(u.samples)+" tok/s") + "\n\n")
	}

	b.WriteString("\n" + labelStyle.Render("q/Ctrl+C abort"))
	return panelStyle.Render(b.String())
}
