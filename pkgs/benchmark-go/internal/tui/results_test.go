package tui

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
)

// --- helpers ---

func ptrF(v float64) *float64 { return &v }

func testHWInfoFull() hw.Info {
	return hw.Info{
		RAMType:     "DDR5",
		RAMSpeedMTs: 5600,
		RAMGiB:      54.5,
		GTTBytes:    27 << 30,
	}
}

func fixedSizeOf(gib float64, known bool) func(string) (float64, bool) {
	return func(_ string) (float64, bool) { return gib, known }
}

// --- buildResultRows ---

func TestBuildResultRows_httpKnownSize(t *testing.T) {
	results := runResults{
		Mode: ModeHTTP,
		Units: []runUnitResult{
			{
				Model:   "Qwen3-30B-A3B-GGUF",
				MeanTPS: ptrF(40.0),
			},
		},
	}
	info := testHWInfoFull()
	// 18 GiB file size, MoE model A3B of 30B → active ≈ 18 * 3/30 = 1.8 GiB
	rows := buildResultRows(results, info, fixedSizeOf(18.0, true))

	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %d", len(rows))
	}
	r := rows[0]
	if r.Model != "Qwen3-30B-A3B-GGUF" {
		t.Errorf("Model = %q", r.Model)
	}
	if r.Predicted <= 0 {
		t.Errorf("Predicted should be >0, got %f", r.Predicted)
	}
	if r.PctOf <= 0 {
		t.Errorf("PctOf should be >0, got %f", r.PctOf)
	}
	if !r.SizeKnown {
		t.Error("SizeKnown should be true")
	}
}

func TestBuildResultRows_unknownSize(t *testing.T) {
	results := runResults{
		Mode: ModeHTTP,
		Units: []runUnitResult{
			{Model: "SomeModel", MeanTPS: ptrF(30.0)},
		},
	}
	rows := buildResultRows(results, testHWInfoFull(), fixedSizeOf(0, false))

	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %d", len(rows))
	}
	r := rows[0]
	if r.Predicted != 0 {
		t.Errorf("Predicted should be 0 for unknown size, got %f", r.Predicted)
	}
	if r.PctOf != 0 {
		t.Errorf("PctOf should be 0 for unknown size, got %f", r.PctOf)
	}
	if r.SizeKnown {
		t.Error("SizeKnown should be false")
	}
	if !r.Estimated {
		t.Error("Estimated should be true when size unknown")
	}
}

func TestBuildResultRows_nilMeanTPS(t *testing.T) {
	results := runResults{
		Mode:  ModeHTTP,
		Units: []runUnitResult{{Model: "M", MeanTPS: nil}},
	}
	rows := buildResultRows(results, testHWInfoFull(), fixedSizeOf(10.0, true))
	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %d", len(rows))
	}
	if rows[0].PctOf != 0 {
		t.Errorf("PctOf should be 0 when MeanTPS is nil, got %f", rows[0].PctOf)
	}
}

// --- buildMarkdownExport ---

func TestBuildMarkdownExport_HTTP(t *testing.T) {
	results := runResults{
		Mode: ModeHTTP,
		Units: []runUnitResult{
			{Model: "M", Backend: "llamacpp", MeanTPS: ptrF(42.0), MeanTTFT: ptrF(0.1)},
		},
	}
	out := buildMarkdownExport(results)
	if !strings.Contains(out, "| Model |") {
		t.Errorf("missing header: %q", out)
	}
	if !strings.Contains(out, "42.0") {
		t.Errorf("missing TPS value: %q", out)
	}
}

func TestBuildMarkdownExport_MTP(t *testing.T) {
	results := runResults{
		Mode: ModeMTP,
		Units: []runUnitResult{
			{Model: "M", Backend: "rocm", Spec: "off", MeanTPS: ptrF(30.0)},
			{Model: "M", Backend: "rocm", Spec: "on", MeanTPS: ptrF(45.0)},
		},
	}
	out := buildMarkdownExport(results)
	if !strings.Contains(out, "MTP off") {
		t.Errorf("missing MTP off header: %q", out)
	}
	if !strings.Contains(out, "1.50x") {
		t.Errorf("missing speedup 1.50x: %q", out)
	}
}

// --- writeLogCmd / log path + content ---

func TestWriteLogCmd_pathAndContent(t *testing.T) {
	tmp := t.TempDir()
	fixed := time.Date(2026, 5, 30, 14, 5, 9, 0, time.UTC)
	now := func() time.Time { return fixed }

	content := "# Benchmark Results\nsome content\n"
	cmd := writeLogCmd(content, tmp, "http", now)
	msg := cmd()

	lwm, ok := msg.(logWrittenMsg)
	if !ok {
		t.Fatalf("expected logWrittenMsg, got %T", msg)
	}
	if lwm.err != nil {
		t.Fatalf("unexpected error: %v", lwm.err)
	}

	// Path: <tmp>/bench-logs-http-2026-05-30/benchmark-140509.md
	expectedDir := filepath.Join(tmp, "bench-logs-http-2026-05-30")
	expectedFile := filepath.Join(expectedDir, "benchmark-140509.md")

	if lwm.path != expectedFile {
		t.Errorf("path = %q, want %q", lwm.path, expectedFile)
	}

	data, err := os.ReadFile(lwm.path)
	if err != nil {
		t.Fatalf("reading written file: %v", err)
	}
	if string(data) != content {
		t.Errorf("content = %q, want %q", string(data), content)
	}
}

func TestWriteLogCmd_MTPTopic(t *testing.T) {
	tmp := t.TempDir()
	fixed := time.Date(2026, 5, 30, 9, 0, 0, 0, time.UTC)
	now := func() time.Time { return fixed }

	cmd := writeLogCmd("content", tmp, "mtp", now)
	msg := cmd()
	lwm := msg.(logWrittenMsg)
	if lwm.err != nil {
		t.Fatalf("unexpected error: %v", lwm.err)
	}
	if !strings.Contains(lwm.path, "bench-logs-mtp-2026-05-30") {
		t.Errorf("path should contain mtp topic, got %q", lwm.path)
	}
}

// --- logTopicFromMode ---

func TestLogTopicFromMode(t *testing.T) {
	tests := []struct {
		mode BenchMode
		want string
	}{
		{ModeMTP, "mtp"},
		{ModeBackend, "backend"},
		{ModeHTTP, "http"},
	}
	for _, tc := range tests {
		got := logTopicFromMode(tc.mode)
		if got != tc.want {
			t.Errorf("logTopicFromMode(%v) = %q, want %q", tc.mode, got, tc.want)
		}
	}
}

// --- fmtPredicted / fmtPct ---

func TestFmtPredicted_known(t *testing.T) {
	got := fmtPredicted(85.3, true, false)
	if got != "85.3 t/s" {
		t.Errorf("got %q, want %q", got, "85.3 t/s")
	}
}

func TestFmtPredicted_estimated(t *testing.T) {
	got := fmtPredicted(85.3, true, true)
	if got != "~85.3 t/s" {
		t.Errorf("got %q, want %q", got, "~85.3 t/s")
	}
}

func TestFmtPredicted_unknown(t *testing.T) {
	got := fmtPredicted(0, false, false)
	if got != "—" {
		t.Errorf("got %q, want %q", got, "—")
	}
}

func TestFmtPct_valid(t *testing.T) {
	mean := 42.5
	got := fmtPct(50.0, 85.0, &mean)
	if got != "50%" {
		t.Errorf("got %q, want %q", got, "50%")
	}
}

func TestFmtPct_noPred(t *testing.T) {
	mean := 42.5
	got := fmtPct(0, 0, &mean)
	if got != "—" {
		t.Errorf("got %q, want %q", got, "—")
	}
}

func TestFmtPct_nilMean(t *testing.T) {
	got := fmtPct(50.0, 85.0, nil)
	if got != "—" {
		t.Errorf("got %q, want %q", got, "—")
	}
}

// --- truncate ---

func TestTruncate_short(t *testing.T) {
	if got := truncate("hello", 10); got != "hello" {
		t.Errorf("got %q", got)
	}
}

func TestTruncate_exact(t *testing.T) {
	if got := truncate("hello", 5); got != "hello" {
		t.Errorf("got %q", got)
	}
}

func TestTruncate_long(t *testing.T) {
	got := truncate("hello world", 8)
	if !strings.HasSuffix(got, "…") {
		t.Errorf("expected ellipsis suffix, got %q", got)
	}
	if len([]rune(got)) != 8 {
		t.Errorf("expected length 8, got %d: %q", len([]rune(got)), got)
	}
}
