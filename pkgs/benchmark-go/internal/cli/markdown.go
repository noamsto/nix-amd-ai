package cli

import (
	"fmt"
	"strings"
)

// Row holds one model's result for the standard lemonade benchmark table.
// Pointer fields are nil when there were no successful iterations (N/A).
// This mirrors Python's (mean_ttft, mean_tps, stdev_tps) tuple where any
// element may be None.
type Row struct {
	Model   string
	Backend string // recipe string, e.g. "llamacpp" or "llamacpp:rocm"
	// Nil pointers → render as "N/A".
	MeanTTFT *float64
	MeanTPS  *float64
	StdevTPS *float64
}

// MTPRow holds one backend's result for the MTP A/B table.
// Nil TPS pointers → render as "N/A". Mirrors Python's format_mtp_row.
type MTPRow struct {
	Model   string
	Backend string
	OffTPS  *float64 // MTP-off (spec-type none)
	OnTPS   *float64 // MTP-on (spec-type draft-mtp)
}

// RenderMarkdownTable renders a GitHub-flavored markdown table matching
// Python's print_markdown_table exactly.
//
//	| Model | Backend | TTFT (s) | Decode (t/s) |
//	| ----- | ------- | -------: | -----------: |
//	| ...   | ...     |     0.12 | 42.3 +/- 1.2 |
func RenderMarkdownTable(rows []Row) string {
	var sb strings.Builder
	sb.WriteString("| Model | Backend | TTFT (s) | Decode (t/s) |\n")
	sb.WriteString("| ----- | ------- | -------: | -----------: |\n")
	for _, r := range rows {
		ttftStr := fmtTTFT(r.MeanTTFT)
		tpsStr := fmtTPS(r.MeanTPS, r.StdevTPS)
		fmt.Fprintf(&sb, "| %s | %s | %s | %s |\n", r.Model, r.Backend, ttftStr, tpsStr)
	}
	return sb.String()
}

// fmtTTFT formats a TTFT value. nil → "N/A".
func fmtTTFT(v *float64) string {
	if v == nil {
		return "N/A"
	}
	return fmt.Sprintf("%.2f", *v)
}

// fmtTPS formats a decode TPS value with optional stdev. nil mean → "N/A".
// Matches Python's:
//
//	if mean_tps is None:
//	    tps_str = "N/A"
//	elif stdev_tps > 0:
//	    tps_str = f"{mean_tps:.1f} +/- {stdev_tps:.1f}"
//	else:
//	    tps_str = f"{mean_tps:.1f}"
func fmtTPS(mean, stdev *float64) string {
	if mean == nil {
		return "N/A"
	}
	if stdev != nil && *stdev > 0 {
		return fmt.Sprintf("%.1f +/- %.1f", *mean, *stdev)
	}
	return fmt.Sprintf("%.1f", *mean)
}

// RenderMTPMarkdownTable renders the MTP A/B table matching Python's
// run_mtp_ab output:
//
//	| Model | Backend | MTP off (t/s) | MTP on (t/s) | Speedup |
//	| ----- | ------- | ------------: | -----------: | ------: |
func RenderMTPMarkdownTable(rows []MTPRow) string {
	var sb strings.Builder
	sb.WriteString("| Model | Backend | MTP off (t/s) | MTP on (t/s) | Speedup |\n")
	sb.WriteString("| ----- | ------- | ------------: | -----------: | ------: |\n")
	for _, r := range rows {
		sb.WriteString(formatMTPRow(r))
		sb.WriteByte('\n')
	}
	return sb.String()
}

// formatMTPRow formats a single MTP row, matching Python's format_mtp_row.
//
//	def fmt(v):
//	    return f"{v:.1f}" if isinstance(v, (int, float)) else "N/A"
//
//	if off > 0 and on is not None:
//	    speedup = f"{on/off:.2f}x"
//	else:
//	    speedup = "N/A"
func formatMTPRow(r MTPRow) string {
	offStr := fmtMTPTPS(r.OffTPS)
	onStr := fmtMTPTPS(r.OnTPS)

	var speedup string
	if r.OffTPS != nil && *r.OffTPS > 0 && r.OnTPS != nil {
		speedup = fmt.Sprintf("%.2fx", *r.OnTPS / *r.OffTPS)
	} else {
		speedup = "N/A"
	}

	return fmt.Sprintf("| %s | %s | %s | %s | %s |",
		r.Model, r.Backend, offStr, onStr, speedup)
}

// fmtMTPTPS formats a TPS value for the MTP table. nil → "N/A".
func fmtMTPTPS(v *float64) string {
	if v == nil {
		return "N/A"
	}
	return fmt.Sprintf("%.1f", *v)
}
