package tui

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/advise"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/report"
)

// resultRow holds the computed display data for one result unit.
type resultRow struct {
	// unit fields
	Model   string
	Backend string
	Spec    string // "", "off", "on"

	// measured
	MeanTPS  *float64
	StdevTPS *float64
	MeanTTFT *float64

	// predicted vs measured
	Predicted float64 // 0 when unknown
	PctOf     float64 // 0 when unknown
	Estimated bool    // bandwidth or size was estimated
	SizeKnown bool
}

// resultsState holds the results screen state on the model.
type resultsState struct {
	showMarkdown bool
	logMsg       string // raw text set after [w] write; empty = no message
	logErr       bool   // true when logMsg is an error (styled with fail), false for pass
	now          func() time.Time
	logBaseDir   string // base directory for bench-logs-*/; defaults to "."
}

// resultSizeOf resolves a model's total size (GiB) for the results screen.
// It prefers the lemonade API size captured by the picker (reliable, keyed by
// the same display id) and falls back to filesystem GGUF resolution when a
// model wasn't seen in the picker.
func (m model) resultSizeOf(id string) (float64, bool) {
	if g, ok := m.modelSizes[id]; ok && g > 0 {
		return g, true
	}
	return resolveModelSizeGiBByID(id)
}

// buildResultRows computes the display rows for the results screen.
// sizeOf is a seam; pass nil to use the default resolver.
func buildResultRows(results runResults, info hw.Info, sizeOf func(id string) (float64, bool)) []resultRow {
	if sizeOf == nil {
		sizeOf = resolveModelSizeGiBByID
	}

	bwGBs, bwEstimated := advise.BandwidthGBs(info.RAMType, info.RAMSpeedMTs)

	rows := make([]resultRow, 0, len(results.Units))
	for _, u := range results.Units {
		row := resultRow{
			Model:    u.Model,
			Backend:  u.Backend,
			Spec:     u.Spec,
			MeanTPS:  u.MeanTPS,
			StdevTPS: u.StdevTPS,
			MeanTTFT: u.MeanTTFT,
		}

		// Predicted ceiling: bandwidth / active size. Uses EstimateActiveGiB
		// (MoE-aware) on the model's total file size, same as the model picker.
		// Size unknown → Predicted stays 0 and the render shows "—".
		fileSizeGiB, sizeKnown := sizeOf(u.Model)
		row.SizeKnown = sizeKnown
		row.Estimated = bwEstimated || !sizeKnown

		if sizeKnown && fileSizeGiB > 0 {
			activeGiB, _ := advise.EstimateActiveGiB(u.Model, fileSizeGiB)
			row.Predicted = advise.DecodeCeilingTPS(bwGBs, activeGiB)
		}

		// % of ceiling
		if row.Predicted > 0 && u.MeanTPS != nil {
			row.PctOf = *u.MeanTPS / row.Predicted * 100
		}

		rows = append(rows, row)
	}
	return rows
}

// allBackendsEmpty returns true when every unit in results has an empty backend.
func allBackendsEmpty(units []runUnitResult) bool {
	for _, u := range units {
		if u.Backend != "" {
			return false
		}
	}
	return true
}

// logTopicFromMode returns the topic string for the log file directory.
func logTopicFromMode(mode BenchMode) string {
	switch mode {
	case ModeMTP:
		return "mtp"
	case ModeBackend:
		return "backend"
	default:
		return "http"
	}
}

// --- write log command and message ---

// logWrittenMsg is sent after [w] attempts to write the log file.
type logWrittenMsg struct {
	path string
	err  error
}

// writeLogCmd returns a tea.Cmd that writes the markdown export to disk.
func writeLogCmd(content, baseDir, topic string, now func() time.Time) tea.Cmd {
	return func() tea.Msg {
		t := now()
		date := t.Format("2006-01-02")
		hms := t.Format("150405")
		dir := filepath.Join(baseDir, fmt.Sprintf("bench-logs-%s-%s", topic, date))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return logWrittenMsg{err: fmt.Errorf("mkdir: %w", err)}
		}
		path := filepath.Join(dir, fmt.Sprintf("benchmark-%s.md", hms))
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return logWrittenMsg{err: fmt.Errorf("write: %w", err)}
		}
		return logWrittenMsg{path: path}
	}
}

// buildMarkdownExport converts runResults to the appropriate markdown table.
func buildMarkdownExport(results runResults) string {
	switch results.Mode {
	case ModeMTP:
		return buildMTPMarkdown(results)
	default:
		return buildHTTPMarkdown(results)
	}
}

// buildHTTPMarkdown converts HTTP / Backend A/B results to a report.Row slice and renders.
func buildHTTPMarkdown(results runResults) string {
	rows := make([]report.Row, 0, len(results.Units))
	for _, u := range results.Units {
		rows = append(rows, report.Row{
			Model:    u.Model,
			Backend:  u.Backend,
			MeanTTFT: u.MeanTTFT,
			MeanTPS:  u.MeanTPS,
			StdevTPS: u.StdevTPS,
		})
	}
	return report.RenderMarkdownTable(rows)
}

// buildMTPMarkdown converts MTP A/B results (off+on pairs) to a report.MTPRow
// slice and renders. It groups consecutive (model, backend, "off"/"on") pairs.
func buildMTPMarkdown(results runResults) string {
	// Pair off and on units for the same (model, backend).
	type key struct{ model, backend string }
	offMap := map[key]*float64{}
	onMap := map[key]*float64{}
	var order []key
	seen := map[key]bool{}

	for _, u := range results.Units {
		k := key{u.Model, u.Backend}
		if !seen[k] {
			seen[k] = true
			order = append(order, k)
		}
		switch u.Spec {
		case "off":
			offMap[k] = u.MeanTPS
		case "on":
			onMap[k] = u.MeanTPS
		}
	}

	rows := make([]report.MTPRow, 0, len(order))
	for _, k := range order {
		rows = append(rows, report.MTPRow{
			Model:   k.model,
			Backend: k.backend,
			OffTPS:  offMap[k],
			OnTPS:   onMap[k],
		})
	}
	return report.RenderMTPMarkdownTable(rows)
}

// --- results screen key handling ---

// handleResultsKey processes key presses on screenResults.
func (m model) handleResultsKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "m":
		m.results.showMarkdown = !m.results.showMarkdown
		return m, nil

	case "w":
		content := buildMarkdownExport(m.run.results)
		topic := logTopicFromMode(m.run.results.Mode)
		now := m.results.now
		if now == nil {
			now = time.Now
		}
		baseDir := m.results.logBaseDir
		if baseDir == "" {
			baseDir = "."
		}
		return m, writeLogCmd(content, baseDir, topic, now)

	case "esc":
		m.current = screenParams
		m.results.showMarkdown = false
		m.results.logMsg = ""
		m.results.logErr = false
		return m, nil

	case "ctrl+c", "q":
		return m, tea.Quit
	}
	return m, nil
}

// handleLogWritten processes the logWrittenMsg from the write goroutine.
func (m model) handleLogWritten(msg logWrittenMsg) (tea.Model, tea.Cmd) {
	if msg.err != nil {
		m.results.logMsg = "write failed: " + msg.err.Error()
		m.results.logErr = true
	} else {
		m.results.logMsg = "saved: " + msg.path
		m.results.logErr = false
	}
	return m, nil
}

// --- render ---

// renderResults renders the full results screen (table or markdown export).
func renderResults(res runResults, err error, rs resultsState, info hw.Info, sizeOf func(id string) (float64, bool), st styles) string {
	if err != nil {
		var b strings.Builder
		b.WriteString(st.fail.Render("Run failed: "+err.Error()) + "\n")
		b.WriteString("\n" + keybar(st, [2]string{"Esc", "← back"}, [2]string{"q", "quit"}))
		return titledPanel(st, "Results", b.String(), 0)
	}

	if rs.showMarkdown {
		return renderMarkdownView(res, rs.logMsg, rs.logErr, st)
	}
	return renderResultsTable(res, info, sizeOf, rs.logMsg, rs.logErr, st)
}

// renderMarkdownView shows the markdown export as copy-paste text.
func renderMarkdownView(res runResults, logMsg string, logErr bool, st styles) string {
	var b strings.Builder
	b.WriteString(st.value.Render(buildMarkdownExport(res)))
	writeLogMsg(&b, logMsg, logErr, st)
	b.WriteString("\n" + keybar(st,
		[2]string{"m", "← table"},
		[2]string{"w", "write log"},
		[2]string{"q", "quit"},
	))
	return titledPanel(st, "Results — Markdown", b.String(), 0)
}

// writeLogMsg appends the [w] write-log outcome (success or failure) with a
// ✓/✗ prefix, so the feedback is visible in both the table and markdown views.
func writeLogMsg(b *strings.Builder, logMsg string, logErr bool, st styles) {
	if logMsg == "" {
		return
	}
	if logErr {
		b.WriteString("\n" + st.fail.Render("✗ "+logMsg) + "\n")
	} else {
		b.WriteString("\n" + st.pass.Render("✓ "+logMsg) + "\n")
	}
}

// renderResultsTable renders the lipgloss-styled results table.
func renderResultsTable(res runResults, info hw.Info, sizeOf func(id string) (float64, bool), logMsg string, logErr bool, st styles) string {
	var b strings.Builder

	if len(res.Units) == 0 {
		b.WriteString(st.hint.Render("No results.") + "\n")
		b.WriteString("\n" + keybar(st, [2]string{"Esc", "← back"}, [2]string{"q", "quit"}))
		return titledPanel(st, "Results", b.String(), 0)
	}

	rows := buildResultRows(res, info, sizeOf)

	switch res.Mode {
	case ModeMTP:
		renderMTPTable(&b, rows, st)
	default:
		renderHTTPTable(&b, rows, allBackendsEmpty(res.Units), st)
	}

	writeLogMsg(&b, logMsg, logErr, st)

	b.WriteString("\n" + keybar(st,
		[2]string{"m", "markdown"},
		[2]string{"w", "write log"},
		[2]string{"Esc", "← back"},
		[2]string{"q", "quit"},
	))
	return titledPanel(st, "Results", b.String(), 0)
}

// renderHTTPTable renders the HTTP / Backend A/B table.
// The Backend column is omitted when all backends are empty.
func renderHTTPTable(b *strings.Builder, rows []resultRow, omitBackend bool, st styles) {
	// Header
	if omitBackend {
		b.WriteString(st.accent.Render(fmt.Sprintf("%-40s  %-14s  %-10s  %-8s", "Model", "Decode (t/s)", "Predicted", "% ceil")) + "\n")
		b.WriteString(st.rule.Render(strings.Repeat("─", 78)) + "\n")
	} else {
		b.WriteString(st.accent.Render(fmt.Sprintf("%-40s  %-12s  %-14s  %-10s  %-8s", "Model", "Backend", "Decode (t/s)", "Predicted", "% ceil")) + "\n")
		b.WriteString(st.rule.Render(strings.Repeat("─", 92)) + "\n")
	}

	for _, r := range rows {
		decodeStr := report.FmtTPS(r.MeanTPS, r.StdevTPS)
		predStr := fmtPredicted(r.Predicted, r.SizeKnown, r.Estimated)
		pctStr := fmtPct(r.PctOf, r.Predicted, r.MeanTPS)

		if omitBackend {
			line := fmt.Sprintf("%-40s  %-14s  %-10s  %-8s",
				truncate(r.Model, 40), decodeStr, predStr, pctStr)
			b.WriteString(st.value.Render(line) + "\n")
		} else {
			line := fmt.Sprintf("%-40s  %-12s  %-14s  %-10s  %-8s",
				truncate(r.Model, 40), truncate(r.Backend, 12), decodeStr, predStr, pctStr)
			b.WriteString(st.value.Render(line) + "\n")
		}
	}
}

// renderMTPTable renders the MTP A/B table, pairing off/on rows.
func renderMTPTable(b *strings.Builder, rows []resultRow, st styles) {
	b.WriteString(st.accent.Render(fmt.Sprintf("%-40s  %-8s  %-10s  %-10s  %-10s", "Model [backend]", "Spec", "Decode t/s", "Predicted", "Speedup")) + "\n")
	b.WriteString(st.rule.Render(strings.Repeat("─", 86)) + "\n")

	// Group by (model, backend) and render off then on with speedup on the on-line.
	type key struct{ model, backend string }
	type pair struct{ off, on *resultRow }
	pairs := map[key]*pair{}
	var order []key
	seen := map[key]bool{}

	for i := range rows {
		r := &rows[i]
		k := key{r.Model, r.Backend}
		if !seen[k] {
			seen[k] = true
			order = append(order, k)
			pairs[k] = &pair{}
		}
		switch r.Spec {
		case "off":
			pairs[k].off = r
		case "on":
			pairs[k].on = r
		}
	}

	for _, k := range order {
		p := pairs[k]
		label := k.model
		if k.backend != "" {
			label = fmt.Sprintf("%s [%s]", k.model, k.backend)
		}

		var offTPS, onTPS, predStr, speedupStr string
		offTPS = "N/A"
		onTPS = "N/A"
		predStr = "—"
		speedupStr = "—"

		if p.off != nil {
			offTPS = report.FmtMTPTPS(p.off.MeanTPS)
			predStr = fmtPredicted(p.off.Predicted, p.off.SizeKnown, p.off.Estimated)
		}
		if p.on != nil {
			onTPS = report.FmtMTPTPS(p.on.MeanTPS)
		}
		if p.off != nil && p.off.MeanTPS != nil && *p.off.MeanTPS > 0 &&
			p.on != nil && p.on.MeanTPS != nil {
			speedupStr = fmt.Sprintf("%.2fx", *p.on.MeanTPS / *p.off.MeanTPS)
		}

		offLine := fmt.Sprintf("%-40s  %-8s  %-10s  %-10s  %-10s",
			truncate(label, 40), "off", offTPS, predStr, "")
		// Speedup is the last column, so coloring it can't shift earlier columns.
		onPrefix := fmt.Sprintf("%-40s  %-8s  %-10s  %-10s  ", "", "on", onTPS, "")
		speedupRender := st.hint.Render(speedupStr)
		if p.off != nil && p.off.MeanTPS != nil && *p.off.MeanTPS > 0 &&
			p.on != nil && p.on.MeanTPS != nil && *p.on.MeanTPS > *p.off.MeanTPS {
			speedupRender = st.pass.Render(speedupStr)
		}

		b.WriteString(st.value.Render(offLine) + "\n")
		b.WriteString(st.value.Render(onPrefix) + speedupRender + "\n")
	}
}

// fmtPredicted formats the predicted ceiling for display.
// "—" when unknown; "~" prefix when estimated.
func fmtPredicted(pred float64, sizeKnown, estimated bool) string {
	if pred <= 0 || !sizeKnown {
		return "—"
	}
	prefix := ""
	if estimated {
		prefix = "~"
	}
	return fmt.Sprintf("%s%.1f t/s", prefix, pred)
}

// fmtPct formats the % of ceiling.
// "—" when predicted is ≤0 or mean is nil.
func fmtPct(pct, pred float64, mean *float64) string {
	if pred <= 0 || mean == nil {
		return "—"
	}
	return fmt.Sprintf("%.0f%%", pct)
}

// truncate clips a string to n runes, appending "…" when clipped.
func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n-1]) + "…"
}
