package cli

import "github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/report"

// Row is an alias for report.Row so cli callers need not import report.
type Row = report.Row

// MTPRow is an alias for report.MTPRow so cli callers need not import report.
type MTPRow = report.MTPRow

// RenderMarkdownTable delegates to report.RenderMarkdownTable.
func RenderMarkdownTable(rows []Row) string { return report.RenderMarkdownTable(rows) }

// RenderMTPMarkdownTable delegates to report.RenderMTPMarkdownTable.
func RenderMTPMarkdownTable(rows []MTPRow) string { return report.RenderMTPMarkdownTable(rows) }
