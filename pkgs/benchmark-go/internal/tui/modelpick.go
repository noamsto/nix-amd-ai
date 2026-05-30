package tui

import (
	"fmt"
	"os"
	"strings"

	tea "charm.land/bubbletea/v2"

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
}

// modelPicker holds transient state for the model selection screen.
type modelPicker struct {
	rows          []modelRow
	cursor        int
	loading       bool
	err           error
	needSelection bool // set when Enter is pressed with no models selected

	// test seams: override these to avoid real filesystem / network calls.
	fetchModels  func(baseURL string) ([]models.Model, error)
	modelSizeGiB func(id string) (float64, bool) // returns (gib, ok)
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

// resolveModelSizeGiB returns the GGUF file size in GiB, or (0, false) if not found.
func resolveModelSizeGiB(id string) (float64, bool) {
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

func fitGlyph(fit advise.FitState) string {
	switch fit {
	case advise.Fits:
		return "✅"
	case advise.Tight:
		return "⚠️"
	default:
		return "❌"
	}
}

// formatModelRow formats a single model row for display (pure, tested directly).
func formatModelRow(id string, totalGiB float64, sizeKnown bool, fit advise.FitState, ceilingTPS float64, isMoE bool, estimated bool, selected bool) string {
	check := "[ ]"
	if selected {
		check = "[✓]"
	}

	sizeStr := "?? GiB"
	if sizeKnown {
		sizeStr = fmt.Sprintf("%.1f GiB", totalGiB)
	}

	ceilStr := "??"
	if ceilingTPS > 0 {
		prefix := ""
		if estimated || !sizeKnown {
			prefix = "~"
		}
		ceilStr = fmt.Sprintf("%s%.1f t/s", prefix, ceilingTPS)
	}

	moeTag := ""
	if isMoE {
		moeTag = " (MoE)"
	}

	return fmt.Sprintf("%s %s  %s  %s  ceil %s%s",
		check, id, sizeStr, fitGlyph(fit), ceilStr, moeTag)
}

func buildModelRows(mList []models.Model, info hw.Info, sizeFunc func(id string) (float64, bool)) []modelRow {
	budgetGiB := advise.BudgetGiB(info.GTTBytes)
	bwGBs, bwEstimated := advise.BandwidthGBs(info.RAMType, info.RAMSpeedMTs)

	sizeOf := sizeFunc
	if sizeOf == nil {
		sizeOf = resolveModelSizeGiB
	}

	rows := make([]modelRow, 0, len(mList))
	for _, m := range mList {
		if !m.Downloaded {
			continue
		}

		totalGiB, sizeKnown := sizeOf(m.ID)

		// fit uses TOTAL size — all expert weights must be resident in GTT.
		fit := advise.Spills
		if sizeKnown {
			fit = advise.FitClass(totalGiB, budgetGiB)
		}

		// ceiling uses ACTIVE size — bandwidth per token only reads active experts.
		var ceilingTPS float64
		var isMoE bool
		if sizeKnown {
			var activeGiB float64
			activeGiB, isMoE = advise.EstimateActiveGiB(m.ID, totalGiB)
			ceilingTPS = advise.DecodeCeilingTPS(bwGBs, activeGiB)
		}

		estimated := bwEstimated || !sizeKnown

		rows = append(rows, modelRow{
			id:         m.ID,
			totalGiB:   totalGiB,
			sizeKnown:  sizeKnown,
			fit:        fit,
			ceilingTPS: ceilingTPS,
			isMoE:      isMoE,
			estimated:  estimated,
		})
	}
	return rows
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
		b.WriteString(st.hint.Render("No downloaded models found.") + "\n")
		b.WriteString("\n" + st.label.Render("Esc ← back"))
		return st.panel.Render(b.String())
	}

	for i, r := range p.rows {
		line := formatModelRow(r.id, r.totalGiB, r.sizeKnown, r.fit, r.ceilingTPS, r.isMoE, r.estimated, r.selected)
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
