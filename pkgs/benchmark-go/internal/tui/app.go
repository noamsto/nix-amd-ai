package tui

import (
	"context"
	"os"
	"path/filepath"

	tea "charm.land/bubbletea/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
)

// screen identifies which panel is currently active.
type screen int

const (
	screenHW screen = iota
	screenPreflight
	screenMode
	screenModel
	screenParams
	screenRun
	screenResults
)

const screenLast = screenResults

// Config holds tunable parameters for the TUI (service names, endpoints, paths).
type Config struct {
	LemondService string // default "lemond.service"
	BaseURL       string // default "http://localhost:13305"; consumed in Task 5.3/5.4
	ConfigPath    string // lemonade config path; consumed in Task 5.3/5.4
}

// model is the root bubbletea model; it holds navigation state and hw info.
type model struct {
	current          screen
	info             hw.Info
	cfg              Config
	preflightResults []preflight.Result
	preflightLoaded  bool
	modePicker       modePicker
	selectedMode     BenchMode
	modelPicker      modelPicker
	selectedModels   []string   // IDs chosen on the model picker screen
	paramsForm       paramsForm // editable run-parameter form (screenParams)

	// Live run state (screenRun). Populated by startRun.
	run runState

	// Results screen state (screenResults). Populated on transition.
	results resultsState

	// Seams for testing. nil values fall back to the real implementations:
	//   runBench → defaultRunBench (spawns llama-server / hits lemonade)
	//   grbmFunc → defaultGRBM (reads real GPU)
	//   sizeOf   → resolveModelSizeGiB (stat the GGUF file)
	// Tests inject fakes so no test touches hardware or the network.
	runBench func(ctx context.Context, req runRequest, progress chan<- tea.Msg) tea.Msg
	grbmFunc func() float64
	sizeOf   func(id string) (float64, bool)
}

// baseURL returns the configured lemonade base URL, defaulting to the standard
// local endpoint (matches the model picker's default).
func (m model) baseURL() string {
	if m.cfg.BaseURL != "" {
		return m.cfg.BaseURL
	}
	return "http://localhost:13305"
}

// configPath returns the configured lemonade config.json path, defaulting to
// the standard cache location (matches the CLI's --config-path default).
func (m model) configPath() string {
	if m.cfg.ConfigPath != "" {
		return m.cfg.ConfigPath
	}
	return filepath.Join(os.Getenv("HOME"), ".cache", "lemonade", "config.json")
}

// New returns an initialised tea.Model starting on the Hardware screen.
func New(info hw.Info, cfg Config) tea.Model {
	return model{current: screenHW, info: info, cfg: cfg}
}

// Init satisfies tea.Model; no startup command needed.
func (m model) Init() tea.Cmd { return nil }

// preflightResultsMsg carries the results of a preflight.Run call.
type preflightResultsMsg struct {
	results []preflight.Result
}

// fixDoneMsg carries the outcome of a fixer invocation.
type fixDoneMsg struct {
	err error
}

// runPreflightCmd returns a tea.Cmd that calls preflight.Run off the event loop.
func runPreflightCmd(info hw.Info, service string) tea.Cmd {
	return func() tea.Msg {
		return preflightResultsMsg{results: preflight.Run(info, service)}
	}
}

// lemondService returns the configured service name, defaulting to "lemond.service".
func (m model) lemondService() string {
	if m.cfg.LemondService != "" {
		return m.cfg.LemondService
	}
	return "lemond.service"
}

// Update handles navigation keys and delegates everything else.
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	// Live-run messages (progress/result/tick) are routed first so they're
	// handled regardless of which screen flag is set when they arrive.
	if updated, cmd, handled := m.handleRunMsg(msg); handled {
		return updated, cmd
	}

	switch msg := msg.(type) {
	case logWrittenMsg:
		return m.handleLogWritten(msg)

	case preflightResultsMsg:
		m.preflightResults = msg.results
		m.preflightLoaded = true
		return m, nil

	case modelsLoadedMsg:
		m.modelPicker.loading = false
		if msg.err != nil {
			m.modelPicker.err = msg.err
			return m, nil
		}
		sizeFunc := m.modelPicker.modelSizeGiB
		m.modelPicker.rows = buildModelRows(msg.models, m.info, sizeFunc)
		return m, nil

	case fixDoneMsg:
		// Re-run preflight after any fix attempt (error or success).
		return m, runPreflightCmd(m.info, m.lemondService())

	case tea.KeyPressMsg:
		// Screen-specific key handling for preflight fixers.
		if m.current == screenPreflight && m.preflightLoaded {
			switch msg.String() {
			case "s":
				// Stop lemond — only if the lemond result has a Fix.
				for _, r := range m.preflightResults {
					if isLemondResult(r) && r.Fix != nil {
						fix := r.Fix
						return m, func() tea.Msg {
							return fixDoneMsg{err: fix()}
						}
					}
				}
			case "p":
				// Set performance mode — only if the power result has a Fix.
				for _, r := range m.preflightResults {
					if isPowerResult(r) && r.Fix != nil {
						fix := r.Fix
						return m, func() tea.Msg {
							return fixDoneMsg{err: fix()}
						}
					}
				}
			}
		}

		// Mode picker: up/down navigation and Enter to select.
		if m.current == screenMode {
			switch msg.String() {
			case "up", "k":
				if m.modePicker.cursor > 0 {
					m.modePicker.cursor--
				}
				return m, nil
			case "down", "j":
				if m.modePicker.cursor < len(modeItems)-1 {
					m.modePicker.cursor++
				}
				return m, nil
			case "enter":
				m.selectedMode = modeItems[m.modePicker.cursor].mode
				m.current = screenModel
				return m, enterModelScreen(&m.modelPicker, m.cfg.BaseURL)
			}
		}

		// Model picker: up/down navigation, space toggles, Enter advances.
		if m.current == screenModel {
			switch msg.String() {
			case "up", "k":
				if m.modelPicker.cursor > 0 {
					m.modelPicker.cursor--
				}
				return m, nil
			case "down", "j":
				if m.modelPicker.cursor < len(m.modelPicker.rows)-1 {
					m.modelPicker.cursor++
				}
				return m, nil
			case " ":
				m.modelPicker.toggleSelected()
				return m, nil
			case "enter":
				selected := m.modelPicker.selectedIDs()
				if len(selected) == 0 {
					// Don't advance with an empty set — that would silently
					// "benchmark 0 models" once 5.4 wires real bench calls.
					m.modelPicker.needSelection = true
					return m, nil
				}
				m.selectedModels = selected
				m.current = screenParams
				enterParamsScreen(&m.paramsForm, largestSelectedGiB(&m.modelPicker))
				return m, nil
			}
		}

		// Params screen: delegate all keys to handleParamsKey before fallthrough.
		if m.current == screenParams {
			return handleParamsKey(m, msg)
		}

		// Run screen: q/Ctrl+C abort, Esc cancels back to params.
		if m.current == screenRun {
			return m.handleRunKey(msg)
		}

		// Results screen: m markdown toggle, w write log, Esc back, q quit.
		if m.current == screenResults {
			return m.handleResultsKey(msg)
		}

		switch msg.String() {
		case "enter":
			if m.current < screenLast {
				m.current++
				// Kick off preflight when entering the preflight screen.
				if m.current == screenPreflight && !m.preflightLoaded {
					return m, runPreflightCmd(m.info, m.lemondService())
				}
			}
		case "esc":
			if m.current > screenHW {
				// Leaving preflight invalidates its results: GPU/power/service
				// state may have changed (incl. via a fixer). Clear them so the
				// next Enter re-runs preflight.Run fresh rather than showing stale data.
				if m.current == screenPreflight {
					m.preflightLoaded = false
					m.preflightResults = nil
				}
				m.current--
			}
		case "ctrl+c", "q":
			return m, tea.Quit
		}
	}
	return m, nil
}

// View renders the currently active screen.
func (m model) View() tea.View {
	var s string
	switch m.current {
	case screenHW:
		s = renderHWPanel(m.info)
	case screenPreflight:
		s = renderPreflightScreen(m.preflightResults, m.preflightLoaded)
	case screenMode:
		s = renderModeScreen(m.modePicker)
	case screenModel:
		s = renderModelScreen(&m.modelPicker)
	case screenParams:
		s = renderParamsScreen(m.paramsForm)
	case screenRun:
		s = renderRunScreen(m.run)
	case screenResults:
		s = renderResults(m.run.results, m.run.err, m.results, m.info, m.sizeOf)
	default:
		s = renderHWPanel(m.info)
	}
	v := tea.NewView(s)
	v.AltScreen = true
	return v
}
