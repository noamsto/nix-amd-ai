package tui

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/advise"
)

// RunParams holds the user-configured values for the benchmark run.
// Task 5.4 reads these from model.paramsForm.runParams().
type RunParams struct {
	Ctx      int
	Repeat   int
	Warmup   int
	Backends []string // split from the comma-delimited string
}

// paramField identifies which form field is focused.
type paramField int

const (
	fieldCtx      paramField = iota
	fieldRepeat              // 1
	fieldWarmup              // 2
	fieldBackends            // 3
	fieldCount    = 4        // total number of fields
)

// paramsForm holds editable state for the params screen.
type paramsForm struct {
	// raw string buffers (edited by the user keystroke-by-keystroke)
	ctx      string
	repeat   string
	warmup   string
	backends string

	focused      paramField
	ctxSuggested bool // true when Ctx was pre-filled by advise
}

// defaultParamsForm returns a form with hardcoded defaults (no advise input).
func defaultParamsForm() paramsForm {
	return paramsForm{
		ctx:      "2048",
		repeat:   "3",
		warmup:   "1",
		backends: "rocm,vulkan",
		focused:  fieldCtx,
	}
}

// enterParamsScreen initialises the params form when transitioning from
// screenModel to screenParams. It pre-fills Ctx from advise.RecommendParams
// using the largest selected model's size in GiB (passed in as largestGiB;
// pass 0 when unknown, which yields the advise default of 2048).
func enterParamsScreen(f *paramsForm, largestGiB float64) {
	rec := advise.RecommendParams(largestGiB)

	f.ctx = fmt.Sprintf("%d", rec.Ctx)
	f.repeat = "3"
	f.warmup = "1"
	f.backends = "rocm,vulkan"
	f.focused = fieldCtx
	f.ctxSuggested = true
}

// largestSelectedGiB returns the largest totalGiB among selected rows.
// Returns 0 if no row is selected or no size is known.
func largestSelectedGiB(p *modelPicker) float64 {
	var max float64
	for _, r := range p.rows {
		if r.selected && r.sizeKnown && r.totalGiB > max {
			max = r.totalGiB
		}
	}
	return max
}

// runParams returns the current form values as a RunParams struct.
// Invalid / empty int fields fall back to 1 (safe minimum).
func (f *paramsForm) runParams() RunParams {
	return RunParams{
		Ctx:      parseIntField(f.ctx, 1),
		Repeat:   parseIntField(f.repeat, 1),
		Warmup:   parseIntField(f.warmup, 1),
		Backends: splitBackends(f.backends),
	}
}

// parseIntField converts a raw string field to an int.
// Falls back to fallback for empty, non-numeric, or non-positive values.
func parseIntField(s string, fallback int) int {
	if s == "" {
		return fallback
	}
	n := 0
	for _, ch := range s {
		if ch < '0' || ch > '9' {
			return fallback
		}
		n = n*10 + int(ch-'0')
	}
	if n <= 0 {
		return fallback
	}
	return n
}

// splitBackends splits a comma-delimited backends string into a trimmed slice.
func splitBackends(s string) []string {
	raw := strings.Split(s, ",")
	out := make([]string, 0, len(raw))
	for _, p := range raw {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// updateParamsForm handles a key press on the params screen.
// Returns whether the key was consumed; the caller must handle Enter/Esc itself.
func updateParamsForm(f *paramsForm, key string) (consumed bool) {
	switch key {
	case "tab", "down":
		f.focused = (f.focused + 1) % fieldCount
		return true
	case "shift+tab", "up":
		if f.focused == 0 {
			f.focused = fieldCount - 1
		} else {
			f.focused--
		}
		return true
	case "backspace":
		switch f.focused {
		case fieldCtx:
			f.ctx = deleteLastChar(f.ctx)
		case fieldRepeat:
			f.repeat = deleteLastChar(f.repeat)
		case fieldWarmup:
			f.warmup = deleteLastChar(f.warmup)
		case fieldBackends:
			f.backends = deleteLastChar(f.backends)
		}
		return true
	default:
		// Accept digit input for int fields, and letters/comma/hyphen for backends.
		if len(key) == 1 {
			ch := key[0]
			switch f.focused {
			case fieldCtx, fieldRepeat, fieldWarmup:
				if ch >= '0' && ch <= '9' {
					switch f.focused {
					case fieldCtx:
						f.ctx += key
					case fieldRepeat:
						f.repeat += key
					case fieldWarmup:
						f.warmup += key
					}
					return true
				}
			case fieldBackends:
				// Accept letters, digits, comma, hyphen, underscore, dot, slash.
				if isBackendChar(ch) {
					f.backends += key
					return true
				}
			}
		}
	}
	return false
}

// isBackendChar returns true for characters valid in a backends string.
func isBackendChar(ch byte) bool {
	return (ch >= 'a' && ch <= 'z') ||
		(ch >= 'A' && ch <= 'Z') ||
		(ch >= '0' && ch <= '9') ||
		ch == ',' || ch == '-' || ch == '_' || ch == '.' || ch == '/'
}

// deleteLastChar removes the last UTF-8 character from s.
func deleteLastChar(s string) string {
	runes := []rune(s)
	if len(runes) == 0 {
		return s
	}
	return string(runes[:len(runes)-1])
}

// renderParamsField renders one field row.
// focused highlights the current field; suggested adds a subtle hint.
func renderParamsField(label, value string, focused, suggested bool) string {
	cursor := "  "
	if focused {
		cursor = "> "
	}

	var labelRender, valueRender string
	if focused {
		labelRender = valueStyle.Render(label)
		valueRender = valueStyle.Render(value)
	} else {
		labelRender = labelStyle.Render(label)
		valueRender = labelStyle.Render(value)
	}

	line := cursor + labelRender + "  " + valueRender

	if suggested {
		line += "  " + hintStyle.Render("(suggested)")
	}

	return line
}

// renderParamsScreen renders the full params form panel.
func renderParamsScreen(f paramsForm) string {
	var b strings.Builder

	b.WriteString(headingStyle.Render("Configure Run Parameters") + "\n\n")

	b.WriteString(renderParamsField(
		"Ctx    (context window):",
		f.ctx,
		f.focused == fieldCtx,
		f.ctxSuggested,
	) + "\n")

	b.WriteString(renderParamsField(
		"Repeat (runs per model):",
		f.repeat,
		f.focused == fieldRepeat,
		false,
	) + "\n")

	b.WriteString(renderParamsField(
		"Warmup (warm-up runs):  ",
		f.warmup,
		f.focused == fieldWarmup,
		false,
	) + "\n")

	b.WriteString(renderParamsField(
		"Backends (comma list):  ",
		f.backends,
		f.focused == fieldBackends,
		false,
	) + "\n")

	b.WriteString("\n" + labelStyle.Render("Tab/↓ next   Shift+Tab/↑ prev   Enter → run   Esc ← back"))

	return panelStyle.Render(b.String())
}

// handleParamsKey processes a key press when current == screenParams.
// Returns the updated model and any command.
func handleParamsKey(m model, msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter":
		m.current = screenRun
		return m, nil
	case "esc":
		m.current = screenModel
		return m, nil
	}
	updateParamsForm(&m.paramsForm, msg.String())
	return m, nil
}
