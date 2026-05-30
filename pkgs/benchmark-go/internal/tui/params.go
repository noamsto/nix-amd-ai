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
	Backends []string
}

// ctxPreset is one selectable context-window preset. Tokens, not bytes.
type ctxPreset struct {
	label  string
	tokens int
}

// ctxPresets are the cyclable presets; "K" = ×1024 (llama.cpp convention).
// The Custom slot lives at index len(ctxPresets) — see ctxCustomIdx.
var ctxPresets = [...]ctxPreset{
	{"2K", 2048},
	{"4K", 4096},
	{"8K", 8192},
	{"16K", 16384},
	{"32K", 32768},
}

// ctxCustomIdx is the cycle position past the last preset: the editable Custom slot.
const ctxCustomIdx = len(ctxPresets)

// availableBackends is the toggleable backend set for A/B runs.
var availableBackends = []string{"rocm", "vulkan"}

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
	ctxIdx    int    // cycle position: 0..len(ctxPresets); ctxCustomIdx == Custom
	ctxCustom string // raw buffer for the Custom slot (digits + K/M/B suffix)
	repeat    string
	warmup    string

	backendSel    []bool // parallel to availableBackends
	backendCursor int    // which backend chip the cursor is on (fieldBackends)

	focused      paramField
	ctxSuggested bool // true when Ctx was pre-filled by advise
}

func defaultParamsForm() paramsForm {
	return paramsForm{
		ctxIdx:     0,
		repeat:     "3",
		warmup:     "1",
		backendSel: []bool{true, true}, // rocm + vulkan
		focused:    fieldCtx,
	}
}

// enterParamsScreen pre-fills the form from advise.RecommendParams(largestGiB).
// The recommended ctx snaps to a matching preset, or the Custom slot otherwise.
func enterParamsScreen(f *paramsForm, largestGiB float64) {
	rec := advise.RecommendParams(largestGiB)

	f.ctxIdx = ctxCustomIdx
	f.ctxCustom = fmt.Sprintf("%d", rec.Ctx)
	for i, p := range ctxPresets {
		if p.tokens == rec.Ctx {
			f.ctxIdx = i
			f.ctxCustom = ""
			break
		}
	}
	f.repeat = "3"
	f.warmup = "1"
	f.backendSel = []bool{true, true}
	f.backendCursor = 0
	f.focused = fieldCtx
	f.ctxSuggested = true
}

// largestSelectedGiB returns the largest totalGiB among selected rows.
func largestSelectedGiB(p *modelPicker) float64 {
	var max float64
	for _, r := range p.rows {
		if r.selected && r.sizeKnown && r.totalGiB > max {
			max = r.totalGiB
		}
	}
	return max
}

// ctxValue returns the resolved context-window token count for the form.
func (f *paramsForm) ctxValue() int {
	if f.ctxIdx == ctxCustomIdx {
		return parseCtxField(f.ctxCustom, ctxPresets[0].tokens)
	}
	return ctxPresets[f.ctxIdx].tokens
}

// runParams returns the current form values as a RunParams struct.
func (f *paramsForm) runParams() RunParams {
	var backends []string
	for i, on := range f.backendSel {
		if on && i < len(availableBackends) {
			backends = append(backends, availableBackends[i])
		}
	}
	return RunParams{
		Ctx:      f.ctxValue(),
		Repeat:   parseIntField(f.repeat, 1),
		Warmup:   parseIntField(f.warmup, 1),
		Backends: backends,
	}
}

// parseCtxField parses a custom context value with an optional unit suffix:
// bare digits are taken as-is; "K"/"KB" = ×1024, "M"/"MB" = ×1024². Case-
// insensitive. Falls back for empty / non-numeric / non-positive input.
func parseCtxField(s string, fallback int) int {
	t := strings.TrimSpace(strings.ToLower(s))
	t = strings.TrimSuffix(t, "b") // accept "kb"/"mb" as "k"/"m"
	mult := 1
	if strings.HasSuffix(t, "k") {
		mult = 1024
		t = strings.TrimSuffix(t, "k")
	} else if strings.HasSuffix(t, "m") {
		mult = 1024 * 1024
		t = strings.TrimSuffix(t, "m")
	}
	n := parseIntField(t, 0)
	if n <= 0 {
		return fallback
	}
	return n * mult
}

// parseIntField converts a raw digit string to an int.
// Falls back for empty, non-numeric, or non-positive values.
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
	case "left", "h":
		return f.moveHorizontal(-1)
	case "right", "l":
		return f.moveHorizontal(+1)
	case " ", "space":
		if f.focused == fieldBackends {
			f.toggleBackend()
			return true
		}
		return false
	case "backspace":
		switch f.focused {
		case fieldCtx:
			if f.ctxIdx == ctxCustomIdx {
				f.ctxCustom = deleteLastChar(f.ctxCustom)
			}
		case fieldRepeat:
			f.repeat = deleteLastChar(f.repeat)
		case fieldWarmup:
			f.warmup = deleteLastChar(f.warmup)
		}
		return true
	default:
		if len(key) == 1 {
			return f.typeChar(key)
		}
	}
	return false
}

// moveHorizontal handles ←/→ for the focused field: cycle ctx presets (incl.
// Custom), or move the backend chip cursor. Other fields ignore it.
func (f *paramsForm) moveHorizontal(dir int) bool {
	switch f.focused {
	case fieldCtx:
		f.ctxIdx += dir
		if f.ctxIdx < 0 {
			f.ctxIdx = ctxCustomIdx
		} else if f.ctxIdx > ctxCustomIdx {
			f.ctxIdx = 0
		}
		f.ctxSuggested = false // user chose a value; no longer the suggestion
		return true
	case fieldBackends:
		f.backendCursor += dir
		if f.backendCursor < 0 {
			f.backendCursor = len(availableBackends) - 1
		} else if f.backendCursor >= len(availableBackends) {
			f.backendCursor = 0
		}
		return true
	}
	return false
}

// toggleBackend flips the backend under the cursor.
func (f *paramsForm) toggleBackend() {
	if f.backendCursor >= 0 && f.backendCursor < len(f.backendSel) {
		f.backendSel[f.backendCursor] = !f.backendSel[f.backendCursor]
	}
}

// typeChar handles a single-rune keypress for the focused field.
func (f *paramsForm) typeChar(key string) bool {
	ch := key[0]
	switch f.focused {
	case fieldCtx:
		// Typing a digit jumps to the Custom slot and appends; unit suffixes
		// (k/m/b) extend an in-progress custom value.
		if ch >= '0' && ch <= '9' {
			if f.ctxIdx != ctxCustomIdx {
				f.ctxIdx = ctxCustomIdx
				f.ctxCustom = ""
			}
			if len(f.ctxCustom) < maxIntFieldDigits {
				f.ctxCustom += key
			}
			f.ctxSuggested = false
			return true
		}
		if f.ctxIdx == ctxCustomIdx && isCtxUnitChar(ch) {
			f.ctxCustom += key
			return true
		}
	case fieldRepeat:
		if ch >= '0' && ch <= '9' && len(f.repeat) < maxIntFieldDigits {
			f.repeat += key
			return true
		}
	case fieldWarmup:
		if ch >= '0' && ch <= '9' && len(f.warmup) < maxIntFieldDigits {
			f.warmup += key
			return true
		}
	}
	return false
}

// maxIntFieldDigits caps numeric-field length so input can't overflow.
const maxIntFieldDigits = 7

// isCtxUnitChar reports whether ch is a valid context unit-suffix character.
func isCtxUnitChar(ch byte) bool {
	switch ch {
	case 'k', 'K', 'm', 'M', 'b', 'B':
		return true
	}
	return false
}

// deleteLastChar removes the last UTF-8 character from s.
func deleteLastChar(s string) string {
	runes := []rune(s)
	if len(runes) == 0 {
		return s
	}
	return string(runes[:len(runes)-1])
}

// renderCtxField renders the context-window control: a ‹ preset › cycler, or an
// editable box with a cursor and unit hint when on the Custom slot.
func renderCtxField(f paramsForm, st styles) string {
	focused := f.focused == fieldCtx
	line := st.focusBullet(focused) + paramLabel("Context", st, focused)

	if f.ctxIdx == ctxCustomIdx {
		buf := f.ctxCustom
		if focused {
			buf += st.cursorStr
		}
		box := st.value.Render("[ " + padCustom(buf) + " ]")
		line += box
		if focused {
			line += "  " + st.hint.Render("✎ digits + K/M (e.g. 24K)")
		} else {
			line += "  " + st.hint.Render(fmt.Sprintf("= %d tok", f.ctxValue()))
		}
	} else {
		cyc := fmt.Sprintf("‹ %s ›", ctxPresets[f.ctxIdx].label)
		if focused {
			line += st.accent.Render(cyc) + "  " + st.hint.Render("←/→ preset · type to customize")
		} else {
			line += st.value.Render(cyc)
		}
	}
	if f.ctxSuggested {
		line += "  " + st.hint.Render("(suggested)")
	}
	return line
}

// padCustom keeps the custom box from collapsing to nothing when empty.
func padCustom(s string) string {
	if s == "" {
		return " "
	}
	return s
}

// renderIntField renders a numeric field as an editable box with a cursor.
func renderIntField(label, value string, focused bool, st styles) string {
	buf := value
	if focused {
		buf += st.cursorStr
	}
	line := st.focusBullet(focused) + paramLabel(label, st, focused) + st.value.Render("[ "+padCustom(buf)+" ]")
	if focused {
		line += "  " + st.hint.Render("✎ digits")
	}
	return line
}

// renderBackendsField renders the backend toggle chips with a cursor.
func renderBackendsField(f paramsForm, st styles) string {
	focused := f.focused == fieldBackends
	line := st.focusBullet(focused) + paramLabel("Backends", st, focused)
	chips := make([]string, 0, len(availableBackends))
	for i, name := range availableBackends {
		on := i < len(f.backendSel) && f.backendSel[i]
		chips = append(chips, chip(st, name, on, focused && i == f.backendCursor))
	}
	line += strings.Join(chips, " ")
	if focused {
		line += "  " + st.hint.Render("←/→ move · Space toggle")
	}
	return line
}

// paramLabel renders a fixed-width field label, accented when focused.
func paramLabel(label string, st styles, focused bool) string {
	padded := fmt.Sprintf("%-10s", label)
	if focused {
		return st.value.Render(padded) + " "
	}
	return st.label.Render(padded) + " "
}

// renderParamsScreen renders the full params form panel.
func renderParamsScreen(f paramsForm, st styles) string {
	var b strings.Builder

	b.WriteString(renderCtxField(f, st) + "\n")
	b.WriteString(renderIntField("Repeat", f.repeat, f.focused == fieldRepeat, st) + "\n")
	b.WriteString(renderIntField("Warmup", f.warmup, f.focused == fieldWarmup, st) + "\n")
	b.WriteString(renderBackendsField(f, st) + "\n")

	b.WriteString("\n" + keybar(st,
		[2]string{"Tab/↑↓", "field"},
		[2]string{"←/→", "change"},
		[2]string{"Enter", "run →"},
		[2]string{"Esc", "← back"},
	))

	return titledPanel(st, "Configure Run Parameters", b.String(), 0)
}

// handleParamsKey processes a key press when current == screenParams.
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
