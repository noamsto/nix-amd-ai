package tui

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

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
	id          string
	totalGiB    float64
	sizeKnown   bool
	fit         advise.FitState
	ceilingTPS  float64
	isMoE       bool
	estimated   bool // bandwidth or size was estimated
	selected    bool
	downloaded  bool // false → model is available but not yet downloaded
	hot         bool // lemonade "hot" label (community-featured) → 🔥
	recommended bool // good for THIS hardware: fits comfortably + decent predicted t/s → ⚡
}

// recommendTPSThreshold is the predicted decode ceiling (t/s) at/above which a
// comfortably-fitting model is flagged ⚡ "recommended for your hardware"
// (~interactive reading speed on this iGPU).
const recommendTPSThreshold = 10.0

// modelPicker holds transient state for the model selection screen.
type modelPicker struct {
	rows          []modelRow
	cursor        int
	loading       bool
	err           error
	needSelection bool   // set when Enter is pressed with no models selected
	needPull      bool   // set when Enter is pressed with not-downloaded selections
	baseURL       string // lemonade endpoint, for error messages + start/retry

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

// pendingPullRows returns selected rows that aren't downloaded yet.
func (p *modelPicker) pendingPullRows() []modelRow {
	var out []modelRow
	for _, r := range p.rows {
		if r.selected && !r.downloaded {
			out = append(out, r)
		}
	}
	return out
}

// pendingPullIDs returns the IDs of selected-but-not-downloaded rows.
func (p *modelPicker) pendingPullIDs() []string {
	rows := p.pendingPullRows()
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.id
	}
	return out
}

// modelsPulledMsg carries the outcome of a `lemonade pull` (run via tea.Exec).
type modelsPulledMsg struct{ err error }

// pullModelsExec builds a command that pulls each model in turn via the
// lemonade CLI. Run via tea.ExecProcess so lemonade's own progress bar shows in
// the handed-over terminal. `&&` stops at the first failure.
func pullModelsExec(ids []string) *exec.Cmd {
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = "lemonade pull " + shellSingleQuote(id)
	}
	return exec.Command("sh", "-c", strings.Join(parts, " && ")) //nolint:gosec
}

// shellSingleQuote single-quotes s for safe use in an sh -c string.
func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// pullPromptText phrases the download confirmation for the pending models.
// One model reads naturally; several are summarised with a total size.
func pullPromptText(pending []modelRow) string {
	var totalGiB float64
	sizeKnown := true
	for _, r := range pending {
		totalGiB += r.totalGiB
		if !r.sizeKnown {
			sizeKnown = false
		}
	}
	size := ""
	if sizeKnown && totalGiB > 0 {
		size = fmt.Sprintf("~%.1f GiB", totalGiB)
	}

	if len(pending) == 1 {
		if size != "" {
			return fmt.Sprintf("%s isn't downloaded yet (%s). Download it and continue?", pending[0].id, size)
		}
		return fmt.Sprintf("%s isn't downloaded yet. Download it and continue?", pending[0].id)
	}

	names := make([]string, len(pending))
	for i, r := range pending {
		names[i] = r.id
	}
	if size != "" {
		return fmt.Sprintf("%d models need downloading (%s total): %s. Download them and continue?",
			len(pending), size, strings.Join(names, ", "))
	}
	return fmt.Sprintf("%d models need downloading: %s. Download them and continue?",
		len(pending), strings.Join(names, ", "))
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
	p.baseURL = baseURL
	url := baseURL

	return func() tea.Msg {
		list, err := fetch(url)
		return modelsLoadedMsg{models: list, err: err}
	}
}

// lemondStartedMsg carries the outcome of the model-screen "start lemonade"
// action (a tea.ExecProcess'd `sudo systemctl restart`).
type lemondStartedMsg struct{ err error }

// waitAndFetchModelsCmd waits for lemond to answer (after a start) then
// re-fetches the model list. Result flows back as modelsLoadedMsg so the normal
// load handling applies.
func waitAndFetchModelsCmd(p *modelPicker, baseURL string) tea.Cmd {
	fetch := p.fetchModels
	if fetch == nil {
		fetch = models.Fetch
	}
	if baseURL == "" {
		baseURL = "http://localhost:13305"
	}
	p.baseURL = baseURL
	return func() tea.Msg {
		if err := bench.WaitForLemond(baseURL, lemondStartTimeout); err != nil {
			return modelsLoadedMsg{err: err}
		}
		list, err := fetch(baseURL)
		return modelsLoadedMsg{models: list, err: err}
	}
}

// lemondStartTimeout bounds the wait for lemond to answer after a start.
const lemondStartTimeout = 60 * time.Second

// isUnreachableErr reports whether err looks like "lemonade isn't up" rather
// than a protocol/HTTP error — so the picker can show actionable guidance.
func isUnreachableErr(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	for _, s := range []string{"connection refused", "no such host", "dial tcp", "connect:"} {
		if strings.Contains(msg, s) {
			return true
		}
	}
	return false
}

// fetchErrorLines renders the fetch error as friendly, width-bounded lines.
func fetchErrorLines(err error, baseURL string) []string {
	if isUnreachableErr(err) {
		return []string{
			"Can't reach lemonade at " + baseURL + ".",
			"The lemond service isn't responding — it may be stopped.",
		}
	}
	return []string{truncate("Error fetching models: "+err.Error(), maxRuleWidth)}
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
//	[x]  <id padded/truncated to 32>  <size right-aligned 9>  <fit>  ceil <ceil>  (MoE)  <markers>
//
// Status markers trail at the END of the row — ⚡ (recommended for this HW),
// 🔥 (lemonade hot/featured), ⬇ (not downloaded) — so their (emoji) display
// width can't shift the fixed data columns in any terminal.
func formatModelRow(id string, totalGiB float64, sizeKnown bool, fit advise.FitState, ceilingTPS float64, isMoE bool, estimated bool, selected bool, downloaded bool, hot bool, recommended bool) string {
	check := "[ ]"
	if selected {
		check = "[✓]"
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

	var marks []string
	if recommended {
		marks = append(marks, "⚡")
	}
	if hot {
		marks = append(marks, "🔥")
	}
	if !downloaded {
		marks = append(marks, "⬇")
	}
	markStr := ""
	if len(marks) > 0 {
		markStr = "  " + strings.Join(marks, " ")
	}

	return fmt.Sprintf("%s %s  %s  %s  ceil %s%s%s",
		check, idCol, sizeStr, glyphPadded, ceilStr, moeTag, markStr)
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
			// 🔥 from the "hot" label (the API's `suggested` is true for nearly the
			// whole catalog, so it's useless as a marker; "hot" is selective).
			hot: hasLabel(m.Labels, "hot"),
			// ⚡ when this fits comfortably AND should run at a decent t/s on this
			// hardware (predicted ceiling ≥ threshold). A model that only fits
			// "tight" or spills, or is bandwidth-bound below the threshold, is not.
			recommended: sizeKnown && fit == advise.Fits && ceilingTPS >= recommendTPSThreshold,
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

	if p.loading {
		b.WriteString(st.hint.Render("Loading models from lemonade…") + "\n")
		return titledPanel(st, "Select Models", b.String(), 0)
	}

	if p.err != nil {
		for _, line := range fetchErrorLines(p.err, p.baseURL) {
			b.WriteString(st.fail.Render(line) + "\n")
		}
		b.WriteString("\n" + keybar(st,
			[2]string{"s", "start lemonade"},
			[2]string{"r", "retry"},
			[2]string{"Esc", "← back"},
		))
		return titledPanel(st, "Select Models", b.String(), 0)
	}

	if len(p.rows) == 0 {
		b.WriteString(st.hint.Render("No models found.") + "\n")
		b.WriteString("\n" + keybar(st, [2]string{"Esc", "← back"}))
		return titledPanel(st, "Select Models", b.String(), 0)
	}

	for i, r := range p.rows {
		line := formatModelRow(r.id, r.totalGiB, r.sizeKnown, r.fit, r.ceilingTPS, r.isMoE, r.estimated, r.selected, r.downloaded, r.hot, r.recommended)
		focused := i == p.cursor
		if focused {
			b.WriteString(st.focusBullet(true) + st.value.Render(line) + "\n")
		} else {
			b.WriteString(st.focusBullet(false) + st.label.Render(line) + "\n")
		}
	}

	b.WriteString("\n" + st.hint.Render("⚡ recommended · 🔥 hot · ⬇ downloadable") + "\n")

	// Confirm prompt: selected models that need downloading first.
	if p.needPull {
		b.WriteString("\n" + st.warn.Render("⬇  "+pullPromptText(p.pendingPullRows())) + "\n")
		b.WriteString("\n" + keybar(st,
			[2]string{"Enter", "download & continue"},
			[2]string{"Esc", "cancel"},
		))
		return titledPanel(st, "Select Models", b.String(), 0)
	}

	if p.needSelection {
		b.WriteString("\n" + st.warn.Render("select at least one model (space to toggle)") + "\n")
	}

	b.WriteString("\n" + keybar(st,
		[2]string{"↑/↓", "move"},
		[2]string{"Space", "toggle"},
		[2]string{"Enter", "continue →"},
		[2]string{"Esc", "← back"},
	))

	return titledPanel(st, "Select Models", b.String(), 0)
}
