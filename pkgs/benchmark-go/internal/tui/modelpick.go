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
	rows    []modelRow
	cursor  int
	loading bool
	err     error

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

// enterModelScreen prepares the picker state and returns the load Cmd.
// Called from model.Update when transitioning to screenModel; the model
// value is updated in place before the Cmd is returned.
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

// resolveModelSizeGiB returns the GGUF file size in GiB.
// Returns (0, false) when the file cannot be found or stat'd.
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

// fitGlyph returns the glyph for a FitState.
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

// formatModelRow formats a single model row for display.
// Pure function — used by unit tests.
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

// buildModelRows converts fetched models into display rows using hw info.
func buildModelRows(mList []models.Model, info hw.Info, sizeFunc func(id string) (float64, bool)) []modelRow {
	budgetGiB := advise.BudgetGiB(info.GTTBytes)
	bwGBs, bwEstimated := advise.BandwidthGBs(info.RAMType, info.RAMSpeedMTs)

	rows := make([]modelRow, 0, len(mList))
	for _, m := range mList {
		if !m.Downloaded {
			continue
		}

		sizeFunc_ := sizeFunc
		if sizeFunc_ == nil {
			sizeFunc_ = resolveModelSizeGiB
		}

		totalGiB, sizeKnown := sizeFunc_(m.ID)

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

// renderModelScreen renders the model picker panel.
func renderModelScreen(p *modelPicker) string {
	var b strings.Builder

	b.WriteString(headingStyle.Render("Select Models") + "\n\n")

	if p.loading {
		b.WriteString(hintStyle.Render("Loading models from lemonade…") + "\n")
		return panelStyle.Render(b.String())
	}

	if p.err != nil {
		b.WriteString(failStyle.Render("Error: "+p.err.Error()) + "\n")
		b.WriteString("\n" + labelStyle.Render("Esc ← back"))
		return panelStyle.Render(b.String())
	}

	if len(p.rows) == 0 {
		b.WriteString(hintStyle.Render("No downloaded models found.") + "\n")
		b.WriteString("\n" + labelStyle.Render("Esc ← back"))
		return panelStyle.Render(b.String())
	}

	for i, r := range p.rows {
		line := formatModelRow(r.id, r.totalGiB, r.sizeKnown, r.fit, r.ceilingTPS, r.isMoE, r.estimated, r.selected)
		if i == p.cursor {
			b.WriteString(valueStyle.Render("> "+line) + "\n")
		} else {
			b.WriteString("  " + labelStyle.Render(line) + "\n")
		}
	}

	b.WriteString("\n" + labelStyle.Render("↑/↓ move   Space toggle   Enter → continue   Esc ← back"))

	return panelStyle.Render(b.String())
}
