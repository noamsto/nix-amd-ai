// Package report provides pure, deterministic markdown table renderers for
// benchmark results. It is imported by both cli (headless output) and tui
// (results screen markdown export), so neither package imports the other.
package report

import (
	"fmt"
	"strings"
)

// Row holds one model's result for the standard lemonade benchmark table.
// Pointer fields are nil when there were no successful iterations (N/A).
type Row struct {
	Model   string
	Backend string // recipe string, e.g. "llamacpp" or "llamacpp:rocm"
	// Nil pointers → render as "N/A".
	MeanTTFT *float64
	MeanTPS  *float64
	StdevTPS *float64
}

// MTPRow holds one backend's result for the MTP A/B table.
// Nil TPS pointers → render as "N/A".
type MTPRow struct {
	Model   string
	Backend string
	OffTPS  *float64 // MTP-off (spec-type none)
	OnTPS   *float64 // MTP-on (spec-type draft-mtp)
}

// colAlign controls per-column padding in renderAlignedTable.
type colAlign int

const (
	alignLeft colAlign = iota
	alignRight
)

// renderAlignedTable renders a GitHub-flavored markdown table with every column
// padded to its widest cell, so the source text lines up in a monospace view
// (it still renders identically on GitHub). Right-aligned columns get a "---:"
// separator. Cells are measured by rune count (good enough for model names and
// numbers; no wide-glyph cells here).
func renderAlignedTable(headers []string, aligns []colAlign, rows [][]string) string {
	n := len(headers)
	width := make([]int, n)
	for i, h := range headers {
		width[i] = len([]rune(h))
	}
	for _, row := range rows {
		for i := 0; i < n && i < len(row); i++ {
			if w := len([]rune(row[i])); w > width[i] {
				width[i] = w
			}
		}
	}

	var sb strings.Builder
	writeRow := func(cells []string) {
		sb.WriteByte('|')
		for i := 0; i < n; i++ {
			c := ""
			if i < len(cells) {
				c = cells[i]
			}
			sb.WriteByte(' ')
			sb.WriteString(padCell(c, width[i], aligns[i]))
			sb.WriteString(" |")
		}
		sb.WriteByte('\n')
	}

	writeRow(headers)
	sb.WriteByte('|')
	for i := 0; i < n; i++ {
		sb.WriteByte(' ')
		if aligns[i] == alignRight {
			sb.WriteString(strings.Repeat("-", width[i]-1) + ":")
		} else {
			sb.WriteString(strings.Repeat("-", width[i]))
		}
		sb.WriteString(" |")
	}
	sb.WriteByte('\n')
	for _, r := range rows {
		writeRow(r)
	}
	return sb.String()
}

// padCell pads s to display width w per the alignment.
func padCell(s string, w int, a colAlign) string {
	gap := w - len([]rune(s))
	if gap <= 0 {
		return s
	}
	if a == alignRight {
		return strings.Repeat(" ", gap) + s
	}
	return s + strings.Repeat(" ", gap)
}

// RenderMarkdownTable renders a column-aligned markdown table:
//
//	| Model | Backend       | TTFT (s) | Decode (t/s) |
//	| ----- | ------------- | -------: | -----------: |
//	| M     | llamacpp:rocm |     0.12 | 42.3 +/- 1.2 |
func RenderMarkdownTable(rows []Row) string {
	headers := []string{"Model", "Backend", "TTFT (s)", "Decode (t/s)"}
	aligns := []colAlign{alignLeft, alignLeft, alignRight, alignRight}
	cells := make([][]string, len(rows))
	for i, r := range rows {
		cells[i] = []string{r.Model, r.Backend, FmtTTFT(r.MeanTTFT), FmtTPS(r.MeanTPS, r.StdevTPS)}
	}
	return renderAlignedTable(headers, aligns, cells)
}

func FmtTTFT(v *float64) string {
	if v == nil {
		return "N/A"
	}
	return fmt.Sprintf("%.2f", *v)
}

// FmtTPS formats a decode TPS value with optional stdev. nil mean → "N/A".
// Matches Python's:
//
//	if mean_tps is None:
//	    tps_str = "N/A"
//	elif stdev_tps > 0:
//	    tps_str = f"{mean_tps:.1f} +/- {stdev_tps:.1f}"
//	else:
//	    tps_str = f"{mean_tps:.1f}"
func FmtTPS(mean, stdev *float64) string {
	if mean == nil {
		return "N/A"
	}
	if stdev != nil && *stdev > 0 {
		return fmt.Sprintf("%.1f +/- %.1f", *mean, *stdev)
	}
	return fmt.Sprintf("%.1f", *mean)
}

// RenderMTPMarkdownTable renders the column-aligned MTP A/B table.
//
//	| Model | Backend | MTP off (t/s) | MTP on (t/s) | Speedup |
//	| ----- | ------- | ------------: | -----------: | ------: |
func RenderMTPMarkdownTable(rows []MTPRow) string {
	headers := []string{"Model", "Backend", "MTP off (t/s)", "MTP on (t/s)", "Speedup"}
	aligns := []colAlign{alignLeft, alignLeft, alignRight, alignRight, alignRight}
	cells := make([][]string, len(rows))
	for i, r := range rows {
		cells[i] = []string{r.Model, r.Backend, FmtMTPTPS(r.OffTPS), FmtMTPTPS(r.OnTPS), mtpSpeedup(r)}
	}
	return renderAlignedTable(headers, aligns, cells)
}

// mtpSpeedup formats the on/off ratio, or "N/A" when it can't be computed.
func mtpSpeedup(r MTPRow) string {
	if r.OffTPS != nil && *r.OffTPS > 0 && r.OnTPS != nil {
		return fmt.Sprintf("%.2fx", *r.OnTPS / *r.OffTPS)
	}
	return "N/A"
}

func FmtMTPTPS(v *float64) string {
	if v == nil {
		return "N/A"
	}
	return fmt.Sprintf("%.1f", *v)
}
