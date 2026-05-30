package tui

import (
	tea "github.com/charmbracelet/bubbletea"

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
	BaseURL       string // default "http://localhost:13305"
	ConfigPath    string // lemonade config path
}

// model is the root bubbletea model; it holds navigation state and hw info.
type model struct {
	current          screen
	info             hw.Info
	cfg              Config
	preflightResults []preflight.Result
	preflightLoaded  bool
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
	switch msg := msg.(type) {
	case preflightResultsMsg:
		m.preflightResults = msg.results
		m.preflightLoaded = true
		return m, nil

	case fixDoneMsg:
		// Re-run preflight after any fix attempt (error or success).
		return m, runPreflightCmd(m.info, m.lemondService())

	case tea.KeyMsg:
		// Screen-specific key handling for preflight fixers.
		if m.current == screenPreflight && m.preflightLoaded {
			switch string(msg.Runes) {
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

		switch msg.Type {
		case tea.KeyEnter:
			if m.current < screenLast {
				m.current++
				// Kick off preflight when entering the preflight screen.
				if m.current == screenPreflight && !m.preflightLoaded {
					return m, runPreflightCmd(m.info, m.lemondService())
				}
			}
		case tea.KeyEsc:
			if m.current > screenHW {
				m.current--
			}
		case tea.KeyCtrlC:
			return m, tea.Quit
		case tea.KeyRunes:
			if string(msg.Runes) == "q" {
				return m, tea.Quit
			}
		}
	}
	return m, nil
}

// View renders the currently active screen.
func (m model) View() string {
	switch m.current {
	case screenHW:
		return renderHWPanel(m.info)
	case screenPreflight:
		return renderPreflightScreen(m.preflightResults, m.preflightLoaded)
	case screenMode:
		return renderMode()
	case screenModel:
		return renderModel()
	case screenParams:
		return renderParams()
	case screenRun:
		return renderRun()
	case screenResults:
		return renderResults()
	default:
		return renderHWPanel(m.info)
	}
}

// --- per-screen stubs (real implementations come in 5.3-5.4) ---

func renderMode() string    { return "Mode — select benchmark mode\n" }
func renderModel() string   { return "Model — choose a model file\n" }
func renderParams() string  { return "Params — configure run parameters\n" }
func renderRun() string     { return "Run — benchmark in progress\n" }
func renderResults() string { return "Results — summary & throughput\n" }
