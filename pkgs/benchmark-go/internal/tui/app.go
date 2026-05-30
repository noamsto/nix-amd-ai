package tui

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
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

// model is the root bubbletea model; it holds navigation state and hw info.
type model struct {
	current screen
	info    hw.Info
}

// New returns an initialised tea.Model starting on the Hardware screen.
func New(info hw.Info) tea.Model {
	return model{current: screenHW, info: info}
}

// Init satisfies tea.Model; no startup command needed.
func (m model) Init() tea.Cmd { return nil }

// Update handles navigation keys and delegates everything else.
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEnter:
			if m.current < screenLast {
				m.current++
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
		return renderHW(m.info)
	case screenPreflight:
		return renderPreflight()
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
		return renderHW(m.info)
	}
}

// --- per-screen stubs (real implementations come in 5.2-5.4) ---

func renderHW(_ hw.Info) string { return "Hardware — detected GPU & memory\n" }
func renderPreflight() string   { return "Preflight — checking environment\n" }
func renderMode() string        { return "Mode — select benchmark mode\n" }
func renderModel() string       { return "Model — choose a model file\n" }
func renderParams() string      { return "Params — configure run parameters\n" }
func renderRun() string         { return "Run — benchmark in progress\n" }
func renderResults() string     { return "Results — summary & throughput\n" }
