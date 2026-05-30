package tui

import (
	"fmt"
	"os"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/advise"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/bench"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/models"
)

// modelsLoadedMsg is sent when the model list fetch completes (success or error).
type modelsLoadedMsg struct {
	models []models.Model
	err    error
}

// modelRow holds display data for one model in the picker.
type modelRow struct {
	id         string
	totalGiB   float64
	sizeKnown  bool
	fit        advise.FitState
	ceilingTPS float64
	isMoE      bool
	estimated  bool // bandwidth or size was estimated
	selected   bool
	downloaded bool // false → model is available but not yet downloaded
	suggested  bool // lemonade marks this as a recommended model
}

// modelPicker holds transient state for the model selection screen.
type modelPicker struct {
	rows          []modelRow
	cursor        int
	loading       bool
	err           error
	needSelection bool // set when Enter is pressed with no models selected

	// fetchModels is a test seam to avoid real network calls.
	fetchModels func(baseURL string) ([]models.Model, error)
}

// toggleSelected toggles the selection of the row under the cursor.
func (p *modelPicker) toggleSelected() {
	if len(p.rows) == 0 {
		return
	}
	p.rows[p.cursor].selected = !p.rows[p.cursor].selected
	p.needSelection = false // any toggle clears the "select something" hint
}

// selectedIDs returns the IDs of all selected rows.
func (p *modelPicker) selectedIDs() []string {
	var out []string
	for _, r := range p.rows {
		if r.selected {
			out = append(out, r.id)
		}
	}
	return out
}

// enterModelScreen resets picker state and returns the load Cmd.
func enterModelScreen(p *modelPicker, baseURL string) tea.Cmd {
	p.loading = true
	p.err = nil
	p.rows = nil
	p.cursor = 0

	fetch := p.fetchModels
	if fetch == nil {
		fetch = models.Fetch
	}
	if baseURL == "" {
		baseURL = "http://localhost:13305"
	}
	url := baseURL

	return func() tea.Msg {
		list, err := fetch(url)
		return modelsLoadedMsg{models: list, err: err}
	}
}

// resolveModelSizeGiBByID returns the GGUF file size in GiB for a model display id.
// Used by the results screen where only the id is available (no checkpoint).
func resolveModelSizeGiBByID(id string) (float64, bool) {
	path := bench.ResolveLemonadeGGUF(id, "")
	if path == "" {
		return 0, false
	}
	fi, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	return float64(fi.Size()) / (1024 * 1024 * 1024), true
}

func fitGlyph(fit advise.FitState, sizeKnown bool) string {
	if !sizeKnown {
		return "?"
	}
	switch fit {
	case advise.Fits:
		return "✅"
	case advise.Tight:
		return "⚠️"
	default:
		return "❌"
	}
}

const idColumnWidth = 32 // display columns for the model id field

// padToWidth pads or truncates s so its display width equals w.
// Truncation appends "…" (1 display column) and is done by rune boundary.
func padToWidth(s string, w int) string {
	cur := lipgloss.Width(s)
	if cur > w {
		// Truncate: walk runes until display width would exceed w-1, then append "…"
		var b strings.Builder
		used := 0
		for _, r := range s {
			rw := lipgloss.Width(string(r))
			if used+rw > w-1 {
				break
			}
			b.WriteRune(r)
			used += rw
		}
		b.WriteString("…")
		used++
		// Pad remaining if needed
		for used < w {
			b.WriteByte(' ')
			used++
		}
		return b.String()
	}
	// Pad with spaces
	return s + strings.Repeat(" ", w-cur)
}

// formatModelRow formats a single model row for display (pure, tested directly).
// Columns (fixed display width):
//
//	[x]  <markers 2>  <id padded/truncated to 32>  <size right-aligned 9>  <fit>  ceil <ceil>  (MoE)
//
// Markers: column of width 2.
//
//	"★ " = suggested
//	"⬇ " = not downloaded
//	"  " = neither
func formatModelRow(id string, totalGiB float64, sizeKnown bool, fit advise.FitState, ceilingTPS float64, isMoE bool, estimated bool, selected bool, downloaded bool, suggested bool) string {
	check := "[ ]"
	if selected {
		check = "[✓]"
	}

	// Markers slot: fixed 2 display columns.
	// Priority: suggested (★) shown if suggested; ⬇ shown if not downloaded.
	// Both can apply simultaneously; show ★ first, ⬇ second, each 1 col wide.
	var markerA, markerB string
	if suggested {
		markerA = "★"
	} else {
		markerA = " "
	}
	if !downloaded {
		markerB = "⬇"
	} else {
		markerB = " "
	}
	markers := markerA + markerB
	// Ensure markers slot is exactly 2 display columns.
	mw := lipgloss.Width(markers)
	if mw < 2 {
		markers += strings.Repeat(" ", 2-mw)
	}

	idCol := padToWidth(id, idColumnWidth)

	sizeStr := "   ?? GiB"
	if sizeKnown {
		sizeStr = fmt.Sprintf("%9s", fmt.Sprintf("%.1f GiB", totalGiB))
	}

	glyphStr := fitGlyph(fit, sizeKnown)
	// Pad fit glyph to 2 display columns so the ceil column aligns regardless
	// of whether glyph is 1-col ("?") or 2-col ("✅"/"⚠️"/"❌").
	glyphPadded := glyphStr + strings.Repeat(" ", 2-lipgloss.Width(glyphStr))

	ceilStr := "      ??"
	if ceilingTPS > 0 {
		prefix := ""
		if estimated || !sizeKnown {
			prefix = "~"
		}
		ceilStr = fmt.Sprintf("%8s", fmt.Sprintf("%s%.1f t/s", prefix, ceilingTPS))
	}

	moeTag := ""
	if isMoE {
		moeTag = "  (MoE)"
	}

	return fmt.Sprintf("%s %s %s  %s  %s  ceil %s%s",
		check, markers, idCol, sizeStr, glyphPadded, ceilStr, moeTag)
}

// hasLabel reports whether the labels slice contains target.
func hasLabel(labels []string, target string) bool {
	for _, l := range labels {
		if l == target {
			return true
		}
	}
	return false
}

// buildModelRows builds display rows from the lemonade model list.
// Size comes from m.Size (API, GB) converted to GiB; no filesystem access.
// mode filters: in ModeMTP, only models with the "mtp" label are included.
// Sorting: downloaded models appear before not-downloaded (stable within each group).
func buildModelRows(mList []models.Model, info hw.Info, mode BenchMode) []modelRow {
	budgetGiB := advise.BudgetGiB(info.GTTBytes)
	bwGBs, bwEstimated := advise.BandwidthGBs(info.RAMType, info.RAMSpeedMTs)

	var downloaded, notDownloaded []modelRow
	for _, m := range mList {
		// Only llamacpp models can be benchmarked by this tool.
		if m.Recipe != "llamacpp" {
			continue
		}
		// In MTP A/B mode, only models with the "mtp" label are relevant.
		if mode == ModeMTP && !hasLabel(m.Labels, "mtp") {
			continue
		}

		// Size from API: GB → GiB (1 GiB = 1.073741824 GB).
		totalGiB := m.Size / 1.073741824
		sizeKnown := m.Size > 0

		// fit uses TOTAL size — all expert weights must be resident in GTT.
		// Unknown size is neutral (not Spills) — we simply don't know.
		fit := advise.Fits
		if sizeKnown {
			fit = advise.FitClass(totalGiB, budgetGiB)
		}

		// ceiling uses ACTIVE size — bandwidth per token only reads active experts.
		// EstimateActiveGiB uses m.ID because the display id carries the A<n>B token.
		var ceilingTPS float64
		var isMoE bool
		if sizeKnown {
			var activeGiB float64
			activeGiB, isMoE = advise.EstimateActiveGiB(m.ID, totalGiB)
			ceilingTPS = advise.DecodeCeilingTPS(bwGBs, activeGiB)
		}

		estimated := bwEstimated || !sizeKnown

		row := modelRow{
			id:         m.ID,
			totalGiB:   totalGiB,
			sizeKnown:  sizeKnown,
			fit:        fit,
			ceilingTPS: ceilingTPS,
			isMoE:      isMoE,
			estimated:  estimated,
			downloaded: m.Downloaded,
			// ★ marks "hot"/featured models. The API's `suggested` is true for
			// nearly the whole catalog (it just means "curated"), so it's useless
			// as a marker; the "hot" label is the selective featured signal.
			suggested: hasLabel(m.Labels, "hot"),
		}
		if m.Downloaded {
			downloaded = append(downloaded, row)
		} else {
			notDownloaded = append(notDownloaded, row)
		}
	}
	return append(downloaded, notDownloaded...)
}

func renderModelScreen(p *modelPicker, st styles) string {
	var b strings.Builder

	b.WriteString(st.heading.Render("Select Models") + "\n\n")

	if p.loading {
		b.WriteString(st.hint.Render("Loading models from lemonade…") + "\n")
		return st.panel.Render(b.String())
	}

	if p.err != nil {
		b.WriteString(st.fail.Render("Error: "+p.err.Error()) + "\n")
		b.WriteString("\n" + st.label.Render("Esc ← back"))
		return st.panel.Render(b.String())
	}

	if len(p.rows) == 0 {
		b.WriteString(st.hint.Render("No models found.") + "\n")
		b.WriteString("\n" + st.label.Render("Esc ← back"))
		return st.panel.Render(b.String())
	}

	for i, r := range p.rows {
		line := formatModelRow(r.id, r.totalGiB, r.sizeKnown, r.fit, r.ceilingTPS, r.isMoE, r.estimated, r.selected, r.downloaded, r.suggested)
		if i == p.cursor {
			b.WriteString(st.value.Render("> "+line) + "\n")
		} else {
			b.WriteString("  " + st.label.Render(line) + "\n")
		}
	}

	if p.needSelection {
		b.WriteString("\n" + st.warn.Render("select at least one model (space to toggle)") + "\n")
	}

	b.WriteString("\n" + st.label.Render("↑/↓ move   Space toggle   Enter → continue   Esc ← back"))

	return st.panel.Render(b.String())
}
