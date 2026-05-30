package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
)

var (
	passStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("46"))  // green
	warnStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("214")) // orange
	failStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("196")) // red
	hintStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("245")) // dim grey
)

// isLemondResult returns true when a Result belongs to the lemond check.
// Key mapping: Name contains "lemond" → 's' (stop lemond).
func isLemondResult(r preflight.Result) bool {
	return strings.Contains(r.Name, "lemond")
}

// isPowerResult returns true when a Result belongs to the power/performance check.
// Key mapping: Name contains "power" or "performance" → 'p' (set performance).
func isPowerResult(r preflight.Result) bool {
	return strings.Contains(r.Name, "power") || strings.Contains(r.Name, "performance")
}

// renderPreflightLine renders a single preflight Result as a display line.
// Format: <glyph> <name>  <reason>  [key hint if fixable]
// Pure function — safe to unit-test without bubbletea.
func renderPreflightLine(r preflight.Result) string {
	var glyphRender string
	switch r.Status {
	case preflight.Pass:
		glyphRender = passStyle.Render("✓")
	case preflight.Warn:
		glyphRender = warnStyle.Render("⚠")
	case preflight.Fail:
		glyphRender = failStyle.Render("✗")
	default:
		glyphRender = "?"
	}

	line := glyphRender + "  " + r.Name

	if r.Reason != "" {
		line += "  " + hintStyle.Render(r.Reason)
	}

	// Append inline key hint for fixable results.
	// Key mapping is name-based (documented here):
	//   lemond   → [s] stop lemond
	//   power    → [p] set performance
	if r.Fix != nil {
		switch {
		case isLemondResult(r):
			line += "  " + hintStyle.Render("[s] stop lemond")
		case isPowerResult(r):
			line += "  " + hintStyle.Render("[p] set performance")
		}
	}

	return line
}

// renderPreflightScreen renders the preflight checklist panel.
// results may be nil when loading hasn't completed yet.
func renderPreflightScreen(results []preflight.Result, loaded bool) string {
	var b strings.Builder

	b.WriteString(headingStyle.Render("Preflight") + "\n\n")

	if !loaded {
		b.WriteString(hintStyle.Render("Checking environment…") + "\n")
	} else if len(results) == 0 {
		b.WriteString(hintStyle.Render("No checks ran.") + "\n")
	} else {
		for _, r := range results {
			b.WriteString(renderPreflightLine(r) + "\n")
		}
	}

	b.WriteString("\n" + labelStyle.Render("Enter → continue   Esc ← back"))

	return panelStyle.Render(b.String())
}
