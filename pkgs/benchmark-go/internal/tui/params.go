package tui

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/advise"
)

// RunParams holds the user-configured values for the benchmark run.
type RunParams struct {
	Ctx      int
	Repeat   int
	Warmup   int
	Backends []string // split from the comma-delimited string
}

// paramField identifies which form field is focused.
type paramField int

const (
	fieldCtx paramField = iota
	fieldRepeat
	fieldWarmup
	fieldBackends
	fieldCount = 4
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

func defaultParamsForm() paramsForm {
	return paramsForm{
		ctx:      "2048",
		repeat:   "3",
		warmup:   "1",
		backends: "rocm,vulkan",
		focused:  fieldCtx,
	}
}

// enterParamsScreen pre-fills the form from advise.RecommendParams(largestGiB).
// Pass 0 when size is unknown; advise defaults to 2048.
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

// updateParamsForm handles a key on the params screen.
// Returns true when the key was consumed; caller handles Enter/Esc.
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
						if len(f.ctx) < maxIntFieldDigits {
							f.ctx += key
						}
					case fieldRepeat:
						if len(f.repeat) < maxIntFieldDigits {
							f.repeat += key
						}
					case fieldWarmup:
						if len(f.warmup) < maxIntFieldDigits {
							f.warmup += key
						}
					}
					return true
				}
			case fieldBackends:
				// Accept letters, digits, comma, hyphen only — so a typo like
				// "rocm/vulkan" can't collapse into one bogus backend name.
				if isBackendChar(ch) {
					f.backends += key
					return true
				}
			}
		}
	}
	return false
}

// maxIntFieldDigits caps the length of the numeric form fields (ctx/repeat/
// warmup) so input can't overflow or become nonsense (e.g. 9_999_999 ctx).
const maxIntFieldDigits = 7

// isBackendChar returns true for characters valid in a backends string:
// letters, digits, comma (separator), and hyphen (e.g. "draft-mtp").
func isBackendChar(ch byte) bool {
	return (ch >= 'a' && ch <= 'z') ||
		(ch >= 'A' && ch <= 'Z') ||
		(ch >= '0' && ch <= '9') ||
		ch == ',' || ch == '-'
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
		cmd := m.startRun()
		return m, cmd
	case "esc":
		m.current = screenModel
		return m, nil
	}
	updateParamsForm(&m.paramsForm, msg.String())
	return m, nil
}
