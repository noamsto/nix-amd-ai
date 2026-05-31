package tui

import (
	"strings"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
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
func renderPreflightLine(r preflight.Result, st styles) string {
	var glyphRender string
	switch r.Status {
	case preflight.Pass:
		glyphRender = st.pass.Render("✓")
	case preflight.Warn:
		glyphRender = st.warn.Render("⚠")
	case preflight.Fail:
		glyphRender = st.fail.Render("✗")
	default:
		glyphRender = "?"
	}

	line := glyphRender + "  " + r.Name

	if r.Reason != "" {
		line += "  " + st.hint.Render(r.Reason)
	}

	// Append inline key hint for fixable results.
	// Key mapping is name-based (documented here):
	//   lemond   → [s] start lemond
	//   power    → [p] set performance
	if r.FixCmd != nil {
		switch {
		case isLemondResult(r):
			line += "  " + st.accent.Render("[s]") + st.hint.Render(" start lemond")
		case isPowerResult(r):
			line += "  " + st.accent.Render("[p]") + st.hint.Render(" set performance")
		}
	}

	return line
}

// renderPreflightScreen renders the preflight checklist panel.
// results may be nil when loading hasn't completed yet.
func renderPreflightScreen(results []preflight.Result, loaded bool, st styles) string {
	var b strings.Builder

	if !loaded {
		b.WriteString(st.hint.Render("Checking environment…") + "\n")
	} else if len(results) == 0 {
		b.WriteString(st.hint.Render("No checks ran.") + "\n")
	} else {
		for _, r := range results {
			b.WriteString(renderPreflightLine(r, st) + "\n")
		}
	}

	b.WriteString("\n" + keybar(st,
		[2]string{"Enter", "continue →"},
		[2]string{"Esc", "← back"},
	))

	return titledPanel(st, "Preflight", b.String(), 0)
}
