package tui

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

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
	ConfigPath    string // default: ~/.cache/lemonade/config.json
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

	// Status rail state.
	rail     railState
	width    int
	railGRBM func() float64 // nil → defaultRailGRBM

	// Theme — updated on BackgroundColorMsg.
	st styles

	// Seams for testing. nil falls back to the real implementation:
	//   runBench → defaultRunBench (spawns llama-server / hits lemonade)
	// Tests inject a fake so no test touches hardware or the network.
	runBench func(ctx context.Context, req runRequest, progress chan<- tea.Msg) tea.Msg
}

func (m model) baseURL() string {
	if m.cfg.BaseURL != "" {
		return m.cfg.BaseURL
	}
	return "http://localhost:13305"
}

func (m model) configPath() string {
	if m.cfg.ConfigPath != "" {
		return m.cfg.ConfigPath
	}
	return filepath.Join(os.Getenv("HOME"), ".cache", "lemonade", "config.json")
}

// New returns an initialised tea.Model starting on the Hardware screen.
func New(info hw.Info, cfg Config) tea.Model {
	return model{current: screenHW, info: info, cfg: cfg, st: newStyles(true)}
}

// Init satisfies tea.Model; starts the rail GPU ticker and requests terminal background color.
func (m model) Init() tea.Cmd {
	return tea.Batch(railTickCmd(m.railGRBM), tea.RequestBackgroundColor)
}

// preflightResultsMsg carries the results of a preflight.Run call.
type preflightResultsMsg struct {
	results []preflight.Result
}

// fixDoneMsg carries the outcome of a fixer invocation.
type fixDoneMsg struct {
	err error
}

func runPreflightCmd(info hw.Info, service string) tea.Cmd {
	return func() tea.Msg {
		return preflightResultsMsg{results: preflight.Run(info, service)}
	}
}

// runFixCmd runs a preflight fix command via tea.ExecProcess: bubbletea releases
// the terminal so a sudo password/fingerprint prompt works, then restores the
// alt-screen. On completion it emits fixDoneMsg, which re-runs preflight.
func runFixCmd(cmd *exec.Cmd) tea.Cmd {
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return fixDoneMsg{err: err}
	})
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
	case tea.BackgroundColorMsg:
		m.st = newStyles(msg.IsDark())
		return m, nil

	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil

	case railTickMsg:
		m.rail.gpuPct = msg.pct
		return m, railTickCmd(m.railGRBM)

	case logWrittenMsg:
		return m.handleLogWritten(msg)

	case preflightResultsMsg:
		m.preflightResults = msg.results
		m.preflightLoaded = true
		m.rail.preflight = summarizePreflight(m.preflightResults)
		return m, nil

	case modelsLoadedMsg:
		m.modelPicker.loading = false
		if msg.err != nil {
			m.modelPicker.err = msg.err
			return m, nil
		}
		m.modelPicker.rows = buildModelRows(msg.models, m.info, m.selectedMode)
		return m, nil

	case fixDoneMsg:
		// Re-run preflight after any fix attempt (error or success).
		return m, runPreflightCmd(m.info, m.lemondService())

	case lemondStartedMsg:
		// Outcome of the model-screen "start lemonade" action. On success, wait
		// for the API then re-fetch; on failure, surface it on the picker.
		if msg.err != nil {
			m.modelPicker.loading = false
			m.modelPicker.err = fmt.Errorf("start lemond: %w", msg.err)
			return m, nil
		}
		return m, waitAndFetchModelsCmd(&m.modelPicker, m.baseURL())

	case tea.KeyPressMsg:
		// Screen-specific key handling for preflight fixers.
		if m.current == screenPreflight && m.preflightLoaded {
			switch msg.String() {
			case "s":
				// Start lemond — only if the lemond result has a fix command.
				for _, r := range m.preflightResults {
					if isLemondResult(r) && r.FixCmd != nil {
						return m, runFixCmd(r.FixCmd())
					}
				}
			case "p":
				// Set performance mode — only if the power result has a fix command.
				for _, r := range m.preflightResults {
					if isPowerResult(r) && r.FixCmd != nil {
						return m, runFixCmd(r.FixCmd())
					}
				}
			}
		}

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

		if m.current == screenModel {
			// On a fetch error, offer to start lemonade or retry the fetch.
			if m.modelPicker.err != nil {
				switch msg.String() {
				case "s":
					m.modelPicker.err = nil
					m.modelPicker.loading = true
					cmd := exec.Command("sudo", "systemctl", "restart", m.lemondService()) //nolint:gosec
					return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
						return lemondStartedMsg{err: err}
					})
				case "r":
					return m, enterModelScreen(&m.modelPicker, m.cfg.BaseURL)
				}
			}
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
			case " ", "space":
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

		if m.current == screenParams {
			return handleParamsKey(m, msg)
		}

		if m.current == screenRun {
			return m.handleRunKey(msg)
		}

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

// stepLabels are the short wizard-step names, indexed by screen.
var stepLabels = [...]string{
	screenHW:        "Hardware",
	screenPreflight: "Preflight",
	screenMode:      "Mode",
	screenModel:     "Model",
	screenParams:    "Params",
	screenRun:       "Run",
	screenResults:   "Results",
}

// renderStepper renders the wizard breadcrumb: completed steps in green, the
// current step in accent, upcoming steps faint, joined by "▸".
func renderStepper(current screen, st styles) string {
	parts := make([]string, 0, len(stepLabels))
	for i, label := range stepLabels {
		switch {
		case screen(i) < current:
			parts = append(parts, st.stepDone.Render(label))
		case screen(i) == current:
			parts = append(parts, st.stepOn.Render(label))
		default:
			parts = append(parts, st.stepTodo.Render(label))
		}
	}
	return strings.Join(parts, st.hint.Render(" ▸ "))
}

func (m model) View() tea.View {
	st := m.st
	var s string
	switch m.current {
	case screenHW:
		s = renderHWPanel(m.info, st)
	case screenPreflight:
		s = renderPreflightScreen(m.preflightResults, m.preflightLoaded, st)
	case screenMode:
		s = renderModeScreen(m.modePicker, st)
	case screenModel:
		s = renderModelScreen(&m.modelPicker, st)
	case screenParams:
		s = renderParamsScreen(m.paramsForm, st)
	case screenRun:
		s = renderRunScreen(m.run, st)
	case screenResults:
		s = renderResults(m.run.results, m.run.err, m.results, m.info, nil, st)
	default:
		s = renderHWPanel(m.info, st)
	}
	rail := renderRail(m.info, m.rail, m.width, st)
	stepper := renderStepper(m.current, st)
	v := tea.NewView(lipgloss.JoinVertical(lipgloss.Left, rail, stepper, "", s))
	v.AltScreen = true
	return v
}
