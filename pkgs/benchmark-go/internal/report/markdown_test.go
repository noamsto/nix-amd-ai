package report

import (
	"strings"
	"testing"
)

func ptr(v float64) *float64 { return &v }

func TestRenderMarkdownTable_withResult(t *testing.T) {
	rows := []Row{
		{
			Model:    "Gemma-4-26B-A4B-it-GGUF",
			Backend:  "llamacpp",
			MeanTTFT: ptr(0.12),
			MeanTPS:  ptr(42.3),
			StdevTPS: ptr(1.2),
		},
	}
	out := RenderMarkdownTable(rows)

	if !strings.Contains(out, "| Model |") {
		t.Errorf("header missing: %q", out)
	}
	if !strings.Contains(out, "Gemma-4-26B-A4B-it-GGUF") {
		t.Errorf("model name missing: %q", out)
	}
	if !strings.Contains(out, "42.3 +/- 1.2") {
		t.Errorf("TPS with stdev missing: %q", out)
	}
	if !strings.Contains(out, "0.12") {
		t.Errorf("TTFT missing: %q", out)
	}
}

func TestRenderMarkdownTable_naResult(t *testing.T) {
	rows := []Row{
		{Model: "BadModel", Backend: "llamacpp", MeanTTFT: nil, MeanTPS: nil, StdevTPS: nil},
	}
	out := RenderMarkdownTable(rows)

	if !strings.Contains(out, "| Model |") {
		t.Errorf("header missing: %q", out)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 3 {
		t.Fatalf("expected ≥3 lines, got %d: %q", len(lines), out)
	}
	dataLine := lines[2]
	if !strings.Contains(dataLine, "N/A") {
		t.Errorf("N/A missing in data line %q", dataLine)
	}
	if strings.Contains(dataLine, "0.0") {
		t.Errorf("got '0.0' in row but expected N/A: %q", dataLine)
	}
}

func TestRenderMarkdownTable_noStdev(t *testing.T) {
	rows := []Row{
		{
			Model:    "M",
			Backend:  "llamacpp:rocm",
			MeanTTFT: ptr(0.5),
			MeanTPS:  ptr(35.7),
			StdevTPS: ptr(0.0),
		},
	}
	out := RenderMarkdownTable(rows)
	if strings.Contains(out, "+/-") {
		t.Errorf("stdev=0 should not render +/-: %q", out)
	}
	if !strings.Contains(out, "35.7") {
		t.Errorf("TPS value missing: %q", out)
	}
}

func TestRenderMTPMarkdownTable_withResult(t *testing.T) {
	rows := []MTPRow{
		{Model: "Qwen3.6-27B-GGUF", Backend: "rocm", OffTPS: ptr(30.0), OnTPS: ptr(45.0)},
	}
	out := RenderMTPMarkdownTable(rows)

	if !strings.Contains(out, "MTP off") {
		t.Errorf("MTP off header missing: %q", out)
	}
	if !strings.Contains(out, "1.50x") {
		t.Errorf("speedup 1.50x missing: %q", out)
	}
	if !strings.Contains(out, "30.0") {
		t.Errorf("off TPS 30.0 missing: %q", out)
	}
	if !strings.Contains(out, "45.0") {
		t.Errorf("on TPS 45.0 missing: %q", out)
	}
}

func TestRenderMTPMarkdownTable_naResult(t *testing.T) {
	rows := []MTPRow{
		{Model: "M", Backend: "rocm", OffTPS: nil, OnTPS: nil},
	}
	out := RenderMTPMarkdownTable(rows)
	if !strings.Contains(out, "N/A") {
		t.Errorf("N/A missing: %q", out)
	}
}
