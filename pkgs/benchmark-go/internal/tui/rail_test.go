package tui

import (
	"strings"
	"testing"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/preflight"
)

// ---------------------------------------------------------------------------
// Task 1 tests
// ---------------------------------------------------------------------------

func TestSummarizePreflight(t *testing.T) {
	t.Run("nil returns not-ran", func(t *testing.T) {
		s := summarizePreflight(nil)
		if s.ran {
			t.Fatal("nil results: expected ran=false")
		}
	})

	t.Run("empty slice returns not-ran", func(t *testing.T) {
		s := summarizePreflight([]preflight.Result{})
		if s.ran {
			t.Fatal("empty results: expected ran=false")
		}
	})

	t.Run("Pass results → ran, issues=0", func(t *testing.T) {
		results := []preflight.Result{
			{Status: preflight.Pass},
			{Status: preflight.Pass},
		}
		s := summarizePreflight(results)
		if !s.ran {
			t.Fatal("expected ran=true")
		}
		if s.issues != 0 {
			t.Fatalf("expected issues=0, got %d", s.issues)
		}
	})

	t.Run("Warn+Fail → ran, issues=2", func(t *testing.T) {
		results := []preflight.Result{
			{Status: preflight.Warn},
			{Status: preflight.Fail},
		}
		s := summarizePreflight(results)
		if !s.ran {
			t.Fatal("expected ran=true")
		}
		if s.issues != 2 {
			t.Fatalf("expected issues=2, got %d", s.issues)
		}
	})
}

func TestRailSegments(t *testing.T) {
	t.Run("railGPU 0 → contains GPU 0% and ✓", func(t *testing.T) {
		s := railGPU(0)
		if !strings.Contains(s, "GPU") {
			t.Fatalf("railGPU(0) missing 'GPU': %q", s)
		}
		if !strings.Contains(s, "0%") {
			t.Fatalf("railGPU(0) missing '0%%': %q", s)
		}
		if !strings.Contains(s, "✓") {
			t.Fatalf("railGPU(0) missing '✓': %q", s)
		}
	})

	t.Run("railGPU 42 → contains 42% and ⚠", func(t *testing.T) {
		s := railGPU(42)
		if !strings.Contains(s, "42%") {
			t.Fatalf("railGPU(42) missing '42%%': %q", s)
		}
		if !strings.Contains(s, "⚠") {
			t.Fatalf("railGPU(42) missing '⚠': %q", s)
		}
	})

	t.Run("railPower AC+perf → contains AC and ✓", func(t *testing.T) {
		info := hw.Info{OnAC: true, Performance: true}
		s := railPower(info)
		if !strings.Contains(s, "AC") {
			t.Fatalf("railPower(AC+perf) missing 'AC': %q", s)
		}
		if !strings.Contains(s, "✓") {
			t.Fatalf("railPower(AC+perf) missing '✓': %q", s)
		}
	})

	t.Run("railPower !OnAC → contains battery", func(t *testing.T) {
		info := hw.Info{OnAC: false}
		s := railPower(info)
		if !strings.Contains(s, "battery") {
			t.Fatalf("railPower(!OnAC) missing 'battery': %q", s)
		}
	})

	t.Run("railPreflight ran,0 → clean", func(t *testing.T) {
		s := railPreflight(railPreflightSummary{ran: true, issues: 0})
		if !strings.Contains(s, "clean") {
			t.Fatalf("railPreflight(ran,0) missing 'clean': %q", s)
		}
	})

	t.Run("railPreflight ran,3 → contains 3", func(t *testing.T) {
		s := railPreflight(railPreflightSummary{ran: true, issues: 3})
		if !strings.Contains(s, "3") {
			t.Fatalf("railPreflight(ran,3) missing '3': %q", s)
		}
	})

	t.Run("railPreflight !ran → …", func(t *testing.T) {
		s := railPreflight(railPreflightSummary{ran: false})
		if !strings.Contains(s, "…") {
			t.Fatalf("railPreflight(!ran) missing '…': %q", s)
		}
	})
}

func TestJoinFitTruncates(t *testing.T) {
	segs := []string{"alpha", "bravo", "charlie"}

	t.Run("wide width keeps all segments", func(t *testing.T) {
		result := joinFit(segs, " · ", 100)
		for _, seg := range segs {
			if !strings.Contains(result, seg) {
				t.Fatalf("joinFit(width=100) dropped %q: %q", seg, result)
			}
		}
	})

	t.Run("narrow width truncates and appends …", func(t *testing.T) {
		result := joinFit(segs, " · ", 12)
		if !strings.Contains(result, "…") {
			t.Fatalf("joinFit(width=12) missing '…': %q", result)
		}
		// Must not contain charlie (last segment) since it was dropped.
		if strings.Contains(result, "charlie") {
			t.Fatalf("joinFit(width=12) should have dropped 'charlie': %q", result)
		}
	})
}

func TestRenderRailContainsArchNoPanic(t *testing.T) {
	info := hw.Info{
		GfxArch:  "gfx1150",
		GTTBytes: 27 << 30,
		OnAC:     true,
	}
	st := railState{gpuPct: 0}
	result := renderRail(info, st, 120)
	if !strings.Contains(result, "gfx1150") {
		t.Fatalf("renderRail missing 'gfx1150': %q", result)
	}
}

// ---------------------------------------------------------------------------
// Task 2 tests
// ---------------------------------------------------------------------------

func TestInitStartsRailTick(t *testing.T) {
	info := hw.Info{GfxArch: "gfx1150", GTTBytes: 27 << 30}
	m := New(info, Config{})
	cmd := m.Init()
	if cmd == nil {
		t.Fatal("Init() returned nil; expected a rail tick command")
	}
}

func TestRailTickUpdatesAndRearms(t *testing.T) {
	info := hw.Info{GfxArch: "gfx1150", GTTBytes: 27 << 30}
	raw := New(info, Config{})
	m, ok := raw.(model)
	if !ok {
		t.Fatalf("New() returned %T, not model", raw)
	}
	m.railGRBM = func() float64 { return 73 }

	updated, cmd := m.Update(railTickMsg{pct: 73})
	nm, ok := updated.(model)
	if !ok {
		t.Fatalf("Update returned %T, not model", updated)
	}
	if nm.rail.gpuPct != 73 {
		t.Fatalf("expected gpuPct=73, got %f", nm.rail.gpuPct)
	}
	if cmd == nil {
		t.Fatal("Update railTickMsg: expected non-nil cmd (rearm)")
	}
}

func TestPreflightResultsRefreshRailSummary(t *testing.T) {
	info := hw.Info{GfxArch: "gfx1150", GTTBytes: 27 << 30}
	raw := New(info, Config{})
	m, ok := raw.(model)
	if !ok {
		t.Fatalf("New() returned %T, not model", raw)
	}

	results := []preflight.Result{
		{Status: preflight.Warn},
		{Status: preflight.Pass},
	}
	updated, _ := m.Update(preflightResultsMsg{results: results})
	nm, ok := updated.(model)
	if !ok {
		t.Fatalf("Update returned %T, not model", updated)
	}
	if !nm.rail.preflight.ran {
		t.Fatal("expected rail.preflight.ran=true after preflightResultsMsg")
	}
	if nm.rail.preflight.issues != 1 {
		t.Fatalf("expected rail.preflight.issues=1, got %d", nm.rail.preflight.issues)
	}
}
