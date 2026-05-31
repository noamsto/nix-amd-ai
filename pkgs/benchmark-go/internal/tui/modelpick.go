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
	downloaded  bool     // false → model is available but not yet downloaded
	hot         bool     // lemonade "hot" label (community-featured) → 🔥
	recommended bool     // good for THIS hardware: fits comfortably + decent predicted t/s → ⚡
	labels      []string // raw lemonade labels, for filter matching (lower priority than id)
}

// filterRows returns the indices of rows matching query, in display order:
// id-substring matches first, then rows that match only on a label. An empty
// or whitespace query returns all indices in natural order. Matching is
// case-insensitive.
func filterRows(rows []modelRow, query string) []int {
	q := strings.ToLower(strings.TrimSpace(query))
	if q == "" {
		all := make([]int, len(rows))
		for i := range rows {
			all[i] = i
		}
		return all
	}
	var idHits, labelHits []int
	for i, r := range rows {
		switch {
		case strings.Contains(strings.ToLower(r.id), q):
			idHits = append(idHits, i)
		case labelsContain(r.labels, q):
			labelHits = append(labelHits, i)
		}
	}
	return append(idHits, labelHits...)
}

// trimLastRune drops the final rune of s (backspace in the filter input).
func trimLastRune(s string) string {
	if s == "" {
		return s
	}
	r := []rune(s)
	return string(r[:len(r)-1])
}

// labelsContain reports whether any label contains q (q is already lower-cased).
func labelsContain(labels []string, q string) bool {
	for _, l := range labels {
		if strings.Contains(strings.ToLower(l), q) {
			return true
		}
	}
	return false
}

// visibleRange windows n rows around cursor so at most maxRows are shown and
// the cursor stays visible. maxRows<=0 or n<=maxRows shows everything. The
// window centres on the cursor, clamped to the ends — a pure function of
// (n, cursor, maxRows) with no scroll-position state.
func visibleRange(n, cursor, maxRows int) (start, end int) {
	if maxRows <= 0 || n <= maxRows {
		return 0, n
	}
	start = cursor - maxRows/2
	if start < 0 {
		start = 0
	}
	if start > n-maxRows {
		start = n - maxRows
	}
	return start, start + maxRows
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

	// Filter state (the `/` search). cursor indexes into `visible`, not `rows`;
	// selection lives on the underlying modelRow, so it survives filter changes.
	filtering bool   // true → the filter input has focus; keystrokes edit `filter`
	filter    string // current query; applies while non-empty even when not editing
	visible   []int  // row indices matching `filter`, in display order (nil → unfiltered)

	// fetchModels is a test seam to avoid real network calls.
	fetchModels func(baseURL string) ([]models.Model, error)
}

// view returns the row indices currently displayed. Before any filter is
// applied (visible nil) it falls back to all rows in natural order, so an
// unfiltered picker behaves exactly as before.
func (p *modelPicker) view() []int {
	if p.visible == nil {
		all := make([]int, len(p.rows))
		for i := range p.rows {
			all[i] = i
		}
		return all
	}
	return p.visible
}

// applyFilter recomputes the visible window from the current query and clamps
// the cursor into range. Always leaves visible non-nil so a zero-match query
// shows nothing rather than falling back to the full list.
func (p *modelPicker) applyFilter() {
	p.visible = filterRows(p.rows, p.filter)
	if p.visible == nil {
		p.visible = []int{}
	}
	if p.cursor >= len(p.visible) {
		p.cursor = len(p.visible) - 1
	}
	if p.cursor < 0 {
		p.cursor = 0
	}
}

// toggleSelected toggles the selection of the row under the cursor (in the
// filtered view).
func (p *modelPicker) toggleSelected() {
	v := p.view()
	if p.cursor < 0 || p.cursor >= len(v) {
		return
	}
	p.rows[v[p.cursor]].selected = !p.rows[v[p.cursor]].selected
	p.needSelection = false // any toggle clears the "select something" hint
}

// apiSizeMap returns id→total GiB for rows whose size is known from the
// lemonade API. Used to feed the results screen a reliable size.
func apiSizeMap(rows []modelRow) map[string]float64 {
	m := make(map[string]float64)
	for _, r := range rows {
		if r.sizeKnown {
			m[r.id] = r.totalGiB
		}
	}
	return m
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
	p.filter = ""
	p.filtering = false
	p.visible = nil

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
			labels:     m.Labels,
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

// modelListReserved is the count of non-list lines on the model screen (rail,
// stepper, panel chrome, filter line, legend, keybar, scroll affordances) —
// subtracted from terminal height to size the scrollable model window.
const modelListReserved = 14

// modelListMin floors the visible window so a short or pre-resize terminal
// still shows a usable handful of rows.
const modelListMin = 5

// modelListRows returns how many model rows fit a terminal of the given height.
// Height 0 (before the first resize) falls back to a generous default so the
// list is never worse than the old unbounded render on a normal terminal.
func modelListRows(height int) int {
	if height <= 0 {
		return 20
	}
	if n := height - modelListReserved; n > modelListMin {
		return n
	}
	return modelListMin
}

func renderModelScreen(p *modelPicker, st styles, maxRows int) string {
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

	// Filter line: shown while editing or whenever a query is active. A block
	// cursor trails the query in edit mode.
	if p.filtering || p.filter != "" {
		q := p.filter
		if p.filtering {
			q += st.cursorStr
		}
		matches := len(p.view())
		unit := "matches"
		if matches == 1 {
			unit = "match"
		}
		b.WriteString(st.accent.Render("/") + st.value.Render(q) +
			"   " + st.hint.Render(fmt.Sprintf("%d %s", matches, unit)) + "\n\n")
	}

	v := p.view()
	if len(v) == 0 {
		// Rows exist but none match the active filter.
		b.WriteString(st.hint.Render(fmt.Sprintf("No models match %q.", p.filter)) + "\n")
	} else {
		start, end := visibleRange(len(v), p.cursor, maxRows)
		if start > 0 {
			b.WriteString(st.hint.Render(fmt.Sprintf("  ↑ %d more", start)) + "\n")
		}
		for i := start; i < end; i++ {
			r := p.rows[v[i]]
			line := formatModelRow(r.id, r.totalGiB, r.sizeKnown, r.fit, r.ceilingTPS, r.isMoE, r.estimated, r.selected, r.downloaded, r.hot, r.recommended)
			if i == p.cursor {
				b.WriteString(st.focusBullet(true) + st.value.Render(line) + "\n")
			} else {
				b.WriteString(st.focusBullet(false) + st.label.Render(line) + "\n")
			}
		}
		if end < len(v) {
			b.WriteString(st.hint.Render(fmt.Sprintf("  ↓ %d more", len(v)-end)) + "\n")
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

	if p.filtering {
		b.WriteString("\n" + keybar(st,
			[2]string{"type", "filter"},
			[2]string{"Enter/↓", "apply"},
			[2]string{"Esc", "clear"},
		))
		return titledPanel(st, "Select Models", b.String(), 0)
	}

	escLabel := "← back"
	if p.filter != "" {
		escLabel = "clear filter"
	}
	b.WriteString("\n" + keybar(st,
		[2]string{"/", "filter"},
		[2]string{"↑/↓", "move"},
		[2]string{"Space", "toggle"},
		[2]string{"Enter", "continue →"},
		[2]string{"Esc", escLabel},
	))

	return titledPanel(st, "Select Models", b.String(), 0)
}
