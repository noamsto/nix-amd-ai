package tui

import (
	"context"
	"fmt"
	"time"

	"charm.land/bubbles/v2/progress"
	tea "charm.land/bubbletea/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/bench"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

// grbmTickInterval is how often the live GPU% readout polls GRBM during a run.
const grbmTickInterval = time.Second

// --- request / progress / result message shapes (the goroutine→Cmd bridge) ---

// runRequest is the immutable description of the work to run, derived from the
// model's mode/selection/params when entering screenRun.
type runRequest struct {
	mode     BenchMode
	models   []string
	params   RunParams
	baseURL  string
	promptTk int
	genTk    int
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

// grbmTickMsg carries a fresh GPU GRBM% reading.
type grbmTickMsg struct {
	pct float64
}

// --- completed-results shape (consumed by results.go in 5.4b) ---

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
	err      error
	results  runResults
	grbmPct  float64
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
// runner goroutine and starts listening + the GRBM tick. Called when entering
// screenRun.
func (m *model) startRun() tea.Cmd {
	req := runRequest{
		mode:     m.selectedMode,
		models:   m.selectedModels,
		params:   m.paramsForm.runParams(),
		baseURL:  m.baseURL(),
		promptTk: defaultPromptTokens,
		genTk:    defaultGenTokens,
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
	// only reader; closing would race a late progress send). The buffered
	// channel + ctx cancellation guarantee the goroutine cannot block forever:
	// on abort we cancel ctx (bench stops) and the goroutine drains to its
	// final send into the 64-deep buffer, then exits — no leak.
	go func() {
		ch <- runner(ctx, req, ch)
	}()

	return tea.Batch(waitForRunMsg(ch), grbmTickCmd(m.grbmFunc))
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

// grbmTickCmd returns a Cmd that, after grbmTickInterval, reads the GRBM% via
// grbm (defaulting to a real hw read) and emits a grbmTickMsg.
func grbmTickCmd(grbm func() float64) tea.Cmd {
	read := grbm
	if read == nil {
		read = defaultGRBM
	}
	return tea.Tick(grbmTickInterval, func(time.Time) tea.Msg {
		return grbmTickMsg{pct: read()}
	})
}

// defaultGRBM reads the live GPU GRBM busy percentage from hardware.
func defaultGRBM() float64 { return hw.Detect().GRBMBusyPct }

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
		if m.run.cancel != nil {
			m.run.cancel()
		}
		return m, tea.Quit
	case "esc":
		// Esc aborts mid-run (same as q-without-quit): cancel and go back. After
		// completion, Esc is harmless (run already done) and returns to params.
		if m.run.active && !m.run.done && m.run.cancel != nil {
			m.run.cancel()
		}
		m.run.active = false
		m.current = screenParams
		return m, nil
	}
	return m, nil
}

// handleRunMsg processes progress/result/tick messages while a run is in flight.
func (m model) handleRunMsg(msg tea.Msg) (tea.Model, tea.Cmd, bool) {
	switch msg := msg.(type) {
	case runProgressMsg:
		m.run.applyProgress(msg)
		// Re-issue the listen Cmd to read the next message off the channel.
		return m, waitForRunMsg(m.run.ch), true

	case runResultMsg:
		m.run.done = true
		m.run.active = false
		m.run.err = msg.err
		m.run.results = msg.results
		m.current = screenResults
		// Stop reading the channel and stop the GRBM tick (no new Cmd).
		return m, nil, true

	case grbmTickMsg:
		m.run.grbmPct = msg.pct
		// Keep ticking only while the run is active.
		if m.run.active && !m.run.done {
			return m, grbmTickCmd(m.grbmFunc), true
		}
		return m, nil, true
	}
	return m, nil, false
}

// --- default real runner ---

// defaultPromptTokens / defaultGenTokens mirror the CLI defaults for the
// live-run workload (cli.go: prompt-tokens=512, gen-tokens=128).
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
				progress <- runProgressMsg{
					specKey:   key,
					label:     fmt.Sprintf("%s [%s] MTP %s", modelID, backend, spec),
					iter:      iter,
					total:     req.params.Repeat,
					decodeTPS: tps,
				}
			},
		}
		abResults, err := bench.RunMTPAB(opts)
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

// runHTTPLive benchmarks each selected model via the lemonade HTTP server,
// streaming per-iteration progress. Used for HTTP and Backend A/B modes.
func runHTTPLive(ctx context.Context, req runRequest, progress chan<- tea.Msg) tea.Msg {
	var res runResults
	res.Mode = req.mode

	for _, modelID := range req.models {
		if ctx.Err() != nil {
			return runResultMsg{results: res, err: ctx.Err()}
		}
		var samples []float64
		key := modelID
		opts := bench.BenchmarkModelOpts{
			BaseURL:      req.baseURL,
			ModelID:      modelID,
			PromptTokens: req.promptTk,
			GenTokens:    req.genTk,
			Warmup:       req.params.Warmup,
			Repeat:       req.params.Repeat,
			OnIteration: func(iter int, tps float64) {
				samples = append(samples, tps)
				progress <- runProgressMsg{
					specKey:   key,
					label:     modelID,
					iter:      iter,
					total:     req.params.Repeat,
					decodeTPS: tps,
				}
			},
		}
		r, err := bench.BenchmarkModel(opts)
		if err != nil {
			return runResultMsg{results: res, err: err}
		}
		res.Units = append(res.Units, runUnitResult{
			Model:    modelID,
			Samples:  samples,
			MeanTPS:  r.MeanTPS,
			StdevTPS: r.StdevTPS,
			MeanTTFT: r.MeanTTFT,
		})
	}
	return runResultMsg{results: res}
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
	var b []byte
	out := func(str string) { b = append(b, str...) }

	out(headingStyle.Render("Running Benchmark") + "\n\n")
	out(valueStyle.Render(fmt.Sprintf("GPU: %.0f%%", s.grbmPct)) + "\n\n")

	if len(s.order) == 0 {
		out(hintStyle.Render("Starting…") + "\n")
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
		out(labelStyle.Render(u.label) + "\n")
		out(fmt.Sprintf("  %s  %d/%d\n", bar, u.iter, u.total))
		out("  " + hintStyle.Render(renderRunningStat(u.samples)+" tok/s") + "\n\n")
	}

	out("\n" + labelStyle.Render("q/Ctrl+C abort"))
	return panelStyle.Render(string(b))
}
