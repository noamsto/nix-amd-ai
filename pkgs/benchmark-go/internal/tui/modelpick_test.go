package tui

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/exp/teatest/v2"

	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/advise"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/hw"
	"github.com/noamsto/nix-amd-ai/pkgs/benchmark-go/internal/models"
)

// TestFormatModelRow_Glyphs verifies that formatModelRow produces the correct
// fit glyph, MoE tag, and estimation prefix.
func TestFormatModelRow_Glyphs(t *testing.T) {
	t.Run("fits dense no estimate", func(t *testing.T) {
		out := formatModelRow("MyModel-7B-GGUF", 4.5, true, advise.Fits, 12.3, false, false, false, true, false, false)
		if !strings.Contains(out, "✅") {
			t.Errorf("expected ✅ in %q", out)
		}
		if strings.Contains(out, "~") {
			t.Errorf("unexpected ~ in %q", out)
		}
		if strings.Contains(out, "(MoE)") {
			t.Errorf("unexpected (MoE) in %q", out)
		}
	})

	t.Run("spills with estimate and MoE", func(t *testing.T) {
		out := formatModelRow("Gemma-4-26B-A4B", 15.7, true, advise.Spills, 42.0, true, true, false, true, false, false)
		if !strings.Contains(out, "❌") {
			t.Errorf("expected ❌ in %q", out)
		}
		if !strings.Contains(out, "~") {
			t.Errorf("expected ~ in %q", out)
		}
		if !strings.Contains(out, "(MoE)") {
			t.Errorf("expected (MoE) in %q", out)
		}
	})

	t.Run("tight selected", func(t *testing.T) {
		out := formatModelRow("Model-14B", 8.0, true, advise.Tight, 5.0, false, false, true, true, false, false)
		if !strings.Contains(out, "⚠️") {
			t.Errorf("expected ⚠️ in %q", out)
		}
		if !strings.Contains(out, "[✓]") {
			t.Errorf("expected [✓] in %q", out)
		}
	})

	t.Run("unknown size shows ? glyph not cross", func(t *testing.T) {
		out := formatModelRow("UnknownModel", 0, false, advise.Fits, 0, false, false, false, true, false, false)
		if strings.Contains(out, "❌") {
			t.Errorf("unknown-size row must not show ❌ in %q", out)
		}
		if !strings.Contains(out, "?") {
			t.Errorf("unknown-size row should show ? in %q", out)
		}
	})

	t.Run("unknown size with fit=Spills still shows ? not cross", func(t *testing.T) {
		// Even if fit field is Spills (stale default), unknown size → neutral glyph.
		out := formatModelRow("UnknownModel", 0, false, advise.Spills, 0, false, false, false, true, false, false)
		if strings.Contains(out, "❌") {
			t.Errorf("unknown-size row must not show ❌ in %q", out)
		}
		if !strings.Contains(out, "?") {
			t.Errorf("unknown-size row should show ? in %q", out)
		}
	})
}

// TestFormatModelRow_Markers verifies the trailing ⚡ (HW-recommended),
// 🔥 (hot) and ⬇ (not-downloaded) markers render correctly.
// Arg order: (id, totalGiB, sizeKnown, fit, ceilingTPS, isMoE, estimated,
// selected, downloaded, hot, recommended).
func TestFormatModelRow_Markers(t *testing.T) {
	t.Run("not-downloaded shows down arrow", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, false, false, false)
		if !strings.Contains(out, "⬇") {
			t.Errorf("not-downloaded row should contain ⬇ in %q", out)
		}
	})

	t.Run("downloaded does not show down arrow", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, false, false)
		if strings.Contains(out, "⬇") {
			t.Errorf("downloaded row must not show ⬇ in %q", out)
		}
	})

	t.Run("hot shows fire", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, true, false)
		if !strings.Contains(out, "🔥") {
			t.Errorf("hot row should contain 🔥 in %q", out)
		}
	})

	t.Run("not hot does not show fire", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, false, false)
		if strings.Contains(out, "🔥") {
			t.Errorf("non-hot row must not show 🔥 in %q", out)
		}
	})

	t.Run("recommended shows bolt", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, false, true)
		if !strings.Contains(out, "⚡") {
			t.Errorf("recommended row should contain ⚡ in %q", out)
		}
	})

	t.Run("all three markers together", func(t *testing.T) {
		out := formatModelRow("SomeModel-7B-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, false, true, true)
		for _, want := range []string{"⚡", "🔥", "⬇"} {
			if !strings.Contains(out, want) {
				t.Errorf("expected %s in %q", want, out)
			}
		}
	})
}

// TestFormatModelRow_Alignment verifies that rows with different id lengths
// produce the size column starting at the same display column.
// Also verifies that marked vs unmarked rows have the same size column offset.
func TestFormatModelRow_Alignment(t *testing.T) {
	short := formatModelRow("A", 4.5, true, advise.Fits, 10.0, false, false, false, true, false, false)
	long := formatModelRow("A-Very-Long-Model-Name-That-Gets-Truncated-GGUF", 4.5, true, advise.Fits, 10.0, false, false, false, true, false, false)

	// Find the display offset of the size string "4.5 GiB" in each row.
	findSizeOffset := func(row string) int {
		target := "4.5 GiB"
		idx := strings.Index(row, target)
		if idx < 0 {
			return -1
		}
		return lipgloss.Width(row[:idx])
	}

	shortOff := findSizeOffset(short)
	longOff := findSizeOffset(long)

	if shortOff < 0 || longOff < 0 {
		t.Fatalf("size string not found: short=%q long=%q", short, long)
	}
	if shortOff != longOff {
		t.Errorf("size column at display offset %d (short) vs %d (long); want equal\nshort: %s\n long: %s",
			shortOff, longOff, short, long)
	}

	// Marker vs no-marker: size column offset must be identical (markers TRAIL
	// at the end of the row, so they can't affect the id or size columns).
	withMarkers := formatModelRow("SomeModel", 4.5, true, advise.Fits, 10.0, false, false, false, false, false, true)
	noMarkers := formatModelRow("SomeModel", 4.5, true, advise.Fits, 10.0, false, false, false, true, false, false)

	markedOff := findSizeOffset(withMarkers)
	plainOff := findSizeOffset(noMarkers)
	if markedOff < 0 || plainOff < 0 {
		t.Fatalf("size string not found in marker test: marked=%q plain=%q", withMarkers, noMarkers)
	}
	if markedOff != plainOff {
		t.Errorf("marker shifts size column: marked offset %d vs plain %d\nmarked: %s\nplain:  %s",
			markedOff, plainOff, withMarkers, noMarkers)
	}
}

// TestToggleSelection verifies space-bar selection logic.
func TestToggleSelection(t *testing.T) {
	p := modelPicker{
		rows: []modelRow{
			{id: "model-a"},
			{id: "model-b"},
		},
		cursor: 0,
	}

	// Toggle model-a on.
	p.toggleSelected()
	if !p.rows[0].selected {
		t.Error("rows[0] should be selected after first toggle")
	}

	// Move to model-b and toggle it on.
	p.cursor = 1
	p.toggleSelected()
	if !p.rows[1].selected {
		t.Error("rows[1] should be selected after toggle")
	}

	// Toggle model-a off.
	p.cursor = 0
	p.toggleSelected()
	if p.rows[0].selected {
		t.Error("rows[0] should be deselected after second toggle")
	}

	// selectedIDs should only return model-b.
	ids := p.selectedIDs()
	if len(ids) != 1 || ids[0] != "model-b" {
		t.Errorf("selectedIDs() = %v; want [model-b]", ids)
	}
}

// TestBuildModelRows_FitVsCeiling confirms that fit uses total size and ceiling
// uses active size (the core correctness invariant for MoE models).
func TestBuildModelRows_FitVsCeiling(t *testing.T) {
	info := hw.Info{
		RAMType:     "DDR5",
		RAMSpeedMTs: 5600,
		GTTBytes:    27 << 30, // 27 GiB budget
	}

	// 15.7 GB from API → ~14.63 GiB
	fakeList := []models.Model{
		{ID: "Gemma-4-26B-A4B-it-GGUF", Downloaded: true, Recipe: "llamacpp", Size: 15.7 * 1.073741824},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	r := rows[0]

	// Fit uses total size (15.7 GiB vs 27 GiB budget → Fits).
	if r.fit != advise.Fits {
		t.Errorf("fit = %v; want Fits (total 15.7 GiB < 27 GiB budget)", r.fit)
	}

	// MoE should be detected.
	if !r.isMoE {
		t.Error("isMoE should be true for Gemma-4-26B-A4B")
	}

	// Ceiling uses active size (~2.42 GiB for 4/26 of 15.7 GiB).
	// With 89.6 GB/s bandwidth: ceil ≈ 89.6 / (2.42 * 1.073741824) ≈ 34.4 t/s
	// Dense ceiling would be: 89.6 / (15.7 * 1.073741824) ≈ 5.3 t/s
	// Verify the MoE ceiling is significantly higher than a dense ceiling would be.
	denseCeiling := advise.DecodeCeilingTPS(89.6, 15.7)
	if r.ceilingTPS <= denseCeiling {
		t.Errorf("MoE ceiling %.2f t/s should exceed dense ceiling %.2f t/s (active < total)", r.ceilingTPS, denseCeiling)
	}
}

// TestBuildModelRows_SizeFromAPI verifies that size comes from m.Size (API, GB→GiB)
// and not from filesystem access.
func TestBuildModelRows_SizeFromAPI(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	// 18.8 GB from API → 18.8/1.073741824 ≈ 17.51 GiB
	fakeList := []models.Model{
		{ID: "Qwen3.6-27B-MTP-GGUF", Downloaded: true, Recipe: "llamacpp", Size: 18.8},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	r := rows[0]

	expected := 18.8 / 1.073741824
	if r.totalGiB < expected-0.01 || r.totalGiB > expected+0.01 {
		t.Errorf("totalGiB = %.4f, want ~%.4f (18.8 GB / 1.073741824)", r.totalGiB, expected)
	}
	if !r.sizeKnown {
		t.Error("sizeKnown should be true when m.Size > 0")
	}
}

// TestBuildModelRows_IncludesNotDownloaded verifies not-downloaded llamacpp models are included.
func TestBuildModelRows_IncludesNotDownloaded(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "downloaded-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
		{ID: "not-downloaded", Downloaded: false, Recipe: "llamacpp", Size: 8.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 2 {
		t.Errorf("expected 2 rows (including not-downloaded), got %d: %v", len(rows), rowIDs(rows))
	}

	// Verify downloaded field is propagated correctly.
	var foundNotDownloaded bool
	for _, r := range rows {
		if r.id == "not-downloaded" {
			foundNotDownloaded = true
			if r.downloaded {
				t.Errorf("not-downloaded row has downloaded=true")
			}
		}
	}
	if !foundNotDownloaded {
		t.Error("not-downloaded model was excluded from rows")
	}
}

// TestBuildModelRows_DownloadedSortedFirst verifies downloaded models appear before not-downloaded.
func TestBuildModelRows_DownloadedSortedFirst(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	// Deliberately put not-downloaded first in the input list.
	fakeList := []models.Model{
		{ID: "not-downloaded-A", Downloaded: false, Recipe: "llamacpp", Size: 5.0},
		{ID: "downloaded-B", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
		{ID: "not-downloaded-C", Downloaded: false, Recipe: "llamacpp", Size: 5.0},
		{ID: "downloaded-D", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 4 {
		t.Fatalf("expected 4 rows, got %d", len(rows))
	}
	// First two should be downloaded.
	if !rows[0].downloaded || !rows[1].downloaded {
		t.Errorf("first two rows should be downloaded: %v %v", rows[0].id, rows[1].id)
	}
	// Last two should be not-downloaded.
	if rows[2].downloaded || rows[3].downloaded {
		t.Errorf("last two rows should be not-downloaded: %v %v", rows[2].id, rows[3].id)
	}
	// Order within each group should be stable (preserved from input).
	if rows[0].id != "downloaded-B" || rows[1].id != "downloaded-D" {
		t.Errorf("downloaded group order: got %v %v, want downloaded-B downloaded-D", rows[0].id, rows[1].id)
	}
	if rows[2].id != "not-downloaded-A" || rows[3].id != "not-downloaded-C" {
		t.Errorf("not-downloaded group order: got %v %v, want not-downloaded-A not-downloaded-C", rows[2].id, rows[3].id)
	}
}

// TestBuildModelRows_HotMarker verifies 🔥 comes from the "hot" label, NOT the
// near-ubiquitous Suggested flag.
func TestBuildModelRows_HotMarker(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		// hot-model has the hot label but Suggested=false; plain-model has
		// Suggested=true but no hot label.
		{ID: "hot-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0, Labels: []string{"hot"}, Suggested: false},
		{ID: "plain-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0, Suggested: true},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}
	for _, r := range rows {
		switch r.id {
		case "hot-model":
			if !r.hot {
				t.Errorf("hot-model: hot = false, want true (hot label → 🔥)")
			}
		case "plain-model":
			if r.hot {
				t.Errorf("plain-model: hot = true, want false (Suggested flag must not drive 🔥)")
			}
		}
	}
}

// TestBuildModelRows_Recommended verifies ⚡ flags models that fit comfortably
// AND have a decent predicted decode ceiling (≥ recommendTPSThreshold). A
// fitting-but-slow large model is NOT recommended.
func TestBuildModelRows_Recommended(t *testing.T) {
	// No RAMType → BandwidthGBs falls back to ~89.6 GB/s.
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		// ~4.66 GiB → ceiling ~17.9 t/s, fits → recommended.
		{ID: "small-fast", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
		// ~18.6 GiB → ceiling ~4.5 t/s (< 10), fits but slow → NOT recommended.
		{ID: "big-slow", Downloaded: true, Recipe: "llamacpp", Size: 20.0},
		// ~32.6 GiB → spills the 27 GiB budget → NOT recommended.
		{ID: "spills", Downloaded: true, Recipe: "llamacpp", Size: 35.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	got := map[string]bool{}
	for _, r := range rows {
		got[r.id] = r.recommended
	}
	if !got["small-fast"] {
		t.Errorf("small-fast: recommended = false, want true (fits + decent t/s)")
	}
	if got["big-slow"] {
		t.Errorf("big-slow: recommended = true, want false (below t/s threshold)")
	}
	if got["spills"] {
		t.Errorf("spills: recommended = true, want false (does not fit)")
	}
}

// TestBuildModelRows_FiltersNonLlamacpp verifies that non-llamacpp models are excluded.
func TestBuildModelRows_FiltersNonLlamacpp(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "llama-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0},
		{ID: "flux-model", Downloaded: true, Recipe: "sd-cpp", Size: 5.0},
		{ID: "whisper-model", Downloaded: true, Recipe: "whispercpp", Size: 5.0},
		{ID: "vllm-model", Downloaded: true, Recipe: "vllm", Size: 5.0},
		{ID: "flm-model", Downloaded: true, Recipe: "flm", Size: 5.0},
		{ID: "kokoro-model", Downloaded: true, Recipe: "kokoro", Size: 5.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 1 {
		t.Errorf("expected 1 row (llamacpp only), got %d; ids: %v", len(rows), rowIDs(rows))
	}
	if len(rows) > 0 && rows[0].id != "llama-model" {
		t.Errorf("unexpected row id %q, want llama-model", rows[0].id)
	}
}

// TestBuildModelRows_UnknownSizeIsNeutral verifies that a model with unknown size
// (m.Size == 0) gets a neutral fit (not Spills) and renders "?" not "❌".
func TestBuildModelRows_UnknownSizeIsNeutral(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "mystery-model", Downloaded: true, Recipe: "llamacpp", Size: 0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	r := rows[0]

	if r.fit == advise.Spills {
		t.Error("unknown-size row should not have fit=Spills")
	}
	if r.sizeKnown {
		t.Error("sizeKnown should be false")
	}

	rendered := formatModelRow(r.id, r.totalGiB, r.sizeKnown, r.fit, r.ceilingTPS, r.isMoE, r.estimated, r.selected, r.downloaded, r.hot, r.recommended)
	if strings.Contains(rendered, "❌") {
		t.Errorf("unknown-size row rendered ❌, want ?: %q", rendered)
	}
	if !strings.Contains(rendered, "?") {
		t.Errorf("unknown-size row should render ?, got: %q", rendered)
	}
}

// TestBuildModelRows_MTPModeFilter verifies MTP mode filtering by label.
func TestBuildModelRows_MTPModeFilter(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "mtp-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0, Labels: []string{"mtp", "llamacpp"}},
		{ID: "plain-model", Downloaded: true, Recipe: "llamacpp", Size: 5.0, Labels: []string{"llamacpp"}},
		{ID: "not-downloaded-mtp", Downloaded: false, Recipe: "llamacpp", Size: 5.0, Labels: []string{"mtp"}},
	}

	t.Run("MTP mode keeps only mtp-labeled", func(t *testing.T) {
		rows := buildModelRows(fakeList, info, ModeMTP)
		ids := rowIDs(rows)
		for _, r := range rows {
			if r.id == "plain-model" {
				t.Errorf("plain-model (no mtp label) should be excluded in MTP mode; got: %v", ids)
			}
		}
		if len(rows) != 2 {
			t.Errorf("expected 2 rows in MTP mode (mtp-model + not-downloaded-mtp), got %d: %v", len(rows), ids)
		}
	})

	t.Run("HTTP mode keeps all llamacpp regardless of mtp label", func(t *testing.T) {
		rows := buildModelRows(fakeList, info, ModeHTTP)
		if len(rows) != 3 {
			t.Errorf("expected 3 rows in HTTP mode, got %d: %v", len(rows), rowIDs(rows))
		}
	})

	t.Run("Backend mode keeps all llamacpp regardless of mtp label", func(t *testing.T) {
		rows := buildModelRows(fakeList, info, ModeBackend)
		if len(rows) != 3 {
			t.Errorf("expected 3 rows in Backend mode, got %d: %v", len(rows), rowIDs(rows))
		}
	})
}

// TestFilterRows verifies case-insensitive id-first, label-second matching.
func TestFilterRows(t *testing.T) {
	rows := []modelRow{
		{id: "Qwen3-8B-GGUF", labels: []string{"llamacpp"}},
		{id: "Gemma-3-27B-GGUF", labels: []string{"hot", "mtp"}},
		{id: "Llama-3-8B-GGUF", labels: []string{"llamacpp"}},
	}

	t.Run("empty query returns all in order", func(t *testing.T) {
		got := filterRows(rows, "")
		if want := []int{0, 1, 2}; !equalInts(got, want) {
			t.Errorf("filterRows(\"\") = %v; want %v", got, want)
		}
	})

	t.Run("whitespace query returns all", func(t *testing.T) {
		got := filterRows(rows, "   ")
		if want := []int{0, 1, 2}; !equalInts(got, want) {
			t.Errorf("filterRows(\"   \") = %v; want %v", got, want)
		}
	})

	t.Run("case-insensitive id substring", func(t *testing.T) {
		got := filterRows(rows, "qwen")
		if want := []int{0}; !equalInts(got, want) {
			t.Errorf("filterRows(\"qwen\") = %v; want %v", got, want)
		}
	})

	t.Run("label match ranks after id matches", func(t *testing.T) {
		// "mtp" matches row 1 only via its label → it should appear, alone.
		got := filterRows(rows, "mtp")
		if want := []int{1}; !equalInts(got, want) {
			t.Errorf("filterRows(\"mtp\") = %v; want %v", got, want)
		}
	})

	t.Run("id matches come before label-only matches", func(t *testing.T) {
		// Query "gemma" matches row 1 by id. Query "llamacpp" matches rows 0,2
		// by label. A query hitting both an id and another row's label must
		// list the id hit first.
		mixed := []modelRow{
			{id: "hot-sauce-GGUF", labels: []string{"x"}}, // id contains "hot"
			{id: "Gemma-GGUF", labels: []string{"hot"}},   // label contains "hot"
		}
		got := filterRows(mixed, "hot")
		if want := []int{0, 1}; !equalInts(got, want) {
			t.Errorf("filterRows(\"hot\") = %v; want %v (id hit before label hit)", got, want)
		}
	})

	t.Run("no match returns empty", func(t *testing.T) {
		got := filterRows(rows, "zzz")
		if len(got) != 0 {
			t.Errorf("filterRows(\"zzz\") = %v; want empty", got)
		}
	})
}

// TestVisibleRange verifies the scroll window keeps the cursor visible.
func TestVisibleRange(t *testing.T) {
	t.Run("fits without scrolling", func(t *testing.T) {
		start, end := visibleRange(5, 2, 10)
		if start != 0 || end != 5 {
			t.Errorf("visibleRange(5,2,10) = (%d,%d); want (0,5)", start, end)
		}
	})

	t.Run("maxRows non-positive shows all", func(t *testing.T) {
		start, end := visibleRange(5, 2, 0)
		if start != 0 || end != 5 {
			t.Errorf("visibleRange(5,2,0) = (%d,%d); want (0,5)", start, end)
		}
	})

	t.Run("cursor near top clamps to 0", func(t *testing.T) {
		start, end := visibleRange(100, 1, 10)
		if start != 0 || end != 10 {
			t.Errorf("visibleRange(100,1,10) = (%d,%d); want (0,10)", start, end)
		}
	})

	t.Run("cursor near bottom clamps to end", func(t *testing.T) {
		start, end := visibleRange(100, 99, 10)
		if start != 90 || end != 100 {
			t.Errorf("visibleRange(100,99,10) = (%d,%d); want (90,100)", start, end)
		}
	})

	t.Run("cursor in middle stays visible and windowed", func(t *testing.T) {
		start, end := visibleRange(100, 50, 10)
		if end-start != 10 {
			t.Errorf("window size = %d; want 10", end-start)
		}
		if 50 < start || 50 >= end {
			t.Errorf("cursor 50 not visible in [%d,%d)", start, end)
		}
	})
}

// pickerWithRows builds a model on screenModel with rows + a populated filter view.
func pickerWithRows(rows []modelRow) model {
	m := model{current: screenModel}
	m.modelPicker.rows = append([]modelRow(nil), rows...)
	m.modelPicker.applyFilter()
	return m
}

// TestSlashEntersFilterMode verifies "/" focuses the filter input.
func TestSlashEntersFilterMode(t *testing.T) {
	m := pickerWithRows([]modelRow{{id: "alpha"}, {id: "beta"}})
	m2 := send(m, tea.KeyPressMsg{Code: '/', Text: "/"})
	if !m2.modelPicker.filtering {
		t.Error("\"/\" should set filtering=true")
	}
	// "/" itself must not be inserted into the query.
	if m2.modelPicker.filter != "" {
		t.Errorf("filter = %q; want empty after entering filter mode", m2.modelPicker.filter)
	}
}

// TestFilterTypingNarrowsView verifies typed characters narrow the visible set.
func TestFilterTypingNarrowsView(t *testing.T) {
	m := pickerWithRows([]modelRow{
		{id: "Qwen3-8B"}, {id: "Gemma-3"}, {id: "Qwen3-4B"},
	})
	m = send(m, tea.KeyPressMsg{Code: '/', Text: "/"})
	for _, r := range "qwen" {
		m = send(m, tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	if m.modelPicker.filter != "qwen" {
		t.Fatalf("filter = %q; want \"qwen\"", m.modelPicker.filter)
	}
	if got := len(m.modelPicker.view()); got != 2 {
		t.Errorf("visible = %d rows; want 2 (the two Qwen models)", got)
	}

	// Backspace shrinks the query and re-widens the view.
	m = send(m, tea.KeyPressMsg{Code: tea.KeyBackspace})
	if m.modelPicker.filter != "qwe" {
		t.Errorf("filter after backspace = %q; want \"qwe\"", m.modelPicker.filter)
	}
}

// TestFilterEscClears verifies Esc while editing clears the query and exits.
func TestFilterEscClears(t *testing.T) {
	m := pickerWithRows([]modelRow{{id: "alpha"}, {id: "beta"}})
	m = send(m, tea.KeyPressMsg{Code: '/', Text: "/"})
	m = send(m, tea.KeyPressMsg{Code: 'a', Text: "a"})
	m = send(m, tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.modelPicker.filtering {
		t.Error("Esc should exit filter-edit mode")
	}
	if m.modelPicker.filter != "" {
		t.Errorf("filter = %q; want cleared after Esc", m.modelPicker.filter)
	}
	if len(m.modelPicker.view()) != 2 {
		t.Errorf("view = %d; want all 2 rows after clearing filter", len(m.modelPicker.view()))
	}
}

// TestFilterEnterKeepsQuery verifies Enter exits edit mode but keeps the filter.
func TestFilterEnterKeepsQuery(t *testing.T) {
	m := pickerWithRows([]modelRow{{id: "alpha"}, {id: "beta"}})
	m = send(m, tea.KeyPressMsg{Code: '/', Text: "/"})
	m = send(m, tea.KeyPressMsg{Code: 'a', Text: "a"})
	m = send(m, tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.modelPicker.filtering {
		t.Error("Enter should leave filter-edit mode")
	}
	if m.modelPicker.filter != "a" {
		t.Errorf("filter = %q; want \"a\" preserved", m.modelPicker.filter)
	}
	if m.current != screenModel {
		t.Errorf("current = %d; want screenModel (Enter applies filter, does not advance)", m.current)
	}
}

// TestEscClearsActiveFilterBeforeBack verifies a list-nav Esc clears an applied
// filter first, and only a second Esc navigates back.
func TestEscClearsActiveFilterBeforeBack(t *testing.T) {
	m := pickerWithRows([]modelRow{{id: "alpha"}, {id: "beta"}})
	m.modelPicker.filter = "a"
	m.modelPicker.applyFilter()

	m = send(m, tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.modelPicker.filter != "" {
		t.Errorf("first Esc should clear filter; filter = %q", m.modelPicker.filter)
	}
	if m.current != screenModel {
		t.Errorf("first Esc should stay on screenModel; current = %d", m.current)
	}

	m = send(m, tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.current != screenMode {
		t.Errorf("second Esc should go back to screenMode; current = %d", m.current)
	}
}

// TestToggleOnFilteredRowPersists verifies selecting a filtered row keeps that
// selection after the filter is cleared.
func TestToggleOnFilteredRowPersists(t *testing.T) {
	m := pickerWithRows([]modelRow{
		{id: "Qwen3-8B"}, {id: "Gemma-3"}, {id: "Qwen3-4B"},
	})
	// Filter to the Qwen models, select the first visible one.
	m = send(m, tea.KeyPressMsg{Code: '/', Text: "/"})
	for _, r := range "qwen" {
		m = send(m, tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	m = send(m, tea.KeyPressMsg{Code: tea.KeyEnter}) // exit edit, keep filter
	m = send(m, tea.KeyPressMsg{Code: ' ', Text: " "})

	// Clear the filter; the selection must survive.
	m = send(m, tea.KeyPressMsg{Code: tea.KeyEscape})
	if ids := m.modelPicker.selectedIDs(); len(ids) != 1 || ids[0] != "Qwen3-8B" {
		t.Errorf("selectedIDs = %v; want [Qwen3-8B] (selection survives filter clear)", ids)
	}
}

// TestRenderModelScreenScrolls verifies the render windows the list to maxRows
// and shows a "more below" affordance instead of overflowing.
func TestRenderModelScreenScrolls(t *testing.T) {
	st := newStyles(true)
	rows := make([]modelRow, 30)
	for i := range rows {
		rows[i] = modelRow{id: fmt.Sprintf("model-%02d", i), sizeKnown: true, totalGiB: 4}
	}
	p := &modelPicker{rows: rows, cursor: 0}
	p.applyFilter()

	out := renderModelScreen(p, st, 10)

	if !strings.Contains(out, "↓ 20 more") {
		t.Errorf("expected \"↓ 20 more\" affordance; got:\n%s", out)
	}
	// The last model must not be rendered when windowed at the top.
	if strings.Contains(out, "model-29") {
		t.Errorf("windowed render should not include model-29 with cursor at top")
	}
}

// TestRenderModelScreenFilterHeader verifies the filter line shows the query
// and a match count.
func TestRenderModelScreenFilterHeader(t *testing.T) {
	st := newStyles(true)
	p := &modelPicker{rows: []modelRow{
		{id: "Qwen3-8B"}, {id: "Gemma-3"}, {id: "Qwen3-4B"},
	}}
	p.filter = "qwen"
	p.applyFilter()

	out := renderModelScreen(p, st, 20)
	// The query text is styled separately from the leading "/", so assert on
	// the contiguous query run rather than "/qwen".
	if !strings.Contains(out, "qwen") {
		t.Errorf("expected filter query \"qwen\" in header; got:\n%s", out)
	}
	if !strings.Contains(out, "2 matches") {
		t.Errorf("expected \"2 matches\"; got:\n%s", out)
	}
}

// TestFilterCtrlCQuits verifies ctrl+c still quits while editing the filter.
func TestFilterCtrlCQuits(t *testing.T) {
	m := pickerWithRows([]modelRow{{id: "alpha"}})
	m = send(m, tea.KeyPressMsg{Code: '/', Text: "/"})
	_, cmd := m.Update(tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})
	if cmd == nil {
		t.Fatal("ctrl+c while filtering should return a quit Cmd")
	}
	if msg := cmd(); msg == nil {
		t.Error("ctrl+c Cmd should produce a quit message")
	} else if _, ok := msg.(tea.QuitMsg); !ok {
		t.Errorf("ctrl+c Cmd produced %T; want tea.QuitMsg", msg)
	}
}

// TestApiSizeMap verifies only known-size rows are captured, keyed by id.
func TestApiSizeMap(t *testing.T) {
	rows := []modelRow{
		{id: "a", totalGiB: 4.5, sizeKnown: true},
		{id: "b", totalGiB: 0, sizeKnown: false},
		{id: "c", totalGiB: 17.0, sizeKnown: true},
	}
	got := apiSizeMap(rows)
	if len(got) != 2 {
		t.Fatalf("len = %d; want 2 (unknown-size row excluded)", len(got))
	}
	if got["a"] != 4.5 || got["c"] != 17.0 {
		t.Errorf("apiSizeMap = %v; want a=4.5 c=17.0", got)
	}
	if _, ok := got["b"]; ok {
		t.Error("row b has unknown size and must be excluded")
	}
}

func equalInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func rowIDs(rows []modelRow) []string {
	ids := make([]string, len(rows))
	for i, r := range rows {
		ids[i] = r.id
	}
	return ids
}

// TestModelScreenHeader is a teatest integration test that asserts the model
// screen header appears. Uses the fake fetch seam — no real lemonade needed.
func TestModelScreenHeader(t *testing.T) {
	info := hw.Info{
		GfxArch:  "gfx1150",
		RAMGiB:   54.5,
		GTTBytes: 27 << 30,
	}
	cfg := Config{BaseURL: "http://fake-host"}

	// Use the internal model struct directly (same package) so we can inject seams.
	m := model{
		current: screenModel,
		info:    info,
		cfg:     cfg,
	}
	// Inject fake fetch that returns an empty list immediately.
	m.modelPicker.fetchModels = func(baseURL string) ([]models.Model, error) {
		return []models.Model{}, nil
	}
	m.modelPicker.loading = true // simulate loading state

	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(120, 40))
	t.Cleanup(func() { _ = tm.Quit() })

	// Send the loaded message directly.
	tm.Send(modelsLoadedMsg{models: []models.Model{}, err: nil})

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Select Models"))
	}, teatest.WithDuration(3*time.Second), teatest.WithCheckInterval(10*time.Millisecond))
}

// TestModelPickerSpaceAndEnter verifies space toggles selection and Enter
// carries selected IDs using only pure unit logic (no teatest).
func TestModelPickerSpaceAndEnter(t *testing.T) {
	info := hw.Info{GTTBytes: 27 << 30}
	fakeList := []models.Model{
		{ID: "model-alpha", Downloaded: true, Recipe: "llamacpp", Size: 4.0},
		{ID: "model-beta", Downloaded: true, Recipe: "llamacpp", Size: 4.0},
	}

	rows := buildModelRows(fakeList, info, ModeHTTP)

	p := modelPicker{rows: rows, cursor: 0}

	// Space on first model.
	p.toggleSelected()
	if !p.rows[0].selected {
		t.Error("model-alpha should be selected")
	}

	// Move to second and select.
	p.cursor = 1
	p.toggleSelected()

	// Enter: collect selected IDs.
	ids := p.selectedIDs()
	if len(ids) != 2 {
		t.Errorf("selectedIDs() = %v; want 2 items", ids)
	}
}

// TestModelEnterGuardsEmptySelection verifies that Enter with no models
// selected stays on screenModel (and flags needSelection), while Enter with
// at least one selected advances to screenParams carrying the selected IDs.
func TestModelEnterGuardsEmptySelection(t *testing.T) {
	rows := []modelRow{
		{id: "model-alpha"},
		{id: "model-beta"},
	}

	t.Run("empty selection stays on screenModel", func(t *testing.T) {
		m := model{current: screenModel}
		m.modelPicker.rows = append([]modelRow(nil), rows...)

		next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
		nm := next.(model)

		if nm.current != screenModel {
			t.Errorf("current = %v; want screenModel (no advance on empty selection)", nm.current)
		}
		if !nm.modelPicker.needSelection {
			t.Error("needSelection should be set after Enter with empty selection")
		}
		if len(nm.selectedModels) != 0 {
			t.Errorf("selectedModels = %v; want empty", nm.selectedModels)
		}
	})

	t.Run("non-empty selection advances to screenParams", func(t *testing.T) {
		m := model{current: screenModel}
		m.modelPicker.rows = append([]modelRow(nil), rows...)
		m.modelPicker.rows[1].selected = true
		m.modelPicker.rows[1].downloaded = true // on disk → no pull needed, advances

		next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
		nm := next.(model)

		if nm.current != screenParams {
			t.Errorf("current = %v; want screenParams", nm.current)
		}
		if len(nm.selectedModels) != 1 || nm.selectedModels[0] != "model-beta" {
			t.Errorf("selectedModels = %v; want [model-beta]", nm.selectedModels)
		}
	})
}

// TestSpaceKeyTogglesViaUpdate confirms that a real bubbletea v2 space
// KeyPressMsg (whose String() returns "space", not " ") toggles selection
// through the full Update path. The previous case " ": handler never matched,
// so this test fails without the "space" case in app.go.
func TestSpaceKeyTogglesViaUpdate(t *testing.T) {
	// Guard: document the v2 key-string contract that motivates the fix.
	if got := (tea.KeyPressMsg{Code: ' ', Text: " "}).String(); got != "space" {
		t.Fatalf("bubbletea v2 contract changed: space key String() = %q, want %q", got, "space")
	}

	rows := []modelRow{
		{id: "alpha"},
		{id: "beta"},
	}
	m := model{current: screenModel}
	m.modelPicker.rows = append([]modelRow(nil), rows...)
	m.modelPicker.needSelection = true

	spaceKey := tea.KeyPressMsg{Code: ' ', Text: " "}

	// First space: alpha (cursor=0) should become selected, needSelection cleared.
	next, _ := m.Update(spaceKey)
	nm := next.(model)
	if !nm.modelPicker.rows[0].selected {
		t.Error("first space: rows[0] should be selected")
	}
	if nm.modelPicker.needSelection {
		// toggleSelected clears needSelection indirectly by making a valid selection.
		// If this fails it means the key wasn't handled at all.
		t.Error("needSelection should clear after a successful toggle")
	}

	// Second space: deselects.
	next2, _ := nm.Update(spaceKey)
	nm2 := next2.(model)
	if nm2.modelPicker.rows[0].selected {
		t.Error("second space: rows[0] should be deselected")
	}
}

// Compile-time check: model implements tea.Model.
var _ tea.Model = model{}

// --- pull-on-demand for not-downloaded selections ---

func TestPendingPullIDs(t *testing.T) {
	p := &modelPicker{rows: []modelRow{
		{id: "A", selected: true, downloaded: true},
		{id: "B", selected: true, downloaded: false, totalGiB: 2.5, sizeKnown: true},
		{id: "C", selected: false, downloaded: false},
	}}
	got := p.pendingPullIDs()
	if len(got) != 1 || got[0] != "B" {
		t.Fatalf("pendingPullIDs = %v; want [B]", got)
	}
}

func TestEnterWithUndownloadedSetsNeedPull(t *testing.T) {
	m := model{current: screenModel}
	m.modelPicker.rows = []modelRow{
		{id: "B", selected: true, downloaded: false, totalGiB: 2.5, sizeKnown: true},
	}
	m2 := send(m, tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m2.modelPicker.needPull {
		t.Fatal("Enter with a not-downloaded selection should set needPull")
	}
	if m2.current != screenModel {
		t.Fatalf("should not advance past model screen; current = %d", m2.current)
	}
}

func TestEnterAllDownloadedAdvances(t *testing.T) {
	m := model{current: screenModel}
	m.modelPicker.rows = []modelRow{
		{id: "A", selected: true, downloaded: true, totalGiB: 4, sizeKnown: true},
	}
	m2 := send(m, tea.KeyPressMsg{Code: tea.KeyEnter})
	if m2.modelPicker.needPull {
		t.Error("all-downloaded selection should not set needPull")
	}
	if m2.current != screenParams {
		t.Errorf("should advance to params; current = %d", m2.current)
	}
}

func TestNeedPullPullKeyReturnsCmd(t *testing.T) {
	m := model{current: screenModel}
	m.modelPicker.rows = []modelRow{{id: "B", selected: true, downloaded: false}}
	m.modelPicker.needPull = true
	next, cmd := m.Update(tea.KeyPressMsg{Code: 'p', Text: "p"})
	if next.(model).modelPicker.needPull {
		t.Error("pressing p should clear needPull")
	}
	if cmd == nil {
		t.Error("pressing p should return a pull Cmd")
	}
}

func TestNeedPullEscCancels(t *testing.T) {
	m := model{current: screenModel}
	m.modelPicker.rows = []modelRow{{id: "B", selected: true, downloaded: false}}
	m.modelPicker.needPull = true
	m2 := send(m, tea.KeyPressMsg{Code: tea.KeyEscape})
	if m2.modelPicker.needPull {
		t.Error("Esc should cancel needPull")
	}
	if m2.current != screenModel {
		t.Errorf("Esc on needPull should stay on model screen; got %d", m2.current)
	}
}

func TestShellSingleQuote(t *testing.T) {
	if got := shellSingleQuote("Qwen3.5-4B-MTP-GGUF"); got != "'Qwen3.5-4B-MTP-GGUF'" {
		t.Errorf("shellSingleQuote = %q", got)
	}
	if got := shellSingleQuote("a'b"); got != `'a'\''b'` {
		t.Errorf("shellSingleQuote escape = %q", got)
	}
}
