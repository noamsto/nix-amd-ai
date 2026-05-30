package cli

import (
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// RenderMarkdownTable
// ---------------------------------------------------------------------------

func ptr(v float64) *float64 { return &v }

func TestRenderMarkdownTable_withResult(t *testing.T) {
	mean := 42.3
	stdev := 1.2
	ttft := 0.12
	rows := []Row{
		{
			Model:    "Gemma-4-26B-A4B-it-GGUF",
			Backend:  "llamacpp",
			MeanTTFT: &ttft,
			MeanTPS:  &mean,
			StdevTPS: &stdev,
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
		{
			Model:    "BadModel",
			Backend:  "llamacpp",
			MeanTTFT: nil,
			MeanTPS:  nil,
			StdevTPS: nil,
		},
	}
	out := RenderMarkdownTable(rows)

	if !strings.Contains(out, "| Model |") {
		t.Errorf("header missing: %q", out)
	}
	// Both TTFT and TPS must show N/A, never "0" or "0.00".
	lines := strings.Split(strings.TrimSpace(out), "\n")
	// lines[0] = header, [1] = sep, [2] = data row
	if len(lines) < 3 {
		t.Fatalf("expected ≥3 lines, got %d: %q", len(lines), out)
	}
	dataLine := lines[2]
	if !strings.Contains(dataLine, "N/A") {
		t.Errorf("N/A missing in data line %q", dataLine)
	}
	// Must NOT contain "0.0" or "0.00" where N/A belongs.
	// The model name "BadModel" doesn't contain digits, so any digit is suspect.
	if strings.Contains(dataLine, "0.0") {
		t.Errorf("got '0.0' in row but expected N/A: %q", dataLine)
	}
}

func TestRenderMarkdownTable_noStdev(t *testing.T) {
	// Single iteration → stdev = 0; should render without "+/-".
	mean := 35.7
	stdev := 0.0
	ttft := 0.5
	rows := []Row{
		{
			Model:    "M",
			Backend:  "llamacpp:rocm",
			MeanTTFT: &ttft,
			MeanTPS:  &mean,
			StdevTPS: &stdev,
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

// ---------------------------------------------------------------------------
// RenderMTPMarkdownTable
// ---------------------------------------------------------------------------

func TestRenderMTPMarkdownTable_withResult(t *testing.T) {
	off := 30.0
	on := 45.0
	rows := []MTPRow{
		{Model: "Qwen3.6-27B-GGUF", Backend: "rocm", OffTPS: &off, OnTPS: &on},
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

// ---------------------------------------------------------------------------
// parseFlags
// ---------------------------------------------------------------------------

func TestParseFlags_defaults(t *testing.T) {
	o, err := parseFlags([]string{"benchmark"})
	if err != nil {
		t.Fatalf("parseFlags error: %v", err)
	}
	if o.MinDecodeTPS != 5.0 {
		t.Errorf("MinDecodeTPS = %v, want 5.0", o.MinDecodeTPS)
	}
	if o.Warmup != 1 {
		t.Errorf("Warmup = %d, want 1", o.Warmup)
	}
	if o.Repeat != 3 {
		t.Errorf("Repeat = %d, want 3", o.Repeat)
	}
	if o.PromptTokens != 512 {
		t.Errorf("PromptTokens = %d, want 512", o.PromptTokens)
	}
	if o.GenTokens != 128 {
		t.Errorf("GenTokens = %d, want 128", o.GenTokens)
	}
	if o.BaseURL != "http://localhost:13305" {
		t.Errorf("BaseURL = %q, want http://localhost:13305", o.BaseURL)
	}
	if o.MTPAbBackends != "rocm,vulkan" {
		t.Errorf("MTPAbBackends = %q, want rocm,vulkan", o.MTPAbBackends)
	}
	if o.CtxSize != 2048 {
		t.Errorf("CtxSize = %d, want 2048", o.CtxSize)
	}
}

func TestParseFlags_mtpAbMutualExclusion(t *testing.T) {
	_, err := parseFlags([]string{"benchmark", "--mtp-ab", "SomeModel", "OtherModel"})
	if err == nil {
		t.Fatal("expected error for --mtp-ab + positional MODEL_ID, got nil")
	}
	if !strings.Contains(err.Error(), "mutually exclusive") {
		t.Errorf("error should mention mutually exclusive, got: %v", err)
	}
}

func TestParseFlags_mtpAbAlone(t *testing.T) {
	o, err := parseFlags([]string{"benchmark", "--mtp-ab", "Qwen3.6-27B-GGUF", "--no-tui"})
	if err != nil {
		t.Fatalf("parseFlags error: %v", err)
	}
	if o.MTPAb != "Qwen3.6-27B-GGUF" {
		t.Errorf("MTPAb = %q, want Qwen3.6-27B-GGUF", o.MTPAb)
	}
	if !o.NoTUI {
		t.Errorf("NoTUI should be true")
	}
}

func TestParseFlags_backendChoices(t *testing.T) {
	for _, b := range []string{"rocm", "vulkan", "auto"} {
		_, err := parseFlags([]string{"benchmark", "--backend", b, "--no-tui", "SomeModel"})
		if err != nil {
			t.Errorf("backend %q should be valid, got: %v", b, err)
		}
	}
	_, err := parseFlags([]string{"benchmark", "--backend", "cuda", "SomeModel"})
	if err == nil {
		t.Error("backend 'cuda' should be rejected")
	}
}

func TestParseFlags_modelIDs(t *testing.T) {
	o, err := parseFlags([]string{"benchmark", "--no-tui", "ModelA", "ModelB"})
	if err != nil {
		t.Fatalf("parseFlags error: %v", err)
	}
	if len(o.ModelIDs) != 2 || o.ModelIDs[0] != "ModelA" || o.ModelIDs[1] != "ModelB" {
		t.Errorf("ModelIDs = %v, want [ModelA ModelB]", o.ModelIDs)
	}
}

func TestSplitBackends(t *testing.T) {
	tests := []struct {
		in   string
		want []string
	}{
		{"rocm,vulkan", []string{"rocm", "vulkan"}},
		{" rocm , vulkan ", []string{"rocm", "vulkan"}},
		{"rocm,,vulkan", []string{"rocm", "vulkan"}},
		{"", []string{}},
	}
	for _, tc := range tests {
		got := splitBackends(tc.in)
		if len(got) != len(tc.want) {
			t.Errorf("splitBackends(%q) = %v, want %v", tc.in, got, tc.want)
			continue
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Errorf("splitBackends(%q)[%d] = %q, want %q", tc.in, i, got[i], tc.want[i])
			}
		}
	}
}
