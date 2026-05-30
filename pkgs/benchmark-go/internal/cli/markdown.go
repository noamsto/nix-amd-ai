package cli

import "github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/report"

type Row = report.Row
type MTPRow = report.MTPRow

func RenderMarkdownTable(rows []Row) string       { return report.RenderMarkdownTable(rows) }
func RenderMTPMarkdownTable(rows []MTPRow) string { return report.RenderMTPMarkdownTable(rows) }
